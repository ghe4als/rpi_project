# Project Plan — travel-router role (fleet Pi provisioning)
Last updated: 2026-10-04

## Status
Current task: none — R/U/V/X/SC/WS waves ALL COMPLETE. Suite 707/0.
The only remaining open items are USER-GATED hardware QA, batched into ONE
re-flash checklist: `tasks/QA-next-reflash.md` (sweeps WQ + HQ + SQ + R/V
re-verification), plus the WS-wave WQ (Pi 4 WPA3/PMF + simulated deauth).
Open code work: NONE. WS (wireless security: WPA3/PMF + deauth detection)
shipped WS01–WS05 — see `tasks/PLAN-wireless-security.md` (CODE COMPLETE).
Last completed: WS wave ✅ (WS01 `8fd89f6`, WS02 `4779e66`, WS03 `353486d`,
WS04 `4f926ce`, WS05 `3e239b9`); SC-wave ✅ (SC01–SC06; plan `d9d10fc`);
X-wave ✅ (`02c7925` + `8418b4e`). S07 Bookworm instance_id bind shipped
(`bf45e5d` + `02a6bc7`); live bind proof deferred to the same re-flash.

WAVE R (2026-10-03) COMPLETE: first-boot resilience. A Trixie arm64 Pi4 first
boot aborted `role-setup` because `roles/base/install.sh` ran `apt-get update`
under `set -euo pipefail` with no retry while the network was not yet usable;
the unit stayed enabled and retried each boot, but the AP was never brought up.
Fixes: bounded apt retry then hard-fail (R01), advisory route+DNS wait before
the NTP/apt gate (R02), §5k3 regression lock (R03), bootfs failure diagnostics
(R04). Suite 612/0; R01 hardware-verified 2026-10-03 (owner re-flash came up
fine). R02–R04 suite-green only (hardware-verify on the next natural re-flash).

The authoritative spec for the travel-router role is
`.omo/plans/travel-router-role.md` (local, gitignored). This file is the
session index: what is done, what is next.

## Task list
- [x] T01 — Role asset configs (hostapd/dnsmasq/nftables/sysctl/NM/units) ✅ `5b1de1e`
- [x] T02 — `wan-select.sh` USB WAN autodetect + nftables render/load + state.json ✅ `6d79d02`
- [x] T03 — `travel-wan.sh` hotel-wifi SSH CLI ✅ `a3b08a0`
- [x] T04 — `status-server.py` read-only LAN status page ✅ `c35436a` (init `e2aec5c`)
- [x] T05 — `install.sh` role installer + dry-run QA seam ✅ `01c37e2`, fix `c31f47d`
- [x] T06 — `TRAVELROUTER_` env wiring into both provisioners + `.env.example` + install.sh contract alignment ✅
- [x] T07 — Docs: admin page / hotel workflow in README; INVENTORY row fixed 2026-09-29 (S06c) ✅
- [x] T08 — Local validation suite validate-local.sh ✅ (3676 lines; 593 green ×5 across waves)
- [x] F1 — Plan compliance audit (travel-router-role + S-waves + S06b/S06c) ✅
- [x] F2 — Code quality review (S-wave; S06b/S06c F2s APPROVE) ✅
- [x] F3 — Real manual QA (suite+real-surface S06b/S06c; hardware flash remains user-gated in WQ) ✅
- [x] F4 — Scope fidelity ✅

## Wave R — first-boot resilience (COMPLETE ✅)
- [x] R01 — Bounded retry for apt/network steps (`retry()` helper; base + travel-router) ✅ (uncommitted; suite 606/0) `tasks/R01-apt-bounded-retry.md`
- [x] R02 — Wait for route+DNS before the NTP/apt gate (`NET_WAIT_SEC`, advisory) ✅ (suite 606/0) `tasks/R02-wait-for-network.md`
- [x] R03 — `validate-local.sh` §5k3: apt-failure retry/hard-fail regression ✅ (suite 612/0) `tasks/R03-retry-regression-test.md`
- [x] R04 — Mirror `role-setup.log` to bootfs on failure (diagnosability) ✅ (suite 612/0) `tasks/R04-bootfs-failure-diagnostics.md`

Order: R01 → R02 → R03 (locks R01/R02) → R04 (independent, may land first).
Explicitly deferred: a real podman arm64 integration test and a QEMU `raspi4b`
full-boot test (owner chose local-suite-only for now).

## Wave U — status page: IP + hierarchy (COMPLETE ✅)
- [x] U01 — Public status: show router LAN IP (`lan_ip`) + fetch-failure row ✅ `a20de7c` `tasks/U01-public-status-lan-ip.md`
- [x] U02 — Admin page: show WAN (hotel) IP + WAN iface (`wan_*`) ✅ `a20de7c` `tasks/U02-admin-wan-ip.md`
- [x] U03 — Status page hierarchy: heading must read as a heading, not a key ✅ `a20de7c` `tasks/U03-status-page-hierarchy.md`

