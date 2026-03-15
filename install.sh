require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root or with sudo." >&2
    echo "Example: sudo bash $0" >&2
    exit 1
  fi
}
require_root
bash official-auto-install.sh --auto

