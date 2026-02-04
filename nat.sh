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
        error "iptables 未安装"
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
        warning "ip6tables 未安装，IPv6 规则将无法设置"
        HAS_IP6TABLES=false
    else
        HAS_IP6TABLES=true
    fi
}

# 安装依赖
install_dependencies() {
    local os_name=$1
    
    info "检查并安装必要的依赖..."
    
    case "$os_name" in
        alpine)
            # 更新包列表
            if command_exists apk; then
                apk update
                # 安装基础依赖
                apk add --no-cache iptables ip6tables bash
                
                # 检查是否安装成功
                if ! command_exists iptables; then
                    apk add --no-cache iptables
                fi
                
                if ! command_exists ip6tables; then
                    apk add --no-cache ip6tables
                fi
                
                # 安装 sysctl 配置工具
                if ! command_exists sysctl; then
                    apk add --no-cache procps
                fi
            else
                error "apk 包管理器不可用"
                return 1
            fi
            ;;
            
        debian|ubuntu)
            # 检查是否需要 sudo
            if [ "$EUID" -ne 0 ]; then
                warning "建议使用 root 用户运行，或者在命令前添加 sudo"
            fi
            
            if command_exists apt-get; then
                # 更新包列表
                apt-get update -qq
                
                # 安装基础依赖
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                    iptables \
                    ip6tables \
                    netfilter-persistent \
                    iptables-persistent \
                    sysctl-utils
                
                # 确保服务启用
                if systemctl is-enabled netfilter-persistent >/dev/null 2>&1; then
                    systemctl enable netfilter-persistent
                fi
            else
                error "apt-get 包管理器不可用"
                return 1
            fi
            ;;
            
        fedora|rhel|centos)
            if command_exists yum || command_exists dnf; then
                local pkg_mgr=$(command -v dnf 2>/dev/null || command -v yum 2>/dev/null)
                
                # 安装依赖
                $pkg_mgr install -y \
                    iptables \
                    ip6tables \
                    iptables-services \
                    policycoreutils \
                    sysctl-utils
                
                # 启用服务
                systemctl enable iptables
                systemctl enable ip6tables
            else
                error "yum/dnf 包管理器不可用"
                return 1
            fi
            ;;
            
        *)
            warning "未知系统类型 $os_name，请手动安装以下依赖："
            echo "  - iptables"
            echo "  - ip6tables"
            echo "  - bash"
            echo ""
            echo "请按 Enter 继续，或按 Ctrl+C 退出安装依赖"
            read -r
            ;;
    esac
    
    # 验证安装
    if ! command_exists iptables; then
        error "iptables 安装失败，请手动安装"
        return 1
    fi
    
    success "依赖安装完成"
}

