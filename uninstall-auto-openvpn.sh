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
UDP_CCD_DIR="${OPENVPN_DIR}/ccd-udp"
CCD_DIR="${OPENVPN_DIR}/ccd"
TCP_CCD_DIR="${OPENVPN_DIR}/ccd-tcp"
CLIENT_DIR="${OPENVPN_DIR}/client-udp-tcp"
EASYRSA_DIR="${SERVER_DIR}/easy-rsa"
UDP_IPP_FILE="${SERVER_DIR}/ipp-udp.txt"
TCP_IPP_FILE="${SERVER_DIR}/ipp-tcp.txt"
SERVER_CONF="${SERVER_DIR}/server-udp.conf"
TCP_SERVER_CONF="${SERVER_DIR}/server-tcp.conf"
LEGACY_SERVER_CONF="${SERVER_DIR}/server.conf"
CLIENT_COMMON_FILE="${SERVER_DIR}/client-common-udp-tcp.txt"
LEGACY_CLIENT_COMMON_FILE="${SERVER_DIR}/client-common.txt"
ASSIGN_TARGET="${SERVER_DIR}/to-assign-ip-to-client.sh"
CLIENT_TARGET="${SERVER_DIR}/auto-openvpn-add-client.sh"
REVOKE_TARGET="${SERVER_DIR}/auto-openvpn-revoke-client.sh"
INSTALL_TARGET="${SERVER_DIR}/to-get-from-hwdsl2.sh"
CLIENT_LINK="/usr/local/sbin/auto-openvpn-add-client.sh"
REVOKE_LINK="/usr/local/sbin/auto-openvpn-revoke-client.sh"
UDP_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-udp.service"
TCP_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-tcp.service"
TCP_UDP_EXCHANGE_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-tcp-udp-exchange-rules.service"
LEGACY_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables.service"
UPSTREAM_LIMITNPROC_DROPIN="/etc/systemd/system/openvpn-server@server.service.d/disable-limitnproc.conf"
UPSTREAM_SYSCTL_FORWARD="/etc/sysctl.d/99-openvpn-forward.conf"
UPSTREAM_SYSCTL_OPTIMIZE="/etc/sysctl.d/99-openvpn-optimize.conf"
LEGACY_IPP_FILE="${OPENVPN_DIR}/ipp.txt"
RCLOCAL_FILE="/etc/rc.local"

ask_yes_no() {
  local prompt="$1"
  local default_answer="$2"
  local reply

  while true; do
    if [ "$default_answer" = "y" ]; then
      read -r -p "$prompt [Y/n]: " reply
      reply="${reply:-Y}"
    else
      read -r -p "$prompt [y/N]: " reply
      reply="${reply:-N}"
    fi

    case "$reply" in
      [Yy]|[Yy][Ee][Ss])
        return 0
        ;;
      [Nn]|[Nn][Oo])
        return 1
        ;;
      *)
        echo "Please answer yes or no."
        ;;
    esac
  done
}

remove_if_exists() {
  local target="$1"

  if [ -e "$target" ] || [ -L "$target" ]; then
    rm -rf "$target"
  fi
}

stop_service_if_present() {
  local service_name="$1"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$service_name" >/dev/null 2>&1 || true
  fi
}

remove_rclocal_openvpn_line() {
  local ipt_cmd="systemctl restart openvpn-iptables.service"

  if [ -f "$RCLOCAL_FILE" ] && grep -qs "$ipt_cmd" "$RCLOCAL_FILE"; then
    sed --follow-symlinks -i "/^$ipt_cmd/d" "$RCLOCAL_FILE"
  fi
}

