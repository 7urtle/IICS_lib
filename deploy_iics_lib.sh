#!/usr/bin/env bash
# Usage:
#   sudo bash deploy_iics_lib.sh [/path/to/iics_lib_deploy.tar.gz]
# Optional:
#   APP_DIR=/opt/iics_lib APP_USER=iics PORT=8787 ADMIN_USER=admin
#   DOMAIN=lib.example.com EMAIL=you@example.com

set -euo pipefail

APP_DIR="${APP_DIR:-/opt/iics_lib}"
APP_USER="${APP_USER:-iics}"
DEFAULT_PORT="${PORT:-8787}"
ADMIN_USER="${ADMIN_USER:-admin}"
ENV_FILE="/etc/iics_lib.env"
SERVICE_FILE="/etc/systemd/system/iics_lib.service"
NGINX_SITE="/etc/nginx/sites-available/iics_lib"
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"

if [ -f /etc/iics_lib.domain ] && [ -z "$DOMAIN" ]; then
  DOMAIN="$(cat /etc/iics_lib.domain)"
fi
if [ -f /etc/iics_lib.email ] && [ -z "$EMAIL" ]; then
  EMAIL="$(cat /etc/iics_lib.email)"
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行：sudo bash $0" >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "本脚本仅支持 Debian / Ubuntu 系统。" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARBALL="${1:-$SCRIPT_DIR/iics_lib_deploy.tar.gz}"
if [ ! -f "$TARBALL" ]; then
  echo "找不到部署包：$TARBALL" >&2
  echo "请把 iics_lib_deploy.tar.gz 和本脚本放在同一目录，或把它作为第一个参数传入。" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
echo "==> 安装系统依赖"
apt-get update
apt-get install -y python3 python3-venv nginx curl

if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
  echo "需要 Python 3.10 或更高版本，当前版本：$(python3 -V 2>&1)" >&2
  exit 1
fi

echo "==> 解压应用"
install -d -m 0755 "$APP_DIR"
tar -xzf "$TARBALL" -C "$APP_DIR"

echo "==> 创建服务账号"
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
fi
if ! getent group "$APP_USER" >/dev/null 2>&1; then
  groupadd --system "$APP_USER"
fi
chown -R "$APP_USER:$APP_USER" "$APP_DIR"

if command -v runuser >/dev/null 2>&1; then
  RUN=(runuser -u "$APP_USER" --)
else
  RUN=(sudo -u "$APP_USER" --)
fi

echo "==> 安装 Python 依赖"
if [ ! -x "$APP_DIR/.venv/bin/python" ]; then
  "${RUN[@]}" python3 -m venv "$APP_DIR/.venv"
fi
"${RUN[@]}" "$APP_DIR/.venv/bin/pip" install --disable-pip-version-check -r "$APP_DIR/requirements.txt"

if [ -f "$ENV_FILE" ]; then
  PORT="$(sed -n 's/^IICS_PORT=//p' "$ENV_FILE" | tail -n 1)"
  PORT="${PORT:-$DEFAULT_PORT}"
  ADMIN_USER="$(sed -n 's/^IICS_ADMIN_USERNAME=//p' "$ENV_FILE" | tail -n 1)"
  ADMIN_USER="${ADMIN_USER:-admin}"
  COOKIE_SECURE="$(sed -n 's/^IICS_COOKIE_SECURE=//p' "$ENV_FILE" | tail -n 1)"
  COOKIE_SECURE="${COOKIE_SECURE:-0}"
else
  PORT="$DEFAULT_PORT"
  COOKIE_SECURE=0
  cat > "$ENV_FILE" <<EOF
IICS_HOST=127.0.0.1
IICS_PORT=$PORT
IICS_COOKIE_SECURE=0
IICS_ADMIN_USERNAME=$ADMIN_USER
IICS_TEXT_INDEXING=1
EOF
  chmod 600 "$ENV_FILE"
fi

echo "==> 写入 systemd 服务"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=IICS_lib paper library
After=network.target

[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$APP_DIR/.venv/bin/waitress-serve --listen=127.0.0.1:$PORT --threads=8 app:app
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable iics_lib >/dev/null
systemctl restart iics_lib

echo "==> 等待应用启动"
ready=0
for _ in $(seq 1 40); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/api/session" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "应用未能在 40 秒内启动，请查看：journalctl -u iics_lib -n 100" >&2
  exit 1
fi

echo "==> 设置管理员初始密码"
DB_FILE="$APP_DIR/instance/iics_lib.sqlite3"
STATUS="$("${RUN[@]}" env ADMIN_USER="$ADMIN_USER" DB_FILE="$DB_FILE" "$APP_DIR/.venv/bin/python" - <<'PY'
import os
import sqlite3

db = sqlite3.connect(os.environ["DB_FILE"])
row = db.execute(
    "SELECT password_hash FROM users WHERE username=? COLLATE NOCASE",
    (os.environ["ADMIN_USER"],),
).fetchone()
print("missing" if row is None else ("unset" if row[0] is None else "set"))
PY
)"

