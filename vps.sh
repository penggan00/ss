#!/bin/bash
set -e

if [ $# -eq 0 ]; then
    echo "❌ 错误：请提供 SSH 公钥作为参数"
    echo ""
    echo '用法：'
    echo 'bash <(curl -sL https://raw.githubusercontent.com/penggan00/ss/main/vps.sh) "公钥内容"'
    exit 1
fi

SSH_PUBKEY="$1"

if [ -z "$SSH_PUBKEY" ]; then
    echo "❌ SSH 公钥不能为空"
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
    echo "❌ 请使用 root 用户运行此脚本"
    exit 1
fi

echo ""
echo "========================================="
echo "🔐 SSH 服务器初始化"
echo "========================================="

if [ ! -f /etc/os-release ]; then
    echo "❌ 无法检测系统类型"
    exit 1
fi

. /etc/os-release

case "$ID" in
    alpine)
        OS_TYPE="alpine"
        echo "✅ 检测到系统：Alpine Linux"
        ;;
    debian)
        OS_TYPE="debian"
        echo "✅ 检测到系统：Debian"
        ;;
    ubuntu)
        OS_TYPE="ubuntu"
        echo "✅ 检测到系统：Ubuntu"
        ;;
    *)
        echo "❌ 不支持的系统：$ID"
        exit 1
        ;;
esac

install_openssh() {
    echo ""
    echo "========================================="
    echo "📦 检查 OpenSSH"
    echo "========================================="

    if command -v sshd >/dev/null 2>&1; then
        echo "✅ sshd 已安装"
    else
        echo "📦 正在安装 OpenSSH..."

        if [ "$OS_TYPE" = "alpine" ]; then
            apk update
            apk add --no-cache openssh
        else
            apt-get update
            apt-get install -y openssh-server
        fi

        echo "✅ OpenSSH 安装完成"
    fi
}

setup_ssh_keys() {
    echo ""
    echo "========================================="
    echo "🔑 配置 SSH 公钥"
    echo "========================================="

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    printf '%s\n' "$SSH_PUBKEY" > /root/.ssh/authorized_keys

    chmod 600 /root/.ssh/authorized_keys
    chown -R root:root /root/.ssh

    echo "✅ 公钥已写入："
    echo "/root/.ssh/authorized_keys"
}

prepare_ssh_config() {
    echo ""
    echo "========================================="
    echo "🔧 准备 SSH 配置目录"
    echo "========================================="

    mkdir -p /etc/ssh/sshd_config.d
    chmod 755 /etc/ssh/sshd_config.d

    if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
        echo "✅ sshd_config 已包含 sshd_config.d"
    else
        echo "➕ 添加 Include..."

        tmp_file="$(mktemp)"

        {
            echo "Include /etc/ssh/sshd_config.d/*.conf"
            cat /etc/ssh/sshd_config
        } > "$tmp_file"

        cat "$tmp_file" > /etc/ssh/sshd_config
        rm -f "$tmp_file"

        echo "✅ Include 已添加"
    fi
}

clean_ssh_config() {
    echo ""
    echo "========================================="
    echo "🧹 清理冲突 SSH 配置"
    echo "========================================="

    sed -i -E '/^[[:space:]]*Port[[:space:]]+(22|222)[[:space:]]*$/d' /etc/ssh/sshd_config

    sed -i -E '/^[[:space:]]*(PasswordAuthentication|PubkeyAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitRootLogin|AuthorizedKeysFile)[[:space:]]+/d' /etc/ssh/sshd_config

    rm -f /etc/ssh/sshd_config.d/99-custom.conf

    echo "✅ 冲突配置已清理"
}

write_ssh_config() {
    echo ""
    echo "========================================="
    echo "📝 写入 SSH 配置"
    echo "========================================="

    cat > /etc/ssh/sshd_config.d/99-custom.conf <<'EOF'
Port 222
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
AuthorizedKeysFile .ssh/authorized_keys
EOF

    chmod 644 /etc/ssh/sshd_config.d/99-custom.conf

    echo "✅ SSH 配置已写入"
}

