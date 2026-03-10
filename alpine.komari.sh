#!/bin/sh
# Komari 安装脚本 - Alpine Linux 专用版
# 使用方法: sh install.sh

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "$1"; }
log_success() { echo -e "${GREEN}$1${NC}"; }
log_error() { echo -e "${RED}$1${NC}"; }
log_step() { echo -e "${YELLOW}$1${NC}"; }

# 全局变量
INSTALL_DIR="/opt/komari"
BINARY_PATH="$INSTALL_DIR/komari"
RUN_SCRIPT="$INSTALL_DIR/run.sh"
SERVICE_NAME="komari"
DEFAULT_PORT="25774"
LISTEN_PORT=""

# 显示横幅
show_banner() {
    clear
    echo "=============================================================="
    echo "       Komari 安装脚本 (Alpine Linux 专用)"
    echo "=============================================================="
    echo
}

# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用 root 权限运行"
        exit 1
    fi
}

# 检查 Alpine Linux 和 OpenRC
check_alpine() {
    if [ ! -f /etc/alpine-release ]; then
        log_error "此脚本仅支持 Alpine Linux"
        exit 1
    fi
    
    if ! command -v rc-service >/dev/null 2>&1; then
        log_error "未检测到 OpenRC，Alpine Linux 应该自带 OpenRC"
        exit 1
    fi
    
    log_success "检测到 Alpine Linux $(cat /etc/alpine-release)"
    log_success "OpenRC 可用"
}

# 检测架构
detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "amd64"
            ;;
        aarch64)
            echo "arm64"
            ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

# 检查是否已安装
is_installed() {
    [ -f "$BINARY_PATH" ]
}

# 安装依赖
install_deps() {
    log_step "安装依赖..."
    apk update
    apk add curl
}

# 创建自动重启脚本
create_run_script() {
    local port="$1"
    log_step "创建自动重启脚本..."
    
    cat > "$RUN_SCRIPT" << EOF
#!/bin/sh
# Komari 自动重启脚本
# 第一次运行，记录密码到日志
if [ ! -f /opt/komari/.initialized ]; then
  $BINARY_PATH server -l 0.0.0.0:$port -l [::]:$port > /var/log/komari.log 2>&1
  touch /opt/komari/.initialized
else
  # 后续运行不记录日志
  $BINARY_PATH server -l 0.0.0.0:$port -l [::]:$port > /dev/null 2>&1
fi
EOF

    chmod +x "$RUN_SCRIPT"
    log_success "自动重启脚本创建完成: $RUN_SCRIPT"
}

# 创建 OpenRC 服务
create_openrc_service() {
    log_step "创建 OpenRC 服务..."
    
    local service_file="/etc/init.d/$SERVICE_NAME"
    cat > "$service_file" << 'EOF'
#!/sbin/openrc-run
# Komari OpenRC 服务

name="komari"
description="Komari Monitor Service"
command="/opt/komari/run.sh"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
command_user="root"

depend() {
    need net
    after firewall
}

start_pre() {
    # 只在第一次创建日志文件
    if [ ! -f /var/log/komari.log ]; then
        touch /var/log/komari.log
        chmod 644 /var/log/komari.log
    fi
    ebegin "Starting Komari"
}

start_post() {
    eend $?
    echo "Komari 服务已启动"
}

stop() {
    ebegin "Stopping Komari"
    # 杀掉所有 komari 相关进程
    pkill -f "komari server" 2>/dev/null
    pkill -f "run.sh" 2>/dev/null
    eend $?
}

status() {
    if pgrep -f "komari server" >/dev/null 2>&1; then
        echo "status: started"
        return 0
    else
        echo "status: stopped"
        return 1
    fi
}
EOF

    chmod +x "$service_file"
    log_success "OpenRC 服务创建完成: $service_file"
}

# 获取初始密码
get_initial_password() {
    log_step "等待服务启动获取密码..."
    sleep 5
    
    local password=""
    # 从日志中提取密码
    password=$(tail -20 /var/log/komari.log 2>/dev/null | grep "admin account created." | tail -n 1 | sed -e 's/.*admin account created.//')
    
    echo "$password"
}

# 获取本机 IP
get_local_ip() {
    ip route get 1 2>/dev/null | awk '{print $NF;exit}' || hostname -i 2>/dev/null | awk '{print $1}' || echo "127.0.0.1"
}

# 显示访问信息
show_access_info() {
    local password="$1"
    local port="$2"
    local ip=$(get_local_ip)
    
    echo
    log_success "======================================"
    log_success "安装完成！"
    log_success "======================================"
    echo
    log_info "访问地址: http://$ip:$port"
    if [ -n "$password" ]; then
        log_info "初始密码: $password"
        log_info "（请妥善保管，仅显示一次）"
    else
        log_info "初始密码: 请查看日志获取: cat /var/log/komari.log | grep 'admin account created'"
    fi
    echo
    log_info "服务管理命令："
    log_info "  启动: rc-service $SERVICE_NAME start"
    log_info "  停止: rc-service $SERVICE_NAME stop"
    log_info "  重启: rc-service $SERVICE_NAME restart"
    log_info "  状态: rc-service $SERVICE_NAME status"
    log_info "  开机自启: rc-update add $SERVICE_NAME"
    log_info "  取消自启: rc-update del $SERVICE_NAME"
    echo
    log_info "查看日志: tail -f /var/log/komari.log"
    echo
    log_success "======================================"
}

