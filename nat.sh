#!/bin/bash
set -e

### ====== 基本参数 ======
TRANSIT_PORT=51300
LANDING_PORT=51200

LANDING_IPV4=1.2.3.4
LANDING_IPV6=2408:xxxx:xxxx::1
### =====================

echo ">>> 开启 IPv4 / IPv6 转发"
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

grep -q net.ipv4.ip_forward /etc/sysctl.conf || cat >> /etc/sysctl.conf << EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl -p

echo ">>> 设置 IPv4 中转规则"

iptables -t nat -A PREROUTING -p tcp --dport ${TRANSIT_PORT} \
  -j DNAT --to-destination ${LANDING_IPV4}:${LANDING_PORT}
iptables -t nat -A PREROUTING -p udp --dport ${TRANSIT_PORT} \
  -j DNAT --to-destination ${LANDING_IPV4}:${LANDING_PORT}

iptables -t nat -A POSTROUTING -p tcp -d ${LANDING_IPV4} --dport ${LANDING_PORT} \
  -j MASQUERADE
iptables -t nat -A POSTROUTING -p udp -d ${LANDING_IPV4} --dport ${LANDING_PORT} \
  -j MASQUERADE

iptables -A FORWARD -p tcp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j ACCEPT
iptables -A FORWARD -p tcp -s ${LANDING_IPV4} --sport ${LANDING_PORT} -j ACCEPT
iptables -A FORWARD -p udp -d ${LANDING_IPV4} --dport ${LANDING_PORT} -j ACCEPT
iptables -A FORWARD -p udp -s ${LANDING_IPV4} --sport ${LANDING_PORT} -j ACCEPT

echo ">>> 设置 IPv6 中转规则（会清空现有 IPv6 防火墙）"

ip6tables -t nat -F
ip6tables -F

ip6tables -t nat -A PREROUTING -p tcp --dport ${TRANSIT_PORT} \
  -j DNAT --to-destination [${LANDING_IPV6}]:${LANDING_PORT}
ip6tables -t nat -A PREROUTING -p udp --dport ${TRANSIT_PORT} \
  -j DNAT --to-destination [${LANDING_IPV6}]:${LANDING_PORT}

ip6tables -t nat -A POSTROUTING -p tcp -d ${LANDING_IPV6} --dport ${LANDING_PORT} \
  -j MASQUERADE
ip6tables -t nat -A POSTROUTING -p udp -d ${LANDING_IPV6} --dport ${LANDING_PORT} \
  -j MASQUERADE

ip6tables -A FORWARD -p tcp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j ACCEPT
ip6tables -A FORWARD -p tcp -s ${LANDING_IPV6} --sport ${LANDING_PORT} -j ACCEPT
ip6tables -A FORWARD -p udp -d ${LANDING_IPV6} --dport ${LANDING_PORT} -j ACCEPT
ip6tables -A FORWARD -p udp -s ${LANDING_IPV6} --sport ${LANDING_PORT} -j ACCEPT

echo ">>> 中转规则已完成"