remove_firewalld_rules_if_requested() {
  local udp_port
  local tcp_port

  command -v firewall-cmd >/dev/null 2>&1 || return 0
  systemctl is-active --quiet firewalld.service || return 0

  if ! ask_yes_no "是否删除 firewalld 中由 OpenVPN 安装写入的端口、trusted source 和 NAT 规则？" "y"; then
    return 0
  fi

  udp_port="$(awk '$1 == "port" { print $2; exit }' "$SERVER_CONF" 2>/dev/null || true)"
  tcp_port="$(awk '$1 == "port" { print $2; exit }' "$TCP_SERVER_CONF" 2>/dev/null || true)"
  [ -n "$udp_port" ] || udp_port=1194
  [ -n "$tcp_port" ] || tcp_port="$udp_port"

  firewall-cmd -q --remove-port="${udp_port}/udp" >/dev/null 2>&1 || true
  firewall-cmd -q --permanent --remove-port="${udp_port}/udp" >/dev/null 2>&1 || true
  firewall-cmd -q --remove-port="${tcp_port}/tcp" >/dev/null 2>&1 || true
  firewall-cmd -q --permanent --remove-port="${tcp_port}/tcp" >/dev/null 2>&1 || true

  firewall-cmd -q --zone=trusted --remove-source="172.22.0.0/16" >/dev/null 2>&1 || true
  firewall-cmd -q --permanent --zone=trusted --remove-source="172.22.0.0/16" >/dev/null 2>&1 || true
  firewall-cmd -q --zone=trusted --remove-source="172.23.0.0/16" >/dev/null 2>&1 || true
  firewall-cmd -q --permanent --zone=trusted --remove-source="172.23.0.0/16" >/dev/null 2>&1 || true
  firewall-cmd -q --zone=trusted --remove-source="fddd:1194:1194:1194::/64" >/dev/null 2>&1 || true
  firewall-cmd -q --permanent --zone=trusted --remove-source="fddd:1194:1194:1194::/64" >/dev/null 2>&1 || true

  firewall-cmd -q --direct --remove-rule ipv4 nat POSTROUTING 0 -s 172.22.0.0/16 ! -d 172.22.0.0/16 -j MASQUERADE >/dev/null 2>&1 || true
  firewall-cmd -q --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s 172.22.0.0/16 ! -d 172.22.0.0/16 -j MASQUERADE >/dev/null 2>&1 || true
  firewall-cmd -q --direct --remove-rule ipv4 nat POSTROUTING 0 -s 172.22.0.0/16 -d 172.23.0.0/16 -j RETURN >/dev/null 2>&1 || true
  firewall-cmd -q --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s 172.22.0.0/16 -d 172.23.0.0/16 -j RETURN >/dev/null 2>&1 || true
  firewall-cmd -q --direct --remove-rule ipv4 nat POSTROUTING 0 -s 172.23.0.0/16 -d 172.22.0.0/16 -j RETURN >/dev/null 2>&1 || true
  firewall-cmd -q --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s 172.23.0.0/16 -d 172.22.0.0/16 -j RETURN >/dev/null 2>&1 || true
  firewall-cmd -q --direct --remove-rule ipv4 nat POSTROUTING 1 -s 172.22.0.0/16 ! -d 172.22.0.0/16 ! -d 172.23.0.0/16 -j MASQUERADE >/dev/null 2>&1 || true
  firewall-cmd -q --permanent --direct --remove-rule ipv4 nat POSTROUTING 1 -s 172.22.0.0/16 ! -d 172.22.0.0/16 ! -d 172.23.0.0/16 -j MASQUERADE >/dev/null 2>&1 || true
  firewall-cmd -q --direct --remove-rule ipv4 nat POSTROUTING 1 -s 172.23.0.0/16 ! -d 172.22.0.0/16 ! -d 172.23.0.0/16 -j MASQUERADE >/dev/null 2>&1 || true
  firewall-cmd -q --permanent --direct --remove-rule ipv4 nat POSTROUTING 1 -s 172.23.0.0/16 ! -d 172.22.0.0/16 ! -d 172.23.0.0/16 -j MASQUERADE >/dev/null 2>&1 || true
  firewall-cmd -q --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j MASQUERADE >/dev/null 2>&1 || true
  firewall-cmd -q --permanent --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j MASQUERADE >/dev/null 2>&1 || true
}

remove_selinux_port_if_requested() {
  local tcp_port

  command -v sestatus >/dev/null 2>&1 || return 0
  command -v semanage >/dev/null 2>&1 || return 0

  if ! sestatus 2>/dev/null | grep -q 'Current mode:.*enforcing'; then
    return 0
  fi

  tcp_port="$(awk '$1 == "port" { print $2; exit }' "$TCP_SERVER_CONF" 2>/dev/null || true)"
  [ -n "$tcp_port" ] || return 0
  [ "$tcp_port" != "1194" ] || return 0

  if ! semanage port -l | grep -Eq "^openvpn_port_t[[:space:]]+tcp[[:space:]].*(^|[^0-9])${tcp_port}([^0-9]|$)"; then
    return 0
  fi

  if ask_yes_no "是否删除 SELinux 中为 OpenVPN TCP 端口 ${tcp_port} 添加的放行规则？" "y"; then
    semanage port -d -t openvpn_port_t -p tcp "$tcp_port" >/dev/null 2>&1 || true
  fi
}

