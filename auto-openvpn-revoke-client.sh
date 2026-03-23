#!/bin/bash
set -euo pipefail

ORIGINAL_ARGS=("$@")

CN=""
REVOKE_SCOPE="all"

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

DEFAULT_CLIENT_DIR="/etc/openvpn/client-udp-tcp"
UDP_CCD_DIR="${OPENVPN_UDP_CCD_DIR:-/etc/openvpn/ccd-udp}"
CCD_DIR="${OPENVPN_CCD_DIR:-/etc/openvpn/ccd}"
TCP_CCD_DIR="${OPENVPN_TCP_CCD_DIR:-/etc/openvpn/ccd-tcp}"
SERVER_DIR="${OPENVPN_SERVER_DIR:-/etc/openvpn/server}"
EASYRSA_DIR="${SERVER_DIR}/easy-rsa"
UDP_IPP_FILE="${OPENVPN_UDP_IPP_FILE:-${SERVER_DIR}/ipp-udp.txt}"
TCP_IPP_FILE="${OPENVPN_TCP_IPP_FILE:-${SERVER_DIR}/ipp-tcp.txt}"

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h)
        cat <<'EOF'
Usage: auto-openvpn-revoke-client.sh <client-name>
EOF
        exit 0
        ;;
      --*)
        echo "unknown option: $1" >&2
        exit 1
        ;;
      *)
        if [ -n "$CN" ]; then
          echo "unexpected extra argument: $1" >&2
          exit 1
        fi
        CN="$1"
        shift
        ;;
    esac
  done

  if [ -z "$CN" ]; then
    echo "missing client name" >&2
    exit 1
  fi
}

validate_client_name() {
  if [[ ! "$CN" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid client name: $CN" >&2
    echo "Allowed characters: letters, numbers, '-' and '_'" >&2
    exit 1
  fi
}

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

  if [ -f "${SCRIPT_DIR}/to-get-from-hwdsl2.sh" ]; then
    printf '%s\n' "${SCRIPT_DIR}/to-get-from-hwdsl2.sh"
    return 0
  fi

  if [ -f "${SERVER_DIR}/to-get-from-hwdsl2.sh" ]; then
    printf '%s\n' "${SERVER_DIR}/to-get-from-hwdsl2.sh"
    return 0
  fi

  return 1
}

resolve_client_dir() {
  local user_home=""

  if [ -n "${OPENVPN_CLIENT_DIR:-}" ]; then
    printf '%s\n' "$OPENVPN_CLIENT_DIR"
    return 0
  fi

  if [ -n "${SUDO_USER:-}" ]; then
    user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
    if [ -n "$user_home" ] && [ -d "$user_home" ] && [ "$user_home" != "/" ]; then
      printf '%s\n' "$user_home"
      return 0
    fi
  fi

  printf '%s\n' "$DEFAULT_CLIENT_DIR"
}

has_udp_client() {
  [ -f "${UDP_CCD_DIR}/${CN}" ] || grep -qs -- "^${CN}," "$UDP_IPP_FILE" 2>/dev/null
}

has_tcp_client() {
  [ -f "${TCP_CCD_DIR}/${CN}" ] || grep -qs -- "^${CN}," "$TCP_IPP_FILE" 2>/dev/null
}

prompt_revoke_scope() {
  local udp_exists
  local tcp_exists
  local answer

  udp_exists=0
  tcp_exists=0
  has_udp_client && udp_exists=1
  has_tcp_client && tcp_exists=1

  if [ "$udp_exists" -eq 1 ] && [ "$tcp_exists" -eq 1 ]; then
    echo
    read -r -p "Found both UDP and TCP client entries for ${CN}. Revoke which protocol? [udp/tcp/all] (default: all): " answer
    answer="${answer:-all}"
    case "$answer" in
      udp|tcp|all)
        REVOKE_SCOPE="$answer"
        ;;
      *)
        echo "Invalid selection: $answer" >&2
        echo "Allowed values: udp, tcp, all" >&2
        exit 1
        ;;
    esac
    return 0
  fi

  if [ "$udp_exists" -eq 1 ]; then
    REVOKE_SCOPE="udp"
    return 0
  fi

  if [ "$tcp_exists" -eq 1 ]; then
    REVOKE_SCOPE="tcp"
    return 0
  fi

  REVOKE_SCOPE="all"
}

