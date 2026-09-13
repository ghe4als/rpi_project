# T5 — Shift NATS IP 192.168.0.76 -> 192.168.0.151

## Goal
Rename the NATS broker IP from `192.168.0.76` to `192.168.0.151` in NATS-related
strings only (example configs, docs, role `NATS_URL` defaults). Intentionally
**skips** non-NATS uses of `.76` — those are personal services on the author's
laptop (Netdata dashboard `:19999`, Ollama `:11434`), not the broker.

## Context
The NATS broker moved to a new host (`192.168.0.151`). Everywhere NATS is named
or referenced must follow. Places that merely *co-locate* on `.76` (Netdata,
Ollama) are left alone. This is a pure textual rename; no behaviour changes.
Scoped by the user to NATS only.

## Files touched (NATS-referenced only)
- `.env.example` — line 28: `NATS_URL="nats://192.168.0.76:4222"`
- `INVENTORY.md` — line 134: `NATS_URL="nats://192.168.0.76:4222"`
- `README.md` — line 193 `NATS_URL` snippet, and line 219 `http://192.168.0.76:8222/varz # NATS broker status`
- `roles/base/assets/nats-announce.sh` — line 6: default `NATS_URL`
- `roles/base/install.sh` — line 41: default `NATS_URL`
- `roles/netdata-child/install.sh` — line 35: `nats://192.168.0.76:4222` comment

## Explicitly NOT touched (skipped on user's instruction)
- `README.md:218` `open http://192.168.0.76:19999 # Netdata (all Pis streaming in)` —
  that's the Netdata dashboard on the author's laptop, not a broker. Leave `.76`.
- `./.env` (gitignored local secrets) — 2 occurrences; not committed.

## Pre-conditions
- [ ] None. Pure textual replacement.

## Exact changes required
Replace each NATS-referenced `192.168.0.76` with `192.168.0.151` in the files above
using targeted per-line string-match edits (NOT a blind global sed), so
port numbers (4222, 8222) are preserved and only the IP octet changes. Do **not**
touch README:218 (Netdata :19999).

## Validation plan
Exact shell commands, copy-pasteable:

```bash
# 1) Every target file parses and the NATS lines are at .151
grep -n "192.168.0.151" .env.example INVENTORY.md README.md \
  roles/base/assets/nats-announce.sh roles/base/install.sh \
  roles/netdata-child/install.sh

# 2) Residual .76 in tracked+non-ignored repo — the ONLY occurrence allowed to
#    remain is README:218 (Netdata). grep -v that line before accepting:
grep -rn "192\.168\.0\.76" . --exclude-dir=.git --exclude='.env' \
  --exclude-dir=tasks | grep -v "19999"
# expected: no output (no NATS line references .76 anymore)

# 3) bash -n on the two role scripts changed (they contain code, not just comments)
bash -n roles/base/assets/nats-announce.sh && bash -n roles/base/install.sh
# expected: SYNTAX_OK for both
```

## Success criteria
- [ ] All 6 NATS-referenced occurrences now read `192.168.0.151`
- [ ] No NATS line references `.76` anymore (README:218 Netdata line may still do)
- [ ] Role scripts still pass `bash -n`
- [ ] Port numbers (4222, 8222, 11434) untouched
- [ ] `git diff` shows only the IP octet changed

## Rollback
```bash
git checkout -- .env.example INVENTORY.md README.md \
  roles/base/assets/nats-announce.sh roles/base/install.sh \
  roles/netdata-child/install.sh
```

## Notes / caveats
- `./.env` (local secrets) has 2 stray occurrences (lines 17, 19) but is
  **gitignored** and holds live credentials — do **not** commit it. Leave it for
  a local, out-of-band edit; mention it to the user.

## Next task
None after this — single mechanical rename.
