#!/bin/bash 
# nginx-manager.sh - Nginx 交互式管理工具 (Alpine Linux) - Cloudflare 强制HTTPS版

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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
DOMAIN=""  # 主域名，从证书获取
CERT_FILE=""  # 证书文件路径
KEY_FILE=""   # 私钥文件路径

# 检查并安装依赖
install_deps() {
    local deps=("nginx" "openssl" "curl" "tree" "apk")
    
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            echo -e "${YELLOW}安装 $dep...${NC}"
            apk add --no-cache $dep
        fi
    done
}

# 初始化检查
init_check() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}请使用 root 权限运行此脚本${NC}"
        exit 1
    fi
    
    # 安装依赖
    install_deps
    
    # 创建必要的目录 (Alpine Linux 默认目录结构)
    mkdir -p "$SITES_AVAILABLE"
    mkdir -p "$SITES_ENABLED"
    mkdir -p "$SSL_DIR"
    mkdir -p "$CERTS_DIR"
    mkdir -p "$PRIVATE_DIR"
    mkdir -p "$WWW_ROOT"
    mkdir -p "$LOG_DIR"
    
    # 设置权限
    chown -R nginx:nginx "$WWW_ROOT" 2>/dev/null || chown -R www-data:www-data "$WWW_ROOT" 2>/dev/null
    
    # 自动创建证书软链接（如果证书存在但软链接缺失）
    auto_create_cert_links
    
    # 检测主域名（从现有证书获取）
    detect_domain
}

