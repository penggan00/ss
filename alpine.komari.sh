#!/bin/bash

# Color definitions for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "$1"
}

log_success() {
    echo -e "${GREEN}$1${NC}"
}

log_error() {
    echo -e "${RED}$1${NC}"
}

log_step() {
    echo -e "${YELLOW}$1${NC}"
}

# Global variables
INSTALL_DIR="/opt/komari"
DATA_DIR="/opt/komari"
SERVICE_NAME="komari"
BINARY_PATH="$INSTALL_DIR/komari"
DEFAULT_PORT="25774"
LISTEN_PORT=""
LISTEN_ADDR=""

# Show banner
show_banner() {
    clear
    echo "=============================================================="
    echo "            Komari Monitoring System Installer"
    echo "       https://github.com/komari-monitor/komari"
    echo "=============================================================="
    echo
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

# Check for systemd
check_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        return 1
    else
        return 0
    fi
}

# Check for OpenRC (Alpine)
check_openrc() {
    if command -v rc-service >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Detect system architecture
detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "amd64"
            ;;
        aarch64)
            echo "arm64"
            ;;
        i386|i686)
            echo "386"
            ;;
        riscv64)
            echo "riscv64"
            ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

# Check if Komari is already installed
is_installed() {
    if [ -f "$BINARY_PATH" ]; then
        return 0
    else
        return 1
    fi
}

# Install dependencies
install_dependencies() {
    log_step "检查并安装依赖..."

    if ! command -v curl >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then
            log_info "使用 apt 安装依赖..."
            apt update
            apt install -y curl
        elif command -v yum >/dev/null 2>&1; then
            log_info "使用 yum 安装依赖..."
            yum install -y curl
        elif command -v apk >/dev/null 2>&1; then
            log_info "使用 apk 安装依赖..."
            apk add curl
        else
            log_error "未找到支持的包管理器 (apt/yum/apk)"
            exit 1
        fi
    fi
}

# Get listen address preference
get_listen_address() {
    echo
    log_info "请选择监听地址："
    echo "  1) 127.0.0.1 (仅本地访问，配合反向代理/Cloudflare Tunnel 使用) [推荐]"
    echo "  2) 0.0.0.0   (所有网络接口，直接公网访问)"
    echo
    while true; do
        read -p "请选择 [1-2] (默认: 1): " addr_choice
        if [[ -z "$addr_choice" ]] || [[ "$addr_choice" == "1" ]]; then
            LISTEN_ADDR="127.0.0.1"
            log_success "已选择: 仅本地访问 (127.0.0.1)"
            break
        elif [[ "$addr_choice" == "2" ]]; then
            LISTEN_ADDR="0.0.0.0"
            log_info "已选择: 所有网络接口 (0.0.0.0)"
            break
        else
            log_error "无效选项，请输入 1 或 2"
        fi
    done
}

# Create OpenRC service file for Alpine (优化版本)
create_openrc_service() {
    local addr="$1"
    local port="$2"
    log_step "创建 OpenRC 服务..."

    local service_file="/etc/init.d/${SERVICE_NAME}"
    cat > "$service_file" << 'EOF'
#!/sbin/openrc-run

name="komari"
description="Komari Monitor Service"
command="/opt/komari/komari"
command_args="server -l ADDR_PLACEHOLDER:PORT_PLACEHOLDER"
command_background="yes"
command_user="root"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/komari.log"
error_log="/var/log/komari.err.log"

respawn_delay="3"
respawn_max="0"

depend() {
  need net
  use dns
  after firewall
}

start_pre() {
  checkpath -f -m 0644 -o root:root /var/log/komari.log
  checkpath -f -m 0644 -o root:root /var/log/komari.err.log
}
EOF

    # 替换地址和端口占位符
    sed -i "s/ADDR_PLACEHOLDER/${addr}/g" "$service_file"
    sed -i "s/PORT_PLACEHOLDER/${port}/g" "$service_file"
    
    chmod +x "$service_file"
    log_success "OpenRC 服务文件创建完成: $service_file"
}

# Create systemd service file
create_systemd_service() {
    local addr="$1"
    local port="$2"
    log_step "创建 systemd 服务..."

    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"
    cat > "$service_file" << EOF
[Unit]
Description=Komari Monitor Service
After=network.target

[Service]
Type=simple
ExecStart=${BINARY_PATH} server -l ${addr}:${port}
WorkingDirectory=${DATA_DIR}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    log_success "systemd 服务文件创建完成"
}

