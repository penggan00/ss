#!/bin/bash
# nginx-manager.sh - Nginx 交互式管理工具 (Debian 12+) - Cloudflare 强制HTTPS版

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 路径定义
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

# 初始化检查
init_check() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}请使用 sudo 运行此脚本${NC}"
        exit 1
    fi
    
    # 创建必要的目录
    mkdir -p "$SITES_AVAILABLE"
    mkdir -p "$SITES_ENABLED"
    mkdir -p "$SSL_DIR"
    mkdir -p "$CERTS_DIR"
    mkdir -p "$PRIVATE_DIR"
    mkdir -p "$WWW_ROOT"
    mkdir -p "$LOG_DIR"
    
    # 检测主域名（从现有证书获取）
    detect_domain
}

# 检测主域名
detect_domain() {
    echo -e "${BLUE}正在检测 SSL 证书...${NC}"
    
    # 优先查找标准名称
    local found_cert=""
    local cert_candidates=(
        "$CERTS_DIR/default.crt"
        "$CERTS_DIR/wildcard.crt"
        "$(find "$CERTS_DIR" -maxdepth 1 -name "*.crt" -type f | head -1)"
    )
    
    for cert in "${cert_candidates[@]}"; do
        if [ -f "$cert" ]; then
            found_cert="$cert"
            echo -e "${GREEN}找到证书: $(basename "$cert")${NC}"
            break
        fi
    done
    
    if [ -n "$found_cert" ] && [ -f "$found_cert" ]; then
        CERT_FILE="$found_cert"
        
        # 尝试查找对应的私钥
        local cert_name=$(basename "$found_cert" .crt)
        local key_candidates=(
            "$PRIVATE_DIR/default.key"
            "$PRIVATE_DIR/wildcard.key"
            "$PRIVATE_DIR/$cert_name.key"
            "$(find "$PRIVATE_DIR" -maxdepth 1 -name "*.key" -type f | head -1)"
        )
        
        for key in "${key_candidates[@]}"; do
            if [ -f "$key" ]; then
                KEY_FILE="$key"
                echo -e "${GREEN}找到私钥: $(basename "$key")${NC}"
                break
            fi
        done
        
        # 从证书提取域名
        DOMAIN=$(openssl x509 -in "$found_cert" -text -noout 2>/dev/null | grep -o "DNS:\*\.\?[^,]*" | head -1 | cut -d: -f2 | sed 's/\*\.//')
        
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
    echo -e "${CYAN}    Nginx 管理工具 - 强制 HTTPS 版${NC}"
    echo -e "${PURPLE}============================================${NC}"
    
    if [ -n "$DOMAIN" ]; then
        echo -e "${GREEN}主域名: $DOMAIN${NC}"
        echo -e "${GREEN}证书: $(basename "$CERT_FILE")${NC}"
        echo -e "${GREEN}私钥: $(basename "$KEY_FILE")${NC}"
    else
        echo -e "${RED}未检测到证书，请先申请 SSL 证书${NC}"
    fi
    
    local nginx_status=$(systemctl is-active nginx 2>/dev/null || echo "未安装")
    if [ "$nginx_status" = "active" ]; then
        echo -e "${GREEN}Nginx 状态: 运行中${NC}"
    else
        echo -e "${RED}Nginx 状态: $nginx_status${NC}"
    fi
    
    # 显示站点统计
    local site_count=$(ls -1 "$SITES_AVAILABLE" 2>/dev/null | wc -l)
    local enabled_count=$(ls -1 "$SITES_ENABLED" 2>/dev/null | wc -l)
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
    echo -e "  ${GREEN}8${NC}) 备份/恢复配置"
    echo -e "  ${GREEN}9${NC}) 生成测试页面"
    echo -e "  ${GREEN}0${NC}) 退出"
    echo ""
}

