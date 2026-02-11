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
    
    # 检测主域名（从现有证书获取）
    detect_domain
}

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
    
    # 如果没找到，再尝试 acme.sh 路径
    if [ -z "$found_cert" ]; then
        local acme_certs=(
            "/root/.acme.sh/*/fullchain.cer"
            "/root/.acme.sh/*_ecc/fullchain.cer"
        )
        
        for cert_pattern in "${acme_certs[@]}"; do
            local cert_file=$(ls $cert_pattern 2>/dev/null | head -1)
            if [ -n "$cert_file" ] && [ -f "$cert_file" ]; then
                found_cert="$cert_file"
                echo -e "${GREEN}找到证书: $(basename "$cert_file")${NC}"
                break
            fi
        done
    fi
    
    if [ -n "$found_cert" ] && [ -f "$found_cert" ]; then
        CERT_FILE="$found_cert"
        
        # 尝试查找对应的私钥
        local cert_name=$(basename "$found_cert" .crt)
        cert_name=$(basename "$cert_name" .cer)
        cert_name=$(basename "$cert_name" .pem)
        
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
        
        # 如果还没找到私钥，尝试 acme.sh 路径
        if [ -z "$KEY_FILE" ] && [ -n "$cert_name" ]; then
            local acme_keys=(
                "/root/.acme.sh/*/$cert_name.key"
                "/root/.acme.sh/*_ecc/$cert_name.key"
            )
            
            for key_pattern in "${acme_keys[@]}"; do
                local key_file=$(ls $key_pattern 2>/dev/null | head -1)
                if [ -n "$key_file" ] && [ -f "$key_file" ]; then
                    KEY_FILE="$key_file"
                    echo -e "${GREEN}找到私钥: $(basename "$key_file")${NC}"
                    break
                fi
            done
        fi
        
        # 从证书提取域名
        DOMAIN=$(openssl x509 -in "$found_cert" -text -noout 2>/dev/null | grep -o "DNS:\*\.\?[^,]*" | head -1 | cut -d: -f2 | sed 's/\*\.//')
        
        if [ -z "$DOMAIN" ]; then
            # 尝试从文件名提取
            DOMAIN="$cert_name"
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
# 强制 HTTPS 配置

# HTTP重定向到HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAME;
    
    # 安全头部
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # 301 永久重定向到 HTTPS
    return 301 https://\$server_name\$request_uri;
}

