# W01 — Provisioners pass WIFI_SSID/PSK/COUNTRY into role.env (travel-router)

## Goal
`roles/travel-router/install.sh` can read the provisioning WiFi credentials
from `role.env` so it can seed the first WAN profile (W03).

## Context
The role.env writer filter (`/^(TOUCHSCREEN|NATS|OLLAMA|COOP|MOTION|
TAILSCALE|NETDATA|TRAVELROUTER)_/`) drops every `WIFI_*` var today. The PSK
is already plaintext on the same bootfs partition (`network-config` /
`firstrun.sh`), so exporting it adds no new exposure. Gated to
`ROLE=travel-router` so other roles' role.env stays unchanged.

## Files touched
- `provision.sh` — role.env writer block (the `{ ... } > "$ROLE_ENV_FILE"`
  section near the end, after the existing `for var in $(env | awk ...)`)
- `provision-bookworm.sh` — same block in its role.env writer
- `.env.example` — comment in the travel-router block noting the new use

## Pre-conditions
- [ ] none

## Exact changes required

### Change 1: provision.sh role.env writer
Inside the `ROLE_ENV_FILE` brace group, AFTER the existing for-loop, add:

```bash
  # travel-router bootstraps its WAN from the provisioning WiFi: install.sh
  # seeds it as the first NM profile ("hotel simulation"). The PSK is already
  # plaintext on this partition (network-config), so no new exposure.
  if [[ "$ROLE" == "travel-router" ]]; then
    for var in WIFI_SSID WIFI_PSK WIFI_COUNTRY; do
      val="${!var}"
      printf '%s=%q\n' "$var" "$val"
    done
  fi
```

### Change 2: provision-bookworm.sh role.env writer
Same addition, same position (its writer also uses `printf '%s=%q\n'`).

### Change 3: .env.example
In the TRAVELROUTER_ block, add a comment line:
`# WIFI_SSID/WIFI_PSK are also passed to the travel-router role and are used
as the FIRST WAN (hotel) profile on first boot.`

## Validation plan
```bash
bash -n provision.sh provision-bookworm.sh
# Expected: no output

DRY_RUN source-level check:
grep -A4 'travel-router' provision.sh | grep -q 'WIFI_SSID' && echo OK
# Expected: OK (both provisioners)
```

## Success criteria
- [ ] `bash -n` clean on both provisioners
- [ ] role.env written for a travel-router flash contains WIFI_SSID/PSK/COUNTRY
- [ ] role.env for any other role does NOT contain WIFI_*

## Rollback
    git checkout provision.sh provision-bookworm.sh .env.example

## Next task
W02