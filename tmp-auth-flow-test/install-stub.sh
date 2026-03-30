#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root or with sudo." >&2
  exit 1
fi
cn=""
outdir=""
[ -n "" ]
cat > "/.ovpn" <<EOF
client
proto udp
remote vpn.example.com 1194
auth-user-pass
<ca>
ca
</ca>
EOF
echo "Configuration available in: /.ovpn"
