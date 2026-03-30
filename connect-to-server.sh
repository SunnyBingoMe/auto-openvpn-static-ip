#!/bin/bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

OPENVPN_DIR="/etc/openvpn"
CLIENT_DIR="${OPENVPN_DIR}/client"
SERVER_DIR="${OPENVPN_DIR}/server"
SERVER_UDP_CONF="${SERVER_DIR}/server-udp.conf"
SERVER_TCP_CONF="${SERVER_DIR}/server-tcp.conf"
DISPATCHER_DIR="/etc/networkd-dispatcher/routable.d"
FIX_ROUTES_PATH="${CLIENT_DIR}/fix-routes.sh"

usage() {
  cat <<'EOF'
Usage: connect-to-server.sh <client-config.ovpn>

Example:
  sudo ./connect-to-server.sh ../yecao-udp.udp.nix.ovpn
EOF
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root or via sudo." >&2
    exit 1
  fi
}

require_argument() {
  if [ "$#" -ne 1 ]; then
    usage >&2
    exit 1
  fi
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

prompt_install_mode() {
  local reply

  while true; do
    read -r -p "Existing client installs found. Choose [del/keep] (default: del): " reply
    reply="${reply:-del}"

    case "${reply,,}" in
      del|d)
        INSTALL_MODE="del"
        return 0
        ;;
      keep|k)
        INSTALL_MODE="keep"
        return 0
        ;;
      *)
        echo "Allowed values: del, keep"
        ;;
    esac
  done
}

require_file() {
  local file_path="$1"

  if [ ! -f "$file_path" ]; then
    echo "File not found: $file_path" >&2
    exit 1
  fi
}

require_client_runtime_layout() {
  if [ ! -x "$FIX_ROUTES_PATH" ]; then
    echo "Missing client helper: $FIX_ROUTES_PATH" >&2
    echo "Run install-auto-openvpn.sh in client mode first." >&2
    exit 1
  fi
}

check_no_server_service_running() {
  local active_units
  local script_dir

  script_dir="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

  active_units="$(systemctl list-units --type=service --all --no-legend 'openvpn-server@*.service' 2>/dev/null | awk '$3 == "active" || $3 == "activating" || $3 == "reloading" { print $1 }')"

  if [ -n "$active_units" ] || [ -f "$SERVER_UDP_CONF" ] || [ -f "$SERVER_TCP_CONF" ] || [ -f "${SERVER_DIR}/server.conf" ] || [ -f "${SERVER_DIR}/client-common.txt" ] || [ -d "${SERVER_DIR}/easy-rsa" ]; then
    echo "Detected OpenVPN server service or leftover server artifacts; refusing to install client auto-connect on the same host." >&2

    if [ -n "$active_units" ]; then
      echo "Running server service(s):" >&2
    printf '%s\n' "$active_units" >&2
    fi

    echo >&2
    echo "If this machine should be client-only, remove the server service/residue first." >&2
    echo "Copy and run one of these commands:" >&2
    echo >&2
    echo "1) Disable the stale server unit only:" >&2
    echo "sudo systemctl disable --now openvpn-server@server-udp.service openvpn-server@server-tcp.service openvpn@server.service openvpn-server@server.service" >&2
    echo >&2
    echo "2) Fully clean old server residue with this repo's uninstall script:" >&2
    echo "sudo bash \"${script_dir}/uninstall-auto-openvpn.sh\"" >&2
    echo >&2
    echo "3) If uninstall already ran before, manually remove the common leftovers:" >&2
    echo "sudo rm -rf /etc/openvpn/server /etc/openvpn/ccd-udp /etc/openvpn/ccd-tcp /etc/openvpn/client-udp-tcp /etc/systemd/system/openvpn-server@server-udp.service.d /etc/systemd/system/openvpn-server@server-tcp.service.d /etc/systemd/system/openvpn-iptables.service /etc/sysctl.d/99-openvpn-forward.conf /etc/sysctl.d/99-openvpn-optimize.conf && sudo sed --follow-symlinks -i '/^systemctl restart openvpn-iptables\.service$/d' /etc/rc.local && sudo systemctl daemon-reload" >&2
    exit 1
  fi
}