# Show access information for systemd
show_access_info_systemd() {
    local addr="$1"
    local password=$2
    local port=${3:-$DEFAULT_PORT}
    
    echo
    log_success "安装完成！"
    echo
    
    if [ "$addr" == "127.0.0.1" ]; then
        log_info "访问信息："
        log_info "  本地地址: http://127.0.0.1:${port}"
        log_info ""
        log_info "⚠️  您选择了仅本地访问模式"
        log_info "   如需通过公网访问，请配置："
        log_info "   - 反向代理 (Nginx/Caddy)"
        log_info "   - Cloudflare Tunnel"
        log_info "   - SSH 隧道"
    else
        local ip=$(hostname -I | awk '{print $1}')
        log_info "访问信息："
        log_info "  URL: http://${ip}:${port}"
    fi
    
    if [ -n "$password" ]; then
        log_info ""
        log_info "初始登录信息（仅显示一次）: $password"
    fi
    
    echo
    log_info "服务管理命令："
    log_info "  状态:  systemctl status $SERVICE_NAME"
    log_info "  启动:  systemctl start $SERVICE_NAME"
    log_info "  停止:  systemctl stop $SERVICE_NAME"
    log_info "  重启:  systemctl restart $SERVICE_NAME"
    log_info "  日志:  journalctl -u $SERVICE_NAME -f"
}

# Show access information for Alpine
show_access_info_alpine() {
    local addr="$1"
    local password=$2
    local port=${3:-$DEFAULT_PORT}
    
    echo
    log_success "安装完成！"
    echo
    
    if [ "$addr" == "127.0.0.1" ]; then
        log_info "访问信息："
        log_info "  本地地址: http://127.0.0.1:${port}"
        log_info ""
        log_info "⚠️  您选择了仅本地访问模式"
        log_info "   如需通过公网访问，请配置："
        log_info "   - 反向代理 (Nginx/Caddy)"
        log_info "   - Cloudflare Tunnel"
        log_info "   - SSH 隧道"
    else
        local ip=$(hostname -I | awk '{print $1}')
        log_info "访问信息："
        log_info "  URL: http://${ip}:${port}"
    fi
    
    if [ -n "$password" ]; then
        log_info ""
        log_info "初始登录信息（仅显示一次）: $password"
    fi
    
    echo
    log_info "服务管理命令："
    log_info "  状态:  rc-service $SERVICE_NAME status"
    log_info "  启动:  rc-service $SERVICE_NAME start"
    log_info "  停止:  rc-service $SERVICE_NAME stop"
    log_info "  重启:  rc-service $SERVICE_NAME restart"
    log_info "  开机自启: rc-update add $SERVICE_NAME"
    log_info "  取消自启: rc-update del $SERVICE_NAME"
    log_info "  日志:  tail -f /var/log/komari.log"
}

