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
TCP_CCD_DIR="${OPENVPN_DIR}/ccd-tcp"
CLIENT_DIR="${OPENVPN_DIR}/client-udp-tcp"
SERVER_CONF="${SERVER_DIR}/server-udp.conf"
TCP_SERVER_CONF="${SERVER_DIR}/server-tcp.conf"
EASYRSA_DIR="${SERVER_DIR}/easy-rsa"
UDP_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-udp.service"
TCP_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-tcp.service"
TCP_UDP_EXCHANGE_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-tcp-udp-exchange-rules.service"
UDP_IPP_FILE="${SERVER_DIR}/ipp-udp.txt"
TCP_IPP_FILE="${SERVER_DIR}/ipp-tcp.txt"
CLIENT_COMMON_FILE="${SERVER_DIR}/client-common-udp-tcp.txt"
PWD_AUTH_DIR="${SERVER_DIR}/client-pwd-auth"
PWD_AUTH_VERIFY_SCRIPT="${SERVER_DIR}/openvpn-pwd-auth-verify.sh"
CLIENT_OPENVPN_DIR="${OPENVPN_DIR}/client"

ASSIGN_SOURCE="${SCRIPT_DIR}/to-assign-ip-to-client.sh"
CLIENT_SOURCE="${SCRIPT_DIR}/auto-openvpn-add-client.sh"
REVOKE_SOURCE="${SCRIPT_DIR}/auto-openvpn-revoke-client.sh"
INSTALL_SOURCE="${SCRIPT_DIR}/to-get-from-hwdsl2.sh"
FIX_ROUTE_SOURCE="${SCRIPT_DIR}/fix-route.sh"

ASSIGN_TARGET="${SERVER_DIR}/to-assign-ip-to-client.sh"
CLIENT_TARGET="${SERVER_DIR}/auto-openvpn-add-client.sh"
REVOKE_TARGET="${SERVER_DIR}/auto-openvpn-revoke-client.sh"
INSTALL_TARGET="${SERVER_DIR}/to-get-from-hwdsl2.sh"
FIX_ROUTE_TARGET="${CLIENT_OPENVPN_DIR}/fix-routes.sh"
CLIENT_LINK="/usr/local/sbin/auto-openvpn-add-client.sh"
REVOKE_LINK="/usr/local/sbin/auto-openvpn-revoke-client.sh"
UDP_OPENVPN_SERVICE="openvpn-server@server-udp.service"
TCP_OPENVPN_SERVICE="openvpn-server@server-tcp.service"
SYSTEMD_DIR="/etc/systemd/system"
UDP_OPENVPN_DROPIN_DIR="${SYSTEMD_DIR}/openvpn-server@server-udp.service.d"
TCP_OPENVPN_DROPIN_DIR="${SYSTEMD_DIR}/openvpn-server@server-tcp.service.d"
OPENVPN_ROLE=""

prompt_for_openvpn_role() {
  local role_choice

  while true; do
    echo
    read -r -p "本机是 client 还是 server？(可以只输入首字母) [client/server] (default: client): " role_choice
    if [ -z "$role_choice" ]; then
      OPENVPN_ROLE="client"
      return 0
    fi

    case "${role_choice:0:1}" in
      [Cc])
        OPENVPN_ROLE="client"
        return 0
        ;;
      [Ss])
        OPENVPN_ROLE="server"
        return 0
        ;;
    esac

    echo "Invalid role choice. Allowed values: client, server" >&2
  done
}

ask_yes_no() {
  local prompt="$1"
  local default_answer="$2"
  local reply

  while true; do
    if [ "$default_answer" = "y" ]; then
      read -r -p "$prompt [Y/n]: " reply
      reply="${reply:-Y}"
    else
      read -r -p "$prompt [y/N]: " reply
      reply="${reply:-N}"
    fi

    case "$reply" in
      [Yy]|[Yy][Ee][Ss])
        return 0
        ;;
      [Nn]|[Nn][Oo])
        return 1
        ;;
      *)
        echo "Please answer yes or no."
        ;;
    esac
  done
}

