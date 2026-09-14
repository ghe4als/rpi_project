# RESUME — travel-router-role

Where am I right now. Source of truth for a fresh session. Checkpoint: **`1b69b68`**
(HEAD, clean tree). Last updated: 2026-09-13.

## Current state

**Hotel-setup wave (H01–H06) IMPLEMENTATION COMPLETE — only HQ (user-gated
hardware QA) remains.** Phone-configurable hotel WiFi: join travel SSID ->
captive-portal popup opens the PIN-gated setup page -> scan -> connect.
Plan: `tasks/PLAN-hotel-setup.md` (Momus APPROVE-OKAY); commits H01 `37847b3`,
H02 `ead073d`, H03 `792f1b5`, H04 `086d81f`, H05 `1f79de3`, H06 `1b69b68`.
Validation suite **SUITE GREEN: 138/0** (`roles/travel-router/assets/validate-local.sh`).

What the wave added (on top of the earlier F-wave-approved role, checkpoint
`f85c04a`): POST API `/api/wan/*` (PIN-gated, CSRF-guarded, list-form
subprocess, deny-by-default), `setup.html` phone UI (textContent-only; `/`
page XSS fixed), captive-portal probe hijack (standalone-keyed dnsmasq
drop-in, restart-on-toggle-only, msftncsi answered with expected constant),
probe-Host 302 -> /setup, mandatory `TRAVELROUTER_SETUP_PIN` staging
(0600 tmpfs EnvironmentFile), phone-first README + banner.

## Remaining

- **HQ (USER-GATED) — hardware QA**: re-provision the live Pi
  (rpi-8e21bb was flashed WITHOUT the PIN) per README "Provisioning the
  travel-router Pi"; verify auto-popup, PIN gate, scan/connect, hotel-portal
  flow, badge-clear lag. Record the result in tasks/PLAN-hotel-setup.md.
- Documented residuals: B12 STATUS_PORT unvalidated; B13 connection-name
  colon truncation; B7-core malformed-role.env late-validation; nftables
  hardcodes tcp/80; innerHTML status fields not HTML-escaped (FIXED in H02
  for the `/` page); RENDER_TMP/STATE_TMP strays on mid-script abort.

## Gotchas carried forward

- Dry-run QA masks real-execution defects — keep the §5b/§5e real-execution
  battery discipline for any new role work.
- Pi Zero W v1.1: 32-bit armhf Lite only (Bookworm recommended); after
  role-setup the Pi is reachable ONLY via the travel SSID or USB Ethernet.
- status-server binds the state.json lan_ip at startup; QA fixtures must use
  127.0.0.1 on the runner (192.168.50.1 bind fails errno 49).
- dnsmasq does NOT re-read dnsmasq.d drop-ins on SIGHUP — restart-on-toggle
  is the only correct mechanism (H03).
- wan-select solely owns /etc/dnsmasq.d/travel-router-portal.conf (the H03
  per-file single-owner exception); install.sh stages its template only.
- validate-local.sh §5e T1 depends on R9: R9 is standalone and pre-writes
  the drop-in; T1 clears it first (see the comment before T1).

## Older checkpoints (still true)

Full earlier arc: 6-lane audit → 4 CRITICAL + ~10 MAJOR defects in T1–T6 →
repair wave → F-wave verdicts F1/F2/F4 APPROVE, F3 (original role hardware
QA) superseded by HQ above. `.omo/` gitignored — never staged. `.env`/
`inventory.yaml` gitignored — never staged.