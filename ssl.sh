#!/bin/sh

# ============================================================
# Nginx SSL 懒人管理器
#
# 用法：
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/penggan00/ss/main/ssl.sh)" \
#   -e "penggan0@qq.com" \
#   -d "215155.xyz" \
#   -t "CF_API_TOKEN"
#
# 参数：
#   -e  邮箱，可选
#   -d  Cloudflare 主域名/Zone，例如 215155.xyz
#   -t  Cloudflare API Token，必填
#
# 支持：
#   Alpine Linux
#   Debian
#
# 功能：
#   1. 自动检测系统
#   2. 自动安装依赖
#   3. Nginx 安装/管理
#   4. acme.sh
#   5. Cloudflare DNS API
#   6. SSL 自动申请
#   7. SSL 自动续签
#   8. 子域名交互式管理
#   9. 静态网站
#  10. 反向代理
#  11. 删除站点
# ============================================================

set -u

# ------------------------------------------------------------
# 基础变量
# ------------------------------------------------------------

SCRIPT_NAME="nginx-ssl-manager"

BASE_DIR="/etc/${SCRIPT_NAME}"
CONFIG_FILE="${BASE_DIR}/config"
LOG_FILE="${BASE_DIR}/manager.log"
SITES_DIR="${BASE_DIR}/sites"
BACKUP_DIR="${BASE_DIR}/backup"

DOMAIN=""
EMAIL=""
CF_TOKEN=""

OS=""
PKG=""
SERVICE=""
ACME_HOME=""
NGINX_CONF=""
NGINX_AVAILABLE=""
NGINX_ENABLED=""
WEB_ROOT=""

# ------------------------------------------------------------
# 颜色
# ------------------------------------------------------------

RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
BLUE="$(printf '\033[34m')"
CYAN="$(printf '\033[36m')"
BOLD="$(printf '\033[1m')"
RESET="$(printf '\033[0m')"

# ------------------------------------------------------------
# 输出
# ------------------------------------------------------------

msg() {
    printf "%s\n" "$1"
}

ok() {
    printf "%s✓ %s%s\n" "$GREEN" "$1" "$RESET"
}

warn() {
    printf "%s⚠ %s%s\n" "$YELLOW" "$1" "$RESET"
}

err() {
    printf "%s✗ %s%s\n" "$RED" "$1" "$RESET"
}

info() {
    printf "%s→ %s%s\n" "$CYAN" "$1" "$RESET"
}

die() {
    err "$1"
    exit 1
}

pause() {
    printf "\n按 Enter 返回..."
    read dummy
}

# ------------------------------------------------------------
# 日志
# ------------------------------------------------------------

log() {
    mkdir -p "$BASE_DIR" 2>/dev/null || true
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# ------------------------------------------------------------
# Root 检查
# ------------------------------------------------------------

check_root() {
    if [ "$(id -u)" != "0" ]; then
        die "必须使用 root 权限运行。"
    fi
}

# ------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------

usage() {
    cat <<EOF

用法：

  bash -c "\$(curl -fsSL https://raw.githubusercontent.com/penggan00/ss/main/ssl.sh)" \\
    -e "邮箱" \\
    -d "主域名" \\
    -t "Cloudflare API Token"

参数：

  -e    邮箱，可选
  -d    主域名，例如 215155.xyz
  -t    Cloudflare API Token，必填
  -h    帮助

例如：

  bash -c "\$(curl -fsSL https://raw.githubusercontent.com/penggan00/ss/main/ssl.sh)" \\
    -e "penggan0@qq.com" \\
    -d "215155.xyz" \\
    -t "CF_API_TOKEN"

EOF
}

while getopts "e:d:t:h" opt; do
    case "$opt" in
        e) EMAIL="$OPTARG" ;;
        d) DOMAIN="$OPTARG" ;;
        t) CF_TOKEN="$OPTARG" ;;
        h)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------
# 参数检查
# ------------------------------------------------------------

[ -z "$DOMAIN" ] && die "缺少 -d 主域名。"

[ -z "$CF_TOKEN" ] && die "缺少 -t Cloudflare API Token。"

# 去掉末尾 /
DOMAIN="${DOMAIN%/}"

# 去掉可能的前导点
DOMAIN="${DOMAIN#.}"

# 简单域名格式检查
case "$DOMAIN" in
    *.*)
        ;;
    *)
        die "主域名格式不正确：$DOMAIN"
        ;;
esac

# ------------------------------------------------------------
# 检测系统
# ------------------------------------------------------------