check_ssh_syntax() {
    echo ""
    echo "========================================="
    echo "🔍 检查 SSH 配置语法"
    echo "========================================="

    if sshd -t; then
        echo "✅ sshd 配置语法正确"
    else
        echo "❌ SSH 配置存在错误"
        echo "⚠️ 不会重启 SSH"
        exit 1
    fi
}

check_effective_ssh_config() {
    echo ""
    echo "========================================="
    echo "🔍 检查 SSH 实际生效配置"
    echo "========================================="

    EFFECTIVE_CONFIG="$(sshd -T)"

    echo ""
    echo "当前实际配置："

    echo "$EFFECTIVE_CONFIG" | grep -E '^(port|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitrootlogin|authorizedkeysfile)[[:space:]]'

    PORT_COUNT="$(echo "$EFFECTIVE_CONFIG" | grep -Ec '^port[[:space:]]+222$' || true)"

    if [ "$PORT_COUNT" -ne 1 ]; then
        echo "❌ SSH 222 端口配置异常，检测到 $PORT_COUNT 个"
        exit 1
    fi

    echo "✅ SSH 端口：222"

    if echo "$EFFECTIVE_CONFIG" | grep -Eq '^pubkeyauthentication[[:space:]]+yes$'; then
        echo "✅ 公钥认证：开启"
    else
        echo "❌ 公钥认证没有开启"
        exit 1
    fi

    if echo "$EFFECTIVE_CONFIG" | grep -Eq '^passwordauthentication[[:space:]]+no$'; then
        echo "✅ 密码认证：关闭"
    else
        echo "❌ 密码认证没有关闭"
        exit 1
    fi

    if echo "$EFFECTIVE_CONFIG" | grep -Eq '^permitrootlogin[[:space:]]+(prohibit-password|without-password)$'; then
        echo "✅ Root 登录：仅允许密钥"
    else
        echo "❌ Root SSH 登录策略不正确"
        exit 1
    fi

    if echo "$EFFECTIVE_CONFIG" | grep -Eq '^authorizedkeysfile[[:space:]]+\.ssh/authorized_keys$'; then
        echo "✅ authorized_keys：正确"
    else
        echo "❌ authorized_keys 配置不正确"
        exit 1
    fi

    echo ""
    echo "✅ SSH 实际生效配置检查通过"
}

restart_ssh() {
    echo ""
    echo "========================================="
    echo "🔄 重启 SSH 服务"
    echo "========================================="

    if [ "$OS_TYPE" = "alpine" ]; then

        if [ -f /.dockerenv ]; then
            echo "🐳 检测到 Docker 容器"

            mkdir -p /run/openrc
            touch /run/openrc/softlevel

            rc-update add sshd default 2>/dev/null || true

            pkill sshd 2>/dev/null || true

            /usr/sbin/sshd
        else
            rc-service sshd restart 2>/dev/null || rc-service sshd start
            rc-update add sshd default 2>/dev/null || true
        fi

    else

        systemctl enable ssh 2>/dev/null || true
        systemctl enable sshd 2>/dev/null || true

        if systemctl restart ssh 2>/dev/null; then
            :
        elif systemctl restart sshd 2>/dev/null; then
            :
        else
            echo "❌ SSH 服务重启失败"
            exit 1
        fi

    fi

    echo "✅ SSH 服务已重启"
}

check_ssh_port() {
    echo ""
    echo "========================================="
    echo "📡 检查 SSH 监听端口"
    echo "========================================="

    sleep 1

    if command -v ss >/dev/null 2>&1; then

        if ss -lntp 2>/dev/null | grep -Eq '[:.]222[[:space:]]'; then
            echo "✅ SSH 正在监听 222 端口"
            ss -lntp 2>/dev/null | grep -E '[:.]222[[:space:]]' || true
        else
            echo "❌ 没有检测到 222 端口监听"

            if [ "$OS_TYPE" = "alpine" ]; then
                rc-service sshd status 2>/dev/null || true
            else
                systemctl status ssh --no-pager 2>/dev/null || systemctl status sshd --no-pager 2>/dev/null || true
            fi

            exit 1
        fi

    else
        echo "⚠️ 系统没有 ss 命令，跳过端口检查"
    fi
}

