#!/bin/bash
#bash <(curl -sL https://raw.githubusercontent.com/penggan00/ss/main/vps.sh) "ACCESS_TOKEN"

TOKEN="$1"
echo "===== 开始配置 VPS ====="
echo "配置 SSH..."
sed -i '/^#*PasswordAuthentication/c\PasswordAuthentication no' /etc/ssh/sshd_config
sed -i '/^#*PubkeyAuthentication/c\PubkeyAuthentication yes' /etc/ssh/sshd_config
sed -i '/^#*PermitRootLogin/c\PermitRootLogin prohibit-password' /etc/ssh/sshd_config
sed -i '/^#*ChallengeResponseAuthentication/c\ChallengeResponseAuthentication no' /etc/ssh/sshd_config
sed -i 's/^#Port 22$/Port 222/; s/^Port 22$/Port 222/; s/^#Port 222$/Port 222/' /etc/ssh/sshd_config

URL="https://ssh-wood-e28b.penggan00.workers.dev"
KEY=$(curl -s -H "Authorization: Bearer $TOKEN" "$URL")

mkdir -p /root/.ssh
echo "$KEY" > /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

echo "重启 SSH 服务..."
systemctl restart sshd

echo "当前SSH配置:"
grep -E "^(PasswordAuthentication|PubkeyAuthentication|PermitRootLogin|Port)" /etc/ssh/sshd_config

echo ""
echo "✅ SSH公钥已成功配置！"
echo "重要提示: 请确保您在其他终端成功连接后再关闭当前会话！"

# 继续执行其他安装任务
echo "开始安装常用工具..."
apt update -y
apt upgrade -y
apt install -y curl wget git htop tmux nano tree jq fail2ban ufw 

# 完整的时区设置
apt-get update && apt-get install -y systemd-timesyncd
timedatectl set-timezone Asia/Singapore && \
timedatectl set-local-rtc 0 && \
timedatectl set-ntp true && \
echo "✅ 时区设置完成" && \
timedatectl status

# 设置交换空间
echo "设置交换空间..."
swapoff -a 2>/dev/null
rm -f /swapfile
dd if=/dev/zero of=/swapfile bs=1M count=1024
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
sed -i '/swap/d' /etc/fstab
echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
echo "vm.swappiness=10" | tee /etc/sysctl.d/99-swap.conf
sysctl -p /etc/sysctl.d/99-swap.conf

# 安装BBR（可选）
echo "正在安装BBR加速..."
wget --no-check-certificate -O /opt/bbr.sh https://raw.githubusercontent.com/penggan00/ss/main/bbr.sh
chmod +x /opt/bbr.sh
/opt/bbr.sh

echo ""
echo "✅ 所有配置完成！"
echo "========================================="
echo "重要信息:"
echo "1. SSH端口: 222"
echo "2. 密码登录已禁用"
echo "3. 使用提供的公钥进行SSH认证"
echo "4. 请立即使用新配置测试连接:"
echo "   ssh -p 222 root@服务器IP"
echo "========================================="

