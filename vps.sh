#!/bin/bash

# 检查是否提供了公钥参数
if [ $# -eq 0 ]; then
    echo "错误: 请提供SSH公钥作为参数"
    echo "用法: bash <(curl -sL https://raw.githubusercontent.com/penggan00/penggan00.github.io/main/my-blog/sh/ssh.sh) \"公钥内容\""
    exit 1
fi

SSH_PUBKEY="$1"

# 检测系统类型
detect_os() {
    if [ -f /etc/alpine-release ]; then
        echo "alpine"
    elif [ -f /etc/debian_version ] || [ -f /etc/ubuntu_version ]; then
        echo "debian"
    elif [ -f /etc/centos-release ] || [ -f /etc/redhat-release ]; then
        echo "centos"
    else
        echo "unknown"
    fi
}

OS_TYPE=$(detect_os)

echo "检测到系统类型: $OS_TYPE"

# 公共配置函数 - 设置SSH密钥
setup_ssh_keys() {
    echo "配置SSH公钥..."
    
    # 设置root用户的SSH密钥
    sudo mkdir -p /root/.ssh && sudo chmod 700 /root/.ssh
    echo "$SSH_PUBKEY" | sudo tee /root/.ssh/authorized_keys > /dev/null
    sudo chmod 600 /root/.ssh/authorized_keys
    
    # 如果是普通用户，也配置当前用户
    if [ "$EUID" -ne 0 ]; then
        echo "为当前用户配置SSH密钥..."
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        echo "$SSH_PUBKEY" > ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
    fi
}

# 公共配置函数 - 修改SSH配置
modify_ssh_config() {
    echo "修改SSH配置文件..."
    
    # 修改认证设置
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    
    # 配置SSH端口
    echo "配置SSH端口..."
    # 先注释掉现有的 Port 行
    sed -i 's/^Port/#Port/' /etc/ssh/sshd_config
    # 确保新端口在文件末尾
    grep -q '^Port 222' /etc/ssh/sshd_config || echo "Port 222" >> /etc/ssh/sshd_config
    
    # 确保允许密钥认证
    grep -q '^AuthorizedKeysFile' /etc/ssh/sshd_config || echo "AuthorizedKeysFile .ssh/authorized_keys" >> /etc/ssh/sshd_config
}

# 公共配置函数 - 添加docker-compose别名
add_docker_alias() {
    echo "添加docker-compose别名..."
    echo "alias docker-compose='docker compose'" >> ~/.bashrc
    if [ -f ~/.zshrc ]; then
        echo "alias docker-compose='docker compose'" >> ~/.zshrc
    fi
    source ~/.bashrc 2>/dev/null || true
}

# Alpine Linux 特定配置
setup_alpine() {
    echo "正在配置 Alpine Linux 系统..."
    
    # 安装必要工具
    apk update
    apk add --no-cache curl openssh-server sudo
    
    # 设置SSH服务
    rc-update add sshd 2>/dev/null || true
    rc-service sshd start 2>/dev/null || true
    
    # 修改SSH配置
    modify_ssh_config
    
    # 设置SSH密钥
    setup_ssh_keys
    
    # 重启SSH服务
    echo "重启SSH服务..."
    rc-service sshd restart 2>/dev/null || /etc/init.d/sshd restart 2>/dev/null || systemctl restart sshd 2>/dev/null
    
    # 验证配置
    echo "当前SSH配置:"
    grep -E "^(PasswordAuthentication|PubkeyAuthentication|PermitRootLogin|Port|AuthorizedKeysFile)" /etc/ssh/sshd_config
    
    # 设置时区
    echo "设置时区..."
    apk add --no-cache tzdata
    ln -sf /usr/share/zoneinfo/Asia/Singapore /etc/localtime
    echo "Asia/Singapore" > /etc/timezone
    hwclock --systohc --utc
    date
}

# Debian/Ubuntu 特定配置
setup_debian() {
    echo "正在配置 Debian/Ubuntu 系统..."
    
    # 修改SSH配置 - 使用debian特定的方式
    echo "修改SSH配置文件..."
    sed -i '/^#*PasswordAuthentication/c\PasswordAuthentication no' /etc/ssh/sshd_config
    sed -i '/^#*PubkeyAuthentication/c\PubkeyAuthentication yes' /etc/ssh/sshd_config
    sed -i '/^#*PermitRootLogin/c\PermitRootLogin prohibit-password' /etc/ssh/sshd_config
    sed -i '/^#*ChallengeResponseAuthentication/c\ChallengeResponseAuthentication no' /etc/ssh/sshd_config
    # 确保222端口配置存在
    echo "配置SSH端口..."
    sed -i 's/^#Port 22$/Port 222/; s/^Port 22$/Port 222/; s/^#Port 222$/Port 222/' /etc/ssh/sshd_config
    
    # 设置SSH密钥
    setup_ssh_keys
    
    echo "重启 SSH 服务..."
    systemctl restart sshd
    
    # 验证SSH配置
    echo "当前SSH配置:"
    grep -E "^(PasswordAuthentication|PubkeyAuthentication|PermitRootLogin|Port)" /etc/ssh/sshd_config
    echo "✅ SSH公钥已成功配置！"
    echo "重要提示: 请确保您在其他终端成功连接后再关闭当前会话！"
    
    # 继续执行其他安装任务
    echo "开始安装常用工具..."
    apt update -y
    apt upgrade -y
    apt install -y curl fail2ban wget nano htop ufw git
    
    # 设置时区
    apt-get update && apt-get install -y systemd-timesyncd
    timedatectl set-timezone Asia/Singapore && \
    timedatectl set-local-rtc 0 && \
    timedatectl set-ntp true && \
    echo "✅ 时区设置完成" && \
    timedatectl status
    
    # 安装docker docker-compose
    curl -fsSL https://get.docker.com | sudo sh && sudo systemctl enable docker && sudo systemctl start docker && sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && sudo chmod +x /usr/local/bin/docker-compose && echo "=== 安装完成 ===" && docker --version && docker-compose --version
}

# 公共配置部分
add_docker_alias

# 根据系统类型执行相应的配置
case "$OS_TYPE" in
    "alpine")
        setup_alpine
        ;;
    "debian"|"ubuntu")
        setup_debian
        ;;
    "centos"|"redhat")
        echo "检测到 CentOS/RedHat 系统，使用类似 Debian 的配置..."
        setup_debian  # 暂时使用debian配置
        ;;
    *)
        echo "未知系统类型，尝试通用配置..."
        # 尝试通用的SSH配置
        modify_ssh_config
        setup_ssh_keys
        
        # 尝试重启SSH服务
        if systemctl --version >/dev/null 2>&1; then
            systemctl restart sshd
        elif service --version >/dev/null 2>&1; then
            service sshd restart
        elif rc-service --version >/dev/null 2>&1; then
            rc-service sshd restart
        fi
        ;;
