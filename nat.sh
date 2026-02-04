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

# 检测系统类型 - 改进版
detect_system() {
    info "检测系统信息..."
    
    # 先检查 Alpine
    if [ -f /etc/alpine-release ]; then
        OS_NAME="alpine"
        OS_VERSION=$(cat /etc/alpine-release)
        OS_PRETTY_NAME="Alpine Linux v$OS_VERSION"
        
    # 检查 Debian
    elif [ -f /etc/debian_version ]; then
        OS_NAME="debian"
        OS_VERSION=$(cat /etc/debian_version)
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            OS_PRETTY_NAME="$PRETTY_NAME"
        else
            OS_PRETTY_NAME="Debian $OS_VERSION"
        fi
        
    # 检查 Ubuntu
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" = "ubuntu" ] || [ "$ID" = "debian" ]; then
            OS_NAME="$ID"
            OS_VERSION="$VERSION_ID"
            OS_PRETTY_NAME="$PRETTY_NAME"
        else
            OS_NAME="unknown"
            OS_VERSION="unknown"
            OS_PRETTY_NAME="Unknown"
        fi
    else
        OS_NAME="unknown"
        OS_VERSION="unknown"
        OS_PRETTY_NAME="Unknown"
    fi
    
    # 检测架构和内核
    ARCH=$(uname -m)
    KERNEL=$(uname -r)
    
    # 检测 IPv6 支持
    if [ -f /proc/net/if_inet6 ] || lsmod | grep -q ipv6; then
        IPV6_SUPPORT=true
    else
        IPV6_SUPPORT=false
        warning "IPv6 内核支持未检测到，尝试加载模块..."
        modprobe ipv6 2>/dev/null && IPV6_SUPPORT=true || IPV6_SUPPORT=false
    fi
    
    info "系统: $OS_PRETTY_NAME"
    info "架构: $ARCH"
    info "内核: $KERNEL"
    info "IPv6 支持: $IPV6_SUPPORT"
    
    if [ "$OS_NAME" = "alpine" ] || [ "$OS_NAME" = "debian" ] || [ "$OS_NAME" = "ubuntu" ]; then
        echo "$OS_NAME"
    else
        error "检测到不支持的系统: $OS_PRETTY_NAME"
        error "本脚本仅支持 Alpine Linux 和 Debian/Ubuntu 系统"
        exit 1
    fi
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 强制安装 ip6tables
force_install_ip6tables() {
    info "检查并安装 ip6tables..."
    
    if command_exists ip6tables; then
        info "ip6tables 已安装"
        return 0
    fi
    
    warning "ip6tables 未安装，尝试自动安装..."
    
    case "$OS_NAME" in
        alpine)
            apk update --quiet
            apk add --no-cache --quiet ip6tables 2>/dev/null
            ;;
        debian|ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq ip6tables >/dev/null 2>&1
            ;;
    esac
    
    if command_exists ip6tables; then
        success "ip6tables 安装成功"
        return 0
    else
        error "ip6tables 安装失败"
        return 1
    fi
}

# 安装依赖
install_dependencies() {
    info "安装系统依赖..."
    
    case "$OS_NAME" in
        alpine)
            info "Alpine Linux 安装依赖..."
            apk update --quiet
            apk add --no-cache --quiet \
                iptables \
                ip6tables \
                bash \
                curl \
                grep \
                sed \
                coreutils \
                procps 2>/dev/null
            success "Alpine 依赖安装完成"
            ;;
            
        debian|ubuntu)
            info "Debian/Ubuntu 安装依赖..."
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq \
                iptables \
                ip6tables \
                netfilter-persistent \
                iptables-persistent \
                >/dev/null 2>&1
            success "Debian/Ubuntu 依赖安装完成"
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
    info "验证 IP 地址..."
    
    # 验证 IPv4
    if ! echo "$LANDING_IPV4" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        error "IPv4 地址格式无效: $LANDING_IPV4"
        exit 1
    else
        info "IPv4 地址有效: $LANDING_IPV4"
    fi
    
    # 验证 IPv6（宽松验证）
    if ! echo "$LANDING_IPV6" | grep -q ':'; then
        error "IPv6 地址格式无效: $LANDING_IPV6"
        exit 1
    else
        info "IPv6 地址有效: $LANDING_IPV6"
    fi
    
    success "IP 地址验证通过"
}

