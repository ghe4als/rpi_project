# S06 — PIN fate + final cleanup (CORRECTED PLAN)

> **CORRECTION of tasks/S06-pin-fate-cleanup.md (2026-09-28):** the original
> task premise — "the PIN is no longer needed for any route" — is FALSE.
> Admin writes still require it. This file supersedes the original; the
> original is kept only for provenance.

## Verified facts (this session, all from tools on the current tree)

1. **The PIN is a LIVE second factor on admin writes.**
   `status-server.py:1197` defines the admin-write set
   (`/api/wan/psks-manage`, `/api/wan/apconfig`, `/api/admin/*`), and
   `:1242` rejects those writes with 403 `{"error":"pin"}` unless
   `body.pin` matches `SETUP_PIN` (`_pin_ok`, `:1074`). Wrong PINs feed the
   `_PIN_FAILS` per-IP throttle + backoff + `_auth_audit` 403s. The admin
   page carries 11 `PIN required` call-sites for exactly this path.
2. **The PIN-as-GET-credential is dead.** Since S03, no GET reads `X-Pin`:
   `_pin_gate` (:617) and `_require_pin_header` (:661) have ZERO call sites
   (verified by grep — the only references are their own definitions and
   comments). The client bucket is fully session-gated.
3. **`X-Pin` is inert, not rejected.** The suite pins this deliberately
   (5ap (A)/(F), §5ah): with or without a session, an `X-Pin` header on
   GET is simply not consulted. 21 mentions in validate-local.sh, mostly
   "PIN alone insufficient → 401" negative tests — these are
   security-relevant pins, do not delete them blindly.
4. **Docs/premise drift found** (the same class of rot S04/S05 cleaned):
   - `status-server.py:607-616` comment block still says "The client
     surface is PIN-gated: X-Pin header on GET" — false since S03.
   - Module docstring lines 36-42 still describe the CLIENT bucket as
     "PIN suffices / X-Pin header" — false since S03.
   - `:13` "GET /api/wan/known -> PIN-gated ... (X-Pin header" — false.
   - `admin.html:1557-1560` comment: "the clients poll needs X-Pin" —
     false since S02 (statusFetch is sessionFetch, no X-Pin sent; the
     `sessToken() && currentPin()` poll gate needlessly requires a PIN
     that is never sent. CurrentPin still gates nothing for /status).
   - README (lines 248, 275, 552, 510-511, 471, 232-264, 357, 367):
     mixed — some "setup PIN" text is still TRUE (admin-write factor),
     but "unlocks the phone setup page" / "client setup page" phrasing
     describes the removed /setup. Also `.env.example:248` comment.
5. **No /admin link from the public page**: `buildLinks()` (the S01 `/`
   page) lists only external speed-test links; a phone dumped on `/` by
   the portal redirect has no on-page path to the management UI — the URL
   must be typed. Fixing this is part of S06 cleanup (small).

## Decision (unchanged after reviewing the facts)

**KEEP the PIN** as the admin-write second factor. Removal would collapse
admin writes to single-factor — a real threat-model change (an observed or
leaked session token could then rename the AP / edit DNS stores with no
second check). The 11-call-site UI + throttle + audit integration is
working and tested. Removing was the ORIGINAL S06's Option B; it is a
posture regression, not cleanup.

## Corrected scope — three work items

### W1 — Remove the dead GET-bucket PIN chain (dead code, zero call sites)
File: `roles/travel-router/assets/status-server.py`
- DELETE `_pin_gate()` (incl. its now-false comment block :607-616) and
  `_require_pin_header()` (:661-665). Verify zero remaining call sites.
- KEEP every live seam: `SETUP_PIN`, `_pin_ok`, `_PIN_FAILS`, the
  `_pin_backoff_tier` wiring, 401-vs-403 semantics, `err_key = "pin"`.
- Rewrite the module docstring CLIENT bucket text (lines ~36-45) and the
  `:13` known-networks line to the S03+ reality: client reads/writes are
  session-gated; PIN is the ADMIN-WRITE second factor only.

### W2 — Correct stale PIN comments/docs (comment/doc surgery only)
- `status-server.py`: any remaining "X-Pin header" phrasing — replaced by
  W1's docstring rewrite. The `:81` "same posture as SETUP_PIN" comment is
  still accurate; keep.
- `admin.html`: fix the `:1557-1560` poll comment. DECISION POINT (owner):
  the poll gate `sessToken() && currentPin()` makes the clients poll
  require a PIN that no longer unlocks anything for that call. Options:
  (a) keep gate as-is (harmless: PIN also used for block/unblock actions),
  (b) drop `currentPin()` from the gate. Default: (a) keep — zero-behavior
  change; revisit if the poll silently idles when no PIN was saved.
- README: update "setup PIN" phrasing to "admin write PIN" where it
  describes the two-factor write gate; remove/rewrite "phone setup page"
  phrasing that describes the removed /setup flow (lines noted above).
  Keep `.env.example` var + install.sh validation + staging (all still
  required by design).
  NOTE: README edits touch the "phone setup page" hotel procedure section
  whose replacement (admin page as the management surface) S04 created —
  this is a documentation-follows-code fix, not new behavior.

### W3 — Suite: assert the truth, delete nothing security-relevant
validate-local.sh:
- ADD/adjust: an assert that `_pin_gate`/`_require_pin_header` are GONE
  (grep count 0 in status-server.py) — prevents zombie revival.
- UPDATE stale suite comments that still describe X-Pin as a live
  credential on GETs (e.g. line 1037, 359): keep the negative asserts,
  reword only the prose.
- KEEP all "PIN alone insufficient" 401 tests (they are the regression
  net for W1: after deleting the dead functions the behavior must not
  change).
- §5g (PIN staging battery) STAYS: SETUP_PIN still stages to the tmpfs
  EnvironmentFile and still gates admin writes. The original S06's
  "mark §5g deprecated" is wrong.
Net expected count: +2/-0 (deletion assert ×1, plus any prose-only
rewrites that don't change `ok`/`bad` counts). If a rewrite removes a
line counted by the gate, recompute and note it in the commit message.

## Validation plan
```bash
python3 -m py_compile roles/travel-router/assets/status-server.py
# Expected: exit 0
bash roles/travel-router/assets/validate-local.sh
# Expected: SUITE GREEN; pass-count 586 (+1 new dead-code assert, -0)
# (run 3x — monotonic gate rule)
grep -c '_pin_gate\|_require_pin_header' roles/travel-router/assets/status-server.py
# Expected: 0
grep -c 'X-Pin' roles/travel-router/assets/status-server.py
# Expected: 0 (no GET credential in server code anymore)
grep -rn 'TRAVELROUTER_SETUP_PIN' .env.example | wc -l
# Expected: 1 (kept: admin second factor)
```

## Success criteria
- [x] `_pin_gate`/`_require_pin_header` gone; `_pin_ok`/`SETUP_PIN`/throttle intact
- [x] All 403-pin admin-write asserts still pass (two-factor survives)
- [x] No "X-Pin as GET credential" doc text remains in server/admin page
- [x] README consistent with the S04 merge (admin page is the setup surface)
- [x] Suite GREEN (monotonic count noted in commit message)

## Rollback
`git checkout roles/travel-router/assets/status-server.py
roles/travel-router/assets/admin.html README.md
roles/travel-router/assets/validate-local.sh`

## Next task
Update `tasks/ISSUES.md`: S1-S4 rows → resolved (c6f45fe / 6af72e6 /
76862a7 / this), C1 stale-comment row → resolved if touched. The S-wave
is then complete.