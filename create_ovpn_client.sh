#!/bin/bash
set -euo pipefail

CN="${1:?missing client name}"

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

CLIENT_DIR="${OPENVPN_CLIENT_DIR:-/etc/openvpn/client}"
CCD_DIR="/etc/openvpn/ccd"

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

find_install_script() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${OPENVPN_INSTALL_SCRIPT:-}" ]; then
    printf '%s\n' "$OPENVPN_INSTALL_SCRIPT"
    return 0
  fi

  if [ -f "${SCRIPT_DIR}/official-auto-install.sh" ]; then
    printf '%s\n' "${SCRIPT_DIR}/official-auto-install.sh"
    return 0
  fi

  if [ -f "/etc/openvpn/server/official-auto-install.sh" ]; then
    printf '%s\n' "/etc/openvpn/server/official-auto-install.sh"
    return 0
  fi

  return 1
}

find_assign_script() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${OPENVPN_ASSIGN_SCRIPT:-}" ]; then
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

find_generated_profile() {
  local user_home=""

  if [ -n "${SUDO_USER:-}" ]; then
    user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
    if [ -n "$user_home" ] && [ -f "${user_home}/${CN}.ovpn" ]; then
      printf '%s\n' "${user_home}/${CN}.ovpn"
      return 0
    fi
  fi

  if [ -f "/root/${CN}.ovpn" ]; then
    printf '%s\n' "/root/${CN}.ovpn"
    return 0
  fi

  if [ -f "${PWD}/${CN}.ovpn" ]; then
    printf '%s\n' "${PWD}/${CN}.ovpn"
    return 0
  fi

  if [ -f "${SCRIPT_DIR}/${CN}.ovpn" ]; then
    printf '%s\n' "${SCRIPT_DIR}/${CN}.ovpn"
    return 0
  fi

  return 1
}

require_root "$@"

INSTALL_SCRIPT="$(find_install_script || true)"
ASSIGN_SCRIPT="$(find_assign_script || true)"

if [ -z "$INSTALL_SCRIPT" ]; then
  echo "install script not found" >&2
  echo "Looked in:" >&2
  echo "  ${SCRIPT_DIR}/official-auto-install.sh" >&2
  echo "  /etc/openvpn/server/official-auto-install.sh" >&2
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

PROFILE_SOURCE="$(find_generated_profile || true)"
if [ -z "$PROFILE_SOURCE" ]; then
  echo "client profile not found after creation: ${CN}.ovpn" >&2
  exit 1
fi

mv "$PROFILE_SOURCE" "$CLIENT_DIR/${CN}.ovpn"
chmod 600 "$CLIENT_DIR/${CN}.ovpn"

echo "Created client cert, CCD, and profile for ${CN}"
echo "Install script: ${INSTALL_SCRIPT}"
echo "Assign script: ${ASSIGN_SCRIPT}"
echo "CCD: ${CCD_DIR}/${CN}"
echo "OVPN: ${CLIENT_DIR}/${CN}.ovpn"
