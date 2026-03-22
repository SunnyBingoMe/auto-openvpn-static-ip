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
UDP_CCD_DIR="${OPENVPN_DIR}/ccd-udp"
CCD_DIR="${OPENVPN_DIR}/ccd"
TCP_CCD_DIR="${OPENVPN_DIR}/ccd-tcp"
CLIENT_DIR="${OPENVPN_DIR}/client-udp-tcp"
SERVER_CONF="${SERVER_DIR}/server-udp.conf"
TCP_SERVER_CONF="${SERVER_DIR}/server-tcp.conf"
EASYRSA_DIR="${SERVER_DIR}/easy-rsa"
UDP_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-udp.service"
TCP_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-tcp.service"
EXTRA_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-udp-tcp-extra.service"
UDP_IPP_FILE="${SERVER_DIR}/ipp-udp.txt"
TCP_IPP_FILE="${SERVER_DIR}/ipp-tcp.txt"
CLIENT_COMMON_FILE="${SERVER_DIR}/client-common-udp-tcp.txt"
PWD_AUTH_DIR="${SERVER_DIR}/client-pwd-auth"
PWD_AUTH_VERIFY_SCRIPT="${SERVER_DIR}/openvpn-pwd-auth-verify.sh"

ASSIGN_SOURCE="${SCRIPT_DIR}/to-assign-ip-to-client.sh"
CLIENT_SOURCE="${SCRIPT_DIR}/auto-openvpn-add-client.sh"
REVOKE_SOURCE="${SCRIPT_DIR}/auto-openvpn-revoke-client.sh"
INSTALL_SOURCE="${SCRIPT_DIR}/to-get-from-hwdsl2.sh"

ASSIGN_TARGET="${SERVER_DIR}/to-assign-ip-to-client.sh"
CLIENT_TARGET="${SERVER_DIR}/auto-openvpn-add-client.sh"
REVOKE_TARGET="${SERVER_DIR}/auto-openvpn-revoke-client.sh"
INSTALL_TARGET="${SERVER_DIR}/to-get-from-hwdsl2.sh"
CLIENT_LINK="/usr/local/sbin/auto-openvpn-add-client.sh"
REVOKE_LINK="/usr/local/sbin/auto-openvpn-revoke-client.sh"

deploy_file() {
  local source_file="$1"
  local target_file="$2"
  local mode="$3"

  install -m "$mode" "$source_file" "$target_file"
}

ensure_server_conf_has_ccd() {
  if [ ! -f "$SERVER_CONF" ]; then
    echo "OpenVPN server config not found: $SERVER_CONF" >&2
    exit 1
  fi

  ensure_conf_has_line "$SERVER_CONF" "client-config-dir ${UDP_CCD_DIR}"
}

extract_server_network() {
  local conf_file="$1"

  awk '$1 == "server" { print $2; exit }' "$conf_file"
}

extract_server_mask() {
  local conf_file="$1"

  awk '$1 == "server" { print $3; exit }' "$conf_file"
}

ensure_conf_has_line() {
  local conf_file="$1"
  local line="$2"

  if ! grep -Fqs "$line" "$conf_file"; then
    printf '\n%s\n' "$line" >> "$conf_file"
  fi
}

deploy_pwd_auth_verify_script() {
  cat > "$PWD_AUTH_VERIFY_SCRIPT" <<'EOF'
#!/bin/bash
set -euo pipefail

pwd_auth_file="$1"
pwd_cred_store="/etc/openvpn/server/client-pwd-auth"
client_file="$pwd_cred_store/${common_name}.credentials"

[ -f "$pwd_auth_file" ] || exit 1
[ -f "$client_file" ] || exit 1

username="$(sed -n '1p' "$pwd_auth_file")"
password="$(sed -n '2p' "$pwd_auth_file")"
[ -n "$username" ] || exit 1

while IFS=: read -r stored_user stored_password; do
  [ "$stored_user" = "$username" ] || continue
  stored_password="${stored_password//\\:/:}"
  stored_password="${stored_password//\\\\/\\}"
  [ "$stored_password" = "$password" ] || exit 1
  exit 0
done < "$client_file"

exit 1
EOF

  chmod 700 "$PWD_AUTH_VERIFY_SCRIPT"
}

ensure_server_conf_has_pwd_auth() {
  local conf_file="$1"

  ensure_conf_has_line "$conf_file" "script-security 2"
  ensure_conf_has_line "$conf_file" "auth-user-pass-verify ${PWD_AUTH_VERIFY_SCRIPT} via-file"
}

extract_server_value() {
  local conf_file="$1"
  local key="$2"

  awk -v key="$key" '$1 == key { print $2; exit }' "$conf_file"
}

