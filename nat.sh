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

# 检测系统类型和版本
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
    elif [ -f /etc/redhat-release ]; then
        OS_NAME="rhel"
        OS_VERSION=$(cat /etc/redhat-release | sed 's/.*release \([0-9]\+\)\..*/\1/')
        OS_PRETTY_NAME=$(cat /etc/redhat-release)
    else
        OS_NAME="unknown"
        OS_VERSION="unknown"
        OS_PRETTY_NAME="Unknown"
    fi
    
    # 检测架构
    ARCH=$(uname -m)
    
    # 检测是否支持 IPv6
    if [ -f /proc/net/if_inet6 ]; then
        IPV6_SUPPORT=true
    else
        IPV6_SUPPORT=false
        warning "系统似乎不支持 IPv6，IPv6 规则可能无法生效"
    fi
    
    info "系统: $OS_PRETTY_NAME"
    info "架构: $ARCH"
    info "IPv6 支持: $IPV6_SUPPORT"
    
    echo "$OS_NAME"
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查 iptables 版本和类型
check_iptables() {
    info "检查 iptables..."
    
    if ! command_exists iptables; then
        return 1
    fi
    
    IPTABLES_VERSION=$(iptables --version 2>/dev/null | head -n1 | awk '{print $2}')
    IPTABLES_MODE=$(iptables --version 2>/dev/null | grep -o nf_tables || echo "legacy")
    
    if [ "$IPTABLES_MODE" = "nf_tables" ]; then
        info "iptables 模式: nftables 后端 (v$IPTABLES_VERSION)"
    else
        info "iptables 模式: legacy 后端 (v$IPTABLES_VERSION)"
    fi
    
    if ! command_exists ip6tables; then
        HAS_IP6TABLES=false
    else
        HAS_IP6TABLES=true
    fi
}

# 安装依赖 - 非交互式
install_dependencies() {
    local os_name=$1
    
    info "安装必要的依赖..."
    
    case "$os_name" in
        alpine)
            if command_exists apk; then
                apk update --quiet
                apk add --no-cache --quiet iptables ip6tables bash procps
                success "Alpine 依赖安装完成"
            else
                error "apk 包管理器不可用"
                return 1
            fi
            ;;
            
        debian|ubuntu)
            # 设置非交互式环境
            export DEBIAN_FRONTEND=noninteractive
            
            if command_exists apt-get; then
                apt-get update -qq >/dev/null
                apt-get install -y -qq \
                    iptables \
                    ip6tables \
                    netfilter-persistent \
                    iptables-persistent \
                    >/dev/null 2>&1
                
                # 启用服务但不启动（避免交互）
                systemctl enable netfilter-persistent >/dev/null 2>&1 || true
                success "Debian/Ubuntu 依赖安装完成"
            else
                error "apt-get 包管理器不可用"
                return 1
            fi
            ;;
            
        fedora|rhel|centos)
            # 设置非交互式
            if command_exists dnf; then
                dnf install -y -q \
                    iptables \
                    ip6tables \
                    iptables-services \
                    >/dev/null 2>&1
            elif command_exists yum; then
                yum install -y -q \
                    iptables \
                    ip6tables \
                    iptables-services \
                    >/dev/null 2>&1
            else
                error "yum/dnf 包管理器不可用"
                return 1
            fi
            
            systemctl enable iptables >/dev/null 2>&1 || true
            systemctl enable ip6tables >/dev/null 2>&1 || true
            success "RHEL/CentOS/Fedora 依赖安装完成"
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
}

# 检查内核模块
check_kernel_modules() {
    info "检查内核模块..."
    
    local modules=("nf_nat" "nf_conntrack" "iptable_nat")
    for module in "${modules[@]}"; do
        if ! lsmod | grep -q "^${module}[[:space:]]"; then
            modprobe "$module" 2>/dev/null || true
        fi
    done
}

# 主要安装流程 - 非交互式
main_install() {
    info "开始系统检查和依赖安装..."
    
    # 检测系统
    OS_NAME=$(detect_system)
    
    # 检查依赖
    check_iptables
    
    # 自动安装缺失的依赖
    if ! command_exists iptables || ! command_exists ip6tables; then
        info "发现缺失的依赖，自动安装..."
        if ! install_dependencies "$OS_NAME"; then
            error "依赖安装失败"
            exit 1
        fi
        # 重新检查
        check_iptables
    fi
    
    # 检查内核模块
    check_kernel_modules
    
    # 验证 IP 地址格式
    info "验证 IP 地址格式..."
    if ! echo "$LANDING_IPV4" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        error "IPv4 地址格式无效: $LANDING_IPV4"
        exit 1
    fi
    
    if [ "$IPV6_SUPPORT" = "true" ]; then
        if ! echo "$LANDING_IPV6" | grep -q ':'; then
            error "IPv6 地址格式无效: $LANDING_IPV6"
            exit 1
        fi
    fi
    
    success "系统检查完成"
}

