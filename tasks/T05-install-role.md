# T05 — `install.sh` for the travel-router role

## Status
- **DONE** — committed `01c37e2`, env-prefix bugfix `c31f47d` (this file formerly lived as `tasks/PLAN-travel-router.md`).

## Goal
Create `roles/travel-router/install.sh` that installs the travel-router role on the Pi (apt, render-once, systemd wiring, PSK validation, final banner), following the repo role contract, with `TRAVELROUTER_DRY_RUN=1` + `DRY_RUN_PREFIX` fully honored so it passes the local QA battery without mutating the Pi.

## Context
- T1–T4 are complete and committed locally (verified):
  - T1 — role asset configs (committed `5b1de1e`).
  - T2 — `wan-select.sh` (committed `6d79d02`).
  - T3 — `travel-wan.sh` (committed `a3b08a0`).
  - T4 — `status-server.py` (committed `c35436a`; initial write `e2aec5c`).
- The plan (`/Users/al/code/rpi_project/.omo/plans/travel-router-role.md`) T5 spec is lines 136-163.
- `install.sh` follows the repo role contract: staged to bootfs `role/` and exec'd by the generic dispatcher via `role-setup.service`. Must source role.env two-path idiom, validate vars, apt hostapd/dnsmasq/nftables/iw **at the very start** (before unmanaging wlan0), resolve AP iface identically to wan-select, render assets ONCE, install + enable systemd units, `restart dnsmasq`, PSK 8–63 + charset validation, and print a final banner.
- DRY_RUN is the key local-QA seam: when `TRAVELROUTER_DRY_RUN=1` (with optional `DRY_RUN_PREFIX=<dir>`), the script must NOT call apt/systemctl/sysctl/ip/iw/rfkill/nft/systemd — it logs the intended actions instead, but still performs all validation and asset renders. With a DRY_RUN_PREFIX, file writes go under that prefix; the rendered nftables template must still render with the first non-comment line being `flush ruleset`.

## Files touched
- `roles/travel-router/install.sh` (new).

## Pre-conditions
- [x] T1–T4 committed and validated (they are).
- [ ] The repo role contract observed (bootfs `role/` staging, `role-setup.service` dispatcher) — confirm by reading `roles/` for an existing example role's install.sh (e.g. tailscale) and mirroring its structure/idiom.

## Exact changes required
Create `roles/travel-router/install.sh` as a POSIX/`bash` script with this structure:

1. **Header + guardrails**: `set -euo pipefail`. `DRY_RUN` defaults to `0`; honored if `TRAVELROUTER_DRY_RUN` is a truthy value. `DRY_RUN_PREFIX` defaults to `/`. A `run()` helper executes the real command when not dry-run, else logs it (`log_dry`). All system-mutating actions go through helpers, never direct calls.

2. **Source role.env (two-path idiom)** — mirror the tailscale role: try `${TRAVELROUTER_ROLE_ENV:-/run/travel-router/role.env}`; if absent, fall back to the staged config path under bootfs `role/` (`${DRY_RUN_PREFIX%/}/etc/role/travel-router/role.env` when dry-run), log the attempt. Then apply defaults via `:` assignments:
   - `: "${TRAVELROUTER_AP_COUNTRY:=US}"`, `: "${TRAVELROUTER_AP_NAME:=travel-router}"`, `: "${TRAVELROUTER_PSK:=$(openssl rand -base64 6)}"`, `: "${TRAVELROUTER_STATUS_PORT:=80}"`, `: "${TRAVELROUTER_AP_IFACE:=}"`.

3. **Validate required vars BEFORE apt**:
   - `TRAVELROUTER_PSK` present, length **8–63**, charset `A-Za-z0-9._-` AND **not** containing any of `| \ &` or a newline (these break the sed render idiom). On failure, log an exact remediation and `exit 1`.
   - `TRAVELROUTER_AP_NAME` non-empty.
   - `TRAVELROUTER_AP_COUNTRY` set (after default).
   - `TRAVELROUTER_AP_SSID` matches `^[ -~]{1,32}$` (no control chars) via `[[ =~ ]]`.

4. **apt BEFORE unmanage** — `run apt-get install -y --no-install-recommends hostapd dnsmasq nftables iw`. Log a note that the stock `dnsmasq` package auto-starts with an empty (inert) config, and that step 8's `systemctl restart dnsmasq` is what actually loads the rendered config.

