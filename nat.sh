#!/bin/bash

set -euo pipefail

CONFIG_DIR="/etc/transit-proxy"
CONFIG_FILE="$CONFIG_DIR/config.conf"

mkdir -p "$CONFIG_DIR"

green() { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
red() { echo -e "\033[31m$*\033[0m"; }

usage() {

cat <<EOF

中转管理脚本

添加规则:

    $0 add <中转端口> <落地IP> <落地端口>

删除规则:

    $0 del <中转端口> <落地IP> <落地端口>

查看规则:

    $0 show

示例:

    $0 add 443 1.2.3.4 443

    $0 add 8443 1.2.3.4 8443

    $0 add 443 2400:1234::1 443

    $0 del 443 1.2.3.4 443

EOF
}

is_ipv6() {
    [[ "$1" == *:* ]]
}

detect_os() {

    if [ -f /etc/alpine-release ]; then
        echo alpine
        return
    fi

    if [ -f /etc/debian_version ]; then
        echo debian
        return
    fi

    echo unknown
}

install_deps() {

    local os
    os=$(detect_os)

    case "$os" in

        debian)

            if ! dpkg -s iptables-persistent >/dev/null 2>&1; then

                green "[+] 安装持久化组件"

                export DEBIAN_FRONTEND=noninteractive

                apt-get update

                apt-get install -y \
                iptables \
                iptables-persistent \
                netfilter-persistent
            fi
            ;;

        alpine)

            command -v iptables >/dev/null 2>&1 || {

                apk update
                apk add iptables
            }
            ;;
    esac
}

enable_forward() {

    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf \
    || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
}

enable_ipv6_forward() {

    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true

    grep -q '^net.ipv6.conf.all.forwarding=1' /etc/sysctl.conf \
    || echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
}

save_rules() {

    mkdir -p /etc/iptables

    iptables-save > /etc/iptables/rules.v4

    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true

    if command -v netfilter-persistent >/dev/null 2>&1; then

        netfilter-persistent save >/dev/null 2>&1 || true
    fi

    if [ -f /etc/alpine-release ]; then

        command -v rc-update >/dev/null 2>&1 && {

            rc-update add iptables default >/dev/null 2>&1 || true
            rc-update add ip6tables default >/dev/null 2>&1 || true
        }
    fi
}

save_config() {

    cat >> "$CONFIG_FILE" <<EOF
$1|$2|$3
EOF
}

