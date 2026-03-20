#!/bin/bash
set -e

### ====== 颜色定义 ======
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

### ====== 配置参数（可自定义） ======
# 配置文件路径
CONFIG_FILE="/etc/transit-proxy/config.conf"
# 默认值
DEFAULT_TRANSIT_PORT=51300
DEFAULT_LANDING_PORT=51200

### ====== 显示帮助 ======
show_help() {
    cat << EOF
${GREEN}中转服务器配置脚本${NC}

用法:
  $0 [选项]

选项:
  -4 <IP>        设置 IPv4 地址
  -6 <IP>        设置 IPv6 地址
  -p <端口列表>   设置开放端口（用逗号分隔，如: 80,443,222）
  -t <端口>       设置中转端口（默认: 51300）
  -l <端口>       设置落地端口（默认: 51200）
  -s              显示当前配置
  -d              删除所有规则
  -h              显示此帮助

示例:
  $0 -4 72.18.81.15 -6 2607:f130:0:18e::17dd:18a0 -p 80,443,222
  $0 -4 72.18.81.15 -p 80,443,222,51200,51201,51300,51301
  $0 -4 72.18.81.15 -6 2607:f130:0:18e::17dd:18a0 -p 80,443 -t 50000 -l 50001
  $0 -d  # 删除所有规则
EOF
}

### ====== 解析命令行参数 ======
parse_args() {
    # 初始化变量
    LANDING_IPV4=""
    LANDING_IPV6=""
    OPEN_PORTS=()
    TRANSIT_PORT=$DEFAULT_TRANSIT_PORT
    LANDING_PORT=$DEFAULT_LANDING_PORT
    SHOW_CONFIG=0
    DELETE_RULES=0
    
    while getopts "4:6:p:t:l:sdh" opt; do
        case $opt in
            4)
                LANDING_IPV4="$OPTARG"
                ;;
            6)
                LANDING_IPV6="$OPTARG"
                ;;
            p)
                IFS=',' read -ra OPEN_PORTS <<< "$OPTARG"
                ;;
            t)
                TRANSIT_PORT="$OPTARG"
                ;;
            l)
                LANDING_PORT="$OPTARG"
                ;;
            s)
                SHOW_CONFIG=1
                ;;
            d)
                DELETE_RULES=1
                ;;
            h)
                show_help
                exit 0
                ;;
            \?)
                echo -e "${RED}错误:${NC} 无效选项"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 如果只显示配置，不需要验证其他参数
    if [ $SHOW_CONFIG -eq 1 ]; then
        return
    fi
    
    # 如果删除规则，不需要验证IP
    if [ $DELETE_RULES -eq 1 ]; then
        return
    fi
    
    # 验证必需参数
    if [ -z "$LANDING_IPV4" ] && [ -z "$LANDING_IPV6" ]; then
        echo -e "${RED}错误:${NC} 至少需要指定一个 IPv4 或 IPv6 地址"
        show_help
        exit 1
    fi
    
    if [ ${#OPEN_PORTS[@]} -eq 0 ]; then
        echo -e "${RED}错误:${NC} 请指定开放端口"
        show_help
        exit 1
    fi
}

### ====== 加载/保存配置 ======
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${GREEN}>>>${NC} 已加载配置文件: $CONFIG_FILE"
    fi
}

save_config() {
    local config_dir=$(dirname "$CONFIG_FILE")
    mkdir -p "$config_dir"
    
    cat > "$CONFIG_FILE" << EOF
# 中转代理配置文件
# 最后更新: $(date)

# IPv4 地址
LANDING_IPV4="$LANDING_IPV4"

# IPv6 地址
LANDING_IPV6="$LANDING_IPV6"

# 开放端口
OPEN_PORTS=(${OPEN_PORTS[*]})

# 中转端口
TRANSIT_PORT="$TRANSIT_PORT"

# 落地端口
LANDING_PORT="$LANDING_PORT"
EOF
    echo -e "${GREEN}>>>${NC} 配置已保存到: $CONFIG_FILE"
}

