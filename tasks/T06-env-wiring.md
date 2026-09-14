# T06 — Wire `TRAVELROUTER_*` vars into both provisioners + `.env.example` + align install.sh contract

## Status
- **DONE** — committed this session; 15/15 battery assertions green.

## Goal
Make the 8 `TRAVELROUTER_*` vars flow from `.env` on the Mac -> `role.env` on
the bootfs -> the travel-router role on the Pi, mirror the tailscale precedent
(`tasks/T02-env-wiring.md`), fix the stale ROLE enum, and align
`roles/travel-router/install.sh` to read the SAME documented var names so
config-over-SSH actually works.

## Context
Both provisioners stage `role.env` with the awk pattern
`^(TOUCHSCREEN|NATS|OLLAMA|COOP|MOTION|TAILSCALE|NETDATA)_`
(`provision.sh:190`, `provision-bookworm.sh:151`). `TRAVELROUTER_*` is missing
from BOTH, so those vars are silently dropped. `.env.example` has no
`TRAVELROUTER_` block and its ROLE enum (line 11) is stale (missing monitor,
netdata-child, travel-router, tailscale).

**Contract bug found this session (critical):** `install.sh` reads
`TRAVELROUTER_AP_NAME` (SSID) and `TRAVELROUTER_PSK`, but the documented
contract (plan todo 5 + the `.env.example` block below) is
`TRAVELROUTER_AP_SSID` / `TRAVELROUTER_AP_PSK`. The T5 dry-run battery passed
because it used the internal names; once T6 wires the documented names,
install.sh would silently fall back to a random PSK / default SSID. Align
install.sh to `AP_SSID` / `AP_PSK` in this task so the contract is ONE
coherent change. Also fix two small bugs found this session: a leading space in
the role.env default path (line 55) and an inverted base-role log (line 139).

Guardrail (plan decision D8): do NOT add `WIFI_*` to the filters — home PSK
stays off role.env.

## Files touched
- `roles/travel-router/install.sh` — var renames + 2 bug fixes.
- `provision.sh` — add `TRAVELROUTER` to awk filter (line 190).
- `provision-bookworm.sh` — add `TRAVELROUTER` to awk filter (line 151).
- `.env.example` — fix ROLE enum (line 11), append `TRAVELROUTER_` block.
- `tasks/T06-env-wiring.md` — this file.

## Pre-conditions
- [x] T05 committed + validated; cleanup commit `e4bbd71` landed.

## Exact changes required

### Change 1: install.sh — rename SSID/PSK vars + bug fixes
File: `roles/travel-router/install.sh`
Action: REPLACE (content-based, not line numbers)
- `TRAVELROUTER_AP_NAME` -> `TRAVELROUTER_AP_SSID` at the default (line ~67),
  the validate reads (line ~102/104/110/112), the hostapd render (line ~203),
  and the banner (line ~259/264).
- `TRAVELROUTER_PSK` -> `TRAVELROUTER_AP_PSK` at line ~82 and in every
  error-message string (~107/115/119/123/124).
- `ROLE_ENV="${TRAVELROUTER_ROLE_ENV:- /run/travel-router/role.env}"` ->
  `ROLE_ENV="${TRAVELROUTER_ROLE_ENV:-/run/travel-router/role.env}"` (drop the
  space so the /run path actually matches).
- `[[ "$DERIVED_BASE" -eq 0 ]] || log "no base role found ..."` ->
  `[[ "$DERIVED_BASE" -eq 0 ]] && log "no base role found ..."` (only log when
  base was NOT found).
Keep `TRAVELROUTER_AP_IFACE` (undocumented escape hatch, harmless).

### Change 2: provision.sh — extend filter
File: `provision.sh`, line ~190
`/^(TOUCHSCREEN|NATS|OLLAMA|COOP|MOTION|TAILSCALE|NETDATA)_/` ->
`/^(TOUCHSCREEN|NATS|OLLAMA|COOP|MOTION|TAILSCALE|NETDATA|TRAVELROUTER)_/`

### Change 3: provision-bookworm.sh — extend filter
File: `provision-bookworm.sh`, line ~151
Same regex extension as Change 2.

### Change 4: .env.example — ROLE enum + TRAVELROUTER block
File: `.env.example`
Action: REPLACE
- Line 11 ROLE enum:
  `One of: base, security-camera, touchscreen` ->
  `One of: base, security-camera, touchscreen, tailscale, monitor, netdata-child, travel-router`
- Append a `TRAVELROUTER_` block after the tailscale block (lines 37-44 style,
  one line of WHY per var):
  - `TRAVELROUTER_AP_SSID=""` (required; the travel network name devices join)
  - `TRAVELROUTER_AP_PSK=""` (required, 8-63 chars, A-Za-z0-9._- only; staged via role.env)
  - `TRAVELROUTER_AP_CHANNEL="6"`
  - `TRAVELROUTER_AP_COUNTRY="US"` (ISO 3166-1 alpha-2)
  - `TRAVELROUTER_LAN_CIDR="192.168.50.1/24"`
  - `TRAVELROUTER_DHCP_RANGE="192.168.50.100,192.168.50.200,12h"`
  - `TRAVELROUTER_WAN_PREFER="auto"` (auto|wifi|ethernet|none)
  - `TRAVELROUTER_STATUS_PORT="80"`

## Validation plan
    bash -n roles/travel-router/install.sh provision.sh provision-bookworm.sh
    # Expected: exit 0 all three

    git grep -n 'TRAVELROUTER_AP_NAME\|TRAVELROUTER_PSK' -- roles/travel-router/install.sh
    # Expected: no matches (all renamed)

    grep -n 'TRAVELROUTER' provision.sh provision-bookworm.sh
    # Expected: awk regex line contains TRAVELROUTER in BOTH files

    # T5 dry-run battery against DOCUMENTED names (fixture values):
    #   valid PSK -> rc=0, banner, wpa_passphrase= with 0 __AP_PSK__ left
    #   PSK <8 / >63 / '|' / '\' -> rc=1 + remediation
    #   empty AP_SSID -> rc=1 + remediation

    grep -c 'TRAVELROUTER_AP_SSID' .env.example install.sh
    # Expected: >=1 in each
    grep -c 'TRAVELROUTER_AP_PSK' .env.example install.sh
    # Expected: >=1 in each
    grep -n 'travel-router' .env.example
    # Expected: ROLE enum line 11 includes travel-router

## Success criteria
- [ ] All validation commands pass.
- [ ] No `TRAVELROUTER_AP_NAME` or bare `TRAVELROUTER_PSK` left in install.sh.
- [ ] No `WIFI_*` added to either provisioner filter.
- [ ] git diff scoped to the 4 listed files.
- [ ] T5 battery green against the documented var names (with the battery's
      fixture using `TRAVELROUTER_AP_PSK`/`TRAVELROUTER_AP_SSID`).

## Rollback
    git checkout roles/travel-router/install.sh provision.sh provision-bookworm.sh .env.example

## Next task
After confirmed complete: T07 (README + INVENTORY.md docs), then T08
(`validate-local.sh`), then F1-F4.