#!/bin/sh
set -e

# 参数检查
[ -z "$CF_KEY" ] && echo "❌ CF_KEY 不能为空" && exit 1
[ -z "$DOMAIN" ] && echo "❌ DOMAIN 不能为空" && exit 1
[ -z "$SUB" ] && echo "❌ SUB 不能为空" && exit 1

PROXY=$( [ "$CF_PROXY" = "1" ] && echo true || echo false )
TTL=$( [ -z "$CF_TTL" ] || [ "$CF_TTL" = "auto" ]; echo ${CF_TTL:+$CF_TTL} | grep -q "auto" && echo 1 || echo $CF_TTL )

# ========== 强制 IPv6 模式 ==========
FORCE_IPV6="${FORCE_IPV6:-0}"
if [ "$FORCE_IPV6" = "1" ]; then
    echo "🔒 强制使用 IPv6 模式"
    
    # 方法1：从所有接口获取公网 IPv6（通用）
    IPV6=$(ip -6 addr show | grep 'inet6' | grep -v 'fe80' | grep -v 'fd' | grep -v 'fc' | grep -v '::1' | head -1 | awk '{print $2}' | cut -d/ -f1)
    
    # 方法2：如果本地没有，尝试外部服务
    if [ -z "$IPV6" ]; then
        echo "  ⚠️ 本地获取失败，尝试外部服务..."
        IPV6=$(curl -s --connect-timeout 3 -6 ip.sb 2>/dev/null | grep -Eo '([a-f0-9:]+:+)+[a-f0-9]+' | head -1)
    fi
    
    # 检查是否获取到有效的公网 IPv6
    if [ -n "$IPV6" ] && ! echo "$IPV6" | grep -qiE '^(fc|fd|fe80|100:)'; then
        IP="$IPV6"
        TYPE="AAAA"
        echo "✅ 获取到 IPv6: $IP"
    else
        echo "❌ 无法获取公网 IPv6"
        exit 1
    fi
    SKIP_AUTO=1
fi

# ========== 手动指定 IP ==========
MANUAL_IP="$IP"

if [ -n "$MANUAL_IP" ] && [ "$FORCE_IPV6" != "1" ]; then
    echo "📝 使用手动指定的 IP: $MANUAL_IP"
    IP="$MANUAL_IP"
    
    if echo "$IP" | grep -q ':'; then
        TYPE="AAAA"
        IP_VER="IPv6"
    else
        TYPE="A"
        IP_VER="IPv4"
    fi
    echo "✅ 已设置为 $IP_VER 记录 ($TYPE)"
elif [ -z "$SKIP_AUTO" ]; then
    # ========== 自动获取 IP（兼容所有系统） ==========
    echo "🌐 获取真实公网 IP..."
    IPV4=""
    IPV6=""

    # IPv4 检测（优先外部服务，最可靠）
    for SERVICE in "ipv4.ip.sb" "v4.ident.me" "api.ipify.org"; do
        TEMP_IP=$(curl -s --connect-timeout 3 -4 "$SERVICE" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        if [ -n "$TEMP_IP" ] && ! echo "$TEMP_IP" | grep -qE '^(100\.|172\.16\.|10\.|192\.168\.)'; then
            IPV4="$TEMP_IP"
            echo "  ✅ IPv4 (外部): $IPV4"
            break
        fi
    done

    # 如果外部服务失败，尝试从本地接口获取 IPv4
    if [ -z "$IPV4" ]; then
        # 获取所有非 lo 接口的 IPv4
        for IFACE in $(ip -4 addr show | grep -E '^[0-9]+:' | awk -F: '{print $2}' | tr -d ' ' | grep -v 'lo'); do
            TEMP_IP=$(ip -4 addr show dev "$IFACE" 2>/dev/null | grep 'inet' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1)
            if [ -n "$TEMP_IP" ] && ! echo "$TEMP_IP" | grep -qE '^(100\.|172\.16\.|10\.|192\.168\.)'; then
                IPV4="$TEMP_IP"
                echo "  ✅ IPv4 (本地 $IFACE): $IPV4"
                break
            fi
        done
    fi

    # IPv6 检测（从所有接口获取）
    if [ -z "$IPV4" ]; then
        # 获取所有非 lo 接口的公网 IPv6
        for IFACE in $(ip -6 addr show | grep -E '^[0-9]+:' | awk -F: '{print $2}' | tr -d ' ' | grep -v 'lo'); do
            TEMP_IP=$(ip -6 addr show dev "$IFACE" 2>/dev/null | grep 'inet6' | grep -v 'fe80' | grep -v 'fd' | grep -v 'fc' | grep -v '::1' | awk '{print $2}' | cut -d/ -f1 | head -1)
            if [ -n "$TEMP_IP" ] && ! echo "$TEMP_IP" | grep -qiE '^(fc|fd|fe80|100:)'; then
                IPV6="$TEMP_IP"
                echo "  ✅ IPv6 (本地 $IFACE): $IPV6"
                break
            fi
        done
        
        # 如果本地没有，尝试外部服务
        if [ -z "$IPV6" ]; then
            IPV6=$(curl -s --connect-timeout 3 -6 ip.sb 2>/dev/null | grep -Eo '([a-f0-9:]+:+)+[a-f0-9]+' | head -1)
            if [ -n "$IPV6" ]; then
                echo "  ✅ IPv6 (外部): $IPV6"
            fi
        fi
    fi

    # 最终判断
    if [ -n "$IPV4" ]; then
        IP="$IPV4"
        TYPE="A"
        echo "📝 使用 IPv4: $IP"
    elif [ -n "$IPV6" ]; then
        IP="$IPV6"
        TYPE="AAAA"
        echo "📝 使用 IPv6: $IP"
    else
        echo "❌ 无法获取公网 IP"
        exit 1
    fi
fi

# ========== 获取 Zone ID ==========
get_zone_id() {
    curl -s "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
        -H "Authorization: Bearer $CF_KEY" \
        -H "Content-Type: application/json" | \
        grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//'
}

ZONE_ID=$(get_zone_id)
[ -z "$ZONE_ID" ] && echo "❌ 无法获取 Zone ID" && exit 1

# ========== 更新 DNS 记录 ==========
update_record() {
    local full_domain="$1"
    echo "🔄 处理: $full_domain"
    
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
        echo "✅ $full_domain -> $IP"
    else
        ERR=$(echo "$RES" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"//')
        echo "❌ $full_domain: $ERR"
    fi
    sleep 1
}

# ========== 主执行 ==========
echo "========================================="
echo "🚀 Cloudflare DDNS 更新"
echo "========================================="

OLD_IFS="$IFS"
IFS=','

for sub in $SUB; do
    sub=$(echo "$sub" | xargs)
    [ -n "$sub" ] && update_record "${sub}.${DOMAIN}"
done

IFS="$OLD_IFS"
echo "========================================="
echo "✨ 完成"
echo "========================================="