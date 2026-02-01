#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}                    Network Doctor Status                   ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo

# Service status
if systemctl is-active --quiet network-doctor.service 2>/dev/null; then
    echo -e "Service:        ${GREEN}● running${NC}"
else
    echo -e "Service:        ${RED}● stopped${NC}"
fi

if systemctl is-enabled --quiet network-doctor.service 2>/dev/null; then
    echo -e "Enabled:        ${GREEN}yes${NC}"
else
    echo -e "Enabled:        ${YELLOW}no${NC}"
fi

# Uptime
uptime_info=$(systemctl show network-doctor.service --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)
if [[ -n "$uptime_info" && "$uptime_info" != "n/a" ]]; then
    echo -e "Since:          $uptime_info"
fi

echo

# Configuration
echo -e "${CYAN}Configuration:${NC}"
env_vars=$(systemctl show network-doctor.service --property=Environment 2>/dev/null | cut -d= -f2-)
if [[ -n "$env_vars" && "$env_vars" != "" ]]; then
    echo "$env_vars" | tr ' ' '\n' | while read -r var; do
        [[ -n "$var" ]] && echo "  $var"
    done
else
    echo "  (defaults)"
fi

echo

# Current connectivity
echo -e "${CYAN}Current State:${NC}"
wifi_iface=$(nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | awk -F: '$2=="wifi" {print $1; exit}')
if [[ -n "$wifi_iface" ]]; then
    wifi_state=$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep "^${wifi_iface}:" | cut -d: -f2)
    echo -e "  Interface:    $wifi_iface ($wifi_state)"

    if [[ "$wifi_state" == "connected" ]]; then
        ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2)
        signal=$(nmcli -t -f active,signal dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2)
        echo -e "  SSID:         $ssid"
        echo -e "  Signal:       ${signal}%"
    fi

    nm_state=$(nmcli -g STATE,CONNECTIVITY general 2>/dev/null | tr ':' ' ')
    echo -e "  NM State:     $nm_state"

    if ping -c 1 -W 2 1.1.1.1 &>/dev/null; then
        echo -e "  Internet:     ${GREEN}reachable${NC}"
    else
        echo -e "  Internet:     ${RED}unreachable${NC}"
    fi
else
    echo -e "  ${YELLOW}No WiFi interface found${NC}"
fi

echo

# Recent activity
echo -e "${CYAN}Recent Activity (last 10 events):${NC}"
journalctl -u network-doctor --no-pager -n 20 --output=cat 2>/dev/null | grep -E 'SOFT RECOVERY|HARD RECOVERY|Connectivity restored|started|detected' | tail -10 | while read -r line; do
    if [[ "$line" == *"RECOVERY"* ]]; then
        echo -e "  ${YELLOW}$line${NC}"
    elif [[ "$line" == *"restored"* ]]; then
        echo -e "  ${GREEN}$line${NC}"
    else
        echo "  $line"
    fi
done

# Stats
echo
echo -e "${CYAN}Recovery Stats (last 24h):${NC}"
soft_count=$(journalctl -u network-doctor --since "24 hours ago" --no-pager --output=cat 2>/dev/null | grep -c "SOFT RECOVERY" || echo "0")
hard_count=$(journalctl -u network-doctor --since "24 hours ago" --no-pager --output=cat 2>/dev/null | grep -c "HARD RECOVERY" || echo "0")
echo "  Soft recoveries:  $soft_count"
echo "  Hard recoveries:  $hard_count"

echo
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
