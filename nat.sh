#!/usr/bin/env bash
set -euo pipefail

IP4=""
IP6=""
PORTS=""
HY_PORT=""
VMS_PORT=""
HY_PROTO="udp"
VMS_PROTO="tcp"

usage() {
  cat <<'EOF'
用法:
  bash nat.sh -4 IPv4 [-6 IPv6] -p HY端口,VMess端口 [选项]

选项:
  -4 <IPv4>          设置落地机 IPv4
  -6 <IPv6>          设置落地机 IPv6
  -p <端口列表>      格式：HY端口,VMess端口
  --hy-port <端口>   单独指定 HY 端口
  --hy-proto <协议>  HY 协议：tcp 或 udp，默认 udp
  --vms-port <端口>  单独指定 VMess 端口
  --vms-proto <协议> VMess 协议：tcp 或 udp，默认 tcp
  -h, --help         显示帮助

示例:
  curl -fsSL 脚本地址 | sudo bash -s -- -4 203.0.113.10 -p 51200,51201
  curl -fsSL 脚本地址 | sudo bash -s -- -4 203.0.113.10 -6 2001:db8::10 -p 51200,51201
  curl -fsSL 脚本地址 | sudo bash -s -- -6 2001:db8::10 -p 51200,51201
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
      [[ $# -ge 2 ]] || { echo "错误：-p 缺少端口"; exit 1; }
      PORTS="$2"
      shift 2
      ;;
    --hy-port)
      [[ $# -ge 2 ]] || { echo "错误：--hy-port 缺少端口"; exit 1; }
      HY_PORT="$2"
      shift 2
      ;;
    --hy-proto)
      [[ $# -ge 2 ]] || { echo "错误：--hy-proto 缺少协议"; exit 1; }
      HY_PROTO="$2"
      shift 2
      ;;
    --vms-port)
      [[ $# -ge 2 ]] || { echo "错误：--vms-port 缺少端口"; exit 1; }
      VMS_PORT="$2"
      shift 2
      ;;
    --vms-proto)
      [[ $# -ge 2 ]] || { echo "错误：--vms-proto 缺少协议"; exit 1; }
      VMS_PROTO="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "错误：未知参数 $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$IP4" && -z "$IP6" ]]; then
  echo "错误：必须使用 -4、-6 或同时使用两者指定落地机地址"
  usage
  exit 1
fi

if [[ -z "$PORTS" && -z "$HY_PORT" && -z "$VMS_PORT" ]]; then
  echo "错误：必须使用 -p 传入端口，例如 -p 51200,51201"
  usage
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "错误：请使用 root 权限运行"
  exit 1
fi

validate_port() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[0-9]+$ ]] ||
     ((10#$value < 1 || 10#$value > 65535)); then
    echo "错误：$name 的端口无效：$value"
    exit 1
  fi
}

validate_proto() {
  local name="$1"
  local value="$2"

  if [[ "$value" != "tcp" && "$value" != "udp" ]]; then
    echo "错误：$name 协议只能是 tcp 或 udp"
    exit 1
  fi
}

if [[ -n "$PORTS" ]]; then
  IFS=',' read -r -a PORT_ARRAY <<< "$PORTS"

  if ((${#PORT_ARRAY[@]} != 2)); then
    echo "错误：-p 需要恰好两个端口，例如 -p 51200,51201"
    exit 1
  fi

  HY_PORT="${HY_PORT:-${PORT_ARRAY[0]}}"
  VMS_PORT="${VMS_PORT:-${PORT_ARRAY[1]}}"
fi

validate_port "HY_PORT" "$HY_PORT"
validate_port "VMS_PORT" "$VMS_PORT"
validate_proto "HY_PROTO" "$HY_PROTO"
validate_proto "VMS_PROTO" "$VMS_PROTO"

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

install_packages() {
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
}

NEED_INSTALL=0
for cmd in python3 iptables sysctl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    NEED_INSTALL=1
  fi
done

if [[ -n "$IP6" ]] && ! command -v ip6tables >/dev/null 2>&1; then
  NEED_INSTALL=1
fi

if ((NEED_INSTALL)); then
  install_packages
fi

for cmd in python3 iptables sysctl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "错误：安装后仍缺少命令 $cmd"
    exit 1
  fi
done

if [[ -n "$IP6" ]] && ! command -v ip6tables >/dev/null 2>&1; then
  echo "错误：IPv6 转发需要 ip6tables，但安装后仍未找到"
  exit 1
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
chmod 755 /etc/relay-forward

cat > /etc/relay-forward/config <<EOF
IP4='$IP4'
IP6='$IP6'
HY_PORT='$HY_PORT'
VMS_PORT='$VMS_PORT'
HY_PROTO='$HY_PROTO'
VMS_PROTO='$VMS_PROTO'
EOF
chmod 600 /etc/relay-forward/config

cat > /usr/local/sbin/relay-forward-apply <<'APPLY'
#!/usr/bin/env bash
set -euo pipefail
source /etc/relay-forward/config

sysctl -w net.ipv4.ip_forward=1 >/dev/null
if [[ -n "$IP6" ]]; then
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
fi

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

  forward_port() {
    local proto="$1"
    local port="$2"
    local destination="$target:$port"

    if [[ "$family" == "V6" ]]; then
      destination="[$target]:$port"
    fi

    "$iptables_bin" -t nat -A "$pre" \
      -p "$proto" --dport "$port" \
      -j DNAT --to-destination "$destination"

    "$iptables_bin" -t nat -A "$post" \
      -p "$proto" -d "$target" --dport "$port" \
      -j MASQUERADE

    "$iptables_bin" -t filter -A "$forward" \
      -p "$proto" -d "$target" --dport "$port" \
      -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
  }

  forward_port "$HY_PROTO" "$HY_PORT"
  forward_port "$VMS_PROTO" "$VMS_PORT"
}

if [[ -n "$IP4" ]]; then
  setup_family iptables V4 "$IP4"
fi

if [[ -n "$IP6" ]]; then
  setup_family ip6tables V6 "$IP6"
fi
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
chmod 644 /etc/sysctl.d/99-relay-forward.conf
sysctl -p /etc/sysctl.d/99-relay-forward.conf >/dev/null

if [[ -f /etc/alpine-release ]]; then
  cat >> /etc/sysctl.conf.tmp 2>/dev/null <<EOF
EOF

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
echo "HY:     $HY_PROTO/$HY_PORT"
echo "VMess:  $VMS_PROTO/$VMS_PORT"

if [[ -n "$IP4" ]]; then
  echo "IPv4:   $IP4"
fi
if [[ -n "$IP6" ]]; then
  echo "IPv6:   $IP6"
fi