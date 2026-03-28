#!/bin/bash
set -euo pipefail

ORIGINAL_ARGS=("$@")

PROFILE_PROTO_EXPLICIT="no"
CN=""
PROFILE_NAME_BASE=""
PWD_AUTH_USERNAME=""
PWD_AUTH_PASSWORD=""
PWD_AUTH_PASSWORD_CONFIRM=""
USE_MANUAL_PWD_AUTH="yes"
CLIENT_OS=""

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
        PROFILE_PROTO_EXPLICIT="yes"
        shift 2
        ;;
      --help|-h)
        cat <<'EOF'
Usage: auto-openvpn-add-client.sh [--proto udp|tcp] <client-name>
If client-name contains a '-' or '_' token equal to tcp/udp, that protocol is auto-detected.
Otherwise the script prompts for udp/tcp and uses a protocol-suffixed profile filename.
EOF
        exit 0
        ;;
      --*)
        echo "unknown option: $1" >&2
        exit 1
        ;;
      *)
        if [ -n "$CN" ]; then
      echo "unexpected positional argument: $1" >&2
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

  if [ "$PROFILE_PROTO_EXPLICIT" = "yes" ]; then
    case "${PROFILE_PROTO:-}" in
      udp|tcp)
        ;;
      *)
        echo "Invalid protocol: $PROFILE_PROTO" >&2
        echo "Allowed values: udp, tcp" >&2
        exit 1
        ;;
    esac
  fi
}

validate_client_name() {
  if [[ ! "$CN" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid client name: $CN" >&2
    echo "Allowed characters: letters, numbers, '-' and '_'" >&2
    echo "The client name is also used as the default embedded username and password." >&2
    exit 1
  fi
}

normalize_proto_value() {
  local proto_value="$1"

  case "${proto_value,,}" in
    udp|tcp)
      printf '%s\n' "${proto_value,,}"
      ;;
    *)
      return 1
      ;;
  esac
}

prompt_for_client_os() {
  local os_choice

  while true; do
    echo
    read -r -p "Client 是 Linux 还是 Windows？(可以只输入首字母) [Linux/Windows] (default: Linux): " os_choice
    if [ -z "$os_choice" ]; then
      CLIENT_OS="linux"
      return 0
    fi

    case "${os_choice:0:1}" in
      [Ll])
        CLIENT_OS="linux"
        return 0
        ;;
      [Ww])
        CLIENT_OS="windows"
        return 0
        ;;
    esac

    echo "Invalid client OS choice. Allowed values: Linux, Windows" >&2
  done
}

prompt_for_profile_proto() {
  local proto_choice

  while true; do
    echo
    read -r -p "选择协议 Select protocol [udp/tcp] (default: udp): " proto_choice
    if [ -z "$proto_choice" ]; then
      PROFILE_PROTO="udp"
      return 0
    fi

    proto_choice="$(normalize_proto_value "$proto_choice" || true)"
    if [ -n "$proto_choice" ]; then
      PROFILE_PROTO="$proto_choice"
      return 0
    fi

    echo "Invalid protocol choice. Allowed values: udp, tcp" >&2
  done
}

profile_base_name() {
  local suffix="-$PROFILE_PROTO"

  case "${CN,,}" in
    *"$suffix")
      printf '%s\n' "$CN"
      ;;
    *)
      printf '%s\n' "${CN}${suffix}"
      ;;
  esac
}

announce_detected_proto() {
  local proto_label

  proto_label="${PROFILE_PROTO^^}"
  echo "Proto keyword detected: ${proto_label}."
}

preprocess_profile_proto_from_client_name() {
  local token
  local detected_proto=""
  local explicit_proto=""

  if [ "$PROFILE_PROTO_EXPLICIT" = "yes" ]; then
    explicit_proto="$(normalize_proto_value "${PROFILE_PROTO:-}" || true)"
  fi

  IFS='-_' read -r -a tokens <<< "$CN"
  for token in "${tokens[@]}"; do
    detected_proto="$(normalize_proto_value "$token" || true)"
    if [ -n "$detected_proto" ]; then
      break
    fi
  done

  if [ -n "$explicit_proto" ]; then
    PROFILE_PROTO="$explicit_proto"
  elif [ -n "$detected_proto" ]; then
    PROFILE_PROTO="$detected_proto"
    announce_detected_proto
  else
    prompt_for_profile_proto
  fi

  CN="$(profile_base_name)"
  PROFILE_NAME_BASE="$CN"
}

generate_random_password() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(18))
PY
}