run_root_cmd() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

deploy_file() {
  local source_file="$1"
  local target_file="$2"
  local mode="$3"

  install -m "$mode" "$source_file" "$target_file"
}

install_exists() {
  [ -f "$SERVER_CONF" ] || [ -d "$EASYRSA_DIR" ]
}

refresh_client_common_template() {
  local tmp_file
  local udp_network
  local udp_mask

  if [ ! -f "$CLIENT_COMMON_FILE" ]; then
    echo "Client template not found for overwrite: $CLIENT_COMMON_FILE" >&2
    echo "Refusing to guess the advertised client endpoint. Re-run a fresh install or restore a valid template first." >&2
    exit 1
  fi

  udp_network="$(extract_server_network "$SERVER_CONF")"
  udp_mask="$(extract_server_mask "$SERVER_CONF")"
  [ -n "$udp_network" ] || udp_network="172.22.0.0"
  [ -n "$udp_mask" ] || udp_mask="255.255.0.0"
  tmp_file="$(mktemp "${CLIENT_COMMON_FILE}.tmp.XXXXXX")"

  awk -v udp_network="$udp_network" -v udp_mask="$udp_mask" '
    BEGIN {
      saw_auth_user_pass = 0
      saw_ignore_unknown = 0
      saw_redirect_filter = 0
      saw_dns_filter = 0
      saw_route_nopull = 0
      saw_route = 0
    }
    $1 == "auth-user-pass" {
      if (!saw_auth_user_pass) {
        print "auth-user-pass"
        saw_auth_user_pass = 1
      }
      next
    }
    $1 == "ignore-unknown-option" {
      if (!saw_ignore_unknown) {
        print "ignore-unknown-option block-outside-dns block-ipv6"
        saw_ignore_unknown = 1
      }
      next
    }
    $1 == "pull-filter" && $2 == "ignore" && $3 == "redirect-gateway" {
      if (!saw_redirect_filter) {
        print "pull-filter ignore redirect-gateway"
        saw_redirect_filter = 1
      }
      next
    }
    $1 == "pull-filter" && $2 == "ignore" && ($3 == "dhcp-option" || $3 == "\"dhcp-option") {
      if (!saw_dns_filter) {
        print "pull-filter ignore \"dhcp-option DNS\""
        saw_dns_filter = 1
      }
      next
    }
    $1 == "route-nopull" {
      if (!saw_route_nopull) {
        print "route-nopull"
        saw_route_nopull = 1
      }
      next
    }
    $1 == "route" {
      if (!saw_route) {
        print "route " udp_network " " udp_mask
        saw_route = 1
      }
      next
    }
    {
      print
    }
    END {
      if (!saw_auth_user_pass) {
        print "auth-user-pass"
      }
      if (!saw_ignore_unknown) {
        print "ignore-unknown-option block-outside-dns block-ipv6"
      }
      if (!saw_redirect_filter) {
        print "pull-filter ignore redirect-gateway"
      }
      if (!saw_dns_filter) {
        print "pull-filter ignore \"dhcp-option DNS\""
      }
      if (!saw_route_nopull) {
        print "route-nopull"
      }
      if (!saw_route) {
        print "route " udp_network " " udp_mask
      }
    }
  ' "$CLIENT_COMMON_FILE" > "$tmp_file"

  mv "$tmp_file" "$CLIENT_COMMON_FILE"
}

confirm_overwrite_existing_install() {
  if ! install_exists; then
    return 0
  fi

  echo "Detected an existing OpenVPN installation under $SERVER_DIR."
  echo "Overwrite will keep current PKI/certs, tc.key, CCD, IPP, and password-auth state when possible,"
  echo "then regenerate helper scripts, derived templates, and compatibility links."

  if ask_yes_no "Overwrite the existing installation and refresh generated config?" "y"; then
    return 0
  fi

  echo "Install cancelled."
  exit 0
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

# Clients without a credentials file fall back to cert-only auth.
[ -f "$client_file" ] || exit 0
[ -f "$pwd_auth_file" ] || exit 1

username="$(sed -n '1p' "$pwd_auth_file")"
password="$(sed -n '2p' "$pwd_auth_file")"
[ -n "$username" ] || exit 1
[ -n "$password" ] || exit 1

while IFS=: read -r stored_user stored_password; do
  [ "$stored_user" = "$username" ] || continue
  stored_password="${stored_password//\\:/:}"
  stored_password="${stored_password//\\\\/\\}"
  [ "$stored_password" = "$password" ] || exit 1
  exit 0
done < "$client_file"

exit 1
EOF

  chmod 750 "$PWD_AUTH_VERIFY_SCRIPT"
}

