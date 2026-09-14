# H02 — /setup phone UI (setup.html asset) + fix `/` innerHTML XSS

## Goal
A mobile-first setup page served at `http://<lan_ip>/setup`: current WAN
status, scan list, SSID/PSK form, PIN entry — rendered with textContent only,
no framework, works in the iOS/Android captive-portal webview. The existing
status page's innerHTML XSS (known residual) is fixed in the same commit.

## Context
Metis slicing task 2. The UI is the "easily set up by phone" half of the
feature; the API half landed in H01. Strategy decision (Metis §4.3, user
confirmed implicitly by approving the plan route): separate `setup.html`
asset read from the install dir — keeps status-server.py readable, avoids the
`__PLACEHOLDER__` grep trap in inlined JS (validate-local placeholder check
scans status-server.py literally). Asset is installed to
`/usr/local/lib/travel-router/` next to status-server.py by install.sh.

## Files touched
- `roles/travel-router/assets/setup.html` — NEW: the UI
- `roles/travel-router/assets/status-server.py` — serve /setup, fix `/` XSS
- `roles/travel-router/assets/validate-local.sh` — UI asserts (§5d extension)

## Pre-conditions
- [x] H01 committed; suite GREEN; POST /api/wan/* behavior available (PIN
      denies by default until H05 — the UI must render a clear "PIN not
      configured / access denied" state for the 403 `{"error":"pin"}` body)

## Exact changes required

### Change 1: NEW setup.html
File: `roles/travel-router/assets/setup.html`
Action: CREATE. Single mobile-first page, vanilla JS, stdlib-served:

- `<meta name="viewport" content="width=device-width, initial-scale=1">`,
  dark-friendly system-ui styling, ~200 lines max. NO framework, NO CDN
  assets (device may be offline by design — that is the whole point).
- Sections, all rendered via `document.createElement` + `textContent`
  (FORBIDDEN in this file: `innerHTML`, `insertAdjacentHTML`, `document.write`):
  1. Status card: polls `/status` every 4s (existing endpoint) — mode,
     hotel SSID, WAN IP, internet state; during `internet:"reachable"` shows
     "Connected to <HotelSSID> — finish the hotel's login page from this
     device" (portal phase messaging, Metis R2).
  2. Scan card: button -> POST `/api/wan/scan` -> rows from `lines[]` via
     textContent (raw nmcli terse lines are fine for display).
  3. Connect form: SSID text input (or pre-filled from a tapped scan row),
     PSK password input (optional, label "leave empty for open networks"),
     PIN input stored to `localStorage["setup-pin"]` after first successful
     call; every write request sends `{"pin": ..., "ssid": ..., "psk": ...}`
     with headers `Content-Type: application/json` +
     `X-Requested-With: XMLHttpRequest` (H01 contract).
  4. Disconnect + Forget buttons (forget takes the SSID from the form).
  5. 403 `{"error":"pin"}` -> show "PIN required — ask the router owner"
     (deny-by-default state is first-class UI, not an error dump).
  6. PSKs never displayed anywhere; password inputs use `type=password`.
- Keep-alive-safe: fetch with `cache: "no-store"` like the existing page.
- Comment at top of the file states the textContent-only rule (greppable).

### Change 2: status-server.py serves /setup + XSS fix on `/`
File: `roles/travel-router/assets/status-server.py`
Action: MODIFY do_GET + `_STATUS_HTML` script block.

- do_GET: `/setup` (and `/setup/index.html`) -> serve
  `os.path.join(os.path.dirname(os.path.abspath(__file__)), "setup.html")`
  with `text/html; charset=utf-8`; file missing -> 500 with a log line
  (install bug, not a client error). Cache header: `no-store` (state changes
  as WAN toggles).
- XSS fix (status-server.py lines 159-161): the rows build in the `/` page's
  `refresh()` uses `.innerHTML = rows.map(...)` with `d.wan_ssid` (hotel
  SSID = attacker-controlled). REPLACE with DOM construction: create cells
  via `document.createElement("td")` + `textContent`. Same data, no HTML
  injection path. Update the `_STATUS_HTML` copy: "There are no web forms on
  this page" -> "Configure at /setup (PIN required)." (H01 made the
  docstring truthful; the page copy becomes truthful here.)

### Change 3: install.sh installs the new asset
File: `roles/travel-router/install.sh`
Action: EXTEND the existing asset-copy loop.
- The loop that stages `status-server.py` to
  `/usr/local/lib/travel-router/` must also stage `setup.html` (same
  install-site, same permissions as status-server.py: 0644). No other
  install.sh change — hostapd/dnsmasq/sysctl ownership untouched.

### Change 4: validate-local.sh UI asserts
File: `roles/travel-router/assets/validate-local.sh`
Action: EXTEND §5d.
- GET /setup -> 200 and body contains `id="scan"` (structural marker);
  GET / -> 200.
- XSS regression: `python3` heredoc asserts `setup.html` contains NO
  `innerHTML`/`insertAdjacentHTML`/`document.write` AND status-server.py's
  `_STATUS_HTML` block contains no `.innerHTML` assignment
  (assert `".innerHTML =" not in src`).
- install.sh dry-run battery: staged tree contains setup.html at
  `$pfx/usr/local/lib/travel-router/setup.html` (existing battery pattern).

## Validation plan
    bash roles/travel-router/assets/validate-local.sh
    # Expected: SUITE GREEN, +3 new asserts over H01 count

    python3 -m py_compile roles/travel-router/assets/status-server.py
    # Expected: exit 0

    # Serve check (suite does this): GET /setup -> 200 text/html

## Success criteria
- [ ] /setup served from install dir, no-store; / no longer XSSes via wan_ssid
- [ ] No innerHTML anywhere in the two HTML-producing code paths
- [ ] UI makes zero external network requests (works offline)
- [ ] git diff scoped to the three touched assets + validate-local.sh

## Rollback
    git checkout roles/travel-router/assets/setup.html roles/travel-router/assets/status-server.py roles/travel-router/assets/validate-local.sh roles/travel-router/install.sh

## Next task
H03 — captive-portal dnsmasq drop-in + wan-select toggle (blocked by H02).