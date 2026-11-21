#!/bin/bash
set -euo pipefail

### ====== 颜色 ======
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

### ====== 配置 ======
CONFIG_FILE="/etc/transit-proxy/config.conf"
WHITELIST_FILE="/etc/transit-proxy/whitelist.conf"
BACKUP_DIR="/etc/transit-proxy/backup"
DEFAULT_TRANSIT_PORT=51300
DEFAULT_LANDING_PORT=51200

### ====== 工具 ======
info() { echo -e "${GREEN}>>>${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}错误:${NC} $*" >&2; }

ip6_nat_available() {
    ip6tables -t nat -L PREROUTING -n >/dev/null 2>&1
}

get_ssh_port() {
    local p
    p=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
    if [ -z "$p" ]; then
        p=$(grep -E '^\s*Port\s+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2; exit}' || true)
    fi
    echo "${p:-22}"
}

### ====== 帮助 ======
show_help() {
    cat << EOF
${GREEN}中转服务器配置脚本${NC}

用法: $0 [选项]

选项:
  -4 <IP>        设置 IPv4 地址
  -6 <IP>        设置 IPv6 地址
  -p <端口列表>   设置开放端口（逗号分隔，如: 80,443,222）
  -w <IP列表>     设置白名单IP（逗号分隔，可访问所有端口）
  -t <端口>       设置中转端口（默认: 51300）
  -l <端口>       设置落地端口（默认: 51200）
  -s              显示当前配置
  -d              删除本脚本添加的规则（不动其他规则）
  -r              回滚到最近一次备份的 iptables 规则
  -h              显示帮助

示例:
  $0 -4 72.18.81.15 -6 2607:f130:0:18e::17dd:18a0 -p 80,443,222 -w 1.2.3.4
  $0 -d
  $0 -r
EOF
}

