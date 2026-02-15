#!/bin/bash
# nginx-manager.sh - Nginx 交互式管理工具 (Alpine Linux) - 默认配置增强版
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 路径定义 (Alpine Linux 标准路径)
NGINX_DIR="/etc/nginx"
SITES_AVAILABLE="${NGINX_DIR}/sites-available"
SITES_ENABLED="${NGINX_DIR}/sites-enabled"
SSL_DIR="${NGINX_DIR}/ssl"
LOG_DIR="/var/log/nginx"
WWW_ROOT="/var/www"
CERTS_DIR="${SSL_DIR}/certs"
PRIVATE_DIR="${SSL_DIR}/private"

# 全局变量
DOMAIN=""
CERT_FILE=""
KEY_FILE=""

# ---------- 辅助函数 ----------
# 站点名规范化（移除 .conf 后缀）
normalize_site_name() {
    local name="$1"
    echo "${name%.conf}"
}

# 检查 busybox date 是否支持 -d
date_supports_d() {
    date --help 2>&1 | grep -q -- "-d"
}

# ---------- 初始化 ----------
install_deps() {
    echo -e "${BLUE}安装必要依赖...${NC}"
    apk update
    apk add --no-cache nginx openssl curl
}

init_check() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用 root 权限运行此脚本${NC}"
        exit 1
    fi

    install_deps

    mkdir -p "$SITES_AVAILABLE" "$SITES_ENABLED" "$SSL_DIR" "$CERTS_DIR" "$PRIVATE_DIR" "$WWW_ROOT" "$LOG_DIR"
    mkdir -p /run/nginx

    # 设置 web 用户权限
    local web_user="nginx"
    if ! id nginx &>/dev/null; then
        web_user="www-data"
    fi
    chown -R "$web_user":"$web_user" "$WWW_ROOT" 2>/dev/null || true

    detect_domain
}

# ---------- 证书检测 ----------
detect_domain() {
    echo -e "${BLUE}正在检测 SSL 证书...${NC}"

    local found_cert=""
    # 1. 标准位置
    for cert in "$CERTS_DIR/default.crt" "$CERTS_DIR/wildcard.crt"; do
        if [ -f "$cert" ]; then
            found_cert="$cert"
            echo -e "${GREEN}找到证书: $(basename "$cert")${NC}"
            break
        fi
    done

    # 2. 任意 .crt 文件
    if [ -z "$found_cert" ]; then
        local any_cert
        any_cert=$(find "$CERTS_DIR" -maxdepth 1 -name "*.crt" -type f 2>/dev/null | head -1)
        if [ -n "$any_cert" ]; then
            found_cert="$any_cert"
            echo -e "${GREEN}找到证书: $(basename "$any_cert")${NC}"
        fi
    fi

    # 3. acme.sh 路径
    if [ -z "$found_cert" ]; then
        local acme_cert
        acme_cert=$(find /root/.acme.sh -maxdepth 2 -type f -name "fullchain.cer" 2>/dev/null | head -1)
        if [ -n "$acme_cert" ]; then
            found_cert="$acme_cert"
            echo -e "${GREEN}找到证书: $(basename "$acme_cert")${NC}"
        fi
    fi

    if [ -n "$found_cert" ] && [ -f "$found_cert" ]; then
        CERT_FILE="$found_cert"

        local cert_name
        cert_name=$(basename "$found_cert" .crt)
        cert_name=$(basename "$cert_name" .cer)
        cert_name=$(basename "$cert_name" .pem)

        # 查找私钥
        for key in "$PRIVATE_DIR/default.key" "$PRIVATE_DIR/wildcard.key" "$PRIVATE_DIR/$cert_name.key"; do
            if [ -f "$key" ]; then
                KEY_FILE="$key"
                echo -e "${GREEN}找到私钥: $(basename "$key")${NC}"
                break
            fi
        done

        if [ -z "$KEY_FILE" ]; then
            local acme_key
            acme_key=$(find /root/.acme.sh -maxdepth 2 -type f -name "$cert_name.key" 2>/dev/null | head -1)
            if [ -n "$acme_key" ]; then
                KEY_FILE="$acme_key"
                echo -e "${GREEN}找到私钥: $(basename "$acme_key")${NC}"
            fi
        fi

        # 提取域名
        DOMAIN=$(openssl x509 -in "$found_cert" -text -noout 2>/dev/null |
            grep -o "DNS:\*\.\?[^,]*" | head -1 | cut -d: -f2 | sed 's/\*\.//')
        [ -z "$DOMAIN" ] && DOMAIN="$cert_name"

        if [ -n "$DOMAIN" ]; then
            echo -e "${GREEN}✓ 检测到主域名: $DOMAIN${NC}"
            return 0
        fi
    fi

    echo -e "${RED}未检测到有效的 SSL 证书${NC}"
    echo -e "请先运行证书申请脚本："
    echo -e "bash <(curl -fsSL https://raw.githubusercontent.com/penggan00/rss/main/https.sh)"
    return 1
}

