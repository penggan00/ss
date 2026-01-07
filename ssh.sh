cat << 'EOF' > ~/rss/ssh.sh
#!/bin/bash

# 确保脚本在出错时退出
set -e

# 读取 .env 文件（如果存在）
if [ -f ".env" ]; then
    set -a
    source .env || { echo "无法正确加载 .env 文件"; exit 1; }
    set +a
else
    echo "警告: 未找到 .env 文件，将尝试使用环境变量"
fi

# 检查必要变量是否设置
for var in TARGET_IP TARGET_USER TARGET_PASS; do
    if [ -z "${!var}" ]; then
        echo "错误: 必须设置 $var 环境变量"
        exit 1
    fi
done

# 自动安装 sshpass（如果需要）
install_sshpass() {
    echo "正在尝试自动安装 sshpass..."
    
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y sshpass
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y sshpass
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y sshpass
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y sshpass
    else
        echo "错误: 无法自动安装 sshpass - 请手动安装"
        echo "Ubuntu/Debian: sudo apt-get install sshpass"
        echo "CentOS/RHEL: sudo yum install sshpass"
        exit 1
    fi
}

# 检查或安装 sshpass
if ! command -v sshpass >/dev/null 2>&1; then
    install_sshpass
    # 再次验证安装是否成功
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "错误: sshpass 安装后仍不可用"
        exit 1
    fi
fi

# 定义要添加的任务列表
CRON_JOBS=(
    "*/10 * * * * /bin/bash ~/rss/rss.sh"
   #  "30 06,15,23 * * 1-5 /bin/bash ~/rss/usd.sh"
   #  "30 06 * * 6-7 /bin/bash ~/rss/usd.sh"   
)

# 检查并添加任务
for JOB in "${CRON_JOBS[@]}"; do
    # 跳过空行和注释行
    [[ -z "$JOB" || "$JOB" == \#* ]] && continue
    
    echo "正在处理任务: $JOB"
    
    # 检测任务是否已存在（精确匹配整行）
    if sshpass -p "$TARGET_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$TARGET_USER@$TARGET_IP" \
        "crontab -l 2>/dev/null | grep -Fxq -- '$JOB'"; then
        echo "任务已存在，跳过"
    else
        # 添加新任务（保留原有任务）
        if sshpass -p "$TARGET_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$TARGET_USER@$TARGET_IP" \
            "(crontab -l 2>/dev/null; echo '$JOB') | crontab -"; then
            echo "任务添加成功"
        else
            echo "错误: 无法添加任务"
            continue
        fi
    fi
done

echo "所有任务处理完成！"
EOF
chmod +x ~/rss/ssh.sh
(crontab -l 2>/dev/null | awk '{if ($0 == "10 0 1 * * ~/rss/ssh.sh") exit 1}') && (crontab -l 2>/dev/null; echo "10 0 1 * * ~/rss/ssh.sh") | crontab - && echo "任务已添加" || echo "任务已存在，跳过"
echo "crontab增加完成！"