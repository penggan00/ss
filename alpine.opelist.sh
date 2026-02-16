#!/bin/sh
###############################################################################
#
# OpenList Manage Script for Alpine Linux
#
# Version: 1.3.4-alpine
# Last Updated: 2025-09-29
#
# Description:
#   A management script for OpenList (https://github.com/OpenListTeam/OpenList)
#   Specifically adapted for Alpine Linux with OpenRC
#
# Requirements:
#   - Alpine Linux
#   - Root privileges for installation
#   - curl, tar
#
# Author: ILoveScratch and OpenList Dev Team
#
# License: MIT
#
###############################################################################

# 颜色定义
RED_COLOR='\033[1;31m'
GREEN_COLOR='\033[1;32m'
YELLOW_COLOR='\033[1;33m'
BLUE_COLOR='\033[1;34m'
CYAN_COLOR='\033[1;36m'
PURPLE_COLOR='\033[1;35m'
RES='\033[0m'

# CPU架构定义
ARCH_MAP_x86_64="amd64"
ARCH_MAP_aarch64="arm64"
ARCH_MAP_loongarch64="loong64"
ARCH_MAP_loongson3="mips64le"
ARCH_MAP_s390x="s390x"

# 检查系统是否为Linux
CURRENT_OS=$(uname -s)
if [ "$CURRENT_OS" != "Linux" ]; then
    echo -e "${RED_COLOR}错误：此脚本仅支持 Linux 系统${RES}"
    exit 1
fi

# 使用 doas 或 sudo 确保 root 执行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED_COLOR}此脚本需要root权限运行${RES}"
        if command -v doas >/dev/null 2>&1; then
            exec doas "sh" "$0" "$@"
        elif command -v sudo >/dev/null 2>&1; then
            exec sudo "sh" "$0" "$@"
        else
            echo -e "${RED_COLOR}请使用 root 用户运行此脚本${RES}"
            exit 1
        fi
    fi
}

check_root "$@"

# 获取安装路径
get_install_path() {
    echo "/opt/openlist"
}

# 检查磁盘空间
check_disk_space() {
    echo -e "${BLUE_COLOR}检查系统空间...${RES}"

    # Alpine 使用 df 的不同格式
    local tmp_space=$(df -h /tmp 2>/dev/null | awk 'NR==2 {print $4}' || echo "unknown")
    local tmp_space_mb=$(df /tmp 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")

    local install_dir_parent=$(dirname "$INSTALL_PATH")
    if [ ! -d "$install_dir_parent" ]; then
        mkdir -p "$install_dir_parent" 2>/dev/null || install_dir_parent="/"
    fi
    local install_space=$(df -h "$install_dir_parent" 2>/dev/null | awk 'NR==2 {print $4}' || echo "unknown")
    local install_space_mb=$(df "$install_dir_parent" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")

    if [ "$tmp_space_mb" != "0" ] && [ "$install_space_mb" != "0" ]; then
        if [ $tmp_space_mb -lt 102400 ] || [ $install_space_mb -lt 102400 ]; then
            echo -e "${RED_COLOR}警告：系统空间不足${RES}"
            echo -e "临时目录可用空间: $tmp_space"
            echo -e "安装目录可用空间: $install_space"
            echo -e "${YELLOW_COLOR}建议清理系统空间后再继续${RES}"
            
            if [ ! -t 0 ]; then
                echo -e "${YELLOW_COLOR}非交互模式：检测到可用空间不足，自动退出${RES}"
                return 1
            fi
            
            printf "是否继续？[y/N]: "
            read continue_choice
            case "$continue_choice" in
                [yY])
                    return 0
                    ;;
                *)
                    exit 1
                    ;;
            esac
        fi
    fi
}

# 检查必要的命令
if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED_COLOR}错误：未找到 curl 命令，请先安装${RES}"
    echo -e "${YELLOW_COLOR}运行: apk add curl${RES}"
    exit 1
