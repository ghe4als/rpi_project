# Project Plan — Wireless security: WPA3/PMF + deauth detection (WS-wave)

Last updated: 2026-10-04
Status: IN PROGRESS — WS01 ✅ + WS02 ✅ (suite 677/0); WS03 next. D1–D5 RESOLVED
(2026-10-04). See `tasks/WS-decisions.md` for the decision-of-record.
**No fork**: one role, capability-gated at install; the WPA2 render stays
byte-identical.

## Goal
Give the travel-router a real response to forged deauthentication, plus
detection so the operator knows when it happens:
1. **WPA3/PMF** on radios that support it (Pi 4 + a capable adapter) — PMF
   (802.11w) cryptographically protects deauth/disassoc, the ONLY real
   mitigation. Hardware-gated: the Zero W stays WPA2.
2. **Deauth detection + alert** — a disconnect-burst heuristic (Tier 1, no new
   hardware) and an optional monitor-mode frame counter (Tier 2, second radio).
3. **Explicitly NOT auto-rotate the SSID** on detection (see "Why not rotate").

## Threat model and honest framing
- Forged deauth/disassoc are 802.11 **management** frames; WPA2-PSK does not
  protect them, and anyone in RF range can forge one at a client.
- The real fix is **802.11w/PMF**, which WPA3 mandates. WPA2-only hardware has
  no cryptographic defense — only detection + alerting.
- The Zero W's **BCM43430A1 is WPA2-only** (no SAE, no PMF) — a **chip
  ceiling**, not a config gap (already documented in the role README).
- **Rotating the SSID is not a defense.** The attacker does not need the SSID;
  rotation drops every client and ends the admin session — a self-inflicted
  DoS. Rotation stays a manual, human-chosen action, if included at all.
- The attacker is usually proximate (deauth is often an **evil-twin
  precursor**). This plan complements the parking-lot rogue-AP / BSSID items.

