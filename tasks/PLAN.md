# Project Plan — travel-router role (fleet Pi provisioning)
Last updated: 2026-09-13

## Status
Current task: T06 (IN PROGRESS — env wiring + install.sh contract alignment)
Last completed: T05 ✅ (commit `01c37e2`, env-prefix fix `c31f47d`)

The authoritative spec for the travel-router role is
`.omo/plans/travel-router-role.md` (local, gitignored). This file is the
session index: what is done, what is next.

## Task list
- [x] T01 — Role asset configs (hostapd/dnsmasq/nftables/sysctl/NM/units) ✅ `5b1de1e`
- [x] T02 — `wan-select.sh` USB WAN autodetect + nftables render/load + state.json ✅ `6d79d02`
- [x] T03 — `travel-wan.sh` hotel-wifi SSH CLI ✅ `a3b08a0`
- [x] T04 — `status-server.py` read-only LAN status page ✅ `c35436a` (init `e2aec5c`)
- [x] T05 — `install.sh` role installer + dry-run QA seam ✅ `01c37e2`, fix `c31f47d`
- [ ] T06 — `TRAVELROUTER_` env wiring into both provisioners + `.env.example` + install.sh contract alignment ⏳ IN PROGRESS
- [ ] T07 — Docs: README + INVENTORY.md role entries and travel workflow
- [ ] T08 — Local validation suite `roles/travel-router/assets/validate-local.sh` (green gate)
- [ ] F1 — Plan compliance audit
- [ ] F2 — Code quality review
- [ ] F3 — Real manual QA (USER-GATED: hardware flash + boot + hotel portal)
- [ ] F4 — Scope fidelity

## Blocked
None.

## Legacy (complete, not part of this plan)
- Tailscale role T01–T03 — done (see `tasks/T01-tailscale-role.md` `T02-env-wiring.md` `T03-documentation.md`).
- Monitor / netdata-child roles — done (see `tasks/PLAN-monitor.md`).
- NATS broker IP shift `192.168.0.76 → 192.168.0.151` — done (see `tasks/t5-nats-ip-shift.md`).

## Per-task commit style (repo protocol)
`feat(provision):` / `docs:` / `test:` / `fix:` — one commit per task, no
commits to `.env` or `inventory.yaml` (gitignored), never stage `.omo/`.