install_debian_tools() {
    echo ""
    echo "========================================="
    echo "📦 安装 Debian/Ubuntu 常用工具"
    echo "========================================="

    apt-get update

    apt-get install -y \
        curl \
        wget \
        nano \
        htop \
        git \
        ufw

    echo ""
    echo "✅ 已安装："
    echo "  curl"
    echo "  wget"
    echo "  nano"
    echo "  htop"
    echo "  git"
    echo "  ufw"

    echo ""
    echo "❌ 不安装："
    echo "  fail2ban"
    echo "  BBR"
}

configure_ufw() {
    echo ""
    echo "========================================="
    echo "🔥 配置 UFW"
    echo "========================================="

    ufw allow 222/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp

    echo ""
    echo "当前 UFW 规则："

    ufw status numbered || true

    echo ""
    echo "⚠️ 启用 UFW..."

    ufw --force enable

    echo ""
    echo "✅ UFW 已启用"

    ufw status numbered
}

configure_timezone() {
    echo ""
    echo "========================================="
    echo "🕐 配置系统时间"
    echo "========================================="

    apt-get install -y systemd-timesyncd

    timedatectl set-timezone Asia/Singapore
    timedatectl set-local-rtc 0
    timedatectl set-ntp true

    echo ""
    echo "✅ 时区：Asia/Singapore"
    echo "✅ NTP：已开启"

    echo ""

    timedatectl status
}

configure_docker_alias() {
    echo ""
    echo "========================================="
    echo "🐳 配置 Docker Compose alias"
    echo "========================================="

    BASHRC="/root/.bashrc"

    if [ ! -f "$BASHRC" ]; then
        touch "$BASHRC"
    fi

    if ! grep -Fqx "alias docker-compose='docker compose'" "$BASHRC"; then
        echo "alias docker-compose='docker compose'" >> "$BASHRC"
    fi

    echo "✅ docker-compose alias 已配置"
}

install_openssh
setup_ssh_keys
prepare_ssh_config
clean_ssh_config
write_ssh_config
check_ssh_syntax
check_effective_ssh_config
restart_ssh
check_ssh_port

if [ "$OS_TYPE" = "debian" ] || [ "$OS_TYPE" = "ubuntu" ]; then
    install_debian_tools
    configure_ufw
    configure_timezone
fi

configure_docker_alias

echo ""
echo ""
echo "========================================="
echo "🎉 服务器初始化完成"
echo "========================================="

echo ""
echo "系统：$PRETTY_NAME"

echo ""
echo "🔐 SSH："
echo "  端口：222"
echo "  公钥登录：开启"
echo "  密码登录：关闭"
echo "  Root：仅允许密钥"
echo "  公钥文件：/root/.ssh/authorized_keys"

echo ""

if [ "$OS_TYPE" = "alpine" ]; then
    echo "🐧 Alpine："
    echo "  OpenSSH：已配置"
    echo "  htop：不安装"
    echo "  ufw：不安装"
    echo "  git：不安装"
    echo "  fail2ban：不安装"
    echo "  BBR：不安装"
else
    echo "🐧 Debian/Ubuntu："
    echo "  curl：已安装"
    echo "  wget：已安装"
    echo "  nano：已安装"
    echo "  htop：已安装"
    echo "  git：已安装"
    echo "  ufw：已安装并启用"
    echo "  fail2ban：不安装"
    echo "  BBR：不安装"
    echo "  时区：Asia/Singapore"
    echo "  NTP：已开启"
fi

echo ""
echo "========================================="
echo "⚠️ 重要提示"
echo "========================================="

echo ""
echo "请确认云服务器安全组已经放行："
echo "  TCP 222"

if [ "$OS_TYPE" = "debian" ] || [ "$OS_TYPE" = "ubuntu" ]; then
    echo "  TCP 80"
    echo "  TCP 443"
fi

echo ""
echo "不要关闭当前 SSH 会话！"

echo ""
echo "请打开新的终端测试："

echo ""
echo "ssh -p 222 root@服务器IP"

echo ""
echo "========================================="
echo "✅ 全部完成"
echo "========================================="