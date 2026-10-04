# WS03 — Tier-1 forged-deauth detection (disconnect-burst watcher)

## Goal
Detect a forged-deauth/disassoc burst on the AP interface with a no-new-hardware
heuristic, write a labelled alert file, and publish a NATS `deauth-alert` —
detection only, never claimed as proof, never auto-rotating.

## Context
WS decision D3 (see `tasks/WS-decisions.md`): Tier 1 only. WPA2 management
frames are unauthenticated, so a proximate attacker can drop clients; the real
defense is PMF/WPA3 (WS02, hardware-gated). This watcher gives the operator
awareness so they can leave/switch — the posture the owner chose. D5: burst =
5 disconnects in 10 s, tunable.

## Files touched
- `roles/travel-router/assets/deauth-watch.sh` — NEW watcher
- `roles/travel-router/assets/deauth-watch.service` — NEW unit
- `roles/travel-router/install.sh` — stage + enable watcher
- `roles/travel-router/assets/travel-wan.sh` — self-suppression stamp on ap-apply/block
- `roles/travel-router/assets/validate-local.sh` — §5au battery
- `roles/travel-router/README.md` — document the detection + residual

## Pre-conditions
- [ ] WS02 committed (`4779e66`); suite green at 677/0.

## Exact changes required

### Change 1: NEW `deauth-watch.sh`
Long-lived (`Type=simple`) watcher. Behavior:
1. Event source: `iw event` by default; test seam `TRAVELROUTER_DEAUTH_EVENT_SRC`
   (a file read to EOF — makes the watcher terminate in tests). EOF/exit of the
   source ends the script nonzero so systemd restarts it.
2. Count a line as a disconnect if it contains `del station` or
   `AP-STA-DISCONNECTED` or `DISCONNECTED`.
3. Sliding window `TRAVELROUTER_DEAUTH_WINDOW_SEC` (default 10); on
   `>= TRAVELROUTER_DEAUTH_THRESHOLD` (default 5) within the window, fire.
4. Cooldown `TRAVELROUTER_DEAUTH_COOLDOWN_SEC` (default 60) between alerts;
   reset the window after firing.
5. Self-suppression: if `TRAVELROUTER_DEAUTH_SUPPRESS_FILE`
   (default `/run/travel-router/deauth-suppress`) mtime is within
   `TRAVELROUTER_DEAUTH_SUPPRESS_SEC` (default 15), skip counting — our own
   ap-apply restart / MAC block kick must not look like an attack.
6. On fire: write `TRAVELROUTER_DEAUTH_ALERT_FILE`
   (default `/run/travel-router/deauth-alert.json`) atomically:
   `{"event":"deauth-alert","count":N,"window_sec":T,"threshold":K,"host":"..","ts":"..Z"}`
   then best-effort publish `rpi.nodes.<host>.deauth-alert` (raw NATS over
   `/dev/tcp`, same idiom as `roles/base/assets/nats-announce.sh`).
   `TRAVELROUTER_DEAUTH_DRY_RUN=1` logs the publish instead of dialing.
7. Missing `iw` (and no event-src seam) -> log + exit 1.
8. Seams: all knobs env-overridable; portable mtime (`stat -f %m` || `stat -c %Y`).

### Change 2: NEW `deauth-watch.service`
    [Unit]
    Description=Travel-router forged-deauth detection (Tier 1, heuristic)
    After=hostapd-travel.service network.target
    Wants=hostapd-travel.service
    [Service]
    Type=simple
    ExecStart=/usr/local/lib/travel-router/deauth-watch.sh
    Restart=on-failure
    RestartSec=30s
    [Install]
    WantedBy=multi-user.target

### Change 3: `install.sh`
- Step (5) real-mode + dry-run: install/copy `deauth-watch.sh` to
  `/usr/local/lib/travel-router/` (0755).
- Both unit-staging loops: add `deauth-watch.service`.
- Step (9): `real_or_log systemctl enable --now deauth-watch.service`.

### Change 4: `travel-wan.sh`
- Add `deauth_suppress_stamp()` (touch `$TRAVELROUTER_DEAUTH_SUPPRESS_FILE`,
  mkdir -p, 0600) and call it immediately BEFORE the ap-apply restart
  (`"$SUDO" "$SYSTEMCTL" restart hostapd-travel.service`, ~L805) and in
  `block_kick` before the deauthenticate.

### Change 5: suite §5au
Battery with a fake event file (no hardware):
- (a) burst: threshold 3, window 5, 3 `del station` lines -> alert file written
  with `"count":3` and a dry-run publish log line.
- (b) no burst: 2 lines -> no alert file.
- (c) cooldown: a second burst within cooldown -> only one alert (file mtime /
  single publish line).
- (d) suppress: a fresh suppress stamp + a burst -> no alert.
- (e) `AP-STA-DISCONNECTED` form counts.
- (f) unit pins: `deauth-watch.service` has `Restart=on-failure` + `[Install]`;
  install.sh stages + enables it; travel-wan.sh calls `deauth_suppress_stamp`.

## Validation plan
    bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -5
    # Expected: SUITE GREEN, 0 failed

## Success criteria
- [ ] Suite green; §5au passes.
- [ ] Burst -> alert file + one NATS publish (dry-run); no-burst -> none.
- [ ] Cooldown + self-suppression both verified.
- [ ] Watcher exits nonzero on event-source EOF (systemd restarts).
- [ ] `git diff` touches only the 6 files.

## Rollback
    git checkout roles/travel-router/install.sh roles/travel-router/assets/travel-wan.sh \
      roles/travel-router/assets/validate-local.sh roles/travel-router/README.md
    git rm roles/travel-router/assets/deauth-watch.sh roles/travel-router/assets/deauth-watch.service

## Next task
After confirmed complete + committed: WS04 — status/admin deauth banner.
