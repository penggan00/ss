#!/bin/sh
set -e

# 参数检查
[ -z "$CF_KEY" ] && echo "❌ CF_KEY 不能为空" && exit 1
[ -z "$DOMAIN" ] && echo "❌ DOMAIN 不能为空" && exit 1
[ -z "$SUB" ] && echo "❌ SUB 不能为空" && exit 1

PROXY=$( [ "$CF_PROXY" = "1" ] && echo true || echo false )
TTL=$( [ -z "$CF_TTL" ] || [ "$CF_TTL" = "auto" ]; echo ${CF_TTL:+$CF_TTL} | grep -q "auto" && echo 1 || echo $CF_TTL )

# ========== IP获取逻辑 ==========
echo "🌐 获取真实公网 IP..."

IPV4=""
IPV6=""

# 检测 IPv4（跳过私有和WARP）
if [ -z "$FORCE_IPV6" ]; then
    echo "  检测 IPv4..."
    for SERVICE in "ipv4.ip.sb" "v4.ident.me" "api.ipify.org"; do
        TEMP_IP=$(curl -s --connect-timeout 3 -4 "$SERVICE" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        if [ -n "$TEMP_IP" ] && ! echo "$TEMP_IP" | grep -qE '^(100\.|172\.16\.|10\.|192\.168\.)'; then
            IPV4="$TEMP_IP"
            echo "  ✅ IPv4: $IPV4"
            break
        fi
    done
fi

# 检测 IPv6（跳过私有）
if [ -z "$FORCE_IPV4" ]; then
    echo "  检测 IPv6..."
    IPV6=$(curl -s --connect-timeout 3 -6 ip.sb 2>/dev/null | grep -Eo '([a-f0-9:]+:+)+[a-f0-9]+' | head -1)
    if [ -n "$IPV6" ] && ! echo "$IPV6" | grep -qiE '^(fc|fd|fe80|100:)'; then
        echo "  ✅ IPv6: $IPV6"
    else
        IPV6=""
    fi
fi

# 检查是否至少有一个IP
if [ -z "$IPV4" ] && [ -z "$IPV6" ]; then
    echo "❌ 无法获取任何公网 IP"
    exit 1
fi

echo "📝 获取到的IP: IPv4=${IPV4:-无}, IPv6=${IPV6:-无}"

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
    local ip_addr="$2"
    local record_type="$3"
    
    echo "🔄 处理: $full_domain ($record_type -> $ip_addr)"
    
    # 获取现有记录ID
    RECORD_RESPONSE=$(curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$record_type&name=$full_domain" \
        -H "Authorization: Bearer $CF_KEY" \
        -H "Content-Type: application/json")
    
    RECORD_ID=$(echo "$RECORD_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')
    DATA="{\"type\":\"$record_type\",\"name\":\"$full_domain\",\"content\":\"$ip_addr\",\"ttl\":$TTL,\"proxied\":$PROXY}"
    
    if [ -n "$RECORD_ID" ]; then
        # 更新现有记录
        RES=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
            -H "Authorization: Bearer $CF_KEY" \
            -H "Content-Type: application/json" \
            -d "$DATA")
    else
        # 创建新记录
        RES=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
            -H "Authorization: Bearer $CF_KEY" \
            -H "Content-Type: application/json" \
            -d "$DATA")
    fi
    
    if echo "$RES" | grep -q '"success":true'; then
        echo "  ✅ $full_domain ($record_type) -> $ip_addr"
    else
        ERR=$(echo "$RES" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"//')
        echo "  ❌ $full_domain ($record_type): $ERR"
    fi
    sleep 1  # 避免 API 限流
}

# ========== 主执行 ==========
echo "========================================="
echo "🚀 Cloudflare DDNS 更新 (IPv4 + IPv6)"
echo "========================================="

OLD_IFS="$IFS"
IFS=','

for sub in $SUB; do
    sub=$(echo "$sub" | xargs)
    [ -z "$sub" ] && continue
    
    full_domain="${sub}.${DOMAIN}"
    
    # 更新 IPv4 记录（如果存在）
    if [ -n "$IPV4" ]; then
        update_record "$full_domain" "$IPV4" "A"
    fi
    
    # 更新 IPv6 记录（如果存在）
    if [ -n "$IPV6" ]; then
        update_record "$full_domain" "$IPV6" "AAAA"
    fi
done

IFS="$OLD_IFS"
echo "========================================="
echo "✨ 完成"
echo "========================================="