## Hardware reality (the load-bearing constraint)
- The role deliberately uses the **onboard (non-USB) radio as the AP**
  (`install.sh` step (6): "first wireless whose device path does NOT contain
  `/usb`"), and the **USB adapter as WAN**. **Resolution (D1):** the Pi 4's
  onboard radio itself exposes SAE + CMAC, so WPA3 runs on the existing AP
  radio — no second adapter, no USB-as-AP inversion. The Zero W stays WPA2
  (chip ceiling); Pi 3B+ has no SAE.
- A WPA3 AP requires the radio + driver + firmware to expose: **AP mode
  (NL80211)**, **SAE**, and **PMF** — verified via `iw phy <phy> info`. The
  Pi 4 onboard radio advertises SAE and the CMAC cipher; `EXT_KEY_ID` is
  absent (yellow flag). WQ proves actual hostapd AP-mode SAE on brcmfmac.

## Design decisions (proposed)
1. **Security mode is an explicit, validated env; default backward-compatible.**
   `TRAVELROUTER_AP_SECURITY=wpa2` (default) | `wpa3-transition`
   (`wpa_key_mgmt=WPA-PSK SAE`, `ieee80211w=1`) | `wpa3` (`SAE`,
   `ieee80211w=2`). A `wpa3*` request is validated against the radio at install;
   unsupported → **fail loud**, never a silent downgrade to WPA2.
2. **Capability probe ships as a verb.** `travel-wan wifi-capabilities` reports
   AP/SAE/PMF support + band, so hardware can be checked before buying or
   provisioning. It generalizes the README's existing `iw phy` recipe.
3. **hostapd template parameterized** for key-mgmt + `ieee80211w` (rendered from
   the chosen mode); no second template file. WPA2 render stays byte-identical
   to today.
4. **Detection Tier 1 (no new hardware).** A small watcher service counts
   AP-interface disconnect events (`iw event` station-`del` with reason codes /
   hostapd station-disconnect) in a sliding window; on a burst it publishes a
   NATS event + sets a status flag. **Heuristic, labeled as such** — not proof.
5. **Detection Tier 2 (optional, second monitor-mode radio).** A lean sniffer
   counting real deauth/disassoc frames addressed to our BSSID/clients.
   Accurate; gated on a second adapter. Defer if no hardware.
6. **Alerting reuses existing plumbing.** `rpi-nats-announce` for the event
   (`rpi.nodes.<host>.deauth-alert`) + a status/admin banner. No new transport.
7. **No auto-rotation and no manual rotate UI** (D4 resolved). Rotation is not
   a defense and drops every client + the admin session. Not wired to
   detection; not offered as a control.
8. **Zero W = detection only; Pi 4 = PMF.** The plan is explicit about which
   hardware gets which capability; no feature claims the Zero can't deliver.

## Task list
- [x] WS01 — Capability probe: `travel-wan wifi-capabilities` verb (AP/SAE/PMF/band) + suite assert ✅ (§5as; suite 668/0)
- [x] WS02 — hostapd template parameterization + `TRAVELROUTER_AP_SECURITY` env + install validation (fail-loud on unsupported) + `.env.example` ✅ (§5at; suite 677/0)
- [ ] WS03 — Detection Tier 1: disconnect-burst watcher service + NATS `deauth-alert` (bounded, rate-limited)
- [ ] WS04 — Status/admin banner for the deauth alert (+ clear/expiry)
- [ ] WS05 — Suite battery (template render per mode, capability gate, detection heuristic against mocked events) + README docs (buy-guide + "rotation is not a defense")
- [ ] WS06 (DEFERRED — D3) — Detection Tier 2: monitor-mode sniffer, gated on a second radio
- [ ] WQ — Hardware QA (USER-GATED): Pi 4 **onboard radio** (D1) — provision `wpa3`, join with a PMF client, confirm `ieee80211w`; simulate a deauth and confirm the alert fires

Order: WS01 → WS02 → (WS03/WS04) → WS05 → [WS06] → WQ. One commit per task
(`feat(travel-router):` / `test:` / `docs:`).

## Decisions — RESOLVED 2026-10-04

All five owner decisions are settled; see `tasks/WS-decisions.md` for the
decision-of-record and probe evidence. Summary:

1. **D1 target hardware:** the Pi 4's **onboard radio** (phy0/BCM43455), not a
   USB adapter. Probe `iw phy` (2026-10-04) shows SAE + CMAC on Pi 4 onboard;
   Pi 3B+ and Zero W are WPA2-only. **No topology change** — the onboard radio
   is already the AP radio. WQ proves hostapd AP-mode SAE on brcmfmac.
2. **D2 default mode:** `wpa2` (zero-change). `wpa3-transition`/`wpa3` opt-in,
   fail-loud on unsupported, never a silent downgrade.
3. **D3 detection:** Tier 1 only (Zero-friendly). Tier 2 deferred.
4. **D4 manual rotate:** leave out (not a defense; self-DoS).
5. **D5 threshold:** 5 disconnects in 10 s, tunable.

Architecture: one role, capability-gated (same shape as the existing
onboard-vs-USB AP rule and default-off flag files). No fork.

## Validation gate
`bash roles/travel-router/assets/validate-local.sh` stays green after every
task; WS05 extends it. PMF/hostapd behavior and real-frame detection are not
reachable from the dry-run battery — proven on hardware in WQ.

## Explicitly out of scope
- Auto-rotating the SSID on detection (rejected: no protection, self-DoS).
- WPA3/PMF on the Zero W (chip ceiling).
- Any claim of prevention on WPA2-only hardware.

## Blocked
None. (D1–D5 resolved 2026-10-04; see `tasks/WS-decisions.md`.) WQ needs the
Pi 4 hardware — USER-GATED, tracked in `tasks/QA-next-reflash.md` patterns.
