# Wiki.js — 自訂部署版

> 基於 [Requarks/wiki](https://github.com/Requarks/wiki) fork，加入**剪貼簿圖片直接貼上**功能。  
> 包含一鍵部署、備份、還原、更新腳本，適用於 Ubuntu 22.04 / 24.04 + Docker 環境。

---

## 自訂功能

- **剪貼簿圖片貼上**：在 Markdown 編輯器與 CKEditor 中，截圖後直接 Ctrl+V，圖片自動上傳並插入

---

## 快速開始

### 一鍵部署（全新 Ubuntu 主機）

```bash
curl -fsSL https://raw.githubusercontent.com/oupaul/wiki/main/deploy.sh | sudo bash
```

**腳本自動完成：**
- 安裝 Docker Engine + Docker Compose
- Clone 本 repo 並 Build 自訂 image
- 建立 PostgreSQL 17 資料庫
- 啟動 Wiki.js（port 80）

**完成後輸出：**
```
Wiki.js 網址   http://YOUR_IP
資料庫密碼     xxxxxxxxxxxxxxxxxx  ← 請妥善保存
設定目錄       /opt/wikijs
日後更新       sudo /opt/wikijs/update.sh
```

> 首次啟動需 30～60 秒，`docker logs -f wiki` 查看進度。

---

## 維運操作

### 備份（在來源主機執行）

```bash
curl -fsSL https://raw.githubusercontent.com/oupaul/wiki/main/migrate-export.sh | sudo bash
```

產生 `/tmp/wikijs-backup-YYYYMMDD-HHMMSS.tar.gz`，包含：
- PostgreSQL 完整資料庫（頁面、使用者、設定）
- 所有上傳的媒體檔案

---

### 還原（在目標主機執行）

```bash
# 1. 將備份檔傳到新主機
scp root@OLD_IP:/tmp/wikijs-backup-*.tar.gz /tmp/

# 2. 下載並執行還原腳本
curl -fsSL https://raw.githubusercontent.com/oupaul/wiki/main/migrate-import.sh -o /tmp/migrate-import.sh
sudo bash /tmp/migrate-import.sh /tmp/wikijs-backup-YYYYMMDD-HHMMSS.tar.gz
```

> 還原前請確認目標主機已完成一鍵部署。還原後至 Admin → General 確認網站 URL。

---

### 更新

```bash
sudo /opt/wikijs/update.sh
```

自動執行：`git pull` → Build image → 重啟 wiki 容器（資料庫不受影響）

---

## 部署後的目錄結構

```
/opt/wikijs/
  ├── docker-compose.yml   # 服務設定（含 DB 密碼）
  ├── src/                 # Wiki.js 原始碼（git clone）
  └── update.sh            # 日後更新腳本
```

---

## 常用管理指令

| 操作 | 指令 |
|---|---|
| 查看容器狀態 | `docker ps` |
| 查看即時 log | `docker logs -f wiki` |
| 重啟 Wiki.js | `cd /opt/wikijs && docker compose restart wiki` |
| 停止全部服務 | `cd /opt/wikijs && docker compose down` |
| 啟動全部服務 | `cd /opt/wikijs && docker compose up -d` |
| 進入資料庫 CLI | `docker exec -it db psql -U wikijs -d wiki` |

---

## 技術規格

| 項目 | 版本 |
|---|---|
| Node.js | 24 (Alpine) |
| PostgreSQL | 17 |
| 授權 | AGPL-3.0 |
| 上游專案 | [Requarks/wiki](https://github.com/Requarks/wiki) |

---

## 維運手冊

完整操作文件（含指令複製按鈕）：[docs-ops.html](./docs-ops.html)

```bash
# 下載到本機
curl -O https://raw.githubusercontent.com/oupaul/wiki/main/docs-ops.html
```
