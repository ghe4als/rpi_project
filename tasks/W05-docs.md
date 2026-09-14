# W05 — Docs: first-boot simulation + NATS notifications

## Goal
README and `.env.example` describe the new first-boot behavior so the
procedure is discoverable.

## Files touched
- `README.md` — travel-router section: new "First-boot simulation" bullets:
  - the provisioning WiFi is used to bootstrap apt AND is seeded as the
    first WAN profile; with a USB adapter plugged in, first boot comes up
    routed to `WIFI_SSID` with no manual steps — change/forget it from the
    setup page later (`travel-wan forget <SSID>` removes the seed profile).
  - NATS notifications on `NATS_URL`: `rpi.nodes.<host>.online` (node
    announcer, retries until the broker is reachable) and
    `rpi.nodes.<host>.setup-complete` (emitted when role-setup succeeds;
    requires a WAN route to the broker — dongle-less boot publishes neither).
- `.env.example` — covered by W01's comment.

## Pre-conditions
- [ ] W01–W04 complete

## Validation plan
```bash
grep -c "setup-complete" README.md
# Expected: >= 1
bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -3
# Expected: suite still green (docs cross-check section §4)
```

## Success criteria
- [ ] README documents seed behavior + both NATS events + the forget path
- [ ] suite green

## Rollback
    git checkout README.md

## Next task
WQ (user-gated hardware QA)