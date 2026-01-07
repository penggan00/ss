#!/bin/bash
# 恢复脚本 - 从远程备份恢复所有服务
set -e  # 遇到错误时停止执行

# 显示菜单
show_menu() {
    echo "======================================="
    echo "        服务恢复脚本"
    echo "======================================="
    echo "1. 恢复所有服务"
    echo "2. 恢复博客服务"
    echo "3. 恢复RSSTT服务"
    echo "4. 恢复Aria2服务"
    echo "5. 恢复OpenAList服务"
    echo "6. 恢复RSSHub服务"
    echo "7. 恢复Nginx Proxy Manager服务"
    echo "8. 恢复RSS服务"
    echo "9. 退出"
    echo "======================================="
}

# 恢复RSS服务
restore_rss() {
    echo "恢复RSS服务..."
    cd ~ && rclone cat penggan:penggan/rss.tar.gz | tar -xzf - && cd ~/rss
    echo "✓ RSS服务恢复完成"
}

# 恢复博客服务
restore_blog() {
    echo "恢复博客服务..."
    cd ~ && rclone cat penggan:penggan/myblog.tar.gz | tar -xzf - && cd ~/myblog && git clone https://github.com/penggan00/penggan00.github.io.git && mv penggan00.github.io blog
    echo "✓ 博客服务恢复完成"
}

# 恢复RSSTT服务
restore_rsstt() {
    echo "恢复RSSTT服务..."
    cd ~ && rclone cat penggan:penggan/rsstt.tar.gz | tar -xzf - && cd ~/rsstt
    echo "✓ RSSTT服务恢复完成"
}

# 恢复Aria2服务
restore_aria2() {
    echo "恢复Aria2服务..."
    cd ~ && rclone cat penggan:penggan/aria2.tar.gz | tar -xzf - && cd ~/aria2
    echo "✓ Aria2服务恢复完成"
}

# 恢复OpenAList服务
restore_openalsit() {
    echo "恢复OpenAList服务..."
    cd ~ && rclone cat penggan:penggan/openalsit.tar.gz | tar -xzf - && cd ~/openalsit && docker-compose up -d
    echo "✓ OpenAList服务恢复完成并启动"
}

# 恢复RSSHub服务
restore_rsshub() {
    echo "恢复RSSHub服务..."
    cd ~ && rclone cat penggan:penggan/rsshub.tar.gz | tar -xzf - && cd ~/rsshub && docker-compose up -d
    echo "✓ RSSHub服务恢复完成并启动"
}

# 恢复NPM服务
restore_npm() {
    echo "恢复Nginx Proxy Manager服务..."
    cd ~ && rclone cat penggan:penggan/npm.tar.gz | tar -xzf - && cd ~/nginx-proxy-manager && docker-compose up -d
    echo "✓ Nginx Proxy Manager服务恢复完成并启动"
}

# 恢复所有服务
restore_all() {
    echo "开始恢复所有服务..."
    
    restore_rss
    restore_blog
    restore_rsstt
    restore_aria2
    restore_openalsit
    restore_rsshub
    restore_npm
    
    echo ""
    echo "所有服务恢复完成！"
}

# 主程序
main() {
    while true; do
        show_menu
        read -p "请选择要恢复的服务 [1-9]: " choice
        
        case $choice in
            1)
                restore_all
                ;;
            2)
                restore_blog
                ;;
            3)
                restore_rsstt
                ;;
            4)
                restore_aria2
                ;;
            5)
                restore_openalsit
                ;;
            6)
                restore_rsshub
                ;;
            7)
                restore_npm
                ;;
            8)
                restore_rss
                ;;
            9)
                echo "退出脚本"
                exit 0
                ;;
            *)
                echo "无效选择，请重新输入"
                ;;
        esac
        
        echo ""
        read -p "按Enter键继续..." -n 1
        echo ""
    done
}

# 启动主程序
main