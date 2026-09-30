# RESUME — S-waves COMPLETE + S06b/S06c both committed (593-green ×5)

<!--
SESSION 2026-09-29. S06b cleanup plan (.omo/plans/s06b-cleanup.md, approved
by dual review momus+oracle) EXECUTED + VERIFIED + S06c doc-truth plan
(.omo/plans/s06c-doc-truth.md, sha256 450c8fbc...) EXECUTED + VERIFIED.
Commits 37bc744..56fd3d6: install.sh dead-/setup summary + 3 stale PIN
strings fixed; status-server.py stale Client-PIN comment fixed + Admin link
on public /; .env.example comments; service Description; README CSRF line;
validate-local.sh fetch-assert restore + served-body Admin assert + 4 prose
rewords; S06b stale PIN-guess rationale + INVENTORY row fix + tasks/PLAN.md
repoint. Suite 593/0 x3 (S06b) + 2x (S06c gate) + 2x (S06c wave-1 F-wave)
= 7+ total greens. Orchestrated start-work; every todo DoneClaim
independently AdversarialVerify-confirmed (confidence 0.93+).
-->

## Current state

- S06b COMPLETE: plan 7/7 todos ticked, F1-F4 all APPROVE, success criteria
  7/7 ticked. Ledger: .omo/start-work/ledger.jsonl; artifacts:
  .omo/evidence/s06b-cleanup/.
- Suite gate: monotonic; **593 passed, 0 failed**, 3 consecutive runs.
- Working tree: CLEAN.
- Carried follow-ups (comment-only, verified real, outside S06b's scoped
  lines): status-server.py:1138 "still a PIN guess" stale rationale;
  validate-local.sh:332-333 "absent pin is 401" mixed framing;
  validate-local.sh:1039 "(body.pin;" stale fragment. All one-line edits,
  non-behavioral.
- Owner decision: F3 stale deployment (live Pi rpi-8e21bb predates the
  S-wave) — re-provision will pick up everything now.
- Prior work travel-router-security-finishing PAUSED (its F3 landed as a
  root-cause-proven stale deployment).

## Next session steps

1. S06c DONE (c6ec7ea..56fd3d6). Remaining comment-truth residue: 18 stale
   spots — 16 in validate-local.sh (34 lines) + 2 in README.md — planned as
   S06d (.omo/plans/s06d-comment-truth.md). NB: the earlier
   ":3122-3131 (body.pin; fragment" note was a PHANTOM (that fragment was
   deleted at S06c); the real residue is the 18 spots S06d lists.
2. Owner: hardware smoke test remains optional (all S06b items server/client-local).

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
- `hostapd_cli -p` takes the ctrl socket DIRECTORY, NOT the socket file
  (cost one debug round-trip 2026-09-26; §5z stubs exit 3 on it).
- 2026-09-26 hardware verification of the AP-rename brick fix is DONE
  (f3-manual.md + Pi's apconfig.log). Do not re-run those.
- PIN (2026-09-28 S06 decision): KEEP as admin-write second factor;
  GET-bucket X-Pin is GONE — do not revive.
- Suite `$LOG` (validate-local.sh:12) is defined but never written — tee
  run output into .omo/evidence/<work>/ yourself when evidence matters.