fi

# 配置部分
GITHUB_REPO="OpenListTeam/OpenList"
VERSION_TAG="beta"
VERSION_FILE="/opt/openlist/.version"
GH_DOWNLOAD_URL="https://github.com/OpenListTeam/OpenList/releases/latest/download"

# 获取平台架构
if command -v arch >/dev/null 2>&1; then
    platform=$(arch)
else
    platform=$(uname -m)
fi

case "$platform" in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64)
        ARCH="arm64"
        ;;
    loongarch64)
        ARCH="loong64"
        ;;
    loongson3)
        ARCH="mips64le"
        ;;
    s390x)
        ARCH="s390x"
        ;;
    *)
        ARCH="UNKNOWN"
        ;;
esac

# 环境检查
if [ "$ARCH" = "UNKNOWN" ]; then
    echo -e "\r\n${RED_COLOR}出错了${RES}，一键安装目前暂不支持 $platform 平台。\r\n"
    exit 1
fi

# 检查 Alpine 是否使用 OpenRC
if ! command -v rc-update >/dev/null 2>&1; then
    echo -e "\r\n${RED_COLOR}出错了${RES}，你当前的系统不支持 OpenRC。\r\n建议手动安装。\r\n"
    exit 1
fi

# 设置安装路径
if [ -z "$2" ]; then
    INSTALL_PATH=$(get_install_path)
else
    INSTALL_PATH=${2%/}
    if ! echo "$INSTALL_PATH" | grep -q "/openlist$"; then
        INSTALL_PATH="$INSTALL_PATH/openlist"
    fi

    parent_dir=$(dirname "$INSTALL_PATH")
    if [ ! -d "$parent_dir" ]; then
        mkdir -p "$parent_dir" || {
            echo -e "${RED_COLOR}错误：无法创建目录 $parent_dir${RES}"
            exit 1
        }
    fi

    if ! [ -w "$parent_dir" ]; then
        echo -e "${RED_COLOR}错误：目录 $parent_dir 没有写入权限${RES}"
        exit 1
    fi
fi

clear

# 检查是否已安装
CHECK() {
    # 检查目标目录是否存在
    if [ ! -d "$(dirname "$INSTALL_PATH")" ]; then
        echo -e "${GREEN_COLOR}目录不存在，正在创建...${RES}"
        mkdir -p "$(dirname "$INSTALL_PATH")" || {
            echo -e "${RED_COLOR}错误：无法创建目录 $(dirname "$INSTALL_PATH")${RES}"
            exit 1
        }
    fi

    # 检查是否已安装
    if [ -f "$INSTALL_PATH/openlist" ]; then
        echo "此位置已经安装，请选择其他位置，或使用更新命令"
        exit 0
    fi

    # 创建或清空安装目录
    if [ ! -d "$INSTALL_PATH/" ]; then
        mkdir -p "$INSTALL_PATH" || {
            echo -e "${RED_COLOR}错误：无法创建安装目录 $INSTALL_PATH${RES}"
            exit 1
        }
    else
        rm -rf "$INSTALL_PATH" && mkdir -p "$INSTALL_PATH"
    fi

    echo -e "${GREEN_COLOR}安装目录准备就绪：$INSTALL_PATH${RES}"
}

# 全局变量
ADMIN_USER=""
ADMIN_PASS=""
ADMIN_INFO_FILE="$INSTALL_PATH/data/.admin_info"

# 下载文件
download_file() {
    local url="$1"
    local output="$2"
    local max_retries=3
    local retry_count=0
    local wait_time=2

    while [ $retry_count -lt $max_retries ]; do
        if curl -L --connect-timeout 10 --retry 3 --retry-delay 3 "$url" -o "$output"; then
            if [ -f "$output" ] && [ -s "$output" ]; then
                return 0
            fi
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo -e "${YELLOW_COLOR}下载失败，${wait_time} 秒后进行第 $retry_count 次重试...${RES}"
            sleep $wait_time
            wait_time=$((wait_time + 2))
        else
            echo -e "${RED_COLOR}下载失败，已重试 $max_retries 次${RES}"
            return 1
        fi
    done
    return 1
}

