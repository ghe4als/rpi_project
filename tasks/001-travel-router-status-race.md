# Task: Fix travel-router admin-page crash loop on reboot (wan-select race)

## Goal
Stop `travel-router-status.service` from crash-looping with `Errno 99` at boot.

## Context
The admin page (status page) was "not loading." Diagnosed from the Pi:

- `travel-router-status.service` is a pure Python stdlib service
  (`ThreadingHTTPServer`) that binds to the **LAN IP from `state.json`**,
  defaulting to `192.168.50.1` (see status-server.py `resolve_host_and_port`).
- On boot, `wan-select.service` writes `state.json` with `lan_ip=192.168.50.1`
  and immediately does `systemctl try-restart travel-router-status.service`.
- On the 2026-09-17 boot the IP `192.168.50.1` had not yet attached to `wlan0`
  when the restart fired, so `socket.bind((192.168.50.1,80))` threw
  `OSerror: [Errno 99] Cannot assign requested address`; systemd restarted it
  (`Restart=always`) and it kept failing for ~30s. Logs:
  `ssh pi@192.168.50.1 'journalctl -u travel-router-status.service'`.
- `wan-select.service` logged `Cannot find device "wlan0"` at 04:16:22 and
  failed; the IP appeared a few seconds later; status service recovered at
  ~04:22:33 and is healthy now (GET /setup -> 200, listener on 192.168.50.1:80).

**Root cause:** `wan-select.sh` restarts the status server *before* the bound
LAN IP is confirmed attached to the interface. On cold boot that order
difference produces the Errno 99 bind failure.

## Current state (verified 2026-09-17 11:25Z from the Pi)
- `travel-router-status.service`: **active (running)**, PID 908, listening on
  `192.168.50.1:80`. GET /, /setup, /health all -> 200.
- `wan-select.service`: completing cleanly; latest ticks end with
  `wan_select_done mode=routed wan_if=wlan1 lan_if=wlan0 lan_ip=192.168.50.1`.
- state.json present, mode=routed.
So the immediate outage is already resolved; the remaining task is preventing
the reboot race.

## Files touched
- `roles/travel-router/assets/wan-select.sh` — section (5), the
  `[[ "$PREV_LAN" != "$LAN_IP" ]]` block that does
  `run_or_log systemctl try-restart travel-router-status.service`.
- (optional) `roles/travel-router/assets/status-server.py` —
  `resolve_host_and_port()` bind host, if 0.0.0.0 bind is accepted.

## Design decision (confirm before choosing)
Two candidate fixes; pick ONE (see "Decide" below):
  A. **Guard in wan-select.sh** — only `try-restart` the status service after
     `iface_addr "$LAN_IF"` returns the LAN IP actually attached. Simple, local,
     targeted at the actual race. Next tick (30s) would restart it once the IP
     is up, but combined with the 04:22 recovery it becomes reachable quickly.
  B. **Bind 0.0.0.0 in status-server.py** — removes dependence on a specific
     IP ever being attached; most robust general fix (LAN service doesn't
     care which iface). Slightly larger change in scope; must confirm binding
     0.0.0.0 is acceptable per security posture.
Recommended: A for minimal blast radius; B for true permanence.

## Pre-conditions
- [ ] User chose fix A vs B (or both, sequentially).
- [ ] User approved applying a change on the Pi (production device).

## Exact changes required

### Fix A — wan-select.sh guard
File: `roles/travel-router/assets/wan-select.sh`
Location: `(5) Emit state.json + try-restart status server on LAN IP change`
(before):
```
if [[ "$PREV_LAN" != "$LAN_IP" ]]; then
  log "lan_ip changed ($PREV_LAN -> $LAN_IP): try-restart travel-router-status.service"
  run_or_log systemctl try-restart travel-router-status.service
fi
```
(after): only restart once the bound IP is actually attached to the LAN iface:
```
if [[ "$PREV_LAN" != "$LAN_IP" ]]; then
  if [[ -n "$LAN_IF" && -z "$DRY_RUN" \
        && "$IP" -4 addr show dev "$LAN_IF" 2>/dev/null \
           | awk 'index($0,"inet")' \
           | grep -q "${LAN_IP}/" ]]; then
    log "lan_ip changed ($PREV_LAN -> $LAN_IP): try-restart travel-router-status.service"
    run_or_log systemctl try-restart travel-router-status.service
  else
    log "lan_ip changed ($PREV_LAN -> $LAN_IP): IP not yet on $LAN_IF; status service starts next tick"
  fi
fi
```
Validate in dry-run: `TRAVELROUTER_DRY_RUN=1 bash roles/travel-router/assets/wan-select.sh`
should log the "not yet on" branch (IP unknown on the mac runner) and not error.

### Fix B — status-server.py bind host (if chosen)
File: `roles/travel-router/assets/status-server.py`
`resolve_host_and_port()` returns the bind host; make it return `0.0.0.0`
unconditionally (or the LAN IP only when it is present, else 0.0.0.0). This is
a larger edit — do only if A is rejected.

## Validation plan
For fix A:
- On the Pi: `sudo reboot`, then immediately (pre-boot-race window)
  `ssh pi@192.168.50.1 'journalctl -u travel-router-status.service --since "-40 sec" -p err'` — expect **zero** Errno 99 lines during bring-up.
- After IP is up: `curl -s -o /dev/null -w '%{http_code}\n' http://192.168.50.1/setup` -> 200.
- Dry-run render on mac: `TRAVELROUTER_DRY_RUN=1 bash roles/travel-router/assets/wan-select.sh` — exit 0, no traceback.

## Success criteria
- [ ] wan-select no longer triggers a status-server restart before the IP is attached.
- [ ] No Errno 99 in status logs across a reboot.
- [ ] Admin page reachable on first post-boot curl.

## Rollback
`roles/travel-router/assets/wan-select.sh` only. If applied on the Pi, revert
with the backup taken at deploy time.

## Next task
Execute fix A (or B if the user chooses). Keep wan-select.sh as the single
touch point; do not also patch status-server.py unless both are wanted.
