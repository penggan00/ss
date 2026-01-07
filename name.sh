#!/bin/bash

if [ -z "$1" ]; then
    echo "错误：请提供新的主机名作为参数"
    echo "使用方法: $0 新主机名"
    echo "示例: $0 hk100"
    echo "或者从GitHub: bash <(curl -sL URL) hk100"
    exit 1
fi

NEW_HOSTNAME="$1"

# 验证主机名格式（基本检查）
if ! [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]]; then
    echo "错误：主机名格式无效"
    echo "规则：只能包含字母、数字和连字符，不能以连字符开头"
    exit 1
fi

# 1. 设置主机名
sudo hostnamectl set-hostname "$NEW_HOSTNAME"

# 3. 智能网络检测和更新
IPV4_EXIST=$(ip -4 addr show 2>/dev/null | grep -q "inet " && echo "yes" || echo "no")
IPV6_EXIST=$(ip -6 addr show 2>/dev/null | grep -q "inet6 " && echo "yes" || echo "no")

echo "检测到网络配置：IPv4[$IPV4_EXIST] IPv6[$IPV6_EXIST]"

# 更新127.0.0.1（总是执行）
sudo sed -i "/^127.0.0.1.*localhost/ s/localhost/& $NEW_HOSTNAME/" /etc/hosts

# 条件更新127.0.1.1（仅IPv4）
if [ "$IPV4_EXIST" = "yes" ]; then
    if grep -q "^127.0.1.1" /etc/hosts; then
        sudo sed -i "s/^127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
    else
        echo -e "127.0.1.1\t$NEW_HOSTNAME" | sudo tee -a /etc/hosts
    fi
fi

# 条件更新::1（仅IPv6）
if [ "$IPV6_EXIST" = "yes" ]; then
    if grep -q "^::1.*localhost" /etc/hosts; then
        sudo sed -i "/^::1.*localhost/ s/localhost/& $NEW_HOSTNAME/" /etc/hosts
    else
        echo -e "::1\tlocalhost ip6-localhost ip6-loopback $NEW_HOSTNAME" | sudo tee -a /etc/hosts
    fi
fi

# 4. 输出结果
echo "========================================"
echo "✅ 主机名修改完成"
echo "原主机名: $OLD_HOSTNAME"
echo "新主机名: $NEW_HOSTNAME"
echo "网络类型: $([ "$IPV4_EXIST" = "yes" ] && echo -n "IPv4 ") $([ "$IPV6_EXIST" = "yes" ] && echo -n "IPv6")"
echo ""
echo "hosts文件修改摘要:"
grep -E "(127.0.0.1|127.0.1.1|::1)" /etc/hosts
echo ""
echo "💡 提示：请重新SSH登录或运行 'exec bash' 使提示符生效"
echo "========================================"