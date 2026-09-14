# RESUME — travel-router-role

Where am I right now. Source of truth for a fresh session. Checkpoint: **`c31f47d`**.
Last updated: 2026-09-13. **Purpose of this run: investigation + status review, then
PLANNING of the remaining fixes in a new session.** No new implementation done beyond
the one bug fixed below.

## Working tree triage (do this FIRST — the tree is unexplained)

```
deleted:    RESUME.md                 <- this file; was deleted uncommitted, now recreated
deleted:    tasks/PLAN.md             <- was project plan index (HEAD had it)
modified:   tasks/PLAN-travel-router.md   <- benign hash-fix (T1/T4 commit labels); uncommitted
untracked:  tasks/t5-nats-ip-shift.md   <- NATS IP-shift tracker; was pre-staged by an earlier session
```
Per repo protocol, a dirty tree with no handoff stops all work. Decide per item:
keep/discard/commit. **Do not build on it before a decision.** The only safe, self-
contained change already shipped this session is the `install.sh` fix (below, committed).

## What's done + committed (T1–T5, verified this session)

- **T1** — role assets, `5b1de1e`. **12 files** under `roles/travel-router/assets/`
  (hostapd/dnsmasq/nftables[flush-first]/sysctl templates, NM `unmanaged.conf`,
  `wan-select.service`+`.timer`, `hostapd-travel.service`, `travel-router-status.service`,
  `wan-select.sh`, `travel-wan.sh`, `status-server.py`). Structural asserts all OK:
  `[Install]`/`WantedBy=multi-user.target` in wan-select.service, `timers.target` in the
  timer, `ExecStart=/usr/sbin/hostapd /etc/hostapd/hostapd-travel.conf`, and wan-select
  has NO `restart NetworkManager` (required by spec).
- **T2** — `wan-select.sh` USB WAN autodetect + per-run nftables render/load + state.json,
  `6d79d02`.
- **T3** — `travel-wan.sh` hotel-wifi SSH CLI, `a3b08a0`.
- **T4** — `status-server.py` stdlib read-only status page, `c35436a` (initial `e2aec5c`).
- **T5** — `install.sh`, `01c37e2` **+ fix `c31f47d`** (this session).

### T5 fix found & committed THIS session (`c31f47d`)
- **Bug:** every env var `install.sh` read was misspelled `TRAWELROUTER_*` (missing the
  `V`; `TRAVEL`→`TRAWEL`). 24 occurrences, 10 distinct tokens.
- **Impact:** (1) the `TRAVELROUTER_DRY_RUN=1` test seam never activated → apt/systemctl
  ran for real → dry-run battery died at `apt-get: command not found` on macOS;
  (2) on a real Pi the script read a *different namespace* than T6 stages into role.env and
  than the sibling assets use → `AP_PSK`/`SSID`/`COUNTRY`/etc. would silently fall back to
  defaults (config-over-SSH defeated).
- **Fix:** `TRAWELROUTER`→`TRAVELROUTER` (single `replaceAll`). `bash -n` clean; diff
  scoped to `install.sh` only (+23/−23).
- **T5 acceptance now GREEN (re-verified):** nftables first non-comment line = `flush
  ruleset`; apt line 146 < NM-unmanaged write line 191; `systemctl restart dnsmasq`
  present (line 228); stock `systemctl enable hostapd.service` ABSENT (dedicated
  hostapd-travel only). Dry-run battery: happy path rc=0 + banner + 7 artifacts under
  `DRY_RUN_PREFIX`; PSK <8 / >63 / `|` / `\` all rc=1 with remediation; valid PSK renders
  `wpa_passphrase=` with 0 unsubstituted `__AP_PSK__`.

## Plan checkbox staleness (housekeeping, not code)

In `.omo/plans/travel-router-role.md` the T1–T8 checkboxes (lines 84/102/118/127/136/
146/155/165) are **still all `[ ]` unchecked** even though T1–T5 are committed. Flip
T1–T5 to `[x]` before/after the remaining work. Separate concern from the code.

## SEPARATE finding: `t5` NATS IP-shift is INCOMPLETE (tracker wrongly says COMPLETED)

`tasks/t5-nats-ip-shift.md` claims COMPLETED at `ff4f76e`, but `192.168.0.76` still
remains in tracked files:
- **`README.md:218`** — `open http://192.168.0.76:19999` (Netdata dashboard). **IN
  SCOPE** — the t5 tracker explicitly named "the Netdata / Netdata-broker lines"; its
  sibling `:219` was already shifted to `192.168.0.151:8222`. GENUINE MISS → flip to
  `192.168.0.151:19999`.
- `tasks/T02-env-wiring.md:32,40` — historical/legacy task-doc NATS_URL=.76. Likely an
  out-of-scope archive; decide (leave vs. correct for consistency).
