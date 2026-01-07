#!/bin/bash
# 功能: NodeScriptKit 安装和更新脚本

goos=$(uname -s | tr '[:upper:]' '[:lower:]')
goarch=$(uname -m)                       

echo "Current OS: $goos"
echo "Current Architecture: $goarch"

if [ "$goos" == "darwin" ]; then
    ext=""
elif [ "$goos" == "linux" ] || [ "$goos" == "freebsd" ]; then
    ext=""
else
    echo "Unsupported OS: $goos"
    exit 1
fi

if [ "$goarch" == "x86_64" ]; then
    arch="amd64"
elif [ "$goarch" == "i386" ]; then
    arch="386"
elif [ "$goarch" == "arm64" ]; then
    arch="arm64"
else
    echo "Unsupported Architecture: $goarch"
    exit 1
fi

BIN_VERSION="$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/NodeSeekDev/NskCore/releases/latest)"
BIN_VERSION=${BIN_VERSION##*/}
BIN_FILENAME="nskCore-$goos-$arch$ext"
BIN_URL="https://github.com/NodeSeekDev/NskCore/releases/download/$BIN_VERSION/$BIN_FILENAME"

curl -Lso /usr/bin/nskCore $BIN_URL
chmod u+x /usr/bin/nskCore

if tar --version 2>&1 | grep -qi 'busybox'; then
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache tar
    fi
fi

MENU_URL="$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/NodeSeekDev/NodeScriptKit/releases/latest)"
MENU_VERSION="${MENU_URL##*/}"

mkdir -p /etc/nsk/modules.d/default
mkdir -p /etc/nsk/modules.d/extend

cd /tmp
temp_dir=$(mktemp -d)
curl -sLo - $temp_download_file "https://github.com/NodeSeekDev/NodeScriptKit/archive/refs/tags/$MENU_VERSION.tar.gz" | \
    tar -xzv -C $temp_dir
cp $temp_dir/*/menu.toml /etc/nsk/config.toml
rm -rf /etc/nsk/modules.d/default/*  # Remove old scripts to prevent conflicts
cp $temp_dir/*/modules.d/* /etc/nsk/modules.d/default/

echo $MENU_VERSION > /etc/nsk/version

cp $temp_dir/*/nsk.sh /usr/bin/nsk
chmod u+x /usr/bin/nsk
[ -f "/usr/bin/n" ] || ln -s /usr/bin/nsk /usr/bin/n

echo -e "\e[1;32mnsk脚本安装成功啦，可以输入n或者nsk命令唤出菜单\e[0m"