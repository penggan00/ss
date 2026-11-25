#!/usr/bin/env bash
set -euo pipefail

IP4=""
IP6=""
PORTS=""

usage() {
  cat <<'EOF'
用法:
  sudo bash nat.sh -4 IPv4 [-6 IPv6] -p 端口/协议[,端口/协议...]

选项:
  -4 <IPv4>       设置落地机 IPv4
  -6 <IPv6>       设置落地机 IPv6
  -p <规则列表>   格式：51210/udp,51211/udp,60000/tcp
  -h, --help      显示帮助

示例:
  sudo bash nat.sh -4 203.0.113.101 -p 51210/udp,51211/udp,60000/tcp
  sudo bash nat.sh -4 203.0.113.101 -6 2001:db8::10 -p 51210/udp,60000/tcp
EOF
}

while (($#)); do
  case "$1" in
    -4)
      [[ $# -ge 2 ]] || { echo "错误：-4 缺少地址"; exit 1; }
      IP4="$2"
      shift 2
      ;;
    -6)
      [[ $# -ge 2 ]] || { echo "错误：-6 缺少地址"; exit 1; }
      IP6="$2"
      shift 2
      ;;
    -p|--ports)
      [[ $# -ge 2 ]] || { echo "错误：-p 缺少规则"; exit 1; }
      PORTS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "错误：未知参数：$1"
      usage
      exit 1
      ;;
  esac
done

[[ -n "$IP4" || -n "$IP6" ]] ||
  { echo "错误：必须使用 -4、-6 或同时使用两者指定落地机地址"; exit 1; }

[[ -n "$PORTS" ]] ||
  { echo "错误：必须使用 -p，例如 -p 51210/udp,60000/tcp"; exit 1; }

[[ $EUID -eq 0 ]] ||
  { echo "错误：请使用 root 权限运行"; exit 1; }

# 校验端口和协议格式。
if [[ ! "$PORTS" =~ ^[0-9]+/(tcp|udp)(,[0-9]+/(tcp|udp))*$ ]]; then
  echo "错误：-p 格式无效，请使用端口/协议，例如 51210/udp,60000/tcp"
  exit 1
fi

IFS=',' read -r -a RULE_ARRAY <<< "$PORTS"
declare -A RULE_SET=()
NORMALIZED_RULES=()

for rule in "${RULE_ARRAY[@]}"; do
  port="${rule%/*}"
  proto="${rule##*/}"

  if ((10#$port < 1 || 10#$port > 65535)); then
    echo "错误：端口必须在 1–65535 范围内：$port"
    exit 1
  fi

  port="$((10#$port))"
  normalized="$port/$proto"

  if [[ -n "${RULE_SET[$normalized]+x}" ]]; then
    echo "错误：重复规则：$normalized"
    exit 1
  fi

  RULE_SET["$normalized"]=1
  NORMALIZED_RULES+=("$normalized")
done

PORTS="$(IFS=,; echo "${NORMALIZED_RULES[*]}")"

detect_distro() {
  if [[ -f /etc/alpine-release ]]; then
    echo alpine
  elif command -v apt-get >/dev/null 2>&1; then
    echo debian
  elif command -v dnf >/dev/null 2>&1; then
    echo fedora
  elif command -v yum >/dev/null 2>&1; then
    echo redhat
  elif command -v zypper >/dev/null 2>&1; then
    echo opensuse
  else
    echo unknown
  fi
}

DISTRO="$(detect_distro)"

if ! command -v python3 >/dev/null 2>&1 ||
   ! command -v iptables >/dev/null 2>&1 ||
   ! command -v sysctl >/dev/null 2>&1 ||
   { [[ -n "$IP6" ]] && ! command -v ip6tables >/dev/null 2>&1; }; then
  echo "检测到缺少依赖，正在自动安装..."

  case "$DISTRO" in
    alpine)
      apk add --no-cache python3 iptables procps kmod
      ;;
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y python3 iptables procps kmod
      ;;
    fedora)
      dnf install -y python3 iptables procps-ng kmod
      ;;
    redhat)
      yum install -y python3 iptables procps-ng kmod
      ;;
    opensuse)
      zypper --non-interactive install -y python3 iptables procps kmod
      ;;
    *)
      echo "错误：无法识别包管理器"
      echo "请手动安装 python3、iptables、sysctl 和 kmod"
      exit 1
      ;;
  esac
fi

python3 - "$IP4" "$IP6" <<'PY'
import ipaddress
import sys

ip4 = sys.argv[1]
ip6 = sys.argv[2]

if ip4:
    try:
        ipaddress.IPv4Address(ip4)
    except ValueError:
        sys.exit(f"错误：-4 地址无效：{ip4}")

if ip6:
    try:
        ipaddress.IPv6Address(ip6)
    except ValueError:
        sys.exit(f"错误：-6 地址无效：{ip6}")
PY

mkdir -p /etc/relay-forward
cat > /etc/relay-forward/config <<EOF
IP4='$IP4'
IP6='$IP6'
PORTS='$PORTS'
EOF
chmod 600 /etc/relay-forward/config

cat > /usr/local/sbin/relay-forward-apply <<'APPLY'
#!/usr/bin/env bash
set -euo pipefail
source /etc/relay-forward/config

sysctl -w net.ipv4.ip_forward=1 >/dev/null
[[ -z "$IP6" ]] ||
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

setup_family() {
  local iptables_bin="$1"
  local family="$2"
  local target="$3"

  local pre="RELAY_${family}_PRE"
  local post="RELAY_${family}_POST"
  local forward="RELAY_${family}_FORWARD"

  "$iptables_bin" -t nat -N "$pre" 2>/dev/null || true
  "$iptables_bin" -t nat -N "$post" 2>/dev/null || true
  "$iptables_bin" -t filter -N "$forward" 2>/dev/null || true

  "$iptables_bin" -t nat -F "$pre"
  "$iptables_bin" -t nat -F "$post"
  "$iptables_bin" -t filter -F "$forward"

  "$iptables_bin" -t nat -C PREROUTING -j "$pre" 2>/dev/null ||
    "$iptables_bin" -t nat -I PREROUTING 1 -j "$pre"

  "$iptables_bin" -t nat -C POSTROUTING -j "$post" 2>/dev/null ||
    "$iptables_bin" -t nat -I POSTROUTING 1 -j "$post"

  "$iptables_bin" -t filter -C FORWARD -j "$forward" 2>/dev/null ||
    "$iptables_bin" -t filter -I FORWARD 1 -j "$forward"

  "$iptables_bin" -t filter -A "$forward" \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  IFS=',' read -r -a rules <<< "$PORTS"

  for rule in "${rules[@]}"; do
    proto="${rule##*/}"
    port="${rule%/*}"
    destination="$target:$port"

    [[ "$family" != "V6" ]] ||
      destination="[$target]:$port"

    "$iptables_bin" -t nat -A "$pre" \
      -p "$proto" --dport "$port" \
      -j DNAT --to-destination "$destination"

    "$iptables_bin" -t nat -A "$post" \
      -p "$proto" -d "$target" --dport "$port" \
      -j MASQUERADE

    "$iptables_bin" -t filter -A "$forward" \
      -p "$proto" -d "$target" --dport "$port" \
      -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
  done
}

[[ -z "$IP4" ]] ||
  setup_family iptables V4 "$IP4"

[[ -z "$IP6" ]] ||
  setup_family ip6tables V6 "$IP6"
APPLY
chmod 755 /usr/local/sbin/relay-forward-apply

mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-relay-forward.conf <<EOF
net.ipv4.ip_forward=1
EOF
if [[ -n "$IP6" ]]; then
  cat >> /etc/sysctl.d/99-relay-forward.conf <<'EOF'
net.ipv6.conf.all.forwarding=1
EOF
fi
sysctl -p /etc/sysctl.d/99-relay-forward.conf >/dev/null

if [[ -f /etc/alpine-release ]]; then
  touch /etc/sysctl.conf
  sed -i '/^net\.ipv4\.ip_forward=/d' /etc/sysctl.conf
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

  if [[ -n "$IP6" ]]; then
    sed -i '/^net\.ipv6\.conf\.all\.forwarding=/d' /etc/sysctl.conf
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
  fi

  cat > /etc/init.d/relay-forward <<'OPENRC'
#!/sbin/openrc-run
description="Relay IPv4 and IPv6 port forwarding"

depend() {
  need net
  after firewall
}

start() {
  ebegin "Applying relay forwarding rules"
  /usr/local/sbin/relay-forward-apply
  eend $?
}

stop() {
  eend 0
}
OPENRC
  chmod 755 /etc/init.d/relay-forward
  rc-update add relay-forward default >/dev/null 2>&1 || true
  rc-service relay-forward restart >/dev/null 2>&1 ||
    rc-service relay-forward start >/dev/null 2>&1
else
  cat > /etc/systemd/system/relay-forward.service <<'SYSTEMD'
[Unit]
Description=Relay IPv4 and IPv6 port forwarding
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/relay-forward-apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SYSTEMD
  chmod 644 /etc/systemd/system/relay-forward.service
  systemctl daemon-reload
  systemctl enable --now relay-forward.service
fi

/usr/local/sbin/relay-forward-apply

echo
echo "转发规则已安装并启用开机恢复"
[[ -z "$IP4" ]] || echo "IPv4 落地机：$IP4"
[[ -z "$IP6" ]] || echo "IPv6 落地机：$IP6"

echo "转发规则："
for rule in "${NORMALIZED_RULES[@]}"; do
  echo "  $rule"
done