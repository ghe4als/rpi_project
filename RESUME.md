# RESUME — S-waves COMPLETE + S06b/S06c/S06d committed (593-green ×7)

<!--
SESSION 2026-09-29. S06b cleanup, S06c doc-truth, and S06d comment-truth all
EXECUTED + VERIFIED. S06d commits a178a6d (validate-local.sh 34/34),
5d6b1e2 (README 3/3), b5aaaa1 (RESUME 5/5): 16 stale credential-model
comments/labels in validate-local.sh + 2 README lines now describe the S03
session gate instead of the pre-S03 client-PIN model. Suite 593/0 x2 at the
S06d gate (7+ greens across the three waves). The S06d plan was dual-reviewed
(r3: momus APPROVE + oracle OKAY) and every todo DoneClaim independently
verified. S06d is TERMINAL — no S06e planned.
COMMENT-TRUTH ARC IS CLOSED: S06b (5 files) -> S06c (3 residuals) -> S06d
(18 spots). The recurring cause was scope drawn from an eyeballed list rather
than an exhaustive class sweep; S06d was scoped from a full sweep and its
independent re-sweep found no 19th site.
-->

## Current state

- S06b, S06c, S06d ALL COMPLETE. S06d plan 5/5 todos + F1-F4 + 5 success
  criteria ticked. Ledger: .omo/start-work/ledger.jsonl; artifacts:
  .omo/evidence/s06d-comment-truth/ (6 run logs).
- Suite gate: monotonic; **593 passed, 0 failed**, 3 consecutive runs.
- Working tree: CLEAN.
- Carried follow-ups (comment-only, verified real, outside S06b's scoped
  lines): status-server.py:1138 "still a PIN guess" stale rationale;
  validate-local.sh:332-333 "absent pin is 401" mixed framing;
  validate-local.sh:1039 "(body.pin;" stale fragment. All one-line edits,
  non-behavioral.
- Owner decision: F3 stale deployment (live Pi rpi-8e21bb predates the
  S-wave) — re-provision will pick up everything now.
- S-wave HARDWARE-VERIFIED 2026-09-30 on rpi-8e21bb (fresh Bookworm travel-router flash): all S-wave HTTP routes live — GET / 200, GET /setup 404 (S04), GET /status 401 (S02), GET /admin 200, /health {"status":"ok"}, public / carries the Admin link (S06b), /api/status = {ap_ssid,wan_ssid,internet}, no device-data leak; PIN env staged 0600; wrong-PSK login 401. Captive-portal 404 on /generate_204 is CORRECT-PER-DESIGN (routed mode removes the portal drop-in; standalone-only feature).
- Prior work travel-router-security-finishing PAUSED (its F3 landed as a
  root-cause-proven stale deployment).

## Next session steps

1. NO pending code work. The comment-truth arc is closed; no S06e is planned.
   NB: the earlier ":3122-3131 (body.pin; fragment" note was a PHANTOM (that
   fragment was deleted at S06c).
2. Optional (deliberately NOT done — cost/benefit): a banned-phrase assert in
   the suite would structurally prevent the prose drift from recurring. Not
   warranted for a one-time 38-line comment fix; revisit only if drift recurs.
3. Hardware smoke test: DONE (see Current state). Remaining known gap: Bookworm flashes cannot bind flash history — provision-bookworm.sh records pending_flashes without an instance_id and deletes /boot/firmware/meta-data, so pi register never matches (Bookworm Lite has no cloud-init). Affects every Bookworm flash; FIXED in S07 (commit bf45e5d): provision-bookworm.sh stamps a Trixie-format instance_id onto bootfs/meta-data, records it in the pending entry, and firstrun persists it to /var/lib/rpi-project/instance_id; suite 604/0 x3. The stranded pre-S07 pending entries remain unbindable by design; live bind proof lands on the next natural re-flash.

## Standing rules (do not relearn)

- Mac on `192.168.0.x` = home LAN (Brook) → Pi unreachable; STOP and ask
  the user to switch to the travel SSID (192.168.50.x). Never poll.
- NEVER run hostapd against the live conf or a conf with
  `interface=wlan0` while hostapd-travel runs — use a dead-iface probe
  copy only.
- Login API needs `X-Requested-With: XMLHttpRequest` from curl.
- The suite is client/capture-fragile: every curl wrapper must pass the
  URL EXACTLY ONCE. Suite ALSO flakes on macOS loopback ([000] transport
  failures — validate-local.sh:3122-3126; bounded re-run, max 3 attempts
  per position; all-[000] = flake, non-transport = real).
- The suite's DRY_RUN seam is `TRAVELROUTER_DRY_RUN=1` (+ optional
  `TRAVELROUTER_DRY_RUN_PREFIX`), NOT bare `DRY_RUN=1`.
- Suite gate: monotonic; do not re-derive the 5ar(e) order. Fixed ports +
  system-wide pkill make CONCURRENT suite runs kill each other — always
  run suites sequentially.
- Comment/prose edits to validate-local.sh: use FULL-LINE old_strings. Some
  phrases occur twice with opposite truth values (`PIN gate` at :365 stale
  vs :2426 accurate) — a file-wide substring replace corrupts the accurate
  one.
- `hostapd_cli -p` takes the ctrl socket DIRECTORY, NOT the socket file
  (cost one debug round-trip 2026-09-26; §5z stubs exit 3 on it).
- 2026-09-26 hardware verification of the AP-rename brick fix is DONE
  (f3-manual.md + Pi's apconfig.log). Do not re-run those.
- PIN (2026-09-28 S06 decision): KEEP as admin-write second factor;
  GET-bucket X-Pin is GONE — do not revive.
- Suite `$LOG` (validate-local.sh:12) is defined but never written — tee
  run output into .omo/evidence/<work>/ yourself when evidence matters.