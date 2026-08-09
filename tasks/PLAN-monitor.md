# Project Plan — monitor + netdata-child roles
Last updated: 2026-08-08

## Status
Current task: none (all complete)
Last completed: T04 ✅

## Task list
- [x] T01 — Create `monitor` role: NATS server (JetStream + :8222 monitoring) + Netdata parent ✅ DONE
- [x] T02 — Create `netdata-child` role: Netdata agent streaming to parent ✅ DONE
- [x] T03 — Wire `NETDATA_*` vars into `.env.example` + both provisioners ✅ DONE
- [x] T04 — Document both roles in README.md + INVENTORY.md ✅ DONE

## Decisions (from user)
- Monitor Pi: Pi 4, Bookworm armhf (or arm64).
- NATS: JetStream persistence ON, HTTP monitoring port :8222, no auth.
- Monitoring: Netdata parent/child streaming.
- Fleet rollout: separate `netdata-child` role, opt-in via role.deps.
- netdata-child declares `base` in role.deps (so monitored Pis also announce over NATS).
- Shared `NETDATA_STREAM_API_KEY` (UUID) in .env, staged to both roles via role.env.
- `NETDATA_PARENT_HOST` defaults to host extracted from `NATS_URL`.