prompt_auth_mode() {
  local auth_choice

  echo
  read -r -p "要求客户端密码登录么？ Require embedded user/pass for this client? [Y/n]: " auth_choice
  case "$auth_choice" in
    [Nn]|[Nn][Oo])
      USE_MANUAL_PWD_AUTH="no"
      echo "将为该客户端内嵌用户名和密码，模拟 cert-only 使用方式。"
      ;;
    *)
      USE_MANUAL_PWD_AUTH="yes"
      echo "该客户端将启用用户名密码登录；连接时需要手动输入用户名和密码。"
      ;;
  esac
}

prompt_pwd_auth_credentials() {
  local username_input

  if [ "$USE_MANUAL_PWD_AUTH" != "yes" ]; then
    PWD_AUTH_USERNAME="$CN"
    PWD_AUTH_PASSWORD="$CN"
    return 0
  fi

  echo
  read -r -p "Username [${CN}]: " username_input
  if [ -z "$username_input" ]; then
    PWD_AUTH_USERNAME="$CN"
  else
    PWD_AUTH_USERNAME="$username_input"
  fi

  read -r -s -p "Password [${CN}; leave empty to use client name]: " PWD_AUTH_PASSWORD
  echo
  read -r -s -p "确认 Confirm Password [${CN}; leave empty to use client name]: " PWD_AUTH_PASSWORD_CONFIRM
  echo

  if [ -z "$PWD_AUTH_PASSWORD" ] && [ -z "$PWD_AUTH_PASSWORD_CONFIRM" ]; then
    PWD_AUTH_PASSWORD="$CN"
    echo "已使用客户端名作为默认登录密码。 Using client name as login password."
    return 0
  fi

  if [ -z "$PWD_AUTH_PASSWORD" ] || [ -z "$PWD_AUTH_PASSWORD_CONFIRM" ]; then
    PWD_AUTH_PASSWORD="$CN"
    echo "检测到空密码输入，已回退为客户端名密码。 Falling back to client name password."
    return 0
  fi

  if [ "$PWD_AUTH_PASSWORD" != "$PWD_AUTH_PASSWORD_CONFIRM" ]; then
    echo "两次输入不同 Passwords do not match." >&2
    exit 1
  fi
}

store_pwd_auth_credentials() {
  local pwd_auth_dir
  local pwd_auth_file
  local escaped_password
  local runtime_group

  pwd_auth_dir="${SERVER_DIR}/client-pwd-auth"
  pwd_auth_file="${pwd_auth_dir}/${CN}.credentials"
  runtime_group="$(awk '$1 == "group" { print $2; exit }' "$SERVER_CONF" 2>/dev/null)"
  if [ -z "$runtime_group" ] || ! getent group "$runtime_group" >/dev/null 2>&1; then
    runtime_group="nogroup"
    if ! getent group "$runtime_group" >/dev/null 2>&1; then
      runtime_group="nobody"
    fi
  fi

  mkdir -p "$pwd_auth_dir"
  chown root:"$runtime_group" "$pwd_auth_dir"
  chmod 750 "$pwd_auth_dir"

  escaped_password="$(printf '%s' "$PWD_AUTH_PASSWORD" | sed 's/\\/\\\\/g; s/:/\\:/g')"
  printf '%s:%s\n' "$PWD_AUTH_USERNAME" "$escaped_password" > "$pwd_auth_file"
  chown root:"$runtime_group" "$pwd_auth_file"
  chmod 640 "$pwd_auth_file"
}

remove_pwd_auth_credentials() {
  local pwd_auth_file

  pwd_auth_file="${SERVER_DIR}/client-pwd-auth/${CN}.credentials"
  rm -f "$pwd_auth_file"
}

embed_inline_auth_block() {
  local target_file="$1"
  local tmp_file

  tmp_file="$(mktemp "${target_file}.tmp.XXXXXX")"
  awk -v username="$PWD_AUTH_USERNAME" -v password="$PWD_AUTH_PASSWORD" '
    BEGIN {
      inserted = 0
      in_auth_block = 0
    }
    /^<auth-user-pass>$/ {
      in_auth_block = 1
      next
    }
    /^<\/auth-user-pass>$/ {
      in_auth_block = 0
      next
    }
    in_auth_block {
      next
    }
    $1 == "auth-user-pass" {
      if (!inserted) {
        print "auth-user-pass"
        print "<auth-user-pass>"
        print username
        print password
        print "</auth-user-pass>"
        inserted = 1
      }
      next
    }
    {
      print
    }
    END {
      if (!inserted) {
        print "auth-user-pass"
        print "<auth-user-pass>"
        print username
        print password
        print "</auth-user-pass>"
      }
    }
  ' "$target_file" > "$tmp_file"

  mv -f "$tmp_file" "$target_file"
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
  local source_name

  source_name="${CN}.ovpn"

  if [ -n "${SUDO_USER:-}" ]; then
    user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
    if [ -n "$user_home" ] && [ -f "${user_home}/${source_name}" ]; then
      printf '%s\n' "${user_home}/${source_name}"
      return 0
    fi
  fi

  if [ -f "/root/${source_name}" ]; then
    printf '%s\n' "/root/${source_name}"
    return 0
  fi

  if [ -f "${PWD}/${source_name}" ]; then
    printf '%s\n' "${PWD}/${source_name}"
    return 0
  fi

  if [ -f "${SCRIPT_DIR}/${source_name}" ]; then
    printf '%s\n' "${SCRIPT_DIR}/${source_name}"
    return 0
  fi

  return 1
}