sanitize_client_name() {
  local raw_name="$1"
  local sanitized_name

  sanitized_name="$(printf '%s' "$raw_name" | LC_ALL=C sed 's/[^A-Za-z0-9_-]/-/g; s/--*/-/g; s/^-//; s/-$//')"
  if [ -z "$sanitized_name" ]; then
    echo "Failed to derive a valid client name from: $raw_name" >&2
    exit 1
  fi

  printf '%s\n' "$sanitized_name"
}

prepare_service_identity() {
  SANITIZED_CLIENT_NAME="$(sanitize_client_name "$CLIENT_CONFIG_NAME")"
  CLIENT_SERVICE_NAME="openvpn-client-${SANITIZED_CLIENT_NAME}.service"
  CLIENT_SERVICE_PATH="/etc/systemd/system/${CLIENT_SERVICE_NAME}"
  DISPATCHER_HOOK_PATH="${DISPATCHER_DIR}/50-${SANITIZED_CLIENT_NAME}-openvpn-client-restart"
}

remove_file_if_present() {
  local target="$1"

  if [ -e "$target" ] || [ -L "$target" ]; then
    rm -f "$target"
  fi
}

remove_matching_files_if_present() {
  local file_path

  for file_path in "$@"; do
    [ -e "$file_path" ] || [ -L "$file_path" ] || continue
    rm -f "$file_path"
  done
}

