#!/bin/sh

# ============================================================
# Nginx SSL 懒人管理器
#
# 直接运行：
#
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/penggan00/ss/main/ssl.sh)" \
# -e "penggan0@qq.com" \
# -d "215155.xyz" \
# -t "CF_API_TOKEN"
#
# -e 邮箱，可选
# -d Cloudflare 主域名
# -t Cloudflare API Token
#
# Alpine / Debian
# Cloudflare DNS-01
# Let's Encrypt
# Nginx reverse proxy
# 自动续签
# ============================================================

set -u

VERSION="2.0.0"
NAME="nginx-ssl-manager"

BASE_DIR="/etc/nginx-ssl-manager"
CONFIG_FILE="${BASE_DIR}/config"
LOG_FILE="${BASE_DIR}/manager.log"
SITES_DIR="${BASE_DIR}/sites"
BACKUP_DIR="${BASE_DIR}/backup"

DOMAIN=""
EMAIL=""
CF_TOKEN=""

OS=""
ARCH=""
ACME_HOME="/root/.acme.sh"

WEB_ROOT="/var/www"

NGINX_AVAILABLE=""
NGINX_ENABLED=""

GREEN="$(printf '\033[32m')"
RED="$(printf '\033[31m')"
YELLOW="$(printf '\033[33m')"
CYAN="$(printf '\033[36m')"
RESET="$(printf '\033[0m')"

# ============================================================
# 输出
# ============================================================

ok() {
    printf "%s✓ %s%s\n" "$GREEN" "$1" "$RESET"
}

info() {
    printf "%s→ %s%s\n" "$CYAN" "$1" "$RESET"
}

warn() {
    printf "%s⚠ %s%s\n" "$YELLOW" "$1" "$RESET"
}

err() {
    printf "%s✗ %s%s\n" "$RED" "$1" "$RESET"
}

die() {
    err "$1"
    exit 1
}

pause() {
    printf "\n按 Enter 返回..."
    read dummy
}

log() {
    mkdir -p "$BASE_DIR" 2>/dev/null || true
    printf '[%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# ============================================================
# Root
# ============================================================

check_root() {

    if [ "$(id -u)" != "0" ]; then
        die "必须使用 root 权限运行。"
    fi
}

# ============================================================
# 兼容：
#
# bash -c "script" -e email -d domain -t token
#
# bash -c 的第一个参数实际上会成为 $0
# 所以这里把 $0 重新放回参数列表。
# ============================================================

if [ "${0:-}" = "-e" ]; then
    set -- "$0" "$@"
fi

# ============================================================
# 参数
# ============================================================

while getopts "e:d:t:h" opt; do

    case "$opt" in

        e)
            EMAIL="$OPTARG"
            ;;

        d)
            DOMAIN="$OPTARG"
            ;;

        t)
            CF_TOKEN="$OPTARG"
            ;;

        h)
            cat <<EOF

Nginx SSL Manager ${VERSION}

用法：

bash -c "\$(curl -fsSL https://raw.githubusercontent.com/penggan00/ss/main/ssl.sh)" \\
-e "penggan0@qq.com" \\
-d "215155.xyz" \\
-t "CF_API_TOKEN"

参数：

-e    邮箱，可选
-d    Cloudflare 主域名
-t    Cloudflare API Token

EOF
            exit 0
            ;;

        *)
            exit 1
            ;;

    esac

done

# ============================================================
# 参数检查
# ============================================================

[ -z "$DOMAIN" ] && die "缺少 -d 主域名。"
[ -z "$CF_TOKEN" ] && die "缺少 -t Cloudflare API Token。"

DOMAIN="${DOMAIN%/}"
DOMAIN="${DOMAIN#.}"

case "$DOMAIN" in
    *.*)
        ;;
    *)
        die "主域名格式不正确：$DOMAIN"
        ;;
esac

# ============================================================
# 检测系统
# ============================================================

