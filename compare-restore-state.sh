#!/bin/bash
set -euo pipefail

OLD_ROOT="${1:-}"
NEW_ROOT="${2:-/}"
STRICT_MODE="${STRICT_MODE:-0}"

FAILURES=0
WARNINGS=0

pass() {
  echo "OK: $1"
}

warn() {
  echo "WARN: $1"
  WARNINGS=$((WARNINGS + 1))
}

fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

usage() {
  cat <<'EOF'
Usage:
  compare-restore-state.sh <old-root> [new-root]

Examples:
  sudo bash compare-restore-state.sh /mnt/old-server /
  sudo STRICT_MODE=1 bash compare-restore-state.sh /srv/pre-restore-snapshot /

The script compares best-effort state for:
- /etc/openvpn/server/client-pwd-auth
- /etc/openvpn/ccd-udp
- /etc/openvpn/ccd-tcp
- /etc/openvpn/server/ipp-udp.txt
- /etc/openvpn/server/ipp-tcp.txt

By default it is informational and exits 0 even on mismatches.
Set STRICT_MODE=1 to make mismatches exit non-zero.
EOF
}

hash_file() {
  local target_file="$1"

  sha256sum "$target_file" 2>/dev/null | awk '{print $1}'
}

build_dir_hash_manifest() {
  local label="$1"
  local target_dir="$2"
  local output_file="$3"
  local file_path
  local relative_name
  local file_hash

  : > "$output_file"

  if [ ! -d "$target_dir" ]; then
    return 0
  fi

  while IFS= read -r file_path; do
    relative_name="$(basename "$file_path")"
    file_hash="$(hash_file "$file_path")"
    if [ -z "$file_hash" ]; then
      warn "could not hash ${label} file: $file_path"
      continue
    fi
    printf '%s %s\n' "$relative_name" "$file_hash" >> "$output_file"
  done < <(find "$target_dir" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | LC_ALL=C sort)
}

count_manifest_entries() {
  local manifest_file="$1"

  if [ ! -f "$manifest_file" ]; then
    printf 'missing\n'
    return 0
  fi

  grep -c '.' "$manifest_file" 2>/dev/null || printf '0\n'
}

compare_hashed_dir() {
  local label="$1"
  local old_dir="$2"
  local new_dir="$3"
  local old_manifest
  local new_manifest

  old_manifest="$(mktemp)"
  new_manifest="$(mktemp)"

  if ! build_dir_hash_manifest "$label" "$old_dir" "$old_manifest"; then
    warn "could not read old ${label} dir: $old_dir"
    rm -f "$old_manifest" "$new_manifest"
    return 0
  fi

  if ! build_dir_hash_manifest "$label" "$new_dir" "$new_manifest"; then
    warn "could not read new ${label} dir: $new_dir"
    rm -f "$old_manifest" "$new_manifest"
    return 0
  fi

  if cmp -s "$old_manifest" "$new_manifest"; then
    pass "${label} file hashes match"
  else
    fail "${label} file hashes differ"
    echo "  old count: $(count_manifest_entries "$old_manifest")"
    echo "  new count: $(count_manifest_entries "$new_manifest")"
    echo "  only in old:"
    comm -23 "$old_manifest" "$new_manifest" | sed 's/^/    /' || true
    echo "  only in new:"
    comm -13 "$old_manifest" "$new_manifest" | sed 's/^/    /' || true
  fi

  rm -f "$old_manifest" "$new_manifest"
}

compare_file_hash() {
  local label="$1"
  local old_file="$2"
  local new_file="$3"
  local old_hash
  local new_hash

  if [ ! -f "$old_file" ]; then
    warn "old ${label} file missing: $old_file"
    return 0
  fi

  if [ ! -f "$new_file" ]; then
    fail "new ${label} file missing: $new_file"
    return 0
  fi

  old_hash="$(hash_file "$old_file")"
  new_hash="$(hash_file "$new_file")"

  if [ -z "$old_hash" ] || [ -z "$new_hash" ]; then
    warn "could not hash ${label} file(s)"
    return 0
  fi

  if [ "$old_hash" = "$new_hash" ]; then
    pass "${label} file hash matches"
  else
    fail "${label} file hash differs"
  fi
}

if [ -z "$OLD_ROOT" ]; then
  usage >&2
  exit 1
fi

OLD_ETC="${OLD_ROOT%/}/etc/openvpn"
NEW_ETC="${NEW_ROOT%/}/etc/openvpn"

compare_hashed_dir "pwd-auth" "${OLD_ETC}/server/client-pwd-auth" "${NEW_ETC}/server/client-pwd-auth"
compare_hashed_dir "UDP CCD" "${OLD_ETC}/ccd-udp" "${NEW_ETC}/ccd-udp"
compare_hashed_dir "TCP CCD" "${OLD_ETC}/ccd-tcp" "${NEW_ETC}/ccd-tcp"
compare_file_hash "UDP IPP" "${OLD_ETC}/server/ipp-udp.txt" "${NEW_ETC}/server/ipp-udp.txt"
compare_file_hash "TCP IPP" "${OLD_ETC}/server/ipp-tcp.txt" "${NEW_ETC}/server/ipp-tcp.txt"

echo "Comparison completed with ${FAILURES} failure(s) and ${WARNINGS} warning(s)."

if [ "$STRICT_MODE" = "1" ] && [ "$FAILURES" -gt 0 ]; then
  exit 1
fi

exit 0
