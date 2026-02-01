#!/usr/bin/env bash
set -euo pipefail

# Network Doctor v2 - Wi-Fi self-healer for NetworkManager
#
# Recovery strategy (escalating):
#   1. Soft recovery: nmcli disconnect/connect (handles NM stuck states)
#   2. Hard recovery: USB device reset (handles driver/firmware hangs)
#
# Detection methods:
#   1. Polling: NM connectivity state + ping checks (every CHECK_INTERVAL_SEC)
#   2. Journal: watches for handshake failures (immediate detection)

# Configuration (override via environment)
CHECK_INTERVAL_SEC="${CHECK_INTERVAL_SEC:-30}"
IFACE_OVERRIDE="${IFACE_OVERRIDE:-}"
PING_HOSTS=("1.1.1.1" "8.8.8.8")

# USB hard reset config (set to enable; leave empty to disable)
USB_RESET_VENDOR="${USB_RESET_VENDOR:-}"      # e.g., "0cf3" for Atheros
USB_RESET_PRODUCT="${USB_RESET_PRODUCT:-}"    # e.g., "9271" for AR9271
SOFT_FAIL_MAX="${SOFT_FAIL_MAX:-3}"           # soft failures before hard reset
HARD_RESET_COOLDOWN="${HARD_RESET_COOLDOWN:-60}"

# Journal monitoring (set to "1" to enable)
JOURNAL_MONITOR="${JOURNAL_MONITOR:-0}"

# State tracking
SOFT_FAIL_COUNT=0
LAST_HARD_RESET=0

log() {
  logger -t network-doctor "$*"
  echo "[$(date '+%H:%M:%S')] $*"
}

get_wifi_iface() {
  if [[ -n "$IFACE_OVERRIDE" ]]; then
    echo "$IFACE_OVERRIDE"
    return 0
  fi
  nmcli -t -f DEVICE,TYPE,STATE dev status 2>/dev/null \
    | awk -F: '$2=="wifi" && $3=="connected" {print $1; exit}'
}

get_any_wifi_iface() {
  # Get any wifi interface, even if not connected
  if [[ -n "$IFACE_OVERRIDE" ]]; then
    echo "$IFACE_OVERRIDE"
    return 0
  fi
  nmcli -t -f DEVICE,TYPE dev status 2>/dev/null \
    | awk -F: '$2=="wifi" {print $1; exit}'
}

nm_state() {
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

# Soft recovery: tell NetworkManager to reconnect
soft_recovery() {
  local iface="$1"
  local reason="${2:-unknown}"

  log "SOFT RECOVERY ($reason) on $iface"

  # Try connection up first (uses saved connection)
  local conn_name
  conn_name=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep ":${iface}$" | cut -d: -f1 | head -1)

  if [[ -n "$conn_name" ]]; then
    log "Attempting: nmcli connection up '$conn_name'"
    if nmcli connection up "$conn_name" 2>&1; then
      log "Soft recovery successful (connection up)"
      SOFT_FAIL_COUNT=0
      return 0
    fi
  fi

  # Fallback: disconnect and reconnect device
  log "Trying device disconnect/connect"
  nmcli device disconnect "$iface" >/dev/null 2>&1 || true
  sleep 2
  if nmcli device connect "$iface" >/dev/null 2>&1; then
    log "Soft recovery successful (device reconnect)"
    SOFT_FAIL_COUNT=0
    return 0
  fi

  # Soft recovery failed
  SOFT_FAIL_COUNT=$((SOFT_FAIL_COUNT + 1))
  log "Soft recovery failed (attempt $SOFT_FAIL_COUNT/$SOFT_FAIL_MAX)"

  # Escalate to hard recovery if configured and threshold reached
  if [[ -n "$USB_RESET_VENDOR" && -n "$USB_RESET_PRODUCT" ]]; then
    if [[ $SOFT_FAIL_COUNT -ge $SOFT_FAIL_MAX ]]; then
      hard_recovery "soft_recovery_exhausted"
    fi
  fi

  return 1
}