Context: public `GET /api/status` is privacy-minimal and the suite asserts it
leaks no IP (§5p(2)/§5ai(1)). Owner decision: expose `lan_ip` publicly (the
router's own AP-side address), keep `wan_ip` admin-only. The "empty Network"
report was a VISUAL issue (heading vs nested rows not distinguished) — U03.
Order: U01 and U03 both edit `_STATUS_HTML` (rows vs CSS) — fine either way;
U02 independent. U03 is a UI change → needs a visual-QA screenshot.

**Wave U status: COMPLETE. Committed `a20de7c`, suite 616/0, visual-QA PASSED.**

## Wave V — hide SSID on the fly (COMPLETE ✅)
- [x] V01 — Admin: "Apply hide/show now" button + confirm dialog (posts hidden-only) ✅ `84bd2a2` `tasks/V01-admin-hide-toggle.md`
- [x] V02 — Regression tests: hidden-only apconfig argv + session rotation + admin static ✅ (suite 626/0) `tasks/V02-hide-toggle-tests.md`
- [x] V03 — Docs: document the on-the-fly hide/show toggle in the role manual ✅ (suite 626/0) `tasks/V03-hide-toggle-docs.md`

Context: the backend ALREADY supports hidden-only changes end-to-end
(`/api/wan/apconfig` builds `ap-apply "" "" "2"|"0"`; `travel-wan.sh ap-apply`
fills empty SSID/PSK from live state; session self-destruct already fires on a
hidden change). The ONLY blocker is `admin.html`'s Save guard
`if (!body.ssid && !body.psk)`. Owner decisions: dedicated apply button +
confirm dialog. Order: V01 → V02 → V03.

## Wave X — connect UX / saved-passwords redesign (COMPLETE ✅)
- [x] X01 — Connect dialog becomes the credential hub (saved passwords inside; cosmetic try-progress) ✅ `02c7925` `tasks/X01-connect-ux-redesign.md`
- [x] X02 — Update suite asserts + docs for the redesign ✅ (suite 635/0)

Owner decisions: **cosmetic playback** (no backend/streaming), **focused
redesign keeping the existing look**, **dialog is the hub**. X01 executed
directly on a clean base (the pre-rebase SC work was stashed during X01 and has
since been superseded by the SC commits — the stash is gone). Suite 626/0;
visual QA passed. X02 added asserts for the new hub ids and updated §5x where
pinned labels changed.

## Wave WS — wireless security: WPA3/PMF + deauth detection (COMPLETE ✅)
See `tasks/PLAN-wireless-security.md` (CODE COMPLETE; WQ user-gated).
- [x] WS01 — `travel-wan wifi-capabilities` probe (AP/SAE/PMF/band) ✅ `8fd89f6` (§5as)
- [x] WS02 — `TRAVELROUTER_AP_SECURITY` (wpa2 default / wpa3-transition / wpa3) + fail-loud capability gate ✅ `4779e66` (§5at)
- [x] WS03 — Detection Tier 1: disconnect-burst watcher + NATS `deauth-alert` ✅ `353486d` (§5au)
- [x] WS04 — Status/admin deauth banner ✅ `4f926ce` (§5av)
- [x] WS05 — Suite battery + README (buy-guide; "rotation is not a defense") ✅ `3e239b9` (§5aw)
- [ ] WS06 (DEFERRED — D3) — Detection Tier 2: monitor-mode sniffer (second radio)
- [ ] WQ — Hardware QA (USER-GATED): Pi 4 **onboard radio** — provision `wpa3`, join a PMF client, simulate a deauth → alert fires

Honest scope: the **real** deauth defense is **PMF/WPA3**, which the Zero W's
BCM43430A1 cannot do (chip ceiling). Zero W = detection/alert only; the Pi 4's
**onboard** radio = WPA3/PMF (probe-proven SAE + CMAC; no USB adapter needed).
**SSID rotation on deauth is rejected** (no protection; self-inflicted
client/session drop). One role, capability-gated — no fork.

## Blocked
- Hardware QA — USER-GATED (needs a re-flash); batched in
  `tasks/QA-next-reflash.md`, plus the WS-wave WQ (Pi 4).

## Legacy (complete, not part of this plan)
- Tailscale role T01–T03 — done (see `tasks/T01-tailscale-role.md` `T02-env-wiring.md` `T03-documentation.md`).
- Monitor / netdata-child roles — done (see `tasks/PLAN-monitor.md`).
- NATS broker IP shift `192.168.0.76 → 192.168.0.151` — done (see `tasks/t5-nats-ip-shift.md`).

## Per-task commit style (repo protocol)
`feat(provision):` / `docs:` / `test:` / `fix:` — one commit per task, no
commits to `.env` or `inventory.yaml` (gitignored), never stage `.omo/`.