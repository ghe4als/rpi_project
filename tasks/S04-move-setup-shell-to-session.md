# S04 — Move /setup shell to session-gated

## Goal
Move the `/setup` HTML shell from unauthenticated to session-gated. After S01-S03, all the API calls on the setup page require a session. The shell itself should also require a session — there's no reason to serve the HTML to unauthenticated users if all the APIs reject them.

## Context
After S01-S03:
- `/` → public minimal status page (no auth) — S01
- `/status` → session-gated — S02
- `/api/wan/known` → session-gated — S03
- `/api/wan/scan` → session-gated — S03
- All `/api/wan/*` POST verbs → session-gated — S03
- `/admin` → session-gated (already was)

The `/setup` shell currently loads without auth. After S03, all its API calls require a session, so serving the shell to unauthenticated users is pointless — they can't do anything with it.

**Decision point**: Should `/setup` be:
- (a) Kept as a separate page but session-gated, OR
- (b) Merged into `/admin` (the admin page already has most of the functionality)

**Recommendation**: Option (b) — merge into `/admin`. The setup page's unique functionality is:
- Scan + connect to WiFi networks
- Known networks list
- Manual connect form
- Disconnect/forget buttons

The admin page already has:
- Connected clients
- Blocked devices
- Kill switch, DNS hardening, audit, sessions, SSH lockdown, stealth
- Saved passwords management
- AP settings

Adding "WiFi Networks" (scan + connect) and "Known networks" sections to the admin page would make `/setup` redundant. This simplifies the surface area and reduces code duplication.

If option (a) is chosen:
- Add session check to `/setup` route in do_GET
- The setup page would need a login mechanism (or redirect to /admin for login)

## Files touched
- `roles/travel-router/assets/status-server.py` — add session check to `/setup` route (if keeping) or remove route (if merging)
- `roles/travel-router/assets/admin.html` — add WiFi Networks + Known networks sections (if merging)
- `roles/travel-router/assets/setup.html` — remove (if merging) or add session check (if keeping)
- `roles/travel-router/install.sh` — remove setup.html install (if merging)
- `roles/travel-router/assets/validate-local.sh` — update tests

## Pre-conditions
- [x] S01 committed (public /api/status)
- [x] S02 committed (/status → session)
- [x] S03 committed (/api/wan/* → session)
- [x] Suite GREEN

## Exact changes required

### Option A: Merge /setup into /admin (RECOMMENDED)

#### Change 1: status-server.py — remove /setup route
File: `roles/travel-router/assets/status-server.py`
Action: REMOVE the `/setup` route from do_GET.

Before:
```python
elif path == "/setup" or path == "/setup/":
    self._serve_page(SETUP_PAGE, "setup")
```

After: Remove this route. The `/setup` path will fall through to 404.

#### Change 2: admin.html — add WiFi Networks + Known networks sections
File: `roles/travel-router/assets/admin.html`
Action: ADD two new sections to the admin page.

New "WiFi Networks" section:
- Scan button → POST /api/wan/scan (session auth)
- Results table: SSID, signal, security, Connect button
- Connect dialog: PSK entry + Connect + Try saved passwords
- Disconnect button → POST /api/wan/disconnect

New "Known networks" section:
- List from GET /api/wan/known (session auth)
- Each row: name, timestamp, autoconnect badge, Connect button, Forget button

These sections reuse the existing `api()` and `sessionFetch()` functions in admin.html. The scan/connect logic is similar to what's in setup.html but adapted for the admin page's session-based idiom.

#### Change 3: install.sh — remove setup.html install
File: `roles/travel-router/install.sh`
Action: REMOVE the setup.html install line.

Before:
```bash
install -m 0644 "$ASSETS/setup.html" /usr/local/lib/travel-router/setup.html
```

After: Remove this line. Also remove from the dry-run cp block.

#### Change 4: validate-local.sh — update tests
File: `roles/travel-router/assets/validate-local.sh`
Action: UPDATE tests.

- `GET /setup` → 404 (route removed)
- `GET /admin` → 200 (still works)
- Admin page contains "WiFi Networks" section (structural assert)
- Admin page contains "Known networks" section (structural assert)
- Remove setup.html-specific tests (XSS asserts for setup.html, etc.)
- Add tests for the new admin page sections

### Option B: Keep /setup as session-gated page

#### Change 1: status-server.py — add session check to /setup
File: `roles/travel-router/assets/status-server.py`
Action: MODIFY the `/setup` route in do_GET.

Before:
```python
elif path == "/setup" or path == "/setup/":
    self._serve_page(SETUP_PAGE, "setup")
```

After:
```python
elif path == "/setup" or path == "/setup/":
    # Setup page is now ADMIN-ONLY (all its APIs require a session).
    if not _require_session(self):
        return
    self._serve_page(SETUP_PAGE, "setup")
```

#### Change 2: setup.html — add login mechanism
File: `roles/travel-router/assets/setup.html`
Action: Add a login section (or redirect to /admin for login).

The setup page would need to:
- Show a login prompt if no session exists
- Store the session token in localStorage
- Add X-Session header to all API calls

#### Change 3: validate-local.sh — update tests
File: `roles/travel-router/assets/validate-local.sh`
Action: UPDATE tests.

- `GET /setup` without session → 401
- `GET /setup` with X-Session → 200
- All setup.html API calls use X-Session (not X-Pin)

## Validation plan
```bash
bash roles/travel-router/assets/validate-local.sh
# Expected: SUITE GREEN, updated asserts

python3 -m py_compile roles/travel-router/assets/status-server.py
# Expected: exit 0

# Manual smoke:
# TRAVELROUTER_SETUP_PIN=1234 TRAVELROUTER_ADMIN_PSK=admin TRAVELWAN_BIN=<stub> \
#   TRAVELROUTER_BIND_HOST=127.0.0.1 TRAVELROUTER_STATUS_PORT=18098 python3 status-server.py &
# curl -s http://127.0.0.1:18098/setup
#   -> 401 {"error":"auth"}  (no session)
# curl -s -H 'X-Session: <token>' http://127.0.0.1:18098/setup
#   -> 200 text/html  (session accepted)
# curl -s http://127.0.0.1:18098/
#   -> 200 text/html  (public minimal status page, No auth)
```

## Success criteria
- [ ] `/setup` without session → 401 (or 404 if merged into admin)
- [ ] `/setup` with X-Session → 200 (if kept as separate page)
- [ ] `/` → 200 (public minimal status page, no auth)
- [ ] Admin page has WiFi Networks + Known networks sections (if merged)
- [ ] setup.html removed (if merged) or session-gated (if kept)
- [ ] install.sh no longer installs setup.html (if merged)
- [ ] Suite GREEN with updated asserts

## Rollback
```bash
git checkout roles/travel-router/assets/status-server.py roles/travel-router/assets/admin.html roles/travel-router/assets/setup.html roles/travel-router/install.sh roles/travel-router/assets/validate-local.sh
```

## Next task
S05 — Update captive portal redirect target (blocked by S04).