should_remove_profile_source() {
  local source_file="$1"
  local target_file="$2"

  [ "$source_file" != "$target_file" ]
}

cleanup_source_profile() {
  local source_file="$1"
  local target_file="$2"

  if should_remove_profile_source "$source_file" "$target_file"; then
    rm -f "$source_file"
  fi
}

validate_profile_auth_mode() {
  local profile_file="$1"

  if ! grep -Fqs 'auth-user-pass' "$profile_file"; then
    echo "generated profile is missing auth-user-pass directive: $profile_file" >&2
    exit 1
  fi

  if [ "$USE_MANUAL_PWD_AUTH" = "yes" ]; then
    if grep -Fqs '<auth-user-pass>' "$profile_file"; then
      echo "generated profile unexpectedly embeds credentials: $profile_file" >&2
      exit 1
    fi
    return 0
  fi

  if ! grep -Fqs '<auth-user-pass>' "$profile_file"; then
    echo "generated profile is missing embedded credentials: $profile_file" >&2
    exit 1
  fi

  if ! grep -Fqs "$PWD_AUTH_USERNAME" "$profile_file" || ! grep -Fqs "$PWD_AUTH_PASSWORD" "$profile_file"; then
    echo "generated profile does not contain expected embedded credentials: $profile_file" >&2
    exit 1
  fi
}

validate_generated_client_artifacts() {
  local profile_file="$1"

  if ! client_pki_complete; then
    echo "client PKI artifacts are incomplete for ${CN}" >&2
    echo "Expected cert: ${SERVER_DIR}/easy-rsa/pki/issued/${CN}.crt" >&2
    echo "Expected key: ${SERVER_DIR}/easy-rsa/pki/private/${CN}.key" >&2
    exit 1
  fi

  if [ ! -f "$profile_file" ]; then
    echo "generated profile missing: $profile_file" >&2
    exit 1
  fi

  if ! grep -Fqs "<cert>" "$profile_file" || ! grep -Fqs "<key>" "$profile_file"; then
    echo "generated profile is incomplete: $profile_file" >&2
    exit 1
  fi

  validate_profile_auth_mode "$profile_file"
}
client_pki_complete() {
  [ -f "${SERVER_DIR}/easy-rsa/pki/issued/${CN}.crt" ] \
    && [ -f "${SERVER_DIR}/easy-rsa/pki/private/${CN}.key" ]
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
      printf '%s.udp.ovpn\n' "$PROFILE_NAME_BASE"
      ;;
    tcp)
      printf '%s.tcp.ovpn\n' "$PROFILE_NAME_BASE"
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
      -v peer_route_mask="$peer_route_mask" \
      -v client_os="$CLIENT_OS" '
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
      if (client_os == "linux") {
        print "script-security 2"
        print "up /etc/openvpn/client/fix-routes.sh"
      } else {
        if (local_route_network != "" && local_route_mask != "") {
          print "route " local_route_network " " local_route_mask
        }
        if (peer_route_network != "" && peer_route_mask != "") {
          print "route " peer_route_network " " peer_route_mask
        }
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

case "${1:-}" in
  --help|-h)
    parse_args "$@"
    ;;
esac

require_root "${ORIGINAL_ARGS[@]}"
parse_args "$@"
validate_client_name
preprocess_profile_proto_from_client_name
prompt_for_client_os
prompt_auth_mode
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
if client_pki_complete; then
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
if [ "$USE_MANUAL_PWD_AUTH" != "yes" ]; then
  embed_inline_auth_block "$PROFILE_TARGET"
fi
cleanup_source_profile "$PROFILE_SOURCE" "$PROFILE_TARGET"
validate_generated_client_artifacts "$PROFILE_TARGET"
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
