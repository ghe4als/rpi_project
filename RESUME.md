# RESUME — R, U, V waves COMPLETE; suite 626/0; R01 hardware-verified

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

- **R wave COMPLETE (R01 `3f73061` + HW-verified, R02 `abd4562`, R03 `66c3fb0`,
  R04 `a773ea0`).** Root cause: Trixie arm64 first boot aborted `role-setup`
  because `roles/base/install.sh` ran `apt-get update` under `set -euo pipefail`
  with no retry while the network was not yet usable. Fixes: bounded apt retry
  then hard-fail (new `roles/base/assets/retry.sh`); advisory route+DNS wait
  before the NTP/apt gate (`NET_WAIT_SEC`); §5k3 regression battery; bootfs
  failure diagnostics (`role-setup-dump.sh` → `/boot/firmware/role-setup-debug.log`).
  R01 hardware-verified 2026-10-03 (owner re-flash came up fine); R02–R04
  suite-green only.
- **V wave COMPLETE (V01 `84bd2a2`, V02 `8cfe965`, V03 + docs commit).** Hide the
  SSID ON THE FLY. The backend already supported a hidden-only apconfig change;
  the sole blocker was `admin.html`'s Save guard (`if (!ssid && !psk) return`).
  V01 adds a dedicated "Apply hide/show now" button (enabled only when the
  broadcast checkbox differs from live state) + a confirm dialog, posting
  `{pin, hidden}`. V02 locks hidden-only argv (`ap-apply   2` / `ap-apply   0`)
  + session rotation on a hidden change (and not on a no-op). V03 documents it.
  Suite **626/0**.
- **U wave COMPLETE (commit `a20de7c`), visual-QA PASSED.**
  U03 fixed the public page's ambiguity where `<h2>Network</h2>` read like a key
  with a blank value (heading and its nested rows shared the same left edges) —
  CSS only: muted uppercase heading + rule, indented rows. U01 added the
  router's OWN `lan_ip` to the public `GET /api/status` + a "Router address"
  row (and a fetch-failure row so the section is never empty). U02 added an
  admin-only Network panel showing LAN/WAN address, WAN iface, connected SSID.
  Privacy split: `lan_ip` public, `wan_ip` admin-only (the `wan_ip` leak assert
  is preserved). Visual QA: headless-Chrome screenshot confirmed the hierarchy
  and the new row render correctly.
- The `armhf Packages` apt warning and `cc_netplan_nm_patch` are both RED
  HERRINGS (RPi OS arm64 intentionally adds armhf as a foreign arch; the
  cloud-init module warning is cosmetic on stock Trixie). Do not chase them.
- S06b, S06c, S06d ALL COMPLETE. S06d plan 5/5 todos + F1-F4 + 5 success
  criteria ticked. Ledger: .omo/start-work/ledger.jsonl; artifacts:
  .omo/evidence/s06d-comment-truth/ (6 run logs).
- Suite gate: monotonic; **593 passed, 0 failed** at the S06d gate (historical);
  **605 passed, 0 failed** post-S07 (T01/T02 x3 + independent re-run each).
- S07 LIVE BIND PROVEN on hardware 2026-10-01: fresh Bookworm flash
  rpios-20261001115252-5789 -> pi register bound it to rpi-8e21bb (first
  Bookworm flash ever to bind flash history); flashed_at/image/role/os recorded
  in the device's flashes list. Evidence: .omo/evidence/hw-2026-10-01-reflash/.
- F3 stale-deployment (security-finishing) CLOSED by the same re-flash: deployed
  /admin + all /api/admin/* reads return 200 (were 404 on the Sep-22 build).
- Working tree: CLEAN.
- 2026-10-01 docs split: the travel-router portion of README.md (10 sections,
  ~300 lines) moved verbatim into `roles/travel-router/README.md` (the role's
  full manual, + Feature parking lot for future-wave ideas). README keeps the
  roles table, threat-model paragraph, and a compact quick-start + pointer;
  suite pinned-strings preserved (Threat model, PSK-in-argv accepted risk, all
  5 TRAVELROUTER_ vars). Gate: SUITE GREEN 605/0 post-split.
- Carried follow-ups (comment-only, verified real, outside S06b's scoped
  lines): status-server.py:1138 "still a PIN guess" stale rationale;
  validate-local.sh:332-333 "absent pin is 401" mixed framing;
  validate-local.sh:1039 "(body.pin;" stale fragment. All one-line edits,
  non-behavioral.
- Owner decision: F3 stale deployment (live Pi rpi-8e21bb predates the
  S-wave) — re-provision will pick up everything now.
- S-wave HARDWARE-VERIFIED 2026-09-30 on rpi-8e21bb (fresh Bookworm travel-router flash): all S-wave HTTP routes live — GET / 200, GET /setup 404 (S04), GET /status 401 (S02), GET /admin 200, /health {"status":"ok"}, public / carries the Admin link (S06b), /api/status = {ap_ssid,wan_ssid,internet}, no device-data leak; PIN env staged 0600; wrong-PSK login 401. Captive-portal 404 on /generate_204 is CORRECT-PER-DESIGN (routed mode removes the portal drop-in; standalone-only feature).
- S07 COMPLETE (2026-09-30): the Bookworm flash-binding gap is FIXED — provision-bookworm.sh mints a Trixie-format instance_id, stamps bootfs/meta-data (after the stale-file cleanup), records it first in the pending_flashes entry, and firstrun persists it to /var/lib/rpi-project/instance_id. Commits bf45e5d (code + 11 suite asserts) and 02a6bc7 (docs + offline bind assert + RESUME flip). Suite: 605 passed / 0 failed, x3 consecutive, plus one independent post-commit re-run. Live bind proof deferred to the next natural re-flash (current Pi predates the fix; post-switch re-probe env-blocked — Pi unreachable from home LAN).
- Prior work travel-router-security-finishing PAUSED (its F3 landed as a
  root-cause-proven stale deployment).

## Next session steps

1. **NO pending code work.** R, U, V waves all COMPLETE; suite 626/0.
2. Optional hardware-verify R02–R04 (R01 already proven) + the V hide toggle on
   the next natural re-flash.
3. Comment-truth arc closed; no S06e planned.
4. Deferred (owner chose local-suite-only): a real podman arm64 integration
   test and a QEMU `raspi4b` full-boot test. Available on this Mac if wanted
   (both installed).

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