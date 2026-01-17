#!/bin/bash
# b2.sh - 支持多系统的安全安装脚本

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

# 安装rclone
install_rclone() {
    echo "正在安装rclone..."
    
    # 检查是否已安装rclone
    if command -v rclone >/dev/null 2>&1; then
        echo "rclone已安装，版本: $(rclone version | head -1)"
        return
    fi
    
    # 根据系统类型选择安装方法
    if [ "$PKG_MANAGER" = "apk" ]; then
        # Alpine Linux的特定处理
        if [ -f /etc/alpine-release ]; then
            # 检查musl版本
            MUSL_ARCH=$(uname -m)
            case $MUSL_ARCH in
                "x86_64")
                    RCLONE_ARCH="amd64"
                    ;;
                "aarch64"|"arm64")
                    RCLONE_ARCH="arm64"
                    ;;
                "armv7l")
                    RCLONE_ARCH="arm-v7"
                    ;;
                *)
                    RCLONE_ARCH="amd64"  # 默认值
                    ;;
            esac
            
            echo "下载rclone for Alpine Linux (musl)..."
            RCLONE_URL="https://downloads.rclone.org/rclone-current-linux-${RCLONE_ARCH}.zip"
            curl -o /tmp/rclone.zip -L "$RCLONE_URL"
            unzip -q /tmp/rclone.zip -d /tmp/
            RCLONE_DIR=$(find /tmp -name "rclone-*-linux-${RCLONE_ARCH}" -type d | head -1)
            if [ -n "$RCLONE_DIR" ]; then
                sudo cp "$RCLONE_DIR/rclone" /usr/local/bin/
                sudo chmod +x /usr/local/bin/rclone
                sudo mkdir -p /usr/local/share/man/man1
                sudo cp "$RCLONE_DIR/rclone.1" /usr/local/share/man/man1/
                rm -rf /tmp/rclone* "$RCLONE_DIR"
            else
                echo "错误: 无法找到解压的rclone文件"
                exit 1
            fi
        else
            # 非Alpine的musl系统
            curl https://rclone.org/install.sh | sudo bash
        fi
    else
        # 使用官方安装脚本（适用于glibc系统）
        curl -fsSL https://rclone.org/install.sh | sudo bash
    fi
    
    if ! command -v rclone >/dev/null 2>&1; then
        echo "错误: rclone安装失败"
        exit 1
    fi
    
    echo "rclone安装完成，版本: $(rclone version | head -1)"
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
    
    # 测试连接（可选，可能需要网络）
    echo -e "\n测试B2连接..."
    if rclone lsd penggan: >/dev/null 2>&1; then
        echo "✓ B2连接成功"
    else
        echo "⚠  B2连接测试失败，请检查密钥和网络连接"
        echo "配置已保存，您可以稍后运行: rclone lsd penggan:"
    fi
}

# 主函数
main() {
    echo "开始安装 B2 配置脚本..."
    
    # 检测系统
    detect_system
    
    # 安装依赖
    install_dependencies
    
    # 安装rclone
    install_rclone
    
    # 创建配置
    create_config
    
    # 验证安装
    verify_installation
    
    echo -e "\n安装完成！"
    echo "使用方法:"
    echo "  列出存储桶: rclone lsd penggan:"
    echo "  列出文件: rclone ls penggan:bucket-name"
    echo "  复制文件: rclone copy source.txt penggan:bucket-name/"
}

# 执行主函数
main "$@"