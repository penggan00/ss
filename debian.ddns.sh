#!/bin/sh

# ==========================================
# 智能安装脚本 - 支持 OpenWrt / Debian
# 用法: 直接运行，会从命令行环境变量读取配置并保存
# ==========================================

# 检测系统
detect_system() {
    if [ -f /etc/openwrt_release ]; then
        echo "openwrt"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/alpine-release ]; then
        echo "alpine"
    else
        echo "generic"
    fi
}

SYS_TYPE=$(detect_system)
echo "========================================="
echo "🧠 智能 Cloudflare DDNS 安装"
echo "📌 检测到系统: $SYS_TYPE"
echo "========================================="

# ==========================================
# 检查并保存环境变量到配置文件
# ==========================================

echo "📝 保存环境变量配置..."

# 检测当前传入的环境变量
if [ -n "$CF_KEY" ] && [ -n "$DOMAIN" ] && [ -n "$SUB" ]; then
    echo "✅ 检测到环境变量，保存到 /etc/cf-ddns.env"
    
    # 创建配置文件
    cat > /etc/cf-ddns.env << EOF
# ==========================================
# Cloudflare DDNS 配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ==========================================

# 强制 IPv6（1=强制IPv6，0=自动检测）
FORCE_IPV6="${FORCE_IPV6:-0}"

# Cloudflare API Token
CF_KEY="${CF_KEY}"

# 主域名
DOMAIN="${DOMAIN}"

# 子域名（多个用逗号分隔）
SUB="${SUB}"

# Cloudflare 代理（1=开启，0=关闭）
CF_PROXY="${CF_PROXY:-0}"

# TTL 值（数字或 auto）
CF_TTL="${CF_TTL:-auto}"
EOF

    chmod 600 /etc/cf-ddns.env
    echo "✅ 配置已保存到 /etc/cf-ddns.env"
    echo ""
    cat /etc/cf-ddns.env
    echo ""
else
    echo "⚠️ 未检测到环境变量，使用默认配置..."
    # 如果配置文件不存在，创建默认配置
    if [ ! -f /etc/cf-ddns.env ]; then
        cat > /etc/cf-ddns.env << 'EOF'
# ==========================================
# Cloudflare DDNS 配置文件
# ==========================================

FORCE_IPV6=0
CF_KEY="cfat_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
DOMAIN="yourdomain.com"
SUB="subdomain"
CF_PROXY=0
CF_TTL=auto
EOF
        chmod 600 /etc/cf-ddns.env
        echo "⚠️ 请编辑 /etc/cf-ddns.env 填入你的 API 密钥和域名"
    fi
fi

# ==========================================
# 安装 curl（如果缺失）
# ==========================================

install_curl() {
    if command -v curl >/dev/null 2>&1; then
        echo "✅ curl 已安装"
        return
    fi
    
    echo "📦 安装 curl..."
    case "$SYS_TYPE" in
        openwrt)
            if command -v opkg >/dev/null 2>&1; then
                opkg update && opkg install curl
            elif command -v apk >/dev/null 2>&1; then
                apk update && apk add curl
            fi
            ;;
        debian|generic)
            if command -v apt >/dev/null 2>&1; then
                apt update && apt install -y curl
            elif command -v apt-get >/dev/null 2>&1; then
                apt-get update && apt-get install -y curl
            fi
            ;;
        alpine)
            apk update && apk add curl
            ;;
    esac
}

install_curl

# ==========================================
# 下载或创建主脚本
# ==========================================

mkdir -p /usr/local/bin

echo "📥 安装 DDNS 核心脚本..."
# 尝试从远程下载
if curl -fsSL https://raw.githubusercontent.com/penggan00/ss/main/cf-ddns.sh -o /usr/local/bin/cf-ddns.sh 2>/dev/null; then
    echo "✅ 从远程下载成功"
else
    echo "⚠️ 远程下载失败，使用内嵌脚本..."
    cat > /usr/local/bin/cf-ddns.sh << 'EOFCF'
#!/bin/sh
set -e

# ==========================================
# 加载环境变量（优先使用命令行传入）
# ==========================================

# 如果命令行没有传入，从配置文件加载
if [ -z "$CF_KEY" ] || [ -z "$DOMAIN" ] || [ -z "$SUB" ]; then
    if [ -f /etc/cf-ddns.env ]; then
        set -a
        . /etc/cf-ddns.env
        set +a
    fi
fi

# ==========================================
# 参数验证
# ==========================================

[ -z "$CF_KEY" ] && echo "❌ CF_KEY 不能为空" && exit 1
[ -z "$DOMAIN" ] && echo "❌ DOMAIN 不能为空" && exit 1
[ -z "$SUB" ] && echo "❌ SUB 不能为空" && exit 1

