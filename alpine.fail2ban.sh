#!/bin/sh
echo "=== Alpine Linux fail2ban 安装配置 ==="

# 1. 更新包管理器
echo "1. 更新软件包列表..."
apk update

# 2. 安装 fail2ban
echo "2. 安装 fail2ban..."
apk add fail2ban

# 3. 创建配置目录
echo "3. 创建配置目录..."
mkdir -p /etc/fail2ban/jail.d
echo "=== 修复 fail2ban 配置 ==="

# 停止服务
rc-service fail2ban stop 2>/dev/null

# 创建简化配置
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
bantime = 3600
findtime = 600
EOF

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
fi

bash -c "$(curl -fsSL https://raw.githubusercontent.com/penggan00/ss/main/ip.sh)"
