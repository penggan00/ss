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
        echo -e "bash -c "$(curl -fsSL https://raw.githubusercontent.com/penggan00/ss/main/ssl.sh)"
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
    
    # 获取后端端口（简化输入）
    echo ""
    echo -e "${YELLOW}反向代理配置${NC}"
    echo -e "默认代理到本地服务 (127.0.0.1)"

    while true; do
        read -p "请输入后端服务端口号 (如 8080, 3000, 9000): " BACKEND_PORT
        
        if [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] && [ "$BACKEND_PORT" -ge 1 ] && [ "$BACKEND_PORT" -le 65535 ]; then
            # 直接使用输入的端口，不检查是否被占用
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
    CONFIG_FILE="$SITES_AVAILABLE/$SITE_NAME"
    
    # 总是生成反向代理配置（不包含default_server）
# 总是生成反向代理配置（使用改进的模板）
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
    return 301 https://\\\$server_name\\\$request_uri;
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
        proxy_set_header Upgrade \\\$http_upgrade;
        proxy_set_header Connection "Upgrade";
        
        # 基础代理头
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
        
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
        proxy_set_header Host \\\$host;
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
    enable_site "$SITE_NAME"
    
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
        
        .listening-info {
            background: #e8f4fc;
            border-radius: 10px;
            padding: 15px;
            margin: 15px 0;
            text-align: left;
        }
        
        .listening-item {
            margin: 5px 0;
            padding: 5px 0;
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
                <span class="value protocol">HTTPS (强制)</span>
            </div>
            <div class="info-item">
                <span class="label"><i class="fas fa-network-wired"></i> HTTPS端口:</span>
                <span class="value">443</span>
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
        
        <div class="listening-info">
            <div class="listening-item">
                <i class="fas fa-check-circle" style="color: #27ae60;"></i>
                <strong>HTTP (80端口):</strong> 监听所有 IPv4/IPv6 接口 → 强制重定向到 HTTPS
            </div>
            <div class="listening-item">
                <i class="fas fa-check-circle" style="color: #27ae60;"></i>
                <strong>HTTPS (443端口):</strong> 监听所有 IPv4/IPv6 接口，SSL/TLS 加密
            </div>
        </div>
        
        <div class="quick-links">
            <button class="link-btn" onclick="location.reload()">
                <i class="fas fa-sync-alt"></i> 刷新页面
            </button>
            <button class="link-btn" onclick="window.open('https://$site_name', '_blank')">
                <i class="fas fa-external-link-alt"></i> 访问网站
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

# 2. 删除站点 - 简化版
delete_site() {
    show_banner
    echo -e "${CYAN}[2] 删除站点${NC}"
    echo ""
    
    list_sites_simple
    
    echo ""
    read -p "请输入要删除的站点名称: " site_name
    
    if [ -z "$site_name" ]; then
        echo -e "${RED}未指定站点名称${NC}"
        read -p "按回车键继续..." -r
        return
    fi
    
    local config_file="$SITES_AVAILABLE/$site_name"
    local enabled_link="$SITES_ENABLED/$site_name"
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
        rm "$enabled_link"
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
            ports="80,443"
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
# 创建优化的主配置文件
echo "5. 创建主配置文件..."
cat > "$NGINX_DIR/nginx.conf" << 'EOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 20000;  # 调整为合理值
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

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
    
    # ========== 包含其他配置 ==========
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    
    # 启动服务
    echo "6. 启动 Nginx 服务..."
    systemctl start nginx
    systemctl enable nginx
    
# 7. 创建日志轮转配置（新增部分）
echo "7. 创建日志轮转配置..."
cat > "/etc/logrotate.d/nginx" << 'EOF'
/var/log/nginx/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        if [ -f /run/nginx.pid ]; then
            kill -USR1 $(cat /run/nginx.pid)
        fi
    endscript
}
EOF
echo -e "${GREEN}✓ 日志轮转配置已创建${NC}"

# 8. 检测域名
detect_domain

echo ""
echo -e "${GREEN}✓ Nginx 安装完成!${NC}"
    
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
    
    local doc_root="/var/www/$site_name"
    
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