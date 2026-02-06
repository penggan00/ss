#!/bin/bash
set -e

### ====== 参数 ======
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "用法: $0 <LANDING_IPV4> <LANDING_IPV6>"
    exit 1
fi

LANDING_IPV4="$1"
LANDING_IPV6="$2"

TRANSIT_PORT=51300
LANDING_PORT=51200

OPEN_PORTS=(222 80 443 51200 51201 51202 51203)

### ====== 系统检测 ======
detect_os() {
    if [ -f /etc/alpine-release ]; then
        echo "alpine"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/lsb-release ] && grep -q "Ubuntu" /etc/lsb-release; then
        echo "debian"  # Ubuntu 也按 Debian 处理
    elif [ -f /etc/os-release ]; then
        source /etc/os-release
        if [[ "$ID" == "alpine" ]]; then
            echo "alpine"
        elif [[ "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
            echo "debian"
        else
            echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

OS_TYPE=$(detect_os)
echo ">>> 检测到系统类型: $OS_TYPE"

if [ "$OS_TYPE" = "unknown" ]; then
    echo "错误: 不支持的操作系统"
    exit 1
fi

### ====== 通用函数 ======
setup_ip_forward() {
    echo ">>> 开启 IPv4 / IPv6 转发"
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    
    grep -q net.ipv4.ip_forward /etc/sysctl.conf || cat >> /etc/sysctl.conf << EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
    sysctl -p 2>/dev/null || true
}

open_ports() {
    echo ">>> 放行直接访问端口（IPv4 + IPv6）"
    for port in "${OPEN_PORTS[@]}"; do
        # IPv4
        iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $port -j ACCEPT
        iptables -C INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport $port -j ACCEPT
        # IPv6
        ip6tables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || ip6tables -A INPUT -p tcp --dport $port -j ACCEPT
        ip6tables -C INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || ip6tables -A INPUT -p udp --dport $port -j ACCEPT
    done
}

setup_ipv4_rules() {
    echo ">>> 设置 IPv4 中转规则（$TRANSIT_PORT -> ${LANDING_IPV4}:${LANDING_PORT}）"
    
    # 清理旧规则
    iptables -t nat -D PREROUTING -p tcp --dport ${TRANSIT_PORT} -j DNAT --to-destination ${LANDING_IPV4}:${LANDING_PORT} 2>/dev/null || true
    iptables -t nat -D PREROUTING -p udp --dport ${TRANSIT_PORT} -j DNAT --to-destination ${LANDING_IPV4}:${LANDING_PORT} 2>/dev/null || true
    iptables -t nat -D POSTROUTING -p tcp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -p udp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j MASQUERADE 2>/dev/null || true
    
    # 添加新规则
    iptables -t nat -A PREROUTING -p tcp --dport ${TRANSIT_PORT} -j DNAT --to-destination ${LANDING_IPV4}:${LANDING_PORT}
    iptables -t nat -A PREROUTING -p udp --dport ${TRANSIT_PORT} -j DNAT --to-destination ${LANDING_IPV4}:${LANDING_PORT}
    iptables -t nat -A POSTROUTING -p tcp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j MASQUERADE
    iptables -t nat -A POSTROUTING -p udp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j MASQUERADE
    
    iptables -A FORWARD -p tcp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j ACCEPT
    iptables -A FORWARD -p tcp -s ${LANDING_IPV4} --sport ${LANDING_PORT} -j ACCEPT
    iptables -A FORWARD -p udp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j ACCEPT
    iptables -A FORWARD -p udp -s ${LANDING_IPV4} --sport ${LANDING_PORT} -j ACCEPT
}

setup_ipv6_rules() {
    echo ">>> 设置 IPv6 中转规则（$TRANSIT_PORT -> ${LANDING_IPV6}:${LANDING_PORT}）"
    
    # 清理旧规则
    ip6tables -t nat -D PREROUTING -p tcp --dport ${TRANSIT_PORT} -j DNAT --to-destination [${LANDING_IPV6}]:${LANDING_PORT} 2>/dev/null || true
    ip6tables -t nat -D PREROUTING -p udp --dport ${TRANSIT_PORT} -j DNAT --to-destination [${LANDING_IPV6}]:${LANDING_PORT} 2>/dev/null || true
    ip6tables -t nat -D POSTROUTING -p tcp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j MASQUERADE 2>/dev/null || true
    ip6tables -t nat -D POSTROUTING -p udp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j MASQUERADE 2>/dev/null || true
    
    # 添加新规则
    ip6tables -t nat -A PREROUTING -p tcp --dport ${TRANSIT_PORT} -j DNAT --to-destination [${LANDING_IPV6}]:${LANDING_PORT}
    ip6tables -t nat -A PREROUTING -p udp --dport ${TRANSIT_PORT} -j DNAT --to-destination [${LANDING_IPV6}]:${LANDING_PORT}
    ip6tables -t nat -A POSTROUTING -p tcp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j MASQUERADE
    ip6tables -t nat -A POSTROUTING -p udp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j MASQUERADE
    
    ip6tables -A FORWARD -p tcp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j ACCEPT
    ip6tables -A FORWARD -p tcp -s ${LANDING_IPV6} --sport ${LANDING_PORT} -j ACCEPT
    ip6tables -A FORWARD -p udp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j ACCEPT
    ip6tables -A FORWARD -p udp -s ${LANDING_IPV6} --sport ${LANDING_PORT} -j ACCEPT
}

### ====== Alpine 特定函数 ======
setup_alpine() {
    echo ">>> Alpine: 安装 iptables 工具"
    apk add iptables ip6tables 2>/dev/null || true
    
    echo ">>> Alpine: 加载内核模块"
    modprobe ip_tables 2>/dev/null || true
    modprobe ip6_tables 2>/dev/null || true
    modprobe nf_nat 2>/dev/null || true
    
    # 执行通用配置
    setup_ip_forward
    open_ports
    setup_ipv4_rules
    setup_ipv6_rules
    
    echo ">>> Alpine: 保存 iptables 规则"
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
    
    echo ">>> Alpine: 创建开机启动脚本"
    cat > /etc/local.d/iptables.start << EOF
#!/bin/sh
# 加载内核模块
modprobe ip_tables 2>/dev/null || true
modprobe ip6_tables 2>/dev/null || true
modprobe nf_nat 2>/dev/null || true
# 恢复规则
iptables-restore < /etc/iptables/rules.v4 2>/dev/null || true
ip6tables-restore < /etc/iptables/rules.v6 2>/dev/null || true
EOF
    chmod +x /etc/local.d/iptables.start
    
    # 确保 local 服务启用
    rc-update add local default 2>/dev/null || true
    
    echo ">>> Alpine: 配置完成"
}

### ====== Debian/Ubuntu 特定函数 ======
setup_debian() {
    echo ">>> Debian/Ubuntu: 安装 iptables-persistent"
    apt-get update 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent 2>/dev/null || true
    
    # 执行通用配置
    setup_ip_forward
    open_ports
    setup_ipv4_rules
    setup_ipv6_rules
    
    echo ">>> Debian/Ubuntu: 保存 iptables 规则"
    # 尝试使用 netfilter-persistent 保存
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save 2>/dev/null || true
    fi
    
    # 同时手动保存到默认位置
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
    
    echo ">>> Debian/Ubuntu: 确保 iptables 服务启用"
    systemctl enable netfilter-persistent 2>/dev/null || true
    systemctl restart netfilter-persistent 2>/dev/null || true
    
    echo ">>> Debian/Ubuntu: 配置完成"
}

### ====== 主执行逻辑 ======
case "$OS_TYPE" in
    "alpine")
        setup_alpine
        ;;
    "debian")
        setup_debian
        ;;
    *)
        echo "错误: 不支持的操作系统"
        exit 1
        ;;
esac

echo ">>> 中转规则及端口放行已完成 ✅"
echo ">>> 系统重启后规则将自动生效"