# 检查内核模块
check_kernel_modules() {
    info "检查必要的内核模块..."
    
    local modules=("nf_nat" "nf_conntrack" "iptable_nat" "ip6table_nat")
    local missing_modules=()
    
    for module in "${modules[@]}"; do
        if ! lsmod | grep -q "^${module}[[:space:]]"; then
            if modprobe -n "$module" 2>/dev/null; then
                info "加载内核模块: $module"
                modprobe "$module" 2>/dev/null || warning "无法加载模块 $module，但可能不影响基本功能"
            else
                missing_modules+=("$module")
            fi
        fi
    done
    
    if [ ${#missing_modules[@]} -gt 0 ]; then
        warning "以下内核模块可能缺失: ${missing_modules[*]}"
        warning "这可能会影响 NAT 功能，建议检查内核配置"
    fi
    
    # 检查内核参数
    local kernel_version=$(uname -r)
    info "内核版本: $kernel_version"
    
    # 检查内核编译选项（如果可能）
    if [ -f "/boot/config-${kernel_version}" ] || [ -f "/proc/config.gz" ]; then
        info "检查内核 NAT 支持..."
        if zgrep -q "CONFIG_NF_NAT=y" /boot/config-${kernel_version} 2>/dev/null || 
           zcat /proc/config.gz 2>/dev/null | grep -q "CONFIG_NF_NAT=y"; then
            success "内核支持 NAT"
        else
            warning "内核可能不支持完整的 NAT 功能"
        fi
    fi
}

# 检查系统资源限制
check_system_limits() {
    info "检查系统限制..."
    
    # 检查文件描述符限制
    local fd_limit=$(ulimit -n)
    if [ "$fd_limit" -lt 1024 ]; then
        warning "文件描述符限制较低 ($fd_limit)，可能影响高并发连接"
        info "建议设置: ulimit -n 65535"
    fi
    
    # 检查 conntrack 最大连接数
    if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
        local conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
        info "conntrack 最大连接数: $conntrack_max"
        
        if [ "$conntrack_max" -lt 65536 ]; then
            warning "conntrack 限制较低，建议增加:"
            info "echo 262144 > /proc/sys/net/netfilter/nf_conntrack_max"
        fi
    fi
}

# 主要安装流程
main_install() {
    info "开始安装中转服务..."
    
    # 检测系统
    OS_NAME=$(detect_system)
    
    # 检查依赖
    check_iptables
    
    if ! command_exists iptables || ! command_exists ip6tables; then
        info "发现缺失的依赖，自动安装..."
        install_dependencies "$OS_NAME"
    fi
    
    # 检查内核模块
    check_kernel_modules
    
    # 检查系统限制
    check_system_limits
    
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
    
    success "系统检查完成，开始配置..."
}

# 配置转发规则
configure_forwarding() {
    info ">>> 开启 IPv4 / IPv6 转发"
    
    # 临时启用
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    
    # 持久化配置
    case "$OS_NAME" in
        alpine)
            # Alpine: 使用 sysctl.d 目录
            mkdir -p /etc/sysctl.d
            cat > /etc/sysctl.d/99-ip-forwarding.conf << EOF
# 启用 IP 转发 - 由中转脚本设置
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1

# 优化 conntrack 设置（可选）
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_tcp_timeout_established=1200
EOF
            sysctl -p /etc/sysctl.d/99-ip-forwarding.conf
            ;;
            
        debian|ubuntu)
            # Debian/Ubuntu: 修改 sysctl.conf
            local sysctl_file="/etc/sysctl.conf"
            local tmp_file="/tmp/sysctl.conf.$$"
            
            # 备份原文件
            cp "$sysctl_file" "${sysctl_file}.backup.$(date +%Y%m%d%H%M%S)"
            
            # 更新或添加配置
            {
                grep -v "^net.ipv4.ip_forward" "$sysctl_file" | \
                grep -v "^net.ipv6.conf.all.forwarding" | \
                grep -v "^net.ipv6.conf.default.forwarding"
                echo "net.ipv4.ip_forward=1"
                echo "net.ipv6.conf.all.forwarding=1"
                echo "net.ipv6.conf.default.forwarding=1"
            } > "$tmp_file"
            
            mv "$tmp_file" "$sysctl_file"
            sysctl -p
            ;;
            
        *)
            # 通用方法
            for param in net.ipv4.ip_forward net.ipv6.conf.all.forwarding; do
                if ! grep -q "^$param" /etc/sysctl.conf 2>/dev/null; then
                    echo "$param=1" >> /etc/sysctl.conf
                else
                    sed -i "s/^$param=.*/$param=1/" /etc/sysctl.conf
                fi
            done
            sysctl -p
            ;;
    esac
    
    success "IP 转发已配置"
}

# 防火墙配置函数
configure_firewall() {
    info ">>> 配置防火墙规则"
    
    # 使用 -w 参数防止锁冲突
    local ipt_cmd="iptables -w"
    local ip6t_cmd="ip6tables -w"
    
    # 清理函数 - 安全地删除规则
    safe_delete_rule() {
        local table="$1"
        local chain="$2"
        local rule="$3"
        local cmd="$4"
        
        # 尝试删除规则，忽略错误
        $cmd -t "$table" -D "$chain" $rule 2>/dev/null || true
    }
    
    info "放行直接访问端口（IPv4 + IPv6）"
    for port in "${OPEN_PORTS[@]}"; do
        # IPv4 TCP
        if ! $ipt_cmd -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            $ipt_cmd -A INPUT -p tcp --dport "$port" -j ACCEPT
        fi
        
        # IPv4 UDP
        if ! $ipt_cmd -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; then
            $ipt_cmd -A INPUT -p udp --dport "$port" -j ACCEPT
        fi
        
        # IPv6 TCP
        if [ "$HAS_IP6TABLES" = "true" ]; then
            if ! $ip6t_cmd -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                $ip6t_cmd -A INPUT -p tcp --dport "$port" -j ACCEPT
            fi
            
            # IPv6 UDP
            if ! $ip6t_cmd -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; then
                $ip6t_cmd -A INPUT -p udp --dport "$port" -j ACCEPT
            fi
        fi
    done
    
    info "设置 IPv4 中转规则（${TRANSIT_PORT} -> ${LANDING_IPV4}:${LANDING_PORT}）"
    
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
        info "设置 IPv6 中转规则（${TRANSIT_PORT} -> ${LANDING_IPV6}:${LANDING_PORT}）"
        
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
    info ">>> 持久化防火墙规则"
    
    case "$OS_NAME" in
        alpine)
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4
            if [ "$HAS_IP6TABLES" = "true" ]; then
                ip6tables-save > /etc/iptables/rules.v6
            fi
            
            # 创建开机启动脚本
            cat > /etc/local.d/iptables.start << 'EOF'