# Binary installation
install_binary() {
    log_step "开始二进制安装..."

    if is_installed; then
        log_info "Komari 已安装。要升级，请使用升级选项。"
        return
    fi

    # 获取监听地址偏好
    get_listen_address

    # 监听端口输入，校验范围 1-65535
    while true; do
        read -p "请输入监听端口 [默认: $DEFAULT_PORT]: " input_port
        if [[ -z "$input_port" ]]; then
            LISTEN_PORT="$DEFAULT_PORT"
            break
        elif [[ "$input_port" =~ ^[0-9]+$ ]] && (( input_port >= 1 && input_port <= 65535 )); then
            LISTEN_PORT="$input_port"
            break
        else
            log_error "端口号无效，请输入 1-65535 之间的数字。"
        fi
    done

    install_dependencies

    local arch=$(detect_arch)
    log_info "检测到架构: $arch"

    log_step "创建安装目录: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    log_step "创建数据目录: $DATA_DIR"
    mkdir -p "$DATA_DIR"

    local file_name="komari-linux-${arch}"
    local download_url="https://github.com/komari-monitor/komari/releases/latest/download/${file_name}"

    log_step "下载 Komari 二进制文件..."
    log_info "URL: $download_url"

    if ! curl -L -o "$BINARY_PATH" "$download_url"; then
        log_error "下载失败"
        return 1
    fi

    chmod +x "$BINARY_PATH"
    log_success "Komari 二进制文件安装完成: $BINARY_PATH"

    # 检查是 systemd 还是 OpenRC
    if check_systemd; then
        log_step "检测到 systemd，创建 systemd 服务..."
        create_systemd_service "$LISTEN_ADDR" "$LISTEN_PORT"
        systemctl daemon-reload
        systemctl enable ${SERVICE_NAME}.service
        systemctl start ${SERVICE_NAME}.service

        if systemctl is-active --quiet ${SERVICE_NAME}.service; then
            log_success "Komari 服务启动成功"
            
            log_step "正在获取初始密码..."
            sleep 5 
            local password=$(journalctl -u ${SERVICE_NAME} --since "1 minute ago" | grep "admin account created." | tail -n 1 | sed -e 's/.*admin account created.//')
            if [ -z "$password" ]; then
                log_error "未能获取初始密码，请检查日志"
            fi
            show_access_info_systemd "$LISTEN_ADDR" "$password" "$LISTEN_PORT"
        else
            log_error "Komari 服务启动失败"
            log_info "查看日志: journalctl -u ${SERVICE_NAME} -f"
            return 1
        fi
    elif check_openrc; then
        log_step "检测到 OpenRC (Alpine)，创建 OpenRC 服务..."
        create_openrc_service "$LISTEN_ADDR" "$LISTEN_PORT"
        
        # 添加到开机自启
        rc-update add "$SERVICE_NAME" default
        
        # 启动服务
        rc-service "$SERVICE_NAME" start
        
        sleep 3
        
        if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
            log_success "Komari 服务启动成功"
            
            log_step "正在获取初始密码..."
            sleep 5
            local password=""
            if [ -f "/var/log/komari.log" ]; then
                password=$(tail -20 /var/log/komari.log | grep "admin account created." | tail -n 1 | sed -e 's/.*admin account created.//')
            fi
            
            if [ -z "$password" ]; then
                log_error "未能获取初始密码，请检查日志: tail -f /var/log/komari.log"
            fi
            show_access_info_alpine "$LISTEN_ADDR" "$password" "$LISTEN_PORT"
        else
            log_error "Komari 服务启动失败"
            log_info "查看日志: tail -f /var/log/komari.log"
            return 1
        fi
    else
        log_step "警告：未检测到 systemd 或 OpenRC，跳过服务创建。"
        log_step "您可以从命令行手动运行 Komari："
        log_step "    $BINARY_PATH server -l $LISTEN_ADDR:$LISTEN_PORT"
        echo
        log_success "安装完成！"
        return
    fi
}

# Upgrade function
upgrade_komari() {
    log_step "升级 Komari..."

    if ! is_installed; then
        log_error "Komari 未安装。请先安装它。"
        return 1
    fi

    if check_systemd; then
        log_step "停止 Komari 服务 (systemd)..."
        systemctl stop ${SERVICE_NAME}.service
    elif check_openrc; then
        log_step "停止 Komari 服务 (OpenRC)..."
        rc-service "$SERVICE_NAME" stop
    else
        log_error "未检测到 systemd 或 OpenRC。无法管理服务。"
        return 1
    fi

    log_step "备份当前二进制文件..."
    cp "$BINARY_PATH" "${BINARY_PATH}.backup.$(date +%Y%m%d_%H%M%S)"

    local arch=$(detect_arch)
    local file_name="komari-linux-${arch}"
    local download_url="https://github.com/komari-monitor/komari/releases/latest/download/${file_name}"

    log_step "下载最新版本..."
    if ! curl -L -o "$BINARY_PATH" "$download_url"; then
        log_error "下载失败，正在从备份恢复"
        mv "${BINARY_PATH}.backup."* "$BINARY_PATH"
        
        if check_systemd; then
            systemctl start ${SERVICE_NAME}.service
        elif check_openrc; then
            rc-service "$SERVICE_NAME" start
        fi
        return 1
    fi

    chmod +x "$BINARY_PATH"

    log_step "重启 Komari 服务..."
    if check_systemd; then
        systemctl start ${SERVICE_NAME}.service
        if systemctl is-active --quiet ${SERVICE_NAME}.service; then
            log_success "Komari 升级成功"
        else
            log_error "服务在升级后未能启动"
        fi
    elif check_openrc; then
        rc-service "$SERVICE_NAME" start
        if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
            log_success "Komari 升级成功"
        else
            log_error "服务在升级后未能启动"
        fi
    fi
}

