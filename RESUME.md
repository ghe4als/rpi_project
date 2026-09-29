# RESUME — travel-router S-wave COMPLETE (S01-S06 committed)

<!--
SESSION 2026-09-28 (continued). S04 committed 6af72e6, S05 76862a7, S06
1d9dd15 (all this session). The S-wave from tasks/S01-S06 + ISSUES.md is
DONE. S06's original premise was WRONG (PIN still live as admin-write
second factor); the corrected plan tasks/S06-pin-fate-corrected.md was
executed: KEEP the PIN, DELETE the dead GET-bucket gate (_pin_gate/
_require_pin_header, zero call sites since S03), docs updated. Suite
592 passed / 0 failed x3 (was 586 at S04 close).

S06 plan-correction note (for future plan-writers): the original
tasks/S06 file assumed the PIN would be fully obsolete post-S03. It
was not — admin writes kept body.pin as the second factor (S03 chose
two-factor). When a task file's premise says a security control is
"no longer needed", VERIFY against code before executing.

Suite-assert surgery this session (S06): X-Session prose census in
admin.html went 6 -> 5 (poll-comment rewrite dropped an incidental doc
hit); dead-code asserts must use match-or-not grep (never
`grep -c | grep -q` — pipefail poisons the pipe on the wanted 0).
-->

## Current state

- ALL plans ticked: security-features plan, finishing plan (await owner
  close-ok, now genuinely final), and the S01-S06 HTTP route workstream
  (tracked in tasks/ISSUES.md — all rows resolved there).
- Suite gate: monotonic; **592 passed, 0 failed**, 3 consecutive runs.
- Working tree: CLEAN (S06 + RESUME committed).
- Live Pi (rpi-8e21bb) does NOT carry S01-S06 yet (last flash predates
  them; AP-rename fixes were hot-pushed earlier). Next natural re-flash
  picks up everything.

## Next session steps

1. NO pending code work. Owner decisions optionally open: close the two
   old plans (security-features + finishing) — everything ticked; and
   whether to hardware-smoke the S-wave on a re-flash (no hardware step
   was planned or needed for any S-item; all server/client-local).
2. ISSUES.md: fully resolved (S1-S5 + C1, C2 kept open as documented
   tradeoff). Nothing actionable left from the 2026-09-27 review.

## Standing rules (do not relearn)

- Mac on `192.168.0.x` = home LAN (Brook) → Pi unreachable; STOP and ask
  the user to switch to the travel SSID (192.168.50.x). Never poll.
- NEVER run hostapd against the live conf or a conf with
  `interface=wlan0` while hostapd-travel runs — use a dead-iface probe
  copy only.
- Login API needs `X-Requested-With: XMLHttpRequest` from curl.
- The suite is client/capture-fragile: every curl wrapper must pass the
  URL EXACTLY ONCE.
- Suite gate: monotonic; do not re-derive the 5ar(e) order.
- `hostapd_cli -p` takes the ctrl socket DIRECTORY, NOT the socket file
  (cost one debug round-trip 2026-09-26; §5z stubs exit 3 on it).
- 2026-09-26 hardware verification of the AP-rename brick fix is DONE
  (f3-manual.md + Pi's apconfig.log). Do not re-run those.
- PIN (2026-09-28 S06 decision): KEEP as admin-write second factor;
  GET-bucket X-Pin is GONE — do not revive.