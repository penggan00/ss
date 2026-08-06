#!/bin/bash
# b2.sh - 支持多系统的安全安装脚本（包含Alpine官方安装）

set -e  # 遇到错误立即退出，但我们会用 || true 处理可恢复的错误

# 使用环境变量传递密钥
B2_ACCOUNT=${B2_ACCOUNT:-""}
B2_KEY=${B2_KEY:-""}

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查环境变量是否设置
check_env() {
    if [ -z "$B2_ACCOUNT" ] || [ -z "$B2_KEY" ]; then
        log_error "请设置环境变量 B2_ACCOUNT 和 B2_KEY"
        echo "用法:"
        echo "  export B2_ACCOUNT='your_account_id'"
        echo "  export B2_KEY='your_application_key'"
        echo "  bash <(curl -sL https://raw.githubusercontent.com/.../b2.sh)"
        exit 1
    fi
}

# 检测系统类型和包管理器
detect_system() {
    log_info "检测系统环境..."
    
    # 检测OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        OS_NAME=$NAME
    elif command -v lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(lsb_release -sr)
        OS_NAME=$(lsb_release -sd)
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
        OS_VERSION=$(cat /etc/alpine-release)
        OS_NAME="Alpine Linux"
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(uname -r)
        OS_NAME=$OS
    fi
    
    # 检测包管理器
    if command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
        PKG_INSTALL="apk add --no-cache"
        PKG_UPDATE="apk update"
        PKG_REMOVE="apk del"
        PKG_QUERY="apk info -e"
    elif command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        PKG_INSTALL="apt-get install -y --no-install-recommends"
        PKG_UPDATE="apt-get update -qq"
        PKG_REMOVE="apt-get remove -y"
        PKG_QUERY="dpkg -l"
        export DEBIAN_FRONTEND=noninteractive
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum check-update -q"
        PKG_REMOVE="yum remove -y"
        PKG_QUERY="rpm -q"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf check-update -q"
        PKG_REMOVE="dnf remove -y"
        PKG_QUERY="rpm -q"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
        PKG_INSTALL="pacman -S --noconfirm --needed"
        PKG_UPDATE="pacman -Sy --noconfirm"
        PKG_REMOVE="pacman -R --noconfirm"
        PKG_QUERY="pacman -Q"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
        PKG_INSTALL="zypper install -y"
        PKG_UPDATE="zypper refresh -q"
        PKG_REMOVE="zypper remove -y"
        PKG_QUERY="zypper se"
    else
        log_warning "未检测到支持的包管理器，将尝试使用curl直接下载"
        PKG_MANAGER="unknown"
    fi
    
    log_info "系统: $OS_NAME $OS_VERSION"
    log_info "包管理器: ${PKG_MANAGER:-未知}"
}

# 检查并安装单个包
install_package() {
    local pkg=$1
    local required=$2
    
    # 检查包是否已安装
    case $PKG_MANAGER in
        "apk")
            if $PKG_QUERY "$pkg" >/dev/null 2>&1; then
                return 0
            fi
            ;;
        "apt")
            if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
                return 0
            fi
            ;;
        "yum"|"dnf")
            if rpm -q "$pkg" >/dev/null 2>&1; then
                return 0
            fi
            ;;
        "pacman")
            if pacman -Q "$pkg" >/dev/null 2>&1; then
                return 0
            fi
            ;;
        "zypper")
            if rpm -q "$pkg" >/dev/null 2>&1; then
                return 0
            fi
            ;;
    esac
    
    # 尝试安装
    log_info "安装 $pkg..."
    if $PKG_INSTALL "$pkg" >/dev/null 2>&1; then
        log_success "$pkg 安装成功"
        return 0
    else
        if [ "$required" = "true" ]; then
            log_error "$pkg 安装失败"
            return 1
        else
            log_warning "$pkg 安装失败（非必需）"
            return 0
        fi
    fi
}