detect_os() {

    ARCH="$(uname -m)"

    if [ -f /etc/alpine-release ]; then

        OS="alpine"

        NGINX_AVAILABLE="/etc/nginx/http.d"
        NGINX_ENABLED="/etc/nginx/http.d"

        ok "检测到 Alpine Linux $(cat /etc/alpine-release)"

    elif [ -f /etc/debian_version ]; then

        OS="debian"

        NGINX_AVAILABLE="/etc/nginx/sites-available"
        NGINX_ENABLED="/etc/nginx/sites-enabled"

        ok "检测到 Debian"

    else

        die "暂不支持此系统，仅支持 Alpine Linux / Debian。"

    fi

    ok "CPU 架构：$ARCH"
}

# ============================================================
# 初始化目录
# ============================================================

init_dirs() {

    mkdir -p "$BASE_DIR"
    mkdir -p "$SITES_DIR"
    mkdir -p "$BACKUP_DIR"

    touch "$LOG_FILE"

    chmod 700 "$BASE_DIR"
    chmod 600 "$LOG_FILE"
}

# ============================================================
# 保存配置
# ============================================================

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

# ============================================================
# 加载配置
# ============================================================

load_config() {

    if [ ! -f "$CONFIG_FILE" ]; then
        die "配置文件不存在。"
    fi

    . "$CONFIG_FILE"
}

# ============================================================
# 系统依赖
# ============================================================

install_dependencies() {

    info "检查系统依赖..."

    if [ "$OS" = "alpine" ]; then

        apk update >/dev/null 2>&1 \
            || die "apk update 失败。"

        for pkg in curl openssl ca-certificates bind-tools; do

            if ! apk info -e "$pkg" >/dev/null 2>&1; then

                info "安装 $pkg ..."

                apk add --no-cache "$pkg" >/dev/null 2>&1 \
                    || die "安装 $pkg 失败。"

            fi

        done

        ok "Alpine 基础依赖正常。"

    else

        export DEBIAN_FRONTEND=noninteractive

        apt-get update -qq >/dev/null 2>&1 \
            || die "apt update 失败。"

        for pkg in curl openssl ca-certificates dnsutils; do

            if ! dpkg -s "$pkg" >/dev/null 2>&1; then

                info "安装 $pkg ..."

                apt-get install -y "$pkg" >/dev/null 2>&1 \
                    || die "安装 $pkg 失败。"

            fi

        done

        ok "Debian 基础依赖正常。"

    fi
}

# ============================================================
# Cron
# ============================================================

setup_cron() {

    info "检查自动任务服务..."

    if [ "$OS" = "alpine" ]; then

        if ! command -v crond >/dev/null 2>&1; then
            apk add --no-cache busybox >/dev/null 2>&1 || true
        fi

        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true

        ok "Alpine crond 已启用。"

    else

        if ! command -v cron >/dev/null 2>&1; then

            export DEBIAN_FRONTEND=noninteractive

            apt-get install -y cron >/dev/null 2>&1 \
                || die "cron 安装失败。"

        fi

        systemctl enable cron >/dev/null 2>&1 || true
        systemctl start cron >/dev/null 2>&1 || true

        ok "Debian cron 已启用。"

    fi
}

# ============================================================
# Nginx
# ============================================================

install_nginx() {

    if command -v nginx >/dev/null 2>&1; then
        ok "Nginx 已安装。"
        return
    fi

    info "Nginx 未安装，正在安装..."

    if [ "$OS" = "alpine" ]; then

        apk add --no-cache nginx >/dev/null 2>&1 \
            || die "Nginx 安装失败。"

    else

        export DEBIAN_FRONTEND=noninteractive

        apt-get install -y nginx >/dev/null 2>&1 \
            || die "Nginx 安装失败。"

    fi

    ok "Nginx 安装完成。"
}

# ============================================================
# Nginx 服务
# ============================================================

nginx_start() {

    if [ "$OS" = "alpine" ]; then

        rc-update add nginx default >/dev/null 2>&1 || true
        rc-service nginx start >/dev/null 2>&1 || true

    else

        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl start nginx >/dev/null 2>&1 || true

    fi
}

# ============================================================
# Nginx reload
# ============================================================

