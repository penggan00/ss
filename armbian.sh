sudo rm -f /etc/apt/sources.list.d/armbian*
sudo rm -f /etc/apt/sources.list.d/configng*
sudo rm -f /etc/apt/sources.list.d/naho.moe*
# 检查全局 sources.list
sudo grep -r "armbian" /etc/apt/sources.list /etc/apt/sources.list.d/
# ​2. 重新配置官方 Armbian 仓库​
# 确保密钥目录存在
sudo mkdir -p /etc/apt/keyrings
# 下载并安装官方 GPG 密钥
curl -fsSL https://apt.armbian.com/armbian.key | sudo gpg --dearmor -o /etc/apt/keyrings/armbian.gpg
# 设置正确的权限
sudo chmod 644 /etc/apt/keyrings/armbian.gpg
# 添加官方仓库配置
echo "deb [signed-by=/etc/apt/keyrings/armbian.gpg] https://apt.armbian.com bullseye main bullseye-utils bullseye-desktop" | sudo tee /etc/apt/sources.list.d/armbian.list
# ​3. 完全清除 APT 缓存​
sudo rm -rf /var/lib/apt/lists/*
sudo apt clean
# ​4. 更新软件源​
sudo apt update