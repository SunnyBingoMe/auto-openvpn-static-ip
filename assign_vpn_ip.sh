#!/bin/bash
set -euo pipefail

CN="${1:?missing certificate CN}"

CCD_DIR="/etc/openvpn/ccd"
IPP_FILE="/etc/openvpn/ipp.txt"
LOCK_FILE="${CCD_DIR}/.assign.lock"

SUBNET_PREFIX="${OPENVPN_SUBNET_PREFIX:-10.8.0}"
START_HOST="${OPENVPN_START_HOST:-10}"
END_HOST="${OPENVPN_END_HOST:-254}"
MASK="${OPENVPN_MASK:-255.255.255.0}"

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root or with sudo." >&2
  echo "Example: sudo bash $0 <client name>" >&2
  exit 1
fi

mkdir -p "$CCD_DIR"

exec 9>"$LOCK_FILE"
flock -x 9

CCD_FILE="$CCD_DIR/$CN"
if [ -f "$CCD_FILE" ]; then
  echo "CCD already exists for $CN"
  exit 0
fi

is_reserved_host() {
  local host="$1"
  [ "$host" -eq 0 ] || [ "$host" -eq 1 ] || [ "$host" -eq 255 ]
}

is_ip_used() {
  local ip="$1"

  if grep -Rqs -- "^ifconfig-push ${ip} " "$CCD_DIR"; then
    return 0
  fi

  if [ -f "$IPP_FILE" ] && grep -qs -- ",${ip}$" "$IPP_FILE"; then
    return 0
  fi

  return 1
}

for host in $(seq "$START_HOST" "$END_HOST"); do
  is_reserved_host "$host" && continue
  ip="${SUBNET_PREFIX}.${host}"

  if ! is_ip_used "$ip"; then
    printf 'ifconfig-push %s %s\n' "$ip" "$MASK" > "$CCD_FILE"
    chmod 644 "$CCD_FILE"
    echo "Assigned $CN -> $ip"
    exit 0
  fi
done

echo "No free VPN IP available in ${SUBNET_PREFIX}.0/24" >&2
exit 1