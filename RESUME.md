# RESUME — travel-router-role

Where am I right now. Source of truth for a fresh session. Checkpoint: **`b6c0211`**.

## State (2026-09-13)
- **Rollback point:** `git reset --hard 5b1de1e` (T1 checkpoint). Current HEAD `b6c0211`.
- **Working tree:** uncommitted `roles/travel-router/install.sh` (new file).
- **Active work:** `travel-router-role`. Plan locked, dual APPROVE (Momus + Oracle).

## What's done + committed
- **T1** — role asset configs (`5b1de1e`).
- **T2** — `wan-select.sh` WAN autodetect + nftables render/load + state.json (`6d79d02`).
- **T3** — `travel-wan.sh` hotel-wifi CLI (`a3b08a0`).
- **T4** — `status-server.py` stdlib status page (`b6c0211`):
  - `GET / /status /health`; all others → 404.
  - `/status` shells to `/usr/local/bin/travel-wan`, merges over cached
    defaults (single TTL, cache validated). 30s in-process reachability cache.
  - binds `lan_ip` from state.json, port `TRAVELROUTER_STATUS_PORT` (default 80, root).
  - write verbs bound → 404; no `do_*` POST literal in source
  - bugs found+fixed locally: `_cache_result` was missing from `global`,
    which would have 500'd on the second page load; removed.
- **No writes to /boot; no prompts; no PSK echo.**

## What's next (dependency order)
1. **T5** `install.sh` (needs T2-T4): apt hostapd/dnsmasq/nftables/iw BEFORE
   unmanaging wlan0; render-once; enable+start units; PSK 8-63 check. **STATUS: DONE.**
   Verified via dry-run battery (rc=0 happy-path, rc=1 all PSK-fail cases, default
   generated PSK renders). Fixed this run: wrong var prefix, `sed` on bare
   file (→ `cp`), `TRAWELROUTER_STATUS_PORT` unbound under `set -u` (→ default
   80), default-gen PSK may drop below 8 chars (→ retry loop + truncation).
2. **T6** `TRAVELROUTER_` env wiring in `provision.sh:190` + `.env.example`.
3. **T7** docs (README roles/env tables, usage, `INVENTORY.md` row).
4. **T8** `validate-local.sh` QA battery.
5. **F1-F4** final wave.

## Why the last run stopped
External infra: **provider model usage limits + a background-worker timeout** — not a design
or code defect. Prior run reported T1/T2/T3/T4/T6 as failed and cancelled everything. Only
**T1's assets are actually on disk and valid** (verified by `.omo/evidence/.../task-1-*`).
The most recent attempt re-read the T2 spec (good diligence) but context-bloated and wrote no
code. **Nothing is broken on disk; just resume.**

## What's done
- **T1 — role asset configs: DONE + committed** (`5b1de1e`). 9 files under
  `roles/travel-router/assets/` (hostapd/dnsmasq/nftables[flush-first] templates,
  90-travel-router sysctl, NM unmanaged.conf, wan-select.service+timer,
  hostapd-travel.service, travel-router-status.service). Pass task-1 evidence battery.

## What's next (dependency order, per plan waves)
1. **T2 (NEXT)** `roles/travel-router/assets/wan-select.sh` — USB WAN autodetect
   (USB-WiFi→hotel client, USB-Eth→wired, prefer Ethernet, none→standalone); per-run
   nftables render→`nft -f /etc/nftables.conf` (template first line `flush ruleset`);
   write `state.json` (keys: mode,wan_if,wan_ssid,wan_ip,lan_ip,ap_interface,timestamp);
   try-restart status service on lan_ip change.
   **MUST test seams:** `SYSFS_ROOT`(default /sys), `IP/IW/NFT/NMCLI/RFKILL` overridable,
   `TRAVELROUTER_DRY_RUN=1` (logs mutations incl. `nft -f`), `TRAVELROUTER_STATE_FILE`
   (default /run/travel-router/state.json), AP iface = first non-/usb wireless else wlan0,
   regdom rejects country `00`→US. **MUST NOT:** restart NetworkManager / hostapd / dnsmasq,
   bridge, hardcode eth0. Spec: plan `.omo/plans/travel-router-role.md` lines 102-116.
2. **T3** `assets/travel-wan.sh` — `scan|connect|disconnect|forget|status[—json]|recheck`
   over nmcli; seams NMCLI/IP/CURL/HOSTAPD_CLI + STATE_FILE; no PSK in status output;
   no writes under /boot.
3. **T4** `assets/status-server.py` — stdlib http.server, bind lan_ip:80,
   `GET / /status /health`, reachability cached 30s, STATE_FILE seam, no POST/forms.
4. **T5** `roles/travel-router/install.sh` (needs T2-T4) — apt hostapd/dnsmasq/nftables/iw
   BEFORE unmanaging wlan0; render-once; `restart dnsmasq`; enable+start units; PSK
   8-63 + charset validation; no bootfs writes for hotel creds.
5. **T6** `TRAVELROUTER_` wiring — add `TRAVELROUTER` to role.env regex
   `provision.sh:190` (mirror `provision-bookworm.sh`), var block + `ROLE` enum in
   `.env.example`. (Prior attempt timed out — retry.)
6. **T7** docs: README roles+env tables + usage/workflow, `INVENTORY.md` role row.
7. **T8** `assets/validate-local.sh` — full QA battery (bash -n, py_compile, render checks,
   seam asserts, provisioner filter, docs cross-check, `git diff --stat` scope guard).
8. **F1-F4** final wave: F1 plan-compliance, F2 code-quality, **F3 user-gated** hardware
   QA (you run flash/boot/portal), F4 scope fidelity.

## Commit policy
One commit per todo (feat/test/docs + `travel-router` scope). No commits to `.env`/
`inventory.yaml` (gitignored).

## Guardrails (do NOT repeat last-run mistake)
- **Do not context-bloat.** Write T2 in one pass: read spec lines 102-116, write the
  script, run acceptance checks (`bash -n` + grep seam asserts + dry-run fixture), stop.
- **No repeated retries on the same request.** One attempt per sub-step; on any anomaly
  (loop, bloat, tool failure) STOP and report.
- Run on local model `qwen3.8:27b-mlx`; weak-model discipline (one file at a time,
  build after edit).
