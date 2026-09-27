# S03 — Move /api/wan/known + /api/wan/scan to session-gated

## Goal
Move the remaining PIN-gated GET routes (`/api/wan/known`, `/api/wan/log`) and POST routes (`/api/wan/scan`, `/api/wan/status`, `/api/wan/connect`, `/api/wan/psks`, `/api/wan/disconnect`, `/api/wan/forget`, `/api/wan/recheck`) to session-gated. These routes expose sensitive data (known network names, scan results, full status) or perform state-changing operations that should require admin auth.

## Context
After S01 (public /api/status) and S02 (/status → session), the following routes are still PIN-gated:

**GET routes:**
- `/api/wan/known` — returns known network names (reveals travel history)
- `/api/wan/log` — returns DHCP log (MACs/IPs/hostnames) — already session-gated, verify

**POST routes:**
- `/api/wan/scan` — returns all nearby WiFi networks (reveals RF environment)
- `/api/wan/status` — returns full status (same as GET /status)
- `/api/wan/connect` — connects to WiFi (state-changing)
- `/api/wan/psks` — tries saved passwords (state-changing)
- `/api/wan/disconnect` — disconnects WAN (state-changing)
- `/api/wan/forget` — forgets network (state-changing)
- `/api/wan/recheck` — triggers wan-select (state-changing)

All of these should require a session (admin auth), not just the PIN.

The setup.html page uses these routes. After this change, setup.html will need to be updated to use session auth (or be merged into admin.html — see S04).

## Files touched
- `roles/travel-router/assets/status-server.py` — move routes from PIN to session gate
- `roles/travel-router/assets/setup.html` — update API calls to use session auth (or remove if merging into admin)
- `roles/travel-router/assets/validate-local.sh` — update tests for new auth posture

## Pre-conditions
- [x] S01 committed (public /api/status)
- [x] S02 committed (/status → session)
- [x] Suite GREEN

## Exact changes required

### Change 1: status-server.py — move /api/wan/known to session gate
File: `roles/travel-router/assets/status-server.py`
Action: MODIFY the `/api/wan/known` route in do_GET.

Before:
```python
elif path == "/api/wan/known":
    if not _require_pin_header(self):
        return
    # ... existing handler ...
```

After:
```python
elif path == "/api/wan/known":
    # Known networks reveal travel history — ADMIN-ONLY.
    if not _require_session(self):
        return
    # ... existing handler ...
```

### Change 2: status-server.py — move POST /api/wan/scan to session gate
File: `roles/travel-router/assets/status-server.py`
Action: MODIFY the `/api/wan/scan` route in do_POST.

Before:
```python
if path == "/api/wan/scan" or path == "/api/wan/status":
    # ... PIN throttle + _pin_gate ...
    if not _pin_gate(self, body.get("pin")):
        return
    # ... handler ...
```

After:
```python
if path == "/api/wan/scan" or path == "/api/wan/status":
    # Scan results + full status are ADMIN-ONLY — session required.
    if not _require_session(self):
        return
    # ... handler (no PIN check needed) ...
```

### Change 3: status-server.py — move POST /api/wan/connect, /api/wan/psks, /api/wan/disconnect, /api/wan/forget, /api/wan/recheck to session gate
File: `roles/travel-router/assets/status-server.py`
Action: MODIFY the client write verbs in do_POST.

These are currently in the "client bucket" (PIN suffices). Move them to require a session.

Before:
```python
# Client verbs: /api/wan/{connect,psks,disconnect,forget,recheck} —
# body.pin is the ONLY credential ("PIN suffices").
```

After:
```python
# Client verbs: /api/wan/{connect,psks,disconnect,forget,recheck} —
# now require a session (admin auth). The PIN alone is no longer sufficient.
```

For each of these routes, replace the PIN gate with a session check:
```python
if not _require_session(self):
    return
```

The PIN check (`_pin_ok(body)`) can be removed from these routes, or kept as a secondary check if desired (session + PIN). The user's intent is "all other ssid/ap config and settings should be only behind the admin interface" — so session alone should suffice.

### Change 4: setup.html — update or remove
File: `roles/travel-router/assets/setup.html`
Action: Either:
- (a) Update all API calls to use session auth (add X-Session header from localStorage "admin-session"), OR
- (b) Remove setup.html entirely and merge its functionality into admin.html

**Recommendation**: Option (b) — merge into admin.html. The setup page's functionality (scan, connect, forget, disconnect) is now admin-only. Having a separate page that requires admin auth is redundant. The admin page already has a "Connected clients" section; add "WiFi Networks" (scan + connect) and "Known networks" sections.

If option (a) is chosen:
- Add a login section to setup.html (or redirect to /admin for login)
- Store the session token in localStorage
- Add X-Session header to all API calls
- Keep the PIN for write operations (if session + PIN is desired)

### Change 5: validate-local.sh — update tests
File: `roles/travel-router/assets/validate-local.sh`
Action: UPDATE the §5d battery.

Changes:
- `/api/wan/known` without session → 401 (was: 200 with PIN)
- `/api/wan/known` with X-Pin but no session → 401 (PIN no longer works)
- `/api/wan/known` with X-Session → 200 (session accepted)
- `POST /api/wan/scan` without session → 401 (was: 200 with PIN)
- `POST /api/wan/scan` with X-Pin but no session → 401
- `POST /api/wan/scan` with X-Session → 200
- `POST /api/wan/connect` without session → 401 (was: 200 with PIN)
- `POST /api/wan/connect` with X-Session → 200
- Same for /api/wan/psks, /api/wan/disconnect, /api/wan/forget, /api/wan/recheck

## Validation plan
```bash
bash roles/travel-router/assets/validate-local.sh
# Expected: SUITE GREEN, updated auth asserts

python3 -m py_compile roles/travel-router/assets/status-server.py
# Expected: exit 0

# Manual smoke:
# TRAVELROUTER_SETUP_PIN=1234 TRAVELROUTER_ADMIN_PSK=admin TRAVELWAN_BIN=<stub> \
#   TRAVELROUTER_BIND_HOST=127.0.0.1 TRAVELROUTER_STATUS_PORT=18097 python3 status-server.py &
# curl -s -H 'X-Pin: 1234' http://127.0.0.1:18097/api/wan/known
#   -> 401 {"error":"auth"}  (PIN no longer works)
# curl -s -H 'X-Session: <token>' http://127.0.0.1:18097/api/wan/known
#   -> 200 {"known":[...]}
# curl -s -X POST -H 'X-Requested-With: XMLHttpRequest' -H 'X-Session: <token>' \
#   -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:18097/api/wan/scan
#   -> 200 {"lines":[...]}
```

## Success criteria
- [ ] `/api/wan/known` without session → 401 (no longer PIN-gated)
- [ ] `POST /api/wan/scan` without session → 401 (no longer PIN-gated)
- [ ] `POST /api/wan/connect` without session → 401 (no longer PIN-gated)
- [ ] All `/api/wan/*` client verbs require session, not PIN
- [ ] setup.html updated to use session auth (or removed if merging into admin)
- [ ] Suite GREEN with updated auth asserts

## Rollback
```bash
git checkout roles/travel-router/assets/status-server.py roles/travel-router/assets/setup.html roles/travel-router/assets/validate-local.sh
```

## Next task
S04 — Move /setup shell to session-gated (blocked by S03).