# ---------- 显示横幅 ----------
show_banner() {
    clear
    echo -e "${PURPLE}============================================${NC}"
    echo -e "${CYAN}    Nginx 管理工具 - Alpine Linux 版${NC}"
    echo -e "${PURPLE}============================================${NC}"

    if [ -n "$DOMAIN" ]; then
        echo -e "${GREEN}主域名: $DOMAIN${NC}"
        [ -f "$CERT_FILE" ] && echo -e "${GREEN}证书: $(basename "$CERT_FILE")${NC}"
        [ -f "$KEY_FILE" ] && echo -e "${GREEN}私钥: $(basename "$KEY_FILE")${NC}"
    else
        echo -e "${RED}未检测到证书，请先申请 SSL 证书${NC}"
    fi

    local nginx_status="未运行"
    if pgrep nginx >/dev/null; then
        nginx_status="运行中"
    fi
    if [ "$nginx_status" = "运行中" ]; then
        echo -e "${GREEN}Nginx 状态: 运行中${NC}"
    else
        echo -e "${RED}Nginx 状态: $nginx_status${NC}"
    fi

    local site_count=0 enabled_count=0
    [ -d "$SITES_AVAILABLE" ] && site_count=$(find "$SITES_AVAILABLE" -maxdepth 1 -name "*.conf" -type f 2>/dev/null | wc -l)
    [ -d "$SITES_ENABLED" ] && enabled_count=$(find "$SITES_ENABLED" -maxdepth 1 -name "*.conf" -type l 2>/dev/null | wc -l)
    echo -e "${BLUE}站点统计: ${site_count}个配置 (${enabled_count}个启用)${NC}"
    echo ""
}

# ---------- 菜单 ----------
show_menu() {
    echo -e "${BLUE}请选择操作:${NC}"
    echo -e "  ${GREEN}1${NC}) 创建新站点 (强制 HTTPS)"
    echo -e "  ${GREEN}2${NC}) 删除站点"
    echo -e "  ${GREEN}3${NC}) 重载 Nginx 配置"
    echo -e "  ${GREEN}4${NC}) 查看 SSL 证书"
    echo -e "  ${GREEN}5${NC}) 查看所有站点"
    echo -e "  ${GREEN}6${NC}) 一键安装/更新 Nginx"
    echo -e "  ${GREEN}7${NC}) 启动/停止 Nginx 服务"
    echo -e "  ${GREEN}8${NC}) 备份/恢复配置"
    echo -e "  ${GREEN}9${NC}) 生成测试页面"
    echo -e "  ${GREEN}0${NC}) 退出"
    echo ""
}

