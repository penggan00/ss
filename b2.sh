#!/bin/bash
# b2.sh - 支持多系统的安全安装脚本（包含Alpine官方安装）

# 使用环境变量传递密钥
B2_ACCOUNT=${B2_ACCOUNT:-""}
B2_KEY=${B2_KEY:-""}

# 检查环境变量是否设置
if [ -z "$B2_ACCOUNT" ] || [ -z "$B2_KEY" ]; then
    echo "错误: 请设置环境变量 B2_ACCOUNT 和 B2_KEY"
    echo "用法:"
    echo "  export B2_ACCOUNT='your_account_id'"
    echo "  export B2_KEY='your_application_key'"
    echo "  bash <(curl -sL https://raw.githubusercontent.com/.../b2.sh)"
    exit 1
fi

# 检测系统类型和包管理器
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    elif command -v lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(lsb_release -sr)
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
        OS_VERSION=$(cat /etc/alpine-release)
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(uname -r)
    fi
    
    # 检测包管理器
    if command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
        PKG_INSTALL="apk add"
        PKG_UPDATE="apk update"
    elif command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum check-update"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf check-update"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
        PKG_INSTALL="pacman -S --noconfirm"
        PKG_UPDATE="pacman -Sy"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
        PKG_INSTALL="zypper install -y"
        PKG_UPDATE="zypper refresh"
    else
        echo "警告: 未检测到支持的包管理器，尝试使用curl直接下载rclone"
        PKG_MANAGER="unknown"
    fi
}

# 安装必要的依赖
install_dependencies() {
    echo "检测到系统: $OS $OS_VERSION"
    echo "使用包管理器: $PKG_MANAGER"
    
    case $PKG_MANAGER in
        "apk")
            $PKG_UPDATE
            $PKG_INSTALL curl unzip ca-certificates
            ;;
        "apt")
            $PKG_UPDATE
            $PKG_INSTALL curl unzip ca-certificates
            ;;
        "yum"|"dnf")
            $PKG_UPDATE || true
            $PKG_INSTALL curl unzip ca-certificates
            ;;
        "pacman")
            $PKG_UPDATE
            $PKG_INSTALL curl unzip ca-certificates
            ;;
        "zypper")
            $PKG_UPDATE
            $PKG_INSTALL curl unzip ca-certificates
            ;;
        *)
            # 尝试安装curl和unzip（如果可能）
            if ! command -v curl >/dev/null 2>&1; then
                echo "警告: curl未安装，可能需要手动安装"
            fi
            if ! command -v unzip >/dev/null 2>&1; then
                echo "警告: unzip未安装，可能需要手动安装"
            fi
            ;;
    esac
}

# 尝试Alpine官方仓库安装
install_rclone_alpine_official() {
    echo "尝试通过Alpine官方仓库安装rclone..."
    
    # 启用社区仓库（如果尚未启用）
    if ! grep -q "^[^#]*community" /etc/apk/repositories; then
        echo "启用Alpine社区仓库..."
        ALPINE_VERSION=$(cat /etc/alpine-release | cut -d. -f1-2)
        echo "http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" >> /etc/apk/repositories
        $PKG_UPDATE
    fi
    
    # 尝试从官方仓库安装
    if $PKG_INSTALL rclone; then
        echo "✓ 通过Alpine官方仓库安装成功"
        return 0
    else
        echo "⚠ 官方仓库安装失败，尝试其他方法"
        return 1
    fi
}

# 尝试Alpine edge/testing仓库安装
install_rclone_alpine_edge() {
    echo "尝试通过Alpine edge仓库安装rclone..."
    
    # 启用edge/testing仓库
    echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories
    echo "http://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
    $PKG_UPDATE
    
    if $PKG_INSTALL rclone; then
        echo "✓ 通过Alpine edge仓库安装成功"
        return 0
    else
        echo "⚠ Edge仓库安装失败"
        # 移除edge仓库以避免影响系统稳定性
        sed -i '/edge\/testing/d' /etc/apk/repositories
        sed -i '/edge\/community/d' /etc/apk/repositories
        $PKG_UPDATE
        return 1
    fi
}

