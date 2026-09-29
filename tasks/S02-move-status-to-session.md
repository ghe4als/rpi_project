# S02 — Move /status from PIN-gated to session-gated

## Goal
Move the `/status` endpoint from PIN-gated (X-Pin header) to session-gated (X-Session token). The full status includes the client list (MACs/IPs/hostnames), WAN IP, and other sensitive data that should only be accessible to admin users, not PIN-holding guests.

## Context
Currently `/status` is PIN-gated and returns the full device state including:
- mode, lan_ip, wan_if, wan_ssid, wan_ip, internet, ap_state
- **clients_list** (MACs, IPs, hostnames of connected devices) — SENSITIVE
- clients_count, standalone

The PIN is a guest credential. The client list should only be visible to admin users (session holders). The new minimal status page (S01) uses the public `/api/status` endpoint instead, so `/status` can be locked down.

The admin page (`admin.html`) currently fetches `/status` with `X-Pin`. After this change, it should use `X-Session` instead (the admin already has a session from login).

## Files touched
- `roles/travel-router/assets/status-server.py` — move `/status` from PIN to session gate
- `roles/travel-router/assets/admin.html` — update `/status` calls to use X-Session
- `roles/travel-router/assets/validate-local.sh` — update tests for new auth posture

## Pre-conditions
- [x] S01 committed (public /api/status endpoint exists)
- [x] Suite GREEN

## Exact changes required

### Change 1: status-server.py — move /status to session gate
File: `roles/travel-router/assets/status-server.py`
Action: MODIFY the `/status` route in do_GET.

Before (current):
```python
elif path == "/status":
    if not _require_pin_header(self):
        return
    self._send(200, json.dumps(get_status()), "application/json")
```

After:
```python
elif path == "/status":
    # Full status (incl. client list) is ADMIN-ONLY — session required.
    # The public minimal status is GET /api/status (S01, no auth).
    if not _require_session(self):
        return
    self._send(200, json.dumps(get_status()), "application/json")
```

### Change 2: admin.html — use X-Session for /status
File: `roles/travel-router/assets/admin.html`
Action: MODIFY the `statusFetch()` function.

Before (current, line ~358):
```javascript
function statusFetch() {
  var pin = currentPin();
  if (!pin) { return Promise.resolve(null); }
  return fetch("/status", { cache: "no-store", headers: { "X-Pin": pin } })
    .then(function (r) {
      if (r.status === 401) { return null; }   // PIN required
      if (r.status === 403) { return null; }   // wrong PIN (throttled)
      return r.json();
    })
    .catch(function () { return null; });
}
```

After:
```javascript
function statusFetch() {
  // /status is ADMIN-ONLY (session-gated) — the admin page already has a
  // session token from login. The public minimal status is GET /api/status.
  return sessionFetch("/status", { cache: "no-store" })
    .then(function (r) {
      if (r.status === 401) { return null; }   // session required
      return r.json();
    })
    .catch(function () { return null; });
}
```

Note: `sessionFetch` already exists in admin.html and attaches the X-Session header. The admin page no longer needs the PIN for `/status` — it uses the session token. The PIN is still needed for admin WRITE operations (body.pin).

### Change 3: validate-local.sh — update tests
File: `roles/travel-router/assets/validate-local.sh`
Action: UPDATE the §5c/§5d batteries.

Changes:
- `/status` without X-Pin → 401 (was: 200 with PIN)
- `/status` with X-Pin but no session → 401 (PIN no longer works for /status)
- `/status` with X-Session → 200 (session is the correct credential)
- `/status` response contains `clients_list` (verify it's still returned to session holders)
- `/api/status` (new public endpoint) → 200 without any auth (S01 test)
- `/api/status` does NOT contain `clients_list` (verify sensitive data is not leaked)

## Validation plan
```bash
bash roles/travel-router/assets/validate-local.sh
# Expected: SUITE GREEN, updated auth asserts

python3 -m py_compile roles/travel-router/assets/status-server.py
# Expected: exit 0

# Manual smoke:
# TRAVELROUTER_SETUP_PIN=1234 TRAVELROUTER_ADMIN_PSK=admin TRAVELWAN_BIN=<stub> \
#   TRAVELROUTER_BIND_HOST=127.0.0.1 TRAVELROUTER_STATUS_PORT=18096 python3 status-server.py &
# curl -s -H 'X-Pin: 1234' http://127.0.0.1:18096/status
#   -> 401 {"error":"auth"}  (PIN no longer works)
# curl -s -H 'X-Session: <token>' http://127.0.0.1:18096/status
#   -> 200 {"mode":"...","clients_list":[...],...}
# curl -s http://127.0.0.1:18096/api/status
#   -> 200 {"ap_ssid":"...","wan_ssid":"...","internet":"..."}
```

## Success criteria
- [x] `/status` without session → 401 (no longer PIN-gated)
- [x] `/status` with X-Pin but no session → 401 (PIN rejected)
- [x] `/status` with X-Session → 200 (session accepted)
- [x] `/status` response still contains `clients_list` for session holders
- [x] `/api/status` (public) → 200 without auth, no `clients_list`
- [x] admin.html uses `sessionFetch` for `/status` (X-Session, not X-Pin)
- [x] Suite GREEN with updated auth asserts

## Rollback
```bash
git checkout roles/travel-router/assets/status-server.py roles/travel-router/assets/admin.html roles/travel-router/assets/validate-local.sh
```

## Next task
S03 — Move /api/wan/known + /api/wan/scan to session-gated (blocked by S02).