show_current_config() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}        当前配置信息${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${BLUE}IPv4 地址:${NC} ${LANDING_IPV4:-未设置}"
    echo -e "${BLUE}IPv6 地址:${NC} ${LANDING_IPV6:-未设置}"
    echo -e "${BLUE}开放端口:${NC} ${OPEN_PORTS[*]:-无}"
    echo -e "${BLUE}中转端口:${NC} $TRANSIT_PORT -> $LANDING_PORT"
    
    # 显示当前生效的iptables规则
    echo -e "\n${BLUE}当前生效的规则:${NC}"
    
    # 显示开放端口规则
    echo -e "${YELLOW}  开放端口:${NC}"
    iptables -L INPUT -n | grep -E "ACCEPT.*dpt" || echo "    无"
    
    # 显示DNAT规则
    echo -e "${YELLOW}  DNAT规则:${NC}"
    iptables -t nat -L PREROUTING -n | grep -E "DNAT.*$TRANSIT_PORT" || echo "    无"
    ip6tables -t nat -L PREROUTING -n | grep -E "DNAT.*$TRANSIT_PORT" 2>/dev/null || echo "    无"
    
    echo -e "${GREEN}========================================${NC}"
}

### ====== 删除所有规则 ======
delete_all_rules() {
    echo -e "${YELLOW}>>>${NC} 开始删除所有中转规则..."
    
    # 如果配置文件存在，加载配置以便知道要删除哪些规则
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    
    # 删除IPv4规则
    echo -e "${BLUE}  删除 IPv4 规则...${NC}"
    
    # 清空所有自定义规则（保留默认策略）
    iptables -F INPUT 2>/dev/null || true
    iptables -F FORWARD 2>/dev/null || true
    iptables -t nat -F PREROUTING 2>/dev/null || true
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    
    # 删除特定端口的INPUT规则
    if [ -n "$LANDING_IPV4" ] && [ ${#OPEN_PORTS[@]} -gt 0 ]; then
        for port in "${OPEN_PORTS[@]}"; do
            iptables -D INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || true
        done
    fi
    
    # 删除IPv6规则
    echo -e "${BLUE}  删除 IPv6 规则...${NC}"
    ip6tables -F INPUT 2>/dev/null || true
    ip6tables -F FORWARD 2>/dev/null || true
    ip6tables -t nat -F PREROUTING 2>/dev/null || true
    ip6tables -t nat -F POSTROUTING 2>/dev/null || true
    
    if [ -n "$LANDING_IPV6" ] && [ ${#OPEN_PORTS[@]} -gt 0 ]; then
        for port in "${OPEN_PORTS[@]}"; do
            ip6tables -D INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
            ip6tables -D INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || true
        done
    fi
    
    # 保存空规则
    save_rules
    
    echo -e "${GREEN}>>>${NC} 所有规则已删除"
}

### ====== 系统检测 ======
detect_os() {
    if [ -f /etc/alpine-release ]; then
        echo "alpine"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/lsb-release ] && grep -q "Ubuntu" /etc/lsb-release; then
        echo "debian"
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

### ====== 保存规则 ======
save_rules() {
    OS_TYPE=$(detect_os)
    
    case "$OS_TYPE" in
        "alpine")
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            ;;
        "debian")
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            if command -v netfilter-persistent >/dev/null 2>&1; then
                netfilter-persistent save 2>/dev/null || true
            fi
            ;;
    esac
    
    echo -e "${GREEN}>>>${NC} 规则已保存"
}

### ====== 依赖安装 ======
install_dependencies() {
    OS_TYPE=$(detect_os)
    echo -e "${GREEN}>>>${NC} 检测到系统类型: $OS_TYPE"
    
    if [ "$OS_TYPE" = "unknown" ]; then
        echo -e "${RED}错误:${NC} 不支持的操作系统"
        exit 1
    fi
    
    echo -e "${GREEN}>>>${NC} 检测并安装必要依赖"
    
    case "$OS_TYPE" in
        "alpine")
            local to_install=""
            command -v iptables >/dev/null 2>&1 || to_install="$to_install iptables"
            command -v ip6tables >/dev/null 2>&1 || to_install="$to_install ip6tables"
            command -v nc >/dev/null 2>&1 || to_install="$to_install netcat-openbsd"
            command -v ss >/dev/null 2>&1 || to_install="$to_install iproute2"
            command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || to_install="$to_install curl"
            
            if [ -n "$to_install" ]; then
                echo -e "${BLUE}>>>${NC} 安装依赖: $to_install"
                apk update 2>/dev/null || true
                apk add $to_install 2>/dev/null || {
                    echo -e "${RED}错误:${NC} 依赖安装失败"
                    exit 1
                }
            fi
            ;;
            
        "debian")
            local to_install=""
            command -v iptables >/dev/null 2>&1 || to_install="$to_install iptables"
            command -v nc >/dev/null 2>&1 || to_install="$to_install netcat-openbsd"
            command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || to_install="$to_install curl"
            
            # iptables-persistent 检查
            if ! dpkg -l | grep -q iptables-persistent; then
                to_install="$to_install iptables-persistent"
            fi
            
            if [ -n "$to_install" ]; then
                echo -e "${BLUE}>>>${NC} 安装依赖: $to_install"
                apt-get update 2>/dev/null || true
                DEBIAN_FRONTEND=noninteractive apt-get install -y $to_install 2>/dev/null || {
                    echo -e "${RED}错误:${NC} 依赖安装失败"
                    exit 1
                }
            fi
            ;;
    esac
    
    echo -e "${GREEN}>>>${NC} 依赖检测完成"
}

