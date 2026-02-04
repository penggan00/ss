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
### =====================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检测系统类型
detect_system() {
    info "检测系统信息..."
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$ID
        OS_VERSION=$VERSION_ID
        OS_PRETTY_NAME=$PRETTY_NAME
    elif [ -f /etc/alpine-release ]; then
        OS_NAME="alpine"
        OS_VERSION=$(cat /etc/alpine-release)
        OS_PRETTY_NAME="Alpine Linux $OS_VERSION"
    elif [ -f /etc/debian_version ]; then
        OS_NAME="debian"
        OS_VERSION=$(cat /etc/debian_version)
        OS_PRETTY_NAME="Debian $OS_VERSION"
    else
        OS_NAME="unknown"
        OS_VERSION="unknown"
        OS_PRETTY_NAME="Unknown"
    fi
    
    info "系统: $OS_PRETTY_NAME"
    echo "$OS_NAME"
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 强制检查并安装 ip6tables
ensure_ip6tables() {
    info "确保 ip6tables 可用..."
    
    if ! command_exists ip6tables; then
        warning "ip6tables 未安装，尝试安装..."
        
        case "$OS_NAME" in
            alpine)
                apk add --no-cache ip6tables 2>/dev/null
                ;;
            debian|ubuntu)
                apt-get update -qq >/dev/null
                apt-get install -y -qq ip6tables 2>/dev/null
                ;;
        esac
        
        if command_exists ip6tables; then
            success "ip6tables 安装成功"
        else
            error "无法安装 ip6tables，IPv6 中转可能无法工作"
            return 1
        fi
    fi
    return 0
}

# 强制启用 IPv6 支持
force_enable_ipv6() {
    info "强制启用 IPv6 支持..."
    
    # 加载 IPv6 内核模块
    modprobe ipv6 2>/dev/null || true
    
    # 确保 IPv6 转发启用
    sysctl -w net.ipv6.conf.all.forwarding=1 2>/dev/null
    sysctl -w net.ipv6.conf.default.forwarding=1 2>/dev/null
    
    # 持久化配置
    if ! grep -q "net.ipv6.conf.all.forwarding" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
        echo "net.ipv6.conf.default.forwarding=1" >> /etc/sysctl.conf
    fi
    
    # Alpine 特殊处理
    if [ "$OS_NAME" = "alpine" ]; then
        mkdir -p /etc/sysctl.d
        cat > /etc/sysctl.d/99-ipv6.conf << EOF
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.accept_ra=2
EOF
        sysctl -p /etc/sysctl.d/99-ipv6.conf 2>/dev/null || true
    fi
    
    sysctl -p 2>/dev/null || true
}

# 安装依赖
install_dependencies() {
    local os_name=$1
    
    info "安装必要的依赖..."
    
    case "$os_name" in
        alpine)
            apk update --quiet
            apk add --no-cache --quiet \
                iptables \
                ip6tables \
                bash \
                curl \
                grep \
                sed
            success "Alpine 依赖安装完成"
            ;;
            
        debian|ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null
            apt-get install -y -qq \
                iptables \
                ip6tables \
                netfilter-persistent \
                iptables-persistent \
                >/dev/null 2>&1
            success "Debian/Ubuntu 依赖安装完成"
            ;;
            
        *)
            error "不支持的系统: $os_name"
            return 1
            ;;
    esac
    
    # 验证安装
    if ! command_exists iptables; then
        error "iptables 安装失败"
        return 1
    fi
    
    return 0
}

# 验证 IP 地址
validate_ips() {
    info "验证 IP 地址格式..."
    
    # 验证 IPv4
    if ! echo "$LANDING_IPV4" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        error "IPv4 地址格式无效: $LANDING_IPV4"
        exit 1
    fi
    
    # 验证 IPv6（宽松验证）
    if ! echo "$LANDING_IPV6" | grep -q ':'; then
        error "IPv6 地址格式无效: $LANDING_IPV6"
        exit 1
    fi
    
    success "IP 地址验证通过"
}

