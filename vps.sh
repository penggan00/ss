#!/bin/bash
set -e

# =========================================================
# SSH 服务器初始化脚本
#
# 支持：
#   Alpine Linux
#   Debian
#   Ubuntu
#
# SSH：
#   端口：222
#   公钥登录：开启
#   密码登录：关闭
#   Root：仅允许密钥
#
# Alpine：
#   openssh
#   Docker Compose alias
#
# Debian / Ubuntu：
#   curl
#   wget
#   nano
#   htop
#   git
#   ufw
#   新加坡时区
#   NTP
#
# 不安装：
#   fail2ban
#   BBR
#
# 使用：
# bash <(curl -sL https://raw.githubusercontent.com/penggan00/penggan00.github.io/main/my-blog/sh/ssh.sh) "你的SSH公钥"
# =========================================================


# =========================================================
# 1. 检查参数
# =========================================================

if [ $# -eq 0 ]; then
    echo "❌ 错误：请提供 SSH 公钥作为参数"
    echo ""
    echo "用法："
    echo 'bash <(curl -sL https://raw.githubusercontent.com/penggan00/penggan00.github.io/main/my-blog/sh/ssh.sh) "公钥内容"'
    exit 1
fi

SSH_PUBKEY="$1"

if [ -z "$SSH_PUBKEY" ]; then
    echo "❌ SSH 公钥不能为空"
    exit 1
fi


# =========================================================
# 2. 必须使用 root
# =========================================================

if [ "$(id -u)" != "0" ]; then
    echo "❌ 请使用 root 用户运行此脚本"
    exit 1
fi


echo ""
echo "========================================="
echo "🔐 SSH 服务器初始化"
echo "========================================="


# =========================================================
# 3. 检测系统
# =========================================================

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


# =========================================================
# 4. 安装 OpenSSH
# =========================================================

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


# =========================================================
# 5. 配置 SSH 公钥
# =========================================================

setup_ssh_keys() {

    echo ""
    echo "========================================="
    echo "🔑 配置 SSH 公钥"
    echo "========================================="

    mkdir -p /root/.ssh

    chmod 700 /root/.ssh

    # 写入公钥
    printf '%s\n' "$SSH_PUBKEY" > /root/.ssh/authorized_keys

    chmod 600 /root/.ssh/authorized_keys

    chown -R root:root /root/.ssh

    echo "✅ 公钥已写入："
    echo "/root/.ssh/authorized_keys"

}


# =========================================================
# 6. 确保 sshd_config.d 可用
# =========================================================

prepare_ssh_config() {

    echo ""
    echo "========================================="
    echo "🔧 准备 SSH 配置目录"
    echo "========================================="

    mkdir -p /etc/ssh/sshd_config.d

    chmod 755 /etc/ssh/sshd_config.d


    # 检查 Include
    if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' \
        /etc/ssh/sshd_config 2>/dev/null; then

        echo "✅ sshd_config 已包含 sshd_config.d"

    else

        echo "➕ 添加 Include..."

        # 添加到 sshd_config 开头
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


# =========================================================
# 7. 清理可能冲突的自定义配置
# =========================================================

clean_custom_ssh_config() {

    echo ""
    echo "========================================="
    echo "🧹 清理旧的自定义 SSH 配置"
    echo "========================================="

    rm -f /etc/ssh/sshd_config.d/99-custom.conf

    echo "✅ 已清理旧配置"

}


# =========================================================
# 8. 写入统一 SSH 配置
# =========================================================

write_ssh_config() {

    echo ""
    echo "========================================="
    echo "📝 写入统一 SSH 配置"
    echo "========================================="

    cat > /etc/ssh/sshd_config.d/99-custom.conf <<'EOF'
# =========================================================
# Custom SSH Configuration
# =========================================================

# SSH 端口
Port 222

# 公钥认证
PubkeyAuthentication yes

# 禁止密码登录
PasswordAuthentication no

# 禁止键盘交互认证
KbdInteractiveAuthentication no

# 禁止 Challenge Response
ChallengeResponseAuthentication no

# Root 仅允许非密码方式登录
PermitRootLogin prohibit-password

# Root 公钥位置
AuthorizedKeysFile .ssh/authorized_keys
EOF

    chmod 644 /etc/ssh/sshd_config.d/99-custom.conf

    echo "✅ SSH 配置已写入："
    echo "/etc/ssh/sshd_config.d/99-custom.conf"

}


# =========================================================
# 9. 检查 SSH 配置语法
# =========================================================

check_ssh_syntax() {

    echo ""
    echo "========================================="
    echo "🔍 检查 SSH 配置语法"
    echo "========================================="

    if sshd -t; then

        echo "✅ sshd 配置语法正确"

    else

        echo ""
        echo "❌ SSH 配置存在错误！"
        echo ""
        echo "⚠️ 为安全起见，不会重启 SSH"
        echo ""

        exit 1

    fi

}


# =========================================================
# 10. 检查实际生效配置
# =========================================================

check_effective_ssh_config() {

    echo ""
    echo "========================================="
    echo "🔍 检查 SSH 实际生效配置"
    echo "========================================="

    EFFECTIVE_CONFIG="$(sshd -T)"


    echo ""
    echo "当前实际配置："

    echo "$EFFECTIVE_CONFIG" | grep -E \
        '^(port|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitrootlogin|authorizedkeysfile)[[:space:]]'


    # -----------------------------------------------------
    # 检查 Port
    # -----------------------------------------------------

    if echo "$EFFECTIVE_CONFIG" | grep -Eq '^port[[:space:]]+222$'; then

        echo "✅ SSH 端口：222"

    else

        echo "❌ SSH 端口不是 222"
        exit 1

    fi


    # -----------------------------------------------------
    # 检查公钥认证
    # -----------------------------------------------------

    if echo "$EFFECTIVE_CONFIG" | grep -Eq '^pubkeyauthentication[[:space:]]+yes$'; then

        echo "✅ 公钥认证：开启"

    else

        echo "❌ 公钥认证没有开启"
        exit 1

    fi


    # -----------------------------------------------------
    # 检查密码认证
    # -----------------------------------------------------

    if echo "$EFFECTIVE_CONFIG" | grep -Eq '^passwordauthentication[[:space:]]+no$'; then

        echo "✅ 密码认证：关闭"

    else

        echo "❌ 密码认证没有关闭"
        exit 1

    fi


    # -----------------------------------------------------
    # 检查 Root 登录
    # -----------------------------------------------------

    if echo "$EFFECTIVE_CONFIG" | grep -Eq '^permitrootlogin[[:space:]]+prohibit-password$'; then

        echo "✅ Root 登录：仅允许密钥"

    else

        echo "❌ Root SSH 登录策略不正确"
        exit 1

    fi


    # -----------------------------------------------------
    # 检查 authorized_keys
    # -----------------------------------------------------

    if echo "$EFFECTIVE_CONFIG" | grep -Eq '^authorizedkeysfile[[:space:]]+\.ssh/authorized_keys$'; then

        echo "✅ authorized_keys：正确"

    else

        echo "❌ authorized_keys 配置不正确"
        exit 1

    fi


    echo ""
    echo "✅ SSH 实际生效配置检查通过"

}


# =========================================================
# 11. 重启 SSH
# =========================================================

restart_ssh() {

    echo ""
    echo "========================================="
    echo "🔄 重启 SSH 服务"
    echo "========================================="


    if [ "$OS_TYPE" = "alpine" ]; then

        # Docker 容器
        if [ -f /.dockerenv ]; then

            echo "🐳 检测到 Docker 容器"

            mkdir -p /run/openrc
            touch /run/openrc/softlevel

            rc-update add sshd default 2>/dev/null || true

            # 停止旧 sshd
            pkill sshd 2>/dev/null || true

            /usr/sbin/sshd

        else

            rc-service sshd restart 2>/dev/null || \
            rc-service sshd start

            rc-update add sshd default 2>/dev/null || true

        fi

    else

        # Debian / Ubuntu
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


# =========================================================
# 12. 检查 SSH 222 端口
# =========================================================

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

            echo "⚠️ 没有检测到 222 端口监听"

            echo ""
            echo "SSH 服务状态："

            if [ "$OS_TYPE" = "alpine" ]; then
                rc-service sshd status 2>/dev/null || true
            else
                systemctl status ssh --no-pager 2>/dev/null || \
                systemctl status sshd --no-pager 2>/dev/null || true
            fi

            exit 1

        fi

    else

        echo "⚠️ 系统没有 ss 命令，跳过端口检查"

    fi

}


# =========================================================
# 13. Debian / Ubuntu 安装工具
# =========================================================

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


# =========================================================
# 14. Debian / Ubuntu 配置 UFW
# =========================================================

configure_ufw() {

    echo ""
    echo "========================================="
    echo "🔥 配置 UFW"
    echo "========================================="


    # -----------------------------------------------------
    # 非常重要：
    # 先放行 SSH 222
    # 再启用 UFW
    # -----------------------------------------------------

    echo "允许 SSH：222/tcp"

    ufw allow 222/tcp


    echo "允许 HTTP：80/tcp"

    ufw allow 80/tcp


    echo "允许 HTTPS：443/tcp"

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


# =========================================================
# 15. Debian / Ubuntu 设置时区
# =========================================================

configure_timezone() {

    echo ""
    echo "========================================="
    echo "🕐 配置系统时间"
    echo "========================================="


    # 安装 systemd-timesyncd
    apt-get install -y systemd-timesyncd


    # 新加坡时区
    timedatectl set-timezone Asia/Singapore


    # 硬件时钟使用 UTC
    timedatectl set-local-rtc 0


    # 开启 NTP
    timedatectl set-ntp true


    echo ""
    echo "✅ 时区：Asia/Singapore"
    echo "✅ NTP：已开启"


    echo ""

    timedatectl status

}


# =========================================================
# 16. Docker Compose alias
# =========================================================

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


# =========================================================
# 17. 开始安装 OpenSSH
# =========================================================

install_openssh


# =========================================================
# 18. 配置 SSH 公钥
# =========================================================

setup_ssh_keys


# =========================================================
# 19. 准备 SSH 配置
# =========================================================

prepare_ssh_config


# =========================================================
# 20. 清理旧配置
# =========================================================

clean_custom_ssh_config


# =========================================================
# 21. 写入统一 SSH 配置
# =========================================================

write_ssh_config


# =========================================================
# 22. 检查 SSH 配置
# =========================================================

check_ssh_syntax

check_effective_ssh_config


# =========================================================
# 23. 重启 SSH
# =========================================================

restart_ssh


# =========================================================
# 24. 检查 SSH 222
# =========================================================

check_ssh_port


# =========================================================
# 25. Debian / Ubuntu
# =========================================================

if [ "$OS_TYPE" = "debian" ] || [ "$OS_TYPE" = "ubuntu" ]; then

    install_debian_tools

    configure_ufw

    configure_timezone

fi


# =========================================================
# 26. Docker Compose alias
# =========================================================

configure_docker_alias


# =========================================================
# 27. 最终结果
# =========================================================

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
echo "不要立即关闭当前 SSH 会话！"

echo ""
echo "请打开新的终端测试："

echo ""
echo "ssh -p 222 root@服务器IP"

echo ""
echo "========================================="
echo "✅ 全部完成"
echo "========================================="