# 处理 TTL
if [ -z "$CF_TTL" ] || [ "$CF_TTL" = "auto" ]; then
    TTL=1
else
    TTL="$CF_TTL"
fi

PROXY=$( [ "$CF_PROXY" = "1" ] && echo true || echo false )

# ==========================================
# 系统检测
# ==========================================

detect_system() {
    if [ -f /etc/openwrt_release ]; then
        echo "openwrt"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/alpine-release ]; then
        echo "alpine"
    else
        echo "generic"
    fi
}

SYS_TYPE=$(detect_system)

# ==========================================
# 日志函数
# ==========================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> /var/log/cf-ddns.log 2>/dev/null || true
    if command -v logger >/dev/null 2>&1; then
        logger -t cf-ddns "$msg"
    fi
}

# ==========================================
# 获取接口列表
# ==========================================

get_interfaces() {
    case "$SYS_TYPE" in
        openwrt)
            echo "pppoe-wan wan"
            ip link show | grep -o '^[0-9]\+: \([^:]\+\)' | awk '{print $2}' | grep -v lo || true
            ;;
        debian|alpine|generic)
            ip link show | grep -o '^[0-9]\+: \([^:]\+\)' | awk '{print $2}' | grep -E '^(eth|ens|enp|eno|enx|en|wan)' || true
            ;;
    esac
}

# ==========================================
# 获取 IPv6
# ==========================================

get_ipv6_from_interface() {
    local iface="$1"
    ip -6 addr show dev "$iface" 2>/dev/null | \
        grep 'inet6' | \
        grep -v 'fe80' | \
        grep -v 'fd' | \
        grep -v 'fc' | \
        grep -v '::1' | \
        head -1 | \
        awk '{print $2}' | \
        cut -d/ -f1
}

# ==========================================
# 检查是否为公网 IP
# ==========================================

is_public_ipv6() {
    [ -n "$1" ] && ! echo "$1" | grep -qiE '^(fc|fd|fe80|100:|::1)'
}

is_public_ipv4() {
    [ -n "$1" ] && ! echo "$1" | grep -qE '^(100\.|172\.16\.|10\.|192\.168\.|127\.)'
}

# ==========================================
# 获取公网 IP
# ==========================================

log "========================================="
log "🚀 Cloudflare DDNS 更新"
log "📌 系统: $SYS_TYPE"
log "📌 域名: ${SUB}.${DOMAIN}"
log "========================================="

if [ "$FORCE_IPV6" = "1" ]; then
    log "🔒 强制 IPv6 模式"
    IPV6=""
    
    for iface in $(get_interfaces); do
        [ -z "$iface" ] && continue
        IPV6=$(get_ipv6_from_interface "$iface")
        if is_public_ipv6 "$IPV6"; then
            log "  ✅ 从 $iface: $IPV6"
            break
        fi
    done
    
    if ! is_public_ipv6 "$IPV6"; then
        for svc in "ip.sb" "v6.ident.me" "api6.ipify.org"; do
            IPV6=$(curl -s --connect-timeout 5 -6 "$svc" 2>/dev/null | grep -Eo '([a-f0-9:]+:+)+[a-f0-9]+' | head -1)
            if is_public_ipv6 "$IPV6"; then
                log "  ✅ 从 $svc: $IPV6"
                break
            fi
        done
    fi
    
    if is_public_ipv6 "$IPV6"; then
        IP="$IPV6"
        TYPE="AAAA"
        log "✅ 最终 IPv6: $IP"
    else
        log "❌ 无法获取公网 IPv6"
        exit 1
    fi
