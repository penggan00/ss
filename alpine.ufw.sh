#!/bin/sh
# Alpine 终极 iptables 配置脚本 + 端口管理工具
#iptables-add-port 51200 udp ss
#iptables-add-port 51200 tcp ss
#iptables-add-port 51201 udp ss
#iptables-add-port 51201 tcp ss

echo "🔧 安装 iptables..."
apk add iptables ip6tables iptables-save iptables-restore

echo "📁 创建规则目录..."
mkdir -p /etc/iptables

echo "⚙️  配置基础规则..."
# 清空现有规则
iptables -F
iptables -X
ip6tables -F
ip6tables -X

# 默认策略
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

echo "🔓 设置基础规则..."
# 1. 允许本地回环
iptables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT

# 2. 允许已建立的连接
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 3. 允许 ICMP (ping)
iptables -A INPUT -p icmp -j ACCEPT
ip6tables -A INPUT -p ipv6-icmp -j ACCEPT

# 4. 开放需要的端口（从配置文件读取）
if [ -f /etc/iptables/ports.conf ]; then
    echo "📖 从配置文件读取端口..."
    while read line; do
        [[ "$line" =~ ^#.*$ ]] || [[ -z "$line" ]] && continue
        port=$(echo "$line" | awk '{print $1}')
        protocol=$(echo "$line" | awk '{print $2}')
        iptables -A INPUT -p $protocol --dport $port -j ACCEPT
        ip6tables -A INPUT -p $protocol --dport $port -j ACCEPT
    done < /etc/iptables/ports.conf
else
    echo "📝 设置默认端口..."
    PORTS="80 443 222"
    for port in $PORTS; do
        iptables -A INPUT -p tcp --dport $port -j ACCEPT
        ip6tables -A INPUT -p tcp --dport $port -j ACCEPT
    done
fi

# 5. 防御基础攻击
iptables -A INPUT -p tcp --syn -m connlimit --connlimit-above 20 -j REJECT
iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP  # NULL 包
iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP   # ALL 包

echo "💾 保存规则..."
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

echo "🔄 配置开机自动恢复..."
# 创建端口配置文件（如果不存在）
if [ ! -f /etc/iptables/ports.conf ]; then
    cat > /etc/iptables/ports.conf << 'EOF'
# iptables 开放端口配置
# 格式：端口号 协议(tcp/udp) [注释]
80 tcp    # HTTP
443 tcp   # HTTPS
222 tcp   # SSH
EOF
fi

# 创建管理脚本
cat > /usr/local/bin/iptables-add-port << 'EOF'
#!/bin/sh
# 添加新端口工具 - 防重复版本

if [ $# -lt 2 ]; then
    echo "用法: iptables-add-port <端口> <协议> [注释]"
    echo "示例: iptables-add-port 3306 tcp # MySQL"
    exit 1
fi

PORT=$1
PROTOCOL=$(echo "$2" | tr '[:upper:]' '[:lower:]')
COMMENT=${3:-""}

# 验证协议
if [ "$PROTOCOL" != "tcp" ] && [ "$PROTOCOL" != "udp" ]; then
    echo "❌ 错误：协议必须是 tcp 或 udp"
    exit 1
fi

echo "🔍 检查端口 $PORT/$PROTOCOL..."

# 检查规则中是否已存在
RULE_EXISTS=$(iptables -L INPUT -n --line-numbers | grep "dpt:$PORT.*$PROTOCOL" | head -1)
if [ -n "$RULE_EXISTS" ]; then
    echo "⚠️  规则已存在："
    echo "   $RULE_EXISTS"
    echo "   无需重复添加"
    RULE_NUM=$(echo "$RULE_EXISTS" | awk '{print $1}')
else
    # 添加到规则
    echo "➕ 添加新规则..."
    iptables -A INPUT -p $PROTOCOL --dport $PORT -j ACCEPT
    ip6tables -A INPUT -p $PROTOCOL --dport $PORT -j ACCEPT
fi

# 管理配置文件
if [ ! -f /etc/iptables/ports.conf ]; then
    mkdir -p /etc/iptables
    echo "# iptables 开放端口配置" > /etc/iptables/ports.conf
    echo "# 格式：端口号 协议 [注释]" >> /etc/iptables/ports.conf
fi

# 检查配置文件中是否已存在
if grep -q "^$PORT $PROTOCOL" /etc/iptables/ports.conf; then
    echo "📝 已在配置文件中"
else
    echo "📝 添加到配置文件..."
    echo "$PORT $PROTOCOL    # $COMMENT" >> /etc/iptables/ports.conf
fi

# 保存规则
echo "💾 保存规则..."
iptables-save > /etc/iptables/rules.v4 2>/dev/null
ip6tables-save > /etc/iptables/rules.v6 2>/dev/null

echo "✅ 完成！"
echo ""
echo "📊 当前 $PORT 端口状态："
iptables -L INPUT -n | grep "dpt:$PORT"
EOF





cat > /usr/local/bin/iptables-remove-port << 'EOF'
#!/bin/sh
# 移除端口工具

if [ $# -lt 2 ]; then
    echo "用法: iptables-remove-port <端口> <协议>"
    echo "示例: iptables-remove-port 3306 tcp"
    exit 1
fi

PORT=$1
PROTOCOL=$2

# 从配置文件中移除
sed -i "/^$PORT $PROTOCOL/d" /etc/iptables/ports.conf
echo "✅ 已从配置文件中移除 $PORT/$PROTOCOL"

# 重新加载规则
echo "🔄 重新加载防火墙规则..."
/etc/init.d/iptables restart

echo "🗑️  端口 $PORT/$PROTOCOL 已关闭"
EOF

cat > /usr/local/bin/iptables-list-ports << 'EOF'
#!/bin/sh
# 列出所有开放端口
echo "📋 当前开放的端口："
echo "======================"
printf "%-8s %-8s %s\n" "端口" "协议" "说明"
echo "----------------------"
while read line; do
    [[ "$line" =~ ^#.*$ ]] || [[ -z "$line" ]] && continue
    port=$(echo "$line" | awk '{print $1}')
    protocol=$(echo "$line" | awk '{print $2}')
    comment=$(echo "$line" | sed 's/.*#//')
    printf "%-8s %-8s %s\n" "$port" "$protocol" "$comment"
done < /etc/iptables/ports.conf
echo "======================"
EOF

# 设置权限
chmod +x /usr/local/bin/iptables-*
chmod +x /usr/local/bin/iptables-add-port
chmod +x /usr/local/bin/iptables-remove-port
chmod +x /usr/local/bin/iptables-list-ports

# Alpine 自带 iptables 服务
if [ -f /etc/init.d/iptables ]; then
    rc-service iptables restart
    rc-update add iptables boot
else
# 创建新的正确服务脚本
# 确保服务脚本能正确从配置文件加载
cat > /etc/init.d/iptables << 'EOF'
#!/sbin/openrc-run

name="iptables"
description="iptables firewall"

depend() {
    need net
    after network
}

start() {
    ebegin "Starting iptables firewall"
    
    # 清空所有规则
    iptables -F
    iptables -X
    ip6tables -F
    ip6tables -X
    
    # 设置默认策略
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT ACCEPT
    
    # 基础规则
    iptables -A INPUT -i lo -j ACCEPT
    ip6tables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p icmp -j ACCEPT
    ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
    
    # 从 ports.conf 加载端口（去重）
    if [ -f /etc/iptables/ports.conf ]; then
        declare -A added_ports
        
        while IFS= read -r line; do
            # 跳过注释和空行
            [[ "$line" =~ ^#.*$ ]] || [[ -z "$line" ]] && continue
            
            # 提取端口和协议
            port=$(echo "$line" | awk '{print $1}')
            protocol=$(echo "$line" | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
            
            # 检查是否已添加（去重）
            key="${port}_${protocol}"
            if [[ -z "${added_ports[$key]}" ]] && { [ "$protocol" = "tcp" ] || [ "$protocol" = "udp" ]; }; then
                iptables -A INPUT -p $protocol --dport $port -j ACCEPT
                ip6tables -A INPUT -p $protocol --dport $port -j ACCEPT
                added_ports[$key]=1
            fi
        done < /etc/iptables/ports.conf
    fi
    
    # 防御规则
    iptables -A INPUT -p tcp --syn -m connlimit --connlimit-above 20 -j REJECT
    iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP
    iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP
    
    eend $?
}

stop() {
    ebegin "Stopping iptables firewall"
    iptables -F
    iptables -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    eend $?
}

restart() {
    stop
    sleep 1
    start
}

save() {
    ebegin "Saving iptables rules"
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
    eend $?
}
EOF

    chmod +x /etc/init.d/iptables
    rc-update add iptables default
fi

echo "✅ 配置完成！"
echo ""
echo "📋 当前规则："
iptables -L -n -v --line-numbers | head -30
echo ""
echo "🛠️  可用管理命令："
echo "  iptables-add-port <端口> <协议> [注释]    # 添加新端口"
echo "  iptables-remove-port <端口> <协议>       # 移除端口"
echo "  iptables-list-ports                      # 列出所有端口"
echo "  rc-service iptables restart              # 重启防火墙"
echo ""
echo "📝 端口配置文件：/etc/iptables/ports.conf"



cat > /usr/local/bin/iptables-cleanup << 'EOF'
#!/bin/sh
# 清理重复的 iptables 规则

echo "🧹 清理重复的 iptables 规则..."

# 获取当前规则并去重
iptables-save | awk '
BEGIN { delete_lines[""]=0 }
/^:/ { print; next }
/^-A/ {
    rule = $0
    if (!seen[rule]++) {
        print rule
    } else {
        print "# 重复规则已删除: " rule > "/dev/stderr"
    }
    next
}
{ print }
' > /tmp/iptables-cleaned.rules

# 应用清理后的规则
iptables-restore < /tmp/iptables-cleaned.rules

# 保存
iptables-save > /etc/iptables/rules.v4

echo "✅ 重复规则已清理"
echo ""
echo "📋 当前 51200/51201 端口规则："
iptables -L INPUT -n | grep -E "dpt:(51200|51201)"
EOF
chmod +x /usr/local/bin/iptables-cleanup
/usr/local/bin/iptables-cleanup

# 在脚本最后添加：
echo ""
echo "🎯 最终验证："
echo "1. 检查服务状态..."
rc-service iptables status 2>&1 | grep -q "started" && echo "✅ 服务运行正常" || echo "⚠️  服务可能有问题"

echo "2. 检查规则数量..."
RULE_COUNT=$(iptables -L INPUT -n | grep -c "ACCEPT")
echo "   当前有 $RULE_COUNT 条 ACCEPT 规则"

echo "3. 检查配置文件..."
if [ -f /etc/iptables/ports.conf ]; then
    PORT_COUNT=$(grep -v "^#" /etc/iptables/ports.conf | grep -c ".")
    echo "   配置文件包含 $PORT_COUNT 个端口"
else
    echo "⚠️  配置文件不存在"
fi

echo ""
echo "📋 当前开放的端口："
iptables -L INPUT -n | grep "dpt:" | awk '{print $NF, $7}' | sed 's/dpt://' | sort -n

# 添加 WARP 接口规则
sudo iptables -A INPUT -i warp -j ACCEPT -m comment --comment "Allow WARP interface"
sudo iptables -A OUTPUT -o warp -j ACCEPT -m comment --comment "Allow WARP interface"

# 保存规则
sudo iptables-save | sudo tee /etc/iptables/rules.v4

# 验证规则
sudo iptables -L INPUT -n -v | grep -A 1 -B 1 warp
sudo iptables -L OUTPUT -n -v | grep -A 1 -B 1 warp