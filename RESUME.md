# RESUME — travel-router-security-features (suite committed, F-wave running)

<!--
SESSION 2026-09-24. Security-features plan closed out to green: todo 12 suite
battery committed f61b7d3 (travel-router-security-finishing plan, T1-T3). The
5ar(e) flake root-caused to a CLIENT-side curl artifact (path passed as an
extra URL arg; curl prints a -w "\n000" line per URL) — server was always
clean. Fixed by shifting path/body out of $@ in aq_get/aq_post + restoring the
missing no-session read/401 in the (e) flow. Suite >=570/0 across 6
consecutive full runs. T4 README docs done (SSH-recovery wording corrected:
wired IP ≠ inbound SSH; policy-drop documented). F1-F4 verification wave
remains; owner-call items below.
-->

## Current state

Plan `.omo/plans/travel-router-security-features.md`: todos 1-13 ALL TICKED
(last: 3 + 12 ticked by f61b7d3, 13 by the docs commit). Old plan
`.omo/plans/travel-router-security-finishing.md` tracks the finishing wave:
T1-T4 DONE, T5 done now, F1-F4 = final verification wave (in flight;
surface results and wait for the user's explicit okay before declaring the
old plan complete).

- Suite gate: monotonic; now **570 passed, 0 failed** (6 consecutive green
  runs at T2+T3). Evidence `.omo/evidence/travel-router-security-finishing/
  t3-green-runs.txt`.
- Commits: `f61b7d3` test(travel-router): suite for security features; docs
  commit adds README security-features section (README:271-345, default-off
  per feature) + the SSH-recovery correction (README ~:491-502).
- Flake root cause (.omo/evidence/travel-router-security-finishing/
  t1-diagnosis.txt): aq_get/aq_post passed the bare path as an extra curl
  URL -> curl -w "\n000" prefix, client-side never on the wire. Do NOT
  re-narrate it as a keep-alive/loopback issue; the aq_post_r comment
  misattributes the fix.

## Owner-call items

- 2026-09-23 wan-select --no-block fix deployed live
  (/usr/local/lib/travel-router/wan-select.sh on rpi-8e21bb) — if the
  provisioned tree differs from HEAD's wan-select.sh, next re-provision
  reconciles. Confirm on next hardware session if desired.

## Next session steps

- F1-F4 verdicts, then close both plans; any new work starts a fresh plan.

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