# HTTPS服务器配置
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name $SERVER_NAME;
    
    # SSL证书（使用检测到的证书）
    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    
    # SSL优化
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers off;
    
    # 安全头部
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # 访问日志
    access_log $LOG_DIR/${SITE_NAME}_ssl_access.log;
    error_log $LOG_DIR/${SITE_NAME}_ssl_error.log warn;
    
    # 允许大文件上传
    client_max_body_size 50M;
    
    # 反向代理配置
    location / {
        proxy_pass http://$BACKEND_ADDRESS;
        
        # WebSocket支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        
        # 基础代理头
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # 禁用代理缓冲（提高实时性）
        proxy_buffering off;
        
        # 连接设置
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
        proxy_read_timeout 60s;
        proxy_connect_timeout 60s;
        
        # 保持活动连接
        proxy_set_header Connection "";
    }
    
    # 静态文件缓存
    location ~* \\.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)\$ {
        proxy_pass http://$BACKEND_ADDRESS;
        proxy_set_header Host \$host;
        add_header Cache-Control "public, max-age=31536000, immutable";
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

# 创建测试页面 (Alpine Linux 适配)
create_test_page() {
    local doc_root="$1"
    local site_name="$2"
    local port="$3"
    
    # Alpine Linux 默认用户组可能是 nginx 或 www-data
    local web_user="nginx"
    local web_group="nginx"
    
    if ! id nginx &>/dev/null; then
        web_user="www-data"
        web_group="www-data"
    fi
    
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
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
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
            font-size: 2.5em;
        }
        
        .domain {
            color: #3498db;
            font-size: 1.6em;
            margin-bottom: 30px;
            font-weight: bold;
            word-break: break-all;
        }
        
        .info-box {
            background: #f8f9fa;
            border-radius: 15px;
            padding: 20px;
            margin: 20px 0;
            text-align: left;
            border-left: 5px solid #3498db;
        }
        
        .info-item {
            margin: 10px 0;
            padding: 8px 0;
            border-bottom: 1px solid #eee;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .label {
            color: #7f8c8d;
            font-weight: 600;
            flex: 1;
        }
        
        .value {
            color: #2c3e50;
            font-weight: 500;
            flex: 2;
            text-align: right;
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
            font-size: 1.1em;
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
            font-size: 14px;
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
            justify-content: center;
        }
        
        .listening-info {
            background: #e8f4fc;
            border-radius: 10px;
            padding: 15px;
            margin: 15px 0;
            text-align: left;
        }
        
        .listening-item {
            margin: 8px 0;
            padding: 5px 0;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .system-info {
            background: #fff3cd;
            border-radius: 10px;
            padding: 15px;
            margin: 15px 0;
            text-align: left;
            border-left: 5px solid #ffc107;
        }
        
        @media (max-width: 600px) {
            .container {
                padding: 20px;
            }
            
            h1 {
                font-size: 2em;
            }
            
            .domain {
                font-size: 1.3em;
            }
            
            .quick-links {
                flex-direction: column;
            }
            
            .link-btn {
                width: 100%;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 站点已就绪</h1>
        <div class="domain">$site_name</div>
        
        <div class="ssl-badge">
            🔒 强制 HTTPS 已启用
        </div>
        
        <div class="info-box">
            <div class="info-item">
                <span class="label">访问协议:</span>
                <span class="value protocol">HTTPS (强制)</span>
            </div>
            <div class="info-item">
                <span class="label">HTTPS端口:</span>
                <span class="value">443</span>
            </div>
            <div class="info-item">
                <span class="label">网站目录:</span>
                <span class="value">$doc_root</span>
            </div>
            <div class="info-item">
                <span class="label">服务器:</span>
                <span class="value">Alpine Linux + Nginx</span>
            </div>
        </div>
        
        <div class="system-info">
            <div class="listening-item">
                📦 <strong>操作系统:</strong> Alpine Linux
            </div>
            <div class="listening-item">
                🐧 <strong>Web用户:</strong> $web_user:$web_group
            </div>
            <div class="listening-item">
                ⚡ <strong>Nginx版本:</strong> $(nginx -v 2>&1 | cut -d/ -f2)
            </div>
        </div>
        
        <div class="listening-info">
            <div class="listening-item">
                ✅ <strong>HTTP (80端口):</strong> 监听所有接口 → 强制重定向到 HTTPS
            </div>
            <div class="listening-item">
                ✅ <strong>HTTPS (443端口):</strong> 监听所有接口，SSL/TLS 加密
            </div>
            <div class="listening-item">
                🔄 <strong>HTTP/2:</strong> 已启用
            </div>
        </div>
        
        <div class="quick-links">
            <button class="link-btn" onclick="location.reload()">
                刷新页面
            </button>
            <button class="link-btn" onclick="window.open('https://$site_name', '_blank')">
                访问网站
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
    
    # 设置权限
    chown -R $web_user:$web_group "$doc_root"
    chmod -R 755 "$doc_root"
    
    echo -e "${GREEN}✓ 测试页面已创建${NC}"
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
    
    # 2. 更新并安装 Nginx
    echo "2. 更新包列表并安装 Nginx..."
    apk update
    apk add --no-cache nginx nginx-openrc
    
    # 3. 创建目录结构
    echo "3. 创建目录结构..."
    mkdir -p "$SITES_AVAILABLE"
    mkdir -p "$SITES_ENABLED"
    mkdir -p "$SSL_DIR"
    mkdir -p "$CERTS_DIR"
    mkdir -p "$PRIVATE_DIR"
    mkdir -p "$WWW_ROOT"
    mkdir -p "$LOG_DIR"
    mkdir -p "/run/nginx"
    
    # 4. 备份原配置
    if [ -f "$NGINX_DIR/nginx.conf" ]; then
        local backup_file="$NGINX_DIR/nginx.conf.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$NGINX_DIR/nginx.conf" "$backup_file"
        echo -e "  ${GREEN}✓ 原配置已备份到: $backup_file${NC}"
    fi
    
    # 5. 创建优化的主配置文件 (Alpine Linux 适配)

echo "4. 创建主配置文件..."
cat > "$NGINX_DIR/nginx.conf" << 'EOF'
user nginx;
worker_processes auto;
worker_rlimit_nofile 20000;  # 调整为合理值
pid /run/nginx/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    # 修复代理头哈希警告
    proxy_headers_hash_max_size 1024;
    proxy_headers_hash_bucket_size 128;
    
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # 优化的日志格式
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for" '
                    'rt=$request_time uct="$upstream_connect_time" uht="$upstream_header_time" urt="$upstream_response_time"';
    
    # 日志缓冲（减少磁盘IO）
    access_log  /var/log/nginx/access.log main buffer=64k flush=30s;
    error_log   /var/log/nginx/error.log warn;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  75s;  # 增加keepalive时间
    keepalive_requests 1000;  # 每个连接最多请求数
    
    types_hash_max_size 2048;
    
    # 隐藏服务器信息
    proxy_hide_header X-Powered-By;
    proxy_hide_header Server;
    server_tokens off;  # 不显示nginx版本

    # ========== 安全头 ==========
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # ========== 缓冲区设置 ==========
    client_body_buffer_size 128K;          # 增加body缓冲区
    client_header_buffer_size 4k;          # 增加header缓冲区
    client_max_body_size 0;                # 不限制，由server块控制
    large_client_header_buffers 4 8k;      # 增加大header缓冲区
    
    # ========== 超时设置 ==========
    client_body_timeout 30s;               # 增加body超时
    client_header_timeout 30s;             # 增加header超时
    send_timeout 30s;                      # 增加发送超时
    reset_timedout_connection on;          # 关闭超时连接
    
    # ========== 连接限制（防DDOS） ==========
    limit_conn_zone $binary_remote_addr zone=perip:10m;
    limit_conn_zone $server_name zone=perserver:10m;
    limit_req_zone $binary_remote_addr zone=perip_req:10m rate=20r/s;
    
    # 全局默认限制（可以在server块覆盖）
    limit_conn perip 20;
    limit_conn perserver 100;
    limit_req zone=perip_req burst=40 nodelay;

    # ========== Gzip压缩 ==========
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_comp_level 6;
    gzip_proxied any;
    gzip_types 
        text/plain
        text/css
        text/xml
        text/javascript
        application/javascript
        application/xml+rss
        application/json
        application/xml
        application/x-font-ttf
        font/opentype
        image/svg+xml;
    gzip_disable "msie6";
    
    # ========== 代理设置 ==========
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
    proxy_buffers 8 16k;
    proxy_buffer_size 32k;
    
    # 缓存相关（可选）
    # proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=my_cache:10m max_size=1g inactive=60m use_temp_path=off;

    # ========== 包含其他配置 ==========
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# 添加日志轮转配置
echo "5. 创建日志轮转配置..."
cat > "/etc/logrotate.d/nginx" << 'EOF'
/var/log/nginx/*.log {
    daily                    # 建议改为按天轮转
    missingok
    rotate 14                # 保留14天日志（Alpine磁盘通常较小）
    compress
    delaycompress
    notifempty
    create 0640 nginx adm    # 修正用户为nginx
    sharedscripts
    postrotate
        if [ -f /run/nginx/nginx.pid ]; then
            kill -USR1 $(cat /run/nginx/nginx.pid)
        fi
    endscript
}
EOF
    
    # 6. 启动服务
    echo "5. 启动 Nginx 服务..."
    if command -v rc-update &> /dev/null; then
        rc-update add nginx default 2>/dev/null || true
        rc-service nginx start
    else
        nginx
    fi
    
    # 7. 检测域名
    echo "6. 检测域名和证书..."
    detect_domain
    
    echo ""
    echo -e "${GREEN}✓ Nginx 安装完成!${NC}"
    echo -e "版本: $(nginx -v 2>&1 | cut -d/ -f2)"
    
    if pgrep nginx > /dev/null; then
        echo -e "状态: ${GREEN}运行中${NC}"
    else
        echo -e "状态: ${RED}未运行${NC}"
    fi
    
    echo -e "配置文件: $NGINX_DIR/nginx.conf"
    echo -e "站点配置目录: $SITES_AVAILABLE"
    echo ""
    
    read -p "按回车键继续..." -r
}

# 7. 管理 Nginx 服务 (Alpine Linux 适配)
manage_service() {
    show_banner
    echo -e "${CYAN}[7] 管理 Nginx 服务${NC}"
    echo ""
    
    local status=""
    if pgrep nginx > /dev/null; then
        status="运行中"
    else
        status="已停止"
    fi
    
    echo -e "当前状态: $([ "$status" = "运行中" ] && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}已停止${NC}")"
    echo ""
    
    echo -e "${BLUE}请选择操作:${NC}"
    echo -e "  ${GREEN}1${NC}) 启动 Nginx"
    echo -e "  ${GREEN}2${NC}) 停止 Nginx"
    echo -e "  ${GREEN}3${NC}) 重启 Nginx"
    echo -e "  ${GREEN}4${NC}) 查看状态"
    echo -e "  ${GREEN}5${NC}) 查看日志"
    echo -e "  ${GREEN}6${NC}) 查看进程"
    echo -e "  ${GREEN}7${NC}) 返回主菜单"
    echo ""
    
    read -p "请选择 [1-7]: " choice
    
    case $choice in
        1)
            if command -v rc-service &> /dev/null; then
                rc-service nginx start
            else
                nginx
            fi
            echo -e "${GREEN}✓ Nginx 已启动${NC}"
            ;;
        2)
            if command -v rc-service &> /dev/null; then
                rc-service nginx stop
            else
                nginx -s quit
            fi
            echo -e "${YELLOW}✓ Nginx 已停止${NC}"
            ;;
        3)
            if command -v rc-service &> /dev/null; then
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
            if command -v rc-service &> /dev/null; then
                rc-service nginx status
            else
                echo "进程状态:"
                pgrep nginx || echo "无 Nginx 进程"
                echo -e "\n监听端口:"
                ss -tulpn | grep nginx 2>/dev/null || echo "无监听端口"
            fi
            ;;
        5)
            echo -e "${BLUE}最近 50 条错误日志:${NC}"
            tail -50 /var/log/nginx/error.log 2>/dev/null || echo "日志文件不存在"
            echo ""
            echo -e "${BLUE}最近 20 条访问日志:${NC}"
            tail -20 /var/log/nginx/access.log 2>/dev/null || echo "日志文件不存在"
            ;;
        6)
            echo -e "${BLUE}Nginx 进程:${NC}"
            ps aux | grep nginx | grep -v grep || echo "无 Nginx 进程"
            echo -e "\n${BLUE}监听端口:${NC}"
            if command -v ss &> /dev/null; then
                ss -tulpn | grep nginx 2>/dev/null || echo "无监听端口"
            elif command -v netstat &> /dev/null; then
                netstat -tulpn | grep nginx 2>/dev/null || echo "无监听端口"
            fi
            ;;
        7)
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
    echo -e "  ${GREEN}4${NC}) 清理旧备份"
    echo -e "  ${GREEN}5${NC}) 返回主菜单"
    echo ""
    
    read -p "请选择 [1-5]: " choice
    
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
                "/etc/nginx/conf.d" 2>/dev/null || true
            
            echo -e "${GREEN}✓ 备份完成: $(basename "$backup_file")${NC}"
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
            ls -lh "$backup_dir/"*.tar.gz
            
            echo ""
            read -p "请输入要恢复的备份文件名 (完整名称): " backup_file
            
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
            
            local total_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
            local file_count=$(ls -1 "$backup_dir/"*.tar.gz 2>/dev/null | wc -l)
            
            if [ "$file_count" -gt 0 ]; then
                echo -e "\n统计: ${file_count}个备份文件，总大小: ${total_size}"
            fi
            ;;
        4)
            echo -e "${YELLOW}清理 7 天前的备份文件...${NC}"
            find "$backup_dir" -name "*.tar.gz" -mtime +7 -delete 2>/dev/null
            echo -e "${GREEN}✓ 清理完成${NC}"
            ;;
        5)
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
    read -p "请输入站点名称 (留空使用第一个站点): " site_name
    
    if [ -z "$site_name" ]; then
        local sites=($(ls "$SITES_AVAILABLE/"*.conf 2>/dev/null))
        if [ ${#sites[@]} -eq 0 ]; then
            echo -e "${RED}没有可用的站点${NC}"
            read -p "按回车键继续..." -r
            return
        fi
        site_name=$(basename "${sites[0]}" .conf)
    fi
    
    local doc_root="/var/www/$site_name"
    
    if [ ! -d "$doc_root" ]; then
        echo -e "${YELLOW}网站目录不存在，是否创建? (y/N): " -n
        read -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            mkdir -p "$doc_root"
            # Alpine Linux 用户组
            local web_user="nginx"
            if ! id nginx &>/dev/null; then
                web_user="www-data"
            fi
            chown -R $web_user:$web_user "$doc_root"
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