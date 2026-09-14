# T07 — Repair install.sh: unit deployment, exec bits, template deploy, SSID charset, set -u

## Goal
Make the installer actually work on a real Pi: the four systemd units must land in
/etc/systemd/system, wan-select.sh must be executable, the nftables template must be
deployed next to wan-select.sh, and SSID validation must reject every sed render-breaker.

## Context
Full 6-lane audit (2026-09-13) confirmed these defects; the dry-run battery passed because
DRY_RUN executes nothing, so install-ordering/exec/deployment failures shipped green.
Ledger: `.omo/drafts/travel-router-role.md` (confirmed_bugs B1/B2/B3/B7).

## Files touched
- `roles/travel-router/install.sh` — only file.

## Exact changes (content-based, plan todo 7 is authoritative)
1. NEW step between (5) and (6): install the 4 unit files (wan-select.service,
   wan-select.timer, hostapd-travel.service, travel-router-status.service) to
   /etc/systemd/system/ — real: `install -m 0644`; dry-run: cp under
   `${DRY_RUN_PREFIX}/etc/systemd/system/`. BEFORE any `systemctl enable`.
2. `install -m 0644 "$ASSETS/wan-select.sh"` → 0755 (real path ~line 133) AND the
   dry-run `chmod 0644` → 0755 (~line 141); status-server.py dry-run chmod → 0755
   (~line 142, matching the real 0755).
3. Deploy `"$ASSETS/nftables.conf.tmpl"` → /usr/local/lib/travel-router/ (real +
   dry-run paths) — wan-select resolves $ASSETS from its own dir and the template
   is never there today.
4. `sid="${TRAVELROUTER_AP_SSID}"` → `sid="${TRAVELROUTER_AP_SSID:-}"` (unset must
   hit the friendly fail(), not an unbound-variable abort).
5. SSID render-breaker validation mirroring the PSK case: reject `|`, `\`, `$`, `&`
   with remediation; add explicit `*$'\n'*` newline case patterns for BOTH ssid and
   pkey (the current `*'\n'*` matches literal backslash-n, never a real newline).
6. Remove the TRAVELROUTER_AP_IFACE override (~line 151) — spec: "No new env var";
   `ap=""` start.
7. Step (8): add `real_or_log systemctl enable dnsmasq.service` before the restart.
8. MOVE the dnsmasq-inert sanity check (current step 9) to BEFORE step (8).

## Pre-conditions
- [x] T01–T06 committed; audit ledger recorded.

## Validation plan
    bash -n roles/travel-router/install.sh                 # exit 0
    TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX=/tmp/t07 \
      TRAVELROUTER_ROLE_ENV=/tmp/t07.env bash roles/travel-router/install.sh
    # Expected: rc=0 + banner; /tmp/t07/etc/systemd/system has the 4 units;
    # staged wan-select.sh mode 0755; nftables.conf.tmpl under /tmp/t07/usr/local/lib/travel-router/
    # SSID battery: SSID="a|b" / "a&b" / 'a\b' / 'a$b' → rc=1 + "remediation:";
    # run with TRAVELROUTER_AP_SSID entirely UNSET → fail() message, NOT "unbound variable"
    # PSK regression: len 7/64, '|' , '\' → rc=1 remediation (still green)

## Success criteria
- [ ] All validation commands pass; PSK never appears in any log; git diff scoped to install.sh.

## Rollback
    git checkout roles/travel-router/install.sh

## Next task
T08 (wan-select.sh repair) — file-disjoint, parallelizable.