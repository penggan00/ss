#!/bin/sh
set -e

# ==========================================
# 🧠 智能系统识别与适配
# ==========================================

# 检测系统类型
detect_system() {
    # 检测 OpenWrt
    if [ -f /etc/openwrt_release ]; then
        echo "openwrt"
        return
    fi
    
    # 检测 Debian/Ubuntu
    if [ -f /etc/debian_version ]; then
        echo "debian"
        return
    fi
    
    # 检测 Alpine
    if [ -f /etc/alpine-release ]; then
        echo "alpine"
        return
    fi
    
    # 检测 Fedora/RHEL
    if [ -f /etc/redhat-release ]; then
        echo "redhat"
        return
    fi
    
    # 检测 Arch
    if [ -f /etc/arch-release ]; then
        echo "arch"
        return
    fi
    
    # 默认使用通用模式
    echo "generic"
}

# 获取系统类型
SYS_TYPE=$(detect_system)

# ==========================================
# 📝 日志配置
# ==========================================

# 日志函数
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    
    # 根据系统类型选择日志位置
    case "$SYS_TYPE" in
        openwrt)
            echo "$msg" >> /var/log/cf-ddns.log 2>/dev/null || true
            ;;
        debian|alpine|redhat|arch|generic)
            echo "$msg" >> /var/log/cf-ddns.log 2>/dev/null || true
            # 同时输出到 systemd journal（如果存在）
            if command -v logger >/dev/null 2>&1; then
                logger -t cf-ddns "$msg"
            fi
            ;;
    esac
}

# ==========================================
# 🔧 加载环境变量
# ==========================================

# 尝试多个可能的配置文件位置
load_env() {
    local env_files="/etc/cf-ddns.env ./cf-ddns.env /etc/config/cf-ddns"
    
    for env_file in $env_files; do
        if [ -f "$env_file" ]; then
            log "📂 加载配置: $env_file"
            set -a
            . "$env_file"
            set +a
            return 0
        fi
    done
    
    # 如果没有配置文件，尝试从环境变量读取
    if [ -n "$CF_KEY" ] && [ -n "$DOMAIN" ] && [ -n "$SUB" ]; then
        log "📂 使用环境变量配置"
        return 0
    fi
    
    log "❌ 未找到配置文件或环境变量"
    return 1
}

load_env || exit 1

# ==========================================
# ✅ 参数验证
# ==========================================

[ -z "$CF_KEY" ] && log "❌ CF_KEY 不能为空" && exit 1
[ -z "$DOMAIN" ] && log "❌ DOMAIN 不能为空" && exit 1
[ -z "$SUB" ] && log "❌ SUB 不能为空" && exit 1

PROXY=$( [ "$CF_PROXY" = "1" ] && echo true || echo false )
TTL=${CF_TTL:-60}

# ==========================================
# 🌐 获取 IP 函数（系统适配）
# ==========================================

# 获取接口列表（适配不同系统）
get_interfaces() {
    case "$SYS_TYPE" in
        openwrt)
            # OpenWrt 优先使用 pppoe-wan 和 wan
            echo "pppoe-wan wan"
            # 再添加其他接口
            ip link show | grep -o '^[0-9]\+: \([^:]\+\)' | awk '{print $2}' | grep -v lo || true
            ;;
        debian|alpine|redhat|arch|generic)
            # Debian 等系统使用 eth0, ens3, enp* 等
            ip link show | grep -o '^[0-9]\+: \([^:]\+\)' | awk '{print $2}' | grep -E '^(eth|ens|enp|eno|enx|en)' || true
            ;;
    esac
}

# 获取 IPv6（适配不同系统）
get_ipv6_from_interface() {
    local iface="$1"
    
    case "$SYS_TYPE" in
        openwrt)
            # OpenWrt 的 ip 命令输出格式略有不同
            ip -6 addr show dev "$iface" 2>/dev/null | \
                grep 'inet6' | \
                grep -v 'fe80' | \
                grep -v 'fd' | \
                grep -v 'fc' | \
                grep -v '::1' | \
                head -1 | \
                awk '{print $2}' | \
                cut -d/ -f1
            ;;
        *)
            # 通用系统
            ip -6 addr show dev "$iface" 2>/dev/null | \
                grep 'inet6' | \
                grep -v 'fe80' | \
                grep -v 'fd' | \
                grep -v 'fc' | \
                grep -v '::1' | \
                head -1 | \
                awk '{print $2}' | \
                cut -d/ -f1
            ;;
    esac
}

# 获取 IPv4（适配不同系统）
get_ipv4_from_interface() {
    local iface="$1"
    
    ip -4 addr show dev "$iface" 2>/dev/null | \
        grep 'inet' | \
        grep -v '127.0.0.1' | \
        head -1 | \
        awk '{print $2}' | \
        cut -d/ -f1
}

# ==========================================
# 🔍 获取公网 IP
# ==========================================

FORCE_IPV6="${FORCE_IPV6:-0}"

# 检查是否为公网 IPv6
is_public_ipv6() {
    local ip="$1"
    [ -n "$ip" ] && ! echo "$ip" | grep -qiE '^(fc|fd|fe80|100:|::1)'
}

# 检查是否为公网 IPv4
is_public_ipv4() {
    local ip="$1"
    [ -n "$ip" ] && ! echo "$ip" | grep -qE '^(100\.|172\.16\.|10\.|192\.168\.|127\.)'
}