# 安装 OpenList
INSTALL() {
    CURRENT_DIR=$(pwd)
    
    # 询问是否使用代理
    echo -e "${GREEN_COLOR}是否使用 GitHub 代理？（默认无代理）${RES}"
    echo -e "${GREEN_COLOR}代理地址必须为 https 开头，斜杠 / 结尾 ${RES}"
    echo -e "${GREEN_COLOR}例如：https://ghproxy.net/ ${RES}"
    printf "请输入代理地址或直接按 Enter 继续: "
    read proxy_input

    if [ -n "$proxy_input" ]; then
        GH_PROXY="$proxy_input"
        GH_DOWNLOAD_URL="${GH_PROXY}https://github.com/OpenListTeam/OpenList/releases/latest/download"
        echo -e "${GREEN_COLOR}已使用代理地址: $GH_PROXY${RES}"
    else
        GH_DOWNLOAD_URL="https://github.com/OpenListTeam/OpenList/releases/latest/download"
        echo -e "${GREEN_COLOR}使用默认 GitHub 地址进行下载${RES}"
    fi

    echo -e "\r\n${GREEN_COLOR}下载 OpenList ...${RES}"
    
    if ! download_file "${GH_DOWNLOAD_URL}/openlist-linux-musl-$ARCH.tar.gz" "/tmp/openlist.tar.gz"; then
        echo -e "${RED_COLOR}下载失败！${RES}"
        exit 1
    fi

    if ! tar zxf /tmp/openlist.tar.gz -C "$INSTALL_PATH/"; then
        echo -e "${RED_COLOR}解压失败！${RES}"
        rm -f /tmp/openlist.tar.gz
        exit 1
    fi

    if [ -f "$INSTALL_PATH/openlist" ]; then
        echo -e "${GREEN_COLOR}下载成功，正在安装...${RES}"

        chmod +x "$INSTALL_PATH/openlist"

        # 获取初始账号密码并保存到文件
        cd "$INSTALL_PATH"
        # 先创建data目录，否则openlist无法生成配置文件
        mkdir -p "$INSTALL_PATH/data"
        
        # 检查是否已存在配置文件
        if [ -f "$INSTALL_PATH/data/config.json" ]; then
            echo -e "${YELLOW_COLOR}检测到现有配置文件，保留原有设置${RES}"
        else
            echo -e "${GREEN_COLOR}生成初始账号密码...${RES}"
            ACCOUNT_INFO=$("$INSTALL_PATH/openlist" admin random 2>&1)
            ADMIN_USER=$(echo "$ACCOUNT_INFO" | grep "username:" | sed 's/.*username://' | tr -d ' ')
            ADMIN_PASS=$(echo "$ACCOUNT_INFO" | grep "password:" | sed 's/.*password://' | tr -d ' ')
            
            # 保存账号信息到文件
            if [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ]; then
                echo "ADMIN_USER=$ADMIN_USER" > "$ADMIN_INFO_FILE"
                echo "ADMIN_PASS=$ADMIN_PASS" >> "$ADMIN_INFO_FILE"
                echo -e "${GREEN_COLOR}初始账号密码已保存到: $ADMIN_INFO_FILE${RES}"
            fi
        fi
        
        cd "$CURRENT_DIR"
    else
        echo -e "${RED_COLOR}安装失败！${RES}"
        rm -rf "$INSTALL_PATH"
        mkdir -p "$INSTALL_PATH"
        exit 1
    fi

    # 记录版本信息
    VERSION_INFO=$("$INSTALL_PATH/openlist" version 2>&1)
    REAL_VERSION=$(echo "$VERSION_INFO" | grep "^Version:" | sed 's/Version://' | tr -d ' ' | grep . || echo "$VERSION_TAG")
    echo "$REAL_VERSION" > "$VERSION_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$VERSION_FILE"

    rm -f /tmp/openlist*
}