# Uninstall function
uninstall_komari() {
    log_step "卸载 Komari..."

    if ! is_installed; then
        log_info "Komari 未安装"
        return 0
    fi

    read -p "这将删除 Komari。您确定吗？(y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_info "卸载已取消"
        return 0
    fi

    if check_systemd; then
        log_step "停止并禁用服务 (systemd)..."
        systemctl stop ${SERVICE_NAME}.service >/dev/null 2>&1
        systemctl disable ${SERVICE_NAME}.service >/dev/null 2>&1
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
        log_success "systemd 服务已删除"
    elif check_openrc; then
        log_step "停止并禁用服务 (OpenRC)..."
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1
        rc-update del "$SERVICE_NAME" >/dev/null 2>&1
        rm -f "/etc/init.d/${SERVICE_NAME}"
        log_success "OpenRC 服务已删除"
    fi

    log_step "删除二进制文件..."
    rm -f "$BINARY_PATH"
    # 尝试在目录为空时删除该目录
    rmdir "$INSTALL_DIR" 2>/dev/null || log_info "数据目录 $INSTALL_DIR 不为空，未删除"
    log_success "Komari 二进制文件已删除"

    log_success "Komari 卸载完成"
    log_info "数据文件保留在 $DATA_DIR"
}

# Show service status
show_status() {
    if ! is_installed; then
        log_error "Komari 未安装"
        return
    fi
    
    if check_systemd; then
        log_step "Komari 服务状态 (systemd):"
        systemctl status ${SERVICE_NAME}.service --no-pager -l
    elif check_openrc; then
        log_step "Komari 服务状态 (OpenRC):"
        rc-service "$SERVICE_NAME" status
    else
        log_error "未检测到 systemd 或 OpenRC。无法获取服务状态。"
    fi
}

# Show service logs
show_logs() {
    if ! is_installed; then
        log_error "Komari 未安装"
        return
    fi
    
    if check_systemd; then
        log_step "查看 Komari 服务日志 (systemd)..."
        journalctl -u ${SERVICE_NAME} -f --no-pager
    elif check_openrc; then
        log_step "查看 Komari 服务日志 (OpenRC)..."
        if [ -f "/var/log/komari.log" ]; then
            tail -f /var/log/komari.log
        else
            log_error "日志文件不存在: /var/log/komari.log"
        fi
    else
        log_error "未检测到 systemd 或 OpenRC。无法获取服务日志。"
    fi
}

# Restart service
restart_service() {
    if ! is_installed; then
        log_error "Komari 未安装"
        return
    fi
    
    if check_systemd; then
        log_step "重启 Komari 服务 (systemd)..."
        systemctl restart ${SERVICE_NAME}.service
        if systemctl is-active --quiet ${SERVICE_NAME}.service; then
            log_success "服务重启成功"
        else
            log_error "服务重启失败"
        fi
    elif check_openrc; then
        log_step "重启 Komari 服务 (OpenRC)..."
        rc-service "$SERVICE_NAME" restart
        if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
            log_success "服务重启成功"
        else
            log_error "服务重启失败"
        fi
    else
        log_error "未检测到 systemd 或 OpenRC。无法重启服务。"
    fi
}

# Stop service
stop_service() {
    if ! is_installed; then
        log_error "Komari 未安装"
        return
    fi
    
    if check_systemd; then
        log_step "停止 Komari 服务 (systemd)..."
        systemctl stop ${SERVICE_NAME}.service
        log_success "服务已停止"
    elif check_openrc; then
        log_step "停止 Komari 服务 (OpenRC)..."
        rc-service "$SERVICE_NAME" stop
        log_success "服务已停止"
    else
        log_error "未检测到 systemd 或 OpenRC。无法停止服务。"
    fi
}

# Main menu
main_menu() {
    show_banner
    echo "请选择操作："
    echo "  1) 安装 Komari"
    echo "  2) 升级 Komari"
    echo "  3) 卸载 Komari"
    echo "  4) 查看状态"
    echo "  5) 查看日志"
    echo "  6) 重启服务"
    echo "  7) 停止服务"
    echo "  8) 退出"
    echo

    read -p "输入选项 [1-8]: " choice

    case $choice in
        1) install_binary ;;
        2) upgrade_komari ;;
        3) uninstall_komari ;;
        4) show_status ;;
        5) show_logs ;;
        6) restart_service ;;
        7) stop_service ;;
        8) exit 0 ;;
        *) log_error "无效选项" ;;
    esac
}

# Main execution
check_root
main_menu