nginx_reload() {

    if ! nginx -t >/dev/null 2>&1; then

        err "Nginx 配置检查失败。"

        nginx -t

        return 1
    fi

    if [ "$OS" = "alpine" ]; then

        rc-service nginx reload >/dev/null 2>&1 \
            || nginx -s reload

    else

        systemctl reload nginx

    fi

    return 0
}

# ============================================================
# 修复旧 acme.sh 环境
# ============================================================

prepare_acme_environment() {

    # 防止旧项目设置 LE_CONFIG_HOME
    unset LE_CONFIG_HOME 2>/dev/null || true

    export HOME="/root"

    # 强制 acme.sh 使用官方默认目录
    export LE_CONFIG_HOME="/root/.acme.sh"

    mkdir -p "$ACME_HOME"

    chmod 700 "$ACME_HOME"

    # 旧项目留下的路径不再使用
    if [ -d "/opt/cert-manager/logs" ]; then
        rm -rf "/opt/cert-manager"
    fi
}

# ============================================================
# 安装 acme.sh
# ============================================================

install_acme() {

    prepare_acme_environment

    if [ -x "$ACME_HOME/acme.sh" ]; then

        ok "acme.sh 已安装。"

        return 0
    fi

    info "正在安装 acme.sh..."

    if [ -n "$EMAIL" ]; then

        curl -fsSL https://get.acme.sh \
            | sh -s "email=$EMAIL" \
            || die "acme.sh 安装失败。"

    else

        curl -fsSL https://get.acme.sh \
            | sh \
            || die "acme.sh 安装失败。"

    fi

    if [ ! -x "$ACME_HOME/acme.sh" ]; then
        die "acme.sh 安装失败，未找到 $ACME_HOME/acme.sh"
    fi

    ok "acme.sh 安装完成。"
}

# ============================================================
# acme.sh
# ============================================================

acme() {

    export HOME="/root"
    export LE_CONFIG_HOME="/root/.acme.sh"

    "$ACME_HOME/acme.sh" "$@"
}

# ============================================================
# 设置 CA
# ============================================================

setup_acme_ca() {

    export HOME="/root"
    export LE_CONFIG_HOME="/root/.acme.sh"

    if [ -n "$EMAIL" ]; then

        acme --register-account \
            -m "$EMAIL" >/dev/null 2>&1 || true

    fi

    acme --set-default-ca \
        --server letsencrypt >/dev/null 2>&1 || true
}

# ============================================================
# Cloudflare API 检查
# ============================================================

check_cloudflare() {

    info "验证 Cloudflare API Token..."

    VERIFY_RESULT="$(
        curl -fsS \
            -H "Authorization: Bearer $CF_TOKEN" \
            -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/user/tokens/verify" \
            2>/dev/null
    )"

    if printf '%s' "$VERIFY_RESULT" | grep -q '"success":true'; then

        ok "Cloudflare API Token 有效。"

    else

        err "Cloudflare API Token 验证失败。"

        printf '%s\n' "$VERIFY_RESULT"

        die "请检查 Cloudflare API Token。"
    fi

    # --------------------------------------------------------
    # 获取 Zone
    # --------------------------------------------------------

    ZONE_RESULT="$(
        curl -fsS \
            -G \
            -H "Authorization: Bearer $CF_TOKEN" \
            -H "Content-Type: application/json" \
            --data-urlencode "name=$DOMAIN" \
            --data-urlencode "status=active" \
            --data-urlencode "per_page=1" \
            "https://api.cloudflare.com/client/v4/zones" \
            2>/dev/null
    )"

    # 不再错误依赖 result_info 中 count 的顺序
    if printf '%s' "$ZONE_RESULT" \
        | grep -q '"success":true' \
        && printf '%s' "$ZONE_RESULT" \
        | grep -q "\"name\":\"$DOMAIN\""
    then

        ok "Cloudflare Zone：$DOMAIN"

    else

        err "没有找到 Cloudflare Zone：$DOMAIN"

        printf '%s\n' "$ZONE_RESULT"

        die "请确认 -d 主域名正确，并确认 Token 有 Zone/DNS 权限。"
    fi
}

# ============================================================
# 获取完整域名
# ============================================================

