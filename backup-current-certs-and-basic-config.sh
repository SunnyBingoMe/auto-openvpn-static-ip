#!/bin/bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

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
PWD_AUTH_DIR="${SERVER_DIR}/client-pwd-auth"
BACKUP_NAME_DEFAULT="current-certs-and-basic-config-$(date +%F).tgz"
OUTPUT_PATH="${1:-${SCRIPT_DIR}/${BACKUP_NAME_DEFAULT}}"

ensure_exists() {
  local path="$1"

  if [ ! -e "$path" ]; then
    echo "Required path not found: $path" >&2
    exit 1
  fi
}

ensure_parent_dir() {
  local output_file="$1"
  local parent_dir

  parent_dir="$(dirname "$output_file")"
  if [ ! -d "$parent_dir" ]; then
    echo "Output directory not found: $parent_dir" >&2
    exit 1
  fi
}

build_manifest() {
  local paths=(
    "${SERVER_DIR}/easy-rsa"
    "${SERVER_DIR}/ca.crt"
    "${SERVER_DIR}/server.crt"
    "${SERVER_DIR}/server.key"
    "${SERVER_DIR}/crl.pem"
    "${SERVER_DIR}/tc.key"
    "${SERVER_DIR}/dh.pem"
    "${SERVER_DIR}/server-udp.conf"
    "${SERVER_DIR}/server-tcp.conf"
    "${SERVER_DIR}/client-common-udp-tcp.txt"
    "${SERVER_DIR}/client-pwd-auth"
    "${SERVER_DIR}/ipp-udp.txt"
    "${SERVER_DIR}/ipp-tcp.txt"
    "${SERVER_DIR}/to-get-from-hwdsl2.sh"
    "${SERVER_DIR}/auto-openvpn-add-client.sh"
    "${SERVER_DIR}/auto-openvpn-revoke-client.sh"
    "${SERVER_DIR}/to-assign-ip-to-client.sh"
    "${OPENVPN_DIR}/ccd-udp"
    "${OPENVPN_DIR}/ccd-tcp"
    "/etc/systemd/system/openvpn-iptables-udp.service"
    "/etc/systemd/system/openvpn-iptables-tcp.service"
    "/etc/systemd/system/openvpn-iptables-udp-tcp-extra.service"
    "/etc/sysctl.d/99-openvpn-forward.conf"
  )

  for path in "${paths[@]}"; do
    ensure_exists "$path"
    printf '%s\n' "${path#/}"
  done
}

print_best_effort_summary() {
  local credential_count="unknown"
  local udp_ccd_count="unknown"
  local tcp_ccd_count="unknown"

  if [ -d "$PWD_AUTH_DIR" ]; then
    credential_count="$(find "$PWD_AUTH_DIR" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  fi

  if [ -d "${OPENVPN_DIR}/ccd-udp" ]; then
    udp_ccd_count="$(find "${OPENVPN_DIR}/ccd-udp" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  fi

  if [ -d "${OPENVPN_DIR}/ccd-tcp" ]; then
    tcp_ccd_count="$(find "${OPENVPN_DIR}/ccd-tcp" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  fi

  echo "Best-effort backup summary:"
  echo "- pwd-auth credential files: ${credential_count}"
  echo "- UDP CCD files: ${udp_ccd_count}"
  echo "- TCP CCD files: ${tcp_ccd_count}"
}

ensure_exists "$SERVER_DIR"
ensure_parent_dir "$OUTPUT_PATH"

TMP_MANIFEST="$(mktemp)"
trap 'rm -f "$TMP_MANIFEST"' EXIT

build_manifest > "$TMP_MANIFEST"

tar -czf "$OUTPUT_PATH" -C / -T "$TMP_MANIFEST"

echo "Backup created: $OUTPUT_PATH"
print_best_effort_summary || echo "WARN: failed to generate backup summary; archive itself is still valid"
echo "Clients can keep their existing cert/key material after restore; only update the remote IP in .ovpn files."
