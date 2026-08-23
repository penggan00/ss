#!/bin/bash
# ============================================================
# Cloudflare DDNS 更新脚本
# 用法：
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/你的用户名/仓库名/main/cf_ddns.sh)" -d www.com -t 你的Token -s tv -i 2001:...
# ============================================================

# ---------- 默认配置 ----------
DOMAIN=""
SUB_DOMAIN=""
IP=""
CF_TOKEN=""
ZONE_ID=""  # 建议填入或通过环境变量传递
PROXIED="false"
TTL="1"
# =============================

# 显示帮助信息
show_help() {
    echo "Cloudflare DDNS 更新脚本"
    echo ""
    echo "用法："
    echo "  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/你的用户名/仓库名/main/cf_ddns.sh)\" [选项]"
    echo ""
    echo "选项："
    echo "  -d, --domain   主域名 (例如: www.com)"
    echo "  -s, --sub      子域名前缀 (例如: tv，将更新 tv.www.com)"
    echo "  -i, --ip       IP 地址 (IPv4 或 IPv6)"
    echo "  -t, --token    Cloudflare API Token"
    echo "  -z, --zone     Cloudflare Zone ID (可选，建议通过环境变量设置)"
    echo "  -p, --proxied  是否开启代理 (true/false, 默认: false)"
    echo "  --ttl          TTL 值 (默认: 1 自动)"
    echo "  -h, --help     显示帮助信息"
    echo ""
    echo "示例："
    echo "  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/你的用户名/仓库名/main/cf_ddns.sh)\" -d www.com -s tv -i 1.2.3.4 -t your_token"
    echo "  bash -c \"\$(curl -fsSL ...)\" --domain www.com --sub tv --ip 2001:db8::1 --token your_token"
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--domain)
                DOMAIN="$2"
                shift 2
                ;;
            -s|--sub)
                SUB_DOMAIN="$2"
                shift 2
                ;;
            -i|--ip)
                IP="$2"
                shift 2
                ;;
            -t|--token)
                CF_TOKEN="$2"
                shift 2
                ;;
            -z|--zone)
                ZONE_ID="$2"
                shift 2
                ;;
            -p|--proxied)
                PROXIED="$2"
                shift 2
                ;;
            --ttl)
                TTL="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                # 支持无选项标记的旧式传参：依次为 邮箱 域名 Token (兼容ssl.sh风格)
                if [[ -z "$DOMAIN" ]]; then
                    DOMAIN="$1"
                elif [[ -z "$CF_TOKEN" ]]; then
                    CF_TOKEN="$1"
                fi
                shift
                ;;
        esac
    done
}

# 检查必需参数
check_params() {
    if [[ -z "$DOMAIN" ]]; then
        read -p "请输入主域名 (例如: www.com): " DOMAIN
    fi
    if [[ -z "$CF_TOKEN" ]]; then
        read -p "请输入 Cloudflare API Token: " CF_TOKEN
    fi
    if [[ -z "$IP" ]]; then
        # 尝试自动获取公网 IP
        echo "未指定 IP，尝试自动获取..."
        IP=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -6 ifconfig.me 2>/dev/null)
        if [[ -z "$IP" ]]; then
            read -p "请输入 IP 地址: " IP
        else
            echo "自动获取到 IP: $IP"
        fi
    fi
    # 如果未指定子域名，默认使用 'ddns'
    if [[ -z "$SUB_DOMAIN" ]]; then
        SUB_DOMAIN="ddns"
    fi
    # 构建完整域名
    FULL_DOMAIN="${SUB_DOMAIN}.${DOMAIN}"
}

# 判断 IP 类型
detect_type() {
    case "$IP" in
        *:*) TYPE="AAAA" ;;
        *) TYPE="A" ;;
    esac
}

# 更新 DNS 记录
update_dns() {
    # 查询记录 ID
    RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$FULL_DOMAIN&type=$TYPE" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" | \
        awk -F'"' '/"id"/ {print $4; exit}')

    if [ -n "$RECORD_ID" ]; then
        echo "🔄 更新 $FULL_DOMAIN -> $IP"
        RESULT=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
            -H "Authorization: Bearer $CF_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"$TYPE\",\"name\":\"$FULL_DOMAIN\",\"content\":\"$IP\",\"ttl\":$TTL,\"proxied\":$PROXIED}")
        
        if echo "$RESULT" | grep -q '"success":true'; then
            echo "✅ 更新成功"
        else
            echo "❌ 更新失败: $RESULT"
            exit 1
        fi
    else
        echo "➕ 新增 $FULL_DOMAIN -> $IP"
        RESULT=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
            -H "Authorization: Bearer $CF_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"$TYPE\",\"name\":\"$FULL_DOMAIN\",\"content\":\"$IP\",\"ttl\":$TTL,\"proxied\":$PROXIED}")
        
        if echo "$RESULT" | grep -q '"success":true'; then
            echo "✅ 新增成功"
        else
            echo "❌ 新增失败: $RESULT"
            exit 1
        fi
    fi
}

# ---------- 主程序 ----------
parse_args "$@"
check_params
detect_type

# 检查 Zone ID（优先使用参数，其次环境变量，最后尝试自动获取）
if [[ -z "$ZONE_ID" ]]; then
    ZONE_ID="${CF_ZONE_ID:-}"
fi

if [[ -z "$ZONE_ID" ]]; then
    echo "⚠️  未指定 Zone ID，尝试通过 API 自动获取..."
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" | \
        awk -F'"' '/"id"/ {print $4; exit}')
    if [[ -z "$ZONE_ID" ]]; then
        echo "❌ 无法自动获取 Zone ID，请通过 -z 参数或环境变量 CF_ZONE_ID 指定"
        exit 1
    else
        echo "✅ 自动获取到 Zone ID: $ZONE_ID"
    fi
fi

update_dns