# 自动创建证书软链接（如果证书存在但软链接缺失）
auto_create_cert_links() {
    echo -e "${BLUE}检查证书软链接...${NC}"
    
    # 查找实际的证书文件
    local actual_cert=""
    local actual_key=""
    local domain_name=""
    
    # 1. 先在 Nginx SSL 目录查找
    actual_cert=$(find "$CERTS_DIR" -name "fullchain.pem" -o -name "cert.pem" 2>/dev/null | head -1)
    
    # 2. 如果没找到，从 acme.sh 目录查找
    if [ -z "$actual_cert" ]; then
        echo -e "${YELLOW}在 Nginx 目录未找到证书，尝试从 acme.sh 查找...${NC}"
        
        # 查找 acme.sh 目录下的证书
        local acme_cert=$(find /root/.acme.sh -name "fullchain.cer" -o -name "fullchain.pem" 2>/dev/null | grep -v "ca" | head -1)
        
        if [ -n "$acme_cert" ]; then
            actual_cert="$acme_cert"
            echo -e "${GREEN}从 acme.sh 找到证书: $actual_cert${NC}"
            
            # 提取域名（从路径或证书中）
            domain_name=$(echo "$acme_cert" | grep -oP '(?<=/root/.acme.sh/)[^/]+' | head -1)
            domain_name=$(echo "$domain_name" | sed 's/_ecc$//' | sed 's/\.$//')
            
            # 查找对应的私钥
            local cert_dir=$(dirname "$acme_cert")
            actual_key=$(find "$cert_dir" -name "*.key" 2>/dev/null | head -1)
            
            if [ -n "$actual_key" ] && [ -f "$actual_key" ]; then
                echo -e "${GREEN}找到私钥: $actual_key${NC}"
                
                # 创建 Nginx 证书目录并复制/链接证书
                mkdir -p "$CERTS_DIR/$domain_name"
                mkdir -p "$PRIVATE_DIR/$domain_name"
                
                # 创建软链接指向 acme.sh 的证书
                ln -sf "$actual_cert" "$CERTS_DIR/$domain_name/fullchain.pem"
                ln -sf "$actual_key" "$PRIVATE_DIR/$domain_name/key.pem"
                
                # 更新实际证书路径为软链接路径
                actual_cert="$CERTS_DIR/$domain_name/fullchain.pem"
                actual_key="$PRIVATE_DIR/$domain_name/key.pem"
                
                echo -e "${GREEN}✓ 已创建证书软链接到 Nginx 目录${NC}"
            fi
        fi
    fi
    
    # 如果还是没找到，退出
    if [ -z "$actual_cert" ] || [ ! -f "$actual_cert" ]; then
        echo -e "${YELLOW}未找到证书文件，跳过软链接创建${NC}"
        return 1
    fi
    
    # 获取域名（如果还没有）
    if [ -z "$domain_name" ]; then
        local cert_dir=$(dirname "$actual_cert")
        domain_name=$(basename "$cert_dir")
    fi
    
    # 查找私钥（如果还没有）
    if [ -z "$actual_key" ] || [ ! -f "$actual_key" ]; then
        # 尝试从证书路径推断
        local possible_key="$PRIVATE_DIR/$domain_name/key.pem"
        if [ -f "$possible_key" ]; then
            actual_key="$possible_key"
        else
            actual_key=$(find "$PRIVATE_DIR" -name "key.pem" 2>/dev/null | head -1)
        fi
    fi
    
    if [ -z "$actual_key" ] || [ ! -f "$actual_key" ]; then
        echo -e "${YELLOW}未找到私钥文件，跳过软链接创建${NC}"
        return 1
    fi
    
    echo -e "${GREEN}最终证书: $actual_cert${NC}"
    echo -e "${GREEN}最终私钥: $actual_key${NC}"
    echo -e "${GREEN}域名: $domain_name${NC}"
    
    # 创建缺失的软链接
    local links_created=0
    
    # 创建 default.crt
    if [ ! -L "$CERTS_DIR/default.crt" ] && [ ! -f "$CERTS_DIR/default.crt" ]; then
        # 确保使用正确的绝对路径
        local target_path=$(readlink -f "$actual_cert" 2>/dev/null || echo "$actual_cert")
        ln -sf "$target_path" "$CERTS_DIR/default.crt"
        echo -e "${GREEN}✓ 创建软链接: $CERTS_DIR/default.crt -> $target_path${NC}"
        links_created=$((links_created + 1))
    fi
    
    # 创建 default.key
    if [ ! -L "$PRIVATE_DIR/default.key" ] && [ ! -f "$PRIVATE_DIR/default.key" ]; then
        ln -sf "$actual_key" "$PRIVATE_DIR/default.key"
        echo -e "${GREEN}✓ 创建软链接: $PRIVATE_DIR/default.key -> $actual_key${NC}"
        links_created=$((links_created + 1))
    fi
    
    # 创建 wildcard.crt
    if [ ! -L "$CERTS_DIR/wildcard.crt" ] && [ ! -f "$CERTS_DIR/wildcard.crt" ]; then
        ln -sf "$actual_cert" "$CERTS_DIR/wildcard.crt"
        echo -e "${GREEN}✓ 创建软链接: $CERTS_DIR/wildcard.crt -> $actual_cert${NC}"
        links_created=$((links_created + 1))
    fi
    
    # 创建 wildcard.key
    if [ ! -L "$PRIVATE_DIR/wildcard.key" ] && [ ! -f "$PRIVATE_DIR/wildcard.key" ]; then
        ln -sf "$actual_key" "$PRIVATE_DIR/wildcard.key"
        echo -e "${GREEN}✓ 创建软链接: $PRIVATE_DIR/wildcard.key -> $actual_key${NC}"
        links_created=$((links_created + 1))
    fi
    
    # 创建域名简写软链接
    if [ ! -L "$CERTS_DIR/$domain_name.crt" ] && [ ! -f "$CERTS_DIR/$domain_name.crt" ]; then
        ln -sf "$actual_cert" "$CERTS_DIR/$domain_name.crt"
        echo -e "${GREEN}✓ 创建软链接: $CERTS_DIR/$domain_name.crt -> $actual_cert${NC}"
        links_created=$((links_created + 1))
    fi
    
    if [ ! -L "$PRIVATE_DIR/$domain_name.key" ] && [ ! -f "$PRIVATE_DIR/$domain_name.key" ]; then
        ln -sf "$actual_key" "$PRIVATE_DIR/$domain_name.key"
        echo -e "${GREEN}✓ 创建软链接: $PRIVATE_DIR/$domain_name.key -> $actual_key${NC}"
        links_created=$((links_created + 1))
    fi
    
    if [ $links_created -gt 0 ]; then
        echo -e "${GREEN}✓ 已创建 $links_created 个证书软链接${NC}"
    else
        echo -e "${GREEN}✓ 所有证书软链接已存在${NC}"
    fi
    
    return 0
}

