# QA — Combined hardware verification on the next natural re-flash

Last updated: 2026-10-03
Status: READY TO RUN — one re-flash sweeps every USER-GATED QA item that is
outstanding across completed waves. No code changes; this is verification only.

This file consolidates the scattered hardware-QA gates so a single re-flash
closes all of them:

| Item | Source plan | What it proves |
|---|---|---|
| WQ   | `PLAN-firstboot-wan.md`   | first-boot WAN seed + NATS online/setup-complete |
| HQ   | `PLAN-hotel-setup.md`     | captive-portal popup + PIN + scan/connect flow |
| SQ   | `PLAN-ssid-common.md`     | `.ssid_common` pool feeds random/pick + rotation |
| R    | R02–R04 (R01 already HW-verified) | apt retry / route-wait / bootfs failure dump |
| V    | V01–V02                   | on-the-fly hide/show toggle |

R01 was hardware-verified 2026-10-03 (owner re-flash). Everything else in the
R/U/V/X/SC waves is suite-green only.

## Pre-conditions

- [ ] A fresh image is staged with `ROLE=travel-router` (Bookworm armhf
      recommended for the Zero W; Trixie for a Pi 4 — see step 6).
- [ ] `.env` has: `TRAVELROUTER_AP_SSID`, `TRAVELROUTER_AP_PSK`,
      `TRAVELROUTER_SETUP_PIN`, `TRAVELROUTER_ADMIN_PSK`,
      `WIFI_SSID` / `WIFI_PSK` (set to the home/travel test network for the
      WAN-seed probe).
- [ ] A **`.ssid_common`** file exists at the repo root with at least 3 known
      SSIDs (one per line, `#` comments allowed) — exercises SQ.
- [ ] A NATS subscriber is running on the monitor Pi:
      `nats sub 'rpi.nodes.>'` (monitor Pi = `NATS_URL` host, e.g.
      `192.168.0.151`).
- [ ] The USB WiFi dongle is plugged into the Pi for the WQ "routed" path.
- [ ] Working tree clean (`git status`).

## Step-by-step

### 1. Flash + provision

```bash
./flash.sh <bookworm-armhf-lite.img.xz> /dev/disk4 travel-router
```

Insert the card in the Pi, plug in the dongle, power on. Watch the monitor
Pi's `nats sub` window.

### 2. WQ — first-boot WAN seed + NATS events

- [ ] `...online` event arrives during role-setup (after base install).
- [ ] `...setup-complete` event arrives at the END of role-setup.
- [ ] Record both timestamps vs the Pi's `/var/log/role-setup.log`.
- [ ] Install log shows `seeded WAN bootstrap profile` for `WIFI_SSID`.
- [ ] No PSK appears in logs:
      `journalctl -u role-setup | grep -i "$WIFI_PSK"` returns nothing, and
      the same for `/var/log/role-setup.log`.

### 3. WQ — routed status

Join the travel SSID from a phone/laptop:

- [ ] `http://192.168.50.1/api/status` (no auth) returns
      `{ap_ssid, wan_ssid, internet}` with `wan_ssid = WIFI_SSID` within ~30 s.
- [ ] The seeded profile auto-joins on the dongle (WAN re-detected by
      `wan-select`).

```bash
# From the travel LAN:
curl -s http://192.168.50.1/api/status
```

### 4. WQ — connect/foget a different network

- [ ] From `/admin` (or the setup page), connect to a DIFFERENT network;
      it wins over the seed.
- [ ] `travel-wan forget <WIFI_SSID>` removes the seed profile.
- [ ] Re-provision restores it.

### 5. WQ — dongle-less boot

- [ ] Repeat the flash ONCE without the dongle: expect standalone mode, NO
      NATS events, install still green, and the AP still up. The seed profile
      should exist but not activate.

### 6. WQ — Trixie seed skip (only if a Trixie image is used)

- [ ] `nmcli -t -f NAME connection show` shows no duplicate-id profile for
      `WIFI_SSID` (netplan profile vs seed).

### 7. HQ — captive portal + setup PIN flow

Standalone (no dongle) or on first association:

- [ ] Joining the travel SSID auto-opens the setup page (or a portal popup
      points at it).
- [ ] Entering `TRAVELROUTER_SETUP_PIN` lets you scan; a wrong PIN is denied.
- [ ] Connect-to-hotel flow completes; SSH/`travel-wan` fallback still works.

### 8. SQ — `.ssid_common` pool

```bash
# Session login first (returns X-Session), then:
curl -s -H "X-Session: <token>" http://192.168.50.1/api/admin/ssids-common
```

- [ ] The endpoint lists the pool entries.
- [ ] `/api/admin/apconfig/preview` (session + PIN) returns an SSID plus
      `"source": "pool"` when the pool is non-empty.
- [ ] Apply a pool pick: the new SSID lands in
      `/etc/rpi-project/travel-router/ap-ssid` and the session rotates.
- [ ] With an EMPTY pool, preview falls back to the generated alphabet
      (`"source": "generated"`) — the zero-change default.

### 9. V — on-the-fly hide/show

- [ ] With the SSID broadcast live, use "Apply hide/show now" and confirm the
      SSID disappears from a client scan.
- [ ] Re-show it; confirm it reappears.
- [ ] Confirm the admin session rotates on the hidden change (and NOT on a
      no-op).

### 10. R — resilience spot-check (R01 already HW-proven)

- [ ] Boot without a usable WAN: the AP still comes up (route-wait advisory
      does not block forever).
- [ ] Force an apt failure (e.g. pull DNS mid-install if convenient) and
      confirm `/boot/firmware/role-setup-debug.log` is written.

## Success criteria

- [ ] All WQ, HQ, SQ, V checkboxes above ticked.
- [ ] Both NATS events observed with the dongle; none without a WAN route.
- [ ] First boot ends routed to `WIFI_SSID`; status page correct.
- [ ] No PSK in any log.
- [ ] Local suite green (run it once on the Mac before flashing to baseline):
      `bash roles/travel-router/assets/validate-local.sh`.

## Rollback

Re-provision from a pre-wave commit. Nothing here mutates the repo; this is a
verification-only checklist.

## On success

Update `RESUME.md` + the wave plans (`PLAN.md`, `PLAN-firstboot-wan.md`,
`PLAN-hotel-setup.md`, `PLAN-ssid-common.md`) to flip the USER-GATED items to
HW-verified, and drop this file (or mark it COMPLETE).
