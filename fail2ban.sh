#!/bin/sh
echo "=== 跨平台 fail2ban 安装配置脚本 ==="
echo "alias docker-compose='docker compose'" >> ~/.bashrc && source ~/.bashrc
sysctl vm.swappiness=10 && echo "vm.swappiness=10" | tee /etc/sysctl.d/99-swappiness.conf
# 检测系统类型
if [ -f /etc/alpine-release ]; then
    SYSTEM="alpine"
elif [ -f /etc/debian_version ]; then
    SYSTEM="debian"
else
    echo "错误：不支持的系统类型"
    exit 1
fi

echo "检测到系统：$SYSTEM"

# 1. 更新包管理器
echo "1. 更新软件包列表..."
if [ "$SYSTEM" = "alpine" ]; then
    apk update
elif [ "$SYSTEM" = "debian" ]; then
    apt update -y
    apt upgrade -y
fi

# 2. 安装 fail2ban
echo "2. 安装 fail2ban..."
if [ "$SYSTEM" = "alpine" ]; then
    apk add fail2ban
elif [ "$SYSTEM" = "debian" ]; then
    apt install -y fail2ban
fi

# 3. 停止服务
echo "3. 停止服务..."
if [ "$SYSTEM" = "alpine" ]; then
    rc-service fail2ban stop 2>/dev/null
elif [ "$SYSTEM" = "debian" ]; then
    systemctl stop fail2ban
fi

# 4. 配置 fail2ban
echo "4. 配置 fail2ban..."
if [ "$SYSTEM" = "alpine" ]; then
    # 创建配置目录
    mkdir -p /etc/fail2ban/jail.d
    
    # 创建配置
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 3600
findtime = 600
maxretry = 3
backend = auto

[sshd]
enabled = true
port = 222
filter = sshd
logpath = /var/log/messages
maxretry = 3
bantime = 31536000
findtime = 86400
EOF

elif [ "$SYSTEM" = "debian" ]; then
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
fi

# 5. 测试配置
echo "5. 测试配置..."
if [ "$SYSTEM" = "alpine" ]; then
    echo "=== 测试配置 ==="
    fail2ban-client -t
    
    if [ $? -eq 0 ]; then
        echo "✓ 配置测试通过"
        
        echo "=== 启动服务 ==="
        rc-service fail2ban start
        
        echo "=== 检查状态 ==="
        rc-service fail2ban status
        
        # 等待服务启动
        sleep 2
        
        echo "=== fail2ban 状态 ==="
        fail2ban-client status
    else
        echo "✗ 配置测试失败，显示详细错误："
        fail2ban-client -d
        exit 1
    fi
elif [ "$SYSTEM" = "debian" ]; then
    systemctl start fail2ban
fi

# 6. 执行额外脚本
echo "6. 执行额外配置..."
bash -c "$(curl -fsSL https://raw.githubusercontent.com/penggan00/ss/main/ip.sh)"

echo "=== fail2ban 安装配置完成 ==="