get_full_domain() {

    SUB="$1"

    SUB="${SUB%.}"

    if [ "$SUB" = "@" ]; then

        FULL_DOMAIN="$DOMAIN"

    elif [ "$SUB" = "$DOMAIN" ]; then

        FULL_DOMAIN="$DOMAIN"

    elif printf '%s' "$SUB" | grep -q "\.${DOMAIN}$"; then

        FULL_DOMAIN="$SUB"

    else

        FULL_DOMAIN="${SUB}.${DOMAIN}"

    fi
}

# ============================================================
# 域名检查
# ============================================================

validate_domain() {

    D="$1"

    case "$D" in

        ""|.*|*.|*..*)
            return 1
            ;;

        *[!a-zA-Z0-9.-]*)
            return 1
            ;;

    esac

    return 0
}

# ============================================================
# 文件路径
# ============================================================

site_info_file() {

    printf "%s/%s.conf" "$SITES_DIR" "$1"
}

nginx_site_file() {

    printf "%s/%s.conf" "$NGINX_AVAILABLE" "$1"
}

cert_dir() {

    printf "%s/%s" "$BASE_DIR" "$1"
}

# ============================================================
# 读取站点端口
# ============================================================

get_site_port() {

    SITE="$1"
    FILE="$(site_info_file "$SITE")"

    PORT=""

    if [ -f "$FILE" ]; then
        . "$FILE"
    fi
}

# ============================================================
# 创建 Nginx 配置
# ============================================================

