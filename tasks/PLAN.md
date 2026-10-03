# Project Plan — travel-router role (fleet Pi provisioning)
Last updated: 2026-10-03

## Status
Current task: none — S-wave hardware-verified; S07 shipped (Bookworm instance_id bind: bf45e5d + 02a6bc7). Remaining open: live bind proof at the next natural re-flash.
Last completed: S06c ✅ (fde41bd was the S06b tail; this cleanup commits on top)

WAVE R (2026-10-03): first-boot resilience. A Trixie arm64 Pi4 first boot
aborted `role-setup` because `roles/base/install.sh` ran `apt-get update`
under `set -euo pipefail` with no retry while the network was not yet usable;
the unit stayed enabled and retried each boot, but the AP was never brought up.
Owner decisions: **bounded retry then hard-fail**, tested via the **existing
local suite** (no container/QEMU). R01 executed + suite green 606/0 + HARDWARE
VERIFIED 2026-10-03 (owner re-flash came up fine). R02-R04 pending approval to
execute.

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

## Wave R — first-boot resilience (PROPOSED, not executed)
- [x] R01 — Bounded retry for apt/network steps (`retry()` helper; base + travel-router) ✅ (uncommitted; suite 606/0) `tasks/R01-apt-bounded-retry.md`
- [ ] R02 — Wait for route+DNS before the NTP/apt gate (`NET_WAIT_SEC`, advisory) ⬜ `tasks/R02-wait-for-network.md`
- [ ] R03 — `validate-local.sh` §5k3: apt-failure retry/hard-fail regression ⬜ `tasks/R03-retry-regression-test.md`
- [ ] R04 — Mirror `role-setup.log` to bootfs on failure (diagnosability) ⬜ `tasks/R04-bootfs-failure-diagnostics.md`

Order: R01 → R02 → R03 (locks R01/R02) → R04 (independent, may land first).
Explicitly deferred: a real podman arm64 integration test and a QEMU `raspi4b`
full-boot test (owner chose local-suite-only for now).

## Blocked
None.

## Legacy (complete, not part of this plan)
- Tailscale role T01–T03 — done (see `tasks/T01-tailscale-role.md` `T02-env-wiring.md` `T03-documentation.md`).
- Monitor / netdata-child roles — done (see `tasks/PLAN-monitor.md`).
- NATS broker IP shift `192.168.0.76 → 192.168.0.151` — done (see `tasks/t5-nats-ip-shift.md`).

## Per-task commit style (repo protocol)
`feat(provision):` / `docs:` / `test:` / `fix:` — one commit per task, no
commits to `.env` or `inventory.yaml` (gitignored), never stage `.omo/`.