#!/bin/bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0")"

OPENVPN_DIR="/etc/openvpn"
SERVER_DIR="${OPENVPN_DIR}/server"
UDP_CCD_DIR="${OPENVPN_DIR}/ccd-udp"
TCP_CCD_DIR="${OPENVPN_DIR}/ccd-tcp"
CLIENT_DIR="${OPENVPN_DIR}/client-udp-tcp"
SERVER_CONF="${SERVER_DIR}/server-udp.conf"
TCP_SERVER_CONF="${SERVER_DIR}/server-tcp.conf"
CLIENT_COMMON_FILE="${SERVER_DIR}/client-common-udp-tcp.txt"
EASYRSA_DIR="${SERVER_DIR}/easy-rsa"
UDP_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-udp.service"
TCP_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-tcp.service"
EXTRA_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-udp-tcp-extra.service"
LEGACY_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables.service"
SYSCTL_FORWARD_FILE="/etc/sysctl.d/99-openvpn-forward.conf"
CLIENT_LINK="/usr/local/sbin/auto-openvpn-add-client.sh"
REVOKE_LINK="/usr/local/sbin/auto-openvpn-revoke-client.sh"

ARCHIVE_PATH="${1:-}"

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

usage() {
  cat <<'EOF'
Usage: restore.sh <current-certs-and-basic-config-YYYY-MM-DD.tgz>

Prerequisite: run install-auto-openvpn.sh on the new Ubuntu server first.
EOF
}

ensure_exists() {
  local path="$1"

  if [ ! -e "$path" ]; then
    echo "Required path not found: $path" >&2
    exit 1
  fi
}

ensure_parent_dir_exists() {
  local path="$1"
  local parent_dir

  parent_dir="$(dirname "$path")"
  if [ ! -d "$parent_dir" ]; then
    echo "Required parent directory not found: $parent_dir" >&2
    exit 1
  fi
}

ensure_archive_entry() {
  local entry="$1"

  if ! grep -Fqx "$entry" "$ARCHIVE_LIST_FILE"; then
    echo "Backup archive missing required entry: $entry" >&2
    exit 1
  fi
}

