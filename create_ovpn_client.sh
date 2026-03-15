#!/bin/bash
set -euo pipefail

CN="${1:?missing client name}"

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

CLIENT_DIR="${OPENVPN_CLIENT_DIR:-/etc/openvpn/client}"
CCD_DIR="/etc/openvpn/ccd"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root or with sudo." >&2
    echo "Example: sudo bash $0 <client name>" >&2
    exit 1
  fi
}

find_install_script() {
  if [ -n "${OPENVPN_INSTALL_SCRIPT:-}" ]; then
    printf '%s\n' "$OPENVPN_INSTALL_SCRIPT"
    return 0
  fi

  if [ -f "${SCRIPT_DIR}/openvpn_install_auto_setup.sh" ]; then
    printf '%s\n' "${SCRIPT_DIR}/openvpn_install_auto_setup.sh"
    return 0
  fi

  if [ -f "/root/openvpn_install_auto_setup.sh" ]; then
    printf '%s\n' "/root/openvpn_install_auto_setup.sh"
    return 0
  fi

  return 1
}

find_assign_script() {
  if [ -n "${OPENVPN_ASSIGN_SCRIPT:-}" ]; then
    printf '%s\n' "$OPENVPN_ASSIGN_SCRIPT"
    return 0
  fi

  if [ -f "${SCRIPT_DIR}/assign_vpn_ip.sh" ]; then
    printf '%s\n' "${SCRIPT_DIR}/assign_vpn_ip.sh"
    return 0
  fi

  if [ -f "/etc/openvpn/server/assign_vpn_ip.sh" ]; then
    printf '%s\n' "/etc/openvpn/server/assign_vpn_ip.sh"
    return 0
  fi

  return 1
}

require_root

INSTALL_SCRIPT="$(find_install_script || true)"
ASSIGN_SCRIPT="$(find_assign_script || true)"

if [ -z "$INSTALL_SCRIPT" ]; then
  echo "install script not found" >&2
  echo "Looked in:" >&2
  echo "  ${SCRIPT_DIR}/openvpn_install_auto_setup.sh" >&2
  echo "  /root/openvpn_install_auto_setup.sh" >&2
  echo "You can also set OPENVPN_INSTALL_SCRIPT." >&2
  exit 1
fi

if [ -z "$ASSIGN_SCRIPT" ]; then
  echo "assign script not found" >&2
  echo "Looked in:" >&2
  echo "  ${SCRIPT_DIR}/assign_vpn_ip.sh" >&2
  echo "  /etc/openvpn/server/assign_vpn_ip.sh" >&2
  echo "You can also set OPENVPN_ASSIGN_SCRIPT." >&2
  exit 1
fi

if [ ! -f "$INSTALL_SCRIPT" ]; then
  echo "install script not found: $INSTALL_SCRIPT" >&2
  exit 1
fi

if [ ! -x "$ASSIGN_SCRIPT" ]; then
  echo "assign script not found or not executable: $ASSIGN_SCRIPT" >&2
  exit 1
fi

mkdir -p "$CLIENT_DIR"
mkdir -p "$CCD_DIR"

bash "$INSTALL_SCRIPT" --addclient "$CN"
"$ASSIGN_SCRIPT" "$CN"

if [ -f "/root/${CN}.ovpn" ]; then
  mv "/root/${CN}.ovpn" "$CLIENT_DIR/${CN}.ovpn"
elif [ -f "${PWD}/${CN}.ovpn" ]; then
  mv "${PWD}/${CN}.ovpn" "$CLIENT_DIR/${CN}.ovpn"
elif [ -f "${SCRIPT_DIR}/${CN}.ovpn" ]; then
  mv "${SCRIPT_DIR}/${CN}.ovpn" "$CLIENT_DIR/${CN}.ovpn"
fi

echo "Created client cert, CCD, and profile for ${CN}"
echo "Install script: ${INSTALL_SCRIPT}"
echo "Assign script: ${ASSIGN_SCRIPT}"
echo "CCD: ${CCD_DIR}/${CN}"
echo "OVPN: ${CLIENT_DIR}/${CN}.ovpn"