remove_existing_client_installations() {
  local service_file
  local hook_file

  for service_file in /etc/systemd/system/openvpn-client*.service; do
    [ -e "$service_file" ] || continue
    service_name="$(basename "$service_file")"
    systemctl disable --now "$service_name" >/dev/null 2>&1 || true
    remove_file_if_present "$service_file"
  done

  for hook_file in /etc/networkd-dispatcher/routable.d/*openvpn-client-restart*; do
    [ -e "$hook_file" ] || continue
    remove_file_if_present "$hook_file"
  done

  remove_matching_files_if_present "$CLIENT_DIR"/*.conf "$CLIENT_DIR"/*.ovpn.auth.txt
  systemctl daemon-reload >/dev/null 2>&1 || true
}

handle_existing_client_installation() {
  local has_existing_clients="no"

  if [ -f "$CLIENT_SERVICE_PATH" ] || [ -f "$INSTALLED_OVPN_PATH" ]; then
    echo "Detected an existing client install with the same service or .ovpn name." >&2
    if ask_yes_no "Overwrite the existing client install?" "y"; then
      return 0
    fi
    echo "Install cancelled."
    exit 0
  fi

  if compgen -G "/etc/systemd/system/openvpn-client*.service" >/dev/null 2>&1; then
    has_existing_clients="yes"
  fi
  if compgen -G "${CLIENT_DIR}/*.conf" >/dev/null 2>&1; then
    has_existing_clients="yes"
  fi

  if [ "$has_existing_clients" = "yes" ]; then
    prompt_install_mode
    if [ "$INSTALL_MODE" = "del" ]; then
      remove_existing_client_installations
    fi
  fi
}

resolve_input_files() {
  INPUT_OVPN_RAW="$1"
  INPUT_OVPN="$(readlink -f "$INPUT_OVPN_RAW")"
  require_file "$INPUT_OVPN"

  case "$INPUT_OVPN" in
    *.ovpn)
      INPUT_AUTH="${INPUT_OVPN}.auth.txt"
      ;;
    *)
      echo "Expected an .ovpn file, got: $INPUT_OVPN" >&2
      exit 1
      ;;
  esac

  CLIENT_CONFIG_BASENAME="$(basename "$INPUT_OVPN")"
  CLIENT_CONFIG_NAME="${CLIENT_CONFIG_BASENAME%.ovpn}"
  CLIENT_CONF_BASENAME="${CLIENT_CONFIG_NAME}.conf"
  CLIENT_AUTH_BASENAME="$(basename "$INPUT_AUTH")"
  prepare_service_identity
  INSTALLED_OVPN_PATH="${CLIENT_DIR}/${CLIENT_CONF_BASENAME}"
  INSTALLED_AUTH_PATH="${CLIENT_DIR}/${CLIENT_AUTH_BASENAME}"
}

install_client_files() {
  install -d -m 755 "$CLIENT_DIR"
  install -m 600 "$INPUT_OVPN" "$INSTALLED_OVPN_PATH"
  if [ "${REQUIRE_AUTH_FILE}" = "yes" ]; then
    install -m 600 "$INPUT_AUTH" "$INSTALLED_AUTH_PATH"
  fi
}

profile_has_inline_auth() {
  python3 - "$INPUT_OVPN" <<'PY'
from pathlib import Path
import sys

content = Path(sys.argv[1]).read_text()
raise SystemExit(0 if "<auth-user-pass>" in content else 1)
PY
}

patch_auth_user_pass_path() {
  python3 - "$INSTALLED_OVPN_PATH" "$INSTALLED_AUTH_PATH" <<'PY'
from pathlib import Path
import sys

ovpn_path = Path(sys.argv[1])
auth_path = Path(sys.argv[2])
lines = ovpn_path.read_text().splitlines()
updated = []
replaced = False

for line in lines:
    stripped = line.strip()
    if stripped == "auth-user-pass" or stripped.startswith("auth-user-pass "):
        updated.append(f"auth-user-pass {auth_path}")
        replaced = True
    else:
        updated.append(line)

if not replaced:
    updated.append(f"auth-user-pass {auth_path}")

ovpn_path.write_text("\n".join(updated) + "\n")
PY
}

ensure_route_hook() {
  python3 - "$INSTALLED_OVPN_PATH" "$FIX_ROUTES_PATH" <<'PY'
from pathlib import Path
import sys

conf_path = Path(sys.argv[1])
fix_routes_path = sys.argv[2]
lines = conf_path.read_text().splitlines()

def has_directive(prefix: str) -> bool:
    return any(line.strip() == prefix or line.strip().startswith(prefix + " ") for line in lines)

if not has_directive("script-security"):
    lines.append("script-security 2")

hook_line = f"up {fix_routes_path}"
if hook_line not in [line.strip() for line in lines]:
    lines.append(hook_line)

conf_path.write_text("\n".join(lines) + "\n")
PY
}

write_service_file() {
  cat > "$CLIENT_SERVICE_PATH" <<EOF
[Unit]
Description=${CLIENT_SERVICE_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
Restart=on-failure
RestartSec=2
ExecStart=/usr/sbin/openvpn --config ${INSTALLED_OVPN_PATH}

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$CLIENT_SERVICE_PATH"
}

write_dispatcher_hook() {
  if ! systemctl list-unit-files --type=service --no-legend networkd-dispatcher.service >/dev/null 2>&1; then
    echo "networkd-dispatcher.service is not installed; cannot configure reconnect hook." >&2
    exit 1
  fi

  install -d -m 755 "$DISPATCHER_DIR"
  cat > "$DISPATCHER_HOOK_PATH" <<EOF
#!/bin/bash
set -euo pipefail

case "\${IFACE:-}" in
  lo|tun*|tap*)
    exit 0
    ;;
esac

systemctl restart ${CLIENT_SERVICE_NAME}
EOF
  chmod 755 "$DISPATCHER_HOOK_PATH"
}

enable_and_start_service() {
  systemctl daemon-reload
  systemctl enable "$CLIENT_SERVICE_NAME"
  systemctl start "$CLIENT_SERVICE_NAME"
}

main() {
  require_argument "$@"
  require_root
  require_client_runtime_layout
  check_no_server_service_running
  resolve_input_files "$1"
  handle_existing_client_installation
  if profile_has_inline_auth; then
    REQUIRE_AUTH_FILE="no"
  else
    REQUIRE_AUTH_FILE="yes"
    require_file "$INPUT_AUTH"
  fi
  install_client_files
  if [ "$REQUIRE_AUTH_FILE" = "yes" ]; then
    patch_auth_user_pass_path
  fi
  ensure_route_hook
  write_service_file
  write_dispatcher_hook
  enable_and_start_service

  echo "Installed client config: $INSTALLED_OVPN_PATH"
  echo "Installed auth file: $INSTALLED_AUTH_PATH"
  echo "Installed service: $CLIENT_SERVICE_PATH"
  echo "Installed dispatcher hook: $DISPATCHER_HOOK_PATH"
  echo "Check service status with: systemctl status ${CLIENT_SERVICE_NAME}"
  echo "Check logs with: journalctl -xeu ${CLIENT_SERVICE_NAME}"
}

main "$@"
