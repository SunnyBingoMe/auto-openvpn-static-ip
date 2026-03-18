#!/bin/bash
set -euo pipefail

ORIGINAL_ARGS=("$@")

PROFILE_PROTO="udp"
CN=""
PWD_AUTH_USERNAME=""
PWD_AUTH_PASSWORD=""

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

DEFAULT_CLIENT_DIR="/etc/openvpn/client-udp-tcp"
UDP_CCD_DIR="/etc/openvpn/ccd-udp"
CCD_DIR="/etc/openvpn/ccd"
TCP_CCD_DIR="/etc/openvpn/ccd-tcp"
SERVER_DIR="/etc/openvpn/server"
UDP_IPP_FILE="${OPENVPN_UDP_IPP_FILE:-${SERVER_DIR}/ipp-udp.txt}"
TCP_SUBNET_PREFIX="${OPENVPN_TCP_SUBNET_PREFIX:-172.23}"
TCP_MASK="${OPENVPN_TCP_MASK:-255.255.0.0}"
TCP_IPP_FILE="${OPENVPN_TCP_IPP_FILE:-${SERVER_DIR}/ipp-tcp.txt}"

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --proto)
        [ "$#" -ge 2 ] || {
          echo "missing value for --proto" >&2
          exit 1
        }
        PROFILE_PROTO="$2"
        shift 2
        ;;
      --help|-h)
        cat <<'EOF'
Usage: auto-openvpn-add-client.sh [--proto udp|tcp] <client-name>
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

  case "$PROFILE_PROTO" in
    udp|tcp)
      ;;
    *)
      echo "Invalid protocol: $PROFILE_PROTO" >&2
      echo "Allowed values: udp, tcp" >&2
      exit 1
      ;;
  esac
}

validate_client_name() {
  if [[ ! "$CN" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid client name: $CN" >&2
    echo "Allowed characters: letters, numbers, '-' and '_'" >&2
    exit 1
  fi
}

prompt_pwd_auth_credentials() {
  local username_input

  echo
  read -r -p "Username [${CN}]: " username_input
  if [ -z "$username_input" ]; then
    PWD_AUTH_USERNAME="$CN"
  else
    PWD_AUTH_USERNAME="$username_input"
  fi

  read -r -s -p "Password [empty]: " PWD_AUTH_PASSWORD
  echo
}

store_pwd_auth_credentials() {
  local pwd_auth_dir
  local pwd_auth_file
  local escaped_password

  pwd_auth_dir="${SERVER_DIR}/client-pwd-auth"
  pwd_auth_file="${pwd_auth_dir}/${CN}.credentials"

  mkdir -p "$pwd_auth_dir"
  chmod 700 "$pwd_auth_dir"

  escaped_password="$(printf '%s' "$PWD_AUTH_PASSWORD" | sed 's/\\/\\\\/g; s/:/\\:/g')"
  printf '%s:%s\n' "$PWD_AUTH_USERNAME" "$escaped_password" > "$pwd_auth_file"
  chmod 600 "$pwd_auth_file"
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

  if [ -f "/etc/openvpn/server/to-get-from-hwdsl2.sh" ]; then
    printf '%s\n' "/etc/openvpn/server/to-get-from-hwdsl2.sh"
    return 0
  fi

  return 1
}

find_assign_script() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${OPENVPN_ASSIGN_SCRIPT:-}" ]; then
    printf '%s\n' "$OPENVPN_ASSIGN_SCRIPT"
    return 0
  fi

  if [ -f "${SCRIPT_DIR}/to-assign-ip-to-client.sh" ]; then
    printf '%s\n' "${SCRIPT_DIR}/to-assign-ip-to-client.sh"
    return 0
  fi

  if [ -f "/etc/openvpn/server/to-assign-ip-to-client.sh" ]; then
    printf '%s\n' "/etc/openvpn/server/to-assign-ip-to-client.sh"
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

extract_generated_profile_from_output() {
  awk -F': ' '/Configuration available in: / { path=$2 } END { if (path != "") print path }'
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

resolve_server_conf() {
  case "$PROFILE_PROTO" in
    udp)
      printf '%s\n' "${SERVER_DIR}/server-udp.conf"
      ;;
    tcp)
      printf '%s\n' "${SERVER_DIR}/server-tcp.conf"
      ;;
  esac
}

resolve_peer_server_conf() {
  case "$PROFILE_PROTO" in
    udp)
      printf '%s\n' "${SERVER_DIR}/server-tcp.conf"
      ;;
    tcp)
      printf '%s\n' "${SERVER_DIR}/server-udp.conf"
      ;;
  esac
}