# 初始化 OpenRC 服务
INIT() {
    if [ ! -f "$INSTALL_PATH/openlist" ]; then
        echo -e "\r\n${RED_COLOR}出错了${RES}，当前系统未安装 OpenList\r\n"
        exit 1
    fi

    # 创建 OpenRC 服务文件 - 修复版
    cat >/etc/init.d/openlist <<EOF
#!/sbin/openrc-run

name="OpenList"
description="OpenList Service"
pidfile="/run/openlist.pid"

command="$INSTALL_PATH/openlist"
command_args="server --data $INSTALL_PATH/data"
command_background=true
command_user="root"

# 设置工作目录
directory="$INSTALL_PATH"

# 日志配置
logger_stdout=true
logger_stderr=true

depend() {
    need net
    after firewall
}

start_pre() {
    # 确保数据目录存在
    if [ ! -d "$INSTALL_PATH/data" ]; then
        mkdir -p "$INSTALL_PATH/data"
    fi
    
    # 检查端口是否被占用
    if lsof -i :5244 >/dev/null 2>&1; then
        eerror "端口 5244 已被占用"
        return 1
    fi
    
    return 0
}

start_post() {
    einfo "OpenList 服务已启动"
    sleep 2
    if [ -f "/run/openlist.pid" ] && kill -0 \$(cat /run/openlist.pid) 2>/dev/null; then
        einfo "OpenList 进程运行正常"
    else
        eerror "OpenList 进程启动失败"
        return 1
    fi
}

stop_post() {
    # 确保进程完全停止
    local timeout=10
    local count=0
    
    if [ -f "/run/openlist.pid" ]; then
        local pid=\$(cat /run/openlist.pid)
        while kill -0 \$pid 2>/dev/null && [ \$count -lt \$timeout ]; do
            sleep 1
            count=\$((count + 1))
        done
        
        if kill -0 \$pid 2>/dev/null; then
            kill -9 \$pid 2>/dev/null
            einfo "强制停止 OpenList 进程"
        fi
    fi
    
    # 清理PID文件
    rm -f /run/openlist.pid
    einfo "OpenList 服务已停止"
}
EOF

    chmod +x /etc/init.d/openlist
    
    # 添加到默认运行级别
    rc-update add openlist default
    
    echo -e "${GREEN_COLOR}OpenRC 服务已配置完成${RES}"
}

