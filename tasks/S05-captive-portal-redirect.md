# S05 — Update captive portal redirect target

## Goal
Update the captive portal redirect to point to the new public minimal status page (`/`) instead of `/setup` (which is now admin-gated or removed).

## Context
The captive portal redirect currently sends probe requests (captive.apple.com, connectivitycheck.gstatic.com, etc.) to `/setup`. After S04, `/setup` is either:
- (a) Session-gated (401 without session), OR
- (b) Removed (404)

Neither is a good captive portal target — the user's phone OS expects a 200 response with a page that can be displayed. A 401 or 404 will cause the captive portal popup to fail or show an error.

The new public minimal status page (`/`) is the correct captive portal target:
- It's accessible without auth
- It shows useful info (AP SSID, WAN SSID, internet status)
- It has helpful links (speed test, etc.)
- It's designed to work in a mobile browser

## Files touched
- `roles/travel-router/assets/status-server.py` — update redirect target
- `roles/travel-router/assets/validate-local.sh` — update tests

## Pre-conditions
- [x] S01 committed (public /api/status + minimal status page at /)
- [x] S04 committed (/setup → session or removed)
- [x] Suite GREEN

## Exact changes required

### Change 1: status-server.py — update redirect target
File: `roles/travel-router/assets/status-server.py`
Action: MODIFY the `_portal_redirect` method.

Before:
```python
def _portal_redirect(self):
    """302 a connectivity-probe request to /setup. Target is the numeric
    LAN IP (captive webviews cannot rely on mDNS); the port is included
    whenever it is not 80, using the actually-bound port."""
    host = _state_field("lan_ip") or DEFAULT_HOST
    port = self.server.server_address[1]
    if port != 80:
        host = "%s:%d" % (host, port)
    self.send_response(302)
    self.send_header("Location", "http://%s/setup" % host)
    self.send_header("Content-Length", "0")
    self.send_header("Cache-Control", "no-store")
    self.end_headers()
```

After:
```python
def _portal_redirect(self):
    """302 a connectivity-probe request to the public minimal status page.
    Target is the numeric LAN IP (captive webviews cannot rely on mDNS);
    the port is included whenever it is not 80, using the actually-bound
    port. The minimal status page (S01) is the correct captive portal
    target — it's public, shows useful info, and works in a mobile browser.
    /setup is now admin-gated (S04) and would return 401."""
    host = _state_field("lan_ip") or DEFAULT_HOST
    port = self.server.server_address[1]
    if port != 80:
        host = "%s:%d" % (host, port)
    self.send_response(302)
    self.send_header("Location", "http://%s/" % host)
    self.send_header("Content-Length", "0")
    self.send_header("Cache-Control", "no-store")
    self.end_headers()
```

### Change 2: validate-local.sh — update tests
File: `roles/travel-router/assets/validate-local.sh`
Action: UPDATE the §5f battery.

Before:
```python
# R1: probe Host + active drop-in -> 302 to /setup on the same bound port
r=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: captive.apple.com' http://127.0.0.1:18091/generate_204 2>/dev/null)
loc=$(curl -s -o /dev/null -w '%{redirect_url}' -H 'Host: captive.apple.com' http://127.0.0.1:18091/generate_204 2>/dev/null)
[[ "$r" == "302" ]] && ok "R1 probe-Host GET -> 302" || bad "R1 code=$r"
[[ "$loc" == "http://127.0.0.1:18091/setup" ]] && ok "R1 Location -> /setup" || bad "R1 location=$loc"
```

After:
```python
# R1: probe Host + active drop-in -> 302 to / (public minimal status page)
r=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: captive.apple.com' http://127.0.0.1:18091/generate_204 2>/dev/null)
loc=$(curl -s -o /dev/null -w '%{redirect_url}' -H 'Host: captive.apple.com' http://127.0.0.1:18091/generate_204 2>/dev/null)
[[ "$r" == "302" ]] && ok "R1 probe-Host GET -> 302" || bad "R1 code=$r"
[[ "$loc" == "http://127.0.0.1:18091/" ]] && ok "R1 Location -> / (public status page)" || bad "R1 location=$loc"
```

Also update R4 (port-suffixed probe Host):
```python
# R4: port-suffixed probe Host still redirects
r=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: captive.apple.com:18091' http://127.0.0.1:18091/generate_204 2>/dev/null)
[[ "$r" == "302" ]] && ok "R4 Host with :port still 302" || bad "R4 code=$r"
```

## Validation plan
```bash
bash roles/travel-router/assets/validate-local.sh
# Expected: SUITE GREEN, updated redirect asserts

python3 -m py_compile roles/travel-router/assets/status-server.py
# Expected: exit 0

# Manual smoke:
# TRAVELROUTER_SETUP_PIN=1234 TRAVELROUTER_ADMIN_PSK=admin TRAVELWAN_BIN=<stub> \
#   TRAVELROUTER_BIND_HOST=127.0.0.1 TRAVELROUTER_STATUS_PORT=18099 \
#   TRAVELROUTER_PORTAL_CONF=<active-conf> python3 status-server.py &
# curl -s -o /dev/null -w '%{redirect_url}' -H 'Host: captive.apple.com' \
#   http://127.0.0.1:18099/generate_204
#   -> http://127.0.0.1:18099/
```

## Success criteria
- [x] Captive portal redirect goes to `/` (not `/setup`)
- [x] Redirect target is the public minimal status page (200, no auth)
- [x] Port-suffixed probe Host still redirects
- [x] Suite GREEN with updated redirect asserts

## Rollback
```bash
git checkout roles/travel-router/assets/status-server.py roles/travel-router/assets/validate-local.sh
```

## Next task
S06 — Decide PIN fate + final cleanup (blocked by S05).
