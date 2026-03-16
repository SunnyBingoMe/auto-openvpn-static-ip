#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

assert_contains() {
  local file="$1"
  local pattern="$2"

  if ! grep -Eq -- "$pattern" "$file"; then
    echo "Assertion failed: pattern '$pattern' not found in $file" >&2
    exit 1
  fi
}

assert_contains "$ROOT_DIR/create_ovpn_client.sh" 'PROFILE_PROTO="udp"'
assert_contains "$ROOT_DIR/create_ovpn_client.sh" '--proto udp\|tcp'
assert_contains "$ROOT_DIR/create_ovpn_client.sh" 'server-udp\.conf'
assert_contains "$ROOT_DIR/create_ovpn_client.sh" 'server-tcp\.conf'
assert_contains "$ROOT_DIR/create_ovpn_client.sh" 'resolve_peer_server_conf\(\)'
assert_contains "$ROOT_DIR/create_ovpn_client.sh" 'printf '\''%s\.udp\.ovpn\\n'\'' "\$CN"'
assert_contains "$ROOT_DIR/create_ovpn_client.sh" 'printf '\''%s\.tcp\.ovpn\\n'\'' "\$CN"'
assert_contains "$ROOT_DIR/create_ovpn_client.sh" 'OPENVPN_CCD_DIR="\$TCP_CCD_DIR"'
assert_contains "$ROOT_DIR/create_ovpn_client.sh" 'OPENVPN_SUBNET_PREFIX="\$TCP_SUBNET_PREFIX"'
assert_contains "$ROOT_DIR/create_ovpn_client.sh" 'peer_route_network'

assert_contains "$ROOT_DIR/install.sh" 'SERVER_CONF="\$\{SERVER_DIR\}/server-udp\.conf"'
assert_contains "$ROOT_DIR/install.sh" 'TCP_SERVER_CONF="\$\{SERVER_DIR\}/server-tcp\.conf"'
assert_contains "$ROOT_DIR/install.sh" 'UDP_CCD_DIR="\$\{OPENVPN_DIR\}/ccd-udp"'
assert_contains "$ROOT_DIR/install.sh" 'TCP_CCD_DIR="\$\{OPENVPN_DIR\}/ccd-tcp"'
assert_contains "$ROOT_DIR/install.sh" 'CLIENT_DIR="\$\{OPENVPN_DIR\}/client-udp-tcp"'
assert_contains "$ROOT_DIR/install.sh" 'CLIENT_COMMON_FILE="\$\{SERVER_DIR\}/client-common-udp-tcp\.txt"'
assert_contains "$ROOT_DIR/install.sh" 'ensure_common_artifact_names\(\)'
assert_contains "$ROOT_DIR/install.sh" 'ensure_tcp_server_conf\(\)'
assert_contains "$ROOT_DIR/install.sh" 'ensure_cross_subnet_routes\(\)'
assert_contains "$ROOT_DIR/install.sh" 'openvpn-server@server-udp\.service'
assert_contains "$ROOT_DIR/install.sh" 'openvpn-server@server-tcp\.service'
assert_contains "$ROOT_DIR/install.sh" 'openvpn-iptables-udp\.service'
assert_contains "$ROOT_DIR/install.sh" 'openvpn-iptables-tcp\.service'
assert_contains "$ROOT_DIR/install.sh" 'openvpn-iptables-udp-tcp-extra\.service'
assert_contains "$ROOT_DIR/install.sh" 'tcp_network'
assert_contains "$ROOT_DIR/install.sh" 'udp_network'
assert_contains "$ROOT_DIR/install.sh" 'server \$\{tcp_subnet_prefix\}\.0\.0 255\.255\.0\.0'

assert_contains "$ROOT_DIR/README.MD" 'create_ovpn_client\.sh --proto tcp'
assert_contains "$ROOT_DIR/README.MD" 'server-udp\.conf'
assert_contains "$ROOT_DIR/README.MD" 'server-tcp\.conf'
assert_contains "$ROOT_DIR/README.MD" 'client-common-udp-tcp\.txt'
assert_contains "$ROOT_DIR/README.MD" 'client-udp-tcp'
assert_contains "$ROOT_DIR/README.MD" 'ccd-udp'
assert_contains "$ROOT_DIR/README.MD" 'openvpn-server@server-udp\.service'
assert_contains "$ROOT_DIR/README.MD" 'openvpn-server@server-tcp\.service'
assert_contains "$ROOT_DIR/README.MD" '172\.23\.0\.0/16'
assert_contains "$ROOT_DIR/README.MD" '默认互通'

echo "dual protocol contract checks passed"
