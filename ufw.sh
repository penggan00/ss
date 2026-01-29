#!/bin/bash
# UFW 一键配置脚本
echo "alias docker-compose='docker compose'" >> ~/.bashrc && source ~/.bashrc
# 修改SSH配置文件
echo "修改SSH配置文件..."
sed -i '/^#*PasswordAuthentication/c\PasswordAuthentication no' /etc/ssh/sshd_config
sed -i '/^#*PubkeyAuthentication/c\PubkeyAuthentication yes' /etc/ssh/sshd_config
sed -i '/^#*PermitRootLogin/c\PermitRootLogin prohibit-password' /etc/ssh/sshd_config
sed -i '/^#*ChallengeResponseAuthentication/c\ChallengeResponseAuthentication no' /etc/ssh/sshd_config

# 确保222端口配置存在
echo "配置SSH端口..."
sed -i 's/^#Port 22$/Port 222/; s/^Port 22$/Port 222/; s/^#Port 222$/Port 222/' /etc/ssh/sshd_config

# 重启SSH服务
echo "重启SSH服务..."
systemctl restart sshd
# 验证SSH配置
echo "当前SSH配置:"
grep -E "^(PasswordAuthentication|PubkeyAuthentication|PermitRootLogin|Port)" /etc/ssh/sshd_config

#新加坡时区
apt-get update && apt-get install -y systemd-timesyncd
timedatectl set-timezone Asia/Singapore && \
timedatectl set-local-rtc 0 && \
timedatectl set-ntp true && \
echo "✅ 时区设置完成" && \
timedatectl status

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

# 5. 允许指定端口（只开通 222、80、443）
echo "添加允许的端口规则..."
PORTS="222 80 443"

for port in $PORTS; do
    sudo ufw allow $port/tcp comment "TCP port $port"
    echo "允许 TCP 端口: $port"
done

# 6. 启用 UFW
echo "启用 UFW..."
sudo ufw --force enable

# 7. 显示规则
echo ""
echo "当前 UFW 规则:"
sudo ufw status numbered

echo ""
echo "========================================="
echo "UFW 配置完成！"
echo "已开通端口: 222 (TCP), 80 (TCP), 443 (TCP)"
echo "========================================="
echo "常用命令:"
echo "  sudo ufw status numbered  # 查看规则"
echo "  sudo ufw delete 规则号    # 删除规则"
echo "  sudo ufw allow 端口号     # 增加规则"
echo "  sudo ufw disable          # 禁用防火墙"
echo "  sudo ufw enable           # 启用防火墙"