# 安装必要的依赖（改进版）
install_dependencies() {
    log_info "安装系统依赖..."
    
    # 先尝试更新包列表（忽略错误）
    case $PKG_MANAGER in
        "apk")
            $PKG_UPDATE >/dev/null 2>&1 || true
            ;;
        "apt")
            $PKG_UPDATE >/dev/null 2>&1 || true
            ;;
        "yum"|"dnf")
            $PKG_UPDATE >/dev/null 2>&1 || true
            ;;
        "pacman")
            $PKG_UPDATE >/dev/null 2>&1 || true
            ;;
        "zypper")
            $PKG_UPDATE >/dev/null 2>&1 || true
            ;;
    esac
    
    # 核心依赖列表
    local core_packages=""
    local optional_packages=""
    
    case $PKG_MANAGER in
        "apk")
            core_packages="curl unzip ca-certificates"
            optional_packages="bash wget"
            ;;
        "apt")
            core_packages="curl unzip ca-certificates"
            optional_packages="wget"
            ;;
        "yum"|"dnf")
            core_packages="curl unzip ca-certificates"
            optional_packages="wget"
            # CentOS/RHEL 需要启用 EPEL
            if [ "$PKG_MANAGER" = "yum" ] && ! rpm -q epel-release >/dev/null 2>&1; then
                log_info "安装 EPEL 仓库..."
                yum install -y epel-release >/dev/null 2>&1 || true
                $PKG_UPDATE >/dev/null 2>&1 || true
            fi
            ;;
        "pacman")
            core_packages="curl unzip ca-certificates"
            optional_packages="wget"
            ;;
        "zypper")
            core_packages="curl unzip ca-certificates"
            optional_packages="wget"
            ;;
        *)
            log_warning "未知包管理器，尝试检查现有工具..."
            ;;
    esac
    
    # 安装核心依赖
    local install_failed=0
    for pkg in $core_packages; do
        if ! install_package "$pkg" "true"; then
            install_failed=1
        fi
    done
    
    # 安装可选依赖（不强制）
    for pkg in $optional_packages; do
        install_package "$pkg" "false"
    done
    
    # 验证安装结果
    if [ $install_failed -eq 1 ]; then
        log_error "部分核心依赖安装失败，尝试手动安装..."
        manual_install_dependencies
    else
        log_success "所有核心依赖安装完成"
    fi
    
    # 额外验证
    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl 未安装，这是必需的"
        return 1
    fi
    
    if ! command -v unzip >/dev/null 2>&1; then
        log_warning "unzip 未安装，将尝试使用其他解压工具"
        # 尝试找替代工具
        if command -v 7z >/dev/null 2>&1; then
            log_info "找到 7z，将使用其解压"
        elif command -v busybox >/dev/null 2>&1 && busybox --list | grep -q unzip; then
            log_info "找到 busybox unzip"
        else
            log_warning "没有找到任何解压工具，安装可能失败"
            log_info "尝试手动安装 unzip..."
            manual_install_unzip
        fi
    fi
    
    return 0
}

# 手动安装依赖（备用方案）
manual_install_dependencies() {
    log_info "尝试手动安装依赖..."
    
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y --no-install-recommends curl unzip ca-certificates >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl unzip ca-certificates >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl unzip ca-certificates >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl unzip ca-certificates >/dev/null 2>&1 || true
    fi
}

# 手动安装 unzip（最后尝试）
manual_install_unzip() {
    log_info "尝试单独安装 unzip..."
    
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y unzip >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y unzip >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y unzip >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache unzip >/dev/null 2>&1 || true
    fi
    
    if command -v unzip >/dev/null 2>&1; then
        log_success "unzip 手动安装成功"
        return 0
    else
        log_warning "unzip 安装失败，将使用替代方法"
        return 1
    fi
}