detect_os() {

    if [ -f /etc/alpine-release ]; then

        OS="alpine"
        PKG="apk"
        SERVICE="openrc"

        NGINX_CONF="/etc/nginx/nginx.conf"
        NGINX_AVAILABLE="/etc/nginx/http.d"
        NGINX_ENABLED="/etc/nginx/http.d"

        WEB_ROOT="/var/www"

        ACME_HOME="/root/.acme.sh"

        ok "检测到 Alpine Linux $(cat /etc/alpine-release)"

    elif [ -f /etc/debian_version ]; then

        OS="debian"
        PKG="apt"
        SERVICE="systemd"

        NGINX_CONF="/etc/nginx/nginx.conf"
        NGINX_AVAILABLE="/etc/nginx/sites-available"
        NGINX_ENABLED="/etc/nginx/sites-enabled"

        WEB_ROOT="/var/www"

        ACME_HOME="/root/.acme.sh"

        ok "检测到 Debian"

    else

        die "暂不支持此系统。仅支持 Alpine Linux / Debian。"

    fi

    ARCH="$(uname -m)"

    ok "CPU 架构：$ARCH"
}

# ------------------------------------------------------------
# 初始化目录
# ------------------------------------------------------------

init_dirs() {

    mkdir -p "$BASE_DIR"
    mkdir -p "$SITES_DIR"
    mkdir -p "$BACKUP_DIR"

    chmod 700 "$BASE_DIR"

    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
}

# ------------------------------------------------------------
# 保存配置
# ------------------------------------------------------------

save_config() {

    umask 077

    cat > "$CONFIG_FILE" <<EOF
DOMAIN='$DOMAIN'
EMAIL='$EMAIL'
CF_TOKEN='$CF_TOKEN'
OS='$OS'
EOF

    chmod 600 "$CONFIG_FILE"
}

# ------------------------------------------------------------
# 加载配置
# ------------------------------------------------------------

load_config() {

    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
    fi

    [ -z "${DOMAIN:-}" ] && die "主域名配置不存在。"
    [ -z "${CF_TOKEN:-}" ] && die "Cloudflare Token 配置不存在。"
}

# ------------------------------------------------------------
# 安装基础依赖
# ------------------------------------------------------------

install_dependencies() {

    info "检查系统依赖..."

    if [ "$OS" = "alpine" ]; then

        apk update >/dev/null 2>&1 || die "apk update 失败。"

        for pkg in curl openssl ca-certificates bind-tools; do
            if ! apk info -e "$pkg" >/dev/null 2>&1; then
                info "安装 $pkg ..."
                apk add --no-cache "$pkg" >/dev/null 2>&1 || die "安装 $pkg 失败。"
            fi
        done

        ok "Alpine 基础依赖正常。"

    elif [ "$OS" = "debian" ]; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get update -qq >/dev/null 2>&1 || die "apt update 失败。"

        for pkg in curl openssl ca-certificates dnsutils; do
            if ! dpkg -s "$pkg" >/dev/null 2>&1; then
                info "安装 $pkg ..."
                apt-get install -y "$pkg" >/dev/null 2>&1 || die "安装 $pkg 失败。"
            fi
        done

        ok "Debian 基础依赖正常。"
    fi
}

# ------------------------------------------------------------
# 安装 Nginx
# ------------------------------------------------------------

install_nginx() {

    if command -v nginx >/dev/null 2>&1; then
        ok "Nginx 已安装。"
        return 0
    fi

    info "Nginx 未安装，正在安装..."

    if [ "$OS" = "alpine" ]; then

        apk add --no-cache nginx >/dev/null 2>&1 \
            || die "Nginx 安装失败。"

    elif [ "$OS" = "debian" ]; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get install -y nginx >/dev/null 2>&1 \
            || die "Nginx 安装失败。"
    fi

    ok "Nginx 安装完成。"
}

# ------------------------------------------------------------
# 启动 Nginx
# ------------------------------------------------------------

start_nginx() {

    if [ "$OS" = "alpine" ]; then

        rc-update add nginx default >/dev/null 2>&1 || true
        rc-service nginx start >/dev/null 2>&1 || true

    elif [ "$OS" = "debian" ]; then

        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl start nginx >/dev/null 2>&1 || true
    fi
}

# ------------------------------------------------------------
# Nginx reload
# ------------------------------------------------------------

reload_nginx() {

    if ! nginx -t >/dev/null 2>&1; then
        err "Nginx 配置检查失败，拒绝 reload。"
        nginx -t
        return 1
    fi

    if [ "$OS" = "alpine" ]; then
        rc-service nginx reload >/dev/null 2>&1 || nginx -s reload
    else
        systemctl reload nginx
    fi

    return 0
}

# ------------------------------------------------------------
# Nginx 配置检查
# ------------------------------------------------------------

nginx_test() {

    nginx -t

}

# ------------------------------------------------------------
# 安装 acme.sh
# ------------------------------------------------------------

install_acme() {

    if [ -x "$ACME_HOME/acme.sh" ]; then
        ok "acme.sh 已安装。"
        return 0
    fi

    info "正在安装 acme.sh..."

    export HOME="/root"

    if [ -n "$EMAIL" ]; then

        curl -fsSL https://get.acme.sh | sh -s "email=$EMAIL" \
            || die "acme.sh 安装失败。"

    else

        curl -fsSL https://get.acme.sh | sh \
            || die "acme.sh 安装失败。"

    fi

    if [ ! -x "$ACME_HOME/acme.sh" ]; then
        die "acme.sh 安装完成后未找到 $ACME_HOME/acme.sh"
    fi

    ok "acme.sh 安装完成。"
}

