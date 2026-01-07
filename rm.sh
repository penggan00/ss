# 清理软件包缓存
apt-get clean
apt-get autoremove -y
apt-get autoclean
# 清理日志文件
find /var/log -type f -name ".gz" -delete
find /var/log -type f -name ".old" -delete
find /var/log -type f -name "*.1" -delete
journalctl --vacuum-time=7d
# 清理临时文件
find /tmp -type f -atime +7 -delete
find /var/tmp -type f -atime +7 -delete
# 清理用户缓存
echo "✅ 清理完成！释放空间: $(df -h / | awk 'NR==2 {print $4}')"