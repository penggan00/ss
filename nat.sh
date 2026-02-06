#!/bin/bash
set -e

### ====== 颜色定义（可读性提升） ======
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

### ====== 参数 ======
if [ $# -lt 3 ]; then
    echo -e "${RED}用法:${NC} $0 <LANDING_IPV4> <LANDING_IPV6> <端口1> [端口2 端口3 ...]"
    exit 1
fi

LANDING_IPV4="$1"
LANDING_IPV6="$2"

TRANSIT_PORT=51300
LANDING_PORT=51200

# 🔧 修改这里：从第3个参数开始获取端口列表
shift 2  # 移除前两个IP参数
OPEN_PORTS=("$@")  # 剩下的所有参数都是端口

echo -e "${GREEN}>>>${NC} 目标 IPv4: $LANDING_IPV4"
echo -e "${GREEN}>>>${NC} 目标 IPv6: $LANDING_IPV6"
echo -e "${GREEN}>>>${NC} 开放端口: ${OPEN_PORTS[*]}"
echo -e "${GREEN}>>>${NC} 中转端口: $TRANSIT_PORT"
echo -e "${GREEN}>>>${NC} 落地端口: $LANDING_PORT"

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
echo -e "${GREEN}>>>${NC} 检测到系统类型: $OS_TYPE"

if [ "$OS_TYPE" = "unknown" ]; then
    echo -e "${RED}错误:${NC} 不支持的操作系统"
    exit 1
fi

### ====== 依赖检测和安装 ======
install_dependencies() {
    echo -e "${GREEN}>>>${NC} 检测并安装必要依赖"
    
    case "$OS_TYPE" in
        "alpine")
            # Alpine Linux
            local to_install=""
            
            # 检测 iptables
            if ! command -v iptables >/dev/null 2>&1; then
                echo -e "${YELLOW}   - 需要安装 iptables${NC}"
                to_install="$to_install iptables"
            fi
            
            # 检测 ip6tables
            if ! command -v ip6tables >/dev/null 2>&1; then
                echo -e "${YELLOW}   - 需要安装 ip6tables${NC}"
                to_install="$to_install ip6tables"
            fi
            
            # 检测 netcat (nc)
            if ! command -v nc >/dev/null 2>&1; then
                echo -e "${YELLOW}   - 需要安装 netcat-openbsd${NC}"
                to_install="$to_install netcat-openbsd"
            fi
            
            # 检测 ss (socket statistics)
            if ! command -v ss >/dev/null 2>&1; then
                echo -e "${YELLOW}   - 需要安装 iproute2${NC}"
                to_install="$to_install iproute2"
            fi
            
            # 检测 curl/wget (网络测试工具)
            if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
                echo -e "${YELLOW}   - 需要安装 curl${NC}"
                to_install="$to_install curl"
            fi
            
            # 安装必要的包
            if [ -n "$to_install" ]; then
                echo -e "${BLUE}>>>${NC} 安装依赖: $to_install"
                apk update 2>/dev/null || true
                apk add $to_install 2>/dev/null || {
                    echo -e "${RED}错误:${NC} 依赖安装失败"
                    exit 1
                }
                echo -e "${GREEN}>>>${NC} 依赖安装完成"
            else
                echo -e "${GREEN}>>>${NC} 所有必要依赖已安装"
            fi
            ;;
            
        "debian")
            # Debian/Ubuntu
            local to_install=""
            
            # 检测 iptables
            if ! command -v iptables >/dev/null 2>&1; then
                echo -e "${YELLOW}   - 需要安装 iptables${NC}"
                to_install="$to_install iptables"
            fi
            
            # 检测 netcat
            if ! command -v nc >/dev/null 2>&1; then
                echo -e "${YELLOW}   - 需要安装 netcat${NC}"
                to_install="$to_install netcat"
            fi
            
            # 检测 iptables-persistent
            if ! dpkg -l | grep -q iptables-persistent; then
                echo -e "${YELLOW}   - 需要安装 iptables-persistent${NC}"
                to_install="$to_install iptables-persistent"
            fi
            
            # 检测 curl/wget
            if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
                echo -e "${YELLOW}   - 需要安装 curl${NC}"
                to_install="$to_install curl"
            fi
            
            # 安装必要的包
            if [ -n "$to_install" ]; then
                echo -e "${BLUE}>>>${NC} 安装依赖: $to_install"
                apt-get update 2>/dev/null || true
                DEBIAN_FRONTEND=noninteractive apt-get install -y $to_install 2>/dev/null || {
                    echo -e "${RED}错误:${NC} 依赖安装失败"
                    exit 1
                }
                echo -e "${GREEN}>>>${NC} 依赖安装完成"
            else
                echo -e "${GREEN}>>>${NC} 所有必要依赖已安装"
            fi
            ;;
    esac
    
    # 通用依赖检测（所有系统）
    echo -e "${GREEN}>>>${NC} 检测通用工具"
    
    # 检测 ping6
    if ! command -v ping6 >/dev/null 2>&1; then
        echo -e "${YELLOW}   警告: ping6 不可用，IPv6 连通性测试可能受限${NC}"
    fi
    
    # 检测 sysctl
    if ! command -v sysctl >/dev/null 2>&1; then
        echo -e "${RED}错误:${NC} sysctl 命令不可用"
        exit 1
    fi
    
    # 检测 modprobe (Alpine需要)
    if [ "$OS_TYPE" = "alpine" ] && ! command -v modprobe >/dev/null 2>&1; then
        echo -e "${RED}错误:${NC} modprobe 命令不可用"
        exit 1
    fi
    
    echo -e "${GREEN}>>>${NC} 依赖检测完成"
}

