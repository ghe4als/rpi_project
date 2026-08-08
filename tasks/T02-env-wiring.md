# T02 — Wire TAILSCALE_* vars into .env.example and provision.sh role.env staging

## Goal
Make `TAILSCALE_AUTH_KEY`, `TAILSCALE_SUBNET`, `TAILSCALE_HOSTNAME`, and
`TAILSCALE_UP_TIMEOUT_SEC` flow from `.env` on the Mac -> `role.env` on the
bootfs partition -> `role.env` sourced by the tailscale role on the Pi.

## Context
`provision.sh` stages `role.env` by writing every env var whose name matches
the awk pattern `^(TOUCHSCREEN|NATS|OLLAMA|COOP|MOTION)_` (provision.sh:180).
`TAILSCALE_*` vars are NOT in that pattern, so they'd be silently dropped.
We need to add `TAILSCALE` to the prefix list. We also document the new vars
in `.env.example` so the user knows what to set.

## Files touched
- `.env.example` — document `TAILSCALE_*` vars.
- `provision.sh` — add `TAILSCALE` to the env-prefix awk pattern.

## Pre-conditions
- [ ] T01 must be complete (the role must exist for these vars to do anything).

## Exact changes required

### Change 1: `.env.example` — add TAILSCALE block
File: `.env.example`
Action: EDIT (append before the `# chicken-cam role only` block, after the
NATS block)

Before (existing tail of .env.example):
```
# All roles: NATS broker for node self-announcement.
NATS_URL="nats://192.168.0.76:4222"

# chicken-cam role only: piChick AI service config.
```

After:
```
# All roles: NATS broker for node self-announcement.
NATS_URL="nats://192.168.0.76:4222"

# tailscale role only: remote-access VPN subnet router.
# Generate a one-time auth key at https://login.tailscale.com/admin/settings/keys
# (Auth keys -> Generate auth key -> reusable: off, ephemeral: off, tags: optional).
# The key is staged to the Pi via role.env and scrubbed after first `tailscale up`.
TAILSCALE_AUTH_KEY=""
TAILSCALE_SUBNET="192.168.0.0/24"
TAILSCALE_HOSTNAME=""        # optional; defaults to the Pi's hostname
TAILSCALE_UP_TIMEOUT_SEC="120"

# chicken-cam role only: piChick AI service config.
```

### Change 2: `provision.sh` — add TAILSCALE to role.env prefix pattern
File: `provision.sh`
Action: EDIT

Before (provision.sh:180):
```
  for var in $(env | awk -F= '/^(TOUCHSCREEN|NATS|OLLAMA|COOP|MOTION)_/ {print $1}'); do
```

After:
```
  for var in $(env | awk -F= '/^(TOUCHSCREEN|NATS|OLLAMA|COOP|MOTION|TAILSCALE)_/ {print $1}'); do
```

## Validation plan

```bash
# 1. .env.example has the new vars.
grep -c TAILSCALE .env.example
# Expected: 4 (four TAILSCALE_* assignments)

# 2. provision.sh pattern includes TAILSCALE.
grep 'TAILSCALE' provision.sh
# Expected: the one-line awk pattern with TAILSCALE in the alternation

# 3. provision.sh still parses.
bash -n provision.sh
# Expected: exit 0, no output
```

## Success criteria
- [ ] `.env.example` contains all four `TAILSCALE_*` vars with helpful comments.
- [ ] `provision.sh` awk pattern includes `TAILSCALE`.
- [ ] `bash -n provision.sh` passes.
- [ ] `git diff` shows only the two intended edits.

## Rollback
```bash
git checkout .env.example provision.sh
```

## Next task
After confirmed complete: execute T03 (documentation + final validation).