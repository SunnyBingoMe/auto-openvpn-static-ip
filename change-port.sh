#!/bin/bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0")"

require_root() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    echo "This script requires root privileges and sudo is not available." >&2
    exit 1
  fi

  exec sudo bash "$SCRIPT_PATH" "$@"
}

require_root "$@"

OPENVPN_DIR="/etc/openvpn"
SERVER_DIR="${OPENVPN_DIR}/server"
UDP_SERVER_CONF="${SERVER_DIR}/server-udp.conf"
TCP_SERVER_CONF="${SERVER_DIR}/server-tcp.conf"
UDP_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-udp.service"
TCP_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-tcp.service"
TCP_UDP_EXCHANGE_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-tcp-udp-exchange-rules.service"
UDP_SERVICE="openvpn-server@server-udp.service"
TCP_SERVICE="openvpn-server@server-tcp.service"
INSTALL_SCRIPT="${SERVER_DIR}/install-auto-openvpn.sh"

usage() {
  cat <<'USAGE'
Usage: change_port.sh <udp-port> <tcp-port>

Example:
  sudo bash change_port.sh 50001 50002
USAGE
}

confirm_enter() {
  local prompt="$1"
  local reply

  read -r -p "$prompt [Enter 确认 / Ctrl+C 取消]: " reply
}

validate_port() {
  local label="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "${label} port must be an integer: ${value}" >&2
    exit 1
  fi

  if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    echo "${label} port must be between 1 and 65535: ${value}" >&2
    exit 1
  fi
}

ensure_exists() {
  local path="$1"

  if [ ! -f "$path" ]; then
    echo "Required file not found: $path" >&2
    exit 1
  fi
}

extract_server_value() {
  local conf_file="$1"
  local key="$2"

  awk -v key="$key" '$1 == key { print $2; exit }' "$conf_file"
}

update_port_line() {
  local conf_file="$1"
  local new_port="$2"

  if grep -Eq '^port[[:space:]]+[0-9]+' "$conf_file"; then
    sed -i "s/^port[[:space:]].*/port ${new_port}/" "$conf_file"
  else
    printf '\nport %s\n' "$new_port" >> "$conf_file"
  fi
}

backup_conf_file() {
  local conf_file="$1"
  local backup_file="${conf_file}.bak"
  local restore_steps_file="${conf_file}.restore.txt"

  cp -f "$conf_file" "$backup_file"
  cat > "$restore_steps_file" <<EOF
Manual restore commands for ${conf_file}:
cp -f "$backup_file" "$conf_file"
EOF
}

update_firewalld_ports() {
  local old_udp_port="$1"
  local new_udp_port="$2"
  local old_tcp_port="$3"
  local new_tcp_port="$4"

  if ! command -v firewall-cmd >/dev/null 2>&1; then
    return 0
  fi

  if ! systemctl is-active --quiet firewalld.service; then
    return 0
  fi

  if [ -n "$old_udp_port" ] && [ "$old_udp_port" != "$new_udp_port" ]; then
    firewall-cmd -q --remove-port="${old_udp_port}/udp" >/dev/null 2>&1 || true
    firewall-cmd -q --permanent --remove-port="${old_udp_port}/udp" >/dev/null 2>&1 || true
  fi

  if [ -n "$old_tcp_port" ] && [ "$old_tcp_port" != "$new_tcp_port" ]; then
    firewall-cmd -q --remove-port="${old_tcp_port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd -q --permanent --remove-port="${old_tcp_port}/tcp" >/dev/null 2>&1 || true
  fi

  firewall-cmd -q --add-port="${new_udp_port}/udp"
  firewall-cmd -q --permanent --add-port="${new_udp_port}/udp"
  firewall-cmd -q --add-port="${new_tcp_port}/tcp"
  firewall-cmd -q --permanent --add-port="${new_tcp_port}/tcp"
}