# 配置转发规则
configure_forwarding() {
    info "开启 IP 转发..."
    
    # 临时启用
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    
    # 持久化配置
    case "$OS_NAME" in
        alpine)
            mkdir -p /etc/sysctl.d
            cat > /etc/sysctl.d/99-ip-forwarding.conf << EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
            sysctl -p /etc/sysctl.d/99-ip-forwarding.conf >/dev/null 2>&1
            ;;
            
        *)
            # 通用方法
            for param in net.ipv4.ip_forward net.ipv6.conf.all.forwarding; do
                if ! grep -q "^$param" /etc/sysctl.conf 2>/dev/null; then
                    echo "$param=1" >> /etc/sysctl.conf
                else
                    sed -i "s/^$param=.*/$param=1/" /etc/sysctl.conf 2>/dev/null || true
                fi
            done
            sysctl -p >/dev/null 2>&1 || true
            ;;
    esac
    
    success "IP 转发已配置"
}

# 防火墙配置函数
configure_firewall() {
    info "配置防火墙规则..."
    
    local ipt_cmd="iptables -w"
    local ip6t_cmd="ip6tables -w"
    
    # 安全删除规则
    safe_delete_rule() {
        local table="$1"
        local chain="$2"
        local rule="$3"
        local cmd="$4"
        
        $cmd -t "$table" -D "$chain" $rule 2>/dev/null || true
    }
    
    info "放行端口: ${OPEN_PORTS[*]}"
    for port in "${OPEN_PORTS[@]}"; do
        # IPv4
        $ipt_cmd -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
            $ipt_cmd -A INPUT -p tcp --dport "$port" -j ACCEPT
        $ipt_cmd -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || \
            $ipt_cmd -A INPUT -p udp --dport "$port" -j ACCEPT
        
        # IPv6
        if [ "$HAS_IP6TABLES" = "true" ]; then
            $ip6t_cmd -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
                $ip6t_cmd -A INPUT -p tcp --dport "$port" -j ACCEPT
            $ip6t_cmd -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || \
                $ip6t_cmd -A INPUT -p udp --dport "$port" -j ACCEPT
        fi
    done
    
    info "设置 IPv4 中转: $TRANSIT_PORT -> $LANDING_IPV4:$LANDING_PORT"
    
    # 清理旧规则
    safe_delete_rule nat PREROUTING "-p tcp --dport $TRANSIT_PORT -j DNAT --to-destination $LANDING_IPV4:$LANDING_PORT" "$ipt_cmd"
    safe_delete_rule nat PREROUTING "-p udp --dport $TRANSIT_PORT -j DNAT --to-destination $LANDING_IPV4:$LANDING_PORT" "$ipt_cmd"
    safe_delete_rule nat POSTROUTING "-p tcp -d $LANDING_IPV4 --dport $LANDING_PORT -j MASQUERADE" "$ipt_cmd"
    safe_delete_rule nat POSTROUTING "-p udp -d $LANDING_IPV4 --dport $LANDING_PORT -j MASQUERADE" "$ipt_cmd"
    
    # 添加新规则
    $ipt_cmd -t nat -A PREROUTING -p tcp --dport $TRANSIT_PORT -j DNAT --to-destination $LANDING_IPV4:$LANDING_PORT
    $ipt_cmd -t nat -A PREROUTING -p udp --dport $TRANSIT_PORT -j DNAT --to-destination $LANDING_IPV4:$LANDING_PORT
    $ipt_cmd -t nat -A POSTROUTING -p tcp -d $LANDING_IPV4 --dport $LANDING_PORT -j MASQUERADE
    $ipt_cmd -t nat -A POSTROUTING -p udp -d $LANDING_IPV4 --dport $LANDING_PORT -j MASQUERADE
    
    # 放行转发
    $ipt_cmd -A FORWARD -p tcp -d $LANDING_IPV4 --dport $LANDING_PORT -j ACCEPT
    $ipt_cmd -A FORWARD -p tcp -s $LANDING_IPV4 --sport $LANDING_PORT -j ACCEPT
    $ipt_cmd -A FORWARD -p udp -d $LANDING_IPV4 --dport $LANDING_PORT -j ACCEPT
    $ipt_cmd -A FORWARD -p udp -s $LANDING_IPV4 --sport $LANDING_PORT -j ACCEPT
    
    if [ "$HAS_IP6TABLES" = "true" ] && [ "$IPV6_SUPPORT" = "true" ]; then
        info "设置 IPv6 中转: $TRANSIT_PORT -> $LANDING_IPV6:$LANDING_PORT"
        
        # 清理旧规则
        safe_delete_rule nat PREROUTING "-p tcp --dport $TRANSIT_PORT -j DNAT --to-destination [$LANDING_IPV6]:$LANDING_PORT" "$ip6t_cmd"
        safe_delete_rule nat PREROUTING "-p udp --dport $TRANSIT_PORT -j DNAT --to-destination [$LANDING_IPV6]:$LANDING_PORT" "$ip6t_cmd"
        safe_delete_rule nat POSTROUTING "-p tcp -d $LANDING_IPV6 --dport $LANDING_PORT -j MASQUERADE" "$ip6t_cmd"
        safe_delete_rule nat POSTROUTING "-p udp -d $LANDING_IPV6 --dport $LANDING_PORT -j MASQUERADE" "$ip6t_cmd"
        
        # 添加新规则
        $ip6t_cmd -t nat -A PREROUTING -p tcp --dport $TRANSIT_PORT -j DNAT --to-destination "[$LANDING_IPV6]:$LANDING_PORT"
        $ip6t_cmd -t nat -A PREROUTING -p udp --dport $TRANSIT_PORT -j DNAT --to-destination "[$LANDING_IPV6]:$LANDING_PORT"
        $ip6t_cmd -t nat -A POSTROUTING -p tcp -d $LANDING_IPV6 --dport $LANDING_PORT -j MASQUERADE
        $ip6t_cmd -t nat -A POSTROUTING -p udp -d $LANDING_IPV6 --dport $LANDING_PORT -j MASQUERADE
        
        # 放行转发
        $ip6t_cmd -A FORWARD -p tcp -d $LANDING_IPV6 --dport $LANDING_PORT -j ACCEPT
        $ip6t_cmd -A FORWARD -p tcp -s $LANDING_IPV6 --sport $LANDING_PORT -j ACCEPT
        $ip6t_cmd -A FORWARD -p udp -d $LANDING_IPV6 --dport $LANDING_PORT -j ACCEPT
        $ip6t_cmd -A FORWARD -p udp -s $LANDING_IPV6 --sport $LANDING_PORT -j ACCEPT
    fi
}