# 配置 IP 转发
configure_forwarding() {
    info "配置 IP 转发..."
    
    # 启用 IPv4 转发
    sysctl -w net.ipv4.ip_forward=1 2>/dev/null
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    
    # 启用 IPv6 转发（强制）
    force_enable_ipv6
    
    # Alpine 特殊处理
    if [ "$OS_NAME" = "alpine" ]; then
        mkdir -p /etc/sysctl.d
        cat > /etc/sysctl.d/99-forwarding.conf << EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
EOF
        sysctl -p /etc/sysctl.d/99-forwarding.conf 2>/dev/null || true
    fi
    
    sysctl -p 2>/dev/null || true
    success "IP 转发配置完成"
}

# 配置防火墙规则
configure_firewall() {
    info "配置防火墙规则..."
    
    # 确保 ip6tables 可用
    ensure_ip6tables
    
    # 使用兼容性更好的命令选项
    local ipt_cmd="iptables -w"
    local ip6t_cmd="ip6tables -w"
    
    # 放行端口
    info "放行端口: ${OPEN_PORTS[*]}"
    for port in "${OPEN_PORTS[@]}"; do
        # IPv4
        $ipt_cmd -A INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
        $ipt_cmd -A INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || true
        
        # IPv6（强制设置）
        $ip6t_cmd -A INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
        $ip6t_cmd -A INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || true
    done
    
    # 清理旧的 IPv4 规则
    info "清理旧的中转规则..."
    $ipt_cmd -t nat -F PREROUTING 2>/dev/null || true
    $ip6t_cmd -t nat -F PREROUTING 2>/dev/null || true
    
    # 配置 IPv4 中转
    info "配置 IPv4 中转: $TRANSIT_PORT -> $LANDING_IPV4:$LANDING_PORT"
    $ipt_cmd -t nat -A PREROUTING -p tcp --dport $TRANSIT_PORT -j DNAT --to-destination $LANDING_IPV4:$LANDING_PORT
    $ipt_cmd -t nat -A PREROUTING -p udp --dport $TRANSIT_PORT -j DNAT --to-destination $LANDING_IPV4:$LANDING_PORT
    $ipt_cmd -t nat -A POSTROUTING -p tcp -d $LANDING_IPV4 --dport $LANDING_PORT -j MASQUERADE
    $ipt_cmd -t nat -A POSTROUTING -p udp -d $LANDING_IPV4 --dport $LANDING_PORT -j MASQUERADE
    
    # 配置 IPv6 中转（强制设置，无论检测结果如何）
    info "配置 IPv6 中转: $TRANSIT_PORT -> [$LANDING_IPV6]:$LANDING_PORT"
    if command_exists ip6tables; then
        $ip6t_cmd -t nat -A PREROUTING -p tcp --dport $TRANSIT_PORT -j DNAT --to-destination "[$LANDING_IPV6]:$LANDING_PORT"
        $ip6t_cmd -t nat -A PREROUTING -p udp --dport $TRANSIT_PORT -j DNAT --to-destination "[$LANDING_IPV6]:$LANDING_PORT"
        $ip6t_cmd -t nat -A POSTROUTING -p tcp -d $LANDING_IPV6 --dport $LANDING_PORT -j MASQUERADE
        $ip6t_cmd -t nat -A POSTROUTING -p udp -d $LANDING_IPV6 --dport $LANDING_PORT -j MASQUERADE
        success "IPv6 中转规则已设置"
    else
        error "无法设置 IPv6 规则，ip6tables 不可用"
    fi
    
    # 放行转发
    $ipt_cmd -A FORWARD -p tcp -d $LANDING_IPV4 --dport $LANDING_PORT -j ACCEPT
    $ipt_cmd -A FORWARD -p udp -d $LANDING_IPV4 --dport $LANDING_PORT -j ACCEPT
    
    if command_exists ip6tables; then
        $ip6t_cmd -A FORWARD -p tcp -d $LANDING_IPV6 --dport $LANDING_PORT -j ACCEPT
        $ip6t_cmd -A FORWARD -p udp -d $LANDING_IPV6 --dport $LANDING_PORT -j ACCEPT
    fi
}

# 持久化规则
persist_rules() {
    info "保存防火墙规则..."
    
    case "$OS_NAME" in
        alpine)
            # Alpine 保存规则
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            
            # 创建开机启动脚本
            cat > /etc/local.d/firewall.start << 'EOF'
#!/bin/sh
# 加载防火墙规则
if [ -f /etc/iptables/rules.v4 ]; then
    iptables-restore < /etc/iptables/rules.v4