TEMP_PASSWORD=""
if [ "$STATUS" = "unset" ]; then
  TEMP_PASSWORD="$("${RUN[@]}" "$APP_DIR/.venv/bin/python" -c 'import secrets; print(secrets.token_urlsafe(12))')"
  "${RUN[@]}" env ADMIN_USER="$ADMIN_USER" ADMIN_PASS="$TEMP_PASSWORD" DB_FILE="$DB_FILE" "$APP_DIR/.venv/bin/python" - <<'PY'
import os
import sqlite3

from werkzeug.security import generate_password_hash

db = sqlite3.connect(os.environ["DB_FILE"])
db.execute(
    "UPDATE users SET password_hash=? WHERE username=? COLLATE NOCASE AND password_hash IS NULL",
    (generate_password_hash(os.environ["ADMIN_PASS"]), os.environ["ADMIN_USER"]),
)
db.commit()
PY
elif [ "$STATUS" = "missing" ]; then
  echo "警告：数据库里没有管理员 $ADMIN_USER，请检查 $ENV_FILE。" >&2
fi

echo "==> 配置 Nginx"
SERVER_NAME="${DOMAIN:-_}"
cat > "$NGINX_SITE" <<EOF
limit_req_zone \$binary_remote_addr zone=iics_auth:10m rate=10r/m;

server {
    listen 80;
    server_name $SERVER_NAME;

    client_max_body_size 110m;

    location /api/auth/ {
        limit_req zone=iics_auth burst=5 nodelay;
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }
}
EOF
ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/iics_lib
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl reload nginx || systemctl restart nginx

if [ -n "$DOMAIN" ]; then
  if [ -z "$EMAIL" ]; then
    echo "警告：提供了 DOMAIN 但没有 EMAIL，跳过 HTTPS 配置。" >&2
  else
    echo "==> 申请 HTTPS 证书"
    if apt-get install -y certbot python3-certbot-nginx && \
       certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect; then
      printf '%s\n' "$DOMAIN" > /etc/iics_lib.domain
      printf '%s\n' "$EMAIL" > /etc/iics_lib.email
      chmod 600 /etc/iics_lib.domain /etc/iics_lib.email
      sed -i 's/^IICS_COOKIE_SECURE=.*/IICS_COOKIE_SECURE=1/' "$ENV_FILE"
      grep -q '^IICS_COOKIE_SECURE=' "$ENV_FILE" || echo 'IICS_COOKIE_SECURE=1' >> "$ENV_FILE"
      COOKIE_SECURE=1
      systemctl restart iics_lib
    else
      echo "警告：HTTPS 配置失败，请确认 $DOMAIN 已解析到本机且 80 端口可访问；网站暂时使用 HTTP。" >&2
    fi
  fi
fi

if [ "$COOKIE_SECURE" = "1" ]; then
  PROTO="https"
else
  PROTO="http"
fi

PUBLIC_IP_HINT=""
if [ -n "$DOMAIN" ]; then
  WEB_HOST="$DOMAIN"
else
  WEB_HOST=""
  for ip_url in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip; do
    candidate="$(curl -fsS --max-time 4 "$ip_url" 2>/dev/null | tr -d '[:space:]' || true)"
    if printf '%s' "$candidate" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
      WEB_HOST="$candidate"
      break
    fi
  done
  if [ -z "$WEB_HOST" ]; then
    WEB_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
    WEB_HOST="${WEB_HOST:-服务器IP}"
    PUBLIC_IP_HINT=1
  fi
fi

cat <<EOF

============================================================
部署完成

  网站：$PROTO://$WEB_HOST/
  管理员：$ADMIN_USER
EOF

if [ -n "$PUBLIC_IP_HINT" ]; then
  echo "  注意：$WEB_HOST 可能是内网地址，公网访问请使用云控制台里的公网 IP 或绑定域名。"
fi

if [ -n "$TEMP_PASSWORD" ]; then
cat <<EOF
  临时密码：$TEMP_PASSWORD
  （登录后请立即在右上角用户菜单中修改）
EOF
else
cat <<EOF
  管理员密码：沿用数据库中已设置的密码
EOF
fi

cat <<EOF

后续：
  1. PDF 可以登录网页用“上传论文”上传；
     也可以 scp 到 $APP_DIR/存内计算/<会议或期刊>/<年份>/
     然后执行 systemctl restart iics_lib 触发扫描。
  2. 服务状态：systemctl status iics_lib
     服务日志：journalctl -u iics_lib -f
  3. 备份：$APP_DIR/instance 和 $APP_DIR/uploads，PDF 目录单独备份。
  4. 如启用 ufw，请放行 80/443：ufw allow 80/tcp && ufw allow 443/tcp
============================================================
EOF
