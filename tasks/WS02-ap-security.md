# WS02 — `TRAVELROUTER_AP_SECURITY` + hostapd template parameterization

## Goal
Add a validated `TRAVELROUTER_AP_SECURITY` env (wpa2 default | wpa3-transition |
wpa3) that parameterizes the hostapd key-mgmt + PMF fields, with a fail-loud
capability gate; the wpa2 render stays byte-identical.

## Context
WS-wave decision D2 (see `tasks/WS-decisions.md`). WS01 shipped the
`wifi-capabilities` probe this gate consumes. Default `wpa2` = zero change;
`wpa3*` is opt-in and validated against the AP radio at install — unsupported
hardware fails loud, never a silent downgrade.

## Files touched
- `roles/travel-router/assets/hostapd.conf.tmpl` — parameterize key-mgmt + 802.11w
- `roles/travel-router/install.sh` — mode parse + capability gate + render substitutions
- `roles/travel-router/assets/travel-wan.sh` — ap-apply renders the same placeholders
- `.env.example` — document the var
- `roles/travel-router/assets/validate-local.sh` — §5at battery + fix §5as(f)

## Pre-conditions
- [ ] WS01 committed (`8fd89f6`); suite green at 668/0.
- [ ] Working tree: only the earlier docs reconciliation is dirty.

## Exact changes required

### Change 1: template
File: `roles/travel-router/assets/hostapd.conf.tmpl`
REPLACE the trailing security block so it reads:
    # AP security — mode rendered from TRAVELROUTER_AP_SECURITY:
    #   wpa2            -> WPA-PSK, no 802.11w (default)
    #   wpa3-transition -> WPA-PSK SAE, ieee80211w=1
    #   wpa3            -> SAE, ieee80211w=2
    wpa=2
    wpa_passphrase=__AP_PSK__
    wpa_key_mgmt=__AP_KEY_MGMT__
    auth_algs=1
    rsn_pairwise=CCMP
    wpa_pairwise=CCMP
    __AP_IEEE80211W__
(`__AP_IEEE80211W__` is a full-line marker: deleted for wpa2, replaced otherwise.)

### Change 2: install.sh
File: `roles/travel-router/install.sh`
- After the AP_COUNTRY default (~L92): `: "${TRAVELROUTER_AP_SECURITY:=wpa2}"`.
- After the PSK validation (~L121): parse the mode into
  `ap_key_mgmt` + `ap_ieee80211w_expr`; unknown value -> `fail` with remediation.
  If mode != wpa2, run the gate:
  `cap_json="$(IW="${IW:-iw}" SYSFS_ROOT="${SYSFS_ROOT:-/sys}" bash "${TRAVELROUTER_CAP_PROBE:-$ASSETS/travel-wan.sh}" wifi-capabilities 2>/dev/null || true)"`
  and `fail` unless it contains `"sae":true`.
- In the step (7) render sed (~L453): add
  `-e "s|__AP_KEY_MGMT__|${ap_key_mgmt}|g"` and `-e "$ap_ieee80211w_expr"`.

### Change 3: travel-wan.sh ap-apply
File: `roles/travel-router/assets/travel-wan.sh`
- Compose `m_key_mgmt="__AP_""KEY_MGMT__"` and `m_ieee80211w="__AP_""IEEE80211W__"`
  alongside the existing `m_*` markers (the dunder composition avoids the §2
  staged-file placeholder check).
- Read `r_security="${TRAVELROUTER_AP_SECURITY:-wpa2}"`; map to key-mgmt +
  ieee80211w expr (same table as install.sh); unknown -> log + return 1.
- Add both substitutions to the ap-apply render sed (~L734).

### Change 4: .env.example
File: `.env.example`
Add under the other `TRAVELROUTER_AP_*` rows:
    TRAVELROUTER_AP_SECURITY="wpa2"                  # wpa2 (default) | wpa3-transition | wpa3; wpa3* requires an SAE-capable AP radio (fail-loud)

### Change 5: suite
File: `roles/travel-router/assets/validate-local.sh`
- REPLACE §5as(f): assert the RENDERED default conf
  (`$pfx/etc/hostapd/hostapd-travel.conf`) has `wpa_key_mgmt=WPA-PSK`,
  `wpa=2`, both CCMP lines, and NO `ieee80211w` / NO `SAE`. (The template no
  longer carries literal `WPA-PSK`, so the old template grep is invalid.)
- ADD §5at battery:
  - (a) default (no var): rendered conf = WPA-PSK, no ieee80211w.
  - (b) wpa3-transition + SAE stub: `wpa_key_mgmt=WPA-PSK SAE`, `ieee80211w=1`.
  - (c) wpa3 + SAE stub: `wpa_key_mgmt=SAE`, `ieee80211w=2`.
  - (d) wpa3 + no-SAE stub: rc=1 + remediation; no conf drift.
  - (e) `wpa4` (invalid): rc=1 + remediation.
  - (f) structural: both render sites substitute the new markers
    (grep `__AP_KEY_MGMT__` in install.sh; `m_key_mgmt` in travel-wan.sh).
  Stub the probe via `TRAVELROUTER_CAP_PROBE` pointing at a heredoc script
  that echoes the WS01 JSON shape.

## Validation plan
    bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -5
    # Expected: SUITE GREEN, 0 failed

## Success criteria
- [ ] Suite green; §5at + revised §5as(f) pass.
- [ ] Default (wpa2) render behavior unchanged (WPA-PSK, no PMF).
- [ ] wpa3* on a non-SAE radio fails loud with remediation; no silent downgrade.
- [ ] ap-apply leaves no unsubstituted placeholders.
- [ ] `git diff` touches only the 5 files.

## Rollback
    git checkout roles/travel-router/assets/hostapd.conf.tmpl \
      roles/travel-router/install.sh roles/travel-router/assets/travel-wan.sh \
      .env.example roles/travel-router/assets/validate-local.sh

## Next task
After confirmed complete + committed: WS03 — Tier-1 disconnect-burst watcher.