# 尝试Alpine官方仓库安装
install_rclone_alpine_official() {
    log_info "尝试通过Alpine官方仓库安装rclone..."
    
    # 启用社区仓库（如果尚未启用）
    if ! grep -q "^[^#]*community" /etc/apk/repositories 2>/dev/null; then
        log_info "启用Alpine社区仓库..."
        ALPINE_VERSION=$(cat /etc/alpine-release | cut -d. -f1-2)
        echo "http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" >> /etc/apk/repositories
        $PKG_UPDATE >/dev/null 2>&1
    fi
    
    # 尝试从官方仓库安装
    if apk add --no-cache rclone >/dev/null 2>&1; then
        log_success "通过Alpine官方仓库安装成功"
        return 0
    else
        log_warning "官方仓库安装失败，尝试其他方法"
        return 1
    fi
}

# 尝试Alpine edge/testing仓库安装
install_rclone_alpine_edge() {
    log_info "尝试通过Alpine edge仓库安装rclone..."
    
    # 启用edge/testing仓库（临时）
    echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories
    echo "http://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
    $PKG_UPDATE >/dev/null 2>&1
    
    if apk add --no-cache rclone >/dev/null 2>&1; then
        log_success "通过Alpine edge仓库安装成功"
        return 0
    else
        log_warning "Edge仓库安装失败"
        # 移除edge仓库以避免影响系统稳定性
        sed -i '/edge\/testing/d' /etc/apk/repositories 2>/dev/null
        sed -i '/edge\/community/d' /etc/apk/repositories 2>/dev/null
        $PKG_UPDATE >/dev/null 2>&1
        return 1
    fi
}

# 手动下载安装rclone（Alpine专用）
install_rclone_alpine_manual() {
    log_info "手动下载rclone for Alpine Linux..."
    
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
        LATEST_VERSION="1.66.0"
        log_warning "无法获取最新版本，使用备用版本 $LATEST_VERSION"
    fi
    
    local RCLONE_URL="https://downloads.rclone.org/v${LATEST_VERSION}/rclone-v${LATEST_VERSION}-linux-${RCLONE_ARCH}.zip"
    
    log_info "下载 rclone v${LATEST_VERSION} for ${RCLONE_ARCH}..."
    
    # 下载到临时目录
    local TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    
    if ! curl -L -o rclone.zip "$RCLONE_URL" --progress-bar; then
        log_error "下载失败"
        cd /
        rm -rf "$TMP_DIR"
        return 1
    fi
    
    # 尝试使用 unzip 解压
    if command -v unzip >/dev/null 2>&1; then
        if ! unzip -q rclone.zip; then
            log_error "解压失败"
            cd /
            rm -rf "$TMP_DIR"
            return 1
        fi
    else
        # 尝试使用其他解压工具
        if command -v 7z >/dev/null 2>&1; then
            7z x rclone.zip >/dev/null 2>&1
        elif command -v busybox >/dev/null 2>&1 && busybox --list | grep -q unzip; then
            busybox unzip rclone.zip >/dev/null 2>&1
        else
            log_error "没有可用的解压工具"
            cd /
            rm -rf "$TMP_DIR"
            return 1
        fi
    fi
    
    # 查找解压目录
    local RCLONE_DIR=$(find . -name "rclone-*-linux-${RCLONE_ARCH}" -type d 2>/dev/null | head -1)
    if [ -z "$RCLONE_DIR" ] || [ ! -f "$RCLONE_DIR/rclone" ]; then
        log_error "找不到rclone可执行文件"
        cd /
        rm -rf "$TMP_DIR"
        return 1
    fi
    
    # 安装到系统
    cp "$RCLONE_DIR/rclone" /usr/local/bin/
    chmod +x /usr/local/bin/rclone
    mkdir -p /usr/local/share/man/man1
    cp "$RCLONE_DIR/rclone.1" /usr/local/share/man/man1/ 2>/dev/null || true
    
    # 清理
    cd /
    rm -rf "$TMP_DIR"
    
    log_success "手动安装成功"
    return 0
}

