# 完整的时区设置
sudo timedatectl set-timezone Asia/Singapore && \
sudo timedatectl set-local-rtc 0 && \
sudo timedatectl set-ntp true && \
echo "✅ 时区设置完成" && \
timedatectl status