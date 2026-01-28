# Network Doctor

A tiny systemd service that watches for NetworkManager reporting "connected" with **limited/no internet** and automatically re-associates Wi-Fi to recover.

## What it does
- Checks NetworkManager connectivity status (CONNECTED_SITE / CONNECTED_LOCAL).
- Verifies internet reachability by pinging public IPs.
- If internet is down while Wi-Fi stays associated, it disconnects/reconnects the Wi‑Fi device.

## Install
```bash
./install.sh
```

## Uninstall
```bash
./uninstall.sh
```

## Manual run (one-shot)
```bash
sudo /usr/local/bin/network-doctor --once
```

## Configuration
Environment variables (optional):
- `CHECK_INTERVAL_SEC` (default `30`)
- `IFACE_OVERRIDE` (force interface, e.g. `wlp3s0`)

Set these in a systemd override:
```bash
sudo systemctl edit network-doctor.service
```
Example:
```
[Service]
Environment=CHECK_INTERVAL_SEC=15
Environment=IFACE_OVERRIDE=wlp3s0
```

## Logs
```bash
journalctl -u network-doctor.service -f
```

## Notes
This is a simple heuristic; it prioritizes quick recovery over deep diagnostics. If outages persist, check router/ISP stability and DNS settings.