# 安装rclone（改进版）
install_rclone() {
    log_info "正在安装rclone..."
    
    # 检查是否已安装rclone
    if command -v rclone >/dev/null 2>&1; then
        local version=$(rclone version 2>/dev/null | head -1)
        log_success "rclone已安装，版本: $version"
        return 0
    fi
    
    # Alpine Linux特殊处理
    if [ "$OS" = "alpine" ]; then
        log_info "检测到Alpine Linux，使用专用安装流程..."
        
        # 方法1: 尝试官方仓库
        install_rclone_alpine_official && return 0
        
        # 方法2: 尝试edge仓库
        install_rclone_alpine_edge && return 0
        
        # 方法3: 手动下载安装
        install_rclone_alpine_manual && return 0
        
        # 方法4: 使用官方安装脚本（最后尝试）
        log_info "尝试使用官方安装脚本..."
        if curl -fsSL https://rclone.org/install.sh | bash; then
            log_success "官方脚本安装成功"
            return 0
        fi
    else
        # 其他系统使用官方安装脚本
        log_info "使用官方安装脚本..."
        if curl -fsSL https://rclone.org/install.sh | bash; then
            log_success "官方脚本安装成功"
            return 0
        fi
    fi
    
    log_error "所有安装方法都失败了"
    return 1
}

# 创建配置
create_config() {
    log_info "创建rclone配置..."
    
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
        log_success "配置文件创建成功: ~/.config/rclone/rclone.conf"
    else
        log_error "配置文件创建失败"
        exit 1
    fi
}

# 验证安装
verify_installation() {
    log_info "验证安装..."
    
    # 检查rclone是否可执行
    if ! command -v rclone >/dev/null 2>&1; then
        log_error "rclone未找到"
        exit 1
    fi
    
    # 测试配置
    log_info "显示配置信息:"
    rclone config show penggan 2>/dev/null || log_warning "无法显示配置信息"
    
    # 测试连接
    echo ""
    log_info "测试B2连接..."
    if rclone lsd penggan: >/dev/null 2>&1; then
        log_success "B2连接成功"
        
        # 列出存储桶
        echo ""
        log_info "可用的存储桶:"
        rclone lsd penggan: 2>/dev/null || echo "  (没有存储桶或列表失败)"
    else
        log_warning "B2连接测试失败，请检查密钥和网络连接"
        log_info "配置已保存，您可以稍后运行: rclone lsd penggan:"
    fi
}

# 显示使用说明
show_usage() {
    echo ""
    log_success "安装完成！"
    echo "使用方法:"
    echo "  列出存储桶: rclone lsd penggan:"
    echo "  列出文件: rclone ls penggan:bucket-name"
    echo "  复制文件: rclone copy source.txt penggan:bucket-name/"
    echo "  下载文件: rclone copy penggan:bucket-name/file.txt ./"
    echo ""
    echo "测试下载命令:"
    echo "  mkdir -p /opt && rclone cat penggan:penggan/opt/komari.tar.gz | tar -xzf - -C /opt --strip-components=1"
}

# 主函数
main() {
    echo "========================================="
    echo "     B2 Rclone 自动安装脚本"
    echo "========================================="
    echo ""
    
    # 检查环境变量
    check_env
    
    # 检测系统
    detect_system
    
    # 安装依赖
    if ! install_dependencies; then
        log_error "依赖安装失败，请手动安装 curl 和 unzip"
        exit 1
    fi
    
    # 安装rclone
    if ! install_rclone; then
        log_error "rclone安装失败"
        exit 1
    fi
    
    # 创建配置
    create_config
    
    # 验证安装
    verify_installation
    
    # 显示使用说明
    show_usage
    
    echo ""
    log_success "✓ 全部安装完成！"
}

# 捕获中断信号
trap 'echo ""; log_warning "安装被中断"; exit 1' INT TERM

# 执行主函数
main "$@"