extract_server_value() {
  local conf_file="$1"
  local key="$2"

  awk -v key="$key" '$1 == key { print $2; exit }' "$conf_file"
}

profile_output_name() {
  case "$PROFILE_PROTO" in
    udp)
      printf '%s.udp.ovpn\n' "$CN"
      ;;
    tcp)
      printf '%s.tcp.ovpn\n' "$CN"
      ;;
  esac
}

rewrite_profile_for_protocol() {
  local source_file="$1"
  local target_file="$2"
  local server_conf="$3"
  local peer_server_conf="$4"
  local target_dir
  local target_name
  local tmp_file
  local remote_host
  local remote_port
  local local_route_network
  local local_route_mask
  local peer_route_network
  local peer_route_mask

  remote_host="$(awk '$1 == "remote" { print $2; exit }' "$source_file")"
  if [ -z "$remote_host" ]; then
    echo "remote host not found in generated profile: $source_file" >&2
    exit 1
  fi

  remote_port="$(extract_server_value "$server_conf" port)"
  if [ -z "$remote_port" ]; then
    echo "port not found in server config: $server_conf" >&2
    exit 1
  fi

  local_route_network="$(awk '$1 == "server" { print $2; exit }' "$server_conf")"
  local_route_mask="$(awk '$1 == "server" { print $3; exit }' "$server_conf")"
  peer_route_network="$(awk '$1 == "server" { print $2; exit }' "$peer_server_conf")"
  peer_route_mask="$(awk '$1 == "server" { print $3; exit }' "$peer_server_conf")"
  target_dir="$(dirname "$target_file")"
  target_name="$(basename "$target_file")"
  tmp_file="$(mktemp "${target_dir}/${target_name}.tmp.XXXXXX")"

  awk -v proto="$PROFILE_PROTO" \
      -v remote_host="$remote_host" \
      -v remote_port="$remote_port" \
      -v local_route_network="$local_route_network" \
      -v local_route_mask="$local_route_mask" \
      -v peer_route_network="$peer_route_network" \
      -v peer_route_mask="$peer_route_mask" '
    $1 == "proto" {
      print "proto " proto
      next
    }
    $1 == "remote" {
      print "remote " remote_host " " remote_port
      next
    }
    $1 == "route" {
      next
    }
    { print }
    END {
      if (local_route_network != "" && local_route_mask != "") {
        print "route " local_route_network " " local_route_mask
      }
      if (peer_route_network != "" && peer_route_mask != "") {
        print "route " peer_route_network " " peer_route_mask
      }
    }
  ' "$source_file" > "$tmp_file" || {
    rm -f "$tmp_file"
    exit 1
  }

  mv -f "$tmp_file" "$target_file" || {
    rm -f "$tmp_file"
    exit 1
  }
}

parse_args "$@"
validate_client_name
require_root "${ORIGINAL_ARGS[@]}"
prompt_pwd_auth_credentials

CLIENT_DIR="$(resolve_client_dir)"
SERVER_CONF="$(resolve_server_conf)"
PEER_SERVER_CONF="$(resolve_peer_server_conf)"

if [ ! -f "$SERVER_CONF" ]; then
  echo "server config not found for protocol $PROFILE_PROTO: $SERVER_CONF" >&2
  exit 1
fi

if [ ! -f "$PEER_SERVER_CONF" ]; then
  echo "peer server config not found for protocol $PROFILE_PROTO: $PEER_SERVER_CONF" >&2
  exit 1
fi

INSTALL_SCRIPT="$(find_install_script || true)"
ASSIGN_SCRIPT="$(find_assign_script || true)"

