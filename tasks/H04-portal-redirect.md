# H04 — Probe-Host 302 redirect handler in status-server.py

## Goal
While the H03 drop-in is active (standalone), any plain-HTTP GET whose Host
is an OS connectivity-probe domain gets `302 -> http://<lan_ip>[:port]/setup`
so the phone's captive-portal detection opens the setup page automatically.
Never fake probe success; redirect only when the hijack is actually active.

## Context
Metis slicing task 4; inert without H03. The redirect target is the NUMERIC
LAN IP (never .local — captive webviews are unreliable with mDNS), with the
port honored when TRAVELROUTER_STATUS_PORT != 80 (hidden-req 9). Probe
requests arrive at this server only when DNS pointed them here, i.e. only
while the drop-in exists — but phone DNS caches can outlive the drop-in, so
the handler re-checks drop-in presence per request (cheap stat()) and serves
the normal status page when inactive.

## Files touched
- `roles/travel-router/assets/status-server.py` — Host-based 302 in do_GET
- `roles/travel-router/assets/validate-local.sh` — §5f redirect asserts

## Pre-conditions
- [x] H03 committed; suite GREEN; drop-in path constant shared or duplicated
      consistently (`/etc/dnsmasq.d/travel-router-portal.conf`)

## Exact changes required

### Change 1: status-server.py — probe-Host redirect
File: `roles/travel-router/assets/status-server.py`
Action: EXTEND do_GET (before the existing route dispatch).

- Constant: `PORTAL_CONF = "/etc/dnsmasq.d/travel-router-portal.conf"`
  (overridable via `TRAVELROUTER_PORTAL_CONF` env seam for tests).
- Probe-Host set (mirror H03's template exactly):
  captive.apple.com, connectivitycheck.gstatic.com, www.google.com,
  www.msftncsi.com, detectportal.firefox.com, nmcheck.gnome.org.
  (dns.msftncsi.com is a DNS-value probe — NEVER in this HTTP set.)
- In do_GET: read the `Host` header, strip `:port`; if host is in the set
  AND `os.path.exists(PORTAL_CONF)` -> 302 to
  `http://<lan_ip><:port>/setup` where lan_ip = `_state_field("lan_ip")`
  falling back to DEFAULT_HOST, and port = the server's actual bound port
  when != 80 (port is available on the handler via `self.server.
  server_address[1]` — use that, not the env re-parse, so a redirected
  client always lands on the listening socket).
- Inactive-hijack edge (stale phone DNS cache, drop-in gone): fall through
  to normal routing — `/` serves the status page, other paths 404. NEVER
  return a fabricated `204`/`Success` body for probe paths (the phone would
  believe internet is up when it is not — Metis R8).
- Redirect response: `Location` header + empty body, `Cache-Control: no-store`.

### Change 2: validate-local.sh §5f
File: `roles/travel-router/assets/validate-local.sh`
Action: APPEND after §5d battery (reuse the §5c server fixture:
`$B/srv-state.json` with lan_ip=127.0.0.1, port 18080/18082).

- R1: `TRAVELROUTER_PORTAL_CONF=<existing file>` + GET
  `http://127.0.0.1:18080/generate_204` with `Host: captive.apple.com` ->
  302 and `Location` header == `http://127.0.0.1:18080/setup`.
- R2: same Host but `TRAVELROUTER_PORTAL_CONF=/nonexistent` -> NOT 302
  (falls through: `/generate_204` -> 404).
- R3: `Host: 127.0.0.1` (normal browsing) + active drop-in -> normal 200
  status page (no redirect — IP-hosted requests are the real UI).
- R4: `Host: captive.apple.com:18080` (port-suffixed Host) -> still 302
  (Host parsing strips the port).

## Validation plan
    bash roles/travel-router/assets/validate-local.sh
    # Expected: SUITE GREEN, +4 asserts over H03 count

    python3 -m py_compile roles/travel-router/assets/status-server.py
    # Expected: exit 0

## Success criteria
- [ ] 302 only when probe-Host AND drop-in active; never fakes probe success
- [ ] Redirect target carries the bound port when != 80
- [ ] POST /status still 404 (no regression)
- [ ] git diff scoped to the two touched files

## Rollback
    git checkout roles/travel-router/assets/status-server.py roles/travel-router/assets/validate-local.sh

## Next task
H05 — mandatory PIN staging (blocked by H04).