### ====== 设置转发 ======
setup_ip_forward() {
    echo -e "${GREEN}>>>${NC} 开启 IPv4 / IPv6 转发"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    
    # 永久生效
    grep -q "net.ipv4.ip_forward" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    grep -q "net.ipv6.conf.all.forwarding" /etc/sysctl.conf || echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
}

### ====== 设置规则 ======
setup_rules() {
    echo -e "${GREEN}>>>${NC} 开始设置转发规则"
    
    # 开启转发
    setup_ip_forward
    
    # 清理旧规则（避免重复）
    echo -e "${BLUE}  清理旧规则...${NC}"
    
    # ====== 新增：设置默认策略为DROP ======
    echo -e "${YELLOW}  设置默认策略为 DROP（只开放指定端口）...${NC}"
    
    # IPv4 默认策略
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    # OUTPUT 保持 ACCEPT 通常没问题
    # iptables -P OUTPUT ACCEPT
    
    # IPv6 默认策略（如果设置了IPv6）
    if [ -n "$LANDING_IPV6" ]; then
        ip6tables -P INPUT DROP
        ip6tables -P FORWARD DROP
        # ip6tables -P OUTPUT ACCEPT
    fi
    
    # ====== 新增：允许已建立的连接 ======
    echo -e "${BLUE}  允许已建立的连接...${NC}"
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    if [ -n "$LANDING_IPV6" ]; then
        ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    fi
    
    # ====== 新增：允许本地回环接口 ======
    echo -e "${BLUE}  允许本地回环接口...${NC}"
    iptables -A INPUT -i lo -j ACCEPT
    if [ -n "$LANDING_IPV6" ]; then
        ip6tables -A INPUT -i lo -j ACCEPT
    fi
    
    # ====== 新增：允许ICMP（ping）便于诊断 ======
    echo -e "${BLUE}  允许ICMP...${NC}"
    iptables -A INPUT -p icmp -j ACCEPT
    if [ -n "$LANDING_IPV6" ]; then
        ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
    fi
    
    # 开放端口（先删除可能存在的旧规则）
    echo -e "${BLUE}  设置开放端口...${NC}"
    for port in "${OPEN_PORTS[@]}"; do
        # IPv4
        iptables -D INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -p tcp --dport $port -j ACCEPT
        iptables -A INPUT -p udp --dport $port -j ACCEPT
        
        # IPv6（如果设置了IPv6）
        if [ -n "$LANDING_IPV6" ]; then
            ip6tables -D INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
            ip6tables -D INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || true
            ip6tables -A INPUT -p tcp --dport $port -j ACCEPT
            ip6tables -A INPUT -p udp --dport $port -j ACCEPT
        fi
    done
    
    # 设置IPv4 DNAT规则
    if [ -n "$LANDING_IPV4" ]; then
        echo -e "${BLUE}  设置 IPv4 中转规则...${NC}"
        
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
        
        # FORWARD 规则
        iptables -D FORWARD -p tcp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -p tcp -s ${LANDING_IPV4} --sport ${LANDING_PORT} -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -p udp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -p udp -s ${LANDING_IPV4} --sport ${LANDING_PORT} -j ACCEPT 2>/dev/null || true
        
        iptables -A FORWARD -p tcp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j ACCEPT
        iptables -A FORWARD -p tcp -s ${LANDING_IPV4} --sport ${LANDING_PORT} -j ACCEPT
        iptables -A FORWARD -p udp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j ACCEPT
        iptables -A FORWARD -p udp -s ${LANDING_IPV4} --sport ${LANDING_PORT} -j ACCEPT
    fi
    
    # 设置IPv6 DNAT规则
    if [ -n "$LANDING_IPV6" ]; then
        echo -e "${BLUE}  设置 IPv6 中转规则...${NC}"
        
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
        
        # FORWARD 规则
        ip6tables -D FORWARD -p tcp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j ACCEPT 2>/dev/null || true
        ip6tables -D FORWARD -p tcp -s ${LANDING_IPV6} --sport ${LANDING_PORT} -j ACCEPT 2>/dev/null || true
        ip6tables -D FORWARD -p udp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j ACCEPT 2>/dev/null || true
        ip6tables -D FORWARD -p udp -s ${LANDING_IPV6} --sport ${LANDING_PORT} -j ACCEPT 2>/dev/null || true
        
        ip6tables -A FORWARD -p tcp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j ACCEPT
        ip6tables -A FORWARD -p tcp -s ${LANDING_IPV6} --sport ${LANDING_PORT} -j ACCEPT
        ip6tables -A FORWARD -p udp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j ACCEPT
        ip6tables -A FORWARD -p udp -s ${LANDING_IPV6} --sport ${LANDING_PORT} -j ACCEPT
    fi
    
    # ====== 新增：记录被拒绝的访问（可选） ======
    # 记录其他被DROP的包（用于调试）
    # iptables -A INPUT -j LOG --log-prefix "IPTables-Dropped: " --log-level 4
    # if [ -n "$LANDING_IPV6" ]; then
    #     ip6tables -A INPUT -j LOG --log-prefix "IP6Tables-Dropped: " --log-level 4
    # fi
    
    echo -e "${GREEN}>>>${NC} 规则设置完成"
}