# ------------------------------------------------------------
# acme.sh 命令
# ------------------------------------------------------------

acme() {
    "$ACME_HOME/acme.sh" "$@"
}

# ------------------------------------------------------------
# 设置 Let's Encrypt
# ------------------------------------------------------------

setup_acme_ca() {

    if [ -n "$EMAIL" ]; then
        acme --register-account -m "$EMAIL" >/dev/null 2>&1 || true
    else
        acme --register-account >/dev/null 2>&1 || true
    fi

    acme --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
}

# ------------------------------------------------------------
# Cloudflare API 验证
# ------------------------------------------------------------

check_cloudflare() {

    info "验证 Cloudflare API Token..."

    VERIFY_RESULT="$(
        curl -fsS \
            -H "Authorization: Bearer $CF_TOKEN" \
            -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/user/tokens/verify" \
            2>/dev/null
    )"

    case "$VERIFY_RESULT" in
        *'"success":true'*)
            ok "Cloudflare API Token 有效。"
            ;;
        *)
            err "Cloudflare API Token 验证失败。"
            echo "$VERIFY_RESULT"
            die "请检查 -t Token。"
            ;;
    esac

    ZONE_RESULT="$(
        curl -fsS \
            -H "Authorization: Bearer $CF_TOKEN" \
            -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN&status=active&per_page=1" \
            2>/dev/null
    )"

    case "$ZONE_RESULT" in
        *'"success":true'*'"count":1'*)
            ok "Cloudflare Zone：$DOMAIN"
            ;;
        *)
            err "没有找到 Cloudflare Zone：$DOMAIN"
            echo "$ZONE_RESULT"
            die "请确认 -d 主域名正确，并确认 Token 有 Zone 权限。"
            ;;
    esac
}

# ------------------------------------------------------------
# 获取站点完整域名
# ------------------------------------------------------------

get_full_domain() {

    SUBDOMAIN="$1"

    if [ "$SUBDOMAIN" = "@" ]; then
        FULL_DOMAIN="$DOMAIN"
    else

        # 去掉用户误输入的末尾 .
        SUBDOMAIN="${SUBDOMAIN%.}"

        # 如果用户已经输入完整域名
        case "$SUBDOMAIN" in
            "$DOMAIN")
                FULL_DOMAIN="$DOMAIN"
                ;;
            *."$DOMAIN")
                FULL_DOMAIN="$SUBDOMAIN"
                ;;
            *)
                FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
                ;;
        esac

    fi
}

# ------------------------------------------------------------
# 检查域名是否合法
# ------------------------------------------------------------

validate_domain() {

    DOMAIN_TO_CHECK="$1"

    case "$DOMAIN_TO_CHECK" in
        *[!a-zA-Z0-9.-]*)
            return 1
            ;;
    esac

    case "$DOMAIN_TO_CHECK" in
        .*|*..*|*.)
            return 1
            ;;
    esac

    return 0
}

# ------------------------------------------------------------
# 检查站点是否存在
# ------------------------------------------------------------

site_file() {

    SITE_DOMAIN="$1"

    printf "%s/%s.conf" "$SITES_DIR" "$SITE_DOMAIN"
}

# ------------------------------------------------------------
# Nginx 文件位置
# ------------------------------------------------------------

nginx_site_file() {

    SITE_DOMAIN="$1"

    if [ "$OS" = "alpine" ]; then
        printf "%s/%s.conf" "$NGINX_AVAILABLE" "$SITE_DOMAIN"
    else
        printf "%s/%s.conf" "$NGINX_AVAILABLE" "$SITE_DOMAIN"
    fi
}

# ------------------------------------------------------------
# 证书路径
# ------------------------------------------------------------

CERT_DIR() {

    SITE_DOMAIN="$1"

    printf "%s/%s" "$BASE_DIR" "$SITE_DOMAIN"
}

# ------------------------------------------------------------
# 创建网站目录
# ------------------------------------------------------------

create_webroot() {

    SITE_DOMAIN="$1"

    mkdir -p "${WEB_ROOT}/${SITE_DOMAIN}"
    chmod 755 "${WEB_ROOT}/${SITE_DOMAIN}"

    if [ ! -f "${WEB_ROOT}/${SITE_DOMAIN}/index.html" ]; then

        cat > "${WEB_ROOT}/${SITE_DOMAIN}/index.html" <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>${SITE_DOMAIN}</title>
</head>
<body>
<h1>${SITE_DOMAIN}</h1>
<p>Nginx SSL Manager</p>
</body>
</html>
EOF

    fi
}

# ------------------------------------------------------------
# 创建 Nginx 静态站点
# ------------------------------------------------------------

