#!/bin/bash
set -euo pipefail
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
