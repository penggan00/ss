red="\033[31m"
black="\033[0m"

base=/etc/dnat
mkdir $base 2>/dev/null
conf=$base/conf
touch $conf

# wget wget --no-check-certificate -qO natcfg.sh http://blog.arloor.com/sh/iptablesUtils/natcfg.sh && bash natcfg.sh

    clear
    echo "#############################################################"
    echo "# Usage: setup iptables nat rules for domian/ip             #"
    echo "# Website:  http://www.arloor.com/                          #"
    echo "# Author: ARLOOR <admin@arloor.com>                         #"
    echo "# Github: https://github.com/arloor/iptablesUtils           #"
    echo "#############################################################"
    echo


setupService(){
    cat > /usr/local/bin/dnat.sh <<"AAAA"
#! /bin/bash
[[ "$EUID" -ne '0' ]] && echo "Error:This script must be run as root!" && exit 1;



base=/etc/dnat
mkdir $base 2>/dev/null
conf=$base/conf
firstAfterBoot=1
lastConfig="/iptables_nat.sh"
lastConfigTmp="/iptables_nat.sh_tmp"


####
echo "正在安装依赖...."
# 检测系统类型并安装依赖
if [ -f /etc/alpine-release ]; then
    # Alpine Linux
    apk add -q bind-tools iptables iptables-openrc 2>/dev/null
    echo "Alpine Linux: 安装bind-tools和iptables"
elif command -v yum >/dev/null 2>&1; then
    # CentOS/RHEL/Fedora
    yum install -y bind-utils iptables iptables-services >/dev/null 2>&1
    echo "CentOS/RHEL: 安装bind-utils和iptables"
elif command -v apt-get >/dev/null 2>&1; then
    # Debian/Ubuntu
    apt-get update >/dev/null 2>&1
    apt-get install -y dnsutils iptables >/dev/null 2>&1
    echo "Debian/Ubuntu: 安装dnsutils和iptables"
elif command -v apk >/dev/null 2>&1; then
    # Alpine Linux (备选检查)
    apk add -q bind-tools iptables iptables-openrc 2>/dev/null
    echo "Alpine Linux: 安装bind-tools和iptables"
else
    echo "无法识别系统类型，请手动安装依赖："
    echo "对于Alpine: apk add bind-tools iptables iptables-openrc"
    echo "对于CentOS: yum install bind-utils iptables iptables-services"
    echo "对于Debian: apt-get install dnsutils iptables"
    exit 1
fi
echo "Completed：依赖安装完毕"
echo ""
####
turnOnNat(){
    # 开启端口转发
    echo "1. 端口转发开启  【成功】"
    
    # 检查并开启IP转发
    if [ -f /etc/alpine-release ]; then
        # Alpine Linux
        if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        fi
        # Alpine使用sysctl -w或直接写到/proc
        echo 1 > /proc/sys/net/ipv4/ip_forward
    else
        # 其他Linux发行版
        sed -i '/^net.ipv4.ip_forward=1/d' /etc/sysctl.conf
        echo -e "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
    
    # 立即生效
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # 检查并开启iptables
    if [ -f /etc/alpine-release ]; then
        # Alpine Linux: 确保iptables服务运行
        if [ -f /etc/init.d/iptables ]; then
            /etc/init.d/iptables start 2>/dev/null || true
            rc-update add iptables boot 2>/dev/null || true
        fi
    fi

    #开放FORWARD链
    echo "2. 开放iptbales中的FORWARD链  【成功】"
    arr1=(`iptables -L FORWARD -n  --line-number |grep "REJECT"|grep "0.0.0.0/0"|sort -r|awk '{print $1,$2,$5}'|tr " " ":"|tr "\n" " "`)  #16:REJECT:0.0.0.0/0 15:REJECT:0.0.0.0/0
    for cell in ${arr1[@]}
    do
        arr2=(`echo $cell|tr ":" " "`)  #arr2=16 REJECT 0.0.0.0/0
        index=${arr2[0]}
        echo 删除禁止FOWARD的规则$index
        iptables -D FORWARD $index
    done
    iptables --policy FORWARD ACCEPT
}
turnOnNat



testVars(){
    local localport=$1
    local remotehost=$2
    local remoteport=$3
    # 判断端口是否为数字
    local valid=
    echo "$localport"|[ -n "`sed -n '/^[0-9][0-9]*$/p'`" ] && echo $remoteport |[ -n "`sed -n '/^[0-9][0-9]*$/p'`" ]||{
       echo  -e "${red}本地端口和目标端口请输入数字！！${black}";
       return 1;
    }
}

dnat(){
     [ "$#" = "3" ]&&{
        local localport=$1
        local remote=$2
        local remoteport=$3

        cat >> $lastConfigTmp <<EOF
iptables -t nat -A PREROUTING -p tcp --dport $localport -j DNAT --to-destination $remote:$remoteport
iptables -t nat -A PREROUTING -p udp --dport $localport -j DNAT --to-destination $remote:$remoteport
iptables -t nat -A POSTROUTING -p tcp -d $remote --dport $remoteport -j SNAT --to-source $localIP
iptables -t nat -A POSTROUTING -p udp -d $remote --dport $remoteport -j SNAT --to-source $localIP
EOF
    }
}

dnatIfNeed(){
  [ "$#" = "3" ]&&{
    local needNat=0
    # 如果已经是ip
    if [ "$(echo  $2 |grep -E -o '([0-9]{1,3}[\.]){3}[0-9]{1,3}')" != "" ];then
        local remote=$2
    else
        local remote=$(host -t a  $2|grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}"|head -1)
    fi

    if [ "$remote" = "" ];then
            echo Warn:解析失败
          return 1;
     fi
  }||{
      echo "Error: host命令缺失或传递的参数数量有误"
      return 1;
  }
    echo $remote >$base/${1}IP
    dnat $1 $remote $3
}


echo "3. 开始监听域名解析变化"
echo ""
while true ;
do
## 获取本机地址
localIP=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 | grep -Ev '(^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.1[6-9]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.2[0-9]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.3[0-1]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^192\.168\.[0-9]{1,3}\.[0-9]{1,3}$)')
if [ "${localIP}" = "" ]; then
        localIP=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1|head -n 1 )
