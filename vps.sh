#!/bin/bash

# 检查是否提供了公钥参数
if [ $# -eq 0 ]; then
    echo "错误: 请提供SSH公钥作为参数"
    echo "用法: bash <(curl -sL https://raw.githubusercontent.com/penggan00/penggan00.github.io/main/my-blog/sh/ssh.sh) \"公钥内容\""
    exit 1
fi

SSH_PUBKEY="$1"

# 检测系统类型
if [ -f /etc/alpine-release ]; then
    OS_TYPE="alpine"
    echo "检测到系统: Alpine Linux"
elif [ -f /etc/debian_version ] || [ -f /etc/ubuntu_version ] || [ -f /etc/lsb-release ]; then
    OS_TYPE="debian"
    echo "检测到系统: Debian/Ubuntu"
else
    echo "错误: 不支持的系统类型"
    exit 1
fi

# 公共配置函数 - 设置SSH密钥
setup_ssh_keys() {
    echo "配置SSH公钥..."
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    echo "$SSH_PUBKEY" | tee /root/.ssh/authorized_keys > /dev/null
    chmod 600 /root/.ssh/authorized_keys
}

# Alpine Linux 配置
if [ "$OS_TYPE" = "alpine" ]; then
    echo "正在配置Alpine Linux系统..."
    
    # 安装openssh-server
    apk update
    apk add --no-cache openssh-server
    
    # 1. 修改认证设置
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    
    # 2. 配置SSH端口
    # 先注释掉现有的 Port 行
    sed -i 's/^Port/#Port/' /etc/ssh/sshd_config
    # 确保新端口在文件末尾
    grep -q '^Port 222' /etc/ssh/sshd_config || echo "Port 222" >> /etc/ssh/sshd_config
    
    # 3. 确保允许密钥认证
    grep -q '^AuthorizedKeysFile' /etc/ssh/sshd_config || echo "AuthorizedKeysFile .ssh/authorized_keys" >> /etc/ssh/sshd_config
    
    # 设置SSH密钥
    setup_ssh_keys
    
    # 启动并设置SSH服务
    echo "启动SSH服务..."
    if [ -f /.dockerenv ]; then
        # Docker容器环境
        mkdir -p /run/openrc
        touch /run/openrc/softlevel
        rc-update add sshd default 2>/dev/null || true
        /usr/sbin/sshd -D &
    else
        # 正常系统环境
        rc-service sshd restart 2>/dev/null || true
        rc-update add sshd default 2>/dev/null || true
    fi
    
    rc-service sshd restart 2>/dev/null || true
    
    # 验证配置
    echo "验证SSH配置:"
    echo "1. 查看密码认证是否关闭:"
    grep -E "^PasswordAuthentication" /etc/ssh/sshd_config
    echo "2. 查看密钥认证是否开启:"
    grep -E "^PubkeyAuthentication" /etc/ssh/sshd_config
    echo "3. 查看端口:"
    grep -E "^Port" /etc/ssh/sshd_config
    
    # 添加docker-compose别名
    echo "alias docker-compose='docker compose'" >> ~/.bashrc

    
# Debian/Ubuntu 配置
elif [ "$OS_TYPE" = "debian" ]; then
    echo "正在配置Debian/Ubuntu系统..."
    
    # 修改SSH配置文件
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
    
    echo "重启SSH服务..."
    systemctl restart sshd
    
    # 验证SSH配置
    echo "当前SSH配置:"
    grep -E "^(PasswordAuthentication|PubkeyAuthentication|PermitRootLogin|Port)" /etc/ssh/sshd_config
    echo "✅ SSH公钥已成功配置！"
    echo "重要提示: 请确保您在其他终端成功连接后再关闭当前会话！"
    
    # 添加docker-compose别名
    echo "alias docker-compose='docker compose'" >> ~/.bashrc && source ~/.bashrc
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
fi

echo ""
echo "✅ SSH配置完成！"
echo "========================================="
echo "重要信息:"
echo "1. SSH端口: 222"
echo "2. 密码登录已禁用"
echo "3. 使用提供的公钥进行SSH认证"
echo "4. Root登录: 仅允许密钥认证"
echo "========================================="
echo "请立即使用新配置测试连接:"
echo "ssh -p 222 root@服务器IP"
echo "========================================="