detect_openvpn_runtime_group() {
  local conf_file
  local runtime_group

  for conf_file in "$SERVER_CONF"; do
    [ -f "$conf_file" ] || continue
    runtime_group="$(awk '$1 == "group" { print $2; exit }' "$conf_file")"
    if [ -n "$runtime_group" ] && getent group "$runtime_group" >/dev/null 2>&1; then
      printf '%s\n' "$runtime_group"
      return 0
    fi
  done

  for runtime_group in nogroup nobody; do
    if getent group "$runtime_group" >/dev/null 2>&1; then
      printf '%s\n' "$runtime_group"
      return 0
    fi
  done

  return 1
}

ensure_runtime_state_access() {
  local runtime_group

  runtime_group="$(detect_openvpn_runtime_group)" || {
    echo "Failed to determine OpenVPN runtime group for runtime state files" >&2
    exit 1
  }

  chown root:"$runtime_group" "$SERVER_DIR" "$UDP_CCD_DIR" "$TCP_CCD_DIR"
  chmod 750 "$SERVER_DIR" "$UDP_CCD_DIR" "$TCP_CCD_DIR"

  if [ -f "$SERVER_CONF" ]; then
    chown root:"$runtime_group" "$SERVER_CONF"
    chmod 640 "$SERVER_CONF"
  fi

  if [ -f "$TCP_SERVER_CONF" ]; then
    chown root:"$runtime_group" "$TCP_SERVER_CONF"
    chmod 640 "$TCP_SERVER_CONF"
  fi

  if [ -f "$CLIENT_COMMON_FILE" ]; then
    chown root:"$runtime_group" "$CLIENT_COMMON_FILE"
    chmod 640 "$CLIENT_COMMON_FILE"
  fi

  if [ -f "$UDP_IPP_FILE" ]; then
    chown root:"$runtime_group" "$UDP_IPP_FILE"
    chmod 640 "$UDP_IPP_FILE"
  fi

  if [ -f "$TCP_IPP_FILE" ]; then
    chown root:"$runtime_group" "$TCP_IPP_FILE"
    chmod 640 "$TCP_IPP_FILE"
  fi

  find "$UDP_CCD_DIR" -maxdepth 1 -type f -exec chown root:"$runtime_group" {} +
  find "$UDP_CCD_DIR" -maxdepth 1 -type f -exec chmod 640 {} +
  find "$TCP_CCD_DIR" -maxdepth 1 -type f -exec chown root:"$runtime_group" {} +
  find "$TCP_CCD_DIR" -maxdepth 1 -type f -exec chmod 640 {} +
}

ensure_pwd_auth_access() {
  local runtime_group

  runtime_group="$(detect_openvpn_runtime_group)" || {
    echo "Failed to determine OpenVPN runtime group for password auth files" >&2
    exit 1
  }

  mkdir -p "$PWD_AUTH_DIR"
  chown root:"$runtime_group" "$PWD_AUTH_DIR" "$PWD_AUTH_VERIFY_SCRIPT"
  chmod 750 "$PWD_AUTH_DIR" "$PWD_AUTH_VERIFY_SCRIPT"

  find "$PWD_AUTH_DIR" -maxdepth 1 -type f -name '*.credentials' \
    -exec chown root:"$runtime_group" {} +
  find "$PWD_AUTH_DIR" -maxdepth 1 -type f -name '*.credentials' \
    -exec chmod 640 {} +
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
  mkdir -p "$UDP_CCD_DIR" "$TCP_CCD_DIR" "$CLIENT_DIR"
  mkdir -p "$PWD_AUTH_DIR"

  if [ -f "$CLIENT_COMMON_FILE" ]; then
    sed -i "s#^route .*#route 172.22.0.0 255.255.0.0#" "$CLIENT_COMMON_FILE"
    if ! grep -Fqs "auth-user-pass" "$CLIENT_COMMON_FILE"; then
      printf '\nauth-user-pass\n' >> "$CLIENT_COMMON_FILE"
    fi
  fi
}

