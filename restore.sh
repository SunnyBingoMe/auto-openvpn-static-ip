#!/bin/bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0")"

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
CLIENT_COMMON_FILE="${SERVER_DIR}/client-common-udp-tcp.txt"
PWD_AUTH_DIR="${SERVER_DIR}/client-pwd-auth"
PWD_AUTH_VERIFY_SCRIPT="${SERVER_DIR}/openvpn-pwd-auth-verify.sh"
EASYRSA_DIR="${SERVER_DIR}/easy-rsa"
UDP_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-udp.service"
TCP_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-tcp.service"
TCP_UDP_EXCHANGE_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables-tcp-udp-exchange-rules.service"
LEGACY_FIREWALL_SERVICE="/etc/systemd/system/openvpn-iptables.service"
SYSCTL_FORWARD_FILE="/etc/sysctl.d/99-openvpn-forward.conf"
CLIENT_LINK="/usr/local/sbin/auto-openvpn-add-client.sh"
REVOKE_LINK="/usr/local/sbin/auto-openvpn-revoke-client.sh"
PUBLIC_IP_WARNINGS=()

ensure_conf_has_line() {
  local conf_file="$1"
  local line="$2"

  if ! grep -Fqs "$line" "$conf_file"; then
    printf '\n%s\n' "$line" >> "$conf_file"
  fi
}

extract_server_network() {
  local conf_file="$1"

  awk '$1 == "server" { print $2; exit }' "$conf_file"
}

extract_server_mask() {
  local conf_file="$1"

  awk '$1 == "server" { print $3; exit }' "$conf_file"
}

extract_server_value() {
  local conf_file="$1"
  local key="$2"

  awk -v key="$key" '$1 == key { print $2; exit }' "$conf_file"
}

host_has_ipv4() {
  local ip="$1"

  ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$ip"
}

is_ipv4() {
  local candidate="$1"

  grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$candidate"
}

fetch_url_ipv4() {
  local url="$1"
  local response=""

  if command -v wget >/dev/null 2>&1; then
    response="$(wget -T 8 -t 1 -4qO- "$url" 2>/dev/null || true)"
  elif command -v curl >/dev/null 2>&1; then
    response="$(curl -m 8 -4fsSL "$url" 2>/dev/null || true)"
  else
    return 1
  fi

  grep -m 1 -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$response" || true
}

fetch_cip_cc_ipv4() {
  local response=""

  if command -v curl >/dev/null 2>&1; then
    response="$(curl -4fsS --max-time 8 cip.cc 2>&1 | head -n 1 | sed 's/.*: //' || true)"
  elif command -v wget >/dev/null 2>&1; then
    response="$(wget -T 8 -t 1 -4qO- "https://cip.cc" 2>/dev/null | head -n 1 | sed 's/.*: //' || true)"
  else
    return 1
  fi

  grep -m 1 -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$response" || true
}

fetch_dns_ipv4() {
  local response=""

  if command -v dig >/dev/null 2>&1; then
    response="$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | head -n 1 || true)"
  elif command -v nslookup >/dev/null 2>&1; then
    response="$(nslookup myip.opendns.com resolver1.opendns.com 2>/dev/null | grep -m 1 -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' || true)"
  else
    return 1
  fi

  grep -m 1 -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$response" || true
}

append_public_ip_warning() {
  local message="$1"

  PUBLIC_IP_WARNINGS+=("$message")
}

detect_public_ipv4() {
  local detected_ip=""

  detected_ip="$(fetch_cip_cc_ipv4)"
  if is_ipv4 "$detected_ip"; then
    printf '%s\n' "$detected_ip"
    return 0
  fi
  append_public_ip_warning "cip.cc 服务出错或未返回有效公网 IPv4"

  detected_ip="$(fetch_url_ipv4 "https://ifconfig.me/ip")"
  if is_ipv4 "$detected_ip"; then
    printf '%s\n' "$detected_ip"
    return 0
  fi
  append_public_ip_warning "ifconfig.me 服务出错或未返回有效公网 IPv4"

  detected_ip="$(fetch_dns_ipv4)"
  if is_ipv4 "$detected_ip"; then
    printf '%s\n' "$detected_ip"
    return 0
  fi
  append_public_ip_warning "OpenDNS 查询服务出错或未返回有效公网 IPv4"

  return 1
}