# 配置 IP 转发
configure_forwarding() {
    info "配置 IP 转发..."
    
    # 启用 IPv4 转发
    sysctl -w net.ipv4.ip_forward=1 2>/dev/null
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    
    # 启用 IPv6 转发
    sysctl -w net.ipv6.conf.all.forwarding=1 2>/dev/null
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    
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
    
    # 重新加载 sysctl
    sysctl -p 2>/dev/null || true
    success "IP 转发配置完成"
}

# 配置防火墙规则
configure_firewall() {
    info "配置防火墙规则..."
    
    # 确保 ip6tables 可用
    force_install_ip6tables
    
    # 使用简化的命令（避免复杂的检查）
    local ipt_cmd="iptables"
    local ip6t_cmd="ip6tables"
    
    # 清理旧规则（简化版）
    info "清理旧规则..."
    $ipt_cmd -t nat -F PREROUTING 2>/dev/null || true
    $ip6t_cmd -t nat -F PREROUTING 2>/dev/null || true
    
    # 放行端口
    info "放行端口: ${OPEN_PORTS[*]}"
    for port in "${OPEN_PORTS[@]}"; do
        # IPv4
        $ipt_cmd -A INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
        $ipt_cmd -A INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || true
        
        # IPv6
        $ip6t_cmd -A INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
        $ip6t_cmd -A INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || true
    done
    
    # 配置 IPv4 中转
    info "配置 IPv4 中转: $TRANSIT_PORT -> $LANDING_IPV4:$LANDING_PORT"
    $ipt_cmd -t nat -A PREROUTING -p tcp --dport $TRANSIT_PORT -j DNAT --to-destination $LANDING_IPV4:$LANDING_PORT
    $ipt_cmd -t nat -A PREROUTING -p udp --dport $TRANSIT_PORT -j DNAT --to-destination $LANDING_IPV4:$LANDING_PORT
    $ipt_cmd -t nat -A POSTROUTING -p tcp -d $LANDING_IPV4 --dport $LANDING_PORT -j MASQUERADE
    $ipt_cmd -t nat -A POSTROUTING -p udp -d $LANDING_IPV4 --dport $LANDING_PORT -j MASQUERADE
    
    # 配置 IPv6 中转
    info "配置 IPv6 中转: $TRANSIT_PORT -> [$LANDING_IPV6]:$LANDING_PORT"
    if command_exists ip6tables; then
        $ip6t_cmd -t nat -A PREROUTING -p tcp --dport $TRANSIT_PORT -j DNAT --to-destination "[$LANDING_IPV6]:$LANDING_PORT"
        $ip6t_cmd -t nat -A PREROUTING -p udp --dport $TRANSIT_PORT -j DNAT --to-destination "[$LANDING_IPV6]:$LANDING_PORT"
        $ip6t_cmd -t nat -A POSTROUTING -p tcp -d $LANDING_IPV6 --dport $LANDING_PORT -j MASQUERADE
        $ip6t_cmd -t nat -A POSTROUTING -p udp -d $LANDING_IPV6 --dport $LANDING_PORT -j MASQUERADE
        success "IPv6 中转规则已设置"
    else
        error "ip6tables 不可用，跳过 IPv6 规则"
    fi
    
    # 放行转发
    $ipt_cmd -A FORWARD -p tcp -d $LANDING_IPV4 --dport $LANDING_PORT -j ACCEPT
    $ipt_cmd -A FORWARD -p udp -d $LANDING_IPV4 --dport $LANDING_PORT -j ACCEPT
    
    if command_exists ip6tables; then
        $ip6t_cmd -A FORWARD -p tcp -d $LANDING_IPV6 --dport $LANDING_PORT -j ACCEPT
        $ip6t_cmd -A FORWARD -p udp -d $LANDING_IPV6 --dport $LANDING_PORT -j ACCEPT
    fi
    
    success "防火墙规则配置完成"
}