detect_domain() {
    echo -e "${BLUE}正在检测 SSL 证书...${NC}"
    
    # 优先检查软链接（证书申请脚本创建的）
    local cert_candidates=(
        "$CERTS_DIR/default.crt"
        "$CERTS_DIR/wildcard.crt"
        "$(find "$CERTS_DIR" -maxdepth 1 -type l -name "*.crt" 2>/dev/null | head -1)"
        "$(find "$CERTS_DIR" -maxdepth 1 -name "*.crt" -type f 2>/dev/null | head -1)"
    )
    
    local found_cert=""
    for cert in "${cert_candidates[@]}"; do
        if [ -n "$cert" ] && [ -e "$cert" ]; then
            if [ -L "$cert" ]; then
                # 如果是软链接，获取真实路径
                found_cert=$(readlink -f "$cert")
                echo -e "${GREEN}找到证书软链接: $(basename "$cert") -> $(basename "$found_cert")${NC}"
            else
                found_cert="$cert"
                echo -e "${GREEN}找到证书: $(basename "$cert")${NC}"
            fi
            break
        fi
    done
    
    # 如果没找到，尝试查找所有子目录中的证书
    if [ -z "$found_cert" ]; then
        found_cert=$(find "$CERTS_DIR" -name "fullchain.pem" -o -name "cert.pem" 2>/dev/null | head -1)
        if [ -n "$found_cert" ]; then
            echo -e "${GREEN}找到证书: $found_cert${NC}"
        fi
    fi
    
    # 如果找到证书，设置变量
    if [ -n "$found_cert" ] && [ -f "$found_cert" ]; then
        CERT_FILE="$found_cert"
        
        # 查找私钥（优先使用软链接）
        local key_candidates=(
            "$PRIVATE_DIR/default.key"
            "$PRIVATE_DIR/wildcard.key"
            "$(find "$PRIVATE_DIR" -maxdepth 1 -type l -name "*.key" 2>/dev/null | head -1)"
            "$(find "$PRIVATE_DIR" -maxdepth 1 -name "*.key" -type f 2>/dev/null | head -1)"
        )
        
        for key in "${key_candidates[@]}"; do
            if [ -n "$key" ] && [ -f "$key" ]; then
                if [ -L "$key" ]; then
                    KEY_FILE=$(readlink -f "$key")
                    echo -e "${GREEN}找到私钥软链接: $(basename "$key") -> $(basename "$KEY_FILE")${NC}"
                else
                    KEY_FILE="$key"
                    echo -e "${GREEN}找到私钥: $(basename "$key")${NC}"
                fi
                break
            fi
        done
        
        # 如果还没找到，尝试从证书路径推断
        if [ -z "$KEY_FILE" ]; then
            local cert_dir=$(dirname "$found_cert")
            local domain_name=$(basename "$cert_dir")
            local possible_key="$PRIVATE_DIR/$domain_name/key.pem"
            if [ -f "$possible_key" ]; then
                KEY_FILE="$possible_key"
                echo -e "${GREEN}找到私钥: $possible_key${NC}"
            fi
        fi
        
        # 从证书提取域名
        DOMAIN=$(openssl x509 -in "$found_cert" -text -noout 2>/dev/null | grep -o "DNS:\*\.\?[^,]*" | head -1 | cut -d: -f2 | sed 's/\*\.//')
        
        if [ -z "$DOMAIN" ]; then
            # 尝试从软链接或文件名提取
            DOMAIN=$(basename "$found_cert" | sed 's/\.crt$//' | sed 's/\.pem$//')
            # 如果还是空，尝试从路径提取
            if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "fullchain" ] || [ "$DOMAIN" = "cert" ]; then
                DOMAIN=$(basename "$(dirname "$found_cert")")
            fi
        fi
        
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