# 安装成功提示
SUCCESS() {
    clear
    print_line() {
        local text="$1"
        local width=50
        printf "│ %-${width}s │\n" "$text"
    }

    # 获取 IP
    LOCAL_IP=$(ip addr show 2>/dev/null | grep -w inet | grep -v "127.0.0.1" | awk '{print $2}' | cut -d/ -f1 | head -n1)
    PUBLIC_IP=$(curl -s4 --connect-timeout 5 ip.sb 2>/dev/null || curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null || echo "localhost")

    # 获取版本信息
    local version_info="UNKNOWN"
    if [ -f "$VERSION_FILE" ]; then
        version_info=$(head -n1 "$VERSION_FILE" 2>/dev/null)
    elif [ -n "$REAL_VERSION" ]; then
        version_info="$REAL_VERSION"
    fi

    # 尝试从保存的文件读取账号信息
    if [ -f "$ADMIN_INFO_FILE" ]; then
        . "$ADMIN_INFO_FILE"
    fi

    echo -e "┌────────────────────────────────────────────────────┐"
    print_line "OpenList 安装成功！"
    print_line ""
    print_line "版本信息：$version_info"
    print_line ""
    print_line "访问地址："
    print_line "  局域网：http://${LOCAL_IP}:5244/"
    print_line "  公网：  http://${PUBLIC_IP}:5244/"
    print_line "配置文件：$INSTALL_PATH/data/config.json"
    print_line "安装目录：$INSTALL_PATH"
    print_line ""
    if [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ]; then
        print_line "账号信息："
        print_line "默认账号：$ADMIN_USER"
        print_line "初始密码：$ADMIN_PASS"
        print_line "账号信息文件：$ADMIN_INFO_FILE"
    else
        print_line "账号信息："
        print_line "请检查文件：$ADMIN_INFO_FILE"
        print_line "或运行: $INSTALL_PATH/openlist admin random"
    fi
    echo -e "└────────────────────────────────────────────────────┘"
    
    echo -e "\n${GREEN_COLOR}启动服务中...${RES}"
    /etc/init.d/openlist start
    
    # 检查服务状态
    sleep 3
    if /etc/init.d/openlist status >/dev/null 2>&1; then
        echo -e "${GREEN_COLOR}服务启动成功！${RES}"
    else
        echo -e "${YELLOW_COLOR}服务启动可能有问题，请手动检查${RES}"
        echo -e "${YELLOW_COLOR}可以尝试手动启动：$INSTALL_PATH/openlist server --data $INSTALL_PATH/data${RES}"
    fi
    
    echo -e "\n${YELLOW_COLOR}温馨提示：${RES}"
    echo -e "${YELLOW_COLOR}1. 如果端口无法访问，请检查防火墙规则${RES}"
    echo -e "${YELLOW_COLOR}2. 允许端口命令：rc-service nftables stop 或添加规则${RES}"
    echo -e "${YELLOW_COLOR}3. 查看日志：tail -f $INSTALL_PATH/data/openlist.log${RES}"
    echo
}