# 持久化规则
persist_rules() {
    info "保存防火墙规则..."
    
    case "$OS_NAME" in
        alpine)
            # Alpine: 保存到 /etc/iptables/
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            
            # 创建开机启动脚本
            cat > /etc/local.d/nat-rules.start << 'EOF'
#!/bin/sh
# 加载 NAT 转发规则
if [ -f /etc/iptables/rules.v4 ]; then
    iptables-restore < /etc/iptables/rules.v4
fi
if [ -f /etc/iptables/rules.v6 ]; then
    ip6tables-restore < /etc/iptables/rules.v6
fi
EOF
            chmod +x /etc/local.d/nat-rules.start
            
            # 如果使用 openrc，添加到启动
            if command_exists rc-update && ! rc-update show | grep -q local; then
                rc-update add local default 2>/dev/null || true
            fi
            
            info "Alpine: 规则已保存到 /etc/iptables/"
            info "        开机启动脚本: /etc/local.d/nat-rules.start"
            ;;
            
        debian|ubuntu)
            # Debian/Ubuntu: 使用 netfilter-persistent
            if command_exists netfilter-persistent; then
                netfilter-persistent save 2>/dev/null || true
                info "规则已通过 netfilter-persistent 保存"
            else
                # 备选方案
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
                
                # 创建 systemd 服务（Debian 12）
                if [ -d /etc/systemd/system ]; then
                    cat > /etc/systemd/system/load-iptables.service << EOF
[Unit]
Description=Load iptables rules
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore < /etc/iptables/rules.v4
ExecStart=/sbin/ip6tables-restore < /etc/iptables/rules.v6
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
                    systemctl enable load-iptables.service 2>/dev/null || true
                fi
                info "规则已保存到 /etc/iptables/"
            fi
            ;;
    esac
    
    success "规则持久化完成"
}

# 验证配置
verify_configuration() {
    info "验证配置..."
    
    echo ""
    echo "========== IPv4 规则检查 =========="
    if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "$TRANSIT_PORT.*$LANDING_IPV4"; then
        success "✓ IPv4 转发规则设置成功"
        echo "规则详情:"
        iptables -t nat -L PREROUTING -n | grep -B1 -A1 "$TRANSIT_PORT"
    else
        error "✗ IPv4 转发规则设置失败"
    fi
    
    echo ""
    echo "========== IPv6 规则检查 =========="
    if command_exists ip6tables; then
        if ip6tables -t nat -L PREROUTING -n 2>/dev/null | grep -q "$TRANSIT_PORT.*$LANDING_IPV6"; then
            success "✓ IPv6 转发规则设置成功"
            echo "规则详情:"
            ip6tables -t nat -L PREROUTING -n | grep -B1 -A1 "$TRANSIT_PORT"
        else
            error "✗ IPv6 转发规则设置失败"
        fi
    else
        warning "⚠ ip6tables 不可用，无法检查 IPv6 规则"
    fi
    
    echo ""
    echo "========== 端口检查 =========="
    for port in "${OPEN_PORTS[@]}"; do
        if iptables -L INPUT -n 2>/dev/null | grep -q "dpt:$port"; then
            echo "✓ 端口 $port (IPv4) 已放行"
        else
            echo "✗ 端口 $port (IPv4) 未放行"
        fi
        
        if command_exists ip6tables; then
            if ip6tables -L INPUT -n 2>/dev/null | grep -q "dpt:$port"; then
                echo "✓ 端口 $port (IPv6) 已放行"
            else
                echo "✗ 端口 $port (IPv6) 未放行"
            fi
        fi
    done
}