esac

# 公共的后续配置（所有系统都执行）

# 配置SSH保活（可选）
echo "配置SSH保活..."
cat > ~/.ssh/config << 'EOF'
Host *
  ServerAliveInterval 60
  ServerAliveCountMax 3
  TCPKeepAlive yes
  ControlMaster auto
  ControlPath ~/.ssh/control/%r@%h:%p
  ControlPersist 168h
  Compression yes
  CompressionLevel 6
  IPQoS throughput
  ConnectTimeout 30
  ConnectionAttempts 3
  StrictHostKeyChecking no
EOF
mkdir -p ~/.ssh/control
chmod 700 ~/.ssh
chmod 600 ~/.ssh/config
chmod 700 ~/.ssh/control

# 设置交换空间
echo "设置交换空间..."
swapoff -a 2>/dev/null
rm -f /swapfile 2>/dev/null
dd if=/dev/zero of=/swapfile bs=1M count=1024 2>/dev/null
if [ -f /swapfile ]; then
    chmod 600 /swapfile
    mkswap /swapfile 2>/dev/null
    swapon /swapfile 2>/dev/null
    sed -i '/swap/d' /etc/fstab 2>/dev/null
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab 2>/dev/null
    echo "vm.swappiness=10" | tee /etc/sysctl.d/99-swap.conf 2>/dev/null
    sysctl -p /etc/sysctl.d/99-swap.conf 2>/dev/null
fi

# 安装BBR（可选）
echo "是否安装BBR加速？(y/N)"
read -t 10 -n 1 install_bbr
if [[ "$install_bbr" =~ [yY] ]]; then
    echo "安装BBR..."
    wget --no-check-certificate -O /opt/bbr.sh https://github.com/teddysun/across/raw/master/bbr.sh 2>/dev/null || \
    curl -L -o /opt/bbr.sh https://github.com/teddysun/across/raw/master/bbr.sh
    if [ -f /opt/bbr.sh ]; then
        chmod +x /opt/bbr.sh
        /opt/bbr.sh
    else
        echo "无法下载BBR脚本"
    fi
fi

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