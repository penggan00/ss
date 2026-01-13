echo "创建新的服务配置..."
cat > /etc/init.d/komari << 'EOF'
#!/sbin/openrc-run

name="komari"
description="Komari Service"
command="/opt/komari/komari"
command_args="server -l 127.0.0.1:25774"  # 只监听本地，更安全
pidfile="/run/${RC_SVCNAME}.pid"
command_background=true
command_user="root"
supervisor=supervise-daemon
respawn_delay=2
respawn_max=5

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -f -m 0644 -o root:root "${pidfile}"
}

stop_post() {
    rm -f "${pidfile}"
}
EOF

chmod +x /etc/init.d/komari

# 创建必要的目录
mkdir -p /run

# 添加到启动项
echo "添加到开机启动..."
rc-update add komari default

# 先停止可能存在的旧进程
pkill -f "komari server" 2>/dev/null
sleep 1

# 手动测试（更长时间）
echo "测试手动启动..."
cd /opt/komari
timeout 10s ./komari server -l 127.0.0.1:25774 > /tmp/komari-test.log 2>&1 &
TEST_PID=$!
sleep 3

# 检查是否在监听
if netstat -tlnp 2>/dev/null | grep -q ":25774" || ss -tlnp 2>/dev/null | grep -q ":25774"; then
    echo "✅ 手动启动成功，端口 25774 正在监听"
    kill $TEST_PID 2>/dev/null
    wait $TEST_PID 2>/dev/null
else
    echo "❌ 手动启动失败，端口未监听"
    echo "检查日志:"
    cat /tmp/komari-test.log
    kill $TEST_PID 2>/dev/null 2>/dev/null
    exit 1
fi

# 启动服务
echo "启动服务..."
rc-service komari start

# 等待服务启动
echo "等待服务启动..."
sleep 5

# 检查状态
echo "检查服务状态..."
rc-service komari status

# 检查是否在监听
echo "检查端口监听状态..."
if netstat -tlnp 2>/dev/null | grep ":25774" || ss -tlnp 2>/dev/null | grep ":25774"; then
    echo "✅ 服务运行正常，端口 25774 正在监听"
    
    # 测试连接
    echo "测试本地连接..."
    if timeout 2s curl -s http://127.0.0.1:25774 >/dev/null; then
        echo "✅ 本地连接成功"
        
        # 检查防火墙
        echo "检查防火墙状态..."
        if command -v iptables &>/dev/null; then
            if iptables -L INPUT -n | grep -q "25774"; then
                echo "⚠️  防火墙已配置，端口 25774 可能被封锁"
                echo "当前规则:"
                iptables -L INPUT -n | grep -A2 -B2 "25774"
            else
                echo "✅ 防火墙未封锁端口 25774"
            fi
        fi
        
        # 检查 Nginx 是否可以访问
        echo "检查 Nginx 配置..."
        if [ -f "/etc/nginx/conf.d/nz.215155.xyz.conf" ]; then
            echo "✅ 找到 Nginx 配置"
            echo "现在可以通过 https://nz.215155.xyz 访问"
        fi
    else
        echo "❌ 本地连接失败，服务可能未响应"
        echo "检查服务日志:"
        journalctl -u komari -n 10 2>/dev/null || tail -20 /var/log/komari.log 2>/dev/null
    fi
else
    echo "❌ 服务未监听端口 25774"
    echo "检查服务状态:"
    rc-service komari status
    echo "检查日志:"
    journalctl -u komari -n 20 2>/dev/null || echo "未找到 systemd 日志"
fi