fi
echo  "本机网卡IP [$localIP]"
cat > $lastConfigTmp <<EOF
iptables -t nat -F PREROUTING
iptables -t nat -F POSTROUTING
EOF
arr1=(`cat $conf`)
for cell in ${arr1[@]}
do
    arr2=(`echo $cell|tr ":" " "|tr ">" " "`)  #arr2=16 REJECT 0.0.0.0/0
    # 过滤非法的行
    [ "${arr2[2]}" != "" -a "${arr2[3]}" = "" ]&& testVars ${arr2[0]}  ${arr2[1]} ${arr2[2]}&&{
        echo "转发规则： ${arr2[0]} => ${arr2[1]}:${arr2[2]}"
        dnatIfNeed ${arr2[0]} ${arr2[1]} ${arr2[2]}
    }
done

lastConfigTmpStr=`cat $lastConfigTmp`
lastConfigStr=`cat $lastConfig`
if [ "$firstAfterBoot" = "1" -o "$lastConfigTmpStr" != "$lastConfigStr" ];then
    echo '更新iptables规则[DOING]'
    source $lastConfigTmp
    cat $lastConfigTmp > $lastConfig
    echo '更新iptables规则[DONE]，新规则如下：'
    echo "###########################################################"
    iptables -L PREROUTING -n -t nat --line-number
    iptables -L POSTROUTING -n -t nat --line-number
    echo "###########################################################"
else
 echo "iptables规则未变更"
fi

firstAfterBoot=0
echo '' > $lastConfigTmp
sleep 60
echo ''
echo ''
echo ''
done    
AAAA
echo 

# 创建服务管理
if [ -f /etc/alpine-release ]; then
    echo "检测到Alpine Linux系统，创建OpenRC服务..."
    
    # 创建openrc服务
    cat > /etc/init.d/dnat <<'EOF'
#!/sbin/openrc-run

name="dnat"
description="动态设置iptables转发规则"
command="/usr/local/bin/dnat.sh"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}

start() {
    ebegin "启动 ${RC_SVCNAME}"
    start-stop-daemon --start --background --make-pidfile \
        --pidfile "${pidfile}" --exec "${command}"
    eend $?
}

stop() {
    ebegin "停止 ${RC_SVCNAME}"
    start-stop-daemon --stop --pidfile "${pidfile}"
    eend $?
}
EOF

    chmod +x /etc/init.d/dnat
    
    echo "OpenRC服务创建完成"
    echo "你可以使用以下命令管理服务："
    echo "  rc-service dnat start    # 启动服务"
    echo "  rc-service dnat stop     # 停止服务"
    echo "  rc-service dnat restart  # 重启服务"
    echo "  rc-update add dnat       # 添加到开机启动"
    
else
    # 非Alpine系统，创建systemd服务
    echo "检测到非Alpine系统，创建systemd服务..."
    
    # 确保目录存在
    mkdir -p /lib/systemd/system /etc/systemd/system
    
    cat > /lib/systemd/system/dnat.service <<'EOF'
[Unit]
Description=动态设置iptables转发规则
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/root/
ExecStart=/bin/bash /usr/local/bin/dnat.sh
Restart=always
RestartSec=30
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=dnat

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable dnat 2>/dev/null || true
    service dnat stop 2>/dev/null || true
    service dnat start 2>/dev/null || true
fi