ARCHIVE_PATH="${1:-}"

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

archive_has_entry() {
  local entry="$1"

  grep -Fqx "$entry" "$ARCHIVE_LIST_FILE"
}

install_if_present() {
  local source_path="$1"
  local mode="$2"
  local target_path="$3"

  if [ ! -e "$source_path" ]; then
    return 0
  fi

  mkdir -p "$(dirname "$target_path")"
  install -m "$mode" "$source_path" "$target_path"
}

remove_rc_local_openvpn_iptables_restart() {
  local rc_local_file="/etc/rc.local"
  local tmp_file

  if [ ! -f "$rc_local_file" ]; then
    return 0
  fi

  tmp_file="$(mktemp)"
  grep -v 'openvpn-iptables.service' "$rc_local_file" > "$tmp_file" || true
  cat "$tmp_file" > "$rc_local_file"
  rm -f "$tmp_file"
}

cleanup_legacy_firewall_state() {
  rm -f "$LEGACY_FIREWALL_SERVICE"
  remove_rc_local_openvpn_iptables_restart
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

  systemctl stop openvpn-server@server-udp.service >/dev/null 2>&1 || true
  systemctl stop openvpn-server@server-tcp.service >/dev/null 2>&1 || true
  systemctl stop openvpn-iptables-udp.service >/dev/null 2>&1 || true
  systemctl stop openvpn-iptables-tcp.service >/dev/null 2>&1 || true
  systemctl stop openvpn-iptables-tcp-udp-exchange-rules.service >/dev/null 2>&1 || true
  systemctl disable --now openvpn-iptables.service >/dev/null 2>&1 || true
}

backup_current_state() {
  ROLLBACK_DIR="/root/openvpn-restore-backup-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$ROLLBACK_DIR"

  for path in "$SERVER_DIR" "$UDP_CCD_DIR" "$TCP_CCD_DIR" "$CLIENT_DIR" "$PWD_AUTH_DIR" "$UDP_FIREWALL_SERVICE" "$TCP_FIREWALL_SERVICE" "$TCP_UDP_EXCHANGE_FIREWALL_SERVICE" "$SYSCTL_FORWARD_FILE"; do
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
  install_path "$STAGING_DIR/${SERVER_DIR#/}/client-pwd-auth" "$PWD_AUTH_DIR"
  install_path "$STAGING_DIR/${OPENVPN_DIR#/}/ccd-udp" "$UDP_CCD_DIR"
  install_path "$STAGING_DIR/${OPENVPN_DIR#/}/ccd-tcp" "$TCP_CCD_DIR"

  install -m 600 "$STAGING_DIR/${SERVER_CONF#/}" "$SERVER_CONF"
  install -m 600 "$STAGING_DIR/${TCP_SERVER_CONF#/}" "$TCP_SERVER_CONF"
  install -m 600 "$STAGING_DIR/${CLIENT_COMMON_FILE#/}" "$CLIENT_COMMON_FILE"
  install -m 600 "$STAGING_DIR/${SERVER_DIR#/}/ipp-udp.txt" "${SERVER_DIR}/ipp-udp.txt"
  install -m 600 "$STAGING_DIR/${SERVER_DIR#/}/ipp-tcp.txt" "${SERVER_DIR}/ipp-tcp.txt"

  install -m 600 "$STAGING_DIR/${SERVER_DIR#/}/ca.crt" "${SERVER_DIR}/ca.crt"
  install -m 600 "$STAGING_DIR/${SERVER_DIR#/}/ca.key" "${SERVER_DIR}/ca.key"
  install -m 600 "$STAGING_DIR/${SERVER_DIR#/}/server.crt" "${SERVER_DIR}/server.crt"
  install -m 600 "$STAGING_DIR/${SERVER_DIR#/}/server.key" "${SERVER_DIR}/server.key"
  install -m 644 "$STAGING_DIR/${SERVER_DIR#/}/crl.pem" "${SERVER_DIR}/crl.pem"
  install -m 600 "$STAGING_DIR/${SERVER_DIR#/}/tc.key" "${SERVER_DIR}/tc.key"
  install -m 600 "$STAGING_DIR/${SERVER_DIR#/}/dh.pem" "${SERVER_DIR}/dh.pem"

  install -m 700 "$STAGING_DIR/${SERVER_DIR#/}/to-get-from-hwdsl2.sh" "${SERVER_DIR}/to-get-from-hwdsl2.sh"
  install -m 700 "$STAGING_DIR/${SERVER_DIR#/}/auto-openvpn-add-client.sh" "${SERVER_DIR}/auto-openvpn-add-client.sh"
  install -m 700 "$STAGING_DIR/${SERVER_DIR#/}/auto-openvpn-revoke-client.sh" "${SERVER_DIR}/auto-openvpn-revoke-client.sh"
  install -m 700 "$STAGING_DIR/${SERVER_DIR#/}/to-assign-ip-to-client.sh" "${SERVER_DIR}/to-assign-ip-to-client.sh"
  install_if_present "$STAGING_DIR/${SERVER_DIR#/}/openvpn-pwd-auth-verify.sh" 750 "$PWD_AUTH_VERIFY_SCRIPT"

  install_if_present "$STAGING_DIR/${UDP_FIREWALL_SERVICE#/}" 644 "$UDP_FIREWALL_SERVICE"
  install_if_present "$STAGING_DIR/${TCP_FIREWALL_SERVICE#/}" 644 "$TCP_FIREWALL_SERVICE"
  install_if_present "$STAGING_DIR/${TCP_UDP_EXCHANGE_FIREWALL_SERVICE#/}" 644 "$TCP_UDP_EXCHANGE_FIREWALL_SERVICE"
  install_if_present "$STAGING_DIR/${SYSCTL_FORWARD_FILE#/}" 644 "$SYSCTL_FORWARD_FILE"
}

