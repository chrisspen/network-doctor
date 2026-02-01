# Network Doctor

A systemd service that monitors NetworkManager connectivity and automatically recovers from WiFi failures.

## What it does

**Detection:**
- Monitors NM connectivity state (CONNECTED_SITE / limited / none)
- Verifies internet reachability via ping
- Optional: watches journal for authentication failures (immediate detection)

**Recovery (escalating):**
1. **Soft recovery**: `nmcli connection up` / `nmcli device reconnect`
2. **Hard recovery**: USB device reset (for driver/firmware hangs) - optional

## Install from APT (recommended)

```bash
# Add GPG key
curl -fsSL https://chrisspen.github.io/network-doctor/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/network-doctor.gpg

# Add repository
echo "deb [signed-by=/usr/share/keyrings/network-doctor.gpg] https://chrisspen.github.io/network-doctor ./" | sudo tee /etc/apt/sources.list.d/network-doctor.list

# Install
sudo apt update
sudo apt install network-doctor
```

To update:

```bash
sudo apt update && sudo apt upgrade
```

To uninstall:

```bash
sudo apt remove network-doctor
```

## Install from source

```bash
./install.sh
```

To uninstall:

```bash
./uninstall.sh
```

## Configuration

All configuration is via environment variables. Set them in a systemd override:

```bash
sudo systemctl edit network-doctor.service
```

### Basic options

| Variable | Default | Description |
|----------|---------|-------------|
| `CHECK_INTERVAL_SEC` | `30` | Seconds between connectivity checks |
| `IFACE_OVERRIDE` | (auto) | Force specific interface (e.g., `wlp3s0`) |

### USB hard reset (for problematic adapters)

Enable this for USB WiFi adapters with driver issues (e.g., ath9k_htc):

| Variable | Default | Description |
|----------|---------|-------------|
| `USB_RESET_VENDOR` | (disabled) | USB vendor ID (e.g., `0cf3` for Atheros) |
| `USB_RESET_PRODUCT` | (disabled) | USB product ID (e.g., `9271` for AR9271) |
| `SOFT_FAIL_MAX` | `3` | Soft recovery failures before hard reset |
| `HARD_RESET_COOLDOWN` | `60` | Minimum seconds between hard resets |

### Journal monitoring

For faster detection of authentication failures:

| Variable | Default | Description |
|----------|---------|-------------|
| `JOURNAL_MONITOR` | `0` | Set to `1` to enable journal monitoring |

### Example: Raspberry Pi with AR9271 USB adapter

```bash
sudo systemctl edit network-doctor.service
```

```ini
[Service]
Environment=CHECK_INTERVAL_SEC=15
Environment=USB_RESET_VENDOR=0cf3
Environment=USB_RESET_PRODUCT=9271
Environment=JOURNAL_MONITOR=1
Environment=IFACE_OVERRIDE=wlx24ec99bfc887
```

Find your USB IDs with: `lsusb | grep -i wireless` or `lsusb | grep -i wifi`

## Manual run

```bash
# One-shot check
sudo /usr/local/bin/network-doctor --once

# Daemon mode (foreground)
sudo /usr/local/bin/network-doctor daemon
```

## Logs

```bash
journalctl -u network-doctor -f
```

## How it works

1. Every `CHECK_INTERVAL_SEC` seconds, checks NM state and pings internet
2. If connectivity is limited/none and ping fails:
   - Tries `nmcli connection up` (preserves saved credentials)
   - Falls back to `nmcli device disconnect/connect`
3. If soft recovery fails `SOFT_FAIL_MAX` times and USB reset is configured:
   - Unbinds/rebinds USB device to reset driver
   - Waits for driver init, then reconnects
4. Optional journal monitor catches auth failures immediately (doesn't wait for poll)