fi
if [ -f /etc/iptables/rules.v6 ]; then
    ip6tables-restore < /etc/iptables/rules.v6
fi
EOF
            chmod +x /etc/local.d/firewall.start
            
            # 添加到启动项
            if command_exists rc-update; then
                rc-update add local default 2>/dev/null || true
            fi
            ;;
            
        debian|ubuntu)
            # Debian 保存规则
            if command_exists netfilter-persistent; then
                netfilter-persistent save 2>/dev/null || true
            else
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            fi
            ;;
    esac
}

# 验证配置
verify_configuration() {
    info "验证配置..."
    
    echo ""
    echo "=== IPv4 规则检查 ==="
    if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "$TRANSIT_PORT.*$LANDING_IPV4:$LANDING_PORT"; then
        success "✓ IPv4 转发规则设置成功"
        iptables -t nat -L PREROUTING -n | grep -E "$TRANSIT_PORT|$LANDING_IPV4"
    else
        error "✗ IPv4 转发规则设置失败"
    fi
    
    echo ""
    echo "=== IPv6 规则检查 ==="
    if command_exists ip6tables; then
        if ip6tables -t nat -L PREROUTING -n 2>/dev/null | grep -q "$TRANSIT_PORT.*$LANDING_IPV6"; then
            success "✓ IPv6 转发规则设置成功"
            ip6tables -t nat -L PREROUTING -n | grep -E "$TRANSIT_PORT|$LANDING_IPV6"
        else
            error "✗ IPv6 转发规则设置失败"
        fi
    else
        error "✗ ip6tables 不可用，无法检查 IPv6 规则"
    fi
}

# 主函数
main() {
    echo "=========================================="
    echo "     双栈中转配置脚本 (Alpine/Debian)"
    echo "=========================================="
    
    # 检查 root 权限
    if [ "$EUID" -ne 0 ]; then
        if command_exists sudo; then
            info "使用 sudo 重新运行..."
            exec sudo "$0" "$@"
        else
            error "需要 root 权限运行此脚本"
            exit 1
        fi
    fi
    
    # 检测系统
    OS_NAME=$(detect_system)
    
    # 只支持 Alpine 和 Debian
    if [ "$OS_NAME" != "alpine" ] && [ "$OS_NAME" != "debian" ] && [ "$OS_NAME" != "ubuntu" ]; then
        error "只支持 Alpine 和 Debian/Ubuntu 系统"
        exit 1
    fi
    
    # 验证 IP 地址
    validate_ips
    
    # 安装依赖
    if ! command_exists iptables || ! command_exists ip6tables; then
        install_dependencies "$OS_NAME"
    fi
    
    # 配置转发
    configure_forwarding
    
    # 配置防火墙
    configure_firewall
    
    # 持久化规则
    persist_rules
    
    # 验证配置
    verify_configuration
    
    echo ""
    success "双栈中转配置完成！"
    echo ""
    info "配置摘要："
    echo "  中转端口: $TRANSIT_PORT"
    echo "  IPv4 目标: $LANDING_IPV4:$LANDING_PORT"
    echo "  IPv6 目标: [$LANDING_IPV6]:$LANDING_PORT"
    echo "  开放端口: ${OPEN_PORTS[*]}"
    echo ""
    info "测试命令："
    echo "  # 查看 IPv4 规则"
    echo "  iptables -t nat -L PREROUTING -n -v"
    echo ""
    echo "  # 查看 IPv6 规则"
    echo "  ip6tables -t nat -L PREROUTING -n -v"
    echo ""
    echo "  # 测试连接"
    echo "  nc -zv 本机IP $TRANSIT_PORT"
    echo ""
    
    # 检查系统重启后规则是否会自动加载
    if [ "$OS_NAME" = "alpine" ]; then
        info "Alpine 注意："
        echo "  规则已保存到 /etc/iptables/"
        echo "  开机启动脚本: /etc/local.d/firewall.start"
        echo "  确保 local 服务已启用: rc-update add local default"
    elif [ "$OS_NAME" = "debian" ] || [ "$OS_NAME" = "ubuntu" ]; then
        info "Debian/Ubuntu 注意："
        echo "  规则已通过 netfilter-persistent 保存"
        echo "  重启后规则会自动加载"
    fi
}

# 执行
main "$@"