create_static_nginx() {

    SITE_DOMAIN="$1"
    CONF_FILE="$(nginx_site_file "$SITE_DOMAIN")"
    SSL_DIR="$(CERT_DIR "$SITE_DOMAIN")"

    mkdir -p "$SSL_DIR"

    create_webroot "$SITE_DOMAIN"

    cat > "$CONF_FILE" <<EOF
# Managed by ${SCRIPT_NAME}
# Domain: ${SITE_DOMAIN}

server {
    listen 80;
    listen [::]:80;

    server_name ${SITE_DOMAIN};

    root ${WEB_ROOT}/${SITE_DOMAIN};
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name ${SITE_DOMAIN};

    root ${WEB_ROOT}/${SITE_DOMAIN};
    index index.html index.htm;

    ssl_certificate ${SSL_DIR}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

}

# ------------------------------------------------------------
# 创建反向代理 Nginx
# ------------------------------------------------------------

create_proxy_nginx() {

    SITE_DOMAIN="$1"
    BACKEND="$2"

    CONF_FILE="$(nginx_site_file "$SITE_DOMAIN")"
    SSL_DIR="$(CERT_DIR "$SITE_DOMAIN")"

    mkdir -p "$SSL_DIR"

    cat > "$CONF_FILE" <<EOF
# Managed by ${SCRIPT_NAME}
# Domain: ${SITE_DOMAIN}

server {
    listen 80;
    listen [::]:80;

    server_name ${SITE_DOMAIN};

    location / {
        proxy_pass ${BACKEND};

        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name ${SITE_DOMAIN};

    ssl_certificate ${SSL_DIR}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass ${BACKEND};

        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

}

# ------------------------------------------------------------
# Debian 启用站点
# ------------------------------------------------------------

enable_debian_site() {

    SITE_DOMAIN="$1"

    if [ "$OS" = "debian" ]; then

        CONF_FILE="$(nginx_site_file "$SITE_DOMAIN")"
        LINK="${NGINX_ENABLED}/${SITE_DOMAIN}.conf"

        if [ ! -L "$LINK" ]; then
            ln -sf "$CONF_FILE" "$LINK"
        fi

    fi
}

# ------------------------------------------------------------
# Alpine 删除站点不需要额外 link
# ------------------------------------------------------------

enable_site() {

    SITE_DOMAIN="$1"

    enable_debian_site "$SITE_DOMAIN"
}

# ------------------------------------------------------------
# 申请 SSL
# ------------------------------------------------------------

issue_certificate() {

    SITE_DOMAIN="$1"

    info "正在申请 SSL：$SITE_DOMAIN"

    export CF_Token="$CF_TOKEN"

    # DNS-01
    if acme \
        --issue \
        --dns dns_cf \
        -d "$SITE_DOMAIN" \
        --keylength ec-256
    then

        ok "SSL 申请成功：$SITE_DOMAIN"

    else

        err "SSL 申请失败：$SITE_DOMAIN"
        return 1
    fi

    return 0
}

# ------------------------------------------------------------
# 安装证书
# ------------------------------------------------------------

install_certificate() {

    SITE_DOMAIN="$1"

    SSL_DIR="$(CERT_DIR "$SITE_DOMAIN")"

    mkdir -p "$SSL_DIR"
    chmod 700 "$SSL_DIR"

    info "正在安装 SSL 证书..."

    RELOAD_CMD="nginx -t && nginx -s reload"

    if [ "$OS" = "alpine" ]; then
        RELOAD_CMD="nginx -t && rc-service nginx reload"
    elif [ "$OS" = "debian" ]; then
        RELOAD_CMD="nginx -t && systemctl reload nginx"
    fi

    if acme \
        --install-cert \
        -d "$SITE_DOMAIN" \
        --ecc \
        --key-file "$SSL_DIR/privkey.pem" \
        --fullchain-file "$SSL_DIR/fullchain.pem" \
        --reloadcmd "$RELOAD_CMD"
    then

        chmod 600 "$SSL_DIR/privkey.pem" 2>/dev/null || true
        chmod 644 "$SSL_DIR/fullchain.pem" 2>/dev/null || true

        ok "SSL 证书安装完成。"

    else

        err "SSL 证书安装失败。"
        return 1
    fi

    return 0
}

# ------------------------------------------------------------
# 新增站点
# ------------------------------------------------------------

add_site() {

    clear 2>/dev/null || true

    printf "%s\n" "========================================="
    printf "           新增 Nginx 站点\n"
    printf "%s\n" "========================================="

    printf "\n主域名：%s\n\n" "$DOMAIN"

    printf "请输入子域名：\n"
    printf "例如：rsshub\n"
    printf "主域名请输入：@\n\n"
    printf "子域名："

    read SUBDOMAIN

    [ -z "$SUBDOMAIN" ] && {
        warn "不能为空。"
        pause
        return
    }

    get_full_domain "$SUBDOMAIN"

    if ! validate_domain "$FULL_DOMAIN"; then
        err "域名格式错误：$FULL_DOMAIN"
        pause
        return
    fi

    SITE_CONF="$(nginx_site_file "$FULL_DOMAIN")"

    if [ -f "$SITE_CONF" ]; then
        warn "站点已经存在：$FULL_DOMAIN"
        pause
        return
    fi

    printf "\n"
    printf "完整域名：%s\n\n" "$FULL_DOMAIN"

    printf "请选择站点类型：\n\n"
    printf "1. 静态网站\n"
    printf "2. 反向代理\n"
    printf "3. 仅申请 SSL\n"
    printf "0. 返回\n\n"
    printf "请选择："

    read SITE_TYPE

    case "$SITE_TYPE" in

        1)

            create_static_nginx "$FULL_DOMAIN"
            enable_site "$FULL_DOMAIN"

            ;;

        2)

            printf "\n请输入后端地址：\n"
            printf "例如：http://127.0.0.1:3000\n\n"
            printf "后端："

            read BACKEND

            [ -z "$BACKEND" ] && {
                warn "后端地址不能为空。"
                pause
                return
            }

            create_proxy_nginx "$FULL_DOMAIN" "$BACKEND"
            enable_site "$FULL_DOMAIN"

            ;;

        3)

            # 仅 SSL 模式先创建一个临时 HTTP 配置
            CONF_FILE="$(nginx_site_file "$FULL_DOMAIN")"

            if [ "$OS" = "debian" ]; then
                mkdir -p "$NGINX_AVAILABLE"
            fi

            cat > "$CONF_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${FULL_DOMAIN};

    location / {
        return 200 "SSL Manager\n";
        add_header Content-Type text/plain;
    }
}
EOF

            enable_site "$FULL_DOMAIN"

            ;;

        0)
            return
            ;;

        *)
            warn "无效选择。"
            pause
            return
            ;;
    esac

    # --------------------------------------------------------
    # Nginx 临时检查
    # --------------------------------------------------------

    if ! nginx -t >/dev/null 2>&1; then

        err "Nginx 配置检查失败。"
        nginx -t

        rm -f "$SITE_CONF"

        if [ "$OS" = "debian" ]; then
            rm -f "${NGINX_ENABLED}/${FULL_DOMAIN}.conf"
        fi

        pause
        return
    fi

    reload_nginx || true

    # --------------------------------------------------------
    # SSL
    # --------------------------------------------------------

    printf "\n"

    if issue_certificate "$FULL_DOMAIN"; then

        if install_certificate "$FULL_DOMAIN"; then

            # 再次检查
            if nginx -t >/dev/null 2>&1; then

                reload_nginx >/dev/null 2>&1 || true

                ok "站点创建完成。"

                printf "\n"
                printf "=========================================\n"
                printf "域名：%s\n" "$FULL_DOMAIN"
                printf "HTTPS：https://%s\n" "$FULL_DOMAIN"
                printf "SSL：Let's Encrypt ECC\n"
                printf "续签：自动\n"
                printf "=========================================\n"

            else

                err "SSL 已申请，但 Nginx 配置检查失败。"
                nginx -t

            fi

        fi

    else

        warn "SSL 申请失败，保留站点配置。"
        warn "可以稍后从菜单重新申请 SSL。"
    fi

    # 记录站点
    {
        printf "DOMAIN='%s'\n" "$FULL_DOMAIN"
        printf "TYPE='%s'\n" "$SITE_TYPE"
    } > "$(site_file "$FULL_DOMAIN")"

    chmod 600 "$(site_file "$FULL_DOMAIN")"

    log "新增站点：$FULL_DOMAIN"

    pause
}