# Hard recovery: USB device reset
hard_recovery() {
  local reason="${1:-unknown}"

  if [[ -z "$USB_RESET_VENDOR" || -z "$USB_RESET_PRODUCT" ]]; then
    log "Hard recovery skipped (USB_RESET_VENDOR/PRODUCT not configured)"
    return 1
  fi

  # Cooldown check
  local now
  now=$(date +%s)
  local elapsed=$((now - LAST_HARD_RESET))
  if [[ $elapsed -lt $HARD_RESET_COOLDOWN ]]; then
    log "Hard recovery skipped (cooldown: ${elapsed}s < ${HARD_RESET_COOLDOWN}s)"
    return 1
  fi

  # Find USB device
  local device_path=""
  local driver_path="/sys/bus/usb/drivers/usb"

  for dev in /sys/bus/usb/devices/*/idVendor; do
    local dir vendor product
    dir=$(dirname "$dev")
    vendor=$(cat "$dir/idVendor" 2>/dev/null || echo "")
    product=$(cat "$dir/idProduct" 2>/dev/null || echo "")
    if [[ "$vendor" == "$USB_RESET_VENDOR" && "$product" == "$USB_RESET_PRODUCT" ]]; then
      device_path=$(basename "$dir")
      break
    fi
  done

  if [[ -z "$device_path" ]]; then
    log "Hard recovery failed: USB device ${USB_RESET_VENDOR}:${USB_RESET_PRODUCT} not found"
    return 1
  fi

  log "HARD RECOVERY ($reason) - USB reset $device_path"
  LAST_HARD_RESET=$now

  # Unbind
  if [[ -e "${driver_path}/${device_path}" ]]; then
    log "Unbinding $device_path"
    echo "$device_path" > "${driver_path}/unbind" 2>/dev/null || {
      log "Failed to unbind $device_path"
      return 1
    }
    sleep 2
  fi

  # Rebind
  log "Rebinding $device_path"
  echo "$device_path" > "${driver_path}/bind" 2>/dev/null || {
    log "Failed to rebind $device_path"
    return 1
  }

  log "USB reset complete, waiting for driver init"
  sleep 10

  # Reset counters
  SOFT_FAIL_COUNT=0

  # Try to reconnect
  local iface
  iface=$(get_any_wifi_iface || true)
  if [[ -n "$iface" ]]; then
    nmcli device connect "$iface" >/dev/null 2>&1 || true
  fi

  return 0
}

# Check connectivity and heal if needed
check_once() {
  local iface state conn
  iface=$(get_wifi_iface || true)

  # If no connected wifi interface, check if we have any wifi interface at all
  if [[ -z "$iface" ]]; then
    iface=$(get_any_wifi_iface || true)
    if [[ -n "$iface" ]]; then
      # Have interface but not connected - try to connect
      log "WiFi interface $iface exists but not connected"
      soft_recovery "$iface" "not_connected"
    fi
    return 0
  fi

  read -r state conn < <(nm_state || echo "unknown unknown")

  # Check for limited/no connectivity
  if [[ "$state" == "connected" && ("$conn" == "limited" || "$conn" == "none") ]]; then
    if ! has_internet; then
      if gateway_reachable; then
        log "Detected limited connectivity (gateway OK, internet down)"
      else
        log "Detected limited connectivity (gateway unreachable)"
      fi
      soft_recovery "$iface" "limited_connectivity"
    fi
  elif [[ "$state" == "connected" && "$conn" == "full" ]]; then
    # All good - reset soft fail counter
    if [[ $SOFT_FAIL_COUNT -gt 0 ]]; then
      log "Connectivity restored"
      SOFT_FAIL_COUNT=0
    fi
  fi
}

# Journal monitor for handshake failures (runs in background)
monitor_journal() {
  log "Journal monitor started"

  journalctl -f -n 0 -u wpa_supplicant -u NetworkManager --no-hostname -o cat 2>/dev/null | \
  while IFS= read -r line; do
    if [[ "$line" == *"4-Way Handshake failed"* ]] || \
       [[ "$line" == *"reason=WRONG_KEY"* ]] || \
       [[ "$line" == *"Activation: failed"* ]] || \
       [[ "$line" == *"no-secrets"* ]]; then
      log "Journal: detected auth failure"
      local iface
      iface=$(get_any_wifi_iface || true)
      if [[ -n "$iface" ]]; then
        soft_recovery "$iface" "auth_failure"
      fi
    fi
  done
}

main() {
  local mode="${1:-daemon}"

  case "$mode" in
    --once|once)
      check_once
      ;;
    daemon)
      log "=========================================="
      log "Network Doctor v2 started"
      log "=========================================="
      log "Check interval: ${CHECK_INTERVAL_SEC}s"
      log "Interface override: ${IFACE_OVERRIDE:-auto}"
      if [[ -n "$USB_RESET_VENDOR" && -n "$USB_RESET_PRODUCT" ]]; then
        log "USB hard reset: enabled (${USB_RESET_VENDOR}:${USB_RESET_PRODUCT})"
        log "Hard reset after: $SOFT_FAIL_MAX soft failures"
      else
        log "USB hard reset: disabled"
      fi
      if [[ "$JOURNAL_MONITOR" == "1" ]]; then
        log "Journal monitor: enabled"
        monitor_journal &
      else
        log "Journal monitor: disabled"
      fi

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
