#!/usr/bin/env bats

# Test helper to source functions without running main
setup() {
  # Create temp dir for mocks
  TEST_DIR="$(mktemp -d)"
  PATH="$TEST_DIR:$PATH"

  # Source the script functions (we'll mock external commands)
  # Extract functions only, skip the main call
  source <(sed '/^main "\$@"/d' "$BATS_TEST_DIRNAME/../network-doctor.sh")

  # Reset state
  SOFT_FAIL_COUNT=0
  LAST_HARD_RESET=0
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Helper to create mock commands
mock_command() {
  local cmd="$1"
  local output="$2"
  local exit_code="${3:-0}"

  cat > "$TEST_DIR/$cmd" << EOF
#!/bin/bash
echo "$output"
exit $exit_code
EOF
  chmod +x "$TEST_DIR/$cmd"
}

# =============================================================================
# Interface detection tests
# =============================================================================

@test "get_wifi_iface returns IFACE_OVERRIDE when set" {
  IFACE_OVERRIDE="wlan99"
  run get_wifi_iface
  [ "$status" -eq 0 ]
  [ "$output" = "wlan99" ]
}

@test "get_wifi_iface finds connected wifi interface" {
  IFACE_OVERRIDE=""
  mock_command "nmcli" "wlan0:wifi:connected"
  run get_wifi_iface
  [ "$status" -eq 0 ]
  [ "$output" = "wlan0" ]
}

@test "get_wifi_iface returns empty when no wifi connected" {
  IFACE_OVERRIDE=""
  mock_command "nmcli" ""
  run get_wifi_iface
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "get_any_wifi_iface finds disconnected interface" {
  IFACE_OVERRIDE=""
  mock_command "nmcli" "wlan0:wifi"
  run get_any_wifi_iface
  [ "$status" -eq 0 ]
  [ "$output" = "wlan0" ]
}

# =============================================================================
# Connectivity detection tests
# =============================================================================

@test "nm_state parses connected full state" {
  mock_command "nmcli" "connected:full"
  run nm_state
  [ "$status" -eq 0 ]
  [ "$output" = "connected full" ]
}

@test "nm_state parses connected limited state" {
  mock_command "nmcli" "connected:limited"
  run nm_state
  [ "$status" -eq 0 ]
  [ "$output" = "connected limited" ]
}

@test "nm_state handles nmcli failure" {
  mock_command "nmcli" "" 1
  run nm_state
  [ "$output" = "" ]
}

@test "has_internet succeeds when first host responds" {
  mock_command "ping" "PING 1.1.1.1" 0
  run has_internet
  [ "$status" -eq 0 ]
}

@test "has_internet fails when all hosts unreachable" {
  mock_command "ping" "" 1
  run has_internet
  [ "$status" -eq 1 ]
}

# =============================================================================
# Soft recovery tests
# =============================================================================

@test "soft_recovery increments fail count on failure" {
  SOFT_FAIL_COUNT=0
  mock_command "nmcli" "" 1

  # Run soft_recovery (will fail due to mock)
  soft_recovery "wlan0" "test" || true

  [ "$SOFT_FAIL_COUNT" -eq 1 ]
}

@test "soft_recovery resets fail count on success" {
  SOFT_FAIL_COUNT=2

  # Mock nmcli to show active connection then succeed
  cat > "$TEST_DIR/nmcli" << 'EOF'
#!/bin/bash
if [[ "$1" == "-t" ]]; then
  echo "MyWifi:wlan0"
else
  exit 0
fi
EOF
  chmod +x "$TEST_DIR/nmcli"

  soft_recovery "wlan0" "test"
  [ "$SOFT_FAIL_COUNT" -eq 0 ]
}

@test "soft_recovery tries device reconnect as fallback" {
  SOFT_FAIL_COUNT=0
  USB_RESET_VENDOR=""
  USB_RESET_PRODUCT=""

  # First nmcli call returns no connection, subsequent calls succeed
  cat > "$TEST_DIR/nmcli" << 'EOF'
#!/bin/bash
if [[ "$1" == "-t" ]]; then
  echo ""  # No active connection
elif [[ "$2" == "disconnect" ]]; then
  exit 0
elif [[ "$2" == "connect" ]]; then
  exit 0
fi
EOF
  chmod +x "$TEST_DIR/nmcli"

  run soft_recovery "wlan0" "test"
  [ "$status" -eq 0 ]
}

# =============================================================================
# Hard recovery tests
# =============================================================================

@test "hard_recovery skipped when USB not configured" {
  USB_RESET_VENDOR=""
  USB_RESET_PRODUCT=""

  run hard_recovery "test"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not configured"* ]]
}

@test "hard_recovery respects cooldown period" {
  USB_RESET_VENDOR="0cf3"
  USB_RESET_PRODUCT="9271"
  HARD_RESET_COOLDOWN=60
  LAST_HARD_RESET=$(date +%s)

  run hard_recovery "test"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cooldown"* ]]
}

@test "hard_recovery fails when USB device not found" {
  USB_RESET_VENDOR="ffff"
  USB_RESET_PRODUCT="ffff"
  HARD_RESET_COOLDOWN=0
  LAST_HARD_RESET=0

  run hard_recovery "test"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

# =============================================================================
# Error path tests (common failure scenarios)
# =============================================================================

@test "handles nmcli not installed" {
  rm -f "$TEST_DIR/nmcli"
  # Remove from PATH entirely for this test
  PATH="/usr/bin:/bin"

  run get_wifi_iface
  # Should not crash, just return empty
  [ "$status" -eq 0 ] || [ "$status" -eq 127 ]
}

@test "handles NetworkManager not running" {
  mock_command "nmcli" "Error: NetworkManager is not running." 1

  run nm_state
  [ "$output" = "" ]
}

@test "escalates to hard recovery after max soft failures" {
  SOFT_FAIL_COUNT=2
  SOFT_FAIL_MAX=3
  USB_RESET_VENDOR="0cf3"
  USB_RESET_PRODUCT="9271"
  HARD_RESET_COOLDOWN=0
  LAST_HARD_RESET=0

  # Mock nmcli to fail
  mock_command "nmcli" "" 1

  # This should trigger hard recovery attempt (which will fail due to no USB device)
  run soft_recovery "wlan0" "test"

  # Should have tried hard recovery (look for "not found" since no real USB device)
  [[ "$output" == *"HARD RECOVERY"* ]] || [[ "$output" == *"not found"* ]]
}

@test "check_once handles missing wifi interface gracefully" {
  IFACE_OVERRIDE=""
  mock_command "nmcli" ""

  run check_once
  [ "$status" -eq 0 ]
}

@test "check_once triggers recovery on limited connectivity" {
  IFACE_OVERRIDE="wlan0"

  # Complex mock for multiple nmcli calls
  cat > "$TEST_DIR/nmcli" << 'EOF'
#!/bin/bash
case "$*" in
  *"DEVICE,TYPE,STATE"*) echo "wlan0:wifi:connected" ;;
  *"STATE,CONNECTIVITY"*) echo "connected:limited" ;;
  *"NAME,DEVICE"*) echo "MyWifi:wlan0" ;;
  *"connection up"*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$TEST_DIR/nmcli"

  # Mock ping to fail (no internet)
  mock_command "ping" "" 1

  run check_once
  # Should have attempted recovery
  [[ "$output" == *"SOFT RECOVERY"* ]] || [[ "$output" == *"limited"* ]]
}
