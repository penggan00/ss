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
# 5. 允许指定端口
echo "添加允许的端口规则..."
# TCP 端口（仅 TCP）
TCP_ONLY_PORTS="222 80 443"

# 同时需要 TCP 和 UDP 的端口
BOTH_PORTS="51200 51201 51202 51203"
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

# 继续执行其他安装任务
echo "开始安装常用工具..."
apt update -y
apt upgrade -y
apt install -y curl fail2ban wget nano htop ufw git

# 配置fail2ban
systemctl stop fail2ban
tee /etc/fail2ban/jail.local > /dev/null << 'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = 222
backend = systemd
maxretry = 3
bantime = 3600
findtime = 600

[recidive]
enabled = true
filter = recidive
logpath = /var/log/fail2ban.log
action = iptables-allports
bantime = 31536000
findtime = 86400
maxretry = 1
EOF
systemctl start fail2ban
bash -c "$(curl -fsSL https://raw.githubusercontent.com/penggan00/ss/main/ip.sh)"