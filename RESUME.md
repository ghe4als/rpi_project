# RESUME — travel-router-role

Where am I right now. Source of truth for a fresh session. Checkpoint: **`6458093`**
(HEAD, clean tree). Last updated: 2026-09-14.

## Current state

**W-wave (first-boot WAN bootstrap + setup-complete announce) IMPLEMENTATION
COMPLETE — W01–W05 done, Final Wave F1/F2/F4 all APPROVE. Only WQ (user-gated
hardware QA) remains.** Plan: `tasks/PLAN-firstboot-wan.md`.
Commits: W01 `387f519` (provisioners emit WIFI_* into role.env, travel-router-
gated), W02 `3c52296` (nats-announce event arg + role-setup ExecStartPost
`setup-complete`), W03 `e6d8860` (install.sh seeds WIFI_SSID as first WAN NM
profile, unbound `ifname '*'`), W04 `abd411b` (suite batteries, **153/0
green**), W05 `ecf2892` (README first-boot simulation + NATS notifications),
spec amendment `6458093` (W03: dropped redundant `nmcli connection reload`,
documented).

What it does: first boot of a travel-router Pi now simulates the full hotel
setup — the provisioning WiFi bootstraps apt AND is seeded as the first WAN
profile; with a USB adapter the Pi comes up routed to `WIFI_SSID` with no
manual steps. NATS: `rpi.nodes.<host>.online` (existing) +
`rpi.nodes.<host>.setup-complete` (new, best-effort, on successful
role-setup). No USB adapter -> standalone, no NATS events (no broker route).

## Remaining

- **WQ (USER-GATED) — hardware QA** (tasks/WQ-hardware-qa.md): flash with
  dongle, watch BOTH NATS events on the monitor Pi (`nats sub 'rpi.nodes.>'`),
  verify routed-to-WIFI_SSID first boot + status page, forget/re-provision
  round-trip, dongle-less standalone run, Bookworm-vs-Trixie idempotency.
- Older user-gated QA HQ (hotel-setup hardware run) also still open.
- Documented residuals (pre-W): B12 STATUS_PORT unvalidated; B13
  connection-name colon truncation; B7-core malformed-role.env; RENDER_TMP
  strays.

## Gotchas carried forward

- W03 spec originally included `nmcli connection reload` after each
  `connection add` — deliberately dropped (D-Bus add already persists;
  `set -euo pipefail` would abort role-setup on spurious reload failure).
  Don't "restore" it.
- Arg-mode nats-announce must NEVER touch /run/rpi-nats-announce.sent
  (ConditionPathExists=! gating of the periodic online announce).
- Dry-run QA masks real-execution defects — keep the real-execution battery
  discipline; the suite (153/0) is the green gate.
- install.sh dry-run battery: fixture role.env WITHOUT WIFI_* exercises the
  skip path (§2); the WITH-WIFI_* seed run is §5h.
- status-server binds state.json lan_ip at startup; QA fixtures use
  127.0.0.1 on the runner (errno 49 otherwise).
- dnsmasq does NOT re-read dnsmasq.d drop-ins on SIGHUP — restart-on-toggle
  only (H03). wan-select solely owns travel-router-portal.conf.
- validate-local.sh §5e T1 depends on R9 (R9 pre-writes the drop-in; T1
  clears it first).
- Pi Zero W v1.1: 32-bit armhf Lite only (Bookworm recommended); after
  role-setup the Pi is reachable ONLY via the travel SSID or USB Ethernet.
- role.env emission must stay gated to ROLE=travel-router (suite §3 asserts
  the awk group regex byte-identical; suite §5l asserts the gate + loop).

## Older checkpoints (still true)

Hotel-setup wave H01–H06 complete (phone setup page, PIN gate, portal
hijack), checkpoint `1b69b68`. Earlier: 6-lane audit → repair wave → F-wave
F1/F2/F4 APPROVE, F3 checklist-confirmed (user hardware run = HQ).
`.omo/` gitignored — never staged. `.env`/`inventory.yaml` gitignored —
never staged.