if [ "$FORCE_IPV6" = "1" ]; then
    log "🔒 强制使用 IPv6 模式 ($SYS_TYPE)"
    IPV6=""
    
    # 从各个接口获取 IPv6
    for iface in $(get_interfaces); do
        if [ -n "$iface" ]; then
            IPV6=$(get_ipv6_from_interface "$iface")
            if is_public_ipv6 "$IPV6"; then
                log "  ✅ 从 $iface 获取到 IPv6: $IPV6"
                break
            fi
        fi
    done
    
    # 如果本地获取失败，尝试外部服务
    if [ -z "$IPV6" ] || ! is_public_ipv6 "$IPV6"; then
        log "  ⚠️ 本地获取失败，尝试外部服务..."
        # 尝试多个 IPv6 检测服务
        for SERVICE in "ip.sb" "v6.ident.me" "api6.ipify.org"; do
            TEMP_IP=$(curl -s --connect-timeout 5 -6 "$SERVICE" 2>/dev/null | \
                grep -Eo '([a-f0-9:]+:+)+[a-f0-9]+' | head -1)
            if is_public_ipv6 "$TEMP_IP"; then
                IPV6="$TEMP_IP"
                log "  ✅ 从 $SERVICE 获取到 IPv6: $IPV6"
                break
            fi
        done
    fi
    
    if is_public_ipv6 "$IPV6"; then
        IP="$IPV6"
        TYPE="AAAA"
        log "✅ 最终使用 IPv6: $IP"
    else
        log "❌ 无法获取公网 IPv6"
        exit 1
    fi
    SKIP_AUTO=1
fi

# ==========================================
# 📝 手动指定 IP
# ==========================================

MANUAL_IP="$IP"
if [ -n "$MANUAL_IP" ] && [ "$FORCE_IPV6" != "1" ]; then
    log "📝 使用手动指定的 IP: $MANUAL_IP"
    IP="$MANUAL_IP"
    
    if echo "$IP" | grep -q ':'; then
        TYPE="AAAA"
        IP_VER="IPv6"
    else
        TYPE="A"
        IP_VER="IPv4"
    fi
    log "✅ 已设置为 $IP_VER 记录 ($TYPE)"
elif [ -z "$SKIP_AUTO" ]; then
    log "🌐 获取真实公网 IP ($SYS_TYPE)"
    IPV4=""
    IPV6=""
    
    # IPv4 检测
    for SERVICE in "ipv4.ip.sb" "v4.ident.me" "api.ipify.org"; do
        TEMP_IP=$(curl -s --connect-timeout 5 -4 "$SERVICE" 2>/dev/null | \
            grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        if is_public_ipv4 "$TEMP_IP"; then
            IPV4="$TEMP_IP"
            log "  ✅ IPv4: $IPV4"
            break
        fi
    done
    
    if [ -z "$IPV4" ]; then
        # IPv6 检测
        for iface in $(get_interfaces); do
            if [ -n "$iface" ]; then
                IPV6=$(get_ipv6_from_interface "$iface")
                if is_public_ipv6 "$IPV6"; then
                    log "  ✅ 从 $iface 获取到 IPv6: $IPV6"
                    break
                fi
            fi
        done
        
        # 如果还是失败，尝试外部服务
        if [ -z "$IPV6" ] || ! is_public_ipv6 "$IPV6"; then
            TEMP_IP=$(curl -s --connect-timeout 5 -6 ip.sb 2>/dev/null | \
                grep -Eo '([a-f0-9:]+:+)+[a-f0-9]+' | head -1)
            if is_public_ipv6 "$TEMP_IP"; then
                IPV6="$TEMP_IP"
                log "  ✅ 从外部服务获取到 IPv6: $IPV6"
            fi
        fi
        
        if [ -z "$IPV4" ] && [ -z "$IPV6" ]; then
            log "  ❌ 无法获取公网 IP"
            exit 1
        fi
    fi
    
    IP="${IPV4:-$IPV6}"
    TYPE="A"
    [ -z "$IPV4" ] && TYPE="AAAA"
    log "📝 使用自动获取的 ${TYPE}: $IP"
fi

# ==========================================
# ☁️ Cloudflare API 操作
# ==========================================

get_zone_id() {
    curl -s "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
        -H "Authorization: Bearer $CF_KEY" \
        -H "Content-Type: application/json" | \
        grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//'
}

update_record() {
    local full_domain="$1"
    log "🔄 处理: $full_domain"
    
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
# 🚀 主执行
# ==========================================

log "========================================="
log "🚀 Cloudflare DDNS 更新"
log "📌 系统: $SYS_TYPE"
log "📌 配置: ${SUB}.${DOMAIN} -> $IP (${TYPE})"
log "========================================="

# 获取 Zone ID
ZONE_ID=$(get_zone_id)
if [ -z "$ZONE_ID" ]; then
    log "❌ 无法获取 Zone ID"
    exit 1
fi

# 更新 DNS 记录
OLD_IFS="$IFS"
IFS=','

for sub in $SUB; do
    sub=$(echo "$sub" | xargs)
    if [ -n "$sub" ]; then
        update_record "${sub}.${DOMAIN}"
    fi
done

IFS="$OLD_IFS"
log "========================================="
log "✨ 完成"
log "========================================="