### ====== 参数 ======
parse_args() {
    LANDING_IPV4=""
    LANDING_IPV6=""
    OPEN_PORTS=()
    WHITELIST_IPS=()
    TRANSIT_PORT=$DEFAULT_TRANSIT_PORT
    LANDING_PORT=$DEFAULT_LANDING_PORT
    SHOW_CONFIG=0
    DELETE_RULES=0
    ROLLBACK=0

    while getopts "4:6:p:w:t:l:sdhr" opt; do
        case $opt in
            4) LANDING_IPV4="$OPTARG" ;;
            6) LANDING_IPV6="$OPTARG" ;;
            p) IFS=',' read -ra OPEN_PORTS <<< "$OPTARG" ;;
            w) IFS=',' read -ra WHITELIST_IPS <<< "$OPTARG" ;;
            t) TRANSIT_PORT="$OPTARG" ;;
            l) LANDING_PORT="$OPTARG" ;;
            s) SHOW_CONFIG=1 ;;
            d) DELETE_RULES=1 ;;
            r) ROLLBACK=1 ;;
            h) show_help; exit 0 ;;
            \?) err "无效选项"; show_help; exit 1 ;;
        esac
    done

    [ "$SHOW_CONFIG" -eq 1 ] && return
    [ "$DELETE_RULES" -eq 1 ] && return
    [ "$ROLLBACK" -eq 1 ] && return

    if [ -z "$LANDING_IPV4" ] && [ -z "$LANDING_IPV6" ]; then
        err "至少需要指定一个 IPv4 或 IPv6 地址"; show_help; exit 1
    fi
    if [ ${#OPEN_PORTS[@]} -eq 0 ] && [ ${#WHITELIST_IPS[@]} -eq 0 ]; then
        err "请指定开放端口或白名单IP"; show_help; exit 1
    fi

    local p
    for p in "$TRANSIT_PORT" "$LANDING_PORT" "${OPEN_PORTS[@]}"; do
        [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] \
            || { err "非法端口: $p"; exit 1; }
    done
}

### ====== 配置加载/保存 ======
load_config() {
    [ -f "$CONFIG_FILE" ] && { source "$CONFIG_FILE"; info "已加载配置: $CONFIG_FILE"; }
    [ -f "$WHITELIST_FILE" ] && { source "$WHITELIST_FILE"; info "已加载白名单: $WHITELIST_FILE"; }
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    chmod 700 "$(dirname "$CONFIG_FILE")" 2>/dev/null || true

    {
        echo "# 中转代理配置 更新: $(date)"
        echo "LANDING_IPV4=\"$LANDING_IPV4\""
        echo "LANDING_IPV6=\"$LANDING_IPV6\""
        printf 'OPEN_PORTS=('
        printf '%q ' "${OPEN_PORTS[@]}"
        echo ')'
        echo "TRANSIT_PORT=\"$TRANSIT_PORT\""
        echo "LANDING_PORT=\"$LANDING_PORT\""
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    if [ ${#WHITELIST_IPS[@]} -gt 0 ]; then
        {
            echo "# 白名单 更新: $(date)"
            printf 'WHITELIST_IPS=('
            printf '%q ' "${WHITELIST_IPS[@]}"
            echo ')'
        } > "$WHITELIST_FILE"
        chmod 600 "$WHITELIST_FILE"
    fi
    info "配置已保存"
}

show_current_config() {
    echo -e "${GREEN}========== 当前配置 ==========${NC}"
    echo -e "${BLUE}IPv4:${NC} ${LANDING_IPV4:-未设置}"
    echo -e "${BLUE}IPv6:${NC} ${LANDING_IPV6:-未设置}"
    echo -e "${BLUE}开放端口:${NC} ${OPEN_PORTS[*]:-无}"
    echo -e "${BLUE}白名单:${NC} ${WHITELIST_IPS[*]:-无}"
    echo -e "${BLUE}中转端口:${NC} $TRANSIT_PORT -> $LANDING_PORT"
    echo -e "\n${BLUE}当前 INPUT 规则:${NC}"
    iptables -S INPUT 2>/dev/null || true
    echo -e "\n${BLUE}当前 IPv4 DNAT:${NC}"
    iptables -t nat -S PREROUTING 2>/dev/null | grep DNAT || echo "  无"
    if [ -n "$LANDING_IPV6" ] && ip6_nat_available; then
        echo -e "\n${BLUE}当前 IPv6 DNAT:${NC}"
        ip6tables -t nat -S PREROUTING 2>/dev/null | grep DNAT || echo "  无"
    fi
    echo -e "${GREEN}===============================${NC}"
}

### ====== 精确删除本脚本规则 ======
delete_all_rules() {
    warn "开始删除本脚本添加的规则（不影响其他规则）"
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    [ -f "$WHITELIST_FILE" ] && source "$WHITELIST_FILE"

    local ip port proto
    for ip in "${WHITELIST_IPS[@]:-}"; do
        [[ "$ip" =~ ^[0-9.]+$ ]] && iptables -D INPUT -s "$ip" -j ACCEPT 2>/dev/null || true
        [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && ip6tables -D INPUT -s "$ip" -j ACCEPT 2>/dev/null || true
        [[ "$ip" =~ ^[0-9.]+$ ]] && iptables -D FORWARD -s "$ip" -j ACCEPT 2>/dev/null || true
        [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && ip6tables -D FORWARD -s "$ip" -j ACCEPT 2>/dev/null || true
    done

    for port in "${OPEN_PORTS[@]:-}"; do
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
    done

    if [ -n "${LANDING_IPV4:-}" ]; then
        iptables -t nat -D PREROUTING -p tcp --dport "$TRANSIT_PORT" -j DNAT --to-destination "$LANDING_IPV4:$LANDING_PORT" 2>/dev/null || true
        iptables -t nat -D PREROUTING -p udp --dport "$TRANSIT_PORT" -j DNAT --to-destination "$LANDING_IPV4:$LANDING_PORT" 2>/dev/null || true
        iptables -t nat -D POSTROUTING -p tcp -d "$LANDING_IPV4" --dport "$LANDING_PORT" -j MASQUERADE 2>/dev/null || true
        iptables -t nat -D POSTROUTING -p udp -d "$LANDING_IPV4" --dport "$LANDING_PORT" -j MASQUERADE 2>/dev/null || true
        for proto in tcp udp; do
            iptables -D FORWARD -p $proto -d "$LANDING_IPV4" --dport "$LANDING_PORT" -j ACCEPT 2>/dev/null || true
            iptables -D FORWARD -p $proto -s "$LANDING_IPV4" --sport "$LANDING_PORT" -j ACCEPT 2>/dev/null || true
        done
    fi

    if [ -n "${LANDING_IPV6:-}" ] && ip6_nat_available; then
        ip6tables -t nat -D PREROUTING -p tcp --dport "$TRANSIT_PORT" -j DNAT --to-destination "[$LANDING_IPV6]:$LANDING_PORT" 2>/dev/null || true
        ip6tables -t nat -D PREROUTING -p udp --dport "$TRANSIT_PORT" -j DNAT --to-destination "[$LANDING_IPV6]:$LANDING_PORT" 2>/dev/null || true
        ip6tables -t nat -D POSTROUTING -p tcp -d "$LANDING_IPV6" --dport "$LANDING_PORT" -j MASQUERADE 2>/dev/null || true
        ip6tables -t nat -D POSTROUTING -p udp -d "$LANDING_IPV6" --dport "$LANDING_PORT" -j MASQUERADE 2>/dev/null || true
    fi

    info "规则已删除（默认策略未改动）"
}

### ====== 系统检测 ======
detect_os() {
    if [ -f /etc/alpine-release ]; then
        echo "alpine"
        return
    fi

    if [ -f /etc/debian_version ]; then
        local ver
        ver=$(cat /etc/debian_version 2>/dev/null || true)
        case "$ver" in
            12*|13*|14*|testing*|sid*) echo "debian12plus" ;;
            *) echo "debian" ;;
        esac
        return
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            alpine) echo "alpine" ;;
            debian)
                case "$VERSION_ID" in
                    12*|13*|14*) echo "debian12plus" ;;
                    *) echo "debian" ;;
                esac
                ;;
            ubuntu) echo "debian" ;;
            *) echo "unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