if [ -z "$INSTALL_SCRIPT" ]; then
  echo "install script not found" >&2
  echo "Looked in:" >&2
  echo "  ${SCRIPT_DIR}/to-get-from-hwdsl2.sh" >&2
  echo "  /etc/openvpn/server/to-get-from-hwdsl2.sh" >&2
  echo "You can also set OPENVPN_INSTALL_SCRIPT." >&2
  exit 1
fi

if [ -z "$ASSIGN_SCRIPT" ]; then
  echo "assign script not found" >&2
  echo "Looked in:" >&2
  echo "  ${SCRIPT_DIR}/to-assign-ip-to-client.sh" >&2
  echo "  /etc/openvpn/server/to-assign-ip-to-client.sh" >&2
  echo "You can also set OPENVPN_ASSIGN_SCRIPT." >&2
  exit 1
fi

if [ ! -f "$INSTALL_SCRIPT" ]; then
  echo "install script not found: $INSTALL_SCRIPT" >&2
  exit 1
fi

if [ ! -r "$ASSIGN_SCRIPT" ]; then
  echo "assign script not found or not readable: $ASSIGN_SCRIPT" >&2
  exit 1
fi

mkdir -p "$CLIENT_DIR"
mkdir -p "$UDP_CCD_DIR" "$TCP_CCD_DIR"
store_pwd_auth_credentials

INSTALL_OUTPUT=""
if [ -f "${SERVER_DIR}/easy-rsa/pki/issued/${CN}.crt" ]; then
  INSTALL_OUTPUT="$(bash "$INSTALL_SCRIPT" --exportclient "$CN")"
else
  INSTALL_OUTPUT="$(bash "$INSTALL_SCRIPT" --addclient "$CN")"
fi

if [ -n "$INSTALL_OUTPUT" ]; then
  printf '%s\n' "$INSTALL_OUTPUT"
fi

if [ "$PROFILE_PROTO" = "tcp" ]; then
  OPENVPN_CCD_DIR="$TCP_CCD_DIR" \
    OPENVPN_SUBNET_PREFIX="$TCP_SUBNET_PREFIX" \
    OPENVPN_MASK="$TCP_MASK" \
    OPENVPN_IPP_FILE="$TCP_IPP_FILE" \
    bash "$ASSIGN_SCRIPT" "$CN"
else
  OPENVPN_CCD_DIR="$UDP_CCD_DIR" \
    OPENVPN_IPP_FILE="$UDP_IPP_FILE" \
    bash "$ASSIGN_SCRIPT" "$CN"
fi

PROFILE_SOURCE="$(printf '%s\n' "$INSTALL_OUTPUT" | extract_generated_profile_from_output || true)"
if [ -z "$PROFILE_SOURCE" ] || [ ! -f "$PROFILE_SOURCE" ]; then
  PROFILE_SOURCE="$(find_generated_profile || true)"
fi
if [ -z "$PROFILE_SOURCE" ]; then
  echo "client profile not found after creation: ${CN}.ovpn" >&2
  exit 1
fi

PROFILE_OUTPUT="$(profile_output_name)"
PROFILE_TARGET="${CLIENT_DIR}/${PROFILE_OUTPUT}"

rewrite_profile_for_protocol "$PROFILE_SOURCE" "$PROFILE_TARGET" "$SERVER_CONF" "$PEER_SERVER_CONF"
rm -f "$PROFILE_SOURCE"
chmod 600 "$PROFILE_TARGET"

if [ -n "${SUDO_USER:-}" ] && getent group "$SUDO_USER" >/dev/null 2>&1; then
  chown "$SUDO_USER:$SUDO_USER" "$PROFILE_TARGET"
fi

#echo "Created client cert in profile-config-file, also CCD, for: ${CN}"
echo "OVPN: ${PROFILE_TARGET}"
#echo "Profile protocol: ${PROFILE_PROTO}"
#echo "Install script: ${INSTALL_SCRIPT}"
#echo "Assign script: ${ASSIGN_SCRIPT}"
if [ "$PROFILE_PROTO" = "tcp" ]; then
  echo "CCD: ${TCP_CCD_DIR}/${CN}"
else
  echo "CCD: ${UDP_CCD_DIR}/${CN}"
fi
