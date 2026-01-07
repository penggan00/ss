# 1. 安装Samba服务
sudo apt update && sudo apt install samba -y
# 2. 备份原配置文件
#sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
# 3. 生成新配置文件
cat << 'EOF' >> /etc/samba/smb.conf
[global]
   workgroup = WORKGROUP
   server role = standalone server
   security = user
   map to guest = Bad User
   dns proxy = no
   socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=8192 SO_SNDBUF=8192
   min receivefile size = 16384
   use sendfile = yes
   read raw = yes
   write raw = yes
   max xmit = 65536
   aio read size = 4096
   aio write size = 4096
   log level = 0
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes

[dav]
   path = /mnt
   browseable = yes
   writable = yes
   guest ok = yes
   guest only = yes
   create mask = 0777
   directory mask = 0777
   force user = nobody
   strict sync = no
   oplocks = yes
   kernel oplocks = yes
EOF
# 4. 设置目录权限
sudo chmod -R 777 /mnt
sudo chown -R nobody:nogroup /mnt
# 强制所有新建文件继承父目录权限（可选）
sudo chmod g+s /mnt
# 5. 重启服务
sudo systemctl restart smbd
sudo systemctl enable smbd
echo "SMB共享已启用：smb://$(hostname -I | awk '{print $1}')/dav/"