### ====== 依赖安装 ======
install_dependencies() {
    local os; os=$(detect_os)
    info "系统类型: $os"

    case "$os" in
        alpine)
            local pkgs=""
            command -v iptables  >/dev/null || pkgs="$pkgs iptables"
            command -v ip6tables >/dev/null || pkgs="$pkgs ip6tables"
            command -v nc        >/dev/null || pkgs="$pkgs netcat-openbsd"
            command -v curl      >/dev/null || command -v wget >/dev/null || pkgs="$pkgs curl"
            if [ -n "$pkgs" ]; then
                apk update
                apk add $pkgs
            fi
            ;;
        debian12plus|debian)
            local pkgs=""
            command -v iptables >/dev/null || pkgs="$pkgs iptables"
            command -v nc       >/dev/null || pkgs="$pkgs netcat-openbsd"
            command -v curl     >/dev/null || command -v wget >/dev/null || pkgs="$pkgs curl"
            dpkg -l iptables-persistent >/dev/null 2>&1 || pkgs="$pkgs iptables-persistent"
            if [ -n "$pkgs" ]; then
                apt-get update
                DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs
            fi
            ;;
        *)
            err "不支持的系统: $os（仅支持 Alpine、Debian 12+、其他 Debian 系）"
            exit 1
            ;;
    esac
}

### ====== 转发开关 ======
setup_ip_forward() {
    info "开启 IPv4/IPv6 转发"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
    grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    grep -q '^net.ipv6.conf.all.forwarding' /etc/sysctl.conf || echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
}

