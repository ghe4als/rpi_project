# Project Plan — First-boot WAN bootstrap + NATS setup-complete (W-wave)

Last updated: 2026-09-14
Status: PLANNED — awaiting user approval to execute.

Feature: make the first boot of a travel-router Pi simulate the full hotel
setup. The provisioning WiFi (`WIFI_SSID`/`WIFI_PSK` from `.env`) bootstraps
apt during role-setup (already true) AND is then seeded as the first WAN
("hotel") profile so a plugged-in USB adapter auto-joins it. A NATS
broadcast lands on `NATS_URL` when role-setup finishes so the user can watch
for completion instead of guessing.

## Review findings (what exists today)

1. **Bootstrap WiFi usage is already correct.** `provision.sh` renders
   `network-config.tmpl` (cloud-init, wlan0 → `${WIFI_SSID}`); 
   `provision-bookworm.sh` writes an NM keyfile + `imager_custom set_wlan`.
   `role-setup.service` is `After=network-online.target`, and
   `roles/travel-router/install.sh` runs apt (base + hostapd/dnsmasq/nftables)
   BEFORE the AP interface is unmanaged (step 6), so WIFI_SSID/PSK fully
   serves the first boot. No change needed here.
2. **NATS "online" announce already exists** (`roles/base/install.sh` →
   `nats-announce.service`, publishes `rpi.nodes.<host>.online` to `NATS_URL`
   with 20×3s retries + `Restart=on-failure`). Gap: there is NO
   "setup finished" event — the user has nothing to watch for completion.
3. **Gap: bootstrap SSID never becomes a WAN profile on Trixie.** After
   install.sh unmanages the AP iface, the provisioner's client profile is
   dead (bound to wlan0 via netplan). On Trixie the dongle comes up
   standalone — no WAN — so the "full setup simulation" doesn't happen.
   (On Bookworm, `provision-bookworm.sh`'s belt-and-suspenders keyfile has
   NO interface binding, so a dongle WOULD auto-join WIFI_SSID — an
   undocumented accident; this wave makes it deterministic and documented.)
4. **role.env never carries WIFI_\*** — the provisioner env filter
   (`^(TOUCHSCREEN|NATS|OLLAMA|COOP|MOTION|TAILSCALE|NETDATA|TRAVELROUTER)_`)
   drops it, so install.sh cannot seed anything today.

## Design decisions

1. **Seed profile via `nmcli connection add`, id = WIFI_SSID, unbound
   (`ifname '*'`), autoconnect=yes.** Unbound = applies to any managed WiFi
   device (the USB dongle), never the AP radio (unmanaged in step 6). 
   Naming by SSID keeps `travel-wan forget <SSID>` and setup-page connect
   consistent. Assumption (verify at QA): netplan/cloud-init renders its
   wlan0 profile with id `netplan-wlan0-<SSID>`, so no duplicate-id clash on
   Trixie; on Bookworm the firstrun keyfile already has id=WIFI_SSID and the
   seeding SKIPS (idempotent).
2. **Skip when a profile with id=WIFI_SSID already exists** (Bookworm
   firstrun seed) — never create a duplicate.
3. **PSK handling**: passed to `nmcli` argv (same exposure as the existing
   `status-server → travel-wan → nmcli` path); DRY_RUN logs the seed command
   with the PSK redacted.
4. **setup-complete broadcast via role-setup ExecStartPost** — generic for
   every role, runs only when role-setup SUCCEEDED (`-` prefix swallows
   failure when no route to the broker exists, e.g. dongle-less boot).
   Event name is arg-constrained to `[A-Za-z0-9._-]` (subject token / PUB
   framing safety). Subject: `rpi.nodes.<host>.setup-complete`.
   The service-mode sentinel (`/run/rpi-nats-announce.sent`) is only touched
   in service mode (no arg) so the online announce keeps its semantics.
5. **Notification reality**: with the dongle present the WAN comes up
   ~30-60s after unmanage; `online` (service, retries forever) and
   `setup-complete` (ExecStartPost, ≤20×3s) both land. Dongle-less first
   boot has NO route to the broker — no NATS at all (expected, documented).
6. **AP country fallback**: `TRAVELROUTER_AP_COUNTRY` defaults to
   `WIFI_COUNTRY` when unset (falls back to `US`).
7. **role.env exposure of WIFI_PSK** is NOT a new secret on disk: the PSK is
   already plaintext on the same FAT partition (`network-config` /
   `firstrun.sh`). Gated to `ROLE=travel-router` only.

## Task list

- [x] W01 — Provisioners pass WIFI_SSID/WIFI_PSK/WIFI_COUNTRY into role.env
      (gated to travel-router) + .env.example note
- [x] W02 — `nats-announce.sh` event arg + `role-setup.service`
      `ExecStartPost=-... setup-complete`
- [x] W03 — install.sh: seed WAN bootstrap profile (WIFI_SSID) + AP_COUNTRY
      fallback + banner line
- [x] W04 — validate-local.sh batteries for W01–W03, suite green
- [x] W05 — README + banner docs (first-boot simulation + notifications)
- [ ] WQ  — Hardware QA (USER-GATED: flash + dongle, verify seed/announce)

Order: W01 → W02 → W03 → W04 → W05 → WQ. One commit per task
(`feat(provision):` / `feat(travel-router):` / `test:` / `docs:`).

## Validation gate

`bash roles/travel-router/assets/validate-local.sh` — suite currently 138/0;
must stay green after every task. W04 extends it.

## Blocked
None.