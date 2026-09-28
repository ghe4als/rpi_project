# RESUME — travel-router S-wave (S04 committed; S05 next)

<!--
SESSION 2026-09-28. Resumed after RESUME.md had gone stale (it still described
the AP-rename brick fix pass, but since then the tree had moved on: the 4-file
fix was committed as 411a7e5, and a NEW workstream started — the HTTP route
security restructure (tasks/S01..S06 + travel-router-http-review.md + tasks/
ISSUES.md, committed as c742cb3). S01-S03 landed as c6f45fe with a reworked
suite (581 green). S04 was mid-flight: an uncommitted admin.html diff carried
the merged setup UI. Owner chose "Finish S04" on resume.

S04 DONE, committed as 6af72e6 (5 files: admin.html merged UI, setup.html
DELETED, status-server.py /setup route + SETUP_PAGE constant removed,
install.sh un-stages setup.html, validate-local.sh re-pointed).
SUITE GREEN: 586 passed / 0 failed, 3 consecutive runs (was 581; +5 net).

Key decisions/findings this session:
- The captive portal redirect (_portal_redirect) still 302s to /setup as a
  STRING LITERAL — the SETUP_PAGE constant was never read by it, so the
  constant is gone but the redirect is INTENTIONALLY untouched until S05
  (S05's pre-condition is "S04 committed"). R1/5ai(4) suite asserts still pin
  Location -> /setup; S05 must flip both the literal and those asserts.
- Suite assert surgery worth remembering: (1) admin.html has 11 occurrences
  of the "PIN required" string (one per PIN-gated write) — the unique pin is
  handleErr's `throw new Error(...)` form, not a string count; (2) the
  known-fetch census must grep `sessionFetch("/api/wan/known"` (a -A2 window
  + "sessionFetch" matches a trailing comment and overcounts to 3); (3) the
  5al(1) awk route-window terminator changed from /setup to /admin (the
  /setup branch no longer exists in do_GET); (4) X-Session census in
  admin.html went 5 -> 6 (S04 merge comments).
- install.sh ADMIN_PSK comment now says "gates the admin page" (S04 wording).
-->

## Current state

- Plan `.omo/plans/travel-router-security-features.md` + finishing plan: all
  rows ticked (owner okay to close still pending from 2026-09-26, superseded
  in practice by the newer S-wave — ask).
- New S-wave tasks live in `tasks/S01..S06-*.md` + `tasks/ISSUES.md`:
  S01 ✅ S02 ✅ S03 ✅ (c6f45fe) — **S04 ✅ (6af72e6, this session)**.
  S05 next (captive portal redirect -> /; blocked only on nothing now),
  then S06 (PIN fate + cleanup; setup PIN still used as admin write factor).
- Suite gate: monotonic; **586 passed, 0 failed**, 3 consecutive runs.
- Working tree: CLEAN (S04 committed). RESUME.md itself is the only expected
  local modification after this write.
- Live Pi (rpi-8e21bb) does NOT carry S04/S01-S03 yet (last flash predates
  them; the AP-rename fixes were hot-pushed earlier). Next natural re-flash
  picks up everything.

## Next session steps

1. **S05 — captive portal redirect -> `/`** (tasks/S05-captive-portal-redirect.md):
   change `_portal_redirect` Location literal `/setup` -> `/`, update the
   R1 (18091) + 5ai(4) (18102) + 5p(5) asserts that pin the Location, run the
   suite (expect 586 -> 586, asserts edited in place, not added), commit.
2. **S06 — PIN fate + cleanup** (tasks/S06-pin-fate-cleanup.md): owner decision
   required on PIN retention — read the task file first, ask the owner.
3. After S06: re-run F3-style hardware smoke or decide the S-wave is
   software-only (all asserts client/server-local; no hardware step planned).
4. Close out tasks/ISSUES.md rows S1-S4 (S1/S2/S3 done in c6f45fe, S4 done in
   6af72e6) and the C1 stale-comment row if desired.

## Standing rules (do not relearn)

- Mac on `192.168.0.x` = home LAN (Brook) → Pi unreachable; STOP and ask the
  user to switch to the travel SSID (192.168.50.x). Never poll.
- NEVER run hostapd against the live conf or a conf with `interface=wlan0`
  while hostapd-travel runs — use a dead-iface probe copy only.
- Login API needs `X-Requested-With: XMLHttpRequest` from curl.
- The suite is client/capture-fragile: every curl wrapper must pass the URL
  EXACTLY ONCE (path is NOT part of "$@" in aq_get/aq_post).
- Suite gate: monotonic; do not re-derive the 5ar(e) order — the (e) ring
  mint order is assert-driven (read/401 -> write/403 -> login/401 x2).
- `hostapd_cli -p` takes the ctrl socket **DIRECTORY** (`/var/run/hostapd`),
  NOT the socket file; pick the interface with `-i <iface>`. A `-p` aimed at
  the socket file is a non-directory, so hostapd_cli answers an EMPTY status —
  which reads as "radio down" and rolls back every rename. Cost one debugging
  round trip on 2026-09-26; §5z's hostapd_cli stubs now exit 3 if `-p` is not
  a directory, so the suite catches it.
- 2026-09-26 hardware verification of the AP-rename brick fix is DONE and
  recorded (see `.omo/evidence/travel-router-security-finishing/f3-manual.md`
  and the Pi's `/var/log/travel-router/apconfig.log` + `failtest2.out`).
  Do not re-run those hardware tests.
- Pre-existing flake root cause (.omo/evidence/.../t1-diagnosis.txt):
  aq_get/aq_post passed the bare path as an extra curl URL. Fixed via
  ap_post/ap_get; do NOT re-narrate as keep-alive/loopback.