# 手动下载安装rclone（Alpine专用）
install_rclone_alpine_manual() {
    echo "手动下载rclone for Alpine Linux..."
    
    # 检测架构
    local ARCH=$(uname -m)
    case $ARCH in
        x86_64) RCLONE_ARCH="amd64" ;;
        aarch64|arm64) RCLONE_ARCH="arm64" ;;
        armv7l) RCLONE_ARCH="arm-v7" ;;
        *) RCLONE_ARCH="amd64" ;;
    esac
    
    # 获取最新版本号
    local LATEST_VERSION=$(curl -s https://downloads.rclone.org/version.txt | cut -d'v' -f2)
    if [ -z "$LATEST_VERSION" ]; then
        LATEST_VERSION="1.66.0"  # 备用版本
    fi
    
    local RCLONE_URL="https://downloads.rclone.org/v${LATEST_VERSION}/rclone-v${LATEST_VERSION}-linux-${RCLONE_ARCH}.zip"
    
    echo "下载rclone v${LATEST_VERSION} for ${RCLONE_ARCH}..."
    
    # 下载
    if ! curl -L -o /tmp/rclone.zip "$RCLONE_URL"; then
        echo "错误: 下载失败"
        return 1
    fi
    
    # 解压
    if ! unzip -q /tmp/rclone.zip -d /tmp/; then
        echo "错误: 解压失败"
        return 1
    fi
    
    # 查找解压目录
    local RCLONE_DIR=$(find /tmp -name "rclone-v${LATEST_VERSION}-linux-${RCLONE_ARCH}" -type d 2>/dev/null | head -1)
    if [ -z "$RCLONE_DIR" ]; then
        # 尝试其他命名模式
        RCLONE_DIR=$(find /tmp -name "rclone-*-linux-${RCLONE_ARCH}" -type d 2>/dev/null | head -1)
    fi
    
    if [ -z "$RCLONE_DIR" ] || [ ! -f "$RCLONE_DIR/rclone" ]; then
        echo "错误: 找不到rclone可执行文件"
        return 1
    fi
    
    # 安装到系统
    cp "$RCLONE_DIR/rclone" /usr/local/bin/
    chmod +x /usr/local/bin/rclone
    mkdir -p /usr/local/share/man/man1
    cp "$RCLONE_DIR/rclone.1" /usr/local/share/man/man1/ 2>/dev/null || true
    
    # 清理
    rm -f /tmp/rclone.zip
    rm -rf "$RCLONE_DIR"
    
    echo "✓ 手动安装成功"
    return 0
}

# 安装rclone
install_rclone() {
    echo "正在安装rclone..."
    
    # 检查是否已安装rclone
    if command -v rclone >/dev/null 2>&1; then
        local version=$(rclone version | head -1)
        echo "rclone已安装，版本: $version"
        return 0
    fi
    
    # Alpine Linux特殊处理
    if [ "$OS" = "alpine" ]; then
        echo "检测到Alpine Linux，使用专用安装流程..."
        
        # 方法1: 尝试官方仓库
        install_rclone_alpine_official && return 0
        
        # 方法2: 尝试edge仓库
        install_rclone_alpine_edge && return 0
        
        # 方法3: 手动下载安装
        install_rclone_alpine_manual && return 0
        
        # 方法4: 使用官方安装脚本（最后尝试）
        echo "尝试使用官方安装脚本..."
        if curl -fsSL https://rclone.org/install.sh | bash; then
            echo "✓ 官方脚本安装成功"
            return 0
        fi
    else
        # 其他系统使用官方安装脚本
        echo "使用官方安装脚本..."
        if curl -fsSL https://rclone.org/install.sh | sudo bash; then
            echo "✓ 官方脚本安装成功"
            return 0
        fi
    fi
    
    echo "错误: 所有安装方法都失败了"
    return 1
}

# 创建配置
create_config() {
    echo "创建rclone配置..."
    
    # 创建配置目录
    mkdir -p ~/.config/rclone
    
    # 创建配置文件
    cat > ~/.config/rclone/rclone.conf <<EOF
[penggan]
type = b2
account = ${B2_ACCOUNT}
key = ${B2_KEY}
EOF
    
    # 设置权限
    chmod 600 ~/.config/rclone/rclone.conf
    
    # 验证配置
    if [ -f ~/.config/rclone/rclone.conf ]; then
        echo "配置文件创建成功: ~/.config/rclone/rclone.conf"
    else
        echo "错误: 配置文件创建失败"
        exit 1
    fi
}

# 验证安装
verify_installation() {
    echo "验证安装..."
    
    # 检查rclone是否可执行
    if ! command -v rclone >/dev/null 2>&1; then
        echo "错误: rclone未找到"
        exit 1
    fi
    
    # 测试配置
    echo "显示配置信息:"
    rclone config show penggan
    
    # 测试连接
    echo -e "\n测试B2连接..."
    if rclone lsd penggan: >/dev/null 2>&1; then
        echo "✓ B2连接成功"
        
        # 列出存储桶
        echo -e "\n可用的存储桶:"
        rclone lsd penggan:
    else
        echo "⚠  B2连接测试失败，请检查密钥和网络连接"
        echo "配置已保存，您可以稍后运行: rclone lsd penggan:"
    fi
}

# 显示使用说明
show_usage() {
    echo -e "\n安装完成！"
    echo "使用方法:"
    echo "  列出存储桶: rclone lsd penggan:"
    echo "  列出文件: rclone ls penggan:bucket-name"
    echo "  复制文件: rclone copy source.txt penggan:bucket-name/"
    echo "  下载文件: rclone copy penggan:bucket-name/file.txt ./"
    echo -e "\n测试下载命令:"
    echo "  mkdir -p /opt && rclone cat penggan:penggan/opt/komari.tar.gz | tar -xzf - -C /opt --strip-components=1"
}

# 主函数
main() {
    echo "开始安装 B2 配置脚本..."
    echo "系统检测: $OS $OS_VERSION"
    
    # 安装依赖
    install_dependencies
    
    # 安装rclone
    if ! install_rclone; then
        echo "错误: rclone安装失败"
        exit 1
    fi
    
    # 创建配置
    create_config
    
    # 验证安装
    verify_installation
    
    # 显示使用说明
    show_usage
    
    echo -e "\n✓ 安装完成！"
}

# 执行主函数
main "$@"