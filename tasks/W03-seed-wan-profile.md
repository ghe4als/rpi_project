# W03 — Seed the bootstrap WAN profile (WIFI_SSID as first "hotel")

## Goal
On first boot, install.sh turns the provisioning WiFi into the first WAN
profile so a plugged-in USB adapter auto-joins it — the Pi comes up routed
to `WIFI_SSID` with zero manual steps, simulating the full hotel setup.

## Context
See PLAN-firstboot-wan.md review finding 3. Profile: `nmcli connection add`,
id = WIFI_SSID, unbound (`ifname '*'`), autoconnect=yes, WPA-PSK. The AP
radio is unmanaged (step 6), so the profile can only ever activate on a
USB dongle. `travel-wan forget <SSID>` and setup-page `connect` keep working
(they manage SSID-named profiles; a netplan-sourced profile has id
`netplan-wlan0-<SSID>` and is never touched). Idempotent: skip when a
profile with id=WIFI_SSID exists (Bookworm's firstrun.sh already seeds one).

## Files touched
- `roles/travel-router/install.sh` — new section (4b) after apt, banner line
  in (10), AP_COUNTRY fallback in the defaults block

## Pre-conditions
- [ ] W01 (WIFI_* present in role.env)

## Exact changes required

### Change 1: defaults block
Replace `: "${TRAVELROUTER_AP_COUNTRY:=US}"` with
`: "${TRAVELROUTER_AP_COUNTRY:=${WIFI_COUNTRY:-US}}"`.

### Change 2: new section (4b) between apt (step 4) and script install (step 5)

```bash
# --- (4b) Seed the bootstrap WAN profile (WIFI_SSID as the initial "hotel") --
# The provisioning WiFi (W01 wires WIFI_* into role.env) becomes the FIRST
# WAN profile: NM auto-activates it on any MANAGED wifi device (the USB
# dongle), exactly as if it had been picked on the setup page. The AP
# interface is unmanaged in step (6), so it can never activate there.
# Idempotent: skip when a profile with id=WIFI_SSID already exists (Bookworm
# firstrun.sh seeds one). DRY_RUN logs the command with the PSK redacted.
if [[ -n "${WIFI_SSID:-}" ]]; then
  if [[ "$DRY_RUN" -ne 1 ]] && nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$WIFI_SSID"; then
    log "WAN bootstrap profile '${WIFI_SSID}' already exists (provisioner seed); skipping"
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: nmcli connection add type wifi con-name '${WIFI_SSID}' ssid '${WIFI_SSID}' wifi-sec.psk <redacted> connection.autoconnect yes"
  elif [[ -n "${WIFI_PSK:-}" ]]; then
    nmcli connection add type wifi ifname '*' con-name "$WIFI_SSID" ssid "$WIFI_SSID" \
      wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PSK" connection.autoconnect yes
    log "seeded WAN bootstrap profile '${WIFI_SSID}' (autoconnect, any managed wifi device)"
  else
    nmcli connection add type wifi ifname '*' con-name "$WIFI_SSID" ssid "$WIFI_SSID" \
      connection.autoconnect yes
    log "seeded WAN bootstrap profile '${WIFI_SSID}' (open network)"
  fi
else
  log "no WIFI_SSID in role.env — skipping WAN bootstrap profile (standalone AP first boot)"
fi
```

AMENDED (post-review, F1 ses_f601cd424ffesCDAhXpIhRYR7m): the original spec
block included `nmcli connection reload` after each real-mode `nmcli
connection add`. Dropped deliberately: `connection add` registers the profile
with the NM daemon via D-Bus AND persists it, so a reload is redundant; and
under install.sh's `set -euo pipefail` a spurious reload failure would abort
role-setup for no benefit. Committed code (e6d8860) is the source of truth.

### Change 3: banner (step 10) — add one line before the NOTE lines
```bash
[[ -n "${WIFI_SSID:-}" ]] && echo "  WAN bootstrap: '${WIFI_SSID}' profile seeded (auto-connects on USB adapter)"
```

## Validation plan
```bash
bash -n roles/travel-router/install.sh
# Expected: no output

TRAVELROUTER_DRY_RUN=1 TRAVELROUTER_ROLE_ENV=/dev/null WIFI_SSID=HomeWifi WIFI_PSK=dummypsk \
  DRY_RUN_PREFIX=/tmp/tr-w03 bash roles/travel-router/install.sh 2>&1 | grep -E "seeded WAN bootstrap|dry-run: nmcli connection add"
# Expected: the redacted dry-run seed line (PSK never printed)

TRAVELROUTER_DRY_RUN=1 TRAVELROUTER_ROLE_ENV=/dev/null DRY_RUN_PREFIX=/tmp/tr-w03b \
  bash roles/travel-router/install.sh 2>&1 | grep "no WIFI_SSID"
# Expected: 1 line (skips cleanly without WIFI_*)
```

## Success criteria
- [ ] dry-run battery shows redacted seed line; no PSK in any output
- [ ] without WIFI_SSID the install proceeds (standalone, as today)
- [ ] AP_COUNTRY falls back to WIFI_COUNTRY when unset
- [ ] dry-run prefix tree otherwise unchanged from today's §2 battery

## Rollback
    git checkout roles/travel-router/install.sh

## Next task
W04