# 显示横幅
show_banner() {
    clear
    echo -e "${PURPLE}============================================${NC}"
    echo -e "${CYAN}    Nginx 管理工具 - Alpine Linux 版${NC}"
    echo -e "${PURPLE}============================================${NC}"
    
    if [ -n "$DOMAIN" ]; then
        echo -e "${GREEN}主域名: $DOMAIN${NC}"
        if [ -f "$CERT_FILE" ]; then
            echo -e "${GREEN}证书: $(basename "$CERT_FILE")${NC}"
        fi
        if [ -f "$KEY_FILE" ]; then
            echo -e "${GREEN}私钥: $(basename "$KEY_FILE")${NC}"
        fi
    else
        echo -e "${RED}未检测到证书，请先申请 SSL 证书${NC}"
    fi
    
    # Alpine Linux 服务状态检查
    local nginx_status=""
    if command -v rc-service &> /dev/null; then
        nginx_status=$(rc-service nginx status 2>/dev/null | grep -o "started\|stopped" || echo "未知")
    elif pgrep nginx > /dev/null; then
        nginx_status="运行中"
    else
        nginx_status="未运行"
    fi
    
    if [[ "$nginx_status" =~ "started"|"运行中" ]]; then
        echo -e "${GREEN}Nginx 状态: 运行中${NC}"
    else
        echo -e "${RED}Nginx 状态: $nginx_status${NC}"
    fi
    
    # 显示站点统计
    local site_count=0
    local enabled_count=0
    
    if [ -d "$SITES_AVAILABLE" ]; then
        site_count=$(ls -1 "$SITES_AVAILABLE" 2>/dev/null | wc -l)
    fi
    
    if [ -d "$SITES_ENABLED" ]; then
        enabled_count=$(ls -1 "$SITES_ENABLED" 2>/dev/null | wc -l)
    fi
    
    echo -e "${BLUE}站点统计: ${site_count}个配置 (${enabled_count}个启用)${NC}"
    
    echo ""
}

# 显示菜单
show_menu() {
    echo -e "${BLUE}请选择操作:${NC}"
    echo -e "  ${GREEN}1${NC}) 创建新站点 (强制 HTTPS)"
    echo -e "  ${GREEN}2${NC}) 删除站点"
    echo -e "  ${GREEN}3${NC}) 重载 Nginx 配置"
    echo -e "  ${GREEN}4${NC}) 查看 SSL 证书"
    echo -e "  ${GREEN}5${NC}) 查看所有站点"
    echo -e "  ${GREEN}6${NC}) 一键安装/更新 Nginx"
    echo -e "  ${GREEN}7${NC}) 启动/停止 Nginx 服务"
    echo -e "  ${GREEN}0${NC}) 退出"
    echo ""
}

# 1. 创建新站点 - 强制 HTTPS 版
create_site() {
    show_banner
    echo -e "${CYAN}[1] 创建新站点 (强制 HTTPS)${NC}"
    echo ""
    
    # 变量定义
    local IS_REVERSE_PROXY=true  # 默认反向代理
    local BACKEND_ADDRESS=""
    local SITE_NAME=""
    local SERVER_NAME=""
    local DOCUMENT_ROOT=""
    local CONFIG_FILE=""
    
    # 检查证书
    if [ -z "$DOMAIN" ] || [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        echo -e "${RED}错误: SSL 证书未检测到${NC}"
        echo -e "请先申请证书："
        echo -e "bash <(curl -fsSL https://raw.githubusercontent.com/penggan00/rss/main/https.sh)"
        echo -e ""
        read -p "按回车键返回主菜单..." -r
        return
    fi
    
    echo -e "${GREEN}主域名: $DOMAIN${NC}"
    echo ""
    
    # 获取子域名
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
            echo -e "${RED}子域名格式不正确，只能包含字母、数字和减号${NC}"
        fi
    done
    
    # 获取后端端口
    echo ""
    echo -e "${YELLOW}反向代理配置${NC}"
    echo -e "默认代理到本地服务 (127.0.0.1)"

    while true; do
        read -p "请输入后端服务端口号 (如 8080, 3000, 9000): " BACKEND_PORT
        
        if [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] && [ "$BACKEND_PORT" -ge 1 ] && [ "$BACKEND_PORT" -le 65535 ]; then
            BACKEND_ADDRESS="127.0.0.1:$BACKEND_PORT"
            echo -e "${GREEN}后端地址: $BACKEND_ADDRESS${NC}"
            break
        elif [ -z "$BACKEND_PORT" ]; then
            echo -e "${RED}端口号不能为空${NC}"
        else
            echo -e "${RED}端口号必须是 1-65535 的数字${NC}"
        fi
    done
    
    # 创建配置文件
    CONFIG_FILE="$SITES_AVAILABLE/$SITE_NAME.conf"
    
# 在 create_site() 函数中，替换配置文件生成部分：
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

   # ssl_session_cache shared:SSL:10m;
  #  ssl_session_timeout 10m;
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
    
    # 启用站点
    enable_site "$SITE_NAME.conf"
    
    echo ""
    echo -e "${CYAN}站点创建完成!${NC}"
    echo -e "${BLUE}配置类型:${NC} 反向代理"
    echo -e "${BLUE}后端地址:${NC} http://$BACKEND_ADDRESS"
    echo -e "${BLUE}本地服务:${NC} 请确保本地服务已在端口 $BACKEND_PORT 运行"
    
    echo -e "${BLUE}监听配置:${NC}"
    echo -e "  ${GREEN}HTTP (80):${NC} 监听所有 IPv4/IPv6 接口"
    echo -e "  ${GREEN}HTTPS (443):${NC} 监听所有 IPv4/IPv6 接口"
    echo -e "  ${YELLOW}安全设置:${NC} 拒绝 IP 直接访问，只能通过域名访问"
    
    echo -e "${BLUE}访问地址:${NC}"
    echo -e "  ${GREEN}HTTPS: https://$SITE_NAME${NC}"
    echo -e "  ${YELLOW}HTTP: http://$SITE_NAME (自动强制重定向到 HTTPS)${NC}"
    
    echo ""
    echo -e "${YELLOW}提醒:${NC} 请确保后端服务已启动并在端口 ${BACKEND_PORT} 监听"
    echo -e "      可以使用命令检查: ${CYAN}ss -tulpn | grep :$BACKEND_PORT${NC}"
    
    echo ""
    read -p "按回车键继续..." -r
}


# 启用站点
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
    
    # 检查配置并重载
    reload_nginx_quiet
}

