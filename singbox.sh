# 1. 创建优化后的服务脚本
cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
description="Sing-box proxy service"

# 核心命令配置（确认路径是否正确！）
command="/root/agsbx/sing-box"
command_args="run -c /root/agsbx/sb.json"

# 后台运行配置
command_background=yes
pidfile="/run/sing-box.pid"
command_user="root"

# 守护进程配置（优化重启策略）
supervisor=supervise-daemon
respawn_delay=3          # 缩短重启延迟（5秒→3秒）
respawn_max=0            # 无限重启（适合代理服务）
respawn_timeout=30       # 新增：启动超时时间（防止僵死）

# 依赖项（确保网络就绪后启动）
depend() {
    need net
    after firewall
}

# 自定义停止逻辑（确保进程彻底退出）
stop() {
    default_stop
    # 清理残留PID文件
    if [ -f "${pidfile}" ]; then
        rm -f "${pidfile}"
    fi
}
EOF

# 2. 设置执行权限
chmod +x /etc/init.d/sing-box

# 3. 添加到默认运行级别
rc-update add sing-box default

# 4. 启动服务
rc-service sing-box start

# 5. 查看服务状态（无需修改，这行是查看状态的正确命令）
rc-service sing-box status