#!/bin/sh
# 恢复 iptables 规则
if [ -f /etc/iptables/rules.v4 ]; then
    iptables-restore < /etc/iptables/rules.v4
fi
if [ -f /etc/iptables/rules.v6 ]; then
    ip6tables-restore < /etc/iptables/rules.v6
fi
EOF
            chmod +x /etc/local.d/iptables.start
            
            # 如果使用 openrc
            if command_exists rc-update; then
                rc-update add local default 2>/dev/null || true
            fi
            
            info "Alpine: 规则已保存到 /etc/iptables/"
            info "       开机自启脚本: /etc/local.d/iptables.start"
            ;;
            
        debian|ubuntu)
            if command_exists netfilter-persistent; then
                netfilter-persistent save
            elif command_exists iptables-save; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4
                if [ "$HAS_IP6TABLES" = "true" ]; then
                    ip6tables-save > /etc/iptables/rules.v6
                fi
            fi
            
            # 确保服务启用
            if systemctl is-active netfilter-persistent >/dev/null 2>&1; then
                systemctl enable netfilter-persistent
            fi
            ;;
            
        fedora|rhel|centos)
            # 保存规则
            iptables-save > /etc/sysconfig/iptables
            if [ "$HAS_IP6TABLES" = "true" ]; then
                ip6tables-save > /etc/sysconfig/ip6tables
            fi
            
            # 启用服务
            systemctl enable iptables
            systemctl enable ip6tables
            ;;
            
        *)
            warning "未知系统类型，规则需要手动持久化"
            info "当前规则:"
            iptables-save | grep -E "(PREROUTING|POSTROUTING|FORWARD|INPUT.*(51200|51300))"
            ;;
    esac
}

# 验证配置
verify_configuration() {
    info ">>> 验证配置"
    
    # 检查规则是否存在
    if iptables -t nat -L PREROUTING -n | grep -q "$TRANSIT_PORT.*$LANDING_IPV4:$LANDING_PORT"; then
        success "IPv4 转发规则设置成功"
    else
        error "IPv4 转发规则设置失败"
    fi
    
    if [ "$HAS_IP6TABLES" = "true" ]; then
        if ip6tables -t nat -L PREROUTING -n | grep -q "$TRANSIT_PORT.*$LANDING_IPV6.*$LANDING_PORT"; then
            success "IPv6 转发规则设置成功"
        else
            warning "IPv6 转发规则设置失败或未设置"
        fi
    fi
    
    # 检查端口监听
    info "开放的端口: ${OPEN_PORTS[*]}"
    
    # 测试连接（可选）
    info "配置完成！"
    echo ""
    info "中转配置摘要："
    echo "  - 中转端口: $TRANSIT_PORT"
    echo "  - 目标 IPv4: $LANDING_IPV4:$LANDING_PORT"
    echo "  - 目标 IPv6: $LANDING_IPV6:$LANDING_PORT"
    echo "  - 开放端口: ${OPEN_PORTS[*]}"
    echo ""
    info "可以使用以下命令测试："
    echo "  iptables -t nat -L -n -v | grep $TRANSIT_PORT"
    echo "  ip6tables -t nat -L -n -v | grep $TRANSIT_PORT"
}

# 主执行流程
main() {
    echo "=========================================="
    echo "     智能中转服务器配置脚本"
    echo "=========================================="
    
    if [ "$EUID" -ne 0 ]; then
        warning "当前不是 root 用户，尝试继续运行..."
        # 检查是否有 sudo 权限
        if command_exists sudo && sudo -n true 2>/dev/null; then
            info "检测到 sudo 权限可用"
        else
            error "需要 root 权限运行此脚本"
            error "请使用: sudo $0 $@"
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
    info "注意事项："
    echo "  1. 确保目标服务器 ($LANDING_IPV4:$LANDING_PORT) 正在运行"
    echo "  2. 防火墙规则已持久化，重启后生效"
    echo "  3. 可以使用 'iptables-save' 查看完整规则"
}

# 执行主函数
main "$@"