#!/usr/bin/env bash
set -euo pipefail

# Simple Wi-Fi self-healer for NetworkManager on Ubuntu.
# Detects CONNECTED_SITE/CONNECTIVITY issues and re-associates Wi-Fi.

CHECK_INTERVAL_SEC="${CHECK_INTERVAL_SEC:-30}"
IFACE_OVERRIDE="${IFACE_OVERRIDE:-}"
PING_HOSTS=("1.1.1.1" "8.8.8.8")

log() {
  logger -t network-doctor "$*"
}

get_wifi_iface() {
  if [[ -n "$IFACE_OVERRIDE" ]]; then
    echo "$IFACE_OVERRIDE"
    return 0
  fi
  nmcli -t -f DEVICE,TYPE,STATE dev status \
    | awk -F: '$2=="wifi" && $3=="connected" {print $1; exit}'
}

nm_state() {
  # Outputs: STATE CONNECTIVITY
  nmcli -g STATE,CONNECTIVITY general 2>/dev/null | tr ':' ' '
}

has_internet() {
  for host in "${PING_HOSTS[@]}"; do
    if ping -c 1 -W 2 "$host" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

gateway_reachable() {
  local gw
  gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
  if [[ -z "$gw" ]]; then
    return 1
  fi
  ping -c 1 -W 2 "$gw" >/dev/null 2>&1
}

heal_wifi() {
  local iface="$1"
  log "Connectivity appears down; restarting Wi-Fi on $iface"
  nmcli dev disconnect "$iface" >/dev/null 2>&1 || true
  sleep 2
  nmcli dev connect "$iface" >/dev/null 2>&1 || true
}

check_once() {
  local iface state conn
  iface=$(get_wifi_iface || true)
  if [[ -z "$iface" ]]; then
    return 0
  fi
  read -r state conn < <(nm_state || echo "unknown unknown")

  # Trigger only when NM reports limited connectivity or no connectivity.
  if [[ "$state" == "connected" && ("$conn" == "limited" || "$conn" == "none") ]]; then
    if ! has_internet; then
      # If gateway reachable but internet isn't, this is likely WAN/DNS; still re-associate.
      # If gateway unreachable, likely Wi-Fi/AP issue; re-associate as well.
      if gateway_reachable; then
        log "Detected CONNECTED_SITE (gateway reachable, internet down)"
      else
        log "Detected CONNECTED_SITE (gateway unreachable)"
      fi
      heal_wifi "$iface"
    fi
  fi
}

main() {
  local mode="${1:-daemon}"
  case "$mode" in
    --once|once)
      check_once
      ;;
    daemon)
      log "Network Doctor started (interval=${CHECK_INTERVAL_SEC}s)"
      while true; do
        check_once || true
        sleep "$CHECK_INTERVAL_SEC"
      done
      ;;
    *)
      echo "Usage: $0 [--once|daemon]" >&2
      exit 2
      ;;
  esac
}

main "$@"