# 持久化防火墙规则
persist_firewall_rules() {
    info "保存防火墙规则..."
    
    case "$OS_NAME" in
        alpine)
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
            if [ "$HAS_IP6TABLES" = "true" ]; then
                ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
            fi
            
            # 创建开机启动脚本
            cat > /etc/local.d/iptables.start << 'EOF'
#!/bin/sh
if [ -f /etc/iptables/rules.v4 ]; then
    iptables-restore < /etc/iptables/rules.v4
fi
if [ -f /etc/iptables/rules.v6 ]; then
    ip6tables-restore < /etc/iptables/rules.v6
fi
EOF
            chmod +x /etc/local.d/iptables.start
            
            if command_exists rc-update; then
                rc-update add local default 2>/dev/null || true
            fi
            ;;
            
        debian|ubuntu)
            if command_exists netfilter-persistent; then
                netfilter-persistent save >/dev/null 2>&1 || true
            else
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null
                if [ "$HAS_IP6TABLES" = "true" ]; then
                    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
                fi
            fi
            ;;
            
        fedora|rhel|centos)
            iptables-save > /etc/sysconfig/iptables 2>/dev/null
            if [ "$HAS_IP6TABLES" = "true" ]; then
                ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null
            fi
            ;;
    esac
}

# 验证配置
verify_configuration() {
    info "验证配置..."
    
    # 检查 IPv4 规则
    if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "$TRANSIT_PORT.*$LANDING_IPV4:$LANDING_PORT"; then
        success "IPv4 转发规则设置成功"
    else
        error "IPv4 转发规则设置失败"
    fi
    
    # 检查 IPv6 规则
    if [ "$HAS_IP6TABLES" = "true" ]; then
        if ip6tables -t nat -L PREROUTING -n 2>/dev/null | grep -q "$TRANSIT_PORT.*$LANDING_IPV6.*$LANDING_PORT"; then
            success "IPv6 转发规则设置成功"
        else
            warning "IPv6 转发规则未设置"
        fi
    fi
}

# 主执行流程 - 完全非交互
main() {
    echo "=========================================="
    echo "     智能中转服务器配置脚本 (非交互版)"
    echo "=========================================="
    
    # 检查 root 权限
    if [ "$EUID" -ne 0 ]; then
        # 尝试自动使用 sudo 重新运行
        if command_exists sudo; then
            info "尝试使用 sudo 重新运行..."
            exec sudo "$0" "$@"
        else
            error "需要 root 权限运行此脚本"
            exit 1
        fi
    fi
    
    # 运行安装前检查
    main_install
    
    # 配置 IP 转发
    configure_forwarding
    
    # 配置防火墙
    configure_firewall
    
    # 持久化规则
    persist_firewall_rules
    
    # 验证配置
    verify_configuration
    
    success "中转服务配置完成！"
    echo ""
    info "配置摘要："
    echo "  - 中转端口: $TRANSIT_PORT"
    echo "  - 目标 IPv4: $LANDING_IPV4:$LANDING_PORT"
    echo "  - 目标 IPv6: $LANDING_IPV6:$LANDING_PORT"
    echo "  - 开放端口: ${OPEN_PORTS[*]}"
    echo ""
    info "测试命令："
    echo "  iptables -t nat -L -n -v | grep $TRANSIT_PORT"
    if [ "$HAS_IP6TABLES" = "true" ]; then
        echo "  ip6tables -t nat -L -n -v | grep $TRANSIT_PORT"
    fi
}

# 执行主函数
main "$@"