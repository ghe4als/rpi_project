# H06 — Docs + banner: phone-first hotel procedure, setup URL in install banner

## Goal
The README's travel-router section leads with the phone flow (join SSID ->
auto-popup -> PIN -> connect), SSH demoted to fallback; install.sh's first-
boot banner prints the setup URL; the live-Pi re-provision note is recorded.

## Context
Metis slicing task 6. All behavior is complete after H05; this task is
truth-in-documentation so a fresh reader provisions and operates the
feature without session context. The status-server docstring and page copy
were made truthful in H01/H02; only README + banner remain.

## Files touched
- `README.md` — "Provisioning the travel-router Pi" rewrite + env rows
- `roles/travel-router/install.sh` — banner
- `INVENTORY.md` — role-table row mention (if it names the manage path)

## Pre-conditions
- [x] H01–H05 committed; suite GREEN

## Exact changes required

### Change 1: README — phone-first procedure
File: `README.md`
Action: EDIT the "Provisioning the travel-router Pi" section (keep structure:
what-to-buy / env / home test / hotel / standalone / recovery).
- New step ordering after flash: join travel SSID -> phone auto-opens the
  setup page (captive-portal hijack, standalone only) or open
  `http://192.168.50.1/setup` manually -> enter SETUP_PIN -> pick hotel
  network -> connect -> if the hotel uses a portal, finish THAT login from
  the same device (probes pass through during the portal phase by design;
  the auto-popup intentionally does NOT steal it) -> badge/status clears.
- SSH/`travel-wan` demoted to "fallback / recovery path" (keep the exact
  commands — CLI stays untouched by design).
- Document: PIN is mandatory; forgot-PIN recovery = re-provision (or hand
  edit `/boot/firmware/role/role.env` + restart the status unit).
- Document the DNS-badge lag honestly: after connect, the phone's "no
  internet" badge can linger up to a couple of minutes (OS re-probe cadence;
  drop-in TTL is 10s) — the status page at 192.168.50.1 is the source of
  truth.
- Note the live-Pi migration: a Pi provisioned BEFORE this feature lacks the
  PIN -> re-provision to get the phone setup feature.

### Change 2: install.sh banner
File: `roles/travel-router/install.sh`
Action: EDIT the final log banner.
Before (current banner, line ~262): manage via SSH phrasing.
After:
    log "setup:      join the travel WiFi, then open http://<lan_ip>/setup (PIN required)"
    log "status:     http://<lan_ip>"
    log "fallback:   ssh pi@<lan_ip> (travel-wan CLI unchanged)"
(lan_ip from the same variable the banner already uses).

### Change 3: README/INVENTORY cross-checks stay green
File: `README.md` (+ `INVENTORY.md` if its travel row mentions management)
Action: VERIFY the §4 docs cross-check still passes: every
`TRAVELROUTER_[A-Z_]+` string in README exists in .env.example (H05 landed
SETUP_PIN in both). If INVENTORY's row mentions SSH-only management, add
"phone setup page" phrasing.

## Validation plan
    bash roles/travel-router/assets/validate-local.sh
    # Expected: SUITE GREEN (docs cross-check §3/§4 must pass with the new var)

    grep -c '192.168.50.1/setup' README.md
    # Expected: >= 2

    grep -c 'setup:' roles/travel-router/install.sh
    # Expected: >= 2 (banner lines)

## Success criteria
- [ ] A reader can provision + use the feature from README alone
- [ ] Suite GREEN (cross-checks intact)
- [ ] No stale "SSH only" claims anywhere in the travel-router docs

## Rollback
    git checkout README.md roles/travel-router/install.sh

## Next task
HQ — hardware QA (USER-GATED; re-provision the live Pi per README).