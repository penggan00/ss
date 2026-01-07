cat << 'EOF' > ~/rss/github.sh
#!/bin/bash

# GitHub文件自动下载脚本
# 支持可选的GitHub Token以提高API限制

# 配置区域
DOWNLOAD_DIR="$HOME/rss"

# 尝试从.env文件加载GitHub Token（可选）
if [[ -f "$(dirname "$0")/.env" ]]; then
    source "$(dirname "$0")/.env"
fi

# 要监控的GitHub文件列表 - 使用正确的用户名
declare -A FILES_TO_MONITOR=(
    ["rss.py"]="https://raw.githubusercontent.com/penggan00/rss/main/rss.py"
    ["rss_config.py"]="https://raw.githubusercontent.com/penggan00/rss/main/rss_config.py"
    ["gpt.py"]="https://raw.githubusercontent.com/penggan00/rss/main/gpt.py"
    ["qq.py"]="https://raw.githubusercontent.com/penggan00/rss/main/qq.py"
    ["mail.py"]="https://raw.githubusercontent.com/penggan00/rss/main/mail.py"
)

# 检查依赖
check_dependencies() {
    local deps=("curl")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "安装缺失的依赖: ${missing_deps[*]}"
        
        if command -v apt-get &> /dev/null; then
            sudo apt-get update
            sudo apt-get install -y "${missing_deps[@]}"
        elif command -v yum &> /dev/null; then
            sudo yum install -y "${missing_deps[@]}"
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y "${missing_deps[@]}"
        elif command -v pacman &> /dev/null; then
            sudo pacman -Sy --noconfirm "${missing_deps[@]}"
        elif command -v zypper &> /dev/null; then
            sudo zypper install -y "${missing_deps[@]}"
        else
            echo "错误: 无法自动安装依赖，请手动安装: ${missing_deps[*]}"
            exit 1
        fi
    fi
}

# 确保下载目录存在
ensure_download_dir() {
    if [ ! -d "$DOWNLOAD_DIR" ]; then
        mkdir -p "$DOWNLOAD_DIR"
    fi
}

# 获取本地文件的Git SHA1哈希
get_local_git_sha() {
    local file_path="$1"
    if [[ -f "$file_path" ]]; then
        local file_size
        if stat -c%s "$file_path" &>/dev/null; then
            file_size=$(stat -c%s "$file_path")
        else
            file_size=$(stat -f%z "$file_path")
        fi
        (printf "blob %d\0" "$file_size"; cat "$file_path") | sha1sum | cut -d' ' -f1
    else
        echo ""
    fi
}

# 从GitHub API获取文件SHA
get_github_sha() {
    local raw_url="$1"
    
    if [[ $raw_url =~ https://raw.githubusercontent.com/([^/]+)/([^/]+)/([^/]+)/(.+) ]]; then
        local user="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        local branch="${BASH_REMATCH[3]}"
        local path="${BASH_REMATCH[4]}"
        
        local api_url="https://api.github.com/repos/$user/$repo/contents/$path?ref=$branch"
        
        # 使用GitHub API获取文件SHA（支持Token）
        if [[ -n "$GITHUB_TOKEN" ]]; then
            curl -s -H "Authorization: token $GITHUB_TOKEN" "$api_url" | grep -o '"sha": "[^"]*' | cut -d'"' -f4
        else
            curl -s "$api_url" | grep -o '"sha": "[^"]*' | cut -d'"' -f4
        fi
    else
        echo ""
    fi
}

# 下载文件
download_file() {
    local filename="$1"
    local url="$2"
    local temp_file="$DOWNLOAD_DIR/$filename.tmp"
    local final_file="$DOWNLOAD_DIR/$filename"
    
    echo "下载: $filename"
    
    if curl -s -o "$temp_file" "$url"; then
        mv "$temp_file" "$final_file"
        echo "完成: $filename"
        return 0
    else
        rm -f "$temp_file"
        echo "失败: $filename"
        return 1
    fi
}

# 主检查函数
check_and_update_files() {
    echo "检查文件更新..."
    
    # 显示当前使用的认证方式
    if [[ -n "$GITHUB_TOKEN" ]]; then
        echo "使用GitHub Token认证"
    else
        echo "使用匿名访问"
    fi
    
    local updated_count=0
    local total_count=0
    
    for filename in "${!FILES_TO_MONITOR[@]}"; do
        local url="${FILES_TO_MONITOR[$filename]}"
        local local_file="$DOWNLOAD_DIR/$filename"
        
        ((total_count++))
        
        # 获取GitHub文件SHA
        local github_sha=$(get_github_sha "$url")
        
        if [[ -z "$github_sha" ]]; then
            echo "错误: 无法获取 $filename 的GitHub SHA"
            continue
        fi
        
        # 获取本地文件的Git SHA1哈希
        local local_sha=$(get_local_git_sha "$local_file")
        
        if [[ -z "$local_sha" ]]; then
            # 本地文件不存在，下载文件
            echo "下载新文件: $filename"
            if download_file "$filename" "$url"; then
                ((updated_count++))
            fi
        elif [[ "$local_sha" != "$github_sha" ]]; then
            # 哈希不匹配，需要更新
            echo "更新文件: $filename"
            if download_file "$filename" "$url"; then
                ((updated_count++))
            fi
        else
            # 文件已是最新
            echo "文件最新: $filename"
        fi
    done
    
    if [ $updated_count -eq 0 ]; then
        echo "所有文件都是最新版本"
    else
        echo "更新完成: $updated_count/$total_count 个文件已更新"
    fi
}

# 显示文件状态
show_status() {
    echo "文件状态:"
    echo "下载目录: $DOWNLOAD_DIR"
    
    if [[ -n "$GITHUB_TOKEN" ]]; then
        echo "认证: 使用GitHub Token"
    else
        echo "认证: 匿名访问"
    fi
    echo ""
    
    for filename in "${!FILES_TO_MONITOR[@]}"; do
        local url="${FILES_TO_MONITOR[$filename]}"
        local local_file="$DOWNLOAD_DIR/$filename"
        
        echo "文件: $filename"
        if [[ -f "$local_file" ]]; then
            local local_sha=$(get_local_git_sha "$local_file")
            local github_sha=$(get_github_sha "$url")
            
            if [[ -n "$local_sha" && -n "$github_sha" ]]; then
                if [[ "$local_sha" == "$github_sha" ]]; then
                    echo "  状态: 最新"
                else
                    echo "  状态: 需要更新"
                fi
            else
                echo "  状态: 无法验证"
            fi
        else
            echo "  状态: 未下载"
        fi
    done
}

# 主程序
main() {
    # 检查依赖
    check_dependencies
    
    # 确保下载目录存在
    ensure_download_dir
    
    case "${1:-}" in
        -s|--status)
            show_status
            ;;
        *)
            check_and_update_files
            ;;
    esac
}

main "$@"
EOF
/bin/bash ~/rss/github.sh