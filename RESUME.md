# RESUME — travel-router-security-features (suite committed, F-wave running)

<!--
SESSION 2026-09-26. F3 was NOT merely "blocked on the network": it RAN on
2026-09-25 07:05 and returned REJECT, and chasing that rejection found a real
bricking bug. F3 evidence: .omo/evidence/travel-router-security-finishing/
f3-manual.md.

THE BUG (root-caused, fixed, HARDWARE-VERIFIED 2026-09-26): ap-apply's liveness
poll accepted the mere PRESENCE of the hostapd ctrl socket as proof the AP was
up. hostapd creates <ctrl_interface>/<iface> during driver init, while the
interface is still UNINITIALIZED/COUNTRY_UPDATE - so the poll went true ~1s
after restart, ap-apply returned 0 and DELETED $AP_CONF.bak (the only copy of
the pre-rename conf). A radio that then failed to bind had nothing to roll back
to: the AP never reappeared and only a re-flash recovered it. Reproduced live
on rpi-8e21bb (minted KNT44Z28, apply returned 0 bytes over the air, AP then
vanished from every scan). The rendered conf was proven VALID offline, so this
was never a bad render and never the hidden-SSID flag.

FIX (3 files, UNCOMMITTED): travel-wan.sh gains _ap_radio_up (asks hostapd_cli
for wpa_state/interface_state=ENABLED instead of trusting the socket, 25s
budget, logs a WARN if hostapd_cli is missing), keeps $AP_CONF.bak until the
radio is proven up, verifies+logs the rollback, and appends 21 aplog lines to
/var/log/travel-router/apconfig.log (durable: journald on the Pi is
Storage=volatile and the admin page is served over the radio it just restarted,
so both the journal and the response die with the outage). install.sh
pre-creates apconfig.log and seeds the ap-ssid file (never written before, which
is why /api/admin/ap-info answered ap_ssid:"" on a HEALTHY fresh box).
validate-local.sh gains a hostapd_cli stub + 9 new asserts: §5z (5) covers the
regression — socket-present-but-not-ENABLED -> rc=1 AND the pre-rename conf
survives — and §5ah (4) covers the install path, including that the seeded
ap-ssid must AGREE with the SSID actually rendered into the conf.

Suite: 581 passed / 0 failed, 3 consecutive full runs (gate was 570; +11 = the
new asserts). Three self-inflicted bugs were introduced and fixed en route:
(1) `${AP_CONF.bak}` is a bash bad substitution (`.` is illegal in a braced
name) - it broke 19 asserts, which is why §5an failed as a group; (2)
`hostapd_cli -p` takes the ctrl socket DIRECTORY, not the socket file - this
would have rolled back EVERY rename on hardware, and only the man pages caught
it; (3) the test stubs invented `wpa_state=ENABLED`, which real hostapd never
emits, so the suite validated my own wrong assumption.

HARDWARE VERIFICATION (rpi-8e21bb, fresh flash 2026-09-26) - all three pass:
- SUCCESS path: admin rename to BS4Z3PBY applied and was connectable.
  apconfig.log: `poll: AP-ENABLED after 1s` then `OK: AP verified beaconing`.
  conf = ap-ssid = ap-info all agreed; no PSK in the log.
- FAILURE path (the brick): with the ctrl-dir seam pointed at an empty dir the
  poll cannot confirm the radio, so the apply must fail AND the AP must
  survive. RC=1, previous conf restored, ZZTEMP99 absent from the live conf,
  radio alive (state=ENABLED, 25 clients). The brick is fixed.
- Real hostapd 2.10 AP-mode `hostapd_cli status` emits a BARE `state=ENABLED`
  key - no `wpa_state`, no `interface_state`. The liveness match is
  substring `state=ENABLED`; the §5z stubs now copy that real key shape so the
  suite cannot drift from the daemon again.

TWO MORE BUGS found ONLY by the hardware failure test, both now fixed:
- `ap-ssid` was written before the restart and never reverted on failure, so
  after a rolled-back apply `ap-info` reported the ABORTED SSID (verified:
  ap-ssid said ZZTEMP99 while the radio was BS4Z3PBY). ap-apply reads that file
  to fill an omitted SSID slot, so the next psk-only change would have
  resurrected the aborted rename. Now rolled back with the conf.
