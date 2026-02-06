#!/bin/bash
# UFW 一键配置脚本
echo "alias docker-compose='docker compose'" >> ~/.bashrc && source ~/.bashrc
echo "开始配置 UFW 防火墙..."
# 1. 安装 UFW（如果未安装）
sudo apt-get update
sudo apt-get install -y ufw
# 2. 重置 UFW 规则
echo "重置 UFW 规则..."
sudo ufw --force reset
# 3. 设置默认策略
echo "设置默认策略..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
# 4. 开启 IPv6
sudo sed -i 's/IPV6=no/IPV6=yes/' /etc/default/ufw
# 5. 允许指定端口
echo "添加允许的端口规则..."
# TCP 端口（仅 TCP）
TCP_ONLY_PORTS="222 80 443"

# 同时需要 TCP 和 UDP 的端口
BOTH_PORTS="51200 51201 51202 51203 51300"
# 配置仅 TCP 端口
for port in $TCP_ONLY_PORTS; do
    sudo ufw allow $port/tcp comment "TCP port $port"
    echo "允许 TCP 端口: $port"
done
# 配置仅 UDP 端口
for port in $UDP_ONLY_PORTS; do
    sudo ufw allow $port/udp comment "UDP port $port"
    echo "允许 UDP 端口: $port"
done
# 配置同时需要 TCP 和 UDP 的端口
for port in $BOTH_PORTS; do
    sudo ufw allow $port comment "TCP/UDP port $port"
    echo "允许 TCP/UDP 端口: $port"
done
# 6. 启用 UFW
echo "启用 UFW..."
sudo ufw --force enable
# 7. 显示规则
echo "当前 UFW 规则:"
sudo ufw status numbered
echo ""
echo "UFW 配置完成！"
echo "使用 'sudo ufw status numbered' 查看规则"
echo "使用 'sudo ufw delete 规则号' 删除规则"
echo "使用 'sudo ufw allow 规则号' 增加规则"