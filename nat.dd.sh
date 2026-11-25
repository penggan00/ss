#!/usr/bin/env bash
set +e

# 停止并禁用开机服务
if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now relay-forward.service
  rm -f /etc/systemd/system/relay-forward.service
  systemctl daemon-reload
fi

if command -v rc-service >/dev/null 2>&1; then
  rc-service relay-forward stop
  rc-update del relay-forward default
  rm -f /etc/init.d/relay-forward
fi

remove_family() {
  bin="$1"
  [ -x "$(command -v "$bin" 2>/dev/null)" ] || return 0

  for entry in \
    "nat PREROUTING RELAY_${2}_PRE" \
    "nat POSTROUTING RELAY_${2}_POST" \
    "filter FORWARD RELAY_${2}_FORWARD"
  do
    set -- $entry
    table="$1"
    parent="$2"
    chain="$3"

    while "$bin" -t "$table" -C "$parent" -j "$chain" 2>/dev/null; do
      "$bin" -t "$table" -D "$parent" -j "$chain"
    done

    "$bin" -t "$table" -F "$chain" 2>/dev/null
    "$bin" -t "$table" -X "$chain" 2>/dev/null
  done
}

remove_family iptables V4
remove_family ip6tables V6

rm -f /usr/local/sbin/relay-forward-apply
rm -f /etc/relay-forward/config
rmdir /etc/relay-forward 2>/dev/null
rm -f /etc/sysctl.d/99-relay-forward.conf

echo "已停止服务并清理脚本创建的转发规则。"
echo "请检查是否有其他程序也在使用内核转发。"