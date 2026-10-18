# Task: Fix travel-router admin-page crash loop on reboot (wan-select race) — RESOLVED

## Goal
Stop `travel-router-status.service` from crash-looping with `Errno 99` at boot.

## Root cause
`wan-select.sh` used to restart the status server as soon as `state.json`'s `lan_ip` changed, before the IP was actually attached to the LAN interface. If `192.168.50.1` had not yet landed on `wlan0`, the status server's `socket.bind((192.168.50.1,80))` threw `OSError: [Errno 99] Cannot assign requested address`, and systemd (`Restart=always`) would restart it repeatedly until the IP appeared.

## Resolution
The guard was implemented in `roles/travel-router/assets/wan-select.sh` lines 515-534:

- On a `lan_ip` change, wan-select first verifies the IP is present on the LAN interface via `ip -4 addr show dev $LAN_IF`.
- Only when the IP is attached does it `systemctl try-restart --no-block travel-router-status.service`.
- If the IP is not yet attached, it logs the skip and the next 30s tick will restart the service once the IP is ready.

The `--no-block` flag is required because `wan-select.service` is ordered `Before=travel-router-status.service`; a blocking restart would deadlock.

## Current state
- `wan-select.sh:515-534` contains the verified fix.
- The status server also gained an additional startup bind-retry loop (`status-server.py`) to tolerate transient IP-absence windows.

## Files touched
- `roles/travel-router/assets/wan-select.sh` — lines 515-534 (IP-attached guard).
- `roles/travel-router/assets/status-server.py` — bind retry loop in `main()`.

## Validation
- On the Pi: `journalctl -u travel-router-status.service --since '-40 sec' -p err` should show zero `Errno 99` lines across a reboot.
- `curl -s -o /dev/null -w '%{http_code}\n' http://192.168.50.1/` returns 200 once the LAN IP is up.
- Dry-run render on mac: `TRAVELROUTER_DRY_RUN=1 bash roles/travel-router/assets/wan-select.sh` exits 0 with no traceback.

## Rollback
If the IP-attached guard causes unexpected delay, revert lines 515-534 of `wan-select.sh` to the original unconditional `try-restart`.