cleanup_upstream_single_stack_artifacts() {
  local upstream_client_dir="${OPENVPN_DIR}/client"
  local upstream_server_conf="${SERVER_DIR}/server.conf"
  local upstream_client_common="${SERVER_DIR}/client-common.txt"
  local upstream_firewall_unit="/etc/systemd/system/openvpn-iptables.service"

  if [ -f "$upstream_server_conf" ] && [ ! -f "$SERVER_CONF" ]; then
    mv "$upstream_server_conf" "$SERVER_CONF"
  fi
  rm -f "$upstream_server_conf"

  if [ -f "$upstream_client_common" ] && [ ! -f "$CLIENT_COMMON_FILE" ]; then
    mv "$upstream_client_common" "$CLIENT_COMMON_FILE"
  fi
  rm -f "$upstream_client_common"

  if [ -d "$upstream_client_dir" ] && [ ! -L "$upstream_client_dir" ]; then
    mv "$upstream_client_dir"/* "$CLIENT_DIR"/ 2>/dev/null || true
    rmdir "$upstream_client_dir" 2>/dev/null || true
  fi
  rm -rf "$upstream_client_dir"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now openvpn-iptables.service >/dev/null 2>&1 || true
  fi
  rm -f "$upstream_firewall_unit"

  if [ -f /etc/rc.local ]; then
    sed --follow-symlinks -i '/^systemctl restart openvpn-iptables\.service$/d' /etc/rc.local
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

ensure_firewall_services() {
  local udp_port
  local tcp_port
  local iptables_path
  local udp_network
  local tcp_network

  udp_port="$(extract_server_value "$SERVER_CONF" port)"
  tcp_port="$(extract_server_value "$TCP_SERVER_CONF" port)"
  [ -n "$udp_port" ] || udp_port=1194
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
  cat > "$UDP_FIREWALL_SERVICE" <<EOF
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -lc '${iptables_path} -w 5 -C INPUT -p udp --dport ${udp_port} -j ACCEPT || ${iptables_path} -w 5 -I INPUT -p udp --dport ${udp_port} -j ACCEPT'
ExecStart=/bin/bash -lc '${iptables_path} -w 5 -C FORWARD -s ${udp_network}/16 -j ACCEPT || ${iptables_path} -w 5 -I FORWARD -s ${udp_network}/16 -j ACCEPT'
ExecStart=/bin/bash -lc '${iptables_path} -w 5 -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT || ${iptables_path} -w 5 -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT'
ExecStart=/bin/bash -lc '${iptables_path} -w 5 -t nat -C POSTROUTING -s ${udp_network}/16 ! -d ${udp_network}/16 -j MASQUERADE || ${iptables_path} -w 5 -t nat -A POSTROUTING -s ${udp_network}/16 ! -d ${udp_network}/16 -j MASQUERADE'
ExecStop=${iptables_path} -w 5 -D INPUT -p udp --dport ${udp_port} -j ACCEPT
ExecStop=${iptables_path} -w 5 -D FORWARD -s ${udp_network}/16 -j ACCEPT
ExecStop=${iptables_path} -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=${iptables_path} -w 5 -t nat -D POSTROUTING -s ${udp_network}/16 ! -d ${udp_network}/16 -j MASQUERADE
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

  cat > "$TCP_FIREWALL_SERVICE" <<EOF
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -lc '${iptables_path} -w 5 -C INPUT -p tcp --dport ${tcp_port} -j ACCEPT || ${iptables_path} -w 5 -I INPUT -p tcp --dport ${tcp_port} -j ACCEPT'
ExecStop=${iptables_path} -w 5 -D INPUT -p tcp --dport ${tcp_port} -j ACCEPT
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

  cat > "$TCP_UDP_EXCHANGE_FIREWALL_SERVICE" <<EOF
[Unit]
After=network-online.target openvpn-iptables-udp.service openvpn-iptables-tcp.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -lc '${iptables_path} -w 5 -C FORWARD -s ${tcp_network}/16 -j ACCEPT || ${iptables_path} -w 5 -I FORWARD -s ${tcp_network}/16 -j ACCEPT'
ExecStart=/bin/bash -lc '${iptables_path} -w 5 -t nat -C POSTROUTING -s ${udp_network}/16 -d ${tcp_network}/16 -j RETURN || ${iptables_path} -w 5 -t nat -I POSTROUTING -s ${udp_network}/16 -d ${tcp_network}/16 -j RETURN'
ExecStart=/bin/bash -lc '${iptables_path} -w 5 -t nat -C POSTROUTING -s ${tcp_network}/16 -d ${udp_network}/16 -j RETURN || ${iptables_path} -w 5 -t nat -I POSTROUTING -s ${tcp_network}/16 -d ${udp_network}/16 -j RETURN'
ExecStart=/bin/bash -lc '${iptables_path} -w 5 -t nat -C POSTROUTING -s ${tcp_network}/16 ! -d ${udp_network}/16 -m addrtype ! --dst-type LOCAL -j MASQUERADE || ${iptables_path} -w 5 -t nat -A POSTROUTING -s ${tcp_network}/16 ! -d ${udp_network}/16 -m addrtype ! --dst-type LOCAL -j MASQUERADE'
ExecStop=${iptables_path} -w 5 -D FORWARD -s ${tcp_network}/16 -j ACCEPT
ExecStop=${iptables_path} -w 5 -t nat -D POSTROUTING -s ${udp_network}/16 -d ${tcp_network}/16 -j RETURN
ExecStop=${iptables_path} -w 5 -t nat -D POSTROUTING -s ${tcp_network}/16 -d ${udp_network}/16 -j RETURN
ExecStop=${iptables_path} -w 5 -t nat -D POSTROUTING -s ${tcp_network}/16 ! -d ${udp_network}/16 -m addrtype ! --dst-type LOCAL -j MASQUERADE
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

  run_root_cmd systemctl daemon-reload
  run_root_cmd systemctl enable --now openvpn-iptables-udp.service
  run_root_cmd systemctl enable --now openvpn-iptables-tcp.service
  run_root_cmd systemctl enable --now openvpn-iptables-tcp-udp-exchange-rules.service
}

ensure_tcp_selinux_port() {
  local tcp_port

  if ! has_command sestatus || ! has_command semanage; then
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
    run_root_cmd semanage port -a -t openvpn_port_t -p tcp "$tcp_port" >/dev/null 2>&1 \
      || run_root_cmd semanage port -m -t openvpn_port_t -p tcp "$tcp_port" >/dev/null 2>&1
  fi
}

ensure_initial_client_ccd() {
  if [ -f "${EASYRSA_DIR}/pki/issued/client.crt" ] && [ ! -f "${UDP_CCD_DIR}/client" ]; then
    "$ASSIGN_TARGET" client
  fi
}

sync_openvpn_dropins() {
  local target_dir="$1"

  mkdir -p "$target_dir"
}

migrate_openvpn_instances() {
  if ! has_command systemctl; then
    return 0
  fi

  if [ -f "$SERVER_CONF" ]; then
    sync_openvpn_dropins "$UDP_OPENVPN_DROPIN_DIR"
  fi

  if [ -f "$TCP_SERVER_CONF" ]; then
    sync_openvpn_dropins "$TCP_OPENVPN_DROPIN_DIR"
  fi

}

restart_openvpn() {
  if ! has_command systemctl; then
    return 0
  fi

  run_root_cmd systemctl daemon-reload >/dev/null 2>&1 || true

  if [ -f "$SERVER_CONF" ]; then
    run_root_cmd systemctl enable "$UDP_OPENVPN_SERVICE" || true
    run_root_cmd systemctl restart "$UDP_OPENVPN_SERVICE" \
      || run_root_cmd systemctl start "$UDP_OPENVPN_SERVICE" \
      || true
  fi

  if [ -f "$TCP_SERVER_CONF" ]; then
    run_root_cmd systemctl enable "$TCP_OPENVPN_SERVICE" || true
    run_root_cmd systemctl restart "$TCP_OPENVPN_SERVICE" \
      || run_root_cmd systemctl start "$TCP_OPENVPN_SERVICE" \
      || true
  fi
}
print_post_install_checks() {
  echo
  echo "Auto-check: OpenVPN service status"
  run_root_cmd systemctl status "$UDP_OPENVPN_SERVICE" "$TCP_OPENVPN_SERVICE" --no-pager || true

  echo
  echo "Auto-check: OpenVPN listening sockets"
  ss -lntup | grep -E 'openvpn|:1194\b' || true
}

for required_file in "$ASSIGN_SOURCE" "$CLIENT_SOURCE" "$REVOKE_SOURCE" "$INSTALL_SOURCE" "$FIX_ROUTE_SOURCE"; do
  if [ ! -f "$required_file" ]; then
    echo "Required file not found: $required_file" >&2
    exit 1
  fi
done

prompt_for_openvpn_role
confirm_overwrite_existing_install

if [ "$OPENVPN_ROLE" = "server" ] && [ ! -f "$SERVER_CONF" ] || [ ! -d "$EASYRSA_DIR" ]; then
  run_root_cmd bash "$INSTALL_SOURCE" --auto
fi

if [ "$OPENVPN_ROLE" = "server" ]; then
  mkdir -p "$SERVER_DIR" "$UDP_CCD_DIR" "$TCP_CCD_DIR" "$CLIENT_DIR" "$CLIENT_OPENVPN_DIR"
  mkdir -p "$PWD_AUTH_DIR"

  deploy_file "$INSTALL_SOURCE" "$INSTALL_TARGET" 700
  deploy_file "$CLIENT_SOURCE" "$CLIENT_TARGET" 700
  deploy_file "$REVOKE_SOURCE" "$REVOKE_TARGET" 700
  deploy_file "$ASSIGN_SOURCE" "$ASSIGN_TARGET" 700
  deploy_file "$FIX_ROUTE_SOURCE" "$FIX_ROUTE_TARGET" 700
  deploy_pwd_auth_verify_script

  cleanup_upstream_single_stack_artifacts
  ensure_common_artifact_names
  refresh_client_common_template
  ensure_pwd_auth_access

  chmod 700 "$CLIENT_DIR"

  ensure_server_conf_has_ccd
  ensure_udp_server_conf
  ensure_tcp_server_conf
  ensure_cross_subnet_routes
  ensure_runtime_state_access
  ensure_firewall_services
  ensure_tcp_selinux_port
  ensure_initial_client_ccd
  migrate_openvpn_instances
  restart_openvpn
else
  mkdir -p "$CLIENT_OPENVPN_DIR"
  deploy_file "$FIX_ROUTE_SOURCE" "$FIX_ROUTE_TARGET" 700
fi

ln -sfn "$CLIENT_TARGET" "$CLIENT_LINK"
ln -sfn "$REVOKE_TARGET" "$REVOKE_LINK"

echo "OpenVPN install completed."
if [ "$OPENVPN_ROLE" = "server" ]; then
  echo "Server config: $SERVER_CONF"
  echo "TCP server config: $TCP_SERVER_CONF"
  echo "UDP CCD dir: $UDP_CCD_DIR"
  echo "TCP CCD dir: $TCP_CCD_DIR"
  echo "Client profiles dir: $CLIENT_DIR"
  echo "Client creation command: $CLIENT_LINK [--proto udp|tcp] <client-name>"
  echo "Client revocation command: $REVOKE_LINK <client-name>"
  print_post_install_checks
else
  echo "Fix routes script: $FIX_ROUTE_TARGET"
fi
