#!/bin/bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

OPENVPN_DIR="/etc/openvpn"
SERVER_DIR="${OPENVPN_DIR}/server"
CCD_DIR="${OPENVPN_DIR}/ccd"
CLIENT_DIR="${OPENVPN_DIR}/client"
SERVER_CONF="${SERVER_DIR}/server.conf"
EASYRSA_DIR="${SERVER_DIR}/easy-rsa"

ASSIGN_SOURCE="${SCRIPT_DIR}/assign_vpn_ip.sh"
CLIENT_SOURCE="${SCRIPT_DIR}/create_ovpn_client.sh"
INSTALL_SOURCE="${SCRIPT_DIR}/official-auto-install.sh"

ASSIGN_TARGET="${SERVER_DIR}/assign_vpn_ip.sh"
CLIENT_TARGET="${SERVER_DIR}/create_ovpn_client.sh"
INSTALL_TARGET="${SERVER_DIR}/official-auto-install.sh"
CLIENT_LINK="/usr/local/sbin/create_ovpn_client.sh"

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

deploy_file() {
  local source_file="$1"
  local target_file="$2"
  local mode="$3"

  install -m "$mode" "$source_file" "$target_file"
}

ensure_server_conf_has_ccd() {
  if [ ! -f "$SERVER_CONF" ]; then
    echo "OpenVPN server config not found: $SERVER_CONF" >&2
    exit 1
  fi

  if ! grep -Fqs 'client-config-dir /etc/openvpn/ccd' "$SERVER_CONF"; then
    printf '\nclient-config-dir /etc/openvpn/ccd\n' >> "$SERVER_CONF"
  fi
}

restart_openvpn() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 'openvpn-server@server.service' >/dev/null 2>&1; then
    systemctl restart openvpn-server@server.service
  fi
}

require_root "$@"

for required_file in "$ASSIGN_SOURCE" "$CLIENT_SOURCE" "$INSTALL_SOURCE"; do
  if [ ! -f "$required_file" ]; then
    echo "Required file not found: $required_file" >&2
    exit 1
  fi
done

if [ ! -f "$SERVER_CONF" ] || [ ! -d "$EASYRSA_DIR" ]; then
  bash "$INSTALL_SOURCE" --auto
fi

mkdir -p "$SERVER_DIR" "$CCD_DIR" "$CLIENT_DIR"

deploy_file "$INSTALL_SOURCE" "$INSTALL_TARGET" 700
deploy_file "$CLIENT_SOURCE" "$CLIENT_TARGET" 700
deploy_file "$ASSIGN_SOURCE" "$ASSIGN_TARGET" 700

chmod 700 "$CCD_DIR"
chmod 700 "$CLIENT_DIR"

ensure_server_conf_has_ccd
restart_openvpn

ln -sfn "$CLIENT_TARGET" "$CLIENT_LINK"

echo "OpenVPN install completed."
echo "Server config: $SERVER_CONF"
echo "CCD dir: $CCD_DIR"
echo "Client profiles dir: $CLIENT_DIR"
echo "Client creation command: $CLIENT_LINK <client-name>"