# 2. 删除站点
delete_site() {
    show_banner
    echo -e "${CYAN}[2] 删除站点${NC}"
    echo ""
    
    list_sites_simple
    
    echo ""
    read -p "请输入要删除的站点配置名: " config_name
    
    if [ -z "$config_name" ]; then
        echo -e "${RED}未指定站点名称${NC}"
        read -p "按回车键继续..." -r
        return
    fi
    
    # 确保有 .conf 后缀
    if [[ ! "$config_name" == *.conf ]]; then
        config_name="$config_name.conf"
    fi
    
    local config_file="$SITES_AVAILABLE/$config_name"
    local enabled_link="$SITES_ENABLED/$config_name"
    local site_name="${config_name%.*}"
    local doc_root="/var/www/$site_name"
    
    if [ ! -f "$config_file" ]; then
        echo -e "${RED}站点不存在: $site_name${NC}"
        read -p "按回车键继续..." -r
        return
    fi
    
    echo ""
    echo -e "${YELLOW}即将删除以下内容:${NC}"
    echo -e "  配置文件: $config_file"
    if [ -L "$enabled_link" ]; then
        echo -e "  启用链接: $enabled_link"
    fi
    if [ -d "$doc_root" ]; then
        echo -e "  网站目录: $doc_root"
    fi
    
    echo ""
    read -p "确认删除? (Y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}取消删除${NC}"
        read -p "按回车键继续..." -r
        return
    fi
    
    # 禁用站点
    if [ -L "$enabled_link" ]; then
        rm -f "$enabled_link"
        echo -e "${GREEN}✓ 已移除启用链接${NC}"
    fi
    
    # 删除配置文件
    rm -f "$config_file"
    echo -e "${GREEN}✓ 已删除配置文件${NC}"
    
    # 删除网站目录（如果存在）
    if [ -d "$doc_root" ]; then
        rm -rf "$doc_root"
        echo -e "${GREEN}✓ 已删除网站目录${NC}"
    fi
    
    # 重载配置
    reload_nginx_quiet
    
    echo ""
    echo -e "${GREEN}站点删除完成${NC}"
    read -p "按回车键继续..." -r
}

# 3. 重载 Nginx 配置 (Alpine Linux 适配)
reload_nginx() {
    show_banner
    echo -e "${CYAN}[3] 重载 Nginx 配置${NC}"
    echo ""
    
    echo -e "${BLUE}检查 Nginx 配置语法...${NC}"
    if nginx -t 2>&1; then
        echo -e "${GREEN}配置语法正确${NC}"
        echo ""
        echo -e "${BLUE}重新加载 Nginx...${NC}"
        
        # Alpine Linux 服务管理方式
        if command -v rc-service &> /dev/null; then
            rc-service nginx reload 2>/dev/null || nginx -s reload
        elif [ -f "/run/nginx/nginx.pid" ]; then
            nginx -s reload
        else
            # 尝试重启
            nginx -s quit 2>/dev/null
            sleep 1
            nginx
        fi
        
        if pgrep nginx > /dev/null; then
            echo -e "${GREEN}✓ Nginx 配置已重新加载${NC}"
        else
            echo -e "${RED}✗ Nginx 重载失败${NC}"
        fi
    else
        echo -e "${RED}配置语法错误，请检查配置文件${NC}"
    fi
    
    echo ""
    read -p "按回车键继续..." -r
}

