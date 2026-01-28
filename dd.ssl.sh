#!/bin/bash

# ================= 一键SSL证书卸载脚本 =================
# 用法: bash /usr/local/bin/uninstall-cert-manager.sh
# ======================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DIR="/opt/cert-manager"

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}      SSL证书管理工具卸载脚本           ${NC}"
echo -e "${YELLOW}========================================${NC}"

# 确认操作
read -p "确定要卸载证书管理工具吗？(y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}取消卸载${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}开始卸载...${NC}"

# 1. 停止相关服务
echo "1. 停止相关服务..."
systemctl stop nginx 2>/dev/null || rc-service nginx stop 2>/dev/null || true

# 2. 删除定时任务
echo "2. 删除定时任务..."
if [ -f /etc/crontab ]; then
    sed -i '/renew-all.sh/d' /etc/crontab
fi
if [ -f /etc/crontabs/root ]; then
    sed -i '/renew-all.sh/d' /etc/crontabs/root
fi
crontab -l 2>/dev/null | grep -v "renew-all.sh" | crontab - 2>/dev/null || true

# 重启cron服务
systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || rc-service crond restart 2>/dev/null || true

# 3. 删除安装目录
echo "3. 删除安装目录..."
if [ -d "$INSTALL_DIR" ]; then
    echo "删除目录: $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
else
    echo "安装目录不存在: $INSTALL_DIR"
fi

# 4. 删除证书文件（可选）
read -p "是否删除所有证书文件？(y/N): " DELETE_CERTS
if [[ "$DELETE_CERTS" =~ ^[Yy]$ ]]; then
    echo "4. 删除证书文件..."
    
    # 查找并删除相关证书
    find /etc/nginx/ssl -name "*.pem" -type f -delete 2>/dev/null || true
    find /etc/nginx/ssl -name "*.crt" -type f -delete 2>/dev/null || true
    find /etc/nginx/ssl -name "*.key" -type f -delete 2>/dev/null || true
    
    find /etc/ssl/certs -name "*.pem" -type f -delete 2>/dev/null || true
    find /etc/ssl/private -name "*.pem" -type f -delete 2>/dev/null || true
    find /etc/ssl/private -name "*.key" -type f -delete 2>/dev/null || true
    
    find /etc/pki/tls/certs -name "*.pem" -type f -delete 2>/dev/null || true
    find /etc/pki/tls/private -name "*.key" -type f -delete 2>/dev/null || true
    
    # 删除符号链接
    find /etc/nginx/ssl -type l -delete 2>/dev/null || true
    find /etc/ssl -type l -delete 2>/dev/null || true
    find /etc/pki -type l -delete 2>/dev/null || true
    
    # 删除空目录
    find /etc/nginx/ssl -type d -empty -delete 2>/dev/null || true
    find /etc/ssl -type d -empty -delete 2>/dev/null || true
    find /etc/pki -type d -empty -delete 2>/dev/null || true
fi

# 5. 清理Nginx配置
echo "5. 清理Nginx配置..."
if [ -f /etc/nginx/nginx.conf ]; then
    # 恢复简单的nginx配置
    cat > /etc/nginx/nginx.conf <<'NGINX_CONF'
user nginx;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;
    
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    
    include /etc/nginx/conf.d/*.conf;
}
NGINX_CONF
fi

# 删除conf.d目录下的相关配置
find /etc/nginx/conf.d -name "*.conf" -type f -delete 2>/dev/null || true

# 6. 重启Nginx
echo "6. 重启Nginx..."
nginx -t 2>/dev/null && {
    systemctl start nginx 2>/dev/null || rc-service nginx start 2>/dev/null || nginx
}

# 7. 清理日志
echo "7. 清理日志..."
find /var/log -name "*acme*" -type f -delete 2>/dev/null || true
find /var/log -name "*renewal*" -type f -delete 2>/dev/null || true

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}      SSL证书管理工具卸载完成            ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "已删除:"
echo "  ✓ 安装目录: /opt/cert-manager"
echo "  ✓ 定时任务"
echo "  ✓ Nginx配置"
if [[ "$DELETE_CERTS" =~ ^[Yy]$ ]]; then
    echo "  ✓ 所有证书文件"
fi
echo ""
echo "注意:"
echo "  1. 如果需要重新安装，请重新运行安装脚本"
echo "  2. 如果还有残留文件，请手动检查:"
echo "     /opt/cert-manager"
echo "     /etc/nginx/ssl/"
echo "     /etc/nginx/conf.d/"
echo "     crontab -l"