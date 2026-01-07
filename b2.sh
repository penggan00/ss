#!/bin/bash
# b2.sh - 安全安装脚本

# 使用环境变量传递密钥
B2_ACCOUNT=${B2_ACCOUNT:-""}
B2_KEY=${B2_KEY:-""}

# 检查环境变量是否设置
if [ -z "$B2_ACCOUNT" ] || [ -z "$B2_KEY" ]; then
    echo "错误: 请设置环境变量 B2_ACCOUNT 和 B2_KEY"
    echo "  bash <(curl -sL https://raw.githubusercontent.com/.../b2.sh)"
    exit 1
fi

# 安装流程
sudo apt update && sudo apt install unzip -y
curl https://rclone.org/install.sh | sudo bash

# 创建配置目录
mkdir -p ~/.config/rclone

# 使用环境变量创建配置文件
cat > ~/.config/rclone/rclone.conf <<EOF
[penggan]
type = b2
account = ${B2_ACCOUNT}
key = ${B2_KEY}
EOF

chmod 600 ~/.config/rclone/rclone.conf

echo "安装完成！"
rclone config show penggan