else
    log "🌐 自动检测 IP"
    IPV4=""
    IPV6=""
    
    for svc in "ipv4.ip.sb" "v4.ident.me" "api.ipify.org"; do
        TEMP=$(curl -s --connect-timeout 5 -4 "$svc" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        if is_public_ipv4 "$TEMP"; then
            IPV4="$TEMP"
            log "  ✅ IPv4: $IPV4"
            break
        fi
    done
    
    if [ -z "$IPV4" ]; then
        for iface in $(get_interfaces); do
            [ -z "$iface" ] && continue
            IPV6=$(get_ipv6_from_interface "$iface")
            if is_public_ipv6 "$IPV6"; then
                log "  ✅ 从 $iface: $IPV6"
                break
            fi
        done
        
        if ! is_public_ipv6 "$IPV6"; then
            IPV6=$(curl -s --connect-timeout 5 -6 ip.sb 2>/dev/null | grep -Eo '([a-f0-9:]+:+)+[a-f0-9]+' | head -1)
            is_public_ipv6 "$IPV6" && log "  ✅ 外部: $IPV6"
        fi
    fi
    
    IP="${IPV4:-$IPV6}"
    TYPE="A"
    [ -z "$IPV4" ] && TYPE="AAAA"
    
    if [ -z "$IP" ]; then
        log "❌ 无法获取公网 IP"
        exit 1
    fi
    log "📝 使用 ${TYPE}: $IP"
fi

# ==========================================
# Cloudflare API
# ==========================================

get_zone_id() {
    curl -s "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
        -H "Authorization: Bearer $CF_KEY" \
        -H "Content-Type: application/json" | \
        grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//'
}

update_record() {
    local full_domain="$1"
    log "🔄 $full_domain"
    
    RECORD_RESPONSE=$(curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$TYPE&name=$full_domain" \
        -H "Authorization: Bearer $CF_KEY" \
        -H "Content-Type: application/json")
    
    RECORD_ID=$(echo "$RECORD_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')
    DATA="{\"type\":\"$TYPE\",\"name\":\"$full_domain\",\"content\":\"$IP\",\"ttl\":$TTL,\"proxied\":$PROXY}"
    
    if [ -n "$RECORD_ID" ]; then
        RES=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
            -H "Authorization: Bearer $CF_KEY" \
            -H "Content-Type: application/json" \
            -d "$DATA")
    else
        RES=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
            -H "Authorization: Bearer $CF_KEY" \
            -H "Content-Type: application/json" \
            -d "$DATA")
    fi
    
    if echo "$RES" | grep -q '"success":true'; then
        log "✅ $full_domain -> $IP"
    else
        ERR=$(echo "$RES" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"//')
        log "❌ $full_domain: $ERR"
    fi
    sleep 1
}

# ==========================================
# 主执行
# ==========================================

ZONE_ID=$(get_zone_id)
if [ -z "$ZONE_ID" ]; then
    log "❌ 无法获取 Zone ID"
    exit 1
fi

OLD_IFS="$IFS"
IFS=','

for sub in $SUB; do
    sub=$(echo "$sub" | xargs)
    [ -n "$sub" ] && update_record "${sub}.${DOMAIN}"
done

IFS="$OLD_IFS"
log "========================================="
log "✨ 完成"
log "========================================="
EOFCF
    chmod +x /usr/local/bin/cf-ddns.sh
fi

# ==========================================
# 配置开机自启
# ==========================================

setup_autostart() {
    case "$SYS_TYPE" in
        openwrt)
            echo "🔧 配置 OpenWrt 开机自启..."
            
            cat > /etc/init.d/cf-ddns << 'EOF'
#!/bin/sh /etc/rc.common
START=99
start() {
    sleep 30
    /usr/local/bin/cf-ddns.sh >> /var/log/cf-ddns.log 2>&1
}
EOF
            chmod +x /etc/init.d/cf-ddns
            /etc/init.d/cf-ddns enable
            
            cat > /etc/hotplug.d/iface/99-ddns << 'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || [ "$ACTION" = "update" ] || exit 0
sleep 30
/usr/local/bin/cf-ddns.sh >> /var/log/cf-ddns.log 2>&1
EOF
            chmod +x /etc/hotplug.d/iface/99-ddns
            ;;
            
        debian|alpine|generic)
            echo "🔧 配置 Systemd 开机自启..."
            
            cat > /etc/systemd/system/cf-ddns.service << 'EOF'
[Unit]
Description=Cloudflare DDNS Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/cf-ddns.env
ExecStart=/usr/local/bin/cf-ddns.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

            cat > /etc/systemd/system/cf-ddns.timer << 'EOF'
[Unit]
Description=Cloudflare DDNS Timer
Requires=cf-ddns.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
EOF

            systemctl daemon-reload
            systemctl enable cf-ddns.timer
            systemctl start cf-ddns.timer
            ;;
    esac
}

setup_autostart

# ==========================================
# 立即执行测试
# ==========================================

echo "========================================="
echo "🚀 立即执行测试..."
echo "========================================="

/usr/local/bin/cf-ddns.sh

echo "========================================="
echo "✅ 安装完成！"
echo "========================================="
echo "📌 系统: $SYS_TYPE"
echo "📌 配置文件: /etc/cf-ddns.env"
echo "📌 脚本路径: /usr/local/bin/cf-ddns.sh"
echo "📌 日志文件: /var/log/cf-ddns.log"
echo ""
echo "📌 修改配置: nano /etc/cf-ddns.env"
echo "📌 手动执行: /usr/local/bin/cf-ddns.sh"
echo "📌 查看日志: tail -f /var/log/cf-ddns.log"
if [ "$SYS_TYPE" = "openwrt" ]; then
    echo "📌 状态: /etc/init.d/cf-ddns status"
else
    echo "📌 定时器: systemctl status cf-ddns.timer"
    echo "📌 查看定时器: systemctl list-timers | grep cf-ddns"
fi
echo "========================================="