# 安装主函数
install_komari() {
    log_step "开始安装 Komari..."
    
    # 检查是否已安装
    if is_installed; then
        log_info "Komari 已安装在 $BINARY_PATH"
        read -p "是否重新安装？(y/N): " reinstall
        if [ "$reinstall" != "y" ] && [ "$reinstall" != "Y" ]; then
            return
        fi
    fi
    
    # 输入端口
    while true; do
        read -p "请输入监听端口 [默认: $DEFAULT_PORT]: " input_port
        if [ -z "$input_port" ]; then
            LISTEN_PORT="$DEFAULT_PORT"
            break
        elif echo "$input_port" | grep -q '^[0-9]\+$' && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
            LISTEN_PORT="$input_port"
            break
        else
            log_error "端口无效，请输入 1-65535 之间的数字"
        fi
    done
    
    # 安装依赖
    install_deps
    
    # 创建目录
    log_step "创建安装目录..."
    mkdir -p "$INSTALL_DIR"
    
    # 检测架构并下载
    local arch=$(detect_arch)
    local file_name="komari-linux-${arch}"
    local download_url="https://github.com/komari-monitor/komari/releases/latest/download/${file_name}"
    
    log_step "下载 Komari ($arch)..."
    log_info "URL: $download_url"
    
    if ! curl -L -o "$BINARY_PATH" "$download_url"; then
        log_error "下载失败"
        exit 1
    fi
    
    chmod +x "$BINARY_PATH"
    log_success "二进制文件安装完成"
    
    # 创建自动重启脚本
    create_run_script "$LISTEN_PORT"
    
    # 创建 OpenRC 服务
    create_openrc_service
    
    # 停止旧服务（如果存在）
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        rc-service "$SERVICE_NAME" stop
    fi
    
    # 添加到开机自启
    rc-update add "$SERVICE_NAME" default
    
    # 启动服务
    log_step "启动服务..."
    rc-service "$SERVICE_NAME" start
    
    # 获取密码并显示信息
    local password=$(get_initial_password)
    show_access_info "$password" "$LISTEN_PORT"
}

# 升级函数
upgrade_komari() {
    log_step "开始升级 Komari..."
    
    if ! is_installed; then
        log_error "Komari 未安装，请先安装"
        return 1
    fi
    
    # 检测架构
    local arch=$(detect_arch)
    local file_name="komari-linux-${arch}"
    local download_url="https://github.com/komari-monitor/komari/releases/latest/download/${file_name}"
    
    # 停止服务
    log_step "停止 Komari 服务..."
    rc-service "$SERVICE_NAME" stop 2>/dev/null
    
    # 备份当前二进制文件
    local backup_file="${BINARY_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
    log_step "备份当前版本到 $backup_file"
    cp "$BINARY_PATH" "$backup_file"
    
    # 下载新版本
    log_step "下载最新版本..."
    log_info "URL: $download_url"
    
    if ! curl -L -o "$BINARY_PATH" "$download_url"; then
        log_error "下载失败，正在从备份恢复"
        mv "$backup_file" "$BINARY_PATH"
        rc-service "$SERVICE_NAME" start
        return 1
    fi
    
    chmod +x "$BINARY_PATH"
    
    # 启动服务
    log_step "启动升级后的服务..."
    rc-service "$SERVICE_NAME" start
    
    # 检查服务状态
    sleep 3
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        log_success "Komari 升级成功"
        
        # 获取新密码（如果生成了新密码）
        local password=$(get_initial_password)
        if [ -n "$password" ]; then
            echo
            log_info "新生成的初始密码（如果存在）: $password"
            log_info "请妥善保管"
        fi
    else
        log_error "服务启动失败，正在从备份恢复"
        cp "$backup_file" "$BINARY_PATH"
        rc-service "$SERVICE_NAME" start
        return 1
    fi
}

# 卸载函数
uninstall_komari() {
    log_step "卸载 Komari..."
    
    if ! is_installed; then
        log_info "Komari 未安装"
        return
    fi
    
    read -p "确定要卸载 Komari 吗？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "取消卸载"
        return
    fi
    
    # 停止并删除服务
    if [ -f "/etc/init.d/$SERVICE_NAME" ]; then
        rc-service "$SERVICE_NAME" stop 2>/dev/null
        rc-update del "$SERVICE_NAME" 2>/dev/null
        rm -f "/etc/init.d/$SERVICE_NAME"
        log_success "OpenRC 服务已删除"
    fi
    
    # 删除文件
    rm -f "$BINARY_PATH"
    rm -f "$RUN_SCRIPT"
    rm -f "/opt/komari/.initialized"
    
    # 尝试删除目录（如果为空）
    rmdir "$INSTALL_DIR" 2>/dev/null || log_info "目录 $INSTALL_DIR 不为空，保留"
    
    log_success "卸载完成"
    log_info "日志文件保留在 /var/log/komari.log"
}

# 查看状态
show_status() {
    if ! is_installed; then
        log_error "Komari 未安装"
        return
    fi
    
    if rc-service "$SERVICE_NAME" status; then
        log_success "Komari 正在运行"
    else
        log_error "Komari 未运行"
    fi
}

# 查看日志
show_logs() {
    if [ -f "/var/log/komari.log" ]; then
        tail -f /var/log/komari.log
    else
        log_error "日志文件不存在"
    fi
}

# 重启服务
restart_service() {
    if ! is_installed; then
        log_error "Komari 未安装"
        return
    fi
    
    rc-service "$SERVICE_NAME" restart
    log_success "服务已重启"
}

# 停止服务
stop_service() {
    if ! is_installed; then
        log_error "Komari 未安装"
        return
    fi
    
    rc-service "$SERVICE_NAME" stop
    log_success "服务已停止"
}

# 主菜单
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
        1) install_komari ;;
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

# 主程序
main() {
    check_root
    check_alpine
    main_menu
}

# 运行主程序
main