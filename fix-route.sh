#!/bin/sh
ip route del 172.22.0.0/16 2>/dev/null || true
ip route replace 172.22.0.0/16 dev "$dev"
ip route replace 172.23.0.0/16 dev "$dev"
exit 0