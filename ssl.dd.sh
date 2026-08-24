if [ -f /etc/alpine-release ]; then
    rc-service nginx stop 2>/dev/null || true
    rc-update del nginx default 2>/dev/null || true
    apk del nginx 2>/dev/null || true
    apk autoremove 2>/dev/null || true
elif [ -f /etc/debian_version ]; then
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    apt-get purge -y nginx nginx-common nginx-core 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
fi

rm -rf \
    /etc/nginx \
    /etc/nginx-ssl-manager \
    /root/.acme.sh \
    /var/www/* \
    /var/log/nginx \
    /etc/ssl/acme \
    /etc/acme.sh

rm -f \
    /etc/init.d/nginx \
    /etc/cron.d/acme.sh \
    /etc/cron.d/nginx

rm -f /etc/systemd/system/acme-*.timer
rm -f /etc/systemd/system/acme-*.service

rm -rf /var/cache/apk/*
rm -rf /var/lib/apt/lists/*

echo "========================================="
echo "✓ Nginx SSL 项目已彻底清理"
echo "✓ Nginx 已删除"
echo "✓ acme.sh 已删除"
echo "✓ SSL 证书已删除"
echo "✓ Nginx 配置已删除"
echo "✓ 网站文件已删除"
echo "✓ 管理器配置已删除"
echo "✓ 续签任务已删除"
echo "========================================="