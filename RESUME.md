# RESUME — travel-router-role

Where am I right now. Source of truth for a fresh session. Checkpoint: **`bec070b`**
(HEAD, clean tree). Last updated: 2026-09-13.

## Current state

**IMPLEMENTATION COMPLETE — F1–F4 final verification wave is the only remaining work.**

Full arc: 6-lane audit (2026-09-13) confirmed 4 CRITICAL + ~10 MAJOR defects in the
committed T1–T6 code (dry-run QA masked the real-execution class) → plan updated
(todos 7–12) → dual review rr-005 (Momus APPROVE; Oracle CHANGES_REQUESTED → C1/C2 +
M1–M4 all folded in) → repair wave executed → validation suite GREEN 88/0.

## Commits this wave (one per todo, per repo protocol)

- `61c7c47` fix(travel-router): install systemd units, exec bits, deploy nftables template, SSID validation
- `dd54b90` fix(travel-router): wan-select regdom parse, ethernet-first, nft load order, state robustness
- `73db0a3` fix(travel-router): status parity + real recheck + travel-wan seam + dnsmasq self-DNS
- `b4fdbb6` docs(travel-router): README + INVENTORY entries and travel workflow
- `bec070b` test(travel-router): local validation suite for role artifacts
- (next) docs: fix stale NATS IP in legacy task doc + checkpoint RESUME  ← T12

## What is now true (was broken)

- Units installed to /etc/systemd/system before enable; wan-select.sh 0755;
  nftables.conf.tmpl deployed next to wan-select; SSID rejects | & \ $ + newlines.
- wan-select: regdom colon stripped (iw reg set gets 2-letter code, 00→US fallback
  works), auto mode ETHERNET-first, copy-before-nft (fresh rules every tick),
  power_save via iw, crash-proof preference modes, atomic same-dir tmp+mv state.json,
  hot-unplug-probed reads guarded.
- travel-wan: status JSON carries mode/lan_ip/standalone from state.json (never
  hardcoded), SSID sanitized before JSON, recheck actually triggers wan-select,
  nmcli `ifname` syntax correct, SYSTEMCTL seam.
- status-server: TRAVELWAN_BIN seam, list-form subprocess (no bash -c), fallback
  payload seeds mode/lan_ip from state.json; dnsmasq bare dhcp-option=6 removed
  (dnsmasq advertises self-DNS by default).
- README: roles-table row + TRAVELROUTER_* env row + ROLE enum fixed + full
  "Provisioning the travel-router Pi" section (buy/home-test/hotel/recovery).
  INVENTORY.md roles row added.

## Green gate

`roles/travel-router/assets/validate-local.sh` → **SUITE GREEN: 88 passed, 0 failed**
(runs: syntax, install.sh dry-run battery + breaker batteries + order asserts,
nftables structural, provisioner filter both provisioners, docs cross-check,
seam asserts, wan-select non-dry-run regression battery incl. cp-before-nft order +
SYSTEMCTL stub + truncated-state resilience + atomic write, travel-wan status parity
+ real recheck, status-server bind/routes/fallback). Evidence:
`.omo/evidence/travel-router-role/task-{7,8,9,10,11}-travel-router-role.log`.

## Remaining (final wave)

- F1 plan compliance audit · F2 code quality review · F3 **USER-GATED** hardware QA
  (flash + boot + hotel portal per README) · F4 scope fidelity.
- Known documented residuals (deliberate, recorded in task-11 log): B12
  TRAVELROUTER_STATUS_PORT not validated at install; B13 connection-name colon
  truncation (awk -F:); B7-core (malformed role.env proceeds to late validation);
  missing evidence logs task-2..task-6 (waiver — todo 11 battery is the durable gate);
  STATUS_PORT≠80 firewalled (nftables hardcodes tcp/80 — port-80 documented).
- `.omo/` gitignored — never staged. `.env`/`inventory.yaml` gitignored — never staged.

## Gotchas carried forward

- Dry-run QA masks real-execution defects — todo 11's battery asserts the
  deployment/runtime classes directly; keep that discipline for any new role work.
- Pi Zero W v1.1: 32-bit armhf Lite only (Bookworm recommended); after role-setup the
  Pi is reachable ONLY via the travel SSID or a USB Ethernet adapter.
- status-server binds the state.json lan_ip at startup; QA fixtures must use a
  bindable address (127.0.0.1) on the runner.