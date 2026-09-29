# S06 — Decide PIN fate + final cleanup

> **SUPERSEDED 2026-09-28** by `tasks/S06-pin-fate-corrected.md`.
> The premise below ("the PIN is no longer needed for any route") was
> FALSE: admin writes (`/api/wan/apconfig`, `/api/wan/psks-manage`,
> `/api/admin/*` POSTs) still require `body.pin` as the second factor
> (status-server.py `_pin_ok`, :1242). Read the corrected file before
> executing any S06 work.

## Goal
Decide whether the PIN is still needed after the HTTP route restructure, and perform any final cleanup.

## Context
After S01-S05:
- `/` → public minimal status page (no auth)
- `/status` → session-gated
- `/api/wan/known` → session-gated
- All `/api/wan/*` POST verbs → session-gated
- `/setup` → session-gated or removed
- `/admin` → session-gated

The PIN was originally the "guest" credential for the setup page. After the restructure, the setup page is admin-only, so the PIN is no longer needed for any route.

**Options:**
1. **Keep the PIN**: It can be used for future guest-facing functionality. The `_pin_gate` function remains in the codebase but is unused.
2. **Remove the PIN**: Simplify the codebase by removing all PIN-related code. The `TRAVELROUTER_SETUP_PIN` env var becomes unnecessary.

**Recommendation**: Keep the PIN for now. It's already implemented, tested, and documented. Removing it would be a separate cleanup task. The PIN can be useful for future features (e.g., a guest-facing "connect to WiFi" page that doesn't reveal sensitive info).

## Files touched
- `roles/travel-router/assets/status-server.py` — remove PIN gate (if removing) or add deprecation comment (if keeping)
- `roles/travel-router/assets/validate-local.sh` — remove PIN tests (if removing) or mark as deprecated (if keeping)
- `roles/travel-router/install.sh` — remove PIN validation (if removing)
- `.env.example` — remove PIN var (if removing)
- `README.md` — remove PIN docs (if removing)

## Pre-conditions
- [x] S01-S05 committed
- [x] Suite GREEN

## Exact changes required

### Option A: Keep the PIN (RECOMMENDED)

#### Change 1: status-server.py — add deprecation comment
File: `roles/travel-router/assets/status-server.py`
Action: ADD a comment to the `_pin_gate` function.

```python
def _pin_gate(handler, supplied):
    """PIN gate — DEPRECATED after S01-S05. The PIN is no longer used for
    any route (all sensitive routes are session-gated). This function is
    kept for future guest-facing functionality. Do not use for new routes.
    """
    # ... existing implementation ...
```

#### Change 2: validate-local.sh — mark PIN tests as deprecated
File: `roles/travel-router/assets/validate-local.sh`
Action: Add a comment to the §5g battery.

```bash
# §5g — PIN staging battery (DEPRECATED after S01-S05)
# The PIN is no longer used for any route. These tests are kept to verify
# the PIN infrastructure still works, but no route uses it.
```

#### Change 3: No other changes
Keep all PIN-related code, tests, and documentation as-is.

### Option B: Remove the PIN

#### Change 1: status-server.py — remove PIN gate
File: `roles/travel-router/assets/status-server.py`
Action: REMOVE the following:
- `SETUP_PIN = os.environ.get("TRAVELROUTER_SETUP_PIN", "")` (line 79)
- `_pin_gate()` function (lines 617-658)
- `_require_pin_header()` function (lines 661-665)
- `_pin_ok()` static method (lines 968-974)
- All calls to `_pin_gate()`, `_require_pin_header()`, `_pin_ok()`
- The `_PIN_FAILS` throttle dict and related code (if only used for PIN)

#### Change 2: install.sh — remove PIN validation
File: `roles/travel-router/install.sh`
Action: REMOVE the PIN validation block (lines 133-144).

#### Change 3: .env.example — remove PIN var
File: `.env.example`
Action: REMOVE the `TRAVELROUTER_SETUP_PIN` line.

#### Change 4: README.md — remove PIN docs
File: `README.md`
Action: REMOVE all references to `TRAVELROUTER_SETUP_PIN`.

#### Change 5: validate-local.sh — remove PIN tests
File: `roles/travel-router/assets/validate-local.sh`
Action: REMOVE the §5g battery and all PIN-related asserts.

#### Change 6: travel-router-status.service — remove PIN from EnvironmentFile
File: `roles/travel-router/assets/travel-router-status.service`
Action: The EnvironmentFile still contains the PIN. Either:
- (a) Keep the EnvironmentFile but remove the PIN line, OR
- (b) Remove the EnvironmentFile entirely (if no other vars are needed)

## Validation plan
```bash
bash roles/travel-router/assets/validate-local.sh
# Expected: SUITE GREEN

python3 -m py_compile roles/travel-router/assets/status-server.py
# Expected: exit 0

# If removing PIN:
grep -c 'TRAVELROUTER_SETUP_PIN' .env.example README.md roles/travel-router/install.sh
# Expected: 0 in all files
```

## Success criteria
- [ ] PIN fate decided (keep or remove)
- [ ] If keeping: deprecation comments added, all tests pass
- [ ] If removing: all PIN code/tests/docs removed, suite GREEN
- [ ] No route uses the PIN (all sensitive routes are session-gated)
- [ ] Suite GREEN

## Rollback
```bash
git checkout roles/travel-router/assets/status-server.py roles/travel-router/assets/validate-local.sh roles/travel-router/install.sh .env.example README.md roles/travel-router/assets/travel-router-status.service
```

## Next task
All security HTTP route fixes complete. Update ISSUES.md to mark S1-S4 as resolved.