# 启动服务
if [ -f /etc/alpine-release ]; then
    # Alpine: 启动并添加到开机启动
    rc-service dnat stop 2>/dev/null || true
    rc-service dnat start 2>/dev/null || true
    rc-update add dnat 2>/dev/null || true
    
    # 确保iptables服务也启动
    if [ -f /etc/init.d/iptables ]; then
        rc-update add iptables boot 2>/dev/null || true
        rc-service iptables start 2>/dev/null || true
    fi
    
    echo ""
    echo "================================================"
    echo "Alpine Linux 配置完成！"
    echo "服务状态："
    rc-service dnat status 2>/dev/null || echo "  dnat服务状态检查失败，请手动检查"
    echo ""
    echo "常用命令："
    echo "  rc-service dnat status    # 查看服务状态"
    echo "  rc-service dnat restart   # 重启服务"
    echo "  rc-service dnat stop      # 停止服务"
    echo "  logs dnat                 # 查看服务日志"
    echo ""
    echo "当前转发规则："
    cat $conf 2>/dev/null | while read line; do echo "  $line"; done
    echo "================================================"
else
    echo ""
    echo "================================================"
    echo "服务配置完成！"
    echo "服务状态："
    systemctl status dnat --no-pager 2>/dev/null || service dnat status 2>/dev/null || echo "  请手动检查服务状态"
    echo ""
    echo "当前转发规则："
    cat $conf 2>/dev/null | while read line; do echo "  $line"; done
    echo "================================================"
fi
}


## 获取本机地址
localIP=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 | grep -Ev '(^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.1[6-9]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.2[0-9]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.3[0-1]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^192\.168\.[0-9]{1,3}\.[0-9]{1,3}$)')
if [ "${localIP}" = "" ]; then
        localIP=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1|head -n 1 )
fi


addDnat(){
    local localport=
    local remoteport=
    local remotehost=
    local valid=
    echo -n "本地端口号:" ;read localport
    echo -n "远程端口号:" ;read remoteport
    # echo $localport $remoteport
    # 判断端口是否为数字
    echo "$localport"|[ -n "`sed -n '/^[0-9][0-9]*$/p'`" ] && echo $remoteport |[ -n "`sed -n '/^[0-9][0-9]*$/p'`" ]||{
        echo  -e "${red}本地端口和目标端口请输入数字！！${black}"
        return 1;
    }

    echo -n "目标域名/IP:" ;read remotehost
    # # 检查输入的不是IP
    # if [ "$remotehost" = "" -o "$(echo  $remotehost |grep -E -o '([0-9]{1,3}[\.]){3}[0-9]{1,3}')" != "" ];then
    #     isip=true
    #     remote=$remotehost
    #     echo -e "${red}请输入一个ddns域名${black}"
    #     return 1
    # fi

    sed -i "s/^$localport.*/$localport>$remotehost:$remoteport/g" $conf
    [ "$(cat $conf|grep "$localport>$remotehost:$remoteport")" = "" ]&&{
            cat >> $conf <<LINE
$localport>$remotehost:$remoteport
LINE
    }
    echo "成功添加转发规则 $localport>$remotehost:$remoteport"
    setupService
}

rmDnat(){
    local localport=
    echo -n "本地端口号:" ;read localport
    sed -i "/^$localport>.*/d" $conf
    echo "done!"
}

testVars(){
    local localport=$1
    local remotehost=$2
    local remoteport=$3
    # 判断端口是否为数字
    local valid=
    echo "$localport"|[ -n "`sed -n '/^[0-9][0-9]*$/p'`" ] && echo $remoteport |[ -n "`sed -n '/^[0-9][0-9]*$/p'`" ]||{
       # echo  -e "${red}本地端口和目标端口请输入数字！！${black}";
       return 1;
    }

    # # 检查输入的不是IP
    # if [ "$(echo  $remotehost |grep -E -o '([0-9]{1,3}[\.]){3}[0-9]{1,3}')" != "" ];then
    #     local isip=true
    #     local remote=$remotehost

    #     # echo -e "${red}警告：你输入的目标地址是一个ip!${black}"
    #     return 2;
    # fi
}

lsDnat(){
    arr1=(`cat $conf`)
for cell in ${arr1[@]}  
do
    arr2=(`echo $cell|tr ":" " "|tr ">" " "`)  #arr2=16 REJECT 0.0.0.0/0
    # 过滤非法的行
    [ "${arr2[2]}" != "" -a "${arr2[3]}" = "" ]&& testVars ${arr2[0]}  ${arr2[1]} ${arr2[2]}&&{
        echo "转发规则： ${arr2[0]}>${arr2[1]}:${arr2[2]}"
    }
done
}




echo  -e "${red}你要做什么呢（请输入数字）？Ctrl+C 退出本脚本${black}"
select todo in 增加转发规则 删除转发规则 列出所有转发规则 查看当前iptables配置
do
    case $todo in
    增加转发规则)
        addDnat
        #break
        ;;
    删除转发规则)
        rmDnat
        #break
        ;;
    # 增加到IP的转发)
    #     addSnat
    #     #break
    #     ;;
    # 删除到IP的转发)
    #     rmSnat
    #     #break
    #     ;;
    列出所有转发规则)
        lsDnat
        ;;
    查看当前iptables配置)
        echo "###########################################################"
        iptables -L PREROUTING -n -t nat --line-number
        iptables -L POSTROUTING -n -t nat --line-number
        echo "###########################################################"
        ;;
    *)
        echo "如果要退出，请按Ctrl+C"
        ;;
    esac
done