safe_tar_extract() {
  while IFS= read -r entry; do
    case "$entry" in
      ''|./*)
        ;;
      /*|../*|*/../*|*..)
        echo "Unsafe archive entry detected: $entry" >&2
        exit 1
        ;;
    esac
  done < "$ARCHIVE_LIST_FILE"

  tar -xzf "$ARCHIVE_PATH" -C "$STAGING_DIR"
}

stop_services() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  systemctl disable --now openvpn-server@server.service >/dev/null 2>&1 || true
  systemctl stop openvpn-server@server-udp.service >/dev/null 2>&1 || true
  systemctl stop openvpn-server@server-tcp.service >/dev/null 2>&1 || true
  systemctl stop openvpn-iptables-udp.service >/dev/null 2>&1 || true
  systemctl stop openvpn-iptables-tcp.service >/dev/null 2>&1 || true
  systemctl stop openvpn-iptables-udp-tcp-extra.service >/dev/null 2>&1 || true
}

backup_current_state() {
  ROLLBACK_DIR="/root/openvpn-restore-backup-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$ROLLBACK_DIR"

  for path in "$SERVER_DIR" "$UDP_CCD_DIR" "$TCP_CCD_DIR" "$CLIENT_DIR" "$UDP_FIREWALL_SERVICE" "$TCP_FIREWALL_SERVICE" "$EXTRA_FIREWALL_SERVICE" "$SYSCTL_FORWARD_FILE"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      cp -a --parents "$path" "$ROLLBACK_DIR"
    fi
  done
}

install_path() {
  local source_path="$1"
  local target_path="$2"

  rm -rf "$target_path"
  mkdir -p "$(dirname "$target_path")"
  cp -a "$source_path" "$target_path"
}

restore_tree() {
  install_path "$STAGING_DIR/${SERVER_DIR#/}/easy-rsa" "$EASYRSA_DIR"
  install_path "$STAGING_DIR/${OPENVPN_DIR#/}/ccd-udp" "$UDP_CCD_DIR"
  install_path "$STAGING_DIR/${OPENVPN_DIR#/}/ccd-tcp" "$TCP_CCD_DIR"

  install -m 600 "$STAGING_DIR/${SERVER_CONF#/}" "$SERVER_CONF"
  install -m 600 "$STAGING_DIR/${TCP_SERVER_CONF#/}" "$TCP_SERVER_CONF"
  install -m 600 "$STAGING_DIR/${CLIENT_COMMON_FILE#/}" "$CLIENT_COMMON_FILE"
  install -m 600 "$STAGING_DIR/${SERVER_DIR#/}/ipp-udp.txt" "${SERVER_DIR}/ipp-udp.txt"
  install -m 600 "$STAGING_DIR/${SERVER_DIR#/}/ipp-tcp.txt" "${SERVER_DIR}/ipp-tcp.txt"

  install -m 600 "$STAGING_DIR/${SERVER_DIR#/}/ca.crt" "${SERVER_DIR}/ca.crt"
  install -m 600 "$STAGING_DIR/${SERVER_DIR#/}/server.crt" "${SERVER_DIR}/server.crt"
  install -m 600 "$STAGING_DIR/${SERVER_DIR#/}/server.key" "${SERVER_DIR}/server.key"
  install -m 644 "$STAGING_DIR/${SERVER_DIR#/}/crl.pem" "${SERVER_DIR}/crl.pem"
  install -m 600 "$STAGING_DIR/${SERVER_DIR#/}/tc.key" "${SERVER_DIR}/tc.key"
  install -m 600 "$STAGING_DIR/${SERVER_DIR#/}/dh.pem" "${SERVER_DIR}/dh.pem"

  install -m 700 "$STAGING_DIR/${SERVER_DIR#/}/to-get-from-hwdsl2.sh" "${SERVER_DIR}/to-get-from-hwdsl2.sh"
  install -m 700 "$STAGING_DIR/${SERVER_DIR#/}/auto-openvpn-add-client.sh" "${SERVER_DIR}/auto-openvpn-add-client.sh"
  install -m 700 "$STAGING_DIR/${SERVER_DIR#/}/auto-openvpn-revoke-client.sh" "${SERVER_DIR}/auto-openvpn-revoke-client.sh"
  install -m 700 "$STAGING_DIR/${SERVER_DIR#/}/to-assign-ip-to-client.sh" "${SERVER_DIR}/to-assign-ip-to-client.sh"

  install -m 644 "$STAGING_DIR/${UDP_FIREWALL_SERVICE#/}" "$UDP_FIREWALL_SERVICE"
  install -m 644 "$STAGING_DIR/${TCP_FIREWALL_SERVICE#/}" "$TCP_FIREWALL_SERVICE"
  install -m 644 "$STAGING_DIR/${EXTRA_FIREWALL_SERVICE#/}" "$EXTRA_FIREWALL_SERVICE"
  install -m 644 "$STAGING_DIR/${SYSCTL_FORWARD_FILE#/}" "$SYSCTL_FORWARD_FILE"
}

restore_compat_links() {
  mkdir -p "$CLIENT_DIR"
  chmod 700 "$UDP_CCD_DIR" "$TCP_CCD_DIR" "$CLIENT_DIR"
  chmod 700 "$SERVER_DIR"
  chown -R root:root "$SERVER_DIR" "$UDP_CCD_DIR" "$TCP_CCD_DIR" "$CLIENT_DIR"
  chown nobody:nogroup "${SERVER_DIR}/crl.pem" 2>/dev/null || true
  chmod o+x "$SERVER_DIR"

  ln -sfn "$SERVER_CONF" "${SERVER_DIR}/server.conf"
  ln -sfn "$CLIENT_COMMON_FILE" "${SERVER_DIR}/client-common.txt"
  ln -sfn "$UDP_CCD_DIR" "${OPENVPN_DIR}/ccd"
  ln -sfn "$CLIENT_DIR" "${OPENVPN_DIR}/client"
  ln -sfn "${SERVER_DIR}/auto-openvpn-add-client.sh" "$CLIENT_LINK"
  ln -sfn "${SERVER_DIR}/auto-openvpn-revoke-client.sh" "$REVOKE_LINK"

  if [ -e "$UDP_FIREWALL_SERVICE" ]; then
    ln -sfn "$UDP_FIREWALL_SERVICE" "$LEGACY_FIREWALL_SERVICE"
  fi
}

restart_services() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  sysctl -e -q -p "$SYSCTL_FORWARD_FILE" >/dev/null 2>&1 || true
  systemctl daemon-reload
  systemctl enable --now openvpn-iptables-udp.service >/dev/null 2>&1 || true
  systemctl enable --now openvpn-iptables-tcp.service >/dev/null 2>&1 || true
  systemctl enable --now openvpn-iptables-udp-tcp-extra.service >/dev/null 2>&1 || true
  systemctl enable --now openvpn-server@server-udp.service >/dev/null 2>&1
  systemctl enable --now openvpn-server@server-tcp.service >/dev/null 2>&1
}

require_root "$@"

if [ -z "$ARCHIVE_PATH" ]; then
  usage >&2
  exit 1
fi

if [ ! -f "$ARCHIVE_PATH" ]; then
  echo "Backup archive not found: $ARCHIVE_PATH" >&2
  exit 1
fi

for required_path in "$SERVER_DIR" "$SERVER_CONF" "$TCP_SERVER_CONF"; do
  ensure_exists "$required_path"
done

ensure_parent_dir_exists "$EASYRSA_DIR"

ARCHIVE_LIST_FILE="$(mktemp)"
STAGING_DIR="$(mktemp -d)"
ROLLBACK_DIR=""
trap 'rm -f "$ARCHIVE_LIST_FILE"; rm -rf "$STAGING_DIR"' EXIT

tar -tzf "$ARCHIVE_PATH" > "$ARCHIVE_LIST_FILE"

ensure_archive_entry "etc/openvpn/server/easy-rsa/"
ensure_archive_entry "etc/openvpn/server/server-udp.conf"
ensure_archive_entry "etc/openvpn/server/server-tcp.conf"
ensure_archive_entry "etc/openvpn/server/client-common-udp-tcp.txt"
ensure_archive_entry "etc/openvpn/server/ca.crt"
ensure_archive_entry "etc/openvpn/server/server.crt"
ensure_archive_entry "etc/openvpn/server/server.key"
ensure_archive_entry "etc/openvpn/server/tc.key"
ensure_archive_entry "etc/openvpn/server/crl.pem"
ensure_archive_entry "etc/openvpn/ccd-udp/"
ensure_archive_entry "etc/openvpn/ccd-tcp/"

safe_tar_extract
stop_services
backup_current_state
restore_tree
restore_compat_links
restart_services

echo "Restore completed from: $ARCHIVE_PATH"
echo "Rollback backup saved to: $ROLLBACK_DIR"
echo "Existing clients should only need the new server IP in their .ovpn remote line."