### ====== 通用函数 ======
setup_ip_forward() {
    echo -e "${GREEN}>>>${NC} 开启 IPv4 / IPv6 转发"
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    
    grep -q net.ipv4.ip_forward /etc/sysctl.conf || cat >> /etc/sysctl.conf << EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
    sysctl -p 2>/dev/null || true
}

open_ports() {
    echo -e "${GREEN}>>>${NC} 放行直接访问端口（IPv4 + IPv6）"
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
    echo -e "${GREEN}>>>${NC} 设置 IPv4 中转规则（$TRANSIT_PORT -> ${LANDING_IPV4}:${LANDING_PORT}）"
    
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
    echo -e "${GREEN}>>>${NC} 设置 IPv6 中转规则（$TRANSIT_PORT -> ${LANDING_IPV6}:${LANDING_PORT}）"
    
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
    echo -e "${GREEN}>>>${NC} Alpine: 加载内核模块"
    modprobe ip_tables 2>/dev/null || true
    modprobe ip6_tables 2>/dev/null || true
    modprobe nf_nat 2>/dev/null || true
    
    # 执行通用配置
    setup_ip_forward
    open_ports
    setup_ipv4_rules
    setup_ipv6_rules
    
    echo -e "${GREEN}>>>${NC} Alpine: 保存 iptables 规则"
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
    
    echo -e "${GREEN}>>>${NC} Alpine: 创建开机启动脚本"
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
    
    echo -e "${GREEN}>>>${NC} Alpine: 配置完成"
}

### ====== Debian/Ubuntu 特定函数 ======
setup_debian() {
    # 执行通用配置
    setup_ip_forward
    open_ports
    setup_ipv4_rules
    setup_ipv6_rules
    
    echo -e "${GREEN}>>>${NC} Debian/Ubuntu: 保存 iptables 规则"
    # 尝试使用 netfilter-persistent 保存
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save 2>/dev/null || true
    fi
    
    # 同时手动保存到默认位置
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
    
    echo -e "${GREEN}>>>${NC} Debian/Ubuntu: 确保 iptables 服务启用"
    systemctl enable netfilter-persistent 2>/dev/null || true
    systemctl restart netfilter-persistent 2>/dev/null || true
    
    echo -e "${GREEN}>>>${NC} Debian/Ubuntu: 配置完成"
}

### ====== 网络连通性测试函数 ======
test_connectivity() {
    echo -e "${GREEN}>>>${NC} 开始网络连通性测试"
    
    # 测试目标服务器 IPv4
    echo -e "${BLUE}   测试目标服务器 IPv4 连通性...${NC}"
    if timeout 3 ping -c 2 "$LANDING_IPV4" >/dev/null 2>&1; then
        echo -e "${GREEN}      ✓ IPv4 可达${NC}"
    else
        echo -e "${RED}      ✗ IPv4 不可达${NC}"
    fi
    
    # 测试目标服务器 IPv6
    echo -e "${BLUE}   测试目标服务器 IPv6 连通性...${NC}"
    if command -v ping6 >/dev/null 2>&1; then
        if timeout 3 ping6 -c 2 "$LANDING_IPV6" >/dev/null 2>&1; then
            echo -e "${GREEN}      ✓ IPv6 可达${NC}"
        else
            echo -e "${RED}      ✗ IPv6 不可达${NC}"
        fi
    else
        echo -e "${YELLOW}      ⚠ ping6 不可用，跳过 IPv6 连通性测试${NC}"
    fi
    
    # 测试 DNAT 规则
    echo -e "${BLUE}   验证 DNAT 规则...${NC}"
    if iptables -t nat -L PREROUTING -n | grep -q "dpt:$TRANSIT_PORT"; then
        echo -e "${GREEN}      ✓ IPv4 DNAT 规则存在${NC}"
    else
        echo -e "${RED}      ✗ IPv4 DNAT 规则缺失${NC}"
    fi
    
    if ip6tables -t nat -L PREROUTING -n | grep -q "dpt:$TRANSIT_PORT"; then
        echo -e "${GREEN}      ✓ IPv6 DNAT 规则存在${NC}"
    else
        echo -e "${RED}      ✗ IPv6 DNAT 规则缺失${NC}"
    fi
    
    echo -e "${GREEN}>>>${NC} 连通性测试完成"
}

### ====== 主执行逻辑 ======
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}        中转服务器配置脚本${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${BLUE}目标 IPv4:${NC} $LANDING_IPV4"
echo -e "${BLUE}目标 IPv6:${NC} $LANDING_IPV6"
echo -e "${BLUE}中转端口:${NC} $TRANSIT_PORT -> $LANDING_PORT"
echo -e "${GREEN}========================================${NC}"

# 1. 安装依赖
install_dependencies

# 2. 根据系统类型执行配置
case "$OS_TYPE" in
    "alpine")
        setup_alpine
        ;;
    "debian")
        setup_debian
        ;;
    *)
        echo -e "${RED}错误:${NC} 不支持的操作系统"
        exit 1
        ;;
esac

# 3. 网络连通性测试
test_connectivity

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}>>> 中转规则及端口放行已完成 ✅${NC}"
echo -e "${GREEN}>>> 系统重启后规则将自动生效${NC}"
echo -e "${GREEN}========================================${NC}"

# 显示最终配置摘要
echo -e "${BLUE}配置摘要:${NC}"
echo -e "  开放端口: ${OPEN_PORTS[*]}"
echo -e "  中转规则: $TRANSIT_PORT → $LANDING_IPV4:$LANDING_PORT (IPv4)"
echo -e "            $TRANSIT_PORT → [$LANDING_IPV6]:$LANDING_PORT (IPv6)"
echo -e "${GREEN}========================================${NC}"