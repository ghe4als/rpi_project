# WS04 — Deauth alert banner (public + admin) + dismiss

## Goal
Surface the WS03 deauth alert on the public status page and the admin page,
with an admin-gated dismiss that clears the alert file.

## Context
WS03 writes `/run/travel-router/deauth-alert.json` on a burst. WS decision D3:
detection → operator decides. This task is the "show it" half — the operator
sees the warning and can dismiss it. No prevention claim, no auto-rotation.

## Files touched
- `roles/travel-router/assets/status-server.py` — alert read + public field + admin clear
- `roles/travel-router/assets/admin.html` — banner + dismiss button
- `roles/travel-router/assets/validate-local.sh` — §5av battery
- `roles/travel-router/README.md` — note the banner

## Pre-conditions
- [ ] WS03 committed (`353486d`); suite green at 687/0.

## Exact changes required

### Change 1: status-server.py — alert state
- New constants near the other stores:
  `DEAUTH_ALERT_FILE` (env `TRAVELROUTER_DEAUTH_ALERT_FILE`, default
  `/run/travel-router/deauth-alert.json`); `DEAUTH_ALERT_TTL` (env
  `TRAVELROUTER_DEAUTH_ALERT_TTL_SEC`, default `900`).
- `_deauth_alert_now()`: stat the file; if absent or `age >= TTL` -> `None`;
  else parse `count` from the JSON and return
  `{"active": True, "count": N, "age_sec": int(age)}`. Age from file mtime
  (robust, no tz parsing). Never raises.
- Public `GET /api/status`: add `"deauth": _deauth_alert_now() or {"active": False}`.
  (Public is LAN-only; the alert is an operator signal, safe to expose.)
- `POST /api/admin/deauth` (`action == "clear"`) admin-write branch: remove the
  alert file (best-effort), return `{"ok": True, "deauth": {"active": False}}`.
  Add the path to BOTH the POST route allowlist and the `admin_write` set.

### Change 2: admin.html — banner + dismiss
- New section `#deauth-section` (hidden by default) with `#deauth-msg` and a
  `#deauth-dismiss` button. Text via `textContent` only (NO innerHTML — §5sc).
- `refreshDeauth()`: `fetch("/api/status")`; if `d.deauth.active`, show the
  section with "Possible deauthentication attack detected (N disconnects);
  consider leaving this network."; else hide it.
- `#deauth-dismiss` click -> `api("/api/admin/deauth", {pin, action:"clear"})`
  then `refreshDeauth()`. Reuse the existing PIN plumbing.
- Call `refreshDeauth()` on load and from the existing status poll.

### Change 3: public `_STATUS_HTML` — banner
- Add a `#deauth-banner` element (hidden) + in `refreshStatus()`, when
  `d.deauth.active` show "⚠ Possible deauthentication attack detected (N);
  consider leaving this network." via `textContent`; else hide.
- Keep the page textContent-only and free of the §5ai leak words.

### Change 4: suite §5av
Battery (live server, stubbed travel-wan; reuse `login_psk`):
- (a) alert file present -> `GET /api/status` body has `"active":true` + count.
- (b) alert file with an OLD mtime (or TTL=0) -> `"active":false`.
- (c) no file -> `"active":false`.
- (d) `POST /api/admin/deauth clear`: no session -> 401; session no PIN -> 403;
  session+PIN -> 200 and the file is gone.
- (e) structural: `_STATUS_HTML` carries a deauth banner id + reads `d.deauth`;
  `admin.html` carries `#deauth-section`/`#deauth-dismiss` and adds no innerHTML.

## Validation plan
    bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -5
    # Expected: SUITE GREEN, 0 failed

## Success criteria
- [ ] Suite green; §5av passes.
- [ ] Public + admin banners reflect an active alert; TTL expiry hides it.
- [ ] Dismiss requires session + PIN and removes the file.
- [ ] No innerHTML added; §5ai leak list unaffected.
- [ ] `git diff` touches only the 4 files.

## Rollback
    git checkout roles/travel-router/assets/status-server.py \
      roles/travel-router/assets/admin.html \
      roles/travel-router/assets/validate-local.sh roles/travel-router/README.md

## Next task
After confirmed complete + committed: WS05 — final suite battery + README close-out.