### ====== 测试连通性 ======
test_connectivity() {
    echo -e "${GREEN}>>>${NC} 开始网络连通性测试"
    
    if [ -n "$LANDING_IPV4" ]; then
        echo -e "${BLUE}   测试目标服务器 IPv4 连通性...${NC}"
        if timeout 3 ping -c 2 "$LANDING_IPV4" >/dev/null 2>&1; then
            echo -e "${GREEN}      ✓ IPv4 可达${NC}"
        else
            echo -e "${YELLOW}      ⚠ IPv4 可能不可达（或被防火墙阻挡）${NC}"
        fi
    fi
    
    if [ -n "$LANDING_IPV6" ]; then
        echo -e "${BLUE}   测试目标服务器 IPv6 连通性...${NC}"
        if command -v ping6 >/dev/null 2>&1; then
            if timeout 3 ping6 -c 2 "$LANDING_IPV6" >/dev/null 2>&1; then
                echo -e "${GREEN}      ✓ IPv6 可达${NC}"
            else
                echo -e "${YELLOW}      ⚠ IPv6 可能不可达（或被防火墙阻挡）${NC}"
            fi
        else
            echo -e "${YELLOW}      ⚠ ping6 不可用，跳过 IPv6 连通性测试${NC}"
        fi
    fi
    
    echo -e "${GREEN}>>>${NC} 连通性测试完成"
}

### ====== 主函数 ======
main() {
    # 解析命令行参数
    parse_args "$@"
    
    # 加载配置文件
    load_config
    
    # 根据选项执行
    if [ $SHOW_CONFIG -eq 1 ]; then
        show_current_config
        exit 0
    fi
    
    if [ $DELETE_RULES -eq 1 ]; then
        delete_all_rules
        exit 0
    fi
    
    # 显示配置信息
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}        中转服务器配置脚本${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    if [ -n "$LANDING_IPV4" ]; then
        echo -e "${BLUE}IPv4 地址:${NC} $LANDING_IPV4"
    fi
    if [ -n "$LANDING_IPV6" ]; then
        echo -e "${BLUE}IPv6 地址:${NC} $LANDING_IPV6"
    fi
    echo -e "${BLUE}开放端口:${NC} ${OPEN_PORTS[*]}"
    echo -e "${BLUE}中转端口:${NC} $TRANSIT_PORT -> $LANDING_PORT"
    echo -e "${GREEN}========================================${NC}"
    
    # 安装依赖
    install_dependencies
    
    # 设置规则
    setup_rules
    
    # 保存配置
    save_config
    
    # 保存规则
    save_rules
    
    # 测试连通性
    test_connectivity
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}>>> 中转规则及端口放行已完成 ✅${NC}"
    echo -e "${GREEN}>>> 系统重启后规则将自动生效${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    # 显示使用提示
    echo -e "${YELLOW}使用提示:${NC}"
    echo -e "  查看当前配置: $0 -s"
    echo -e "  删除所有规则: $0 -d"
    echo -e "  修改配置: 重新运行脚本并指定新参数"
    echo -e "${GREEN}========================================${NC}"
}

# 执行主函数
main "$@"