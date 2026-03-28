#!/bin/bash
set -euo pipefail
CLIENT_OS="linux"
PROFILE_PROTO="udp"
CN="demo"

extract_server_value() {
  local conf_file="$1"
  local key="$2"

  awk -v key="$key" '$1 == key { print $2; exit }' "$conf_file"
}

rewrite_profile_for_protocol() {
  local source_file="$1"
  local target_file="$2"
  local server_conf="$3"
  local peer_server_conf="$4"
  local target_dir
  local target_name
  local tmp_file
  local remote_host
  local remote_port
  local local_route_network
  local local_route_mask
  local peer_route_network
  local peer_route_mask

  remote_host="$(awk '$1 == "remote" { print $2; exit }' "$source_file")"
  if [ -z "$remote_host" ]; then
    echo "remote host not found in generated profile: $source_file" >&2
    exit 1
  fi

  remote_port="$(extract_server_value "$server_conf" port)"
  if [ -z "$remote_port" ]; then
    echo "port not found in server config: $server_conf" >&2
    exit 1
  fi

  local_route_network="$(awk '$1 == "server" { print $2; exit }' "$server_conf")"
  local_route_mask="$(awk '$1 == "server" { print $3; exit }' "$server_conf")"
  peer_route_network="$(awk '$1 == "server" { print $2; exit }' "$peer_server_conf")"
  peer_route_mask="$(awk '$1 == "server" { print $3; exit }' "$peer_server_conf")"
  target_dir="$(dirname "$target_file")"
  target_name="$(basename "$target_file")"
  tmp_file="$(mktemp "${target_dir}/${target_name}.tmp.XXXXXX")"

  awk -v proto="$PROFILE_PROTO" \
      -v remote_host="$remote_host" \
      -v remote_port="$remote_port" \
      -v local_route_network="$local_route_network" \
      -v local_route_mask="$local_route_mask" \
      -v peer_route_network="$peer_route_network" \
      -v peer_route_mask="$peer_route_mask" \
      -v client_os="$CLIENT_OS" '
    $1 == "proto" {
      print "proto " proto
      next
    }
    $1 == "remote" {
      print "remote " remote_host " " remote_port
      next
    }
    $1 == "route" {
      next
    }
    { print }
    END {
      if (client_os == "linux") {
        print "script-security 2"
        print "up /etc/openvpn/client/fix-routes.sh"
      } else {
        if (local_route_network != "" && local_route_mask != "") {
          print "route " local_route_network " " local_route_mask
        }
        if (peer_route_network != "" && peer_route_mask != "") {
          print "route " peer_route_network " " peer_route_mask
        }
      }
    }
  ' "$source_file" > "$tmp_file" || {
    rm -f "$tmp_file"
    exit 1
  }

  mv -f "$tmp_file" "$target_file" || {
    rm -f "$tmp_file"
    exit 1
  }
}


rewrite_profile_for_protocol "/mnt/c/BigFiles/Github/auto-openvpn-static-ip/tmp-route-qa/source.ovpn" "/mnt/c/BigFiles/Github/auto-openvpn-static-ip/tmp-route-qa/linux.ovpn" "/mnt/c/BigFiles/Github/auto-openvpn-static-ip/tmp-route-qa/server-udp.conf" "/mnt/c/BigFiles/Github/auto-openvpn-static-ip/tmp-route-qa/server-tcp.conf"
