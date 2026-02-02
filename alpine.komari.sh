#!/bin/sh
# 简化版 Alpine B2 安装脚本

# 设置您的 B2 凭证
B2_ACCOUNT="您的账户ID"
B2_KEY="您的应用密钥"

# 安装依赖
apk add --no-cache curl unzip

# 下载最新 rclone
cd /tmp
curl -LO https://downloads.rclone.org/rclone-current-linux-amd64.zip
unzip rclone-current-linux-amd64.zip
cd rclone-*-linux-amd64

# 安装
cp rclone /usr/local/bin/
chmod +x /usr/local/bin/rclone

# 创建配置
mkdir -p ~/.config/rclone
cat > ~/.config/rclone/rclone.conf <<EOF
[b2backup]
type = b2
account = ${B2_ACCOUNT}
key = ${B2_KEY}
EOF

# 测试
echo "安装完成！测试连接："
rclone lsd b2backup: