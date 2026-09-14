# H03 — Captive-portal dnsmasq drop-in + wan-select toggle (standalone-keyed)

## Goal
When the Pi has NO WAN (`wan_if == ""`, standalone), phones joining the
travel SSID auto-open the setup page: a dnsmasq drop-in answers OS
connectivity-probe domains with the Pi, and the phone's "captive portal"
popup lands on our /setup. When a WAN exists (portal phase or online), the
drop-in is removed so probes pass through — the documented hotel-portal
login flow keeps working unchanged.

## Context
Metis R2/R3 and hidden-req 7/8. state.json carries `wan_if` (wan-select
writes it every 30s tick); it has NO internet field — keying the hijack on
"internet" is impossible without adding a state key AND would hijack the
phone's probe during the associated-but-unauthenticated phase, stealing it
from the hotel portal. Standalone-keying: hijack only when there is no WAN
at all (popup -> our /setup is pure win there), otherwise pass probes
through. This is the deliberate, per-file single-owner exception to the
"install.sh owns dnsmasq rendering / wan-select never touches dnsmasq" rule:
wan-select solely owns `/etc/dnsmasq.d/travel-router-portal.conf` (install.sh
NEVER renders it), toggles only on content change, and restarts dnsmasq —
documented in BOTH scripts' headers. dnsmasq does NOT re-read dnsmasq.d
drop-ins on SIGHUP (SIGHUP re-reads hosts files); add/remove requires
`systemctl restart dnsmasq` — restart-on-content-change only, never per-tick.

## Files touched
- `roles/travel-router/assets/portal-dnsmasq.conf.tmpl` — NEW template
- `roles/travel-router/assets/wan-select.sh` — toggle logic + header exception
- `roles/travel-router/install.sh` — stage the template, header exception
- `roles/travel-router/assets/validate-local.sh` — §5e toggle battery

## Pre-conditions
- [x] H02 committed; suite GREEN
- [x] wan-select.sh §(4) render + §(5) state.json write read; existing seams
      (TRAVELROUTER_DRY_RUN, run_or_log, SYSTEMCTL stub pattern in §5b) known

## Exact changes required

### Change 1: NEW portal-dnsmasq.conf.tmpl
File: `roles/travel-router/assets/portal-dnsmasq.conf.tmpl`
Action: CREATE. Rendered by wan-select at runtime (template lives in the
ASSETS dir = /usr/local/lib/travel-router/ on the Pi; the validate-local
placeholder check scans only $pfx/etc + status-server.py + $pfx/usr/local/bin,
so a runtime template here is NOT flagged — verified):

    # Captive-portal hijack (travel-router). OWNED by wan-select.sh —
    # written/removed per tick ONLY on content change; standalone mode only.
    local-ttl=10
    address=/captive.apple.com/__LAN_IP__
    address=/connectivitycheck.gstatic.com/__LAN_IP__
    address=/www.google.com/__LAN_IP__            # Android fallback probe host
    address=/www.msftncsi.com/__LAN_IP__
    address=/detectportal.firefox.com/__LAN_IP__
    address=/nmcheck.gnome.org/__LAN_IP__
    # Android DNS-value probe: answer the EXPECTED value, never the Pi IP
    # (a wrong value here flags "no internet" persistently on some Androids).
    address=/dns.msftncsi.com/131.107.255.255

NOTE: `local-ttl=10` keeps stale hijack answers out of phone DNS caches for
more than ~10s so the "no internet" badge clears quickly after removal
(hidden-req 8). `www.google.com` is Android's fallback HTTP probe host —
pointing it at the Pi is safe ONLY because the drop-in exists solely in
standalone mode (no real internet to lose). Keep that pairing explicit in
the comment.

### Change 2: wan-select.sh — toggle in §(5), header exception
File: `roles/travel-router/assets/wan-select.sh`
Action: INSERT a new step between §(5) state write and the try-restart block;
UPDATE the header comment.

- Header (lines 19-22) gains: EXCEPTION — wan-select owns exactly one dnsmasq
  runtime file, `/etc/dnsmasq.d/travel-router-portal.conf` (captive-portal
  probe hijack, standalone mode only, H03); install.sh never renders it;
  dnsmasq is restarted ONLY when that file's existence toggles (never
  SIGHUP — dnsmasq does not re-read drop-ins on HUP).
