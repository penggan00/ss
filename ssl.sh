#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
用法：
  bash ssl.sh -e EMAIL -d BASE_DOMAIN -t CLOUDFLARE_API_TOKEN

示例：
  bash ssl.sh -e admin@example.com -d example.com -t 'CloudflareToken'

运行时会询问子域名和本地应用端口。
USAGE
}

EMAIL=""
BASE_DOMAIN=""
CF_API_TOKEN=""

while getopts ":e:d:t:h" opt; do
  case "$opt" in
    e) EMAIL="$OPTARG" ;;
    d) BASE_DOMAIN="$OPTARG" ;;
    t) CF_API_TOKEN="$OPTARG" ;;
    h) usage; exit 0 ;;
    :)
      echo "参数 -$OPTARG 缺少值。" >&2
      usage >&2
      exit 2
      ;;
    \?)
      echo "未知参数：-$OPTARG" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "请以 root 运行，例如：sudo bash ssl.sh ..." >&2
  exit 1
fi

if [[ -z "$EMAIL" || -z "$BASE_DOMAIN" || -z "$CF_API_TOKEN" ]]; then
  usage >&2
  exit 2
fi

if [[ ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  echo "邮箱格式不正确。" >&2
  exit 1
fi

BASE_DOMAIN="${BASE_DOMAIN,,}"
BASE_DOMAIN="${BASE_DOMAIN%.}"

if [[ ! "$BASE_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
  echo "主域名格式不正确：$BASE_DOMAIN" >&2
  exit 1
fi

if [[ "$CF_API_TOKEN" == *$'\n'* || "$CF_API_TOKEN" == *$'\r'* ]]; then
  echo "Cloudflare Token 格式不正确。" >&2
  exit 1
fi

read -r -p "子域名（例如 rss；不需要输入 .$BASE_DOMAIN）: " SUBDOMAIN
SUBDOMAIN="${SUBDOMAIN,,}"

if [[ ! "$SUBDOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "子域名格式不正确；请输入单个标签，例如 rss 或 app。" >&2
  exit 1
fi

DOMAIN="$SUBDOMAIN.$BASE_DOMAIN"

read -r -p "本地应用端口（例如 12004）: " APP_PORT
if [[ ! "$APP_PORT" =~ ^[0-9]+$ ]] || (( APP_PORT < 1 || APP_PORT > 65535 )); then
  echo "端口必须是 1–65535 之间的数字。" >&2
  exit 1
fi

SITE_AVAILABLE="/etc/nginx/sites-available/$DOMAIN.conf"
SITE_ENABLED="/etc/nginx/sites-enabled/$DOMAIN.conf"
DEFAULT_AVAILABLE="/etc/nginx/sites-available/00-reject-unknown.conf"
DEFAULT_ENABLED="/etc/nginx/sites-enabled/00-reject-unknown.conf"
CF_CREDENTIAL_DIR="/root/.secrets/certbot"
CF_CREDENTIAL="$CF_CREDENTIAL_DIR/cloudflare.ini"
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"

echo
echo "准备部署："
echo "  域名：$DOMAIN"
echo "  反代：http://127.0.0.1:$APP_PORT"
echo

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx certbot python3-certbot-dns-cloudflare

# Cloudflare 凭据仅 root 可读；Certbot 自动续签会继续使用此文件。
install -d -m 700 "$CF_CREDENTIAL_DIR"
umask 077
printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" > "$CF_CREDENTIAL"
chmod 600 "$CF_CREDENTIAL"
unset CF_API_TOKEN

# 已有证书则保留；没有才申请新证书。
if [[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" ]]; then
  echo "检测到现有证书，跳过申请：$DOMAIN"
else
  certbot certonly \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" \
    --authenticator dns-cloudflare \
    --dns-cloudflare-credentials "$CF_CREDENTIAL" \
    --dns-cloudflare-propagation-seconds 30 \
    --domain "$DOMAIN"
fi

if [[ ! -s "$CERT_DIR/fullchain.pem" || ! -s "$CERT_DIR/privkey.pem" ]]; then
  echo "证书文件不存在，停止配置。" >&2
  exit 1
fi

# 备份同名站点配置，方便回滚。
if [[ -f "$SITE_AVAILABLE" ]]; then
  BACKUP="$SITE_AVAILABLE.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$SITE_AVAILABLE" "$BACKUP"
  echo "已备份旧站点配置：$BACKUP"
fi

# 移除 Debian 默认站点链接，避免它占用 default_server。
if [[ -L /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
fi

# 未知域名/IP 的 HTTP 请求关闭连接；未知 HTTPS SNI 在握手阶段拒绝。
cat > "$DEFAULT_AVAILABLE" <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
NGINX

ln -sfn "$DEFAULT_AVAILABLE" "$DEFAULT_ENABLED"

# 配置 HTTP 跳转和 HTTPS 反代。
cat > "$SITE_AVAILABLE" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    client_max_body_size 100m;
    client_body_timeout 300s;
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket 支持
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # 上传和流式响应
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;

        proxy_connect_timeout 10s;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINX

ln -sfn "$SITE_AVAILABLE" "$SITE_ENABLED"

# 证书续签成功后检查配置并自动重载 Nginx。
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx <<'HOOK'
#!/bin/sh
/usr/sbin/nginx -t && /bin/systemctl reload nginx
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx

nginx -t
systemctl enable --now nginx
systemctl reload nginx

# Debian Certbot 定时器会定期检查并续签证书。
if systemctl list-unit-files certbot.timer --no-legend 2>/dev/null | grep -q certbot.timer; then
  systemctl enable --now certbot.timer
fi

echo
echo "测试自动续签流程……"
if certbot renew --dry-run; then
  echo "续签演练成功。"
else
  echo "警告：续签演练失败，请检查 Certbot 输出；站点配置已经完成。" >&2
fi

echo
echo "部署完成： https://$DOMAIN"
echo "反代目标： http://127.0.0.1:$APP_PORT"
echo "证书凭据： $CF_CREDENTIAL"
echo "自动续签： certbot.timer"
echo
echo "提示：应用需要正在监听 127.0.0.1:$APP_PORT。"
echo "注意：Nginx 默认站点规则会拒绝普通 IP/未知域名请求；要防止绕过 Cloudflare 直接访问源站，还需用防火墙限制 80/443 入站来源。"