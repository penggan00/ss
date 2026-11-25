cat > /root/hy2-tune.sh <<'EOF'
#!/bin/sh
echo "===== 1. 调 UDP 缓冲 ====="
echo 4194304 > /proc/sys/net/core/rmem_default
echo 4194304 > /proc/sys/net/core/wmem_default
echo 4194304 > /proc/sys/net/core/rmem_max
echo 4194304 > /proc/sys/net/core/wmem_max
for k in rmem_default wmem_default rmem_max wmem_max; do
  grep -q "net.core.$k=4194304" /etc/sysctl.conf 2>/dev/null || echo "net.core.$k=4194304" >> /etc/sysctl.conf
done
echo "当前缓冲: $(cat /proc/sys/net/core/rmem_default)"

echo "===== 2. 清理 sb.json 不兼容字段 ====="
cd /root/agsbx || exit 1
sed -i '/"quic": {/,/},/d' sb.json 2>/dev/null || true
sed -i '/recv_window_conn/d; /recv_window_client/d; /max_conn_client/d' sb.json 2>/dev/null || true
if grep -n "recv_window\|max_conn\|\"quic\"" sb.json 2>/dev/null; then
  echo "⚠️ 仍有残留字段"
else
  echo "干净"
fi

echo "===== 3. 重启 sing-box ====="
rc-service sing-box restart || true
sleep 3
PID=$(pgrep -f "agsbx/sing-box run" | head -1)
if [ -z "$PID" ]; then
  echo "❌ 工作进程未启动，请手动检查配置！"
  exit 1
fi
echo "工作进程 PID: $PID"

echo "===== 4. 提优先级 ====="
renice -n -20 -p "$PID" 2>/dev/null || echo "renice 失败（影响不大）"
awk '{print "PID:"$1, "Nice:"$19}' /proc/"$PID"/stat 2>/dev/null || true

echo "===== 5. 确认监听 ====="
netstat -tulpn 2>/dev/null | grep 51200 || ss -tulpn 2>/dev/null | grep 51200 || echo "netstat/ss 不可用，请看第 3 步的 PID"
echo "===== 完成 ====="
EOF
chmod +x /root/hy2-tune.sh
/root/hy2-tune.sh