- New seams: `DNSMASQ_CONF_DIR="${DNSMASQ_CONF_DIR:-/etc/dnsmasq.d}"`,
  `PORTAL_TMPL` = `$ASSETS/portal-dnsmasq.conf.tmpl` (ASSETS derivation
  already exists), `SYSTEMCTL="${SYSTEMCTL:-systemctl}"` seam.
- Logic (idempotent, both branches respect TRAVELROUTER_DRY_RUN=1 as log-only):
  - LAN_IP is already computed for state.json (§5) — render target:
    `sed -e "s|__LAN_IP__|${LAN_IP}|g" "$ASSETS/portal-dnsmasq.conf.tmpl"`
  - standalone (`WAN_IF == ""`): if the rendered content differs from the
    existing file (or file absent), write atomically (tmp in same dir + mv)
    and `run_or_log "$SYSTEMCTL" restart dnsmasq.service` ONCE; log the
    toggle. Content-identical -> no restart (no 30s churn).
  - routed (`WAN_IF != ""`): if the file exists, remove it and restart
    dnsmasq ONCE; absent -> no-op.
  - Never touches install.sh's `/etc/dnsmasq.d/travel-router.conf`.
- Ordering inside the script: AFTER state.json write, BEFORE the lan_ip
  try-restart block (a lan_ip change already restarts the status server;
  portal toggle is orthogonal).

### Change 3: install.sh stages the template + header exception
File: `roles/travel-router/install.sh`
Action: EXTEND asset staging.
- Copy `portal-dnsmasq.conf.tmpl` to `/usr/local/lib/travel-router/` beside
  wan-select.sh (same loop as wan-select.sh itself, 0644).
- Header comment of install.sh gains one line: the H03 exception (wan-select
  owns the portal drop-in + dnsmasq restart-on-toggle; install.sh never
  renders it).

### Change 4: validate-local.sh §5e toggle battery
File: `roles/travel-router/assets/validate-local.sh`
Action: APPEND after §5d (reuse §5b rig `$B`: fake sysfs, `$B/bin/*` stubs,
run_wan helper; the systemctl stub already logs argv to calls.log).
- `DNSMASQ_CONF_DIR="$B/dnsmasq.d"` added to run_wan's env (mkdir first).
- T1: standalone run (WAN_PREFER=none) -> drop-in exists at
  `$B/dnsmasq.d/travel-router-portal.conf`, contains `address=/captive.apple.com/192.168.50.1`,
  contains `address=/dns.msftncsi.com/131.107.255.255`, does NOT contain
  `__LAN_IP__`, calls.log has exactly one `systemctl restart dnsmasq.service`.
- T2: re-run standalone (state file reused) -> calls.log has NO new restart
  (content-identical -> no churn; count restarts across both runs == 1).
- T3: routed run (WAN_PREFER=ethernet) -> drop-in file ABSENT, calls.log has
  exactly one restart (the removal), and
  `$B/dnsmasq.d/travel-router.conf` (install.sh's file) untouched in a
  fixture where it pre-exists (assert still present).
- T4: dry-run standalone -> no drop-in written, no restart logged
  (existing DRY_RUN discipline).

## Validation plan
    bash roles/travel-router/assets/validate-local.sh
    # Expected: SUITE GREEN, +4 asserts over H02 count

    bash -n roles/travel-router/assets/wan-select.sh
    # Expected: exit 0

    # Render sanity on the runner:
    sed -e "s|__LAN_IP__|192.168.50.1|g" roles/travel-router/assets/portal-dnsmasq.conf.tmpl | grep -c 'address='
    # Expected: 7

## Success criteria
- [ ] Suite GREEN incl. T1–T4; no dnsmasq churn on unchanged ticks
- [ ] wan-select still never restarts NetworkManager (§5 assert stays green)
- [ ] Header exception documented in both wan-select.sh and install.sh
- [ ] git diff scoped to the four touched files

## Rollback
    git checkout roles/travel-router/assets/portal-dnsmasq.conf.tmpl roles/travel-router/assets/wan-select.sh roles/travel-router/install.sh roles/travel-router/assets/validate-local.sh

## Next task
H04 — probe-Host 302 redirect handler (blocked by H03).