remove_config() {

    [ -f "$CONFIG_FILE" ] || return

    grep -v "^$1|$2|$3\$" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"

    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

ip6_nat_supported() {

    ip6tables -t nat -L >/dev/null 2>&1
}

add_ipv4() {

    local tport="$1"
    local ip="$2"
    local lport="$3"

    iptables -t nat -C PREROUTING \
    -p tcp --dport "$tport" \
    -j DNAT --to-destination "$ip:$lport" 2>/dev/null \
    || \
    iptables -t nat -A PREROUTING \
    -p tcp --dport "$tport" \
    -j DNAT --to-destination "$ip:$lport"

    iptables -t nat -C PREROUTING \
    -p udp --dport "$tport" \
    -j DNAT --to-destination "$ip:$lport" 2>/dev/null \
    || \
    iptables -t nat -A PREROUTING \
    -p udp --dport "$tport" \
    -j DNAT --to-destination "$ip:$lport"

    iptables -C FORWARD \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT 2>/dev/null \
    || \
    iptables -A FORWARD \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT

    iptables -C FORWARD \
    -p tcp \
    -d "$ip" \
    --dport "$lport" \
    -j ACCEPT 2>/dev/null \
    || \
    iptables -A FORWARD \
    -p tcp \
    -d "$ip" \
    --dport "$lport" \
    -j ACCEPT

    iptables -C FORWARD \
    -p udp \
    -d "$ip" \
    --dport "$lport" \
    -j ACCEPT 2>/dev/null \
    || \
    iptables -A FORWARD \
    -p udp \
    -d "$ip" \
    --dport "$lport" \
    -j ACCEPT

    iptables -t nat -C POSTROUTING \
    -j MASQUERADE 2>/dev/null \
    || \
    iptables -t nat -A POSTROUTING \
    -j MASQUERADE
}

add_ipv6() {

    local tport="$1"
    local ip="$2"
    local lport="$3"

    ip6_nat_supported || {

        red "[!] 当前系统不支持 IPv6 NAT"

        exit 1
    }

    enable_ipv6_forward

    ip6tables -t nat -C PREROUTING \
    -p tcp --dport "$tport" \
    -j DNAT \
    --to-destination "[$ip]:$lport" 2>/dev/null \
    || \
    ip6tables -t nat -A PREROUTING \
    -p tcp --dport "$tport" \
    -j DNAT \
    --to-destination "[$ip]:$lport"

    ip6tables -t nat -C PREROUTING \
    -p udp --dport "$tport" \
    -j DNAT \
    --to-destination "[$ip]:$lport" 2>/dev/null \
    || \
    ip6tables -t nat -A PREROUTING \
    -p udp --dport "$tport" \
    -j DNAT \
    --to-destination "[$ip]:$lport"

    ip6tables -C FORWARD \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT 2>/dev/null \
    || \
    ip6tables -A FORWARD \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT

    ip6tables -C FORWARD \
    -p tcp \
    -d "$ip" \
    --dport "$lport" \
    -j ACCEPT 2>/dev/null \
    || \
    ip6tables -A FORWARD \
    -p tcp \
    -d "$ip" \
    --dport "$lport" \
    -j ACCEPT

    ip6tables -C FORWARD \
    -p udp \
    -d "$ip" \
    --dport "$lport" \
    -j ACCEPT 2>/dev/null \
    || \
    ip6tables -A FORWARD \
    -p udp \
    -d "$ip" \
    --dport "$lport" \
    -j ACCEPT

    ip6tables -t nat -C POSTROUTING \
    -j MASQUERADE 2>/dev/null \
    || \
    ip6tables -t nat -A POSTROUTING \
    -j MASQUERADE
}

delete_ipv4() {

    local tport="$1"
    local ip="$2"
    local lport="$3"

    iptables -t nat -D PREROUTING -p tcp --dport "$tport" -j DNAT --to-destination "$ip:$lport" 2>/dev/null || true
    iptables -t nat -D PREROUTING -p udp --dport "$tport" -j DNAT --to-destination "$ip:$lport" 2>/dev/null || true

    iptables -D FORWARD -p tcp -d "$ip" --dport "$lport" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -p udp -d "$ip" --dport "$lport" -j ACCEPT 2>/dev/null || true
}

delete_ipv6() {

    local tport="$1"
    local ip="$2"
    local lport="$3"

    ip6tables -t nat -D PREROUTING -p tcp --dport "$tport" -j DNAT --to-destination "[$ip]:$lport" 2>/dev/null || true
    ip6tables -t nat -D PREROUTING -p udp --dport "$tport" -j DNAT --to-destination "[$ip]:$lport" 2>/dev/null || true

    ip6tables -D FORWARD -p tcp -d "$ip" --dport "$lport" -j ACCEPT 2>/dev/null || true
    ip6tables -D FORWARD -p udp -d "$ip" --dport "$lport" -j ACCEPT 2>/dev/null || true
}

show_rules() {

    echo

    green "当前配置"

    [ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE"

    echo
    green "IPv4 DNAT"
    iptables -t nat -L PREROUTING -n -v

    echo
    green "IPv6 DNAT"
    ip6tables -t nat -L PREROUTING -n -v 2>/dev/null || true
}

ACTION="${1:-}"

case "$ACTION" in

add)

    PORT="$2"
    DEST="$3"
    DPORT="$4"

    install_deps
    enable_forward

    if is_ipv6 "$DEST"
    then
        add_ipv6 "$PORT" "$DEST" "$DPORT"
    else
        add_ipv4 "$PORT" "$DEST" "$DPORT"
    fi

    save_config "$PORT" "$DEST" "$DPORT"

    save_rules

    green "✅ 规则添加成功"
    ;;

del)

    PORT="$2"
    DEST="$3"
    DPORT="$4"

    if is_ipv6 "$DEST"
    then
        delete_ipv6 "$PORT" "$DEST" "$DPORT"
    else
        delete_ipv4 "$PORT" "$DEST" "$DPORT"
    fi

    remove_config "$PORT" "$DEST" "$DPORT"

    save_rules

    green "✅ 规则删除成功"
    ;;

show)

    show_rules
    ;;

*)

    usage
    ;;
esac