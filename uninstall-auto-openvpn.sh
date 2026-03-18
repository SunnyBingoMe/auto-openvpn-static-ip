#!/bin/bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0")"

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
EXTRA_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-udp-tcp-extra.service"
LEGACY_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables.service"

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

cleanup_empty_dirs() {
  rmdir "$SERVER_DIR" >/dev/null 2>&1 || true
  rmdir "$OPENVPN_DIR" >/dev/null 2>&1 || true
}

require_root "$@"

keep_client_config=false
keep_server_config=false

if ask_yes_no "Keep existing clients-related configuration (ipp, ccd, certs, exported client files, etc.)?" "y"; then
  keep_client_config=true
fi

if ask_yes_no "Keep existing OpenVPN server configuration?" "y"; then
  keep_server_config=true
fi

stop_service_if_present openvpn-server@server.service
stop_service_if_present openvpn-server@server-udp.service
stop_service_if_present openvpn-server@server-tcp.service
stop_service_if_present openvpn-iptables-udp.service
stop_service_if_present openvpn-iptables-tcp.service
stop_service_if_present openvpn-iptables-udp-tcp-extra.service

remove_if_exists "$CLIENT_LINK"
remove_if_exists "$REVOKE_LINK"
remove_if_exists "$ASSIGN_TARGET"
remove_if_exists "$CLIENT_TARGET"
remove_if_exists "$REVOKE_TARGET"
remove_if_exists "$INSTALL_TARGET"
remove_if_exists "$UDP_FIREWALL_SERVICE"
remove_if_exists "$TCP_FIREWALL_SERVICE"
remove_if_exists "$EXTRA_FIREWALL_SERVICE"
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
  echo "Keeping existing clients-related configuration."
fi

if [ "$keep_server_config" = false ]; then
  remove_if_exists "$SERVER_CONF"
  remove_if_exists "$TCP_SERVER_CONF"
  remove_if_exists "$LEGACY_SERVER_CONF"
  remove_if_exists "$CLIENT_COMMON_FILE"
  remove_if_exists "$LEGACY_CLIENT_COMMON_FILE"
else
  echo "Keeping existing OpenVPN server configuration."
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

cleanup_empty_dirs

echo "OpenVPN uninstall completed."
