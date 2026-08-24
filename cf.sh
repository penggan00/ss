#!/bin/sh
set -e

# 参数检查
[ -z "$CF_KEY" ] && echo "❌ CF_KEY 不能为空" && exit 1
[ -z "$DOMAIN" ] && echo "❌ DOMAIN 不能为空" && exit 1
[ -z "$SUB" ] && echo "❌ SUB 不能为空" && exit 1

PROXY=$( [ "$CF_PROXY" = "1" ] && echo true || echo false )
TTL=$( [ -z "$CF_TTL" ] || [ "$CF_TTL" = "auto" ]; echo ${CF_TTL:+$CF_TTL} | grep -q "auto" && echo 1 || echo $CF_TTL )

# ========== 新增：检查是否手动指定了 IP ==========
MANUAL_IP="$IP"  # 读取环境变量 IP

if [ -n "$MANUAL_IP" ]; then
    # 用户手动指定了 IP，直接使用
    echo "📝 使用手动指定的 IP: $MANUAL_IP"
    IP="$MANUAL_IP"
    
    # 自动判断是 IPv4 还是 IPv6
    if echo "$IP" | grep -q ':'; then
        TYPE="AAAA"
        IP_VER="IPv6"
    else
        TYPE="A"
        IP_VER="IPv4"
    fi
    echo "✅ 已设置为 $IP_VER 记录 ($TYPE)"
else
    # ========== 原有的自动获取 IP 逻辑 ==========
    echo "🌐 获取真实公网 IP..."
    IPV4=""
    IPV6=""

    # IPv4 检测（跳过私有和 WARP）
    for SERVICE in "ipv4.ip.sb" "v4.ident.me" "api.ipify.org"; do
        TEMP_IP=$(curl -s --connect-timeout 3 -4 "$SERVICE" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        if [ -n "$TEMP_IP" ] && ! echo "$TEMP_IP" | grep -qE '^(100\.|172\.16\.|10\.|192\.168\.)'; then
            IPV4="$TEMP_IP"
            echo "  ✅ IPv4: $IPV4"
            break
        fi
    done

    if [ -z "$IPV4" ]; then
        # IPv6 检测（跳过私有）
        IPV6=$(curl -s --connect-timeout 3 -6 ip.sb 2>/dev/null | grep -Eo '([a-f0-9:]+:+)+[a-f0-9]+' | head -1)
        if [ -n "$IPV6" ] && ! echo "$IPV6" | grep -qiE '^(fc|fd|fe80|100:)'; then
            echo "  ✅ IPv6: $IPV6"
        else
            echo "  ❌ 无法获取公网 IP"
            exit 1
        fi
    fi

    IP="${IPV4:-$IPV6}"
    TYPE="A"
    [ -z "$IPV4" ] && TYPE="AAAA"
    echo "📝 使用自动获取的 ${TYPE}: $IP"
fi
# ========== 自动获取 IP 逻辑结束 ==========

# 获取 Zone ID（只获取一次）
get_zone_id() {
    curl -s "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
        -H "Authorization: Bearer $CF_KEY" \
        -H "Content-Type: application/json" | \
        grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//'
}

ZONE_ID=$(get_zone_id)
[ -z "$ZONE_ID" ] && echo "❌ 无法获取 Zone ID" && exit 1

# 更新 DNS 记录
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
    sleep 1  # 避免 API 限流
}

# 主执行
echo "========================================="
echo "🚀 Cloudflare DDNS 更新"
echo "========================================="

# 修复：不使用管道循环，避免子 shell 问题
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