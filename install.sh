#!/usr/bin/env bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/network-doctor.sh"
SERVICE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/network-doctor.service"

install -m 0755 "$SCRIPT_SRC" /usr/local/bin/network-doctor
install -m 0644 "$SERVICE_SRC" /etc/systemd/system/network-doctor.service

systemctl daemon-reload
systemctl enable --now network-doctor.service

echo "Installed and started network-doctor.service"
