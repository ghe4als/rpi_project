# W04 — Validation battery for W01–W03 (suite green gate)

## Goal
`roles/travel-router/assets/validate-local.sh` (currently 138/0) covers the
three behavior changes so the green gate protects them.

## Files touched
- `roles/travel-router/assets/validate-local.sh` — new sections (5h)/(5i):
  - (5h) install.sh dry-run seed battery (§2 style): with WIFI_SSID/PSK in
    env → assert the redacted `dry-run: nmcli connection add` line appears,
    PSK value appears NOWHERE in output; without WIFI_SSID → assert the
    skip line and that nothing else changed vs the §2 baseline.
  - role-setup template assert: `ExecStartPost=-/usr/local/bin/rpi-nats-announce setup-complete` present in `role-setup.service.tmpl` (structural, §5 style).
  - announcer arg contract (§5d style, stub runner):
    `NATS_ANNOUNCE_DRY_RUN=1` + event arg → payload `"event":"setup-complete"`;
    bad event → rc 2; no-arg dry-run → `"event":"online"` (service mode intact).
  - provisioner filter asserts (§3 style): both provisioners contain the
    travel-router-gated WIFI_* block; no role.env leak for other roles
    (grep the gated `if [[ "$ROLE" == "travel-router" ]]` guard).

## Pre-conditions
- [ ] W01, W02, W03 complete

## Validation plan
```bash
bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -3
# Expected: suite green (>= 148 tests, 0 failures — count grows with new asserts)
```

## Success criteria
- [ ] suite green, new batteries fail loudly if W01–W03 regress

## Rollback
    git checkout roles/travel-router/assets/validate-local.sh

## Next task
W05