restore_compat_links() {
  mkdir -p "$CLIENT_DIR"
  chmod 700 "$UDP_CCD_DIR" "$TCP_CCD_DIR" "$CLIENT_DIR"
  chmod 700 "$SERVER_DIR"
  chown -R root:root "$SERVER_DIR" "$UDP_CCD_DIR" "$TCP_CCD_DIR" "$CLIENT_DIR"
  chown nobody:nogroup "${SERVER_DIR}/crl.pem" 2>/dev/null || true
  chmod o+x "$SERVER_DIR"

  ln -sfn "${SERVER_DIR}/auto-openvpn-add-client.sh" "$CLIENT_LINK"
  ln -sfn "${SERVER_DIR}/auto-openvpn-revoke-client.sh" "$REVOKE_LINK"
}

deploy_pwd_auth_verify_script() {
  cat > "$PWD_AUTH_VERIFY_SCRIPT" <<'EOF'
#!/bin/bash
set -euo pipefail

pwd_auth_file="$1"
pwd_cred_store="/etc/openvpn/server/client-pwd-auth"
client_file="$pwd_cred_store/${common_name}.credentials"

[ -f "$pwd_auth_file" ] || exit 1
[ -f "$client_file" ] || exit 0

username="$(sed -n '1p' "$pwd_auth_file")"
password="$(sed -n '2p' "$pwd_auth_file")"
[ -n "$username" ] || exit 1
[ -n "$password" ] || exit 1

while IFS=: read -r stored_user stored_password; do
  [ "$stored_user" = "$username" ] || continue
  stored_password="${stored_password//\:/:}"
  stored_password="${stored_password//\\/\\}"
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

normalize_local_bind() {
  local conf_file="$1"
  local bind_ip

  bind_ip="$(extract_server_value "$conf_file" local)"
  [ -n "$bind_ip" ] || return 0

  if host_has_ipv4 "$bind_ip"; then
    return 0
  fi

  sed -i '/^local /d' "$conf_file"
}

ensure_udp_server_conf() {
  if [ ! -f "$SERVER_CONF" ]; then
    echo "OpenVPN server config not found: $SERVER_CONF" >&2
    exit 1
  fi

  sed -i "s#^client-config-dir .*#client-config-dir ${UDP_CCD_DIR}#" "$SERVER_CONF"
  sed -i "s#^ifconfig-pool-persist .*#ifconfig-pool-persist ${SERVER_DIR}/ipp-udp.txt#" "$SERVER_CONF"
  normalize_local_bind "$SERVER_CONF"
  ensure_conf_has_line "$SERVER_CONF" "client-config-dir ${UDP_CCD_DIR}"
  ensure_server_conf_has_pwd_auth "$SERVER_CONF"
}

ensure_tcp_server_conf() {
  local udp_port
  local tcp_port

  if [ ! -f "$TCP_SERVER_CONF" ]; then
    echo "OpenVPN TCP server config not found: $TCP_SERVER_CONF" >&2
    exit 1
  fi

  udp_port="$(extract_server_value "$SERVER_CONF" port)"
  [ -n "$udp_port" ] || udp_port=1194
  tcp_port="$(extract_server_value "$TCP_SERVER_CONF" port)"
  [ -n "$tcp_port" ] || tcp_port="$udp_port"

  sed -i 's/^proto .*/proto tcp/' "$TCP_SERVER_CONF"
  sed -i "s/^port .*/port ${tcp_port}/" "$TCP_SERVER_CONF"
  sed -i "s#^client-config-dir .*#client-config-dir ${TCP_CCD_DIR}#" "$TCP_SERVER_CONF"
  sed -i "s#^ifconfig-pool-persist .*#ifconfig-pool-persist ${SERVER_DIR}/ipp-tcp.txt#" "$TCP_SERVER_CONF"
  sed -i '/^explicit-exit-notify$/d' "$TCP_SERVER_CONF"
  normalize_local_bind "$TCP_SERVER_CONF"
  ensure_conf_has_line "$TCP_SERVER_CONF" "client-config-dir ${TCP_CCD_DIR}"
  ensure_server_conf_has_pwd_auth "$TCP_SERVER_CONF"
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

  [ -n "$udp_network" ] && [ -n "$udp_mask" ] && [ -n "$tcp_network" ] && [ -n "$tcp_mask" ] || return 0

  ensure_conf_has_line "$SERVER_CONF" "push \"route ${tcp_network} ${tcp_mask}\""
  ensure_conf_has_line "$TCP_SERVER_CONF" "push \"route ${udp_network} ${udp_mask}\""
}

sync_openvpn_dropins() {
  local target_dir="$1"

  mkdir -p "$target_dir"
}

migrate_openvpn_instances() {
  local udp_dropin_dir="/etc/systemd/system/openvpn-server@server-udp.service.d"
  local tcp_dropin_dir="/etc/systemd/system/openvpn-server@server-tcp.service.d"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  sync_openvpn_dropins "$udp_dropin_dir"
  sync_openvpn_dropins "$tcp_dropin_dir"
}

converge_firewall_units() {
  if [ -x "$SERVER_DIR/install-auto-openvpn.sh" ]; then
    OPENVPN_INSTALL_SCRIPT="$SERVER_DIR/to-get-from-hwdsl2.sh"       OPENVPN_ASSIGN_SCRIPT="$SERVER_DIR/to-assign-ip-to-client.sh"       bash "$SERVER_DIR/install-auto-openvpn.sh"
    return 0
  fi

  return 1
}

restart_services() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  sysctl -e -q -p "$SYSCTL_FORWARD_FILE" >/dev/null 2>&1 || true

  if [ ! -f "$UDP_FIREWALL_SERVICE" ] || [ ! -f "$TCP_FIREWALL_SERVICE" ] || [ ! -f "$TCP_UDP_EXCHANGE_FIREWALL_SERVICE" ]; then
    converge_firewall_units || true
  fi

  systemctl daemon-reload
  systemctl enable --now openvpn-iptables-udp.service >/dev/null 2>&1 || true
  systemctl enable --now openvpn-iptables-tcp.service >/dev/null 2>&1 || true
  systemctl enable --now openvpn-iptables-tcp-udp-exchange-rules.service >/dev/null 2>&1 || true
  systemctl enable --now openvpn-server@server-udp.service >/dev/null 2>&1
  systemctl enable --now openvpn-server@server-tcp.service >/dev/null 2>&1
}

