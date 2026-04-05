#!/bin/sh

# 一键 Cloudflare DDNS - 支持主域名变量和子域名列表
# 用法：CF_KEY="token" DOMAIN="2151553.xyz" SUB="aa,bb,cc" CF_PROXY=0 CF_TTL=auto sh -c "$(curl -sL https://xxx.sh)"

set -e

# 参数检查
[ -z "$CF_KEY" ] && echo "❌ CF_KEY 不能为空" && exit 1
[ -z "$DOMAIN" ] && echo "❌ DOMAIN 不能为空" && exit 1
[ -z "$SUB" ] && echo "❌ SUB 不能为空" && exit 1

# 处理 PROXY 参数
PROXY=$( [ "$CF_PROXY" = "1" ] && echo true || echo false )

# 处理 TTL 参数
if [ -z "$CF_TTL" ] || [ "$CF_TTL" = "auto" ]; then
    TTL=1
else
    TTL="$CF_TTL"
fi

# 获取真实公网 IP（优先 IPv4，排除 WARP）
echo "🌐 获取真实公网 IP..."

# 方法1：使用 ip.sb（自动识别，但可能拿到 WARP IP）
# 方法2：使用多个服务商，避免 WARP
IPV4=""
IPV6=""

# 获取真实 IPv4（跳过 Cloudflare WARP）
for SERVICE in "ipv4.ip.sb" "v4.ident.me" "api.ipify.org" "icanhazip.com" "ipv4.icanhazip.com"; do
    TEMP_IP=$(curl -s --connect-timeout 3 -4 "$SERVICE" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    if [ -n "$TEMP_IP" ]; then
        # 检查是否为 Cloudflare WARP IP（WARP IP 段通常以 100. 开头或特定段）
        if echo "$TEMP_IP" | grep -qE '^(100\.|172\.16\.|10\.|192\.168\.)'; then
            echo "  ⚠️  检测到 WARP/VPN IP: $TEMP_IP，尝试其他服务..."
            continue
        fi
        IPV4="$TEMP_IP"
        echo "  ✅ 获取到真实 IPv4: $IPV4"
        break
    fi
done

# 如果没有 IPv4，则获取 IPv6
if [ -z "$IPV4" ]; then
    echo "  ⚠️  未获取到真实 IPv4，尝试获取 IPv6..."
    IPV6=$(curl -s --connect-timeout 3 -6 ip.sb 2>/dev/null | grep -Eo '([a-f0-9:]+:+)+[a-f0-9]+' | head -1)
    if [ -n "$IPV6" ]; then
        echo "  ✅ 获取到 IPv6: $IPV6"
    else
        echo "  ❌ 无法获取任何公网 IP"
        exit 1
    fi
fi

# 决定使用的 IP 和类型
if [ -n "$IPV4" ]; then
    IP="$IPV4"
    TYPE="A"
    IP_VER="IPv4"
else
    IP="$IPV6"
    TYPE="AAAA"
    IP_VER="IPv6"
fi

echo "📝 使用 $IP_VER: $IP"
echo ""

# 获取 Zone ID
get_zone_id() {
    local domain="$1"
    ZONE_RESPONSE=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=$domain" \
        -H "Authorization: Bearer $CF_KEY" \
        -H "Content-Type: application/json")
    
    echo "$ZONE_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//'
}

# 更新 DNS 记录
update_record() {
    local full_domain="$1"
    echo "🔄 处理: $full_domain"
    
    # 获取 Zone ID
    ZONE_ID=$(get_zone_id "$DOMAIN")
    if [ -z "$ZONE_ID" ]; then
        echo "❌ $full_domain: 无法获取 Zone ID"
        echo ""
        return 1
    fi
    
    # 查询现有记录
    RECORD_RESPONSE=$(curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$TYPE&name=$full_domain" \
        -H "Authorization: Bearer $CF_KEY" \
        -H "Content-Type: application/json")
    
    RECORD_ID=$(echo "$RECORD_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')
    
    # 构建请求数据
    DATA="{\"type\":\"$TYPE\",\"name\":\"$full_domain\",\"content\":\"$IP\",\"ttl\":$TTL,\"proxied\":$PROXY}"
    
    # 更新或创建
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
    
    # 检查结果
    if echo "$RES" | grep -q '"success":true'; then
        echo "✅ $full_domain -> $IP"
    else
        ERR=$(echo "$RES" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"//')
        echo "❌ $full_domain: $ERR"
    fi
    echo ""
}

# 主执行
echo "========================================="
echo "🚀 Cloudflare DDNS 更新"
echo "========================================="
echo "📍 主域名: $DOMAIN"
echo "📝 子域名: $SUB"
echo ""

# 遍历子域名
echo "$SUB" | tr ',' '\n' | while read -r sub; do
    sub=$(echo "$sub" | xargs)  # 去除空格
    if [ -n "$sub" ]; then
        full_domain="${sub}.${DOMAIN}"
        update_record "$full_domain"
    fi
done

echo "========================================="
echo "✨ 完成"
echo "========================================="