# 静默重载
reload_nginx_quiet() {
    if nginx -t >/dev/null 2>&1; then
        if command -v rc-service &> /dev/null; then
            rc-service nginx reload >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1
        else
            nginx -s reload >/dev/null 2>&1
        fi
        return 0
    else
        return 1
    fi
}

# 4. 查看 SSL 证书
view_certificates() {
    show_banner
    echo -e "${CYAN}[4] SSL 证书信息${NC}"
    echo ""

    if [ -z "$CERT_FILE" ] || [ ! -f "$CERT_FILE" ]; then
        echo -e "${YELLOW}未找到 SSL 证书${NC}"
        read -p "按回车键继续..." -r
        return
    fi

    echo -e "${GREEN}证书文件: $(basename "$CERT_FILE")${NC}"
    if [ -f "$KEY_FILE" ]; then
        echo -e "${GREEN}私钥文件: $(basename "$KEY_FILE")${NC}"
    fi
    echo ""

    echo -e "${BLUE}证书信息:${NC}"
    openssl x509 -in "$CERT_FILE" -text -noout 2>/dev/null \
        | grep -E "Subject:|Issuer:|Not Before:|Not After:|Signature Algorithm:|DNS:" \
        | head -10 || echo "无法解析证书"

    echo -e "\n${BLUE}有效性检查:${NC}"

    # 使用 OpenSSL 官方方式判断是否过期（权威、不会误判）
    if openssl x509 -checkend 0 -noout -in "$CERT_FILE" >/dev/null 2>&1; then
        # 仅用于显示剩余天数（不参与生死判断）
        local expiry_epoch
        expiry_epoch=$(openssl x509 -in "$CERT_FILE" -enddate -noout \
            | cut -d= -f2 \
            | xargs -I{} date -u -d "{}" +%s 2>/dev/null)

        local now_epoch
        now_epoch=$(date -u +%s)

        local days_left
        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        if [ "$days_left" -le 30 ]; then
            echo -e "  ${YELLOW}⚠ 证书即将过期，剩余 ${days_left} 天${NC}"
        else
            echo -e "  ${GREEN}✓ 证书有效，剩余 ${days_left} 天${NC}"
        fi
    else
        echo -e "  ${RED}✗ 证书已过期${NC}"
    fi

    echo ""
    echo -e "${BLUE}证书路径:${NC}"
    echo "  证书: $CERT_FILE"
    if [ -f "$KEY_FILE" ]; then
        echo "  私钥: $KEY_FILE"
    fi

    echo ""
    read -p "按回车键继续..." -r
}

# 5. 查看所有站点
view_sites() {
    show_banner
    echo -e "${CYAN}[5] 所有站点列表${NC}"
    echo ""
    
    list_sites_detailed
    
    echo ""
    read -p "按回车键继续..." -r
}