create_nginx_config() {

    SITE="$1"
    PORT="$2"

    CONF="$(nginx_site_file "$SITE")"
    CERT="$(cert_dir "$SITE")"

    mkdir -p "$CERT"

    cat > "$CONF" <<EOF
# Managed by nginx-ssl-manager
# Domain: ${SITE}
# Backend: 127.0.0.1:${PORT}

server {

    listen 80;
    listen [::]:80;

    server_name ${SITE};

    location / {

        proxy_pass http://127.0.0.1:${PORT};

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

    server_name ${SITE};

    ssl_certificate ${CERT}/fullchain.pem;
    ssl_certificate_key ${CERT}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;

    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    location / {

        proxy_pass http://127.0.0.1:${PORT};

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

    if [ "$OS" = "debian" ]; then

        mkdir -p "$NGINX_ENABLED"

        ln -sf "$CONF" \
            "${NGINX_ENABLED}/${SITE}.conf"

    fi
}

# ============================================================
# 临时 HTTP 配置
# ============================================================

create_temp_config() {

    SITE="$1"
    CONF="$(nginx_site_file "$SITE")"

    cat > "$CONF" <<EOF
# Temporary configuration managed by nginx-ssl-manager

server {

    listen 80;
    listen [::]:80;

    server_name ${SITE};

    location / {
        return 200 "Nginx SSL Manager";
        add_header Content-Type text/plain;
    }
}
EOF

    if [ "$OS" = "debian" ]; then

        mkdir -p "$NGINX_ENABLED"

        ln -sf "$CONF" \
            "${NGINX_ENABLED}/${SITE}.conf"

    fi
}

# ============================================================
# 保存站点
# ============================================================

save_site() {

    SITE="$1"
    PORT="$2"

    cat > "$(site_info_file "$SITE")" <<EOF
DOMAIN='$SITE'
PORT='$PORT'
EOF

    chmod 600 "$(site_info_file "$SITE")"
}

# ============================================================
# 申请 SSL
# ============================================================

issue_ssl() {

    SITE="$1"

    info "正在申请 SSL：$SITE"

    export CF_Token="$CF_TOKEN"

    # 防止旧变量影响
    unset CF_Key 2>/dev/null || true

    if acme \
        --issue \
        --dns dns_cf \
        -d "$SITE" \
        --keylength ec-256
    then

        ok "SSL 申请成功：$SITE"

        return 0

    fi

    err "SSL 申请失败：$SITE"

    return 1
}

# ============================================================
# 安装 SSL
# ============================================================

install_ssl() {

    SITE="$1"

    CERT="$(cert_dir "$SITE")"

    mkdir -p "$CERT"

    chmod 700 "$CERT"

    if [ "$OS" = "alpine" ]; then

        RELOAD_CMD="nginx -t && rc-service nginx reload"

    else

        RELOAD_CMD="nginx -t && systemctl reload nginx"

    fi

    info "正在部署 SSL 证书..."

    if acme \
        --install-cert \
        -d "$SITE" \
        --ecc \
        --key-file "$CERT/privkey.pem" \
        --fullchain-file "$CERT/fullchain.pem" \
        --reloadcmd "$RELOAD_CMD"
    then

        chmod 600 "$CERT/privkey.pem" 2>/dev/null || true
        chmod 644 "$CERT/fullchain.pem" 2>/dev/null || true

        ok "SSL 证书部署成功。"

        return 0

    fi

    err "SSL 证书部署失败。"

    return 1
}

# ============================================================
# 新增站点
# ============================================================

add_site() {

    clear 2>/dev/null || true

    printf '%s\n' "========================================="
    printf '              新增站点\n'
    printf '%s\n' "========================================="

    printf '\n主域名：%s\n\n' "$DOMAIN"

    printf '请输入子域名：\n'
    printf '例如：rsshub\n'
    printf '主域名请输入：@\n\n'
    printf '子域名：'

    read SUB

    [ -z "$SUB" ] && {
        warn "子域名不能为空。"
        pause
        return
    }

    get_full_domain "$SUB"

    if ! validate_domain "$FULL_DOMAIN"; then

        err "域名格式错误：$FULL_DOMAIN"

        pause

        return
    fi

    CONF="$(nginx_site_file "$FULL_DOMAIN")"

    if [ -f "$CONF" ]; then

        warn "站点已经存在：$FULL_DOMAIN"

        pause

        return
    fi

    printf '\n完整域名：%s\n' "$FULL_DOMAIN"

    printf '\n请输入后端端口：\n'
    printf '默认地址：127.0.0.1\n'
    printf '端口：'

    read PORT

    case "$PORT" in

        ''|*[!0-9]*)
            err "端口必须是数字。"
            pause
            return
            ;;

    esac

    if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then

        err "端口范围必须是 1-65535。"

        pause

        return
    fi

    printf '\n'
    printf '%s\n' "-----------------------------------------"
    printf '域名：%s\n' "$FULL_DOMAIN"
    printf '后端：127.0.0.1:%s\n' "$PORT"
    printf 'SSL：Let's Encrypt\n'
    printf '验证：Cloudflare DNS-01\n'
    printf '续签：自动\n'
    printf '%s\n' "-----------------------------------------"
    printf '\n'

    # --------------------------------------------------------
    # 先临时创建 HTTP 配置
    # --------------------------------------------------------

    create_temp_config "$FULL_DOMAIN"

    if ! nginx -t >/dev/null 2>&1; then

        err "Nginx 配置检查失败。"

        nginx -t

        rm -f "$CONF"

        if [ "$OS" = "debian" ]; then
            rm -f "${NGINX_ENABLED}/${FULL_DOMAIN}.conf"
        fi

        pause

        return
    fi

    nginx_reload >/dev/null 2>&1 || true

    # --------------------------------------------------------
    # DNS-01 申请证书
    # --------------------------------------------------------

    if ! issue_ssl "$FULL_DOMAIN"; then

        warn "SSL 申请失败。"

        warn "暂时保留站点配置。"

        save_site "$FULL_DOMAIN" "$PORT"

        pause

        return
    fi

    # --------------------------------------------------------
    # 写入正式 Nginx 配置
    # --------------------------------------------------------

    create_nginx_config "$FULL_DOMAIN" "$PORT"

    # --------------------------------------------------------
    # 保存站点
    # --------------------------------------------------------

    save_site "$FULL_DOMAIN" "$PORT"

    # --------------------------------------------------------
    # 部署证书
    # --------------------------------------------------------

    if ! install_ssl "$FULL_DOMAIN"; then

        err "SSL 部署失败。"

        pause

        return
    fi

    # --------------------------------------------------------
    # 最终 Nginx 检查
    # --------------------------------------------------------

    if ! nginx -t; then

        err "Nginx 最终配置检查失败。"

        pause

        return
    fi

    nginx_reload >/dev/null 2>&1 || true

    log "新增站点 $FULL_DOMAIN -> 127.0.0.1:$PORT"

    printf '\n'
    printf '%s\n' "========================================="
    ok "站点创建完成"
    printf '%s\n' "========================================="
    printf '\n'

    printf '域名：%s\n' "$FULL_DOMAIN"
    printf 'HTTPS：https://%s\n' "$FULL_DOMAIN"
    printf '后端：127.0.0.1:%s\n' "$PORT"
    printf 'SSL：✓\n'
    printf '自动续签：✓\n'

    printf '\n'

    pause
}

# ============================================================
# 站点列表
# ============================================================

list_sites() {

    clear 2>/dev/null || true

    printf '%s\n' "========================================="
    printf '              当前站点\n'
    printf '%s\n' "========================================="

    COUNT=0

    for FILE in "$SITES_DIR"/*.conf; do

        [ -f "$FILE" ] || continue

        unset DOMAIN PORT 2>/dev/null || true

        . "$FILE"

        COUNT=$((COUNT + 1))

        printf '\n%d. %s\n' "$COUNT" "$DOMAIN"
        printf '   后端：127.0.0.1:%s\n' "$PORT"

        if [ -f "$(cert_dir "$DOMAIN")/fullchain.pem" ]; then
            printf '   SSL：✓\n'
        else
            printf '   SSL：✗\n'
        fi

    done

    if [ "$COUNT" -eq 0 ]; then
        printf '\n暂无站点。\n'
    fi

    printf '\n'

    pause
}

# ============================================================
# 选择站点
# ============================================================

choose_site() {

    SELECT_FILE="${BASE_DIR}/.select"

    : > "$SELECT_FILE"

    COUNT=0

    for FILE in "$SITES_DIR"/*.conf; do

        [ -f "$FILE" ] || continue

        unset DOMAIN PORT 2>/dev/null || true

        . "$FILE"

        COUNT=$((COUNT + 1))

        printf '%d. %s -> 127.0.0.1:%s\n' \
            "$COUNT" "$DOMAIN" "$PORT"

        printf '%s\n' "$DOMAIN" >> "$SELECT_FILE"

    done

    if [ "$COUNT" -eq 0 ]; then

        rm -f "$SELECT_FILE"

        return 1
    fi

    printf '\n0. 返回\n\n'
    printf '请选择：'

    read NUM

    if [ "$NUM" = "0" ]; then

        rm -f "$SELECT_FILE"

        return 1
    fi

    TARGET="$(sed -n "${NUM}p" "$SELECT_FILE" 2>/dev/null)"

    rm -f "$SELECT_FILE"

    [ -z "$TARGET" ] && return 1

    return 0
}

# ============================================================
# 修改反向代理端口
# ============================================================

modify_port() {

    clear 2>/dev/null || true

    printf '%s\n' "========================================="
    printf '          修改反向代理端口\n'
    printf '%s\n' "========================================="

    printf '\n'

    if ! choose_site; then

        warn "没有可修改的站点。"

        pause

        return
    fi

    SITE="$TARGET"

    get_site_port "$SITE"

    printf '\n当前：%s -> 127.0.0.1:%s\n' \
        "$SITE" "$PORT"

    printf '\n请输入新端口：'

    read NEW_PORT

    case "$NEW_PORT" in

        ''|*[!0-9]*)
            err "端口必须是数字。"
            pause
            return
            ;;

    esac

    if [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then

        err "端口范围必须是 1-65535。"

        pause

        return
    fi

    # 备份
    mkdir -p "$BACKUP_DIR/$SITE"

    CONF="$(nginx_site_file "$SITE")"

    [ -f "$CONF" ] && \
        cp "$CONF" "$BACKUP_DIR/$SITE/$(date '+%Y%m%d-%H%M%S').conf"

    create_nginx_config "$SITE" "$NEW_PORT"

    save_site "$SITE" "$NEW_PORT"

    if nginx -t >/dev/null 2>&1; then

        nginx_reload >/dev/null 2>&1 || true

        ok "端口修改成功。"

        printf '\n%s -> 127.0.0.1:%s\n' \
            "$SITE" "$NEW_PORT"

        log "修改端口 $SITE -> $NEW_PORT"

    else

        err "Nginx 配置检查失败。"

        nginx -t
    fi

    pause
}

# ============================================================
# 删除站点
# ============================================================

delete_site() {

    clear 2>/dev/null || true

    printf '%s\n' "========================================="
    printf '              删除站点\n'
    printf '%s\n' "========================================="

    printf '\n'

    if ! choose_site; then

        warn "没有站点。"

        pause

        return
    fi

    SITE="$TARGET"

    printf '\n'
    printf '即将删除：%s\n' "$SITE"

    get_site_port "$SITE"

    printf '后端：127.0.0.1:%s\n' "$PORT"

    printf '\n请输入 DELETE 确认删除：'

    read CONFIRM

    if [ "$CONFIRM" != "DELETE" ]; then

        warn "已取消。"

        pause

        return
    fi

    CONF="$(nginx_site_file "$SITE")"

    # 备份配置
    mkdir -p "$BACKUP_DIR/$SITE"

    [ -f "$CONF" ] && \
        cp "$CONF" "$BACKUP_DIR/$SITE/"

    [ -f "$(site_info_file "$SITE")" ] && \
        cp "$(site_info_file "$SITE")" "$BACKUP_DIR/$SITE/"

    # 删除 Nginx
    rm -f "$CONF"

    if [ "$OS" = "debian" ]; then
        rm -f "${NGINX_ENABLED}/${SITE}.conf"
    fi

    # 删除站点记录
    rm -f "$(site_info_file "$SITE")"

    # 删除证书
    rm -rf "$(cert_dir "$SITE")"

    # 删除 acme.sh 证书/续签配置
    acme --remove \
        -d "$SITE" \
        --ecc >/dev/null 2>&1 || true

    nginx_reload >/dev/null 2>&1 || true

    log "删除站点 $SITE"

    ok "站点已删除。"

    printf '\n'
    printf '✓ Nginx 配置已删除\n'
    printf '✓ SSL 证书已删除\n'
    printf '✓ 自动续签配置已删除\n'
    printf '✓ Nginx 已重新加载\n'

    pause
}

# ============================================================
# SSL 状态
# ============================================================

ssl_status() {

    clear 2>/dev/null || true

    printf '%s\n' "========================================="
    printf '              SSL 状态\n'
    printf '%s\n' "========================================="

    COUNT=0

    for FILE in "$SITES_DIR"/*.conf; do

        [ -f "$FILE" ] || continue

        unset DOMAIN PORT 2>/dev/null || true

        . "$FILE"

        COUNT=$((COUNT + 1))

        CERT="$(cert_dir "$DOMAIN")/fullchain.pem"

        printf '\n%s\n' "$DOMAIN"

        if [ -f "$CERT" ]; then

            ok "证书已安装"

            if command -v openssl >/dev/null 2>&1; then

                END_DATE="$(
                    openssl x509 \
                        -in "$CERT" \
                        -noout \
                        -enddate 2>/dev/null \
                        | sed 's/^notAfter=//'
                )"

                printf '到期：%s\n' "$END_DATE"

            fi

        else

            err "没有证书"

        fi

    done

    [ "$COUNT" -eq 0 ] && printf '\n暂无站点。\n'

    printf '\n'

    pause
}

# ============================================================
# Nginx 检查
# ============================================================

nginx_check() {

    clear 2>/dev/null || true

    printf '%s\n' "========================================="
    printf '             Nginx 检查\n'
    printf '%s\n' "========================================="

    printf '\n'

    nginx -t

    printf '\n'

    pause
}

# ============================================================
# Nginx Reload
# ============================================================

nginx_reload_menu() {

    clear 2>/dev/null || true

    printf '%s\n' "========================================="
    printf '             Nginx Reload\n'
    printf '%s\n' "========================================="

    printf '\n'

    if nginx_reload; then

        ok "Nginx reload 成功。"

    else

        err "Nginx reload 失败。"

    fi

    printf '\n'

    pause
}

# ============================================================
# 系统状态
# ============================================================

system_status() {

    clear 2>/dev/null || true

    printf '%s\n' "========================================="
    printf '              系统状态\n'
    printf '%s\n' "========================================="

    printf '\n'

    if [ "$OS" = "alpine" ]; then
        printf '系统：Alpine Linux %s\n' \
            "$(cat /etc/alpine-release)"
    else
        printf '系统：Debian\n'
    fi

    printf '架构：%s\n' "$ARCH"
    printf '内核：%s\n' "$(uname -r)"
    printf '主域名：%s\n' "$DOMAIN"

    if [ -n "$EMAIL" ]; then
        printf '邮箱：%s\n' "$EMAIL"
    else
        printf '邮箱：未设置\n'
    fi

    printf '\nNginx：'
    nginx -v 2>&1

    printf '\nacme.sh：'

    if [ -x "$ACME_HOME/acme.sh" ]; then
        acme --version 2>/dev/null | head -n 1
    else
        printf '未安装\n'
    fi

    printf '\n磁盘：\n'
    df -h / | tail -n 1

    printf '\n内存：\n'

    if command -v free >/dev/null 2>&1; then
        free -h
    else
        grep -E 'MemTotal|MemAvailable' \
            /proc/meminfo 2>/dev/null || true
    fi

    printf '\nIPv6：\n'

    if command -v ip >/dev/null 2>&1; then
        ip -6 addr show scope global 2>/dev/null \
            | grep 'inet6 ' \
            | head -n 5 || true
    fi

    printf '\n'

    pause
}

# ============================================================
# 主菜单
# ============================================================

menu() {

    while true; do

        clear 2>/dev/null || true

        printf '%s\n' "╔════════════════════════════════════════╗"
        printf '%s\n' "║       Nginx SSL 懒人管理器            ║"
        printf '%s\n' "╠════════════════════════════════════════╣"
        printf '║ 主域名：%-29s ║\n' "$DOMAIN"
        printf '║ 系统：%-31s ║\n' "$OS"
        printf '║ Cloudflare DNS：%-20s ║\n' "✓"
        printf '║ SSL 自动续签：%-22s ║\n' "✓"
        printf '%s\n' "╠════════════════════════════════════════╣"
        printf '%s\n' "║                                        ║"
        printf '%s\n' "║  1. 新增站点                           ║"
        printf '%s\n' "║  2. 删除站点                           ║"
        printf '%s\n' "║  3. 修改反向代理端口                   ║"
        printf '%s\n' "║  4. 查看站点                           ║"
        printf '%s\n' "║  5. SSL证书状态                        ║"
        printf '%s\n' "║  6. Nginx配置检查                      ║"
        printf '%s\n' "║  7. Nginx重新加载                      ║"
        printf '%s\n' "║  8. 系统状态                           ║"
        printf '%s\n' "║                                        ║"
        printf '%s\n' "║  0. 退出                               ║"
        printf '%s\n' "║                                        ║"
        printf '%s\n' "╚════════════════════════════════════════╝"

        printf '\n请选择：'

        read CHOICE

        case "$CHOICE" in

            1)
                add_site
                ;;

            2)
                delete_site
                ;;

            3)
                modify_port
                ;;

            4)
                list_sites
                ;;

            5)
                ssl_status
                ;;

            6)
                nginx_check
                ;;

            7)
                nginx_reload_menu
                ;;

            8)
                system_status
                ;;

            0)
                printf '\n退出。\n'
                exit 0
                ;;

            *)
                warn "无效选择。"
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# 主程序
# ============================================================

main() {

    check_root

    detect_os

    init_dirs

    install_dependencies

    setup_cron

    install_nginx

    nginx_start

    prepare_acme_environment

    install_acme

    setup_acme_ca

    save_config

    check_cloudflare

    if ! nginx -t >/dev/null 2>&1; then

        err "Nginx 当前配置有错误。"

        nginx -t

        exit 1
    fi

    nginx_reload >/dev/null 2>&1 || true

    log "Manager ${VERSION} started"

    menu
}

main "$@"