#!/bin/bash

# 智能安装 Docker 和 Docker Compose 脚本
# 支持 Debian/Ubuntu 和 Alpine 系统

set -e

echo "=== 开始安装 Docker 和 Docker Compose ==="
echo "检测系统类型..."

# 检测系统类型
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
elif [ -f /etc/alpine-release ]; then
    OS="alpine"
else
    echo "错误：不支持的操作系统"
    exit 1
fi

echo "检测到系统: $OS"

install_docker_debian() {
    echo "=== 在 Debian/Ubuntu 系统上安装 Docker ==="
    
    # 安装必要依赖
    apt-get update
    apt-get install -y curl
    
    # 使用官方脚本安装 Docker
    curl -fsSL https://get.docker.com | sh
    
    # 启动并启用 Docker 服务（确保开机自启动）
    systemctl enable --now docker
    systemctl start docker
    
    # 检查 Docker 服务状态
    if systemctl is-active --quiet docker; then
        echo "✓ Docker 服务已启动"
    else
        echo "✗ Docker 服务启动失败，尝试手动启动..."
        systemctl start docker
    fi
    
    # 确认开机自启已启用
    if systemctl is-enabled --quiet docker; then
        echo "✓ Docker 服务已设置为开机自启动"
    else
        echo "✗ Docker 开机自启动设置失败"
        systemctl enable docker
    fi
    
    # 安装 Docker Compose
    echo "=== 安装 Docker Compose ==="
    
    # 获取最新版本号
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    echo "下载 Docker Compose 版本: $COMPOSE_VERSION"
    
    # 下载 Docker Compose
    curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
    
    # 添加执行权限
    chmod +x /usr/local/bin/docker-compose
    
    # 创建软链接（如果需要）
    if [ ! -f /usr/bin/docker-compose ]; then
        ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose 2>/dev/null || true
    fi
    
    # 验证安装
    if [ -x "$(command -v docker-compose)" ]; then
        echo "✓ Docker Compose 安装成功"
    else
        echo "✗ Docker Compose 安装失败"
        exit 1
    fi
}

install_docker_alpine() {
    echo "=== 在 Alpine 系统上安装 Docker ==="
    
    # 取消注释 community 仓库
    if ! grep -q "^http://dl-cdn.alpinelinux.org/alpine/.*/community" /etc/apk/repositories; then
        echo "启用 community 仓库..."
        # 尝试取消注释已有的行
        sed -i 's|#http://dl-cdn.alpinelinux.org/alpine/.*/community|http://dl-cdn.alpinelinux.org/alpine/v3.21/community|' /etc/apk/repositories
        
        # 如果没有找到，则添加新的
        if ! grep -q "^http://dl-cdn.alpinelinux.org/alpine/.*/community" /etc/apk/repositories; then
            echo "http://dl-cdn.alpinelinux.org/alpine/v3.21/community" >> /etc/apk/repositories
        fi
    fi
    
    # 验证仓库配置
    echo "当前仓库配置:"
    grep -E '^http' /etc/apk/repositories || cat /etc/apk/repositories
    
    # 更新软件包列表
    apk update
    
    # 安装 Docker 和 Docker Compose
    echo "安装 Docker 和 Docker Compose..."
    apk add docker docker-compose docker-cli-compose
    
    # 启动 Docker 服务并设置为开机自启动
    echo "启动 Docker 服务..."
    rc-service docker start
    
    # 确保服务已启动
    if rc-service docker status | grep -q "started"; then
        echo "✓ Docker 服务已启动"
    else
        echo "✗ Docker 服务启动失败，尝试重新启动..."
        rc-service docker restart
    fi
    
    # 设置开机自启动
    echo "设置 Docker 开机自启动..."
    rc-update add docker boot
    
    # 验证开机自启动设置
    if rc-update show | grep -q "docker.*boot"; then
        echo "✓ Docker 服务已设置为开机自启动"
    else
        echo "✗ Docker 开机自启动设置失败"
        rc-update add docker boot
    fi
    
    # 确保 docker 组存在
    if ! grep -q "^docker:" /etc/group; then
        addgroup docker
    fi
}

# 根据系统类型执行相应的安装
case "$OS" in
    debian|ubuntu|raspbian|kali)
        install_docker_debian
        ;;
    alpine)
        install_docker_alpine
        ;;
    *)
        echo "错误：不支持的系统 '$OS'"
        echo "仅支持 Debian/Ubuntu 和 Alpine 系统"
        exit 1
        ;;
esac

echo ""
echo "=== 验证安装结果 ==="
echo "Docker 版本:"
if docker --version; then
    echo "✓ Docker 安装成功"
else
    echo "✗ Docker 安装失败"
    exit 1
fi

echo ""
echo "Docker Compose 版本:"
if docker-compose --version; then
    echo "✓ Docker Compose 安装成功"
else
    echo "✗ Docker Compose 安装失败"
    exit 1
fi

echo ""
echo "Docker 服务状态:"
if [ "$OS" = "alpine" ]; then
    rc-service docker status
    echo ""
    echo "开机自启动设置:"
    rc-update show | grep docker || echo "docker | boot"
else
    systemctl status docker --no-pager -l
    echo ""
    echo "开机自启动设置:"
    systemctl is-enabled docker
fi

echo ""
echo "=== 安装完成！ ==="
echo "重要：请确保当前用户已添加到 docker 组以获得权限"
echo ""
echo "运行以下命令将当前用户添加到 docker 组："
echo "  sudo usermod -aG docker \$USER"
echo ""
echo "然后退出当前会话并重新登录，或者运行："
echo "  newgrp docker"
echo ""
echo "验证权限（重新登录后运行）："
echo "  docker run hello-world"