5. **Install scripts** (mirror tailscale idiom; DRY_RUN writes under `DRY_RUN_PREFIX`):
   - `wan-select.sh → /usr/local/lib/travel-router/wan-select.sh`
   - `travel-wan.sh → /usr/local/bin/travel-wan` (0755)
   - `status-server.py → /usr/local/lib/travel-router/status-server.py`

6. **Resolve the AP interface** using the **exact same rule as wan-select**: the first wireless interface whose resolved `/sys/class/net/<if>/device` path does NOT contain `/usb` (onboard SDIO radio); fallback `wlan0`. Write a rendering-ready NM unmanaged conf to `/etc/NetworkManager/conf.d/90-travel-router-unmanaged.conf` (with that interface name in the file) and `run systemctl restart NetworkManager`. From here the AP iface is free for hostapd and the Pi's home-WiFi client config is neutralized. On the macOS runner (dry-run), the interface resolution must degrade gracefully (fallback to `wlan0`) without touching the host.

7. **Render ONCE**: hostapd.conf → `/etc/hostapd/hostapd-travel.conf`; dnsmasq.conf → `/etc/dnsmasq.d/travel-router.conf`; sysctl drop-in → `/etc/sysctl.d/90-travel-router.conf` + `run sysctl --system`. (install.sh is the sole owner of these files.)

8. **Systemd units**: `run systemctl daemon-reload`; `run systemctl enable --now wan-select.service`; `run systemctl restart dnsmasq.service` (mandatory — the stock-config instance running since apt is inert; a plain enable is a no-op on an already-active unit); `run systemctl enable --now hostapd-travel.service`; `run systemctl enable --now wan-select.timer`; `run systemctl enable --now travel-router-status.service`.

9. **Sanity-assert**: `/etc/dnsmasq.d` exists and stock `/etc/dnsmasq.conf` is inert (no active `listen-address` duplication). If an assertion fails, log exact remediation and `exit 1`.

10. **Final banner** (print to stdout after all actions succeed): AP SSID, LAN IP, status URL (http://<lan_ip>:<port>; when port is 80 omit `:80`), a one-line `travel-wan` usage reminder, and an explicit WARNING that the Pi can no longer be reached via home WiFi.

## Acceptance criteria (agent-executable, no Pi)
- `bash -n roles/travel-router/install.sh` passes; `bash install.sh TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX=/Users/al/code/rpi_project/.omo/role` (or the repo's dry-run idiom) runs end-to-end without mutating the host, performs PSK validation, renders all assets, and prints the banner.
- The rendered `90-travel-router-nftables.conf` first non-comment line is `flush ruleset`.
- PSK validation rejects: too-short (<8), too-long (>63), and charset violations (`|`, `\`, `&`, newline) with an exact remediation message.
- No untracked/drifted files introduced by the dry-run in the repo tree.

## Verification plan
Run (in a scratch clone or with dry-run, on the macOS runner):
```bash
bash -n roles/travel-router/install.sh && echo "SYNTAX_OK"
DRY_RUN=1 DRY_RUN_PREFIX=/tmp/rpishell bash roles/travel-router/install.sh   # or the repo's dry-run idiom
tail -30 /tmp/rpishell/role-setup.log      # rendered hosts, nftables render, banner
grep -A4 '^render_nftables' /tmp/rpishell/role-setup.log | head    # confirm first line 'flush ruleset'
```
- `SYNTAX_OK` prints, the banner is present, the first non-comment line of the rendered nftables is `flush ruleset`, and a malformed PSK triggers the remediation message with no host mutation.

## Success criteria
- [x] `bash -n` clean.
- [x] dry-run run: PSK validation renders all assets, renders nftables with `flush ruleset` first, prints banner, mutates nothing on the host.
- [x] git diff shows only `roles/travel-router/install.sh` (plus the `c31f47d` env-prefix fix).

## Rollback
    git stash  # or: rm roles/travel-router/install.sh

## Next task
After confirmed complete: execute T6 (`TRAVELROUTER_` env wiring into both provisioners + `.env.example`), then T7 docs, then T8 (local validation suite), then F1–F4.

## Notes / gotchas
- The Pi is frequently unreachable (`192.168.0.151`), so full install.sh execution must be verified on the Pi (F3, user-gated). This session's local validation of install.sh must rely on the dry-run seam — do **not** guess that apt/systemd wiring works without a real boot.
