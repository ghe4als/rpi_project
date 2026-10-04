# WS01 — `travel-wan wifi-capabilities` probe verb

## Goal
Add a read-only `travel-wan wifi-capabilities` verb that reports the AP
radio's WPA3/PMF capability as JSON, generalizing the manual `iw phy` check.

## Context
WS-wave decision-of-record: `tasks/WS-decisions.md`. D1 is resolved — the Pi 4
onboard radio (phy0/BCM43455) advertises SAE + CMAC; Zero W and Pi 3B+ do not.
WS01 builds the instrument so install (WS02) and the admin page can ask "can
this radio do WPA3?" without a human reading `iw phy` by hand. No behavior
change to any existing path; new verb only.

## Files touched
- `roles/travel-router/assets/travel-wan.sh` — new subcommand + seams + usage line
- `roles/travel-router/assets/validate-local.sh` — new §5as battery (stubbed `iw`)
- `roles/travel-router/README.md` — document the verb next to the `iw phy` recipe

## Pre-conditions
- [ ] Working tree clean before starting (`git status`).
- [ ] Baseline suite green at 659/0 (`bash roles/travel-router/assets/validate-local.sh`).

## Exact changes required

### Change 1: add tool seams at the top of `travel-wan.sh`
File: `roles/travel-router/assets/travel-wan.sh`
Action: INSERT alongside the existing seams (near lines 29-36).

Add:
    IW="${IW:-iw}"
    SYSFS_ROOT="${SYSFS_ROOT:-/sys}"

(`SYSFS_ROOT` mirrors `wan-select.sh:39` so tests can fake `/sys`.)

### Change 2: add the AP-iface + phy resolvers and the verb
File: `roles/travel-router/assets/travel-wan.sh`
Action: INSERT a new function block before `cmd_stealth_check` (line ~1132),
and add a dispatch case + usage line.

Behavior:
1. Resolve the AP (onboard) interface with the SAME rule as install.sh
   step (6) / wan-select.sh (3): first wireless whose
   `$SYSFS_ROOT/class/net/<if>/device` path does NOT contain `/usb`,
   fallback `wlan0`.
2. Resolve its phy via `basename "$(readlink -f "$SYSFS_ROOT/class/net/<if>/phy80211")"`
   (fallback: parse `wiphy <N>` from `iw dev <if> info`).
3. Run `"$IW" phy <phy> info` (read-only, no sudo).
4. Parse and emit one JSON line:
       {"iface":"wlan0","phy":"phy0","ap_mode":true,"sae":true,
        "pmf":true,"wpa3":true,"bands":["2.4","5"],"iw":true}
   - `ap_mode`  — `AP` present under "Supported interface modes"
   - `sae`      — "Device supports SAE with AUTHENTICATE command" OR
                  `00-0f-ac:8` in the AKM suites
   - `pmf`      — `CMAC (00-0f-ac:6)` present (the BIP/management-frame cipher)
   - `wpa3`     — derived: `sae && ap_mode`
   - `bands`    — `Band 1`->"2.4", `Band 2`->"5", `Band 4`->"6" (any subset)
   - `iw`       — false if the `iw` binary is missing/unusable
5. Exit codes: 0 = probe ran; 3 = `iw` missing/unusable (JSON carries
   `"iw":false` and a `log` line). NEVER abort, NEVER require root.

Dispatch: add `wifi-capabilities) cmd_wifi_capabilities ;;` to the case block.
Usage: add a line to the usage banner:
    travel-wan wifi-capabilities          report AP-radio WPA3/PMF support (JSON)

Style constraints (match the file):
- `json_escape` for any interpolated string; no PSK/PIN anywhere.
- `log()` messages to stderr only; JSON on stdout via `printf`.
- Never `set -e`-abort on a missing tool — degrade like `stealth-check` does.

### Change 3: suite battery §5as
File: `roles/travel-router/assets/validate-local.sh`
Action: ADD a new section at the end (after §5ar's block).

Battery (stubbed `iw`, no hardware):
- (a) Pi4-like fixture (SAE + CMAC + AP + Band1/Band2) via the `IW` seam →
      JSON has `"wpa3":true`, `"sae":true`, `"pmf":true`, `"ap_mode":true`,
      `"bands":["2.4","5"]`.
- (b) Zero-like fixture (no SAE, no CMAC) → `"wpa3":false`, `"sae":false`,
      `"pmf":false`.
- (c) AP-mode missing → `"ap_mode":false`, `"wpa3":false` even if SAE present.
- (d) `iw` unavailable (stub exits 127 / absent) → exit 3, `"iw":false`,
      no abort.
- (e) Real-repo source pins (grep the real files): the `wifi-capabilities`
      case exists in `travel-wan.sh`; the usage line exists; `IW` and
      `SYSFS_ROOT` seams exist.
- (f) Byte-identity guard: `hostapd.conf.tmpl` still contains
      `wpa=2` / `wpa_key_mgmt=WPA-PSK` (the WS02 default must not drift).

Use the existing helpers (`ok`/`bad`, `$TMP`, `$B`, the `IW=...` seam export
idiom). Fake sysfs exactly like the existing wan-select section does
(`mkdir -p "$B/sys/class/net/wlan0/wireless"` + a non-usb `device` symlink).

### Change 4: README
File: `roles/travel-router/README.md`
Action: ADD a short subsection in "WiFi security mode: WPA2 vs WPA3" noting
the verb:
    ssh pi@192.168.50.1 travel-wan wifi-capabilities
prints the AP radio's capability JSON; `wpa3:true` means SAE+AP are exposed
(install the WS02 wpa3 mode); `wpa3:false` means the radio's ceiling is WPA2.

## Validation plan
    bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -5
    # Expected: SUITE GREEN: <659+N passed>, 0 failed

    # spot-check the verb against a stub:
    printf '#!/bin/bash\necho "Device supports SAE with AUTHENTICATE command"\necho "Band 1"\n' > /tmp/iw-stub; chmod +x /tmp/iw-stub
    IW=/tmp/iw-stub bash roles/travel-router/assets/travel-wan.sh wifi-capabilities
    # Expected: one JSON line with "sae":true

## Success criteria
- [ ] Suite green (0 failed); §5as asserts pass.
- [ ] `wifi-capabilities` returns valid JSON, never aborts, never needs root.
- [ ] Missing `iw` -> exit 3 + `"iw":false` (no crash).
- [ ] WPA2 hostapd render unchanged (byte-identity guard passes).
- [ ] `git diff` touches only the 3 files listed.

## Rollback
    git checkout roles/travel-router/assets/travel-wan.sh \
      roles/travel-router/assets/validate-local.sh roles/travel-router/README.md

## Next task
After confirmed complete + committed: WS02 — template parameterization +
`TRAVELROUTER_AP_SECURITY` + fail-loud install gate (reuses this verb).
