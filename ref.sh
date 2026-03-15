chmod 700 /etc/openvpn/server/assign_vpn_ip.sh

sudo mkdir -p /etc/openvpn/ccd && sudo chmod 755 /etc/openvpn/ccd

echo 'client-config-dir /etc/openvpn/ccd' >> /etc/openvpn/server/server.conf