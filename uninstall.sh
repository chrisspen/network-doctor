#!/usr/bin/env bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

systemctl disable --now network-doctor.service 2>/dev/null || true
rm -f /etc/systemd/system/network-doctor.service
rm -f /usr/local/bin/network-doctor
systemctl daemon-reload

echo "Uninstalled network-doctor.service"
