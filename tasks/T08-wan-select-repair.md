# T08 — Repair wan-select.sh: regdom colon, ethernet-first, load order, power_save, atomic state

## Goal
Fix the runtime defects that abort every 30s tick on a real Pi and invert the spec's
WAN preference, so wan-select actually renders + loads nftables and survives hotplug.

## Context
Audit lanes bg_d46ab658 + bg_0366335d; ledger C4/B4/B5/B6/B16. Real `iw reg get`
prints `country XX: DFS-…` — the awk keeps the colon, the reject-case never fires,
and `iw reg set "XX:"` is invalid → every tick dies before nftables when
TRAVELROUTER_AP_COUNTRY is unset (the documented default).

## Files touched
- `roles/travel-router/assets/wan-select.sh`
- `roles/travel-router/assets/nftables.conf.tmpl` (comments only)

## Exact changes (plan todo 8 is authoritative)
a. ~line 181: `_REGPROG='/^country /{sub(/:$/,"",$2); print $2; exit}'`.
b. ~line 195: `ip link set … power_save off` → `iw dev "$LAN_IF" set power_save off`.
c. ~lines 147-156: auto → `find_wan 0` (USB ethernet) FIRST, then `find_wan 1`; same
   in the unknown-value fallback; fix the log text.
d. ~lines 136,140: add `|| true` inside the substitutions so absent preferred
   adapters fall through to standalone (no set -e crash loop).
e. ~lines 219-224: copy render to $NFTABLES_TARGET BEFORE `nft -f` (copy guarded for
   dry-run); drop the `.wan-selected` fallback.
f. state.json: write tmp + `mv -f` (atomic); make read_state_json's grep non-fatal
   (`(grep … || true) | head | sed`); guard WAN_SSID + iface_addr call sites with
   `|| true` inside the substitutions.
g. nftables.conf.tmpl comments: describe the actual standalone mechanism (WAN rule
   lines are stripped via grep -v; comment headers remain).

## Pre-conditions
- [x] T01–T06 committed; audit ledger recorded. File-disjoint from T07/T09.

## Validation plan
    bash -n roles/travel-router/assets/wan-select.sh        # exit 0
    # Stub battery: stub IP/IW/NFT/NMCLI/RFKILL in /tmp/t08/bin + fake SYSFS_ROOT
    #  - auto with both adapters → wan_if=eth0 (ethernet-first)
    #  - WAN_PREFER=ethernet with no USB ethernet → rc=0, state.json mode=standalone
    #  - `country 00: DFS-UNSET` fixture → falls back US; stub log never receives "00:"/"XX:"
    #  - stub logs prove cp-before-nft order
    #  - truncated state.json → run completes and rewrites state
    #  - power_save: stub log shows `iw dev <if> set power_save off`

## Success criteria
- [ ] Battery green; `bash -n` clean; never restarts NetworkManager; never renders hostapd/dnsmasq.

## Rollback
    git checkout roles/travel-router/assets/wan-select.sh roles/travel-router/assets/nftables.conf.tmpl

## Next task
T09 (travel-wan/status-server/dnsmasq template repair) — file-disjoint, parallelizable.