ensure_tcp_server_conf() {
  local udp_port
  local tcp_port
  local tcp_subnet_prefix

  if [ ! -f "$SERVER_CONF" ]; then
    echo "OpenVPN server config not found: $SERVER_CONF" >&2
    exit 1
  fi

  udp_port="$(extract_server_value "$SERVER_CONF" port)"
  [ -n "$udp_port" ] || udp_port=1194
  tcp_port="${OPENVPN_TCP_PORT:-$udp_port}"
  tcp_subnet_prefix="${OPENVPN_TCP_SUBNET_PREFIX:-172.23}"

  cp "$SERVER_CONF" "$TCP_SERVER_CONF"
  sed -i "s/^proto .*/proto tcp/" "$TCP_SERVER_CONF"
  sed -i "s/^port .*/port ${tcp_port}/" "$TCP_SERVER_CONF"
  sed -i "s#^server .*#server ${tcp_subnet_prefix}.0.0 255.255.0.0#" "$TCP_SERVER_CONF"
  sed -i "s#^client-config-dir .*#client-config-dir ${TCP_CCD_DIR}#" "$TCP_SERVER_CONF"
  sed -i "s#^ifconfig-pool-persist .*#ifconfig-pool-persist ${TCP_IPP_FILE}#" "$TCP_SERVER_CONF"
  sed -i '/^explicit-exit-notify$/d' "$TCP_SERVER_CONF"

  ensure_conf_has_line "$TCP_SERVER_CONF" "client-config-dir ${TCP_CCD_DIR}"
  ensure_server_conf_has_pwd_auth "$TCP_SERVER_CONF"
}

ensure_udp_server_conf() {
  sed -i "s#^client-config-dir .*#client-config-dir ${UDP_CCD_DIR}#" "$SERVER_CONF"
  sed -i "s#^ifconfig-pool-persist .*#ifconfig-pool-persist ${UDP_IPP_FILE}#" "$SERVER_CONF"
  ensure_conf_has_line "$SERVER_CONF" "client-config-dir ${UDP_CCD_DIR}"
  ensure_server_conf_has_pwd_auth "$SERVER_CONF"
}