# ---------- 1. 创建站点 ----------
create_site() {
    show_banner
    echo -e "${CYAN}[1] 创建新站点 (强制 HTTPS)${NC}\n"

    if [ -z "$DOMAIN" ] || [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        echo -e "${RED}错误: SSL 证书未检测到${NC}"
        echo -e "请先申请证书"
        read -p "按回车键返回主菜单..." -r
        return
    fi

    echo -e "${GREEN}主域名: $DOMAIN${NC}\n"

    local SUBDOMAIN="" SITE_NAME="" SERVER_NAME=""
    while true; do
        read -p "请输入子域名 (如 blog, shop, 留空直接使用主域名): " SUBDOMAIN
        if [ -z "$SUBDOMAIN" ]; then
            SITE_NAME="$DOMAIN"
            SERVER_NAME="$DOMAIN www.$DOMAIN"
            break
        elif [[ "$SUBDOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$ ]]; then
            SITE_NAME="${SUBDOMAIN}.${DOMAIN}"
            SERVER_NAME="${SUBDOMAIN}.${DOMAIN}"
            break
        else
            echo -e "${RED}子域名格式不正确${NC}"
        fi
    done

    local BACKEND_PORT="" BACKEND_ADDRESS=""
    echo -e "\n${YELLOW}反向代理配置${NC}"
    while true; do
        read -p "请输入后端服务端口号 (如 8080, 3000): " BACKEND_PORT
        if [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] && [ "$BACKEND_PORT" -ge 1 ] && [ "$BACKEND_PORT" -le 65535 ]; then
            BACKEND_ADDRESS="127.0.0.1:$BACKEND_PORT"
            echo -e "${GREEN}后端地址: $BACKEND_ADDRESS${NC}"
            break
        else
            echo -e "${RED}端口号必须是 1-65535 的数字${NC}"
        fi
    done

    local CONFIG_FILE="$SITES_AVAILABLE/$SITE_NAME.conf"
    cat > "$CONFIG_FILE" << EOF
# 自动生成 - $(date)
# 站点: $SITE_NAME
# 反向代理到: $BACKEND_ADDRESS

server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAME;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $SERVER_NAME;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;

    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    access_log $LOG_DIR/${SITE_NAME}_ssl_access.log;
    error_log $LOG_DIR/${SITE_NAME}_ssl_error.log warn;

    client_max_body_size 50M;

    location / {
        proxy_pass http://$BACKEND_ADDRESS;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
        proxy_read_timeout 60s;
        proxy_connect_timeout 60s;
        proxy_set_header Connection "";
    }

    location ~* \\.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)\$ {
        proxy_pass http://$BACKEND_ADDRESS;
        proxy_set_header Host \$host;
        add_header Cache-Control "public, max-age=31536000, immutable";
        access_log off;
    }

    location ~ /\\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

    echo -e "${GREEN}✓ 配置文件已创建: $CONFIG_FILE${NC}"
    enable_site "$SITE_NAME.conf"

    echo -e "\n${CYAN}站点创建完成!${NC}"
    echo -e "${BLUE}访问地址: https://$SITE_NAME${NC}"
    echo -e "${BLUE}后端服务: http://$BACKEND_ADDRESS${NC}"

    # 端口占用提示
    if ss -tuln 2>/dev/null | grep -q ":$BACKEND_PORT "; then
        echo -e "${GREEN}✓ 端口 $BACKEND_PORT 已被监听，后端服务可能已运行${NC}"
    else
        echo -e "${YELLOW}⚠ 端口 $BACKEND_PORT 未监听，请确保后端服务已启动${NC}"
    fi

    echo ""
    read -p "按回车键继续..." -r
}

# ---------- 启用站点 ----------
enable_site() {
    local config_name="$1"
    local source="$SITES_AVAILABLE/$config_name"
    local target="$SITES_ENABLED/$config_name"

    if [ ! -f "$source" ]; then
        echo -e "${RED}配置文件不存在: $source${NC}"
        return 1
    fi

    if [ -L "$target" ]; then
        echo -e "${YELLOW}站点已在启用状态${NC}"
    else
        ln -s "$source" "$target"
        echo -e "${GREEN}✓ 站点已启用${NC}"
    fi

    reload_nginx_quiet
}

# ---------- 2. 删除站点 ----------
delete_site() {
    show_banner
    echo -e "${CYAN}[2] 删除站点${NC}\n"

    list_sites_simple

    echo ""
    read -p "请输入要删除的站点名称: " input_name
    [ -z "$input_name" ] && echo -e "${RED}未指定站点名称${NC}" && read -p "按回车键继续..." -r && return

    local site_name
    site_name=$(normalize_site_name "$input_name")
    local config_file="$SITES_AVAILABLE/$site_name.conf"
    local enabled_link="$SITES_ENABLED/$site_name.conf"
    local doc_root="/var/www/$site_name"

    if [ ! -f "$config_file" ]; then
        echo -e "${RED}站点不存在: $site_name${NC}"
        read -p "按回车键继续..." -r
        return
    fi

    echo -e "\n${YELLOW}即将删除:${NC}"
    echo -e "  配置文件: $config_file"
    [ -L "$enabled_link" ] && echo -e "  启用链接: $enabled_link"
    [ -d "$doc_root" ] && echo -e "  网站目录: $doc_root"

    echo ""
    read -p "确认删除? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && echo -e "${RED}取消删除${NC}" && read -p "按回车键继续..." -r && return

    [ -L "$enabled_link" ] && rm -f "$enabled_link" && echo -e "${GREEN}✓ 已移除启用链接${NC}"
    rm -f "$config_file" && echo -e "${GREEN}✓ 已删除配置文件${NC}"
    if [[ "$doc_root" =~ ^/var/www/[^/]+$ ]] && [ -d "$doc_root" ]; then
        rm -rf "$doc_root"
        echo -e "${GREEN}✓ 已删除网站目录${NC}"
    fi

    reload_nginx_quiet
    echo -e "\n${GREEN}站点删除完成${NC}"
    read -p "按回车键继续..." -r
}

# ---------- 3. 重载 Nginx ----------
reload_nginx() {
    show_banner
    echo -e "${CYAN}[3] 重载 Nginx 配置${NC}\n"

    echo -e "${BLUE}检查配置语法...${NC}"
    if nginx -t 2>&1; then
        echo -e "${GREEN}配置语法正确${NC}"
        if command -v rc-service &>/dev/null; then
            rc-service nginx reload || nginx -s reload
        else
            nginx -s reload
        fi
        echo -e "${GREEN}✓ Nginx 配置已重载${NC}"
    else
        echo -e "${RED}配置语法错误，请检查${NC}"
    fi

    echo ""
    read -p "按回车键继续..." -r
}

reload_nginx_quiet() {
    nginx -t >/dev/null 2>&1 || return 1
    if command -v rc-service &>/dev/null; then
        rc-service nginx reload >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1
    else
        nginx -s reload >/dev/null 2>&1
    fi
    return 0
}

# ---------- 4. 查看 SSL 证书 ----------
view_certificates() {
    show_banner
    echo -e "${CYAN}[4] SSL 证书信息${NC}\n"

    if [ -z "$CERT_FILE" ] || [ ! -f "$CERT_FILE" ]; then
        echo -e "${YELLOW}未找到 SSL 证书${NC}"
        read -p "按回车键继续..." -r
        return
    fi

    echo -e "${GREEN}证书文件: $(basename "$CERT_FILE")${NC}"
    [ -f "$KEY_FILE" ] && echo -e "${GREEN}私钥文件: $(basename "$KEY_FILE")${NC}"
    echo ""

    echo -e "${BLUE}证书信息:${NC}"
    openssl x509 -in "$CERT_FILE" -text -noout 2>/dev/null \
        | grep -E "Subject:|Issuer:|Not Before:|Not After:|DNS:" \
        | head -10 || echo "无法解析证书"

    echo -e "\n${BLUE}有效性检查:${NC}"
    if openssl x509 -checkend 0 -noout -in "$CERT_FILE" >/dev/null 2>&1; then
        # 证书未过期，尝试计算剩余天数（兼容 busybox）
        local end_date expiry_sec now_sec days_left
        end_date=$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)
        if date_supports_d; then
            expiry_sec=$(date -u -d "$end_date" +%s 2>/dev/null)
            now_sec=$(date -u +%s)
            days_left=$(( (expiry_sec - now_sec) / 86400 ))
            echo -e "  ${GREEN}✓ 证书有效，剩余 ${days_left} 天${NC}"
        else
            echo -e "  ${GREEN}✓ 证书有效${NC} (剩余天数: 系统 date 不支持计算)"
        fi
    else
        echo -e "  ${RED}✗ 证书已过期${NC}"
    fi

    echo ""
    read -p "按回车键继续..." -r
}

# ---------- 5. 查看站点 ----------
view_sites() {
    show_banner
    echo -e "${CYAN}[5] 所有站点列表${NC}\n"
    list_sites_detailed
    echo ""
    read -p "按回车键继续..." -r
}

list_sites_simple() {
    echo -e "${BLUE}可用站点:${NC}"
    if [ ! -d "$SITES_AVAILABLE" ] || [ -z "$(ls -A "$SITES_AVAILABLE" 2>/dev/null)" ]; then
        echo -e "  ${YELLOW}暂无站点配置${NC}"
    else
        for conf in "$SITES_AVAILABLE"/*.conf; do
            [ -f "$conf" ] || continue
            local name
            name=$(basename "$conf" .conf)
            if [ -L "$SITES_ENABLED/$name.conf" ]; then
                echo -e "  ${GREEN}✓ $name${NC}"
            else
                echo -e "  ${YELLOW}○ $name${NC}"
            fi
        done
    fi
}

list_sites_detailed() {
    echo -e "${BLUE}站点状态概览:${NC}\n"
    if [ ! -d "$SITES_AVAILABLE" ] || [ -z "$(ls -A "$SITES_AVAILABLE" 2>/dev/null)" ]; then
        echo -e "  ${YELLOW}暂无站点配置${NC}"
        return
    fi

    printf "%-30s %-8s %-12s %-12s %s\n" "站点名称" "状态" "端口" "协议" "配置位置"
    echo "----------------------------------------------------------------------"
    for conf in "$SITES_AVAILABLE"/*.conf; do
        [ -f "$conf" ] || continue
        local name enabled ports protocol
        name=$(basename "$conf" .conf)
        enabled="否"
        [ -L "$SITES_ENABLED/$name.conf" ] && enabled="是"
        ports="80"
        protocol="HTTP"
        if grep -q "listen 443" "$conf"; then
            ports="80,443"
            protocol="HTTPS"
        fi
        printf "%-30s %-8s %-12s %-12s %s\n" "$name" "$enabled" "$ports" "$protocol" "$conf"
    done

    echo -e "\n${BLUE}监听端口:${NC}"
    if command -v ss &>/dev/null; then
        ss -tulpn | grep nginx 2>/dev/null || echo "  Nginx 未运行或未监听端口"
    elif command -v netstat &>/dev/null; then
        netstat -tulpn | grep nginx 2>/dev/null || echo "  Nginx 未运行或未监听端口"
    else
        echo "  无法获取端口信息"
    fi
}

# ---------- 6. 安装/更新 Nginx（保持默认配置）----------
install_nginx() {
    show_banner
    echo -e "${CYAN}[6] 安装/更新 Nginx${NC}\n"

    if pgrep nginx >/dev/null; then
        echo -e "${YELLOW}Nginx 已安装且正在运行${NC}"
        read -p "是否重新安装? (y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return
    fi

    echo -e "${BLUE}开始安装 Nginx...${NC}\n"

    # 1. 停止现有进程
    echo "1. 停止现有 Nginx 进程..."
    pkill nginx 2>/dev/null || true
    sleep 1

    # 2. 安装 Nginx（Alpine 官方包）
    echo "2. 安装 Nginx..."
    apk update
    apk add --no-cache nginx nginx-openrc

    # 3. 创建目录结构
    echo "3. 创建目录结构..."
    mkdir -p "$SITES_AVAILABLE" "$SITES_ENABLED" "$SSL_DIR" "$CERTS_DIR" "$PRIVATE_DIR" "$WWW_ROOT" "$LOG_DIR" /run/nginx

    # 4. 备份原配置（如果有）
    if [ -f "$NGINX_DIR/nginx.conf" ]; then
        local backup_file="$NGINX_DIR/nginx.conf.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$NGINX_DIR/nginx.conf" "$backup_file"
        echo -e "  ${GREEN}✓ 原配置已备份到: $backup_file${NC}"
    fi

    # 5. 确保默认配置文件存在（Alpine 官方包自带）
    if [ ! -f "$NGINX_DIR/nginx.conf" ]; then
        # 极少情况：包未安装完整，写入最小配置
        cat > "$NGINX_DIR/nginx.conf" << 'EOF'
user nginx;
worker_processes auto;
pid /run/nginx/nginx.pid;
events {
    worker_connections 1024;
}
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    fi

    # 6. 创建优化配置（独立文件，不修改主配置）
    echo "4. 创建优化配置文件 (conf.d)..."
    cat > "$NGINX_DIR/conf.d/00-optimizations.conf" << 'EOF'
# Nginx 优化配置 - 由 nginx-manager.sh 生成
# 不影响主配置文件，仅添加额外设置

# 代理头哈希（解决常见警告）
proxy_headers_hash_max_size 1024;
proxy_headers_hash_bucket_size 128;

# 连接限制（内存占用降低为1m，适合小内存）
limit_conn_zone $binary_remote_addr zone=perip:1m;
limit_conn_zone $server_name zone=perserver:1m;
limit_req_zone $binary_remote_addr zone=perip_req:1m rate=20r/s;

# 全局限制（可在 server 块覆盖）
limit_conn perip 20;
limit_conn perserver 100;
limit_req zone=perip_req burst=40 nodelay;

# 隐藏版本号
server_tokens off;

# 缓冲区优化
client_body_buffer_size 128k;
client_header_buffer_size 4k;
large_client_header_buffers 4 8k;

# 超时优化
client_body_timeout 30s;
client_header_timeout 30s;
send_timeout 30s;
reset_timedout_connection on;

# 日志格式增强（在 http 块内有效）
log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                '$status $body_bytes_sent "$http_referer" '
                '"$http_user_agent" "$http_x_forwarded_for"';
EOF

    # 7. 创建日志轮转配置（修正用户组）
    echo "5. 创建日志轮转配置..."
    cat > "/etc/logrotate.d/nginx" << 'EOF'
/var/log/nginx/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 nginx nginx
    sharedscripts
    postrotate
        if [ -f /run/nginx/nginx.pid ]; then
            kill -USR1 $(cat /run/nginx/nginx.pid)
        fi
    endscript
}
EOF

    # 8. 启动服务
    echo "6. 启动 Nginx 服务..."
    if command -v rc-service &>/dev/null; then
        rc-update add nginx default 2>/dev/null || true
        rc-service nginx start
    else
        nginx
    fi

    # 9. 检测域名
    echo "7. 检测域名和证书..."
    detect_domain

    echo -e "\n${GREEN}✓ Nginx 安装完成!${NC}"
    echo -e "版本: $(nginx -v 2>&1 | cut -d/ -f2)"
    pgrep nginx >/dev/null && echo -e "状态: ${GREEN}运行中${NC}" || echo -e "状态: ${RED}未运行${NC}"
    echo -e "主配置文件: $NGINX_DIR/nginx.conf (保持官方默认)"
    echo -e "优化配置: $NGINX_DIR/conf.d/00-optimizations.conf"
    echo -e "站点配置目录: $SITES_AVAILABLE"

    echo ""
    read -p "按回车键继续..." -r
}

# ---------- 7. 管理服务 ----------
manage_service() {
    show_banner
    echo -e "${CYAN}[7] 管理 Nginx 服务${NC}\n"

    local status="已停止"
    pgrep nginx >/dev/null && status="运行中"
    echo -e "当前状态: $([ "$status" = "运行中" ] && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}已停止${NC}")"
    echo ""

    echo -e "${BLUE}请选择操作:${NC}"
    echo -e "  ${GREEN}1${NC}) 启动"
    echo -e "  ${GREEN}2${NC}) 停止"
    echo -e "  ${GREEN}3${NC}) 重启"
    echo -e "  ${GREEN}4${NC}) 查看状态"
    echo -e "  ${GREEN}5${NC}) 查看日志"
    echo -e "  ${GREEN}6${NC}) 返回"
    echo ""

    read -p "请选择 [1-6]: " choice

    case $choice in
        1)
            if command -v rc-service &>/dev/null; then
                rc-service nginx start
            else
                nginx
            fi
            echo -e "${GREEN}✓ Nginx 已启动${NC}"
            ;;
        2)
            if command -v rc-service &>/dev/null; then
                rc-service nginx stop
            else
                nginx -s quit
            fi
            echo -e "${YELLOW}✓ Nginx 已停止${NC}"
            ;;
        3)
            if command -v rc-service &>/dev/null; then
                rc-service nginx restart
            else
                nginx -s quit 2>/dev/null
                sleep 1
                nginx
            fi
            echo -e "${GREEN}✓ Nginx 已重启${NC}"
            ;;
        4)
            echo ""
            if command -v rc-service &>/dev/null; then
                rc-service nginx status
            else
                echo "进程: $(pgrep nginx | wc -l) 个"
            fi
            ;;
        5)
            echo -e "${BLUE}最近 50 条错误日志:${NC}"
            tail -50 /var/log/nginx/error.log 2>/dev/null || echo "日志文件不存在"
            echo ""
            echo -e "${BLUE}最近 20 条访问日志:${NC}"
            tail -20 /var/log/nginx/access.log 2>/dev/null || echo "日志文件不存在"
            ;;
        6) return ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac

    echo ""
    read -p "按回车键继续..." -r
}

# ---------- 8. 备份/恢复 ----------
backup_restore() {
    show_banner
    echo -e "${CYAN}[8] 备份/恢复配置${NC}\n"

    local backup_dir="/var/backups/nginx"
    mkdir -p "$backup_dir"

    echo -e "${BLUE}请选择操作:${NC}"
    echo -e "  ${GREEN}1${NC}) 备份配置"
    echo -e "  ${GREEN}2${NC}) 恢复配置"
    echo -e "  ${GREEN}3${NC}) 列出备份"
    echo -e "  ${GREEN}4${NC}) 清理旧备份"
    echo -e "  ${GREEN}5${NC}) 返回"
    echo ""

    read -p "请选择 [1-5]: " choice

    case $choice in
        1)
            local timestamp=$(date +%Y%m%d_%H%M%S)
            local backup_file="$backup_dir/nginx-backup-$timestamp.tar.gz"
            echo -e "${BLUE}正在备份...${NC}"
            tar -czf "$backup_file" \
                "$NGINX_DIR/nginx.conf" \
                "$NGINX_DIR/conf.d" \
                "$SITES_AVAILABLE" \
                "$SITES_ENABLED" \
                "$SSL_DIR" 2>/dev/null || true
            echo -e "${GREEN}✓ 备份完成: $(basename "$backup_file")${NC}"
            ls -lh "$backup_file"
            ;;
        2)
            echo -e "${BLUE}可用的备份:${NC}"
            ls -1 "$backup_dir/"*.tar.gz 2>/dev/null || {
                echo -e "${YELLOW}暂无备份${NC}"
                read -p "按回车键继续..." -r
                return
            }
            echo ""
            ls -lh "$backup_dir/"*.tar.gz
            echo ""
            read -p "请输入要恢复的备份文件名: " backup_file
            [ ! -f "$backup_dir/$backup_file" ] && echo -e "${RED}文件不存在${NC}" && read -p "按回车键继续..." -r && return
            echo -e "${YELLOW}警告: 将覆盖当前配置${NC}"
            read -p "确认恢复? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                tar -xzf "$backup_dir/$backup_file" -C /
                echo -e "${GREEN}✓ 配置已恢复${NC}"
                reload_nginx_quiet
            fi
            ;;
        3)
            echo -e "${BLUE}备份列表:${NC}"
            ls -lh "$backup_dir/"*.tar.gz 2>/dev/null || echo -e "${YELLOW}暂无备份${NC}"
            local total_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
            local file_count=$(ls -1 "$backup_dir/"*.tar.gz 2>/dev/null | wc -l)
            [ "$file_count" -gt 0 ] && echo -e "\n统计: ${file_count}个文件，总大小: ${total_size}"
            ;;
        4)
            echo -e "${YELLOW}清理 7 天前的备份...${NC}"
            find "$backup_dir" -name "*.tar.gz" -mtime +7 -delete 2>/dev/null
            echo -e "${GREEN}✓ 清理完成${NC}"
            ;;
        5) return ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac

    echo ""
    read -p "按回车键继续..." -r
}

# ---------- 9. 生成测试页面 ----------
create_test_page() {
    local doc_root="$1"
    local site_name="$2"
    local port="$3"

    local web_user="nginx"
    ! id nginx &>/dev/null && web_user="www-data"

    cat > "$doc_root/index.html" << EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>欢迎访问 $site_name</title>
    <style>
        * { margin:0; padding:0; box-sizing:border-box; }
        body { font-family:-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background:linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height:100vh; display:flex; justify-content:center; align-items:center; padding:20px; }
        .container { background:rgba(255,255,255,0.95); border-radius:20px; padding:40px; box-shadow:0 20px 60px rgba(0,0,0,0.3); max-width:800px; width:100%; text-align:center; animation:fadeIn 0.8s ease-out; }
        @keyframes fadeIn { from { opacity:0; transform:translateY(20px); } to { opacity:1; transform:translateY(0); } }
        h1 { color:#2c3e50; margin-bottom:10px; font-size:2.5em; }
        .domain { color:#3498db; font-size:1.6em; margin-bottom:30px; font-weight:bold; word-break:break-all; }
        .info-box { background:#f8f9fa; border-radius:15px; padding:20px; margin:20px 0; text-align:left; border-left:5px solid #3498db; }
        .info-item { margin:10px 0; padding:8px 0; border-bottom:1px solid #eee; display:flex; justify-content:space-between; }
        .label { color:#7f8c8d; font-weight:600; flex:1; }
        .value { color:#2c3e50; font-weight:500; flex:2; text-align:right; }
        .ssl-badge { background:linear-gradient(45deg, #27ae60, #2ecc71); color:white; padding:10px 20px; border-radius:25px; display:inline-flex; align-items:center; gap:8px; margin:15px 0; }
        .system-info { background:#fff3cd; border-radius:10px; padding:15px; margin:15px 0; text-align:left; border-left:5px solid #ffc107; }
        .quick-links { display:flex; justify-content:center; gap:15px; margin-top:30px; flex-wrap:wrap; }
        .link-btn { padding:12px 25px; background:linear-gradient(45deg, #3498db, #2980b9); color:white; text-decoration:none; border-radius:10px; font-weight:600; transition:all 0.3s; border:none; cursor:pointer; }
        .link-btn:hover { transform:translateY(-3px); box-shadow:0 10px 20px rgba(52,152,219,0.3); }
        .time { margin-top:30px; color:#95a5a6; font-size:0.9em; }
        @media (max-width:600px) { .container { padding:20px; } h1 { font-size:2em; } .domain { font-size:1.3em; } .quick-links { flex-direction:column; } .link-btn { width:100%; } }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 站点已就绪</h1>
        <div class="domain">$site_name</div>
        <div class="ssl-badge">🔒 强制 HTTPS 已启用</div>
        <div class="info-box">
            <div class="info-item"><span class="label">访问协议:</span><span class="value">HTTPS (强制)</span></div>
            <div class="info-item"><span class="label">网站目录:</span><span class="value">$doc_root</span></div>
            <div class="info-item"><span class="label">服务器:</span><span class="value">Alpine Linux + Nginx</span></div>
        </div>
        <div class="system-info">
            <div>📦 操作系统: Alpine Linux</div>
            <div>🐧 Web用户: $web_user</div>
            <div>⚡ Nginx版本: $(nginx -v 2>&1 | cut -d/ -f2)</div>
        </div>
        <div class="quick-links">
            <button class="link-btn" onclick="location.reload()">刷新页面</button>
            <button class="link-btn" onclick="window.open('https://$site_name','_blank')">访问网站</button>
        </div>
        <div class="time">生成时间: <span id="current-time"></span></div>
    </div>
    <script>
        function updateTime() {
            const now = new Date();
            document.getElementById('current-time').textContent = now.toLocaleString('zh-CN');
        }
        updateTime();
        setInterval(updateTime, 1000);
    </script>
</body>
</html>
EOF

    chown -R "$web_user":"$web_user" "$doc_root"
    chmod -R 755 "$doc_root"
    echo -e "${GREEN}✓ 测试页面已创建${NC}"
}

generate_test_page() {
    show_banner
    echo -e "${CYAN}[9] 生成测试页面${NC}\n"

    list_sites_simple

    echo ""
    read -p "请输入站点名称 (留空使用第一个站点): " input_name

    local site_name=""
    if [ -z "$input_name" ]; then
        local first_conf
        first_conf=$(find "$SITES_AVAILABLE" -maxdepth 1 -name "*.conf" -type f 2>/dev/null | head -1)
        if [ -z "$first_conf" ]; then
            echo -e "${RED}没有可用的站点${NC}"
            read -p "按回车键继续..." -r
            return
        fi
        site_name=$(basename "$first_conf" .conf)
    else
        site_name=$(normalize_site_name "$input_name")
    fi

    local doc_root="/var/www/$site_name"
    if [ ! -d "$doc_root" ]; then
        echo -e "${YELLOW}网站目录不存在，是否创建? (y/N): " -n
        read -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            mkdir -p "$doc_root"
            local web_user="nginx"
            ! id nginx &>/dev/null && web_user="www-data"
            chown -R "$web_user":"$web_user" "$doc_root"
        else
            echo -e "${RED}取消操作${NC}"
            read -p "按回车键继续..." -r
            return
        fi
    fi

    create_test_page "$doc_root" "$site_name" "443"
    echo -e "${GREEN}✓ 测试页面已生成${NC}"
    echo -e "访问地址: https://$site_name"
    echo ""
    read -p "按回车键继续..." -r
}

# ---------- 主循环 ----------
main() {
    init_check
    while true; do
        show_banner
        show_menu
        read -p "请输入选项 [0-9]: " choice
        echo ""
        case $choice in
            1) create_site ;;
            2) delete_site ;;
            3) reload_nginx ;;
            4) view_certificates ;;
            5) view_sites ;;
            6) install_nginx ;;
            7) manage_service ;;
            8) backup_restore ;;
            9) generate_test_page ;;
            0) echo -e "${GREEN}感谢使用，再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

main