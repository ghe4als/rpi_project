# S01 — Public /api/status endpoint + minimal status page

## Goal
Create a new unauthenticated `GET /api/status` endpoint returning only non-sensitive data (AP SSID, WAN SSID, internet status), and replace the current `/` static warning page with a minimal status page that fetches from it. This is the foundation for moving all sensitive data behind admin auth.

## Context
The current `/` page is a static "Private travel network" warning (security through obscurity). The user wants a useful minimal status page showing: travel AP SSID, WAN SSID (what network it's connected to), internet status, and helpful links (Cloudflare speed test, etc.). This page must be accessible WITHOUT any auth — it's the only public surface.

The captive portal redirect (probe hosts → 302 to `/setup`) must be preserved and continue to work.

## Files touched
- `roles/travel-router/assets/status-server.py` — add `GET /api/status`, replace `/` warning page
- `roles/travel-router/assets/status-server.py` — add minimal status page HTML (or new asset file)
- `roles/travel-router/assets/validate-local.sh` — add tests for new endpoint + page

## Pre-conditions
- [x] Suite GREEN at HEAD (581 passed / 0 failed)
- [x] status-server.py structure understood (do_GET dispatch, _send, _state_field, captive portal redirect)

## Exact changes required

### Change 1: status-server.py — add GET /api/status (no auth)
File: `roles/travel-router/assets/status-server.py`
Action: INSERT a new route in do_GET, BEFORE the captive portal check (or after — it's unauthenticated so order doesn't matter for security, but logically it fits with the other public routes).

New route:
```python
elif path == "/api/status":
    # Public minimal status — NO auth. Returns only non-sensitive data:
    # AP SSID, WAN SSID, internet status. No client list, no WAN IP, no
    # known networks, no scan results.
    state_mode = _state_field("mode") or "standalone"
    wan_ssid = _state_field("wan_ssid") or ""
    # AP SSID: prefer the live ap-ssid file (updated by ap-apply), fall back
    # to the state file's ap_interface lookup
    ap_ssid = ""
    ap_ssid_file = "/etc/rpi-project/travel-router/ap-ssid"
    if os.path.isfile(ap_ssid_file):
        try:
            with open(ap_ssid_file, "r") as fh:
                ap_ssid = fh.read().strip()
        except OSError:
            pass
    if not ap_ssid:
        ap_ssid = _state_field("ap_ssid") or ""
    # Internet status: reuse the cached get_status() logic but only extract
    # the internet field (don't expose the full payload)
    internet = "unknown"
    try:
        full = get_status()
        internet = full.get("internet", "unknown")
    except Exception:
        pass
    self._send(200, json.dumps({
        "ap_ssid": ap_ssid,
        "wan_ssid": wan_ssid,
        "internet": internet,
    }), "application/json")
```

### Change 2: status-server.py — replace / warning page with minimal status page
File: `roles/travel-router/assets/status-server.py`
Action: REPLACE the `_WARNING_HTML` block and the `/` route handler.

The new `/` page should be a minimal HTML page that:
- Fetches `/api/status` via JavaScript
- Displays: Travel AP SSID, WAN SSID (or "standalone"), Internet status
- Shows helpful links:
  - Cloudflare speed test: `https://speed.cloudflare.com`
  - DNS leak test: `https://www.dnsleaktest.com`
  - 1.1.1.1: `https://1.1.1.1`
- Uses textContent-only DOM construction (same rule as setup.html/admin.html)
- Mobile-first, dark-friendly, system-ui styling (match setup.html/admin.html style)
- No external requests (works offline — the device may be standalone)
- Cache-Control: no-store

Replace the current:
```python
elif path == "/" or path == "/index.html":
    self._send(200, _WARNING_HTML, "text/html")
```

With a new `_STATUS_HTML` block that includes inline JavaScript to fetch `/api/status` and render the data.

### Change 3: validate-local.sh — add tests for new endpoint + page
File: `roles/travel-router/assets/validate-local.sh`
Action: APPEND a new section (§5p) after the existing batteries.

New tests:
- `GET /api/status` (no auth) → 200, JSON parses, has `ap_ssid`, `wan_ssid`, `internet` fields
- `GET /api/status` does NOT contain `clients`, `wan_ip`, `lan_ip`, `mode`, `standalone` fields (sensitive data not leaked)
- `GET /` → 200, body contains `id="ap-ssid"` (or similar structural marker)
- `GET /` does NOT contain `innerHTML`, `insertAdjacentHTML`, `document.write` (XSS rule)
- Captive portal redirect still works: probe Host → 302 to `/setup` (existing test should still pass)
- The new `/` page fetches `/api/status` (assert the fetch URL appears in the HTML)

## Validation plan
```bash
bash roles/travel-router/assets/validate-local.sh
# Expected: SUITE GREEN, PASS count >= 581 + ~6 new §5p asserts

python3 -m py_compile roles/travel-router/assets/status-server.py
# Expected: exit 0

# Manual smoke:
# TRAVELROUTER_BIND_HOST=127.0.0.1 TRAVELROUTER_STATUS_PORT=18095 python3 status-server.py &
# curl -s http://127.0.0.1:18095/api/status
#   -> {"ap_ssid":"...","wan_ssid":"...","internet":"..."}
# curl -s http://127.0.0.1:18095/
#   -> HTML with ap-ssid, wan-ssid, internet elements + links
```

## Success criteria
- [x] `GET /api/status` returns 200 with `{ap_ssid, wan_ssid, internet}` (no auth)
- [x] `GET /api/status` does NOT return clients, wan_ip, lan_ip, mode, standalone
- [x] `GET /` serves a minimal status page (no auth)
- [x] The minimal status page shows AP SSID, WAN SSID, internet status, helpful links
- [x] The minimal status page uses textContent-only (no innerHTML/insertAdjacentHTML/document.write)
- [x] Captive portal redirect still works (probe hosts → 302)
- [x] No external network requests from the minimal page
- [x] Suite GREEN with new §5p asserts

## Rollback
```bash
git checkout roles/travel-router/assets/status-server.py roles/travel-router/assets/validate-local.sh
```

## Next task
S02 — Move /status from PIN-gated to session-gated (blocked by S01).
