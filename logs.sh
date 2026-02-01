#!/usr/bin/env bash
# Show network-doctor logs. Pass arguments to journalctl (e.g., -f for follow, -n 50 for last 50)
exec journalctl -u network-doctor "${@:--f}"
