#!/bin/bash
# =============================================================
#  Wiki.js 資料匯入腳本（在新主機執行）
#  用法：sudo bash migrate-import.sh /tmp/wikijs-backup-YYYYMMDD-HHMMSS.tar.gz
# =============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

BACKUP_FILE="${1:-}"
INSTALL_DIR="/opt/wikijs"
RESTORE_DIR="/tmp/wikijs-restore"

[ "$EUID" -eq 0 ] || die "請以 root 或 sudo 執行"
[ -n "$BACKUP_FILE" ] || die "用法：sudo bash migrate-import.sh /tmp/wikijs-backup-YYYYMMDD.tar.gz"
[ -f "$BACKUP_FILE" ] || die "找不到備份檔案：${BACKUP_FILE}"
[ -f "$INSTALL_DIR/docker-compose.yml" ] || die "找不到 ${INSTALL_DIR}/docker-compose.yml，請先完成新主機的部署"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       Wiki.js 資料還原                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

# ─────────────────────────────────────────────────────────────
# STEP 1：解壓縮備份
# ─────────────────────────────────────────────────────────────
log "解壓縮備份檔案..."
rm -rf "$RESTORE_DIR"
mkdir -p "$RESTORE_DIR"
tar xzf "$BACKUP_FILE" -C "$RESTORE_DIR" --strip-components=1
ok "解壓縮完成"

# 顯示備份資訊
if [ -f "$RESTORE_DIR/credentials.env" ]; then
  log "備份資訊："
  grep -E "DB_NAME|EXPORT_TIME|WIKI_IMAGE" "$RESTORE_DIR/credentials.env" | while IFS= read -r line; do
    echo "      $line"
  done
fi

# ─────────────────────────────────────────────────────────────
# STEP 2：確認新主機容器狀態
# ─────────────────────────────────────────────────────────────
log "確認新主機容器狀態..."
cd "$INSTALL_DIR"

DB_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "^db$|wiki.*db|postgres" | head -1)
WIKI_CONTAINER=$(docker ps -a --format "{{.Names}}" | grep -E "^wiki$" | head -1)

[ -n "$DB_CONTAINER" ] || die "找不到資料庫容器，請確認 docker compose up -d 已執行"
ok "資料庫容器：${DB_CONTAINER}"

# 讀取新主機的 DB 認證
NEW_DB_USER=$(docker exec "$DB_CONTAINER" env | grep POSTGRES_USER | cut -d= -f2)
NEW_DB_NAME=$(docker exec "$DB_CONTAINER" env | grep POSTGRES_DB | cut -d= -f2)

[ -n "$NEW_DB_USER" ] || die "無法取得新主機的 POSTGRES_USER"
ok "新主機資料庫：${NEW_DB_NAME}，使用者：${NEW_DB_USER}"

# ─────────────────────────────────────────────────────────────
# STEP 3：停止 wiki（保留 DB 繼續運行）
# ─────────────────────────────────────────────────────────────
log "暫停 Wiki.js 服務（保留資料庫）..."
docker compose stop wiki
ok "Wiki.js 已停止"

# ─────────────────────────────────────────────────────────────
# STEP 4：還原資料庫
# ─────────────────────────────────────────────────────────────
log "還原 PostgreSQL 資料庫..."

[ -f "$RESTORE_DIR/database.sql" ] || die "備份中找不到 database.sql"

# 清空並重建目標資料庫
docker exec "$DB_CONTAINER" \
  psql -U "$NEW_DB_USER" -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${NEW_DB_NAME}' AND pid <> pg_backend_pid();" \
  postgres >/dev/null 2>&1 || true

docker exec "$DB_CONTAINER" \
  psql -U "$NEW_DB_USER" -c "DROP DATABASE IF EXISTS ${NEW_DB_NAME};" postgres

docker exec "$DB_CONTAINER" \
  psql -U "$NEW_DB_USER" -c "CREATE DATABASE ${NEW_DB_NAME};" postgres

# 匯入備份
docker exec -i "$DB_CONTAINER" \
  psql -U "$NEW_DB_USER" -d "$NEW_DB_NAME" \
  < "$RESTORE_DIR/database.sql"

ok "資料庫還原完成"

# ─────────────────────────────────────────────────────────────
# STEP 5：還原上傳檔案
# ─────────────────────────────────────────────────────────────
if [ -f "$RESTORE_DIR/content.tar.gz" ]; then
  log "還原上傳檔案..."

  # 找到新主機的 wiki data volume
  VOLUME_NAME=$(docker inspect "$WIKI_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/wiki/data/content"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || echo "")

  if [ -n "$VOLUME_NAME" ]; then
    log "還原至 volume：${VOLUME_NAME}"
    # 先清空 volume
    docker run --rm -v "${VOLUME_NAME}:/target" alpine sh -c "rm -rf /target/* /target/.[!.]*" 2>/dev/null || true
    # 解壓縮備份進去
    docker run --rm \
      -v "${VOLUME_NAME}:/target" \
      -v "$RESTORE_DIR:/backup:ro" \
      alpine \
      tar xzf /backup/content.tar.gz -C /target
  else
    warn "找不到 volume，改用 docker cp..."
    # 啟動臨時容器
    docker start "$WIKI_CONTAINER" >/dev/null 2>&1 || true
    sleep 3
    tar xzf "$RESTORE_DIR/content.tar.gz" -C "$RESTORE_DIR"
    docker cp "$RESTORE_DIR/." "${WIKI_CONTAINER}:/wiki/data/content/"
    docker stop "$WIKI_CONTAINER" >/dev/null 2>&1 || true
  fi

  ok "上傳檔案還原完成"
else
  warn "備份中沒有 content.tar.gz，跳過檔案還原"
fi

# ─────────────────────────────────────────────────────────────
# STEP 6：重啟 Wiki.js
# ─────────────────────────────────────────────────────────────
log "重新啟動 Wiki.js..."
cd "$INSTALL_DIR"
docker compose up -d wiki
ok "Wiki.js 重啟完成"

# ─────────────────────────────────────────────────────────────
# 清理
# ─────────────────────────────────────────────────────────────
rm -rf "$RESTORE_DIR"

# ─────────────────────────────────────────────────────────────
# 完成
# ─────────────────────────────────────────────────────────────
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  資料還原完成！                           ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Wiki.js 網址：${BLUE}http://${SERVER_IP}${NC}"
echo -e "  請等待 ${YELLOW}30~60 秒${NC}讓服務完全啟動"
echo -e "  查看啟動進度：${BLUE}docker logs -f wiki${NC}"
echo ""
echo -e "  ${YELLOW}注意：${NC}還原後請至 Admin → General 確認以下設定："
echo -e "    ・網站 URL（若 IP/Domain 已變更）"
echo -e "    ・Storage 設定"
echo -e "    ・Authentication 設定"
echo ""
