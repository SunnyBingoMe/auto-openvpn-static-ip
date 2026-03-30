#!/bin/sh
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root or with sudo." >&2
  exit 1
fi
ip route del 172.22.0.0/16 2>/dev/null || true
ip route del 172.23.0.0/16 2>/dev/null || true
ip route replace 172.22.0.0/16 dev "$dev"
ip route replace 172.23.0.0/16 dev "$dev"
exit 0
