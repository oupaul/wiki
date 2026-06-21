#!/bin/bash
# =============================================================
#  Wiki.js 一鍵部署腳本
#  目標：全新 Ubuntu 22.04 / 24.04
#  用法：curl -fsSL https://raw.githubusercontent.com/oupaul/wiki/main/deploy.sh | sudo bash
# =============================================================
set -euo pipefail

# ── 顏色 ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── 設定 ──────────────────────────────────────────────────────
REPO_URL="https://github.com/oupaul/wiki.git"
INSTALL_DIR="/opt/wikijs"
SRC_DIR="$INSTALL_DIR/src"
IMAGE_NAME="wikijs-custom"
DB_NAME="wiki"
DB_USER="wikijs"
DB_PASS="$(openssl rand -base64 20 | tr -d '=+/' | head -c 20)"
HOST_PORT="${HOST_PORT:-80}"   # 可用環境變數覆寫，例如 HOST_PORT=8080

# ── 檢查 root ─────────────────────────────────────────────────
[ "$EUID" -eq 0 ] || die "請以 root 或 sudo 執行此腳本"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       Wiki.js 自訂版  一鍵部署腳本       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

# ─────────────────────────────────────────────────────────────
# STEP 1：安裝 Docker
# ─────────────────────────────────────────────────────────────
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  ok "Docker 已安裝（$(docker --version)）"
else
  log "安裝 Docker Engine..."
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
  ok "Docker 安裝完成"
fi

# ─────────────────────────────────────────────────────────────
# STEP 2：Clone / 更新原始碼
# ─────────────────────────────────────────────────────────────
log "取得 Wiki.js 原始碼..."
if [ -d "$SRC_DIR/.git" ]; then
  git -C "$SRC_DIR" pull --ff-only && ok "原始碼已更新"
else
  mkdir -p "$INSTALL_DIR"
  git clone "$REPO_URL" "$SRC_DIR"
  ok "原始碼 Clone 完成"
fi

# ─────────────────────────────────────────────────────────────
# STEP 3：Build Docker image
# ─────────────────────────────────────────────────────────────
log "Build Docker image（首次約需 5～15 分鐘）..."
docker build \
  -f "$SRC_DIR/dev/build/Dockerfile" \
  -t "${IMAGE_NAME}:latest" \
  "$SRC_DIR"
ok "Image build 完成：${IMAGE_NAME}:latest"

# ─────────────────────────────────────────────────────────────
# STEP 4：建立 docker-compose.yml（若已存在則保留 DB 密碼）
# ─────────────────────────────────────────────────────────────
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

if [ -f "$COMPOSE_FILE" ]; then
  # 保留舊密碼，避免資料庫無法連線
  EXISTING_PASS=$(grep "DB_PASS:" "$COMPOSE_FILE" | head -1 | sed 's/.*DB_PASS: *//')
  [ -n "$EXISTING_PASS" ] && DB_PASS="$EXISTING_PASS"
  warn "docker-compose.yml 已存在，保留現有資料庫密碼"
else
  log "建立 docker-compose.yml..."
fi

cat > "$COMPOSE_FILE" << COMPOSE
version: '3.8'

services:

  wiki:
    image: ${IMAGE_NAME}:latest
    container_name: wiki
    restart: unless-stopped
    environment:
      DB_TYPE: postgres
      DB_HOST: db
      DB_PORT: 5432
      DB_USER: ${DB_USER}
      DB_PASS: ${DB_PASS}
      DB_NAME: ${DB_NAME}
      DB_SSL: "false"
      SSL_ACTIVE: "false"
      HA_ACTIVE: "false"
      LOG_LEVEL: info
      LOG_FORMAT: default
    volumes:
      - wikijs-data:/wiki/data/content
    ports:
      - "${HOST_PORT}:3000"
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/healthz"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  db:
    image: postgres:17
    container_name: db
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 10

volumes:
  wikijs-data:
  postgres-data:
COMPOSE

ok "docker-compose.yml 建立完成"

# ─────────────────────────────────────────────────────────────
# STEP 5：啟動服務
# ─────────────────────────────────────────────────────────────
log "啟動 Wiki.js 及 PostgreSQL..."
cd "$INSTALL_DIR"
docker compose up -d
ok "容器已啟動"

# ─────────────────────────────────────────────────────────────
# STEP 6：建立 update.sh（日後更新用）
# ─────────────────────────────────────────────────────────────
cat > "$INSTALL_DIR/update.sh" << 'UPDATE'
#!/bin/bash
set -euo pipefail
echo "拉取最新原始碼..."
git -C /opt/wikijs/src pull --ff-only
echo "重新 Build image（約 5~15 分鐘）..."
docker build -f /opt/wikijs/src/dev/build/Dockerfile -t wikijs-custom:latest /opt/wikijs/src
echo "重啟 Wiki.js..."
cd /opt/wikijs && docker compose up -d --no-deps wiki
echo "更新完成！"
UPDATE
chmod +x "$INSTALL_DIR/update.sh"

# ─────────────────────────────────────────────────────────────
# 取得本機 IP
# ─────────────────────────────────────────────────────────────
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

# ─────────────────────────────────────────────────────────────
# 完成訊息
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║          部署完成！                       ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Wiki.js 網址${NC}   http://${SERVER_IP}:${HOST_PORT}"
echo -e "  ${BOLD}資料庫密碼${NC}     ${YELLOW}${DB_PASS}${NC}  ← 請妥善保存"
echo -e "  ${BOLD}設定目錄${NC}       ${INSTALL_DIR}"
echo -e "  ${BOLD}日後更新${NC}       sudo ${INSTALL_DIR}/update.sh"
echo ""
echo -e "  Wiki.js 首次啟動需約 ${YELLOW}30~60 秒${NC}，請稍後再開啟網址"
echo -e "  查看啟動進度：${BLUE}docker logs -f wiki${NC}"
echo ""