remove_ipp_entry() {
  local ipp_file="$1"
  local tmp_file

  if [ ! -f "$ipp_file" ]; then
    return 0
  fi

  tmp_file="$(mktemp "${ipp_file}.tmp.XXXXXX")"
  awk -F, -v cn="$CN" '$1 != cn { print }' "$ipp_file" > "$tmp_file" || {
    rm -f "$tmp_file"
    exit 1
  }

  mv -f "$tmp_file" "$ipp_file" || {
    rm -f "$tmp_file"
    exit 1
  }
}

cleanup_client_files() {
  local client_dir

  client_dir="$(resolve_client_dir)"

  case "$REVOKE_SCOPE" in
    udp)
      rm -f \
        "${UDP_CCD_DIR}/${CN}" \
        "${client_dir}/${CN}.udp.ovpn" \
        "/root/${CN}.udp.ovpn" \
        "${PWD}/${CN}.udp.ovpn" \
        "${SCRIPT_DIR}/${CN}.udp.ovpn"
      if [ "$CCD_DIR" = "$UDP_CCD_DIR" ]; then
        rm -f "${CCD_DIR}/${CN}"
      fi
      remove_ipp_entry "$UDP_IPP_FILE"
      ;;
    tcp)
      rm -f \
        "${TCP_CCD_DIR}/${CN}" \
        "${client_dir}/${CN}.tcp.ovpn" \
        "/root/${CN}.tcp.ovpn" \
        "${PWD}/${CN}.tcp.ovpn" \
        "${SCRIPT_DIR}/${CN}.tcp.ovpn"
      if [ "$CCD_DIR" = "$TCP_CCD_DIR" ]; then
        rm -f "${CCD_DIR}/${CN}"
      fi
      remove_ipp_entry "$TCP_IPP_FILE"
      ;;
    all)
      rm -f \
        "${UDP_CCD_DIR}/${CN}" \
        "${TCP_CCD_DIR}/${CN}" \
        "${EASYRSA_DIR}/pki/issued/${CN}.crt" \
        "${EASYRSA_DIR}/pki/private/${CN}.key" \
        "${EASYRSA_DIR}/pki/reqs/${CN}.req" \
        "${client_dir}/${CN}.ovpn" \
        "${client_dir}/${CN}.udp.ovpn" \
        "${client_dir}/${CN}.tcp.ovpn" \
        "/root/${CN}.ovpn" \
        "/root/${CN}.udp.ovpn" \
        "/root/${CN}.tcp.ovpn" \
        "${PWD}/${CN}.ovpn" \
        "${PWD}/${CN}.udp.ovpn" \
        "${PWD}/${CN}.tcp.ovpn" \
        "${SCRIPT_DIR}/${CN}.ovpn" \
        "${SCRIPT_DIR}/${CN}.udp.ovpn" \
        "${SCRIPT_DIR}/${CN}.tcp.ovpn"

      if [ "$CCD_DIR" != "$UDP_CCD_DIR" ] && [ "$CCD_DIR" != "$TCP_CCD_DIR" ]; then
        rm -f "${CCD_DIR}/${CN}"
      fi

      remove_ipp_entry "$UDP_IPP_FILE"
      remove_ipp_entry "$TCP_IPP_FILE"
      ;;
  esac
}

case "${1:-}" in
  --help|-h)
    parse_args "$@"
    ;;
esac

require_root "${ORIGINAL_ARGS[@]}"
parse_args "$@"
validate_client_name
prompt_revoke_scope

INSTALL_SCRIPT="$(find_install_script || true)"

if [ -z "$INSTALL_SCRIPT" ]; then
  echo "install script not found" >&2
  echo "Looked in:" >&2
  echo "  ${SCRIPT_DIR}/to-get-from-hwdsl2.sh" >&2
  echo "  ${SERVER_DIR}/to-get-from-hwdsl2.sh" >&2
  echo "You can also set OPENVPN_INSTALL_SCRIPT." >&2
  exit 1
fi

if [ ! -f "$INSTALL_SCRIPT" ]; then
  echo "install script not found: $INSTALL_SCRIPT" >&2
  exit 1
fi

if [ "$REVOKE_SCOPE" = "all" ]; then
  bash "$INSTALL_SCRIPT" -y --revokeclient "$CN"
fi
cleanup_client_files

echo "REVOKED (${REVOKE_SCOPE}): ${CN}"