cleanup_empty_dirs() {
  rmdir "$SERVER_DIR" >/dev/null 2>&1 || true
  rmdir "$OPENVPN_DIR" >/dev/null 2>&1 || true
}

is_dir_non_empty() {
  local dir_path="$1"

  [ -d "$dir_path" ] || return 1

  if find "$dir_path" -mindepth 1 -maxdepth 1 | read -r _; then
    return 0
  fi

  return 1
}

keep_client_config=false
keep_server_config=false

if ! ask_yes_no "是否删除现有 clients 相关配置（ipp、ccd、cert 等）？" "y"; then
  keep_client_config=true
fi

if ! ask_yes_no "是否删除 OpenVPN server 现有配置？" "y"; then
  keep_server_config=true
fi

stop_service_if_present openvpn-server@server.service
stop_service_if_present openvpn-server@server-udp.service
stop_service_if_present openvpn-server@server-tcp.service
stop_service_if_present openvpn-iptables-udp.service
stop_service_if_present openvpn-iptables-tcp.service
stop_service_if_present openvpn-iptables-tcp-udp-exchange-rules.service

remove_if_exists "$CLIENT_LINK"
remove_if_exists "$REVOKE_LINK"
remove_if_exists "$ASSIGN_TARGET"
remove_if_exists "$CLIENT_TARGET"
remove_if_exists "$REVOKE_TARGET"
remove_if_exists "$INSTALL_TARGET"
remove_if_exists "$UDP_FIREWALL_SERVICE"
remove_if_exists "$TCP_FIREWALL_SERVICE"
remove_if_exists "$TCP_UDP_EXCHANGE_FIREWALL_SERVICE"
remove_if_exists "$LEGACY_FIREWALL_SERVICE"

if [ "$keep_client_config" = false ]; then
  remove_if_exists "$UDP_CCD_DIR"
  remove_if_exists "$TCP_CCD_DIR"
  remove_if_exists "$CCD_DIR"
  remove_if_exists "$CLIENT_DIR"
  remove_if_exists "$UDP_IPP_FILE"
  remove_if_exists "$TCP_IPP_FILE"
  remove_if_exists "$EASYRSA_DIR"
else
  echo "保留现有 clients 相关配置。"
fi

if [ "$keep_server_config" = false ]; then
  remove_if_exists "$SERVER_CONF"
  remove_if_exists "$TCP_SERVER_CONF"
  remove_if_exists "$LEGACY_SERVER_CONF"
  remove_if_exists "$CLIENT_COMMON_FILE"
  remove_if_exists "$LEGACY_CLIENT_COMMON_FILE"
else
  echo "保留现有 OpenVPN server 配置。"
fi

if ask_yes_no "是否删除上游 OpenVPN 写入的系统调优文件和服务 drop-in（sysctl、disable-limitnproc）？" "y"; then
  remove_if_exists "$UPSTREAM_LIMITNPROC_DROPIN"
  remove_if_exists "$UPSTREAM_SYSCTL_FORWARD"
  remove_if_exists "$UPSTREAM_SYSCTL_OPTIMIZE"
fi

if ask_yes_no "是否删除旧版 OpenVPN 的 ipp 记录文件 ${LEGACY_IPP_FILE}？" "y"; then
  remove_if_exists "$LEGACY_IPP_FILE"
fi

if ask_yes_no "是否删除 /etc/rc.local 中由 OpenVPN 安装写入的启动规则？" "y"; then
  remove_rclocal_openvpn_line
fi

remove_firewalld_rules_if_requested
remove_selinux_port_if_requested

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

if is_dir_non_empty "$OPENVPN_DIR"; then
  if ask_yes_no "$OPENVPN_DIR NOT empty! 非空！确定删除么？" "y"; then
    remove_if_exists "$OPENVPN_DIR"
  fi
fi

cleanup_empty_dirs

echo "OpenVPN uninstall completed."
