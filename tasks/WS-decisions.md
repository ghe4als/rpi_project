# WS — Owner decisions (RESOLVED 2026-10-04)

Companion to `tasks/PLAN-wireless-security.md`. The WS wave is no longer
PROPOSED-blocked; all five decisions are settled and recorded here. This file
is now the decision-of-record for WS.

## Architecture decision: capability-gated feature, NOT a fork

**Decision: one codebase, one `travel-router` role, capability-gated at
install/runtime. Do NOT fork for WPA2 vs WPA3 hardware.**

Rationale (grounded in the existing code):
- The repo already handles hardware divergence without forking:
  - onboard-vs-USB AP selection: `install.sh` (first wireless whose
    `/sys/class/net/<if>/device` path does NOT contain `/usb`) and
    `wan-select.sh` (`SYSFS_ROOT`, same rule).
  - arm64 vs armhf: provisioning layer (`flash.sh` picks image/provisioner).
  - every security feature: a default-off flag file under
    `/etc/rpi-project/travel-router/`.
- The WPA2↔WPA3 delta is **one radio capability bit** (SAE yes/no). A fork
  would duplicate `install.sh`, `hostapd.conf.tmpl`, `status-server.py`,
  `travel-wan.sh`, the 659-assert suite, and both provisioners — every future
  fix written twice — to encode a single bit.
- Model: parameterize `hostapd.conf.tmpl` for the key-mgmt/PMF fields, render
  from `TRAVELROUTER_AP_SECURITY`, and **lock the WPA2 render byte-identical**
  so the default path cannot regress.
- Ongoing tax: hostapd edits carry a 3-mode matrix + suite render-per-mode
  cases. `wan-select.sh`, `status-server.py`, provisioners, and nftables stay
  single-source and hardware-agnostic.

## D1 — WPA3/PMF target hardware: RESOLVED

**Decision: the Pi 4's ONBOARD radio (phy0 / BCM43455). No USB adapter, no
topology change.**

Probe evidence (owner ran `iw phy` on physical hardware, 2026-10-04):

| Radio | SAE advertised | CMAC cipher | Bands | Verdict |
|---|---|---|---|---|
| **Pi 4 phy0 (onboard)** | **yes** — "Device supports SAE with AUTHENTICATE command" | **yes** (`CMAC 00-0f-ac:6`) | 2.4 + 5 GHz | **WPA3/PMF candidate** |
| Pi 3B+ phy0 | no | no | 2.4 only | WPA2-only |
| Zero W BCM43430A1 | no | no | 2.4 only | WPA2-only (chip ceiling) |

Why this matters: the Pi 4's onboard radio is already the AP radio under the
existing selection rule, so WPA3 needs **no second radio and no USB-as-AP
inversion** (which would have cost onboard-WAN). The plan's original
"Pi 4 + USB adapter" assumption is retired.

**Caveats carried into WQ (must be proven on hardware, not assumed):**
- `iw phy` advertising SAE ≠ hostapd proving AP-mode SAE on `brcmfmac`.
  Broadcom AP-mode SAE has historically been finicky. WQ starts hostapd in
  `wpa3` mode and joins a real PMF client — that is the proof.
- `EXT_KEY_ID` is **absent** from the Pi 4 extended features (the README
  recipe looked for it). Yellow flag, not red — CMAC is the more direct PMF
  signal. WQ resolves it.
- The capability gate must probe **the AP radio specifically** (the onboard
  phy), not "any radio."

## D2 — Default `TRAVELROUTER_AP_SECURITY`: RESOLVED

**Decision: `wpa2` default.** `wpa3-transition` / `wpa3` are explicit
per-device opts. A `wpa3*` request is validated against the AP radio at
install; unsupported → **fail loud**, never a silent downgrade. The WPA2
render stays byte-identical to today.

## D3 — Detection scope: RESOLVED

**Decision: Tier 1 only** (disconnect-burst heuristic, no new hardware —
Zero-friendly; WS03 + WS04). Tier 2 (monitor-mode sniffer) is deferred to a
future wave gated on a second radio.

## D4 — Manual "rotate SSID now" control: RESOLVED

**Decision: leave rotation out.** Rotation is not a defense (the attacker does
not need the SSID) and it drops every client + the admin session — a
self-inflicted DoS. No new UI.

## D5 — Tier 1 burst threshold: RESOLVED

**Decision: 5 disconnects in 10 seconds, tunable.** Default constant + suite
fixture numbers use this. Revisit after field data.

## Consequences for the wave

- WS01 (`wifi-capabilities` verb) is unblocked and first — it builds the
  instrument that produced the D1 probe by hand.
- WS02 parameterizes the template + env + fail-loud gate.
- WS03/WS04 detection + banner.
- WS05 suite battery + README.
- WS06 (Tier 2) **deferred**.
- WQ hardware QA: Pi 4 + onboard radio, `wpa3` mode, real PMF client join,
  simulated deauth → alert fires.
