# Project Plan — Tailscale role for remote-access VPN
Last updated: 2026-08-08

## Status
Current task: none (all complete)
Last completed: T03 ✅

## Task list
- [x] T01 — Create `tailscale` role: install.sh + systemd bring-up service ✅ DONE
- [x] T02 — Wire TAILSCALE_* vars into .env.example and provision.sh role.env staging ✅ DONE
- [x] T03 — Document the role in INVENTORY.md / README and add validation ✅ DONE

## Blocked
None.

## Decisions (from user)
- Mode: **subnet router** (advertise LAN subnet to tailnet). Exit node: off.
- Auth: **auth key in .env** (`TAILSCALE_AUTH_KEY`), staged via role.env, scrubbed after first `tailscale up`.
- Tailscale SSH: **enabled** (`tailscale up --ssh`).
- Subnet: **configurable via .env** (`TAILSCALE_SUBNET`, default `192.168.0.0/24`).
- Install method: **official installer script** (`https://tailscale.com/install.sh`).

---

# Project Plan — NATS / broker IP shift (192.168.0.76 → 192.168.0.151)
Last updated: 2026-09-13

## Status
Current task: t5 (IN PROGRESS)
Last completed: —

## Task list
- [ ] t5 — Replace every `192.168.0.76` with `192.168.0.151` across env examples, README (with Netdata/Netdata-broker lines), base role `NATS_URL` defaults, and docs. See `tasks/t5-nats-ip-shift.md`.

## Blocked
None.

## Notes
- `.env` (gitignored, local secrets) also contains 2 occurrences — NOT covered by this commit; leave for local edit.