# RESUME — travel-router-ap-stealth (COMPLETE — witness run passed, plan closed)

<!--
SESSION 2026-09-22. Witness run COMPLETE on hardware (HEAD a17bad5,
reflash bookworm armhf 2026-06-18): T1 login, T5 write-path + restore,
T2 random rename (travel-router -> YZ47K3MZ), T3 hide (scan negative,
manual rejoin works), T4 un-hide (envelope delivered, client kept, scan
positive). ALL PASS. Plan checkbox 3 ticked. Suite 436/0. Outage root
cause (empty country render + dead liveness poll) fixed + hardware-
proven. The ap-stealth plan is DONE; nothing pending for it.
-->

## Current state

Plan `.omo/plans/travel-router-ap-stealth.md`: **ALL 3 TODOs DONE**
(a85bb1b, b3f51ea, d71ff81 + session fixes faaff26, a17bad5; docs 01984f5,
048df90). Suite monotonic: **436 passed, 0 failed**. Evidence:
`.omo/evidence/travel-router-ap-stealth/hostapd-probe-fix.txt` — witness
run final verdict + T1-T4 results + operational notes at the bottom.

Live AP state on the Pi right now: SSID **YZ47K3MZ** (random rename
applied), VISIBLE (un-hidden), PSK **fubar123**, admin login Password123,
PIN 5555. Note: this SSID is a witness-run artifact — re-provisioning
resets AP name/PSK to `.env` values (travel-router) by design whenever
the user wants the standard name back.

## Owner-call items (carried over, unchanged)

- provision.sh CR-strip hunk uncommitted (working tree)
- untracked scratch file tasks/5-session-auth.md

## Next session steps

None for ap-stealth — plan closed. Any new work starts a fresh plan.
Standing ops notes live in the evidence file (envelope loss on radio-
restarting applies; hidden-network manual rejoin; invalid-PSK test
vectors must be structurally invalid).

## Standing rules (do not relearn)

- Mac on `192.168.0.x` = home LAN (Brook) → Pi unreachable; STOP and ask the
  user to switch to the travel SSID (192.168.50.x). Never poll.
- NEVER run hostapd against the live conf or a conf with `interface=wlan0`
  while hostapd-travel runs — use a dead-iface probe copy only.
- Login API needs `X-Requested-With: XMLHttpRequest` from curl.
- Suite gate: monotonic; now 436/0.

## Standing rules (do not relearn)

- Mac on `192.168.0.x` = home LAN (Brook) → Pi unreachable; STOP and ask the
  user to switch to the travel SSID (192.168.50.x). Never poll.
- NEVER run hostapd against the live conf or a conf with `interface=wlan0`
  while hostapd-travel runs — use a dead-iface probe copy only.
- Login API needs `X-Requested-With: XMLHttpRequest` from curl.
- Pre-existing owner-call items (unchanged): provision.sh CR-strip hunk
  uncommitted; untracked scratch file tasks/5-session-auth.md.
- Suite gate: monotonic; now 433/0.