# 更新 OpenList
UPDATE() {
    if [ ! -f "$INSTALL_PATH/openlist" ]; then
        echo -e "\r\n${RED_COLOR}错误：未在 $INSTALL_PATH 找到 OpenList${RES}\r\n"
        exit 1
    fi

    echo -e "${GREEN_COLOR}开始更新 OpenList ...${RES}"

    # 询问是否使用代理
    if [ -t 0 ]; then
        echo -e "${GREEN_COLOR}是否使用 GitHub 代理？（默认无代理）${RES}"
        echo -e "${GREEN_COLOR}例如：https://ghproxy.com/ ${RES}"
        printf "请输入代理地址或直接按 Enter 继续: "
        read proxy_input

        if [ -n "$proxy_input" ]; then
            GH_PROXY="$proxy_input"
            GH_DOWNLOAD_URL="${GH_PROXY}https://github.com/OpenListTeam/OpenList/releases/download"
        else
            GH_PROXY=""
            GH_DOWNLOAD_URL="https://github.com/OpenListTeam/OpenList/releases/download"
        fi
    else
        if [ -n "$GH_PROXY" ]; then
            GH_DOWNLOAD_URL="${GH_PROXY}https://github.com/OpenListTeam/OpenList/releases/download"
        else
            GH_DOWNLOAD_URL="https://github.com/OpenListTeam/OpenList/releases/download"
        fi
    fi

    # 获取版本信息
    echo -e "${GREEN_COLOR}获取版本信息...${RES}"
    REAL_VERSION=$(curl -s "https://api.github.com/repos/OpenListTeam/OpenList/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' 2>/dev/null | grep . || echo "$VERSION_TAG")

    if [ "$REAL_VERSION" = "beta" ]; then
        echo -e "${YELLOW_COLOR}提示：获取最新版本信息失败，默认升级到latest版本！${RES}"
        GH_DOWNLOAD_URL="${GH_PROXY}https://github.com/OpenListTeam/OpenList/releases/latest/download"
    else
        CURRENT_VERSION=""
        if [ -f "$VERSION_FILE" ]; then
            CURRENT_VERSION=$(head -n1 "$VERSION_FILE" 2>/dev/null)
        fi

        if [ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" = "$REAL_VERSION" ]; then
            echo -e "${GREEN_COLOR}当前已是最新版本 ($CURRENT_VERSION)，无需更新${RES}"
            return 0
        fi
        GH_DOWNLOAD_URL="${GH_DOWNLOAD_URL}/${REAL_VERSION}"
    fi

    echo -e "${GREEN_COLOR}停止 OpenList 进程${RES}\r\n"
    /etc/init.d/openlist stop

    cp "$INSTALL_PATH/openlist" /tmp/openlist.bak

    echo -e "${GREEN_COLOR}下载 OpenList ...${RES}"
    if ! download_file "${GH_DOWNLOAD_URL}/openlist-linux-musl-$ARCH.tar.gz" "/tmp/openlist.tar.gz"; then
        echo -e "${RED_COLOR}下载失败，更新终止${RES}"
        echo -e "${GREEN_COLOR}正在恢复之前的版本...${RES}"
        mv /tmp/openlist.bak "$INSTALL_PATH/openlist"
        /etc/init.d/openlist start
        exit 1
    fi

    if ! tar zxf /tmp/openlist.tar.gz -C "$INSTALL_PATH/"; then
        echo -e "${RED_COLOR}解压失败，更新终止${RES}"
        echo -e "${GREEN_COLOR}正在恢复之前的版本...${RES}"
        mv /tmp/openlist.bak "$INSTALL_PATH/openlist"
        /etc/init.d/openlist start
        rm -f /tmp/openlist.tar.gz
        exit 1
    fi

    if [ -f "$INSTALL_PATH/openlist" ]; then
        echo -e "${GREEN_COLOR}下载成功，正在更新${RES}"
        chmod +x "$INSTALL_PATH/openlist"
    else
        echo -e "${RED_COLOR}更新失败！${RES}"
        echo -e "${GREEN_COLOR}正在恢复之前的版本...${RES}"
        mv /tmp/openlist.bak "$INSTALL_PATH/openlist"
        /etc/init.d/openlist start
        rm -f /tmp/openlist.tar.gz
        exit 1
    fi

    VERSION_INFO=$("$INSTALL_PATH/openlist" version 2>&1)
    REAL_VERSION=$(echo "$VERSION_INFO" | grep "^Version:" | sed 's/Version://' | tr -d ' ' | grep . || echo "$REAL_VERSION")
    echo "$REAL_VERSION" > "$VERSION_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$VERSION_FILE"

    rm -f /tmp/openlist.tar.gz /tmp/openlist.bak

    echo -e "${GREEN_COLOR}启动 OpenList 进程${RES}\r\n"
    /etc/init.d/openlist restart

    echo -e "${GREEN_COLOR}更新完成！${RES}"
    echo -e "${GREEN_COLOR}当前版本：${RES}$REAL_VERSION"
    echo -e "${GREEN_COLOR}更新时间：${RES}$(date '+%Y-%m-%d %H:%M:%S')"
    echo
}

# 卸载 OpenList
UNINSTALL() {
    # 查找安装路径
    local found_path=""
    
    if [ -f "/etc/init.d/openlist" ]; then
        found_path=$(grep "command=" /etc/init.d/openlist | cut -d'=' -f2 | sed "s|/openlist.*||" | head -n1)
        if [ -f "$found_path/openlist" ]; then
            INSTALL_PATH="$found_path"
        else
            found_path=""
        fi
    fi

    if [ -z "$found_path" ]; then
        for path in "/opt/openlist" "$INSTALL_PATH"; do
            if [ -f "$path/openlist" ]; then
                INSTALL_PATH="$path"
                found_path="$path"
                break
            fi
        done
    fi

    if [ -z "$found_path" ]; then
        echo -e "${YELLOW_COLOR}未找到 OpenList 安装路径${RES}"
        printf "请手动指定 OpenList 安装目录: "
        read manual_path
        if [ -f "$manual_path/openlist" ]; then
            INSTALL_PATH="$manual_path"
        else
            echo -e "\r\n${RED_COLOR}错误：在指定路径 $manual_path 中未找到 OpenList${RES}\r\n"
            exit 1
        fi
    fi

    echo -e "${GREEN_COLOR}找到 OpenList 安装路径：$INSTALL_PATH${RES}"
    echo -e "${RED_COLOR}警告：卸载后将删除本地 OpenList 目录！${RES}"
    printf "是否确认卸载？[y/N]: "
    read choice

    case "$choice" in
        [yY])
            echo -e "${GREEN_COLOR}开始卸载...${RES}"

            echo -e "${GREEN_COLOR}停止 OpenList 进程${RES}"
            /etc/init.d/openlist stop
            
            echo -e "${GREEN_COLOR}移除 OpenRC 服务${RES}"
            rc-update del openlist default 2>/dev/null

            echo -e "${GREEN_COLOR}删除 OpenList 文件${RES}"
            rm -rf "$INSTALL_PATH"
            rm -f /etc/init.d/openlist
            rm -f /run/openlist.pid 2>/dev/null

            echo -e "${GREEN_COLOR}OpenList 已完全卸载${RES}"
            exit 0
            ;;
        *)
            echo -e "${GREEN_COLOR}已取消卸载${RES}"
            return 0
            ;;
    esac
}

