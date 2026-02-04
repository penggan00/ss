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

echo ">>> 开启 IPv4 / IPv6 转发"
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

grep -q net.ipv4.ip_forward /etc/sysctl.conf || cat >> /etc/sysctl.conf << EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl -p

echo ">>> 放行直接访问端口（IPv4 + IPv6）"
for port in "${OPEN_PORTS[@]}"; do
    # IPv4
    iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $port -j ACCEPT
    iptables -C INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport $port -j ACCEPT
    # IPv6
    ip6tables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || ip6tables -A INPUT -p tcp --dport $port -j ACCEPT
    ip6tables -C INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || ip6tables -A INPUT -p udp --dport $port -j ACCEPT
done

echo ">>> 设置 IPv4 中转规则（51300 -> ${LANDING_IPV4}:${LANDING_PORT}）"
iptables -t nat -D PREROUTING -p tcp --dport ${TRANSIT_PORT} -j DNAT --to-destination ${LANDING_IPV4}:${LANDING_PORT} 2>/dev/null || true
iptables -t nat -D PREROUTING -p udp --dport ${TRANSIT_PORT} -j DNAT --to-destination ${LANDING_IPV4}:${LANDING_PORT} 2>/dev/null || true
iptables -t nat -D POSTROUTING -p tcp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -p udp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j MASQUERADE 2>/dev/null || true

iptables -t nat -A PREROUTING -p tcp --dport ${TRANSIT_PORT} -j DNAT --to-destination ${LANDING_IPV4}:${LANDING_PORT}
iptables -t nat -A PREROUTING -p udp --dport ${TRANSIT_PORT} -j DNAT --to-destination ${LANDING_IPV4}:${LANDING_PORT}
iptables -t nat -A POSTROUTING -p tcp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j MASQUERADE
iptables -t nat -A POSTROUTING -p udp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j MASQUERADE

iptables -A FORWARD -p tcp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j ACCEPT
iptables -A FORWARD -p tcp -s ${LANDING_IPV4} --sport ${LANDING_PORT} -j ACCEPT
iptables -A FORWARD -p udp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j ACCEPT
iptables -A FORWARD -p udp -s ${LANDING_IPV4} --sport ${LANDING_PORT} -j ACCEPT

echo ">>> 设置 IPv6 中转规则（51300 -> ${LANDING_IPV6}:${LANDING_PORT}）"
ip6tables -t nat -D PREROUTING -p tcp --dport ${TRANSIT_PORT} -j DNAT --to-destination [${LANDING_IPV6}]:${LANDING_PORT} 2>/dev/null || true
ip6tables -t nat -D PREROUTING -p udp --dport ${TRANSIT_PORT} -j DNAT --to-destination [${LANDING_IPV6}]:${LANDING_PORT} 2>/dev/null || true
ip6tables -t nat -D POSTROUTING -p tcp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j MASQUERADE 2>/dev/null || true
ip6tables -t nat -D POSTROUTING -p udp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j MASQUERADE 2>/dev/null || true

ip6tables -t nat -A PREROUTING -p tcp --dport ${TRANSIT_PORT} -j DNAT --to-destination [${LANDING_IPV6}]:${LANDING_PORT}
ip6tables -t nat -A PREROUTING -p udp --dport ${TRANSIT_PORT} -j DNAT --to-destination [${LANDING_IPV6}]:${LANDING_PORT}
ip6tables -t nat -A POSTROUTING -p tcp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j MASQUERADE
ip6tables -t nat -A POSTROUTING -p udp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j MASQUERADE

ip6tables -A FORWARD -p tcp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j ACCEPT
ip6tables -A FORWARD -p tcp -s ${LANDING_IPV6} --sport ${LANDING_PORT} -j ACCEPT
ip6tables -A FORWARD -p udp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j ACCEPT
ip6tables -A FORWARD -p udp -s ${LANDING_IPV6} --sport ${LANDING_PORT} -j ACCEPT

echo ">>> 中转规则及端口放行已完成 ✅"