# 1. 创建新站点 - 强制 HTTPS 版
create_site() {
    show_banner
    echo -e "${CYAN}[1] 创建新站点 (强制 HTTPS)${NC}"
    echo ""
    
    # 变量定义
    local IS_REVERSE_PROXY=false
    local BACKEND_ADDRESS=""
    local SITE_NAME=""
    local SERVER_NAME=""
    local PORT=""
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
    
    # 获取端口（默认 443）
    while true; do
        read -p "请输入 HTTPS 端口 (默认 443): " PORT
        PORT=${PORT:-443}
        
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
            if ss -tulpn | grep -q ":$PORT "; then
                local service=$(ss -tulpn | grep ":$PORT " | awk '{print $NF}')
                echo -e "${YELLOW}端口 $PORT 已被占用: $service${NC}"
                read -p "是否继续? (y/N): " -n 1 -r
                echo
                [[ $REPLY =~ ^[Yy]$ ]] || continue
            fi
            break
        else
            echo -e "${RED}端口号必须是 1-65535 的数字${NC}"
        fi
    done
    
    # 询问是否反向代理
    echo ""
    read -p "是否是反向代理到其他服务? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        IS_REVERSE_PROXY=true
        while true; do
            read -p "请输入后端服务地址 (如 127.0.0.1:8080): " BACKEND_ADDRESS
            if [[ "$BACKEND_ADDRESS" =~ ^[a-zA-Z0-9.-]+:[0-9]+$ ]] || [[ "$BACKEND_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
                echo -e "${GREEN}后端地址: $BACKEND_ADDRESS${NC}"
                break
            else
                echo -e "${RED}格式错误，正确格式: IP:端口 或 域名:端口${NC}"
            fi
        done
    else
        IS_REVERSE_PROXY=false
        BACKEND_ADDRESS=""
    fi
    
    # 网站根目录
    DOCUMENT_ROOT="$WWW_ROOT/$SITE_NAME"
    
    # 创建目录
    echo -e "${BLUE}创建网站目录...${NC}"
    mkdir -p "$DOCUMENT_ROOT"
    chown -R www-data:www-data "$DOCUMENT_ROOT"
    chmod 755 "$DOCUMENT_ROOT"
    
    # 创建配置文件
    CONFIG_FILE="$SITES_AVAILABLE/$SITE_NAME"
    
    if $IS_REVERSE_PROXY; then
        # 生成反向代理配置
        cat > "$CONFIG_FILE" << EOF
# 自动生成 - $(date)
# 站点: $SITE_NAME
# 反向代理到: $BACKEND_ADDRESS

# HTTP 重定向到 HTTPS（强制所有 HTTP 流量转到 HTTPS）
server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAME;
    
    # 301 永久重定向到 HTTPS
    return 301 https://\$server_name\$request_uri;
}

# HTTPS 服务器 - 反向代理
server {
    listen $PORT ssl http2;
    listen [::]:$PORT ssl http2;
    server_name $SERVER_NAME;
    
    # SSL 证书
    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    
    # SSL 安全配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # HSTS 强制 HTTPS
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # 访问日志
    access_log $LOG_DIR/${SITE_NAME}-access.log;
    error_log $LOG_DIR/${SITE_NAME}-error.log;
    
    # 反向代理配置
    location / {
        proxy_pass http://$BACKEND_ADDRESS;
        
        # 重要请求头
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 超时设置
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # 静态文件缓存
    location ~* \\.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)\$ {
        proxy_pass http://$BACKEND_ADDRESS;
        proxy_set_header Host \$host;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
    
    # 禁止访问隐藏文件
    location ~ /\\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF
    else
        # 生成静态站点配置
        cat > "$CONFIG_FILE" << EOF
# 自动生成 - $(date)
# 站点: $SITE_NAME
# 强制 HTTPS 配置

# HTTP 重定向到 HTTPS（强制所有 HTTP 流量转到 HTTPS）
server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAME;
    
    # 301 永久重定向到 HTTPS
    return 301 https://\$server_name\$request_uri;
}

# HTTPS 服务器
server {
    listen $PORT ssl http2;
    listen [::]:$PORT ssl http2;
    server_name $SERVER_NAME;
    
    # SSL 证书
    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    
    # SSL 安全配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # HSTS 强制 HTTPS
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # 网站根目录
    root $DOCUMENT_ROOT;
    index index.html index.htm index.php;
    
    # 访问日志
    access_log $LOG_DIR/${SITE_NAME}-access.log;
    error_log $LOG_DIR/${SITE_NAME}-error.log;
    
    # 安全设置
    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }
    
    location = /robots.txt {
        log_not_found off;
        access_log off;
    }
    
    # 禁止访问隐藏文件
    location ~ /\\. {
        deny all;
        access_log off;
        log_not_found off;
    }
    
    # 静态文件缓存
    location ~* \\.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
    
    # 主 location
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # PHP 支持
    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    
    # 错误页面
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
}
EOF
    fi
    
    echo -e "${GREEN}✓ 配置文件已创建: $CONFIG_FILE${NC}"
    
    # 创建默认页面（如果不是反向代理）
    if ! $IS_REVERSE_PROXY; then
        create_test_page "$DOCUMENT_ROOT" "$SITE_NAME" "$PORT"
    fi
    
    # 启用站点
    enable_site "$SITE_NAME"
    
    echo ""
    echo -e "${CYAN}站点创建完成!${NC}"
    if $IS_REVERSE_PROXY; then
        echo -e "${BLUE}配置类型:${NC} 反向代理"
        echo -e "${BLUE}后端地址:${NC} http://$BACKEND_ADDRESS"
    else
        echo -e "${BLUE}配置类型:${NC} 静态站点"
        echo -e "${BLUE}目录位置:${NC} $DOCUMENT_ROOT"
    fi

    echo -e "${BLUE}访问地址:${NC}"
    echo -e "  ${GREEN}HTTPS: https://$SITE_NAME${NC}"
    echo -e "  ${YELLOW}HTTP: http://$SITE_NAME (自动重定向到 HTTPS)${NC}"
    
    echo ""
    read -p "按回车键继续..." -r
}

# 创建测试页面
create_test_page() {
    local doc_root="$1"
    local site_name="$2"
    local port="$3"
    
    cat > "$doc_root/index.html" << EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>欢迎访问 $site_name</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #6a11cb 0%, #2575fc 100%);
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 20px;
        }
        
        .container {
            background: rgba(255, 255, 255, 0.95);
            border-radius: 20px;
            padding: 40px;
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
            max-width: 800px;
            width: 100%;
            text-align: center;
            animation: fadeIn 0.8s ease-out;
        }
        
        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(20px); }
            to { opacity: 1; transform: translateY(0); }
        }
        
        h1 {
            color: #2c3e50;
            margin-bottom: 10px;
            font-size: 2.8em;
        }
        
        .domain {
            color: #3498db;
            font-size: 1.8em;
            margin-bottom: 30px;
            font-weight: bold;
        }
        
        .info-box {
            background: #f8f9fa;
            border-radius: 15px;
            padding: 25px;
            margin: 20px 0;
            text-align: left;
            border-left: 5px solid #3498db;
        }
        
        .info-item {
            margin: 10px 0;
            padding: 8px 0;
            border-bottom: 1px solid #eee;
        }
        
        .label {
            color: #7f8c8d;
            font-weight: 600;
            display: inline-block;
            width: 180px;
        }
        
        .value {
            color: #2c3e50;
            font-weight: 500;
        }
        
        .status {
            display: inline-block;
            padding: 6px 15px;
            border-radius: 20px;
            font-size: 0.9em;
            font-weight: 600;
        }
        
        .success {
            background: #d4edda;
            color: #155724;
        }
        
        .protocol {
            font-size: 1.2em;
            font-weight: bold;
            color: #27ae60;
        }
        
        .time {
            margin-top: 30px;
            color: #95a5a6;
            font-size: 0.9em;
        }
        
        .quick-links {
            display: flex;
            justify-content: center;
            gap: 15px;
            margin-top: 30px;
            flex-wrap: wrap;
        }
        
        .link-btn {
            padding: 12px 25px;
            background: linear-gradient(45deg, #3498db, #2980b9);
            color: white;
            text-decoration: none;
            border-radius: 10px;
            font-weight: 600;
            transition: all 0.3s ease;
            border: none;
            cursor: pointer;
        }
        
        .link-btn:hover {
            transform: translateY(-3px);
            box-shadow: 0 10px 20px rgba(52, 152, 219, 0.3);
        }
        
        .ssl-badge {
            background: linear-gradient(45deg, #27ae60, #2ecc71);
            color: white;
            padding: 10px 20px;
            border-radius: 25px;
            display: inline-flex;
            align-items: center;
            gap: 8px;
            margin: 15px 0;
        }
    </style>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css">
</head>
<body>
    <div class="container">
        <h1><i class="fas fa-rocket"></i> 站点已就绪</h1>
        <div class="domain">$site_name</div>
        
        <div class="ssl-badge">
            <i class="fas fa-lock"></i> 强制 HTTPS 已启用
        </div>
        
        <div class="info-box">
            <div class="info-item">
                <span class="label"><i class="fas fa-globe"></i> 访问协议:</span>
                <span class="value protocol">HTTPS</span>
            </div>
            <div class="info-item">
                <span class="label"><i class="fas fa-network-wired"></i> 端口号:</span>
                <span class="value">$port</span>
            </div>
            <div class="info-item">
                <span class="label"><i class="fas fa-folder-open"></i> 网站目录:</span>
                <span class="value">$doc_root</span>
            </div>
            <div class="info-item">
                <span class="label"><i class="fas fa-server"></i> 服务器:</span>
                <span class="value">Nginx 1.28.2</span>
            </div>
        </div>
        
        <div class="quick-links">
            <button class="link-btn" onclick="location.reload()">
                <i class="fas fa-sync-alt"></i> 刷新页面
            </button>
        </div>
        
        <div class="time">
            生成时间: <span id="current-time"></span>
        </div>
    </div>
    
    <script>
        function updateTime() {
            const now = new Date();
            document.getElementById('current-time').textContent = 
                now.toLocaleString('zh-CN', { 
                    year: 'numeric',
                    month: '2-digit',
                    day: '2-digit',
                    hour: '2-digit',
                    minute: '2-digit',
                    second: '2-digit'
                });
        }
        updateTime();
        setInterval(updateTime, 1000);
    </script>
</body>
</html>
EOF
    
    echo -e "${GREEN}✓ 测试页面已创建${NC}"
}

# 启用站点
enable_site() {
    local site_name="$1"
    local source="$SITES_AVAILABLE/$site_name"
    local target="$SITES_ENABLED/$site_name"
    
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
    
    read -p "请输入要删除的站点名称: " site_name
    
    if [ -z "$site_name" ]; then
        echo -e "${RED}未指定站点名称${NC}"
        read -p "按回车键继续..." -r
        return
    fi
    
    local config_file="$SITES_AVAILABLE/$site_name"
    local enabled_link="$SITES_ENABLED/$site_name"
    local doc_root="$WWW_ROOT/$site_name"
    
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
    read -p "确认删除? (输入站点名称确认): " confirm
    
    if [ "$confirm" != "$site_name" ]; then
        echo -e "${RED}取消删除${NC}"
        read -p "按回车键继续..." -r
        return
    fi
    
    # 禁用站点
    if [ -L "$enabled_link" ]; then
        rm "$enabled_link"
        echo -e "${GREEN}✓ 已移除启用链接${NC}"
    fi
    
    # 删除配置文件
    rm -f "$config_file"
    echo -e "${GREEN}✓ 已删除配置文件${NC}"
    
    # 询问是否删除网站目录
    if [ -d "$doc_root" ]; then
        read -p "是否删除网站目录 ($doc_root)? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$doc_root"
            echo -e "${GREEN}✓ 已删除网站目录${NC}"
        fi
    fi
    
    # 重载配置
    reload_nginx_quiet
    
    echo ""
    echo -e "${GREEN}站点删除完成${NC}"
    read -p "按回车键继续..." -r
}

# 3. 重载 Nginx 配置
reload_nginx() {
    show_banner
    echo -e "${CYAN}[3] 重载 Nginx 配置${NC}"
    echo ""
    
    echo -e "${BLUE}检查 Nginx 配置语法...${NC}"
    if nginx -t; then
        echo -e "${GREEN}配置语法正确${NC}"
        echo ""
        echo -e "${BLUE}重新加载 Nginx...${NC}"
        systemctl reload nginx
        echo -e "${GREEN}✓ Nginx 配置已重新加载${NC}"
    else
        echo -e "${RED}配置语法错误，请检查配置文件${NC}"
    fi
    
    echo ""
    read -p "按回车键继续..." -r
}

# 静默重载
reload_nginx_quiet() {
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
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
        return
    fi
    
    echo -e "${GREEN}证书文件: $(basename "$CERT_FILE")${NC}"
    echo -e "${GREEN}私钥文件: $(basename "$KEY_FILE")${NC}"
    echo ""
    
    echo -e "${BLUE}证书信息:${NC}"
    openssl x509 -in "$CERT_FILE" -text -noout 2>/dev/null | grep -E "Subject:|Issuer:|Not Before:|Not After:|Signature Algorithm:|DNS:" | head -10
    
    echo -e "\n${BLUE}有效性检查:${NC}"
    local expiry_date=$(openssl x509 -in "$CERT_FILE" -enddate -noout | cut -d= -f2)
    local expiry_epoch=$(date -d "$expiry_date" +%s)
    local today_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - today_epoch) / 86400 ))
    
    if [ "$days_left" -gt 30 ]; then
        echo -e "  ${GREEN}✓ 证书有效，剩余 ${days_left} 天${NC}"
    elif [ "$days_left" -gt 0 ]; then
        echo -e "  ${YELLOW}⚠ 证书即将过期，剩余 ${days_left} 天${NC}"
    else
        echo -e "  ${RED}✗ 证书已过期${NC}"
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
    if [ -z "$(ls -A "$SITES_AVAILABLE")" ]; then
        echo -e "  ${YELLOW}暂无站点配置${NC}"
    else
        for site in $(ls "$SITES_AVAILABLE/"); do
            if [ -L "$SITES_ENABLED/$site" ]; then
                echo -e "  ${GREEN}✓ $site${NC}"
            else
                echo -e "  ${YELLOW}○ $site${NC}"
            fi
        done
    fi
}

