#!/bin/bash
# =============================================================
#  Wiki.js 資料匯出腳本（在舊主機執行）
#  用法：sudo bash migrate-export.sh
# =============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="wikijs-backup-${TIMESTAMP}"
BACKUP_DIR="/tmp/${BACKUP_NAME}"
BACKUP_FILE="/tmp/${BACKUP_NAME}.tar.gz"

[ "$EUID" -eq 0 ] || die "請以 root 或 sudo 執行"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       Wiki.js 資料匯出                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

mkdir -p "$BACKUP_DIR"

# ─────────────────────────────────────────────────────────────
# STEP 1：確認容器狀態
# ─────────────────────────────────────────────────────────────
log "確認容器狀態..."
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | grep -E "NAMES|wiki|db" || true

# 自動偵測 db 容器名稱（可能是 db 或 wiki-db 等）
DB_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "^db$|wiki.*db|postgres" | head -1)
WIKI_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "^wiki$" | head -1)

[ -n "$DB_CONTAINER" ]   || die "找不到資料庫容器，請確認 'docker ps' 有 postgres 容器"
[ -n "$WIKI_CONTAINER" ] || die "找不到 wiki 容器"

ok "資料庫容器：${DB_CONTAINER}"
ok "Wiki 容器：${WIKI_CONTAINER}"

# ─────────────────────────────────────────────────────────────
# STEP 2：取得資料庫認證
# ─────────────────────────────────────────────────────────────
log "讀取資料庫認證..."
DB_USER=$(docker exec "$DB_CONTAINER" env | grep POSTGRES_USER | cut -d= -f2)
DB_PASS=$(docker exec "$DB_CONTAINER" env | grep POSTGRES_PASSWORD | cut -d= -f2)
DB_NAME=$(docker exec "$DB_CONTAINER" env | grep POSTGRES_DB | cut -d= -f2)

[ -n "$DB_USER" ] || die "無法取得 POSTGRES_USER"
[ -n "$DB_NAME" ] || die "無法取得 POSTGRES_DB"

ok "資料庫：${DB_NAME}，使用者：${DB_USER}"

# 儲存認證資訊（供還原時參考）
cat > "$BACKUP_DIR/credentials.env" << EOF
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
DB_NAME=${DB_NAME}
EXPORT_TIME=${TIMESTAMP}
WIKI_IMAGE=$(docker inspect "$WIKI_CONTAINER" --format '{{.Config.Image}}')
EOF

# ─────────────────────────────────────────────────────────────
# STEP 3：備份 PostgreSQL 資料庫
# ─────────────────────────────────────────────────────────────
log "匯出 PostgreSQL 資料庫（${DB_NAME}）..."
docker exec "$DB_CONTAINER" \
  pg_dump -U "$DB_USER" --no-owner --no-acl --clean --if-exists "$DB_NAME" \
  > "$BACKUP_DIR/database.sql"

DB_SIZE=$(wc -c < "$BACKUP_DIR/database.sql")
ok "資料庫匯出完成（$(( DB_SIZE / 1024 )) KB）"

# ─────────────────────────────────────────────────────────────
# STEP 4：備份上傳檔案（/wiki/data/content）
# ─────────────────────────────────────────────────────────────
log "匯出上傳檔案..."
# 用臨時容器從 volume 打包，volume name 自動偵測
VOLUME_NAME=$(docker inspect "$WIKI_CONTAINER" \
  --format '{{range .Mounts}}{{if eq .Destination "/wiki/data/content"}}{{.Name}}{{end}}{{end}}')

if [ -n "$VOLUME_NAME" ]; then
  log "Volume 名稱：${VOLUME_NAME}"
  docker run --rm \
    -v "${VOLUME_NAME}:/source:ro" \
    alpine \
    tar czf - -C /source . \
    > "$BACKUP_DIR/content.tar.gz"
  ok "上傳檔案備份完成"
else
  # fallback：直接從容器 cp
  warn "找不到 volume，改從容器直接複製..."
  docker cp "${WIKI_CONTAINER}:/wiki/data/content" "$BACKUP_DIR/content-dir"
  tar czf "$BACKUP_DIR/content.tar.gz" -C "$BACKUP_DIR" content-dir
  rm -rf "$BACKUP_DIR/content-dir"
  ok "上傳檔案備份完成（fallback）"
fi

# ─────────────────────────────────────────────────────────────
# STEP 5：打包所有備份
# ─────────────────────────────────────────────────────────────
log "打包備份檔案..."
tar czf "$BACKUP_FILE" -C /tmp "$BACKUP_NAME"
rm -rf "$BACKUP_DIR"

TOTAL_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
ok "備份完成：${BACKUP_FILE}（${TOTAL_SIZE}）"

# ─────────────────────────────────────────────────────────────
# 完成
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  備份完成！請將以下檔案複製到新主機      ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  備份檔案：${YELLOW}${BACKUP_FILE}${NC}"
echo -e "  檔案大小：${TOTAL_SIZE}"
echo ""
echo -e "  複製到新主機的指令（在新主機執行）："
echo -e "  ${BLUE}scp root@$(hostname -I | awk '{print $1}'):${BACKUP_FILE} /tmp/${NC}"
echo ""
