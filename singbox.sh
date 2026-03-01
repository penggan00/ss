# 一键创建/更新 sing-box 服务脚本并重启
cat > /etc/init.d/sing-box <<'EOF' && chmod +x /etc/init.d/sing-box && rc-service sing-box restart
#!/sbin/openrc-run
description="sb service"
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
}
EOF