#!/bin/bash
set -euo pipefail

CN="${1:?missing certificate CN}"

CCD_DIR="${OPENVPN_CCD_DIR:-/etc/openvpn/ccd-udp}"
IPP_FILE="${OPENVPN_IPP_FILE:-}"
LOCK_FILE="${CCD_DIR}/.assign.lock"

SUBNET_PREFIX="${OPENVPN_SUBNET_PREFIX:-172.22}"
START_HOST="${OPENVPN_START_HOST:-10}"
END_HOST="${OPENVPN_END_HOST:-254}"
MASK="${OPENVPN_MASK:-255.255.0.0}"

validate_client_name() {
  if [[ ! "$CN" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid client name: $CN" >&2
    echo "Allowed characters: letters, numbers, '-' and '_'" >&2
    exit 1
  fi
}

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root or with sudo." >&2
  echo "Example: sudo bash $0 <client name>" >&2
  exit 1
fi

validate_client_name

if [ -z "$IPP_FILE" ]; then
  if [ -f "/etc/openvpn/server/ipp-udp.txt" ]; then
    IPP_FILE="/etc/openvpn/server/ipp-udp.txt"
  elif [ -f "/etc/openvpn/server/ipp.txt" ]; then
    IPP_FILE="/etc/openvpn/server/ipp.txt"
  elif [ -f "/etc/openvpn/ipp.txt" ]; then
    IPP_FILE="/etc/openvpn/ipp.txt"
  else
    IPP_FILE="/etc/openvpn/server/ipp-udp.txt"
  fi
fi

mkdir -p "$CCD_DIR"

exec 9>"$LOCK_FILE"
flock -x 9

CCD_FILE="${CCD_DIR}/${CN}"
case "$CCD_FILE" in
  "${CCD_DIR}"/*) ;;
  *)
    echo "Refusing to write outside CCD dir: $CCD_FILE" >&2
    exit 1
    ;;
esac

if [ -f "$CCD_FILE" ]; then
  echo "CCD already exists for $CN"
  exit 0
fi

is_reserved_host() {
  local host="$1"
  [ "$host" -eq 0 ] || [ "$host" -eq 1 ] || [ "$host" -eq 255 ]
}

build_candidate_ips() {
  local prefix_octets
  IFS='.' read -r -a prefix_octets <<< "$SUBNET_PREFIX"

  case "${#prefix_octets[@]}" in
    2)
      local third_octet
      local host
      for third_octet in $(seq 0 255); do
        for host in $(seq "$START_HOST" "$END_HOST"); do
          is_reserved_host "$host" && continue
          printf '%s.%s.%s.%s\n' "${prefix_octets[0]}" "${prefix_octets[1]}" "$third_octet" "$host"
        done
      done
      ;;
    3)
      local host
      for host in $(seq "$START_HOST" "$END_HOST"); do
        is_reserved_host "$host" && continue
        printf '%s.%s.%s.%s\n' "${prefix_octets[0]}" "${prefix_octets[1]}" "${prefix_octets[2]}" "$host"
      done
      ;;
    *)
      echo "Unsupported OPENVPN_SUBNET_PREFIX: $SUBNET_PREFIX" >&2
      exit 1
      ;;
  esac
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

while IFS= read -r ip; do
  if ! is_ip_used "$ip"; then
    printf 'ifconfig-push %s %s\n' "$ip" "$MASK" > "$CCD_FILE"
    chmod 600 "$CCD_FILE"
    echo "Assigned $CN -> $ip"
    exit 0
  fi
done < <(build_candidate_ips)

echo "No free VPN IP available for prefix ${SUBNET_PREFIX} with mask ${MASK}" >&2
exit 1