ensure_common_artifact_names() {
  local legacy_udp_conf="${SERVER_DIR}/server.conf"
  local legacy_common_file="${SERVER_DIR}/client-common.txt"
  local legacy_client_dir="${OPENVPN_DIR}/client"

  mkdir -p "$UDP_CCD_DIR" "$TCP_CCD_DIR" "$CLIENT_DIR"
  mkdir -p "$PWD_AUTH_DIR"

  if [ -f "$legacy_udp_conf" ] && [ ! -f "$SERVER_CONF" ]; then
    mv "$legacy_udp_conf" "$SERVER_CONF"
  fi

  if [ -f "$legacy_common_file" ] && [ ! -f "$CLIENT_COMMON_FILE" ]; then
    mv "$legacy_common_file" "$CLIENT_COMMON_FILE"
  fi

  if [ -d "$legacy_client_dir" ] && [ ! -L "$legacy_client_dir" ]; then
    mv "$legacy_client_dir"/* "$CLIENT_DIR"/ 2>/dev/null || true
    rmdir "$legacy_client_dir" 2>/dev/null || true
  fi

  rm -f "$legacy_udp_conf" "$legacy_common_file" "$legacy_client_dir" "$CCD_DIR" "/etc/systemd/system/openvpn-iptables.service" 2>/dev/null || true
  ln -sfn "$SERVER_CONF" "$legacy_udp_conf"
  ln -sfn "$CLIENT_COMMON_FILE" "$legacy_common_file"
  ln -sfn "$CLIENT_DIR" "$legacy_client_dir"
  ln -sfn "$UDP_CCD_DIR" "$CCD_DIR"

  if [ -f "/etc/systemd/system/openvpn-iptables.service" ] && [ ! -e "$UDP_FIREWALL_SERVICE" ]; then
    mv "/etc/systemd/system/openvpn-iptables.service" "$UDP_FIREWALL_SERVICE"
  fi
  if [ -e "$UDP_FIREWALL_SERVICE" ]; then
    ln -sfn "$UDP_FIREWALL_SERVICE" "/etc/systemd/system/openvpn-iptables.service"
  fi

  if [ -f "$CLIENT_COMMON_FILE" ]; then
    sed -i "s#^route .*#route 172.22.0.0 255.255.0.0#" "$CLIENT_COMMON_FILE"
    if ! grep -Fqs "auth-user-pass" "$CLIENT_COMMON_FILE"; then
      printf '\nauth-user-pass\n' >> "$CLIENT_COMMON_FILE"
    fi
  fi
}

ensure_cross_subnet_routes() {
  local udp_network
  local udp_mask
  local tcp_network
  local tcp_mask

  udp_network="$(extract_server_network "$SERVER_CONF")"
  udp_mask="$(extract_server_mask "$SERVER_CONF")"
  tcp_network="$(extract_server_network "$TCP_SERVER_CONF")"
  tcp_mask="$(extract_server_mask "$TCP_SERVER_CONF")"

  [ -n "$udp_network" ] && [ -n "$udp_mask" ] && [ -n "$tcp_network" ] && [ -n "$tcp_mask" ] || {
    echo "Failed to determine VPN subnet routes from server configs" >&2
    exit 1
  }

  ensure_conf_has_line "$SERVER_CONF" "push \"route ${tcp_network} ${tcp_mask}\""
  ensure_conf_has_line "$TCP_SERVER_CONF" "push \"route ${udp_network} ${udp_mask}\""
}

ensure_tcp_firewall() {
  local tcp_port
  local iptables_path
  local udp_network
  local tcp_network

  tcp_port="$(extract_server_value "$TCP_SERVER_CONF" port)"
  [ -n "$tcp_port" ] || tcp_port=1194
  udp_network="$(extract_server_network "$SERVER_CONF")"
  tcp_network="$(extract_server_network "$TCP_SERVER_CONF")"

  if systemctl is-active --quiet firewalld.service; then
    firewall-cmd -q --zone=trusted --add-source="${tcp_network}/16"
    firewall-cmd -q --permanent --zone=trusted --add-source="${tcp_network}/16"
    firewall-cmd -q --add-port="${tcp_port}/tcp"
    firewall-cmd -q --permanent --add-port="${tcp_port}/tcp"
    firewall-cmd -q --direct --remove-rule ipv4 nat POSTROUTING 0 -s "${udp_network}/16" ! -d "${udp_network}/16" -j MASQUERADE >/dev/null 2>&1 || true
    firewall-cmd -q --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s "${udp_network}/16" ! -d "${udp_network}/16" -j MASQUERADE >/dev/null 2>&1 || true
    firewall-cmd -q --direct --add-rule ipv4 nat POSTROUTING 0 -s "${udp_network}/16" -d "${tcp_network}/16" -j RETURN
    firewall-cmd -q --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s "${udp_network}/16" -d "${tcp_network}/16" -j RETURN
    firewall-cmd -q --direct --add-rule ipv4 nat POSTROUTING 0 -s "${tcp_network}/16" -d "${udp_network}/16" -j RETURN
    firewall-cmd -q --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s "${tcp_network}/16" -d "${udp_network}/16" -j RETURN
    firewall-cmd -q --direct --add-rule ipv4 nat POSTROUTING 1 -s "${udp_network}/16" ! -d "${udp_network}/16" ! -d "${tcp_network}/16" -j MASQUERADE
    firewall-cmd -q --permanent --direct --add-rule ipv4 nat POSTROUTING 1 -s "${udp_network}/16" ! -d "${udp_network}/16" ! -d "${tcp_network}/16" -j MASQUERADE
    firewall-cmd -q --direct --add-rule ipv4 nat POSTROUTING 1 -s "${tcp_network}/16" ! -d "${udp_network}/16" ! -d "${tcp_network}/16" -j MASQUERADE
    firewall-cmd -q --permanent --direct --add-rule ipv4 nat POSTROUTING 1 -s "${tcp_network}/16" ! -d "${udp_network}/16" ! -d "${tcp_network}/16" -j MASQUERADE
    return 0
  fi

  iptables_path="$(command -v iptables)"
  cat > "$TCP_FIREWALL_SERVICE" <<EOF
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=${iptables_path} -w 5 -I INPUT -p tcp --dport ${tcp_port} -j ACCEPT
ExecStop=${iptables_path} -w 5 -D INPUT -p tcp --dport ${tcp_port} -j ACCEPT
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now openvpn-iptables-tcp.service >/dev/null 2>&1

  cat > "$EXTRA_FIREWALL_SERVICE" <<EOF
[Unit]
After=network-online.target openvpn-iptables-udp.service openvpn-iptables-tcp.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=${iptables_path} -w 5 -I FORWARD -s ${tcp_network}/16 -j ACCEPT
ExecStart=${iptables_path} -w 5 -t nat -I POSTROUTING -s ${udp_network}/16 -d ${tcp_network}/16 -j RETURN
ExecStart=${iptables_path} -w 5 -t nat -I POSTROUTING -s ${tcp_network}/16 -d ${udp_network}/16 -j RETURN
ExecStart=${iptables_path} -w 5 -t nat -A POSTROUTING -s ${tcp_network}/16 ! -d ${udp_network}/16 ! -d ${tcp_network}/16 -j MASQUERADE
ExecStop=${iptables_path} -w 5 -D FORWARD -s ${tcp_network}/16 -j ACCEPT
ExecStop=${iptables_path} -w 5 -t nat -D POSTROUTING -s ${udp_network}/16 -d ${tcp_network}/16 -j RETURN
ExecStop=${iptables_path} -w 5 -t nat -D POSTROUTING -s ${tcp_network}/16 -d ${udp_network}/16 -j RETURN
ExecStop=${iptables_path} -w 5 -t nat -D POSTROUTING -s ${tcp_network}/16 ! -d ${udp_network}/16 ! -d ${tcp_network}/16 -j MASQUERADE
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now openvpn-iptables-udp-tcp-extra.service >/dev/null 2>&1
}

ensure_tcp_selinux_port() {
  local tcp_port

  if ! command -v sestatus >/dev/null 2>&1 || ! command -v semanage >/dev/null 2>&1; then
    return 0
  fi

  if ! sestatus 2>/dev/null | grep -q 'Current mode:.*enforcing'; then
    return 0
  fi

  tcp_port="$(extract_server_value "$TCP_SERVER_CONF" port)"
  [ -n "$tcp_port" ] || tcp_port=1194

  if [ "$tcp_port" = "1194" ]; then
    return 0
  fi

  if ! semanage port -l | grep -Eq "^openvpn_port_t[[:space:]]+tcp[[:space:]].*\b${tcp_port}\b"; then
    semanage port -a -t openvpn_port_t -p tcp "$tcp_port" >/dev/null 2>&1 \
      || semanage port -m -t openvpn_port_t -p tcp "$tcp_port" >/dev/null 2>&1
  fi
}

ensure_initial_client_ccd() {
  if [ -f "${EASYRSA_DIR}/pki/issued/client.crt" ] && [ ! -f "${CCD_DIR}/client" ]; then
    "$ASSIGN_TARGET" client
  fi
}

restart_openvpn() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true

  if [ -f "$SERVER_CONF" ]; then
    systemctl disable --now openvpn-server@server.service >/dev/null 2>&1 || true
    systemctl restart openvpn-server@server-udp.service >/dev/null 2>&1 \
      || systemctl enable --now openvpn-server@server-udp.service >/dev/null 2>&1 \
      || true
  fi

  if [ -f "$TCP_SERVER_CONF" ]; then
    systemctl restart openvpn-server@server-tcp.service >/dev/null 2>&1 \
      || systemctl enable --now openvpn-server@server-tcp.service >/dev/null 2>&1 \
      || true
  fi
}

for required_file in "$ASSIGN_SOURCE" "$CLIENT_SOURCE" "$REVOKE_SOURCE" "$INSTALL_SOURCE"; do
  if [ ! -f "$required_file" ]; then
    echo "Required file not found: $required_file" >&2
    exit 1
  fi
done

if { [ ! -f "$SERVER_CONF" ] && [ ! -f "${SERVER_DIR}/server.conf" ]; } || [ ! -d "$EASYRSA_DIR" ]; then
  bash "$INSTALL_SOURCE" --auto
fi

mkdir -p "$SERVER_DIR" "$UDP_CCD_DIR" "$TCP_CCD_DIR" "$CLIENT_DIR"
mkdir -p "$PWD_AUTH_DIR"

deploy_file "$INSTALL_SOURCE" "$INSTALL_TARGET" 700
deploy_file "$CLIENT_SOURCE" "$CLIENT_TARGET" 700
deploy_file "$REVOKE_SOURCE" "$REVOKE_TARGET" 700
deploy_file "$ASSIGN_SOURCE" "$ASSIGN_TARGET" 700
deploy_pwd_auth_verify_script

ensure_common_artifact_names

chmod 700 "$UDP_CCD_DIR"
chmod 700 "$TCP_CCD_DIR"
chmod 700 "$CLIENT_DIR"

ensure_server_conf_has_ccd
ensure_udp_server_conf
ensure_tcp_server_conf
ensure_cross_subnet_routes
ensure_tcp_firewall
ensure_tcp_selinux_port
ensure_initial_client_ccd
restart_openvpn

ln -sfn "$CLIENT_TARGET" "$CLIENT_LINK"
ln -sfn "$REVOKE_TARGET" "$REVOKE_LINK"

echo "OpenVPN install completed."
echo "Server config: $SERVER_CONF"
echo "TCP server config: $TCP_SERVER_CONF"
echo "UDP CCD dir: $UDP_CCD_DIR"
echo "TCP CCD dir: $TCP_CCD_DIR"
echo "Client profiles dir: $CLIENT_DIR"
echo "Client creation command: $CLIENT_LINK [--proto udp|tcp] <client-name>"
echo "Client revocation command: $REVOKE_LINK <client-name>"