### ====== 规则设置 ======
setup_rules() {
    info "设置转发规则"

    mkdir -p "$BACKUP_DIR"
    iptables-save  > "$BACKUP_DIR/iptables.$(date +%s).bak" 2>/dev/null || true
    ip6tables-save > "$BACKUP_DIR/ip6tables.$(date +%s).bak" 2>/dev/null || true

    setup_ip_forward

    local ssh_port; ssh_port=$(get_ssh_port)
    info "检测到 SSH 端口: $ssh_port（将强制放行，防止锁死）"

    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -p icmp -j ACCEPT
    iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
    iptables -A INPUT -p udp --dport "$ssh_port" -j ACCEPT

    if [ -n "$LANDING_IPV6" ]; then
        ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        ip6tables -A INPUT -i lo -j ACCEPT
        ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
        ip6tables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT 2>/dev/null || true
    fi

    local ip port proto
    for ip in "${WHITELIST_IPS[@]:-}"; do
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            iptables -I INPUT 1 -s "$ip" -j ACCEPT
            iptables -I FORWARD 1 -s "$ip" -j ACCEPT
        elif [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [ -n "$LANDING_IPV6" ]; then
            ip6tables -I INPUT 1 -s "$ip" -j ACCEPT
            ip6tables -I FORWARD 1 -s "$ip" -j ACCEPT
        else
            warn "跳过无效 IP: $ip"
        fi
    done

    for port in "${OPEN_PORTS[@]:-}"; do
        iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
        iptables -A INPUT -p udp --dport "$port" -j ACCEPT
        if [ -n "$LANDING_IPV6" ]; then
            ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
            ip6tables -A INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
    done

    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    if [ -n "$LANDING_IPV6" ]; then
        ip6tables -P INPUT DROP
        ip6tables -P FORWARD DROP
    fi

    if [ -n "$LANDING_IPV4" ]; then
        info "设置 IPv4 DNAT"
        iptables -t nat -D PREROUTING -p tcp --dport "$TRANSIT_PORT" -j DNAT --to-destination "$LANDING_IPV4:$LANDING_PORT" 2>/dev/null || true
        iptables -t nat -D PREROUTING -p udp --dport "$TRANSIT_PORT" -j DNAT --to-destination "$LANDING_IPV4:$LANDING_PORT" 2>/dev/null || true
        iptables -t nat -A PREROUTING -p tcp --dport "$TRANSIT_PORT" -j DNAT --to-destination "$LANDING_IPV4:$LANDING_PORT"
        iptables -t nat -A PREROUTING -p udp --dport "$TRANSIT_PORT" -j DNAT --to-destination "$LANDING_IPV4:$LANDING_PORT"

        iptables -t nat -D POSTROUTING -p tcp -d "$LANDING_IPV4" --dport "$LANDING_PORT" -j MASQUERADE 2>/dev/null || true
        iptables -t nat -D POSTROUTING -p udp -d "$LANDING_IPV4" --dport "$LANDING_PORT" -j MASQUERADE 2>/dev/null || true
        iptables -t nat -A POSTROUTING -p tcp -d "$LANDING_IPV4" --dport "$LANDING_PORT" -j MASQUERADE
        iptables -t nat -A POSTROUTING -p udp -d "$LANDING_IPV4" --dport "$LANDING_PORT" -j MASQUERADE

        for proto in tcp udp; do
            iptables -D FORWARD -p $proto -d "$LANDING_IPV4" --dport "$LANDING_PORT" -j ACCEPT 2>/dev/null || true
            iptables -D FORWARD -p $proto -s "$LANDING_IPV4" --sport "$LANDING_PORT" -j ACCEPT 2>/dev/null || true
            iptables -A FORWARD -p $proto -d "$LANDING_IPV4" --dport "$LANDING_PORT" -j ACCEPT
            iptables -A FORWARD -p $proto -s "$LANDING_IPV4" --sport "$LANDING_PORT" -j ACCEPT
        done
    fi

    if [ -n "$LANDING_IPV6" ]; then
        if ip6_nat_available; then
            info "设置 IPv6 DNAT"
            ip6tables -t nat -D PREROUTING -p tcp --dport "$TRANSIT_PORT" -j DNAT --to-destination "[$LANDING_IPV6]:$LANDING_PORT" 2>/dev/null || true
            ip6tables -t nat -D PREROUTING -p udp --dport "$TRANSIT_PORT" -j DNAT --to-destination "[$LANDING_IPV6]:$LANDING_PORT" 2>/dev/null || true
            ip6tables -t nat -A PREROUTING -p tcp --dport "$TRANSIT_PORT" -j DNAT --to-destination "[$LANDING_IPV6]:$LANDING_PORT"
            ip6tables -t nat -A PREROUTING -p udp --dport "$TRANSIT_PORT" -j DNAT --to-destination "[$LANDING_IPV6]:$LANDING_PORT"

            ip6tables -t nat -D POSTROUTING -p tcp -d "$LANDING_IPV6" --dport "$LANDING_PORT" -j MASQUERADE 2>/dev/null || true
            ip6tables -t nat -D POSTROUTING -p udp -d "$LANDING_IPV6" --dport "$LANDING_PORT" -j MASQUERADE 2>/dev/null || true
            ip6tables -t nat -A POSTROUTING -p tcp -d "$LANDING_IPV6" --dport "$LANDING_PORT" -j MASQUERADE
            ip6tables -t nat -A POSTROUTING -p udp -d "$LANDING_IPV6" --dport "$LANDING_PORT" -j MASQUERADE

            for proto in tcp udp; do
                ip6tables -D FORWARD -p $proto -d "$LANDING_IPV6" --dport "$LANDING_PORT" -j ACCEPT 2>/dev/null || true
                ip6tables -D FORWARD -p $proto -s "$LANDING_IPV6" --sport "$LANDING_PORT" -j ACCEPT 2>/dev/null || true
                ip6tables -A FORWARD -p $proto -d "$LANDING_IPV6" --dport "$LANDING_PORT" -j ACCEPT
                ip6tables -A FORWARD -p $proto -s "$LANDING_IPV6" --sport "$LANDING_PORT" -j ACCEPT
            done
        else
            warn "当前内核/系统不支持 ip6tables nat 表，跳过 IPv6 DNAT"
        fi
    fi

    info "规则设置完成"
}

### ====== 保存规则 ======
save_rules() {
    local os; os=$(detect_os)
    mkdir -p /etc/iptables

    case "$os" in
        alpine)
            iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            if command -v rc-update >/dev/null; then
                rc-update add iptables  default 2>/dev/null || true
                rc-update add ip6tables default 2>/dev/null || true
            fi
            ;;
        debian12plus|debian)
            iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            if command -v netfilter-persistent >/dev/null; then
                netfilter-persistent save 2>/dev/null || true
            fi
            ;;
    esac
    info "规则已保存（$os）"
}

