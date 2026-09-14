# WQ — Hardware QA (USER-GATED)

## Goal
Prove the full first-boot simulation on the real Pi Zero W v1.1 + USB dongle.

## Steps
1. Flash with `ROLE=travel-router`, dongle plugged in (32-bit armhf Lite,
   Bookworm recommended), `.env` WIFI_SSID/PSK = home network, broker
   (192.168.0.151) subscribed: `nats sub 'rpi.nodes.>'` on the monitor Pi.
2. Watch for BOTH events: `...online` (during role-setup, after base) and
   `...setup-complete` (at the end). Record timestamps vs
   `/var/log/role-setup.log`.
3. After boot: join the travel SSID → status page must show
   mode=routed, wan_ssid=WIFI_SSID, internet=yes (seeded profile active on
   the dongle, WAN re-detected by wan-select within 30s).
4. From the setup page: Connect to a DIFFERENT network → confirm it wins;
   `travel-wan forget <WIFI_SSID>` removes the seed profile; re-provision
   restores it.
5. Repeat once WITHOUT the dongle: expect standalone mode, no NATS events,
   install still green (skips seeding with the "no WIFI_SSID"... no — with
   WIFI_SSID present but no adapter: profile seeds, nothing activates;
   assert log line "seeded WAN bootstrap profile" and AP still up).
6. Bookworm-vs-Trixie: if a Trixie armhf image is used, verify the seed
   skip/existence logic (`nmcli -t -f NAME connection show` — confirm no
   duplicate-id profile for WIFI_SSID).

## Success criteria
- [ ] Both NATS events observed with the dongle; none without a WAN route
- [ ] First boot ends routed to WIFI_SSID, status page correct
- [ ] Suite green; no PSK in any log (`journalctl -u role-setup` +
      /var/log/role-setup.log greps)

## Rollback
Re-provision from a pre-W commit.