# 简单列出站点
list_sites_simple() {
    echo -e "${BLUE}可用站点:${NC}"
    if [ ! -d "$SITES_AVAILABLE" ] || [ -z "$(ls -A "$SITES_AVAILABLE")" ]; then
        echo -e "  ${YELLOW}暂无站点配置${NC}"
    else
        for config in "$SITES_AVAILABLE"/*.conf; do
            if [ -f "$config" ]; then
                local site_name=$(basename "$config" .conf)
                if [ -L "$SITES_ENABLED/$site_name.conf" ]; then
                    echo -e "  ${GREEN}✓ $site_name${NC}"
                else
                    echo -e "  ${YELLOW}○ $site_name${NC}"
                fi
            fi
        done
    fi
}

# 详细列出站点
list_sites_detailed() {
    echo -e "${BLUE}站点状态概览:${NC}"
    echo ""
    
    if [ ! -d "$SITES_AVAILABLE" ] || [ -z "$(ls -A "$SITES_AVAILABLE")" ]; then
        echo -e "  ${YELLOW}暂无站点配置${NC}"
        return
    fi
    
    echo "站点名称                       状态     端口        协议        配置位置"
    echo "----------------------------------------------------------------------------------------------------"
    
    for config in "$SITES_AVAILABLE"/*.conf; do
        if [ -f "$config" ]; then
            local site_name=$(basename "$config" .conf)
            local enabled="否"
            local ports=""
            local protocol="HTTP"
            
            if [ -L "$SITES_ENABLED/$site_name.conf" ]; then
                enabled="是"
            fi
            
            # 解析配置文件获取端口
            if grep -q "listen 443" "$config"; then
                ports="80,443"
                protocol="HTTPS"
            elif grep -q "listen 80" "$config"; then
                ports="80"
                protocol="HTTP"
            fi
            
            printf "%-30s %-8s %-12s %-12s %s\n" "$site_name" "$enabled" "$ports" "$protocol" "$config"
        fi
    done
    
    echo ""
    echo -e "${BLUE}监听端口:${NC}"
    if command -v ss &> /dev/null; then
        ss -tulpn | grep nginx 2>/dev/null || echo -e "  ${YELLOW}Nginx 未运行或未监听端口${NC}"
    elif command -v netstat &> /dev/null; then
        netstat -tulpn | grep nginx 2>/dev/null || echo -e "  ${YELLOW}Nginx 未运行或未监听端口${NC}"
    else
        echo -e "  ${YELLOW}无法获取端口信息${NC}"
    fi
}

# 6. 一键安装 Nginx (Alpine Linux 适配)
# 6. 一键安装 Nginx (Alpine Linux 适配)
install_nginx() {
    show_banner
    echo -e "${CYAN}[6] 安装/更新 Nginx${NC}"
    echo ""
    
    # 检查 Nginx 是否运行
    if pgrep nginx > /dev/null; then
        echo -e "${YELLOW}Nginx 已安装且正在运行${NC}"
        read -p "是否重新安装? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return
        fi
    fi
    
    echo -e "${BLUE}开始安装 Nginx...${NC}"
    echo ""
    
    # 1. 停止现有 Nginx
    echo "1. 停止现有 Nginx 进程..."
    pkill nginx 2>/dev/null || true
    sleep 2
    
    # 2. 安装 Nginx
    echo "2. 安装 Nginx..."
    apk update
    apk add --no-cache nginx nginx-openrc
    
    # 3. 确保 nginx 用户存在
    echo "3. 确保 nginx 用户存在..."
    if ! id nginx &>/dev/null; then
        adduser -D -H -s /sbin/nologin nginx
        echo -e "${GREEN}✓ nginx 用户已创建${NC}"
    fi
    
    # 4. 创建必要的目录结构
    echo "4. 创建目录结构..."
    mkdir -p "$SITES_AVAILABLE"
    mkdir -p "$SITES_ENABLED"
    mkdir -p "$SSL_DIR"
    mkdir -p "$CERTS_DIR"
    mkdir -p "$PRIVATE_DIR"
    mkdir -p "$WWW_ROOT"
    mkdir -p "$LOG_DIR"
    mkdir -p "/run/nginx"
    
    # 5. 设置权限
    echo "5. 设置目录权限..."
    chown -R nginx:nginx "$WWW_ROOT" 2>/dev/null || chown -R www-data:www-data "$WWW_ROOT" 2>/dev/null
    chmod 755 "$WWW_ROOT"
    
    # 6. 启动 Nginx 服务
    echo "6. 启动 Nginx 服务..."
    if command -v rc-update &> /dev/null; then
        rc-update add nginx default 2>/dev/null || true
        rc-service nginx start
    else
        nginx
    fi
    
    # 7. 检测域名和证书
    echo "7. 检测域名和证书..."
    detect_domain
    
    echo ""
    echo -e "${GREEN}✓ Nginx 安装完成!${NC}"
    echo -e "版本: $(nginx -v 2>&1 | cut -d/ -f2)"
    
    if pgrep nginx > /dev/null; then
        echo -e "状态: ${GREEN}运行中${NC}"
    else
        echo -e "状态: ${RED}未运行${NC}"
        echo -e "${YELLOW}提示: 可能需要检查 /etc/nginx/nginx.conf 配置文件${NC}"
    fi
    
    echo -e "配置文件目录: $NGINX_DIR"
    echo -e "站点配置目录: $SITES_AVAILABLE"
    echo ""
    
    read -p "按回车键继续..." -r
}

# 主循环
main() {
    # 初始化检查
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
            0)
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}

# 运行主函数
main