# 显示菜单
SHOW_MENU() {
    echo -e "\n欢迎使用 OpenList 管理脚本 (Alpine)\n"
    echo -e "${GREEN_COLOR}基础功能：${RES}"
    echo -e "${GREEN_COLOR}1、安装 OpenList${RES}"
    echo -e "${GREEN_COLOR}2、更新 OpenList${RES}"
    echo -e "${GREEN_COLOR}3、卸载 OpenList${RES}"
    echo -e "${GREEN_COLOR}-------------------${RES}"
    echo -e "${GREEN_COLOR}服务管理：${RES}"
    echo -e "${GREEN_COLOR}4、查看状态${RES}"
    echo -e "${GREEN_COLOR}5、启动 OpenList${RES}"
    echo -e "${GREEN_COLOR}6、停止 OpenList${RES}"
    echo -e "${GREEN_COLOR}7、重启 OpenList${RES}"
    echo -e "${GREEN_COLOR}8、查看账号信息${RES}"
    echo -e "${GREEN_COLOR}9、重置管理员密码${RES}"
    echo -e "${GREEN_COLOR}-------------------${RES}"
    echo -e "${GREEN_COLOR}0、退出脚本${RES}"
    echo
    printf "请输入选项 [0-9]: "
    read choice
    
    case "$choice" in
        1)
            INSTALL_PATH=$(get_install_path)
            check_disk_space
            CHECK
            INSTALL
            INIT
            SUCCESS
            return 0
            ;;
        2)
            check_disk_space
            UPDATE
            return 0
            ;;
        3)
            UNINSTALL
            return 0
            ;;
        4)
            if [ ! -f "$INSTALL_PATH/openlist" ]; then
                echo -e "\r\n${RED_COLOR}错误：系统未安装 OpenList，请先安装！${RES}\r\n"
                return 1
            fi
            
            /etc/init.d/openlist status
            return 0
            ;;
        5)
            if [ ! -f "$INSTALL_PATH/openlist" ]; then
                echo -e "\r\n${RED_COLOR}错误：系统未安装 OpenList，请先安装！${RES}\r\n"
                return 1
            fi
            /etc/init.d/openlist start
            echo -e "${GREEN_COLOR}OpenList 已启动${RES}"
            return 0
            ;;
        6)
            if [ ! -f "$INSTALL_PATH/openlist" ]; then
                echo -e "\r\n${RED_COLOR}错误：系统未安装 OpenList，请先安装！${RES}\r\n"
                return 1
            fi
            /etc/init.d/openlist stop
            echo -e "${GREEN_COLOR}OpenList 已停止${RES}"
            return 0
            ;;
        7)
            if [ ! -f "$INSTALL_PATH/openlist" ]; then
                echo -e "\r\n${RED_COLOR}错误：系统未安装 OpenList，请先安装！${RES}\r\n"
                return 1
            fi
            /etc/init.d/openlist restart
            echo -e "${GREEN_COLOR}OpenList 已重启${RES}"
            return 0
            ;;
        8)
            if [ ! -f "$INSTALL_PATH/openlist" ]; then
                echo -e "\r\n${RED_COLOR}错误：系统未安装 OpenList，请先安装！${RES}\r\n"
                return 1
            fi
            
            if [ -f "$ADMIN_INFO_FILE" ]; then
                echo -e "${GREEN_COLOR}账号信息文件：$ADMIN_INFO_FILE${RES}"
                cat "$ADMIN_INFO_FILE"
            else
                echo -e "${YELLOW_COLOR}未找到账号信息文件${RES}"
                echo -e "${YELLOW_COLOR}您可以运行以下命令重置密码：${RES}"
                echo -e "cd $INSTALL_PATH && ./openlist admin random"
            fi
            return 0
            ;;
        9)
            if [ ! -f "$INSTALL_PATH/openlist" ]; then
                echo -e "\r\n${RED_COLOR}错误：系统未安装 OpenList，请先安装！${RES}\r\n"
                return 1
            fi
            
            cd "$INSTALL_PATH"
            echo -e "${GREEN_COLOR}正在生成新的管理员账号密码...${RES}"
            ACCOUNT_INFO=$("$INSTALL_PATH/openlist" admin random 2>&1)
            ADMIN_USER=$(echo "$ACCOUNT_INFO" | grep "username:" | sed 's/.*username://' | tr -d ' ')
            ADMIN_PASS=$(echo "$ACCOUNT_INFO" | grep "password:" | sed 's/.*password://' | tr -d ' ')
            
            if [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ]; then
                echo "ADMIN_USER=$ADMIN_USER" > "$ADMIN_INFO_FILE"
                echo "ADMIN_PASS=$ADMIN_PASS" >> "$ADMIN_INFO_FILE"
                echo -e "${GREEN_COLOR}新的账号信息已保存${RES}"
                echo -e "用户名: $ADMIN_USER"
                echo -e "密码: $ADMIN_PASS"
            else
                echo -e "${RED_COLOR}生成账号信息失败${RES}"
            fi
            return 0
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED_COLOR}无效的选项${RES}"
            return 1
            ;;
    esac
}

# 主程序
if [ $# -eq 0 ]; then
    while true; do
        SHOW_MENU
        echo
        printf "按任意键继续 ... "
        read -n 1 -s
        clear
    done
elif [ "$1" = "install" ]; then
    check_disk_space
    CHECK
    INSTALL
    INIT
    SUCCESS
elif [ "$1" = "update" ]; then
    if [ $# -gt 1 ]; then
        echo -e "${RED_COLOR}错误：update 命令不需要指定路径${RES}"
        echo -e "正确用法: $0 update"
        exit 1
    fi
    check_disk_space
    UPDATE
elif [ "$1" = "uninstall" ]; then
    if [ $# -gt 1 ]; then
        echo -e "${RED_COLOR}错误：uninstall 命令不需要指定路径${RES}"
        echo -e "正确用法: $0 uninstall"
        exit 1
    fi
    UNINSTALL
else
    echo -e "${RED_COLOR}错误的命令${RES}"
    echo -e "用法: $0 install [安装路径]    # 安装 OpenList"
    echo -e "     $0 update              # 更新 OpenList"
    echo -e "     $0 uninstall          # 卸载 OpenList"
    echo -e "     $0                    # 显示交互菜单"
fi