update_tcp_selinux_port() {
  local old_tcp_port="$1"
  local new_tcp_port="$2"

  if ! command -v sestatus >/dev/null 2>&1 || ! command -v semanage >/dev/null 2>&1; then
    return 0
  fi

  if ! sestatus 2>/dev/null | grep -q 'Current mode:.*enforcing'; then
    return 0
  fi

  if [ "$new_tcp_port" != "1194" ]; then
    if ! semanage port -l | grep -Eq "^openvpn_port_t[[:space:]]+tcp[[:space:]].*(^|[^0-9])${new_tcp_port}([^0-9]|$)"; then
      semanage port -a -t openvpn_port_t -p tcp "$new_tcp_port" >/dev/null 2>&1 \
        || semanage port -m -t openvpn_port_t -p tcp "$new_tcp_port" >/dev/null 2>&1
    fi
  fi

  if [ -n "$old_tcp_port" ] && [ "$old_tcp_port" != "$new_tcp_port" ] && [ "$old_tcp_port" != "1194" ]; then
    if semanage port -l | grep -Eq "^openvpn_port_t[[:space:]]+tcp[[:space:]].*(^|[^0-9])${old_tcp_port}([^0-9]|$)"; then
      semanage port -d -t openvpn_port_t -p tcp "$old_tcp_port" >/dev/null 2>&1 || true
    fi
  fi
}

refresh_iptables_units() {
  if [ ! -f "$INSTALL_SCRIPT" ]; then
    return 0
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld.service; then
    return 0
  fi

  OPENVPN_INSTALL_SCRIPT="${SERVER_DIR}/to-get-from-hwdsl2.sh" \
  OPENVPN_ASSIGN_SCRIPT="${SERVER_DIR}/to-assign-ip-to-client.sh" \
    bash "$INSTALL_SCRIPT" >/dev/null 2>&1
}

restart_runtime_services() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found; please restart OpenVPN services manually." >&2
    exit 1
  fi

  systemctl daemon-reload

  if [ -f "$UDP_FIREWALL_SERVICE" ]; then
    systemctl enable --now openvpn-iptables-udp.service >/dev/null 2>&1 || true
  fi

  if [ -f "$TCP_FIREWALL_SERVICE" ]; then
    systemctl enable --now openvpn-iptables-tcp.service >/dev/null 2>&1 || true
  fi

  if [ -f "$TCP_UDP_EXCHANGE_FIREWALL_SERVICE" ]; then
    systemctl enable --now openvpn-iptables-tcp-udp-exchange-rules.service >/dev/null 2>&1 || true
  fi

  systemctl restart "$UDP_SERVICE"
  systemctl restart "$TCP_SERVICE"
}

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 1
fi

UDP_PORT="$1"
TCP_PORT="$2"

validate_port "UDP" "$UDP_PORT"
validate_port "TCP" "$TCP_PORT"
ensure_exists "$UDP_SERVER_CONF"
ensure_exists "$TCP_SERVER_CONF"

OLD_UDP_PORT="$(extract_server_value "$UDP_SERVER_CONF" port)"
OLD_TCP_PORT="$(extract_server_value "$TCP_SERVER_CONF" port)"
OLD_UDP_PORT="${OLD_UDP_PORT:-1194}"
OLD_TCP_PORT="${OLD_TCP_PORT:-$OLD_UDP_PORT}"

printf '即将修改 OpenVPN 监听端口：UDP:%s ; TCP:%s ； 回车立即修改并重启生效。\n' "$UDP_PORT" "$TCP_PORT"
if [ "$UDP_PORT" -lt 50000 ] || [ "$TCP_PORT" -lt 50000 ]; then
  printf '建议使用 50000 以上端口号。\n'
fi
confirm_enter "请确认新的 UDP 和 TCP 端口号"

backup_conf_file "$UDP_SERVER_CONF"
backup_conf_file "$TCP_SERVER_CONF"
update_port_line "$UDP_SERVER_CONF" "$UDP_PORT"
update_port_line "$TCP_SERVER_CONF" "$TCP_PORT"
update_firewalld_ports "$OLD_UDP_PORT" "$UDP_PORT" "$OLD_TCP_PORT" "$TCP_PORT"
update_tcp_selinux_port "$OLD_TCP_PORT" "$TCP_PORT"
refresh_iptables_units

printf '端口配置已改为 UDP:%s ; TCP：%s; 正在应用变更并重启服务使其生效\n' "$UDP_PORT" "$TCP_PORT"
echo '如有已分发给客户端的 .ovpn 文件，请同步更新其中的 remote 端口。'

restart_runtime_services

echo "OpenVPN services restarted successfully."
echo "Current listen ports: UDP ${UDP_PORT}, TCP ${TCP_PORT}"
