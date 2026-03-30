#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root or with sudo." >&2
  exit 1
fi
ccd_dir=""
[ -n "" ]
mkdir -p ""
printf "ifconfig-push 172.22.0.10 255.255.0.0
" > "/"