# ------------------------------------------------------------
# 获取站点列表
# ------------------------------------------------------------

list_sites() {

    clear 2>/dev/null || true

    printf "%s\n" "========================================="
    printf "             当前站点"
    printf "%s\n" "========================================="

    FOUND=0

    if [ -d "$SITES_DIR" ]; then

        for f in "$SITES_DIR"/*.conf; do

            [ -f "$f" ] || continue

            . "$f"

            FOUND=$((FOUND + 1))

            printf "\n%d. %s\n" "$FOUND" "$DOMAIN"

            if [ "${TYPE:-}" = "1" ]; then
                printf "   类型：静态网站\n"
            elif [ "${TYPE:-}" = "2" ]; then
                printf "   类型：反向代理\n"
            else
                printf "   类型：SSL\n"
            fi

            if [ -f "$(CERT_DIR "$DOMAIN")/fullchain.pem" ]; then
                printf "   SSL：✓\n"
            else
                printf "   SSL：✗\n"
            fi

        done

    fi

    if [ "$FOUND" -eq 0 ]; then
        printf "\n暂无站点。\n"
    fi

    printf "\n"

    pause
}

# ------------------------------------------------------------
# 删除站点
# ------------------------------------------------------------

delete_site() {

    clear 2>/dev/null || true

    printf "%s\n" "========================================="
    printf "             删除站点"
    printf "%s\n" "========================================="

    printf "\n当前站点：\n\n"

    INDEX=0
    DOMAINS_FILE="${BASE_DIR}/.delete_list"

    : > "$DOMAINS_FILE"

    for f in "$SITES_DIR"/*.conf; do

        [ -f "$f" ] || continue

        . "$f"

        INDEX=$((INDEX + 1))

        printf "%d. %s\n" "$INDEX" "$DOMAIN"

        printf "%s\n" "$DOMAIN" >> "$DOMAINS_FILE"

    done

    if [ "$INDEX" -eq 0 ]; then
        printf "\n暂无站点。\n"
        rm -f "$DOMAINS_FILE"
        pause
        return
    fi

    printf "\n0. 返回\n\n"
    printf "请选择："

    read SELECT

    [ "$SELECT" = "0" ] && {
        rm -f "$DOMAINS_FILE"
        return
    }

    TARGET="$(sed -n "${SELECT}p" "$DOMAINS_FILE" 2>/dev/null)"

    rm -f "$DOMAINS_FILE"

    [ -z "$TARGET" ] && {
        warn "选择无效。"
        pause
        return
    }

    printf "\n即将删除：\n\n"
    printf "域名：%s\n" "$TARGET"
    printf "Nginx：✓\n"
    printf "SSL：可能存在\n"
    printf "网站目录：可能存在\n\n"

    printf "如果确定删除，请输入：DELETE\n"
    printf "确认："

    read CONFIRM

    [ "$CONFIRM" != "DELETE" ] && {
        warn "已取消。"
        pause
        return
    }

    # --------------------------------------------------------
    # 备份配置
    # --------------------------------------------------------

    BACKUP_NAME="${BACKUP_DIR}/${TARGET}-$(date '+%Y%m%d-%H%M%S')"

    mkdir -p "$BACKUP_NAME"

    CONF_FILE="$(nginx_site_file "$TARGET")"

    [ -f "$CONF_FILE" ] && cp "$CONF_FILE" "$BACKUP_NAME/" 2>/dev/null || true
    [ -f "$(site_file "$TARGET")" ] && cp "$(site_file "$TARGET")" "$BACKUP_NAME/" 2>/dev/null || true

    # --------------------------------------------------------
    # 删除 Nginx 配置
    # --------------------------------------------------------

    rm -f "$CONF_FILE"

    if [ "$OS" = "debian" ]; then
        rm -f "${NGINX_ENABLED}/${TARGET}.conf"
    fi

    # --------------------------------------------------------
    # 删除项目记录
    # --------------------------------------------------------

    rm -f "$(site_file "$TARGET")"

    # --------------------------------------------------------
    # 删除证书
    # --------------------------------------------------------

    rm -rf "$(CERT_DIR "$TARGET")"

    # --------------------------------------------------------
    # 删除网站目录
    # --------------------------------------------------------

    if [ -d "${WEB_ROOT}/${TARGET}" ]; then

        printf "\n网站目录：%s\n" "${WEB_ROOT}/${TARGET}"
        printf "是否删除网站文件？[y/N]："

        read DELETE_WEB

        case "$DELETE_WEB" in
            y|Y)
                rm -rf "${WEB_ROOT}/${TARGET}"
                ok "网站目录已删除。"
                ;;
            *)
                ok "网站文件已保留。"
                ;;
        esac
    fi

    # --------------------------------------------------------
    # 从 acme.sh 删除证书
    # --------------------------------------------------------

    acme --remove -d "$TARGET" --ecc >/dev/null 2>&1 || true

    reload_nginx >/dev/null 2>&1 || true

    ok "站点删除完成。"

    log "删除站点：$TARGET"

    pause
}

# ------------------------------------------------------------
# SSL 列表
# ------------------------------------------------------------

list_ssl() {

    clear 2>/dev/null || true

    printf "%s\n" "========================================="
    printf "             SSL 证书"
    printf "%s\n" "========================================="

    FOUND=0

    for f in "$SITES_DIR"/*.conf; do

        [ -f "$f" ] || continue

        . "$f"

        FOUND=$((FOUND + 1))

        CERT="$(CERT_DIR "$DOMAIN")/fullchain.pem"

        printf "\n%s\n" "$DOMAIN"

        if [ -f "$CERT" ]; then

            printf "  状态：✓ 已安装\n"

            if command -v openssl >/dev/null 2>&1; then

                EXPIRY="$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"

                printf "  到期：%s\n" "$EXPIRY"

            fi

        else

            printf "  状态：✗ 未安装\n"
        fi

    done

    [ "$FOUND" -eq 0 ] && printf "\n暂无证书。\n"

    printf "\n"

    pause
}

# ------------------------------------------------------------
# 选择站点
# ------------------------------------------------------------

select_site() {

    INDEX=0
    SELECT_FILE="${BASE_DIR}/.select_list"

    : > "$SELECT_FILE"

    for f in "$SITES_DIR"/*.conf; do

        [ -f "$f" ] || continue

        . "$f"

        INDEX=$((INDEX + 1))

        printf "%d. %s\n" "$INDEX" "$DOMAIN"
        printf "%s\n" "$DOMAIN" >> "$SELECT_FILE"

    done

    if [ "$INDEX" -eq 0 ]; then
        rm -f "$SELECT_FILE"
        return 1
    fi

    printf "\n0. 返回\n\n"
    printf "请选择："

    read SELECT

    if [ "$SELECT" = "0" ]; then
        rm -f "$SELECT_FILE"
        return 1
    fi

    TARGET="$(sed -n "${SELECT}p" "$SELECT_FILE" 2>/dev/null)"

    rm -f "$SELECT_FILE"

    [ -z "$TARGET" ] && return 1

    return 0
}

# ------------------------------------------------------------
# 单独续签/重新申请
# ------------------------------------------------------------

renew_one() {

    clear 2>/dev/null || true

    printf "%s\n" "========================================="
    printf "             SSL 续签"
    printf "%s\n" "========================================="

    printf "\n"

    if ! select_site; then
        warn "没有站点。"
        pause
        return
    fi

    printf "\n目标：%s\n\n" "$TARGET"

    if issue_certificate "$TARGET"; then

        if install_certificate "$TARGET"; then

            reload_nginx >/dev/null 2>&1 || true

            ok "SSL 处理完成。"

        fi

    fi

    pause
}

# ------------------------------------------------------------
# 全部续签
# ------------------------------------------------------------

renew_all() {

    clear 2>/dev/null || true

    printf "%s\n" "========================================="
    printf "             全部 SSL 续签"
    printf "%s\n" "========================================="

    COUNT=0

    for f in "$SITES_DIR"/*.conf; do

        [ -f "$f" ] || continue

        . "$f"

        COUNT=$((COUNT + 1))

        printf "\n-----------------------------------------\n"
        printf "处理：%s\n" "$DOMAIN"
        printf "-----------------------------------------\n"

        if issue_certificate "$DOMAIN"; then
            install_certificate "$DOMAIN" || true
        fi

    done

    if [ "$COUNT" -eq 0 ]; then
        warn "没有站点。"
    else
        reload_nginx >/dev/null 2>&1 || true
        ok "全部处理完成。"
    fi

    pause
}

# ------------------------------------------------------------
# Nginx 配置检查
# ------------------------------------------------------------

check_nginx_menu() {

    clear 2>/dev/null || true

    printf "%s\n" "========================================="
    printf "          Nginx 配置检查"
    printf "%s\n" "========================================="

    printf "\n"

    nginx -t

    printf "\n"

    pause
}

# ------------------------------------------------------------
# Nginx reload
# ------------------------------------------------------------

reload_nginx_menu() {

    clear 2>/dev/null || true

    printf "%s\n" "========================================="
    printf "             Nginx Reload"
    printf "%s\n" "========================================="

    printf "\n"

    if reload_nginx; then
        ok "Nginx reload 成功。"
    else
        err "Nginx reload 失败。"
    fi

    printf "\n"

    pause
}

# ------------------------------------------------------------
# 查看日志
# ------------------------------------------------------------

show_log() {

    clear 2>/dev/null || true

    printf "%s\n" "========================================="
    printf "             管理器日志"
    printf "%s\n" "========================================="

    printf "\n"

    if [ -f "$LOG_FILE" ]; then
        tail -n 100 "$LOG_FILE"
    else
        printf "暂无日志。\n"
    fi

    printf "\n"

    pause
}

# ------------------------------------------------------------
# 系统状态
# ------------------------------------------------------------

system_status() {

    clear 2>/dev/null || true

    printf "%s\n" "========================================="
    printf "             系统状态"
    printf "%s\n" "========================================="

    printf "\n"

    printf "系统："
    if [ "$OS" = "alpine" ]; then
        printf "Alpine Linux %s\n" "$(cat /etc/alpine-release)"
    else
        printf "Debian\n"
    fi

    printf "架构：%s\n" "$(uname -m)"
    printf "内核：%s\n" "$(uname -r)"

    printf "\n"

    printf "主域名：%s\n" "$DOMAIN"

    if [ -n "$EMAIL" ]; then
        printf "邮箱：%s\n" "$EMAIL"
    else
        printf "邮箱：未设置\n"
    fi

    printf "\n"

    printf "Nginx："
    nginx -v 2>&1

    printf "acme.sh："
    if [ -x "$ACME_HOME/acme.sh" ]; then
        acme --version 2>/dev/null | head -n 1
    else
        printf "未安装\n"
    fi

    printf "\nIPv6：\n"

    if command -v ip >/dev/null 2>&1; then
        ip -6 addr show scope global 2>/dev/null | grep 'inet6 ' | head -n 5 || true
    fi

    printf "\n磁盘：\n"
    df -h / | tail -n 1

    printf "\n内存：\n"

    if command -v free >/dev/null 2>&1; then
        free -h
    else
        if [ -f /proc/meminfo ]; then
            grep -E 'MemTotal|MemAvailable' /proc/meminfo
        fi
    fi

    printf "\n"

    pause
}

# ------------------------------------------------------------
# 依赖检查
# ------------------------------------------------------------

dependency_check() {

    clear 2>/dev/null || true

    printf "%s\n" "========================================="
    printf "             依赖检查"
    printf "%s\n" "========================================="

    printf "\n"

    for cmd in curl openssl nginx; do

        if command -v "$cmd" >/dev/null 2>&1; then
            ok "$cmd"
        else
            err "$cmd"
        fi

    done

    if [ -x "$ACME_HOME/acme.sh" ]; then
        ok "acme.sh"
    else
        err "acme.sh"
    fi

    printf "\n"

    pause
}

# ------------------------------------------------------------
# Cloudflare 设置
# ------------------------------------------------------------

cloudflare_info() {

    clear 2>/dev/null || true

    printf "%s\n" "========================================="
    printf "           Cloudflare 设置"
    printf "%s\n" "========================================="

    printf "\n"

    printf "主域名：%s\n" "$DOMAIN"

    if [ -n "$CF_TOKEN" ]; then
        printf "API Token：已设置\n"
    else
        printf "API Token：未设置\n"
    fi

    if [ -n "$EMAIL" ]; then
        printf "邮箱：%s\n" "$EMAIL"
    else
        printf "邮箱：未设置\n"
    fi

    printf "\n"

    check_cloudflare

    printf "\n"

    pause
}

# ------------------------------------------------------------
# 主菜单
# ------------------------------------------------------------

menu() {

    while true; do

        clear 2>/dev/null || true

        printf "%s\n" "╔════════════════════════════════════════╗"
        printf "%s\n" "║       Nginx SSL 懒人管理器            ║"
        printf "%s\n" "╠════════════════════════════════════════╣"
        printf "║ 系统：%-31s ║\n" "$OS"
        printf "║ 主域名：%-29s ║\n" "$DOMAIN"

        if [ -n "$EMAIL" ]; then
            printf "║ 邮箱：%-31s ║\n" "$EMAIL"
        else
            printf "║ 邮箱：%-31s ║\n" "未设置"
        fi

        printf "║ Cloudflare：%-25s ║\n" "✓"
        printf "║ Nginx：%-30s ║\n" "✓"
        printf "║ SSL：%-31s ║\n" "Let's Encrypt"
        printf "%s\n" "╠════════════════════════════════════════╣"
        printf "%s\n" "║                                        ║"
        printf "%s\n" "║  1. 新增站点                           ║"
        printf "%s\n" "║  2. 删除站点                           ║"
        printf "%s\n" "║  3. 查看站点                           ║"
        printf "%s\n" "║  4. SSL证书列表                        ║"
        printf "%s\n" "║  5. 续签指定证书                       ║"
        printf "%s\n" "║  6. 全部续签                           ║"
        printf "%s\n" "║  7. Nginx配置检查                      ║"
        printf "%s\n" "║  8. Nginx重新加载                      ║"
        printf "%s\n" "║  9. 查看日志                           ║"
        printf "%s\n" "║ 10. 检查依赖                           ║"
        printf "%s\n" "║ 11. Cloudflare状态                     ║"
        printf "%s\n" "║ 12. 系统状态                           ║"
        printf "%s\n" "║                                        ║"
        printf "%s\n" "║  0. 退出                               ║"
        printf "%s\n" "║                                        ║"
        printf "%s\n" "╚════════════════════════════════════════╝"

        printf "\n请选择："

        read CHOICE

        case "$CHOICE" in

            1)
                add_site
                ;;

            2)
                delete_site
                ;;

            3)
                list_sites
                ;;

            4)
                list_ssl
                ;;

            5)
                renew_one
                ;;

            6)
                renew_all
                ;;

            7)
                check_nginx_menu
                ;;

            8)
                reload_nginx_menu
                ;;

            9)
                show_log
                ;;

            10)
                dependency_check
                ;;

            11)
                cloudflare_info
                ;;

            12)
                system_status
                ;;

            0)
                printf "\n退出。\n"
                exit 0
                ;;

            *)
                warn "无效选择。"
                sleep 1
                ;;
        esac

    done
}

# ------------------------------------------------------------
# 初始化
# ------------------------------------------------------------

main() {

    check_root

    detect_os

    init_dirs

    install_dependencies

    install_nginx

    start_nginx

    install_acme

    setup_acme_ca

    save_config

    check_cloudflare

    # 确保 Nginx 基础配置正常
    if ! nginx -t >/dev/null 2>&1; then
        err "当前 Nginx 配置存在问题："
        nginx -t
        exit 1
    fi

    reload_nginx >/dev/null 2>&1 || true

    log "Nginx SSL Manager 启动"

    menu
}

main "$@"