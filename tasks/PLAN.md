# Project Plan — travel-router role (fleet Pi provisioning)
Last updated: 2026-09-29

## Status
Current task: none — S06b + S06c complete; next open items are the optional hardware smoke (tasks/WQ-hardware-qa.md) or a Pi re-flash (live Pi predates the S-wave)
Last completed: S06c ✅ (fde41bd was the S06b tail; this cleanup commits on top)

The authoritative spec for the travel-router role is
`.omo/plans/travel-router-role.md` (local, gitignored). This file is the
session index: what is done, what is next.

## Task list
- [x] T01 — Role asset configs (hostapd/dnsmasq/nftables/sysctl/NM/units) ✅ `5b1de1e`
- [x] T02 — `wan-select.sh` USB WAN autodetect + nftables render/load + state.json ✅ `6d79d02`
- [x] T03 — `travel-wan.sh` hotel-wifi SSH CLI ✅ `a3b08a0`
- [x] T04 — `status-server.py` read-only LAN status page ✅ `c35436a` (init `e2aec5c`)
- [x] T05 — `install.sh` role installer + dry-run QA seam ✅ `01c37e2`, fix `c31f47d`
- [x] T06 — `TRAVELROUTER_` env wiring into both provisioners + `.env.example` + install.sh contract alignment ✅
- [x] T07 — Docs: admin page / hotel workflow in README; INVENTORY row fixed 2026-09-29 (S06c) ✅
- [x] T08 — Local validation suite validate-local.sh ✅ (3676 lines; 593 green ×5 across waves)
- [x] F1 — Plan compliance audit (travel-router-role + S-waves + S06b/S06c) ✅
- [x] F2 — Code quality review (S-wave; S06b/S06c F2s APPROVE) ✅
- [x] F3 — Real manual QA (suite+real-surface S06b/S06c; hardware flash remains user-gated in WQ) ✅
- [x] F4 — Scope fidelity ✅

## Blocked
None.

## Legacy (complete, not part of this plan)
- Tailscale role T01–T03 — done (see `tasks/T01-tailscale-role.md` `T02-env-wiring.md` `T03-documentation.md`).
- Monitor / netdata-child roles — done (see `tasks/PLAN-monitor.md`).
- NATS broker IP shift `192.168.0.76 → 192.168.0.151` — done (see `tasks/t5-nats-ip-shift.md`).

## Per-task commit style (repo protocol)
`feat(provision):` / `docs:` / `test:` / `fix:` — one commit per task, no
commits to `.env` or `inventory.yaml` (gitignored), never stage `.omo/`.