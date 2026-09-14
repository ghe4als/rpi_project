# H05 — Mandatory PIN staging (.env.example, README, install.sh, unit env)

## Goal
`TRAVELROUTER_SETUP_PIN` becomes a REQUIRED provisioning var: validated by
install.sh like the SSID/PSK, staged to the status unit's environment, and
documented — flipping H01's deny-by-default gate to always-on auth for every
properly provisioned Pi. Zero provisioner changes (both provisioners'
TRAVELROUTER_ regex already matches the new var — verified).

## Context
User decision: mandatory PIN. Metis analysis: the AP PSK already gates LAN
membership, so the PIN is defense-in-depth against someone you shared the AP
key with — mandatory per user choice, deny-by-default when absent (H01).
Suite coupling (Metis R7): §3's var loop (validate-local.sh:117) and §4's
README-<->.env.example cross-check (line 127-129) must move in the SAME
commit: README documents the var -> .env.example must carry it in the same
commit or the suite goes red.

## Files touched
- `.env.example` — new required var + comment
- `roles/travel-router/install.sh` — PIN validation + env into the status unit
- `roles/travel-router/assets/travel-router-status.service` — EnvironmentFile
- `README.md` — TRAVELROUTER_SETUP_PIN var row entry (triggers §4 cross-check)
- `roles/travel-router/assets/validate-local.sh` — §3 loop + §5g auth asserts

## Pre-conditions
- [x] H04 committed; suite GREEN
- [x] H01's PIN gate reads env `TRAVELROUTER_SETUP_PIN` and denies when empty
      (this task makes the var always present at provision time)

## Exact changes required

### Change 1: .env.example
File: `.env.example`
Action: INSERT into the travel-router block (after AP_PSK/AP_CHANNEL…):
    # Setup-page PIN — REQUIRED. Gates the phone setup UI (/setup + /api/wan).
    # 4-12 chars, A-Za-z0-9 (kept deliberately phone-keyboard-friendly).
    TRAVELROUTER_SETUP_PIN="1234"
(with a real default placeholder consistent with the file's existing style).

### Change 2: install.sh — validation + env delivery
File: `roles/travel-router/install.sh`
Action: EXTEND the existing SSID/PSK validation block + status-unit wiring.
- Validation: SETUP_PIN must be non-empty and match `^[A-Za-z0-9]{4,12}$`;
  empty/malformed -> friendly fail BEFORE any system mutation (same
  fail-fast pattern as the SSID checks; note the B7-core residual treats
  malformed role.env as late-validation — do not widen that here, the PIN
  joins the SAME early validation block as AP_SSID/AP_PSK).
- Delivery: the status unit needs the var in its environment. The unit
  (Change 3) gains `EnvironmentFile=-/run/travel-router/role-env.d/travel-router.env`;
  install.sh writes that file at install time containing ONLY
  `TRAVELROUTER_SETUP_PIN="<value>"` (mode 0600 — it is a secret; /run is
  tmpfs so it does not persist on disk) AND `systemctl set-property`-free
  restart of the status unit already happens later in install.sh's wiring
  step (the unit is enabled --now after the file exists — ordering: write
  the env file BEFORE the enable --now of travel-router-status.service).
  The existing `WAN_TOOL`/state env for the status unit: if the unit
  currently relies on defaults, leave those alone; only the PIN env file is
  new.

### Change 3: travel-router-status.service
File: `roles/travel-router/assets/travel-router-status.service`
Action: INSERT under [Service]:
    EnvironmentFile=-/run/travel-router/role-env/travel-router-setup.env
(missing file tolerated with `-` so the unit still starts on un-provisioned
or pre-H05 Pis — deny-by-default then applies in status-server).

### Change 4: README var row
File: `README.md`
Action: EXTEND the TRAVELROUTER_* env row in the .env table:
`TRAVELROUTER_SETUP_PIN` — setup-page PIN, required, gates the phone UI.
(This README mention + .env.example entry land in the SAME commit — §4
cross-check.) Full procedure docs are H06; this is the var-table row only.

### Change 5: validate-local.sh
File: `roles/travel-router/assets/validate-local.sh`
Action: EXTEND §3 loop + add §5g.
- §3 loop (line 117): add `SETUP_PIN` to the var list.
- §5g battery:
  - install.sh dry-run with malformed PIN (short/empty/`-`/non-alnum) ->
    friendly fail + nonzero rc (existing breaker-battery pattern).
  - dry-run staging: `$pfx/run/travel-router/role-env/travel-router.env`
    exists, contains the PIN, mode 0600 (staged-tree assert in the existing
    render battery).
  - service file contains the EnvironmentFile line.
  - status-server behavior (server fixture from §5d): PIN set -> wrong pin
    403, right pin 200 on /api/wan/connect (stub logs argv); PIN unset ->
    403 even with right-body pin (deny-by-default re-assert).

## Validation plan
    bash roles/travel-router/assets/validate-local.sh
    # Expected: SUITE GREEN, +5 asserts over H04 count

    python3 -m py_compile roles/travel-router/assets/status-server.py   # untouched but sanity
    bash -n roles/travel-router/install.sh
    # Expected: exit 0

    grep -c 'TRAVELROUTER_SETUP_PIN' .env.example README.md
    # Expected: 1 in each (plus README prose references in H06)

## Success criteria
- [ ] A flash with .env lacking SETUP_PIN fails install.sh with a clear message
- [ ] A provisioned Pi has the PIN live in the status unit env (0600, tmpfs)
- [ ] Deny-by-default intact when the env file is absent
- [ ] git diff scoped to the five touched files

## Rollback
    git checkout .env.example roles/travel-router/install.sh roles/travel-router/assets/travel-router-status.service README.md roles/travel-router/assets/validate-local.sh

## Next task
H06 — docs + banner (blocked by H05).