### ====== 回滚 ======
rollback_rules() {
    if [ ! -d "$BACKUP_DIR" ]; then
        err "没有找到备份目录: $BACKUP_DIR"
        exit 1
    fi

    local latest_v4 latest_v6
    latest_v4=$(ls -1t "$BACKUP_DIR"/iptables.*.bak 2>/dev/null | grep -v pre-rollback | head -n1 || true)
    latest_v6=$(ls -1t "$BACKUP_DIR"/ip6tables.*.bak 2>/dev/null | grep -v pre-rollback | head -n1 || true)

    if [ -z "$latest_v4" ] && [ -z "$latest_v6" ]; then
        err "备份目录里没有可回滚的规则文件"
        exit 1
    fi

    echo -e "${YELLOW}即将回滚到以下备份：${NC}"
    [ -n "$latest_v4" ] && echo -e "  IPv4: $latest_v4"
    [ -n "$latest_v6" ] && echo -e "  IPv6: $latest_v6"
    echo -e "${YELLOW}回滚会覆盖当前 iptables 规则，但会先自动备份当前规则。${NC}"
    read -r -p "确认继续? [y/N] " ans
    case "$ans" in
        [yY]|[yY][eE][sS]) ;;
        *) info "已取消"; exit 0 ;;
    esac

    mkdir -p "$BACKUP_DIR"
    iptables-save  > "$BACKUP_DIR/iptables.pre-rollback.$(date +%s).bak" 2>/dev/null || true
    ip6tables-save > "$BACKUP_DIR/ip6tables.pre-rollback.$(date +%s).bak" 2>/dev/null || true

    if [ -n "$latest_v4" ]; then
        iptables-restore < "$latest_v4" || { err "IPv4 回滚失败"; exit 1; }
        info "IPv4 规则已回滚"
    fi
    if [ -n "$latest_v6" ] && ip6_nat_available; then
        ip6tables-restore < "$latest_v6" || warn "IPv6 回滚失败（可能内核不支持 nat）"
        info "IPv6 规则已回滚"
    fi

    local os; os=$(detect_os)
    case "$os" in
        alpine)
            iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            ;;
        debian12plus|debian)
            iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            command -v netfilter-persistent >/dev/null && netfilter-persistent save 2>/dev/null || true
            ;;
    esac

    info "回滚完成（$os）"
}

