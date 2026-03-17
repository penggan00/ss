# 1. 创建服务脚本（您的命令稍微调整一下）
cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
description="Sing-box proxy service"
command="/root/agsbx/sing-box"
command_args="run -c /root/agsbx/sb.json"
command_background=yes
pidfile="/run/sing-box.pid"
command_user="root"

# 添加 supervisor 配置
supervisor=supervise-daemon
respawn_delay=5
respawn_max=0

depend() {
    need net
    after firewall
}
EOF

# 2. 设置执行权限
chmod +x /etc/init.d/sing-box

# 3. 添加到默认运行级别
rc-update add sing-box default

# 4. 启动服务
rc-service sing-box start

# 5. 查看服务状态
rc-service sing-box status