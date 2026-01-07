#!/bin/bash

# 强制非交互式安装
export DEBIAN_FRONTEND=noninteractive

# 1. 系统更新及基础工具
sudo apt update -y && \
sudo apt upgrade -y && \
sudo apt install -y --no-install-recommends \
    curl \
    git \
    python3-venv \
    ca-certificates \
    gnupg \
    lsb-release \
    nano

# 2. 配置虚拟内存（1GB）
fallocate -l 1G /swapfile && \
chmod 600 /swapfile && \
mkswap /swapfile && \
swapon /swapfile && \
echo "/swapfile none swap sw 0 0" >> /etc/fstab && \
sysctl vm.swappiness=10 && \
echo "vm.swappiness=10" >> /etc/sysctl.conf

# 3. 设置新加坡时区
timedatectl set-timezone Asia/Singapore && \
timedatectl set-local-rtc 0 && \
hwclock --systohc

# 4. Docker 安装
sudo mkdir -m 0755 -p /etc/apt/keyrings && \
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && \
sudo apt update -y && \
sudo apt install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin && \
sudo docker run --rm hello-world > /dev/null 2>&1

# 5. Docker Compose 安装
COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -Po '"tag_name": "\K[\d.]+') && \
sudo curl -L "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && \
sudo chmod +x /usr/local/bin/docker-compose

# 6. 克隆项目并执行安装
git clone https://github.com/penggan00/rss.git ~/rss && \
chmod +x ~/rss/setup.sh && \
/bin/bash ~/rss/setup.sh
echo "加入环境变量.env"
nano .env
echo "创建usd.py脚本"
nano usd.py
# 7. 最终状态验证
echo -e "\n\033[32m[完成] 系统已配置：\033[0m"
swapon --show && free -h && \
echo -e "\n\033[34m当前时区：\033[0m" && timedatectl status && \
echo -e "\n\033[34mDocker 版本：\033[0m" && docker --version && \
echo -e "\033[34mDocker Compose 版本：\033[0m" && docker-compose --version