### ====== 连通性测试 ======
test_connectivity() {
    info "连通性测试（ping 不通不代表中转不通）"
    if [ -n "$LANDING_IPV4" ]; then
        timeout 3 ping -c 2 "$LANDING_IPV4" >/dev/null 2>&1 \
            && echo -e "  ${GREEN}✓ IPv4 可达${NC}" \
            || warn "IPv4 可能不可达（或被禁 ping）"
    fi
    if [ -n "$LANDING_IPV6" ]; then
        if command -v ping6 >/dev/null; then
            timeout 3 ping6 -c 2 "$LANDING_IPV6" >/dev/null 2>&1 \
                && echo -e "  ${GREEN}✓ IPv6 可达${NC}" \
                || warn "IPv6 可能不可达（或被禁 ping）"
        else
            warn "ping6 不可用，跳过 IPv6 测试"
        fi
    fi
}

### ====== 主函数 ======
main() {
    parse_args "$@"
    load_config

    [ "$SHOW_CONFIG" -eq 1 ] && { show_current_config; exit 0; }
    [ "$DELETE_RULES" -eq 1 ] && { delete_all_rules; exit 0; }
    [ "$ROLLBACK" -eq 1 ] && { rollback_rules; exit 0; }

    echo -e "${GREEN}========== 中转服务器配置 ==========${NC}"
    [ -n "$LANDING_IPV4" ] && echo -e "${BLUE}IPv4:${NC} $LANDING_IPV4"
    [ -n "$LANDING_IPV6" ] && echo -e "${BLUE}IPv6:${NC} $LANDING_IPV6"
    echo -e "${BLUE}开放端口:${NC} ${OPEN_PORTS[*]:-无}"
    echo -e "${BLUE}白名单:${NC} ${WHITELIST_IPS[*]:-无}"
    echo -e "${BLUE}中转端口:${NC} $TRANSIT_PORT -> $LANDING_PORT"
    echo -e "${GREEN}====================================${NC}"

    install_dependencies
    setup_rules
    save_config
    save_rules
    test_connectivity

    echo -e "${GREEN}>>> 完成 ✅${NC}"
    echo -e "${YELLOW}提示: $0 -s 查看配置 | $0 -d 删除本脚本规则 | $0 -r 回滚${NC}"
}

main "$@"