# 详细列出站点
list_sites_detailed() {
    echo -e "${BLUE}站点状态概览:${NC}"
    echo ""
    
    if [ -z "$(ls -A "$SITES_AVAILABLE")" ]; then
        echo -e "  ${YELLOW}暂无站点配置${NC}"
        return
    fi
    
    printf "%-40s %-12s %-10s %-15s %s\n" "站点名称" "状态" "端口" "协议" "配置位置"
    echo "----------------------------------------------------------------------------------------------------"
    
    for config in "$SITES_AVAILABLE"/*; do
        local site_name=$(basename "$config")
        local enabled="否"
        local ports=""
        local protocol="HTTP"
        
        if [ -L "$SITES_ENABLED/$site_name" ]; then
            enabled="${GREEN}是${NC}"
        else
            enabled="${YELLOW}否${NC}"
        fi
        
        # 解析配置文件获取端口
        if [ -f "$config" ]; then
            ports=$(grep -E "listen\s+[0-9]+" "$config" | grep -v "ssl" | head -1 | awk '{print $2}' | tr -d ';' || echo "80")
            protocol="HTTPS"
        fi
        
        printf "%-40s %-12b %-10s %-15s %s\n" "$site_name" "$enabled" "$ports" "$protocol" "$config"
    done
    
    echo ""
    echo -e "${BLUE}监听端口:${NC}"
    ss -tulpn | grep nginx || echo -e "  ${YELLOW}Nginx 未运行或未监听端口${NC}"
}

# 6. 一键安装 Nginx
install_nginx() {
    show_banner
    echo -e "${CYAN}[6] 安装/更新 Nginx${NC}"
    echo ""
    
    if systemctl is-active --quiet nginx; then
        echo -e "${YELLOW}Nginx 已安装且正在运行${NC}"
        read -p "是否重新安装? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return
        fi
    fi
    
    echo -e "${BLUE}开始安装 Nginx...${NC}"
    echo ""
    
    # 安装依赖
    echo "1. 安装依赖包..."
    apt-get update
    apt-get install -y curl gnupg2 ca-certificates lsb-release
    
    # 添加 Nginx 官方源
    echo "2. 添加 Nginx 官方源..."
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
    
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/debian $(lsb_release -cs) nginx" | tee /etc/apt/sources.list.d/nginx.list
    
    echo -e "Package: *\nPin: origin nginx.org\nPin-Priority: 900" | tee /etc/apt/preferences.d/99nginx
    
    # 安装 Nginx
    echo "3. 安装 Nginx..."
    apt-get update
    apt-get install -y nginx
    
    # 创建标准目录结构
    echo "4. 创建目录结构..."
    mkdir -p "$SITES_AVAILABLE"
    mkdir -p "$SITES_ENABLED"
    mkdir -p "$SSL_DIR"
    mkdir -p "$CERTS_DIR"
    mkdir -p "$PRIVATE_DIR"
    mkdir -p "$WWW_ROOT"
    
    # 备份原配置
    if [ -f "$NGINX_DIR/nginx.conf" ]; then
        cp "$NGINX_DIR/nginx.conf" "$NGINX_DIR/nginx.conf.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # 创建优化的主配置文件
    echo "5. 创建主配置文件..."
    cat > "$NGINX_DIR/nginx.conf" << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
    multi_accept on;
    use epoll;
}

http {
    # 基础设置
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 100M;
    
    # MIME 类型
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    # 日志格式
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;
    
    # Gzip 压缩
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript 
               application/json application/javascript application/xml+rss 
               application/atom+xml image/svg+xml;
    
    # 缓存
    open_file_cache max=1000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;
    
    # 包含其他配置
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    
    # 启动服务
    echo "6. 启动 Nginx 服务..."
    systemctl start nginx
    systemctl enable nginx
    
    # 检测域名
    detect_domain
    
    echo ""
    echo -e "${GREEN}✓ Nginx 安装完成!${NC}"
    echo -e "版本: $(nginx -v 2>&1 | cut -d/ -f2)"
    echo -e "状态: $(systemctl is-active nginx)"
    echo ""
    
    read -p "按回车键继续..." -r
}

# 7. 管理 Nginx 服务
manage_service() {
    show_banner
    echo -e "${CYAN}[7] 管理 Nginx 服务${NC}"
    echo ""
    
    local status=$(systemctl is-active nginx 2>/dev/null || echo "inactive")
    
    echo -e "当前状态: $([ "$status" = "active" ] && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}已停止${NC}")"
    echo ""
    
    echo -e "${BLUE}请选择操作:${NC}"
    echo -e "  ${GREEN}1${NC}) 启动 Nginx"
    echo -e "  ${GREEN}2${NC}) 停止 Nginx"
    echo -e "  ${GREEN}3${NC}) 重启 Nginx"
    echo -e "  ${GREEN}4${NC}) 查看状态"
    echo -e "  ${GREEN}5${NC}) 查看日志"
    echo -e "  ${GREEN}6${NC}) 返回主菜单"
    echo ""
    
    read -p "请选择 [1-6]: " choice
    
    case $choice in
        1)
            systemctl start nginx
            echo -e "${GREEN}✓ Nginx 已启动${NC}"
            ;;
        2)
            systemctl stop nginx
            echo -e "${YELLOW}✓ Nginx 已停止${NC}"
            ;;
        3)
            systemctl restart nginx
            echo -e "${GREEN}✓ Nginx 已重启${NC}"
            ;;
        4)
            echo ""
            systemctl status nginx --no-pager
            ;;
        5)
            echo -e "${BLUE}最近 50 条日志:${NC}"
            journalctl -u nginx --no-pager -n 50
            ;;
        6)
            return
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
    
    echo ""
    read -p "按回车键继续..." -r
}

# 8. 备份/恢复配置
backup_restore() {
    show_banner
    echo -e "${CYAN}[8] 备份/恢复配置${NC}"
    echo ""
    
    local backup_dir="/var/backups/nginx"
    mkdir -p "$backup_dir"
    
    echo -e "${BLUE}请选择操作:${NC}"
    echo -e "  ${GREEN}1${NC}) 备份当前配置"
    echo -e "  ${GREEN}2${NC}) 恢复配置"
    echo -e "  ${GREEN}3${NC}) 列出备份"
    echo -e "  ${GREEN}4${NC}) 返回主菜单"
    echo ""
    
    read -p "请选择 [1-4]: " choice
    
    case $choice in
        1)
            local timestamp=$(date +%Y%m%d_%H%M%S)
            local backup_file="$backup_dir/nginx-backup-$timestamp.tar.gz"
            
            echo -e "${BLUE}正在备份配置...${NC}"
            tar -czf "$backup_file" \
                "$NGINX_DIR/nginx.conf" \
                "$SITES_AVAILABLE" \
                "$SITES_ENABLED" \
                "$SSL_DIR" \
                "/etc/nginx/conf.d" 2>/dev/null
            
            echo -e "${GREEN}✓ 备份完成: $backup_file${NC}"
            ls -lh "$backup_file"
            ;;
        2)
            echo -e "${BLUE}可用的备份:${NC}"
            ls -1 "$backup_dir/"*.tar.gz 2>/dev/null || {
                echo -e "${YELLOW}暂无备份文件${NC}"
                read -p "按回车键继续..." -r
                return
            }
            
            echo ""
            read -p "请输入要恢复的备份文件名: " backup_file
            
            if [ ! -f "$backup_dir/$backup_file" ]; then
                echo -e "${RED}文件不存在${NC}"
                read -p "按回车键继续..." -r
                return
            fi
            
            echo -e "${YELLOW}警告: 这将覆盖当前配置${NC}"
            read -p "确认恢复? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo -e "${BLUE}恢复备份...${NC}"
                tar -xzf "$backup_dir/$backup_file" -C /
                echo -e "${GREEN}✓ 配置已恢复${NC}"
                reload_nginx_quiet
            fi
            ;;
        3)
            echo -e "${BLUE}备份文件列表:${NC}"
            ls -lh "$backup_dir/"*.tar.gz 2>/dev/null || echo -e "${YELLOW}暂无备份${NC}"
            ;;
        4)
            return
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
    
    echo ""
    read -p "按回车键继续..." -r
}

# 9. 生成测试页面
generate_test_page() {
    show_banner
    echo -e "${CYAN}[9] 生成测试页面${NC}"
    echo ""
    
    list_sites_simple
    
    echo ""
    read -p "请输入站点名称 (留空使用默认): " site_name
    
    if [ -z "$site_name" ]; then
        local sites=($(ls "$SITES_AVAILABLE/"))
        if [ ${#sites[@]} -eq 0 ]; then
            echo -e "${RED}没有可用的站点${NC}"
            read -p "按回车键继续..." -r
            return
        fi
        site_name="${sites[0]}"
    fi
    
    local doc_root="$WWW_ROOT/$site_name"
    
    if [ ! -d "$doc_root" ]; then
        echo -e "${YELLOW}网站目录不存在，是否创建? (y/N): ${NC}" -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            mkdir -p "$doc_root"
            chown www-data:www-data "$doc_root"
        else
            echo -e "${RED}取消操作${NC}"
            read -p "按回车键继续..." -r
            return
        fi
    fi
    
    # 获取站点信息
    local config_file="$SITES_AVAILABLE/$site_name"
    local port="443"
    
    if [ -f "$config_file" ]; then
        port=$(grep -E "listen\s+[0-9]+" "$config_file" | grep "ssl" | head -1 | awk '{print $2}' | tr -d ';' || echo "443")
    fi
    
    create_test_page "$doc_root" "$site_name" "$port"
    
    echo -e "${GREEN}✓ 测试页面已生成${NC}"
    echo -e "访问地址: https://$site_name:$port"
    
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
            9) generate_test_page ;;
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