# 显示配置摘要
show_summary() {
    echo ""
    echo "=========================================="
    success "       中转服务配置完成！"
    echo "=========================================="
    echo ""
    info "配置摘要："
    echo "  系统类型: $OS_PRETTY_NAME"
    echo "  中转端口: $TRANSIT_PORT"
    echo "  IPv4 目标: $LANDING_IPV4:$LANDING_PORT"
    echo "  IPv6 目标: [$LANDING_IPV6]:$LANDING_PORT"
    echo "  开放端口: ${OPEN_PORTS[*]}"
    echo ""
    
    info "测试命令："
    echo "  # 查看 IPv4 NAT 规则"
    echo "  iptables -t nat -L PREROUTING -n -v"
    echo ""
    echo "  # 查看 IPv6 NAT 规则"
    echo "  ip6tables -t nat -L PREROUTING -n -v"
    echo ""
    echo "  # 测试连接"
    echo "  nc -zv 本机IP $TRANSIT_PORT"
    echo "  nc -zv 本机IPv6 $TRANSIT_PORT"
    echo ""
    
    # 获取本机IP
    LOCAL_IPV4=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    LOCAL_IPV6=$(ip -6 addr show scope global | grep -oP '(?<=inet6\s)[0-9a-f:]+' | head -1)
    
    if [ -n "$LOCAL_IPV4" ]; then
        echo "  本机 IPv4: $LOCAL_IPV4"
    fi
    if [ -n "$LOCAL_IPV6" ]; then
        echo "  本机 IPv6: $LOCAL_IPV6"
    fi
    echo ""
    
    info "系统特定说明："
    case "$OS_NAME" in
        alpine)
            echo "  - 规则已保存到 /etc/iptables/rules.v4 和 rules.v6"
            echo "  - 开机启动脚本: /etc/local.d/nat-rules.start"
            echo "  - 确保 local 服务已启用: rc-update add local default"
            ;;
        debian|ubuntu)
            echo "  - 规则已通过 netfilter-persistent 保存"
            echo "  - 重启后规则会自动加载"
            echo "  - 如需手动重载: netfilter-persistent reload"
            ;;
    esac
}

# 主函数
main() {
    echo "=========================================="
    echo "     双栈中转配置脚本 v1.0"
    echo "     支持 Alpine Linux 和 Debian/Ubuntu"
    echo "=========================================="
    
    # 检查参数
    if [ $# -ne 2 ]; then
        echo "用法: $0 <IPv4地址> <IPv6地址>"
        echo "示例: $0 72.18.81.15 2607:f130:0:18e::17dd:18a0"
        exit 1
    fi
    
    # 检查 root 权限
    if [ "$EUID" -ne 0 ]; then
        warning "需要 root 权限，尝试使用 sudo..."
        if command_exists sudo; then
            info "使用 sudo 重新运行脚本..."
            exec sudo "$0" "$@"
        else
            error "请使用 root 用户运行此脚本"
            exit 1
        fi
    fi
    
    # 1. 检测系统
    OS_NAME=$(detect_system)
    
    # 2. 验证 IP 地址
    validate_ips
    
    # 3. 安装依赖
    if ! command_exists iptables || ! command_exists ip6tables; then
        install_dependencies "$OS_NAME"
    fi
    
    # 4. 配置 IP 转发
    configure_forwarding
    
    # 5. 配置防火墙
    configure_firewall
    
    # 6. 持久化规则
    persist_rules
    
    # 7. 验证配置
    verify_configuration
    
    # 8. 显示摘要
    show_summary
    
    echo ""
    success "所有配置已完成！"
    echo ""
}

# 异常处理
trap 'error "脚本执行中断"; exit 1' INT TERM

# 执行主函数
main "$@"