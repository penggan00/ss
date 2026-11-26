#!/bin/bash

set -euo pipefail

TCP_PORTS="22 222 80 443"
UDP_PORTS="51200"                  # 按需填写，例如："53 123"
TCP_UDP_PORTS="51201 51202 51203"

if [[ $EUID -ne 0 ]]; then
    echo "请使用 sudo 或以 root 身份运行此脚本"
    exit 1
fi

echo "开始配置 UFW 防火墙..."

apt-get update
apt-get install -y ufw

# 远程服务器上先放行当前 SSH 端口，避免断开连接
if systemctl is-active --quiet ssh 2>/dev/null ||
   systemctl is-active --quiet sshd 2>/dev/null; then
    ufw allow 222/tcp comment "SSH port 222"
fi

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw

echo "添加允许的端口规则..."
for port in $TCP_PORTS; do
    ufw allow "${port}/tcp" comment "TCP port ${port}"
done

for port in $UDP_PORTS; do
    ufw allow "${port}/udp" comment "UDP port ${port}"
done

for port in $TCP_UDP_PORTS; do
    ufw allow "${port}/tcp" comment "TCP port ${port}"
    ufw allow "${port}/udp" comment "UDP port ${port}"
done

ufw --force enable

echo
echo "当前 UFW 规则:"
ufw status numbered
echo
echo "UFW 配置完成！"
echo "查看规则：sudo ufw status numbered"
echo "删除规则：sudo ufw delete 规则号"
echo "添加规则：sudo ufw allow 端口/协议"