print_manual_checklist() {
  local udp_port
  local tcp_port
  local public_ip=""

  udp_port="$(awk '$1 == "port" { print $2; exit }' "$SERVER_CONF")"
  tcp_port="$(awk '$1 == "port" { print $2; exit }' "$TCP_SERVER_CONF")"
  [ -n "$udp_port" ] || udp_port=1194
  [ -n "$tcp_port" ] || tcp_port="$udp_port"

  echo
  echo "恢复后建议继续做两步核对："
  echo "第 1 步：先做主流程检查"
  echo "  sudo bash tests/restore-smoke-test.sh"
  echo "  sudo systemctl status openvpn-server@server-udp.service openvpn-server@server-tcp.service --no-pager"
  echo "第 2 步：再做人工确认"
  public_ip="$(detect_public_ipv4 || true)"
  if [ -n "$public_ip" ]; then
    echo "- 修改客户端 .ovpn 里的服务器地址；如果写的是 IP，就把 remote IP 更新为 ${public_ip}；如果写的是域名，就确认 DNS 已切到当前服务器。"
  else
    echo "- 修改客户端 .ovpn 里的服务器地址；如果写的是 IP，就更新 remote IP；如果写的是域名，就确认 DNS 已切到当前服务器。"
    if [ "${#PUBLIC_IP_WARNINGS[@]}" -gt 0 ]; then
      printf '  公网 IP 自动探测失败：%s\n' "${PUBLIC_IP_WARNINGS[0]}"
      if [ "${#PUBLIC_IP_WARNINGS[@]}" -gt 1 ]; then
        printf '  备用方法也失败：%s\n' "${PUBLIC_IP_WARNINGS[1]}"
      fi
      if [ "${#PUBLIC_IP_WARNINGS[@]}" -gt 2 ]; then
        printf '  DNS 回退方法也失败：%s\n' "${PUBLIC_IP_WARNINGS[2]}"
      fi
    fi
  fi
  echo "- 确认外围防火墙方向和端口已放行：入站至少允许 UDP ${udp_port} 和 TCP ${tcp_port}，同时不要拦截 OpenVPN 转发后的相关出站/回包流量。"
  echo "- 确认 /etc/openvpn/server/client-pwd-auth 与旧服务器一致，尤其是所有使用密码登录的客户端。"
  echo "- 用一个真实 UDP 客户端和一个真实 TCP 客户端各连一次，验证修改服务器地址后即可正常连接。"
  echo "- 如果你已经有旧服务器的本地快照，可选执行：sudo bash compare-restore-state.sh <old-server-root> /"
}

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
ensure_archive_entry "etc/openvpn/server/client-pwd-auth/"
ensure_archive_entry "etc/openvpn/server/ca.crt"
ensure_archive_entry "etc/openvpn/server/ca.key"
ensure_archive_entry "etc/openvpn/server/server.crt"
ensure_archive_entry "etc/openvpn/server/server.key"
ensure_archive_entry "etc/openvpn/server/crl.pem"
ensure_archive_entry "etc/openvpn/server/tc.key"
ensure_archive_entry "etc/openvpn/server/dh.pem"
ensure_archive_entry "etc/openvpn/server/ipp-udp.txt"
ensure_archive_entry "etc/openvpn/server/ipp-tcp.txt"
ensure_archive_entry "etc/openvpn/server/to-get-from-hwdsl2.sh"
ensure_archive_entry "etc/openvpn/server/auto-openvpn-add-client.sh"
ensure_archive_entry "etc/openvpn/server/auto-openvpn-revoke-client.sh"
ensure_archive_entry "etc/openvpn/server/to-assign-ip-to-client.sh"
ensure_archive_entry "etc/openvpn/ccd-udp/"
ensure_archive_entry "etc/openvpn/ccd-tcp/"

safe_tar_extract
stop_services
backup_current_state
cleanup_legacy_firewall_state
restore_tree
restore_compat_links
deploy_pwd_auth_verify_script
ensure_udp_server_conf
ensure_tcp_server_conf
ensure_cross_subnet_routes
ensure_pwd_auth_access
migrate_openvpn_instances
restart_services

echo "Restore completed from: $ARCHIVE_PATH"
echo "Rollback backup saved to: $ROLLBACK_DIR"
echo "Existing clients should only need the new server IP in their .ovpn remote line."
print_manual_checklist
