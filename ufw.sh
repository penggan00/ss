#!/bin/bash

set -e  # 有错误立即退出

echo "========================================"
echo "开始配置UFW防火墙"
echo "========================================"

# [1] 更新系统
echo "[1/6] 更新系统并安装ufw..."
sudo apt update -y
sudo apt install ufw -y

# [2] 设置默认策略
echo "[2/6] 设置默认策略..."
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing

# [3] 开放必要端口
echo "[3/6] 配置防火墙规则..."
echo "允许端口: 222/tcp (SSH), 80/tcp, 443/tcp, 53/udp, 123/udp"

sudo ufw allow 222/tcp comment 'SSH alternative port'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw allow 53/udp comment 'DNS'
sudo ufw allow 123/udp comment 'NTP'
#sudo ufw allow 12000/tcp comment 'Custom port 12000'

# [4] 检查当前监听的端口
echo "[4/6] 当前系统监听的端口:"
sudo ss -tulnp | head -20

# [5] 启用UFW（自动确认）
echo "[5/6] 启用UFW防火墙..."
echo "注意：已允许SSH端口222，确保您使用此端口连接！"
echo "y" | sudo ufw enable
sudo systemctl enable ufw --now

# [6] 显示结果
echo "[6/6] UFW配置完成！"
echo "========================================"
sudo ufw status numbered
echo "========================================"
echo "重要提醒："
echo "1. 确保端口222可以访问，否则可能丢失SSH连接"
echo "2. 如需修改规则：sudo ufw delete [规则号]"
echo "3. 查看详细日志：sudo ufw status verbose"
echo "4. 启用：sudo ufw allow 12000"
echo "5. 启用：sudo ufw deny 12000"
echo "6. 删除：sudo ufw delete allow 12000"