- The rollback log claimed "AP is DOWN; recover over USB/serial or re-flash"
  when liveness was merely UNPROVEN - that check is unanswerable if the ctrl
  dir or hostapd_cli is wrong, and it would send an operator to re-flash a
  healthy router. Now "rollback UNVERIFIED: ... Liveness is unproven, not
  disproven".
-->

## Current state

Plan `.omo/plans/travel-router-security-features.md`: todos 1-13 ALL TICKED
+ F1/F2/F4 ticked (F2 via REJECT -> fix 47a8e5e -> re-verdict APPROVE).
F3 ran twice: 2026-09-25 REJECT (stale deployed build — every admin route 404'd),
which is what surfaced the AP-rename bricking bug above; then 2026-09-26
**APPROVE** on a fresh flash carrying the fix — all 7 steps pass, both rename
paths (success + forced-failure rollback) hardware-verified. F3 is now ticked in
the old plan, and the finishing plan's T1-T5 + F1-F4 are all ticked, so BOTH
plans have zero unticked rows. They await the owner's explicit okay to close
(the 2026-09-26 "keep open" decision was made while F3 was still REJECT).

- Suite gate: monotonic; now **581 passed, 0 failed**, 3 consecutive green runs
  after the apconfig fix (was 570; +11 new asserts).
- **UNCOMMITTED, 4 files** (incl. this RESUME.md):
  `roles/travel-router/assets/travel-wan.sh`, `roles/travel-router/install.sh`,
  `roles/travel-router/assets/validate-local.sh`. Nothing is committed — the
  owner has not asked for a commit.
- The Pi card WAS flashed from the tree containing items 1-4, and
  `travel-wan.sh` was then hot-pushed to `/usr/local/bin/travel-wan` for the
  two follow-on fixes, so the LIVE Pi carries the complete fix. A re-flash is
  NOT needed for correctness; the next natural flash picks all of it up.
- **Live AP identity is back to the `.env` default: `travel-router`** (the F3
  rename test renamed it from the minted `BS4Z3PBY` and restored it). All
  feature flags verified default-off afterwards: blocked empty, killswitch
  flag absent, sshlockdown flag absent, no `.bak` residue, no ZZTEMP99 residue.
- F3 verdict evidence: `.omo/evidence/travel-router-security-finishing/f3-manual.md`
  (2026-09-26 **APPROVE**, supersedes the 2026-09-25 REJECT). Pi-side forensic
  logs: `/var/log/travel-router/apconfig.log`, `failtest.out`, `failtest2.out`.
- Pre-existing flake root cause, still valid
  (.omo/evidence/travel-router-security-finishing/t1-diagnosis.txt): aq_get/aq_post
  passed the bare path as an extra curl URL -> curl -w "\n000" prefix,
  client-side never on the wire. Do NOT re-narrate it as a keep-alive/loopback
  issue; the aq_post_r comment misattributes the fix.

## Owner-call items

- 2026-09-23 wan-select --no-block fix deployed live
  (/usr/local/lib/travel-router/wan-select.sh on rpi-8e21bb) — if the
  provisioned tree differs from HEAD's wan-select.sh, next re-provision
  reconciles. Confirm on next hardware session if desired.
- OPEN: the admin page cannot report an apply result at all — it is served over
  the radio the apply restarts, so the response dies with the connection. The
  owner deliberately scoped a fix for this OUT of the current pass (fix items
  1-4 only). Durable logging is the interim mitigation. Revisit if renames stay
  opaque in the field.

## Next session steps

1. DONE 2026-09-26: hardware-verified (success path, brick path, ap-ssid
   rollback, honest rollback wording) — see the SESSION block above. Do not
   re-run these; the evidence is in the Pi's
   `/var/log/travel-router/apconfig.log` and `/var/log/travel-router/failtest2.out`.
2. DONE 2026-09-26: F3 re-run — **APPROVE**, all 7 steps, recorded in
   `.omo/evidence/travel-router-security-finishing/f3-manual.md`. Both plans now
   have zero unticked rows.
3. Ask whether to commit the 4-file fix, then close both plans (the plan's rule
   is to surface results and wait for the owner's explicit okay).
- The live AP is back on the `.env` `travel-router`; all feature flags verified
  default-off after the QA run.
- If you re-flash, the card picks up the whole fix automatically; the
  hot-push of `travel-wan.sh` was only to avoid another flash.
- The owner's ISP was intermittently dropping 2026-09-26 mid-session. If SSH or
  HTTP verification suddenly fails, check whether the Mac roamed to Brook
  (`192.168.0.x`) before assuming the Pi is down.

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
