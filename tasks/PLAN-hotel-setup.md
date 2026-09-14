# Project Plan — Hotel-WiFi phone setup (captive-portal + setup page)

Last updated: 2026-09-13
Status: IMPLEMENTATION COMPLETE — H01–H06 done. HQ (hardware QA) is USER-GATED.

Feature: configure the hotel WiFi from a phone with no SSH. Join the travel
SSID -> phone auto-opens the setup page (captive-portal hijack while
standalone) -> PIN -> scan -> connect. SSH/`travel-wan` stays as fallback.

Momus review: APPROVE-OKAY (ses_f621046a2ffeNKsCgzIVT5qdRu) — all file/line
anchors verified accurate.

## Design decisions (locked, from Metis consultation ses_f6219dca4ffedD5s8gaSZMiCt7)

1. **POST API is a deliberate posture change.** `status-server.py` currently
   rejects all writes (404) and `validate-local.sh:147-150` asserts no literal
   `do_POST`. H01 *deliberately retires* that textual assert and replaces it
   with behavioral asserts (unknown POST -> 404, POST /status -> 404 kept,
   PIN-denied POST -> 403, happy path via stubbed TRAVELWAN_BIN). No write
   surface smuggled under another method name.
2. **Portal hijack keys off STANDALONE (`wan_if == ""`), never "internet".**
   state.json has no internet field (internet tri-state lives only in
   travel-wan status). Hijacking during the associated-but-unauthenticated
   phase would steal the phone's probe from the HOTEL portal and break the
   documented login flow. Standalone-only keeps: standalone -> popup to our
   /setup; portal phase -> probes pass through, hotel portal pops as today;
   internet up -> drop-in removed, badge clears.
3. **Mandatory setup PIN** (user decision): `TRAVELROUTER_SETUP_PIN` becomes a
   required provisioning var. Server denies all /api/wan writes when the var
   is unset (deny-by-default). Check via `X-Setup-PIN` header +
   hmac.compare_digest; the custom header doubles as the CSRF guard
   (no CORS headers, JSON-only bodies, 8KB cap).
4. **Per-file single-owner exception**: wan-select solely owns
   `/etc/dnsmasq.d/travel-router-portal.conf` (install.sh never renders it),
   toggles only on content change, restarts (`try-restart`) dnsmasq — never
   per-tick churn. Exception documented in both scripts' headers. (dnsmasq
   does NOT re-read dnsmasq.d on SIGHUP; restart-on-toggle only.)
5. **Android probe nuance**: `dns.msftncsi.com` must be answered with the
   EXPECTED value 131.107.255.255 (not the Pi IP) so Android proceeds to the
   HTTP probe we can hijack. Only HTTP-probe domains point at the Pi.
6. **UI renders with textContent only**; the existing innerHTML XSS on `/`
   (status-server.py:159, builds rows from d.wan_ssid) is fixed in H02.
7. **PSK invariants**: never echoed in responses/UI; list-form subprocess
   (no shell=True); SSIDs rejected on leading `-`, control chars, >32 bytes.
8. **Redirect target is the numeric LAN IP** (never .local — webviews are
   unreliable with mDNS); port honored when TRAVELROUTER_STATUS_PORT != 80.
9. **No state.json schema change**; drop-in file existence is the toggle
   state. `travel-wan` CLI untouched (API reuses TRAVELWAN_BIN seam).

## Task list

- [x] H01 — POST API skeleton in status-server.py + retire `no do_POST` assert ✅ `37847b3` (suite 102/0)
- [x] H02 — /setup phone UI (setup.html asset) + fix `/` innerHTML XSS ✅ `ead073d` (suite 106/0)
- [x] H03 — captive-portal dnsmasq drop-in + wan-select toggle (standalone-keyed) ✅ `792f1b5` (suite 118/0)
- [x] H04 — probe-Host 302 redirect handler in status-server ✅ `086d81f` (suite 123/0)
- [x] H05 — mandatory PIN staging (.env.example, README, install.sh, unit env) ✅ `1f79de3` (suite 138/0)
- [x] H06 — docs + banner (README phone-first procedure, install.sh setup URL) ✅ `1b69b68` (suite 138/0)
- [ ] HQ  — Hardware QA (USER-GATED: re-provision Pi, verify popup/PIN/flow)

Order: H01 -> H02 -> H03 -> H04 -> H05 -> H06 -> HQ. Suite
(`roles/travel-router/assets/validate-local.sh`) must stay GREEN after every
task; H01 pairs the assert retirement with its behavioral replacements in the
same commit.

## Blocked

- None. (H04 needs H03's drop-in; H05 flips the auth that H01 stubs; docs last.)

## Note for the currently flashed Pi

The live Pi (rpi-8e21bb) was provisioned WITHOUT `TRAVELROUTER_SETUP_PIN`.
After H05/H06 land it must be re-provisioned (or the var hand-added to
`/boot/firmware/role/role.env` + `systemctl restart travel-router-status`)
or the setup API stays deny-by-default. Recorded in README via H06.

## Per-task commit style (repo protocol)

`feat(travel-router):` / `fix(travel-router):` / `test(travel-router):` /
`docs:` — one commit per task. Never stage `.env`, `inventory.yaml`, `.omo/`.