#!/bin/bash
set -euo pipefail

OPENVPN_DIR="/etc/openvpn"
SERVER_DIR="${OPENVPN_DIR}/server"
UDP_CCD_DIR="${OPENVPN_DIR}/ccd-udp"
TCP_CCD_DIR="${OPENVPN_DIR}/ccd-tcp"
CLIENT_DIR="${OPENVPN_DIR}/client-udp-tcp"
SERVER_CONF="${SERVER_DIR}/server-udp.conf"
TCP_SERVER_CONF="${SERVER_DIR}/server-tcp.conf"
CLIENT_COMMON_FILE="${SERVER_DIR}/client-common-udp-tcp.txt"
UDP_IPP_FILE="${SERVER_DIR}/ipp-udp.txt"
TCP_IPP_FILE="${SERVER_DIR}/ipp-tcp.txt"
PWD_AUTH_DIR="${SERVER_DIR}/client-pwd-auth"
PWD_AUTH_VERIFY_SCRIPT="${SERVER_DIR}/openvpn-pwd-auth-verify.sh"
EASYRSA_DIR="${SERVER_DIR}/easy-rsa"
UDP_FIREWALL_SERVICE="openvpn-iptables-udp.service"
TCP_FIREWALL_SERVICE="openvpn-iptables-tcp.service"
TCP_UDP_EXCHANGE_FIREWALL_SERVICE="openvpn-iptables-tcp-udp-exchange-rules.service"
UDP_PORT_DEFAULT=1194
HELPER_SCRIPTS=(
  "${SERVER_DIR}/to-get-from-hwdsl2.sh"
  "${SERVER_DIR}/auto-openvpn-add-client.sh"
  "${SERVER_DIR}/auto-openvpn-revoke-client.sh"
  "${SERVER_DIR}/to-assign-ip-to-client.sh"
)

failures=0
warnings=0

pass() {
  printf '[OK] %s\n' "$1"
}

warn() {
  printf '[WARN] %s\n' "$1"
  warnings=$((warnings + 1))
}

fail() {
  printf '[FAILED!] %s\n' "$1" >&2
  failures=$((failures + 1))
}

check_exists() {
  local path="$1"
  local label="$2"

  if [ -e "$path" ]; then
    pass "$label exists: $path"
  else
    fail "$label missing: $path"
  fi
}

check_mode() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local actual

  if [ ! -e "$path" ]; then
    fail "$label missing for mode check: $path"
    return 0
  fi

  actual="$(stat -c '%a' "$path")"
  if [ "$actual" = "$expected" ]; then
    pass "$label mode is $expected: $path"
  else
    fail "$label mode is $actual, expected $expected: $path"
  fi
}

check_group() {
  local path="$1"
  local label="$2"
  local actual_group

  if [ ! -e "$path" ]; then
    fail "$label missing for group check: $path"
    return 0
  fi

  actual_group="$(stat -c '%G' "$path")"
  if [ "$actual_group" = 'nogroup' ] || [ "$actual_group" = 'nobody' ]; then
    pass "$label group is runtime-compatible: $path ($actual_group)"
  else
    fail "$label group is $actual_group, expected nogroup or nobody: $path"
  fi
}

check_executable() {
  local path="$1"
  local label="$2"

  if [ ! -e "$path" ]; then
    fail "$label missing: $path"
  elif [ -x "$path" ]; then
    pass "$label executable: $path"
  else
    fail "$label not executable: $path"
  fi
}

check_symlink_target() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local actual

  if [ ! -L "$path" ]; then
    fail "$label is not a symlink: $path"
    return 0
  fi

  actual="$(readlink -f "$path")"
  if [ "$actual" = "$expected" ]; then
    pass "$label points to $expected"
  else
    fail "$label points to $actual, expected $expected"
  fi
}

check_service_active() {
  local service="$1"
  local label="$2"

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl unavailable, skipped service check: $label"
    return 0
  fi

  if systemctl is-active --quiet "$service"; then
    pass "$label active: $service"
  else
    fail "$label inactive: $service"
  fi
}

extract_port() {
  local conf_file="$1"
  local port

  port="$(awk '$1 == "port" { print $2; exit }' "$conf_file" 2>/dev/null || true)"
  if [ -n "$port" ]; then
    printf '%s\n' "$port"
  else
    printf '%s\n' "$UDP_PORT_DEFAULT"
  fi
}

check_port_listening() {
  local proto="$1"
  local port="$2"
  local label="$3"

  if command -v ss >/dev/null 2>&1; then
    if ss -lntup 2>/dev/null | grep -Eq "${proto}[[:space:]].*:${port}[[:space:]]"; then
      pass "$label listening on ${proto}/${port}"
    else
      fail "$label not listening on ${proto}/${port}"
    fi
    return 0
  fi

  warn "ss unavailable, skipped port check: $label ${proto}/${port}"
}

check_ip_forward() {
  local value

  if [ -r /proc/sys/net/ipv4/ip_forward ]; then
    value="$(cat /proc/sys/net/ipv4/ip_forward)"
    if [ "$value" = "1" ]; then
      pass 'net.ipv4.ip_forward enabled'
    else
      fail "net.ipv4.ip_forward is ${value}, expected 1"
    fi
  else
    warn 'cannot read /proc/sys/net/ipv4/ip_forward'
  fi
}

check_credentials_dir() {
  local cred_file

  check_exists "$PWD_AUTH_DIR" 'password auth directory'
  check_exists "$PWD_AUTH_VERIFY_SCRIPT" 'password auth verify script'

  if [ ! -d "$PWD_AUTH_DIR" ]; then
    return 0
  fi

  check_mode "$PWD_AUTH_DIR" '750' 'password auth directory'
  check_group "$PWD_AUTH_DIR" 'password auth directory'
  check_mode "$PWD_AUTH_VERIFY_SCRIPT" '750' 'password auth verify script'
  check_group "$PWD_AUTH_VERIFY_SCRIPT" 'password auth verify script'

  cred_file="$(find "$PWD_AUTH_DIR" -maxdepth 1 -type f -name '*.credentials' | head -n 1)"
  if [ -n "$cred_file" ]; then
    pass "password auth credentials present in $PWD_AUTH_DIR"
    check_mode "$cred_file" '640' 'password auth credential file'
    check_group "$cred_file" 'password auth credential file'
  else
    warn "password auth directory is empty: $PWD_AUTH_DIR"
  fi
}

check_runtime_state_access() {
  check_mode "$SERVER_DIR" '750' 'server directory'
  check_group "$SERVER_DIR" 'server directory'
  check_mode "$UDP_CCD_DIR" '750' 'UDP CCD directory'
  check_group "$UDP_CCD_DIR" 'UDP CCD directory'
  check_mode "$TCP_CCD_DIR" '750' 'TCP CCD directory'
  check_group "$TCP_CCD_DIR" 'TCP CCD directory'
  check_mode "$SERVER_CONF" '640' 'UDP server config'
  check_group "$SERVER_CONF" 'UDP server config'
  check_mode "$TCP_SERVER_CONF" '640' 'TCP server config'
  check_group "$TCP_SERVER_CONF" 'TCP server config'
  check_mode "$CLIENT_COMMON_FILE" '640' 'shared client template'
  check_group "$CLIENT_COMMON_FILE" 'shared client template'
  check_mode "$UDP_IPP_FILE" '640' 'UDP ipp file'
  check_group "$UDP_IPP_FILE" 'UDP ipp file'
  check_mode "$TCP_IPP_FILE" '640' 'TCP ipp file'
  check_group "$TCP_IPP_FILE" 'TCP ipp file'
}

check_client_common_remote() {
  local remote_host
  local remote_port

  remote_host="$(awk '$1 == "remote" { print $2; exit }' "$CLIENT_COMMON_FILE" 2>/dev/null || true)"
  remote_port="$(awk '$1 == "remote" { print $3; exit }' "$CLIENT_COMMON_FILE" 2>/dev/null || true)"

  if [ -n "$remote_host" ]; then
    pass "shared client template remote host set: $remote_host"
  else
    fail "shared client template remote host missing: $CLIENT_COMMON_FILE"
  fi

  if [ -n "$remote_port" ]; then
    pass "shared client template remote port set: $remote_port"
  else
    fail "shared client template remote port missing: $CLIENT_COMMON_FILE"
  fi
}

main() {
  local udp_port
  local tcp_port

  check_exists "$SERVER_CONF" 'UDP server config'
  check_exists "$TCP_SERVER_CONF" 'TCP server config'
  check_exists "$CLIENT_COMMON_FILE" 'shared client template'
  check_exists "$UDP_IPP_FILE" 'UDP ipp file'
  check_exists "$TCP_IPP_FILE" 'TCP ipp file'
  check_exists "$EASYRSA_DIR" 'easy-rsa directory'
  check_exists "$UDP_CCD_DIR" 'UDP CCD directory'
  check_exists "$TCP_CCD_DIR" 'TCP CCD directory'
  check_exists "$CLIENT_DIR" 'combined client directory'
  check_exists "${SERVER_DIR}/ca.crt" 'CA certificate'
  check_exists "${SERVER_DIR}/ca.key" 'CA key'
  check_exists "${SERVER_DIR}/server.crt" 'server certificate'
  check_exists "${SERVER_DIR}/server.key" 'server private key'
  check_exists "${SERVER_DIR}/crl.pem" 'CRL file'
  check_exists "${SERVER_DIR}/dh.pem" 'DH params'
  check_exists "${SERVER_DIR}/tc.key" 'tls-crypt key'

  check_credentials_dir
  check_runtime_state_access
  check_client_common_remote

  for helper_script in "${HELPER_SCRIPTS[@]}"; do
    check_executable "$helper_script" 'restored helper script'
  done

  check_symlink_target "/usr/local/sbin/auto-openvpn-add-client.sh" "${SERVER_DIR}/auto-openvpn-add-client.sh" 'client add symlink'
  check_symlink_target "/usr/local/sbin/auto-openvpn-revoke-client.sh" "${SERVER_DIR}/auto-openvpn-revoke-client.sh" 'client revoke symlink'

  check_service_active 'openvpn-server@server-udp.service' 'UDP OpenVPN service'
  check_service_active 'openvpn-server@server-tcp.service' 'TCP OpenVPN service'
  check_service_active "$UDP_FIREWALL_SERVICE" 'UDP firewall service'
  check_service_active "$TCP_FIREWALL_SERVICE" 'TCP firewall service'
  check_service_active "$TCP_UDP_EXCHANGE_FIREWALL_SERVICE" 'TCP/UDP exchange firewall service'

  udp_port="$(extract_port "$SERVER_CONF")"
  tcp_port="$(extract_port "$TCP_SERVER_CONF")"
  check_port_listening udp "$udp_port" 'UDP OpenVPN socket'
  check_port_listening tcp "$tcp_port" 'TCP OpenVPN socket'

  check_ip_forward

  printf '\nSmoke test finished: %s failure(s), %s warning(s).\n' "$failures" "$warnings"
  if [ "$failures" -ne 0 ]; then
    exit 1
  fi
}

main "$@"
