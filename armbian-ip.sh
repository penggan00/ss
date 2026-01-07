# 一、基础网络配置
# 设置静态IP
cat << 'EOF' > /etc/network/interfaces
auto eth0
iface eth0 inet static
address 192.168.3.33
netmask 255.255.255.0
gateway 192.168.3.1
dns-nameservers 8.8.8.8 223.6.6.6 223.5.5.5 1.1.1.1 192.168.3.1 
EOF
sudo systemctl restart networking
# sudo nano /etc/sysctl.conf
# net.ipv4.ip_forward=1
# sudo sysctl -p
# ip转发
cat << 'EOF' >> /etc/sysctl.conf
net.ipv4.ip_forward=1
EOF
sudo sysctl -p
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i eth0 -j ACCEPT
sudo apt install iptables-persistent -y
sudo netfilter-persistent save
# ipv6
# 一、禁用IPv6的完整步骤
# 方法1：通过sysctl临时禁用
# 临时禁用所有接口的IPv6
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1
# 方法2：永久禁用IPv6（推荐）
# sudo nano /etc/sysctl.conf
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
# net.ipv6.conf.lo.disable_ipv6 = 1
cat << 'EOF' >> /etc/sysctl.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sudo sysctl -p
cat /proc/sys/net/ipv6/conf/all/disable_ipv6  
# 显示1表示已禁用