- Confirmed CORRECT already: `roles/base/install.sh:41` and `:50`,
  `roles/base/assets/nats-announce.sh:6` (`.151`), `.env.example:28` (`.151`).
- NOTE: `.env` (gitignored) also has 2 `.76` occurrences — intentionally left for a local
  edit per the tracker; not in scope, don't commit.

## What's LEFT (dependency order)

### T6 — `TRAVELROUTER_` env wiring into BOTH provisioners + `.env.example` — **NOT DONE**
- `provision.sh:190` — awk role.env filter regex is
  `^(TOUCHSCREEN|NATS|OLLAMA|COOP|MOTION|TAILSCALE|NETDATA)_`; **add `TRAVELROUTER`**.
- `provision-bookworm.sh:151` — SAME regex; **add `TRAVELROUTER`**.
- `.env.example` — **no `TRAVELROUTER_` block exists**; append one mirroring the tailscale
  block (lines 41–44): `TRAVELROUTER_AP_SSID` (required), `TRAVELROUTER_AP_PSK` (required,
  8–63), `TRAVELROUTER_AP_CHANNEL` (default 6), `TRAVELROUTER_AP_COUNTRY` (default US),
  `TRAVELROUTER_LAN_CIDR` (default 192.168.50.1/24), `TRAVELROUTER_DHCP_RANGE`
  (default 192.168.50.100,192.168.50.200,12h), `TRAVELROUTER_WAN_PREFER`
  (auto|wifi|ethernet|none, default auto), `TRAVELROUTER_STATUS_PORT` (default 80).
- `.env.example:11` ROLE enum is **stale**: `One of: base, security-camera, touchscreen`.
  Should include `tailscale, monitor, netdata-child, travel-router` (pre-existing
  staleness; T6 spec also mandates fixing this line).
- Guardrail from plan: do NOT add `WIFI_*` to the filter (home PSK stays off role.env).
- Spec: `.omo/plans/travel-router-role.md` lines 146–153.

### T7 — Docs: README + INVENTORY.md — **NOT DONE** (0 occurrences of `travel-router`)
- README: roles-table row + `TRAVELROUTER_` env-table row + fix ROLE enum line 83 +
  "Provisioning the travel-router Pi" usage section (buy / home-test / hotel / recovery;
  mirror tailscale/monitor section style).
- INVENTORY.md: roles-table row.
- Spec: lines 155–163.

### T8 — `roles/travel-router/assets/validate-local.sh` — **DOES NOT EXIST**
- Full agent-executable QA battery (bash -n / py_compile / shellcheck-skippable; render
  checks incl. nftables `flush ruleset`; provisioner filter cross-check both provisioners;
  docs cross-check; structural unit asserts; seam asserts; `git diff --stat` scope assert).
- Spec: lines 165–172. Exit 0 end-to-end, write
  `.omo/evidence/travel-router-role/task-8-travel-router-role.log`.

### F1–F4 — final wave (after T8) — **NOT STARTED**
F1 plan compliance audit · F2 code quality · F3 real manual QA (**USER-GATED**: hardware
flash+boot+hotel portal — runs in real life; verifier only confirms the checklist exists) ·
F4 scope fidelity.

## Recommended next session order
1. Triage the dirty tree (decide the 4 items above) — protocol-recommended first.
2. Flip plan checkboxes T1–T5 → `[x]` in `.omo/plans/travel-router-role.md`.
3. Fix `README.md:218` `.76`→`.151` (the t5 gap) — tiny, ships the "completed" t5 clean.
4. T6 → T7 → T8 (T8 is the green gate) → F1–F4.
5. After each task: `git add`/`commit` per repo protocol (one commit per task,
   conventional style `feat(travel-router):`/`docs:`/`test:`).

## Why the last run stopped
Investigation + status review were requested ("review t5 and plan, what's left"), then
"record findings in RESUME.md". Only the one `install.sh` fix was implemented (a bug this
session *found* while verifying T5, so fixing before re-running its battery was in-scope
and low-risk); it is committed + verified green. Nothing else was built. T6/T7/T8/F1–F4
remain unplanned-for-implementation by design — the new session plans the fixes.

## Gotchas carried forward
- W13: re-run the check after every edit — "fixed" is a claim, "suite passes" is a fact.
- On Pi Zero W v1.1 the first boot is slow (ARMv6 single core + full apt); use a 32-bit
  armhf Lite image (Bookworm recommended); the Pi is reachable ONLY via its travel SSID or
  a USB Ethernet adapter after role-setup (see hotel_wifi_bridge.txt:442-448).
- `.env` + `inventory.yaml` are gitignored — never stage them; both still hold `.76`
  (local secrets), intentionally left.
- `tasks/PLAN-travel-router.md` is mislabeled: it actually holds the T5 task content,
  not a plan index. `tasks/PLAN.md` (the real index) is deleted uncommitted.
