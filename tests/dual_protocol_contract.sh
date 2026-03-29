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

assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" 'PROFILE_PROTO_EXPLICIT="no"'
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" '--proto udp\|tcp'
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" 'prompt_for_profile_proto\('
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" 'preprocess_profile_proto_from_client_name\('
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" 'CN="\$\(profile_base_name\)"'
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" 'PROFILE_NAME_BASE="\$CN"'
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" '\[ "\$source_file" != "\$target_file" \]'
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" 'cleanup_source_profile '
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" 'server-udp\.conf'
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" 'server-tcp\.conf'
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" 'resolve_peer_server_conf\(\)'
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" "printf '%s\\.udp\\.%s\\.ovpn"
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" "printf '%s\\.tcp\\.%s\\.ovpn"
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" 'validate_generated_client_artifacts\('
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" 'OPENVPN_CCD_DIR="\$TCP_CCD_DIR"'
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" 'OPENVPN_SUBNET_PREFIX="\$TCP_SUBNET_PREFIX"'
assert_contains "$ROOT_DIR/auto-openvpn-add-client.sh" 'peer_route_network'

assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'SERVER_CONF="\$\{SERVER_DIR\}/server-udp\.conf"'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'TCP_SERVER_CONF="\$\{SERVER_DIR\}/server-tcp\.conf"'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'UDP_CCD_DIR="\$\{OPENVPN_DIR\}/ccd-udp"'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'TCP_CCD_DIR="\$\{OPENVPN_DIR\}/ccd-tcp"'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'CLIENT_DIR="\$\{OPENVPN_DIR\}/client-udp-tcp"'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'CLIENT_COMMON_FILE="\$\{SERVER_DIR\}/client-common-udp-tcp\.txt"'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'ensure_common_artifact_names\(\)'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'ensure_tcp_server_conf\(\)'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'ensure_cross_subnet_routes\(\)'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'openvpn-server@server-udp\.service'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'openvpn-server@server-tcp\.service'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'openvpn-iptables-udp\.service'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'openvpn-iptables-tcp\.service'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'openvpn-iptables-tcp-udp-exchange-rules\.service'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'tcp_network'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'udp_network'
assert_contains "$ROOT_DIR/install-auto-openvpn.sh" 'server \$\{tcp_subnet_prefix\}\.0\.0 255\.255\.0\.0'

assert_contains "$ROOT_DIR/README.MD" 'auto-openvpn-add-client\.sh --proto tcp'
assert_contains "$ROOT_DIR/README.MD" 'server-udp\.conf'
assert_contains "$ROOT_DIR/README.MD" 'server-tcp\.conf'
assert_contains "$ROOT_DIR/README.MD" 'client-common-udp-tcp\.txt'
assert_contains "$ROOT_DIR/README.MD" 'client-udp-tcp'
assert_contains "$ROOT_DIR/README.MD" 'ccd-udp'
assert_contains "$ROOT_DIR/README.MD" 'openvpn-server@server-udp\.service'
assert_contains "$ROOT_DIR/README.MD" 'openvpn-server@server-tcp\.service'
assert_contains "$ROOT_DIR/README.MD" '172\.23\.0\.0/16'
assert_contains "$ROOT_DIR/README.MD" '默认互通'
assert_contains "$ROOT_DIR/README.MD" '只有选择 `all` 时，才会吊销共享证书'

echo "dual protocol contract checks passed"
