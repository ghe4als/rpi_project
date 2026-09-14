# W02 — NATS "setup-complete" broadcast at end of role-setup

## Goal
A visible notification on `NATS_URL` when first-boot role-setup finishes
successfully (subject `rpi.nodes.<host>.setup-complete`), reusing the base
role's announcer binary.

## Context
The `online` announce exists (base role, mid-role-setup) but nothing signals
completion. `role-setup.service` is the one place that knows "role install
succeeded" for EVERY role, so the hook goes there (`ExecStartPost` runs only
after a successful ExecStart for a oneshot unit). `-` prefix: best effort —
a dongle-less travel-router boot has no route to the broker and must not
fail the unit over it. The announcer retries ≤20×3s, inside the unit's
30min budget.

## Files touched
- `roles/base/assets/nats-announce.sh` — optional `$1` = event name
- `role-setup.service.tmpl` — add the ExecStartPost line

## Pre-conditions
- [ ] none (base installs the binary before role-setup's ExecStart ends)

## Exact changes required

### Change 1: nats-announce.sh — event arg + sentinel scope
After the role.env sourcing block (which currently ends the `for role_env`
loop), insert:

```bash
# Optional $1 = event override (e.g. "setup-complete" from role-setup's
# ExecStartPost). Must be a valid NATS subject token: it is framed into the
# PUB line, so spaces/newlines would corrupt the protocol framing.
ARG_EVENT=""
if [[ -n "${1:-}" ]]; then
  case "$1" in
    *[!A-Za-z0-9._-]*) log "invalid event name: $1" >&2; exit 2 ;;
    *) ARG_EVENT="$1"; NATS_ANNOUNCE_EVENT="$1" ;;
  esac
fi
```

And in the publish success path, replace the unconditional

```bash
    touch /run/rpi-nats-announce.sent 2>/dev/null || true
```
with
```bash
    if [[ -z "$ARG_EVENT" ]]; then
      touch /run/rpi-nats-announce.sent 2>/dev/null || true
    fi
```
(so the service-mode sentinel semantics are untouched; explicit event calls
never suppress the service's own "online" announce).

### Change 2: role-setup.service.tmpl
After the existing `ExecStartPost=/bin/systemctl disable role-setup.service`
line add:

```
# Broadcast "setup-complete" to NATS (best effort: '-' ignores failure when
# no route to the broker exists). The announcer's own retry loop bounds this
# to <= 20 x 3s inside the unit's 30min start budget.
ExecStartPost=-/usr/local/bin/rpi-nats-announce setup-complete
```

## Validation plan
```bash
bash -n roles/base/assets/nats-announce.sh
# Expected: no output

NATS_ANNOUNCE_DRY_RUN=1 bash roles/base/assets/nats-announce.sh setup-complete | grep -o '"event":"setup-complete"'
# Expected: "event":"setup-complete"

NATS_ANNOUNCE_DRY_RUN=1 bash roles/base/assets/nats-announce.sh 'bad event' ; echo rc=$?
# Expected: rc=2 (and an "invalid event name" line)

grep -n 'ExecStartPost=-/usr/local/bin/rpi-nats-announce' role-setup.service.tmpl
# Expected: 1 match
```

## Success criteria
- [ ] dry-run payload shows event override
- [ ] invalid event → rc 2, no publish
- [ ] no-arg invocation still touches the sentinel; arg invocation does not
- [ ] unit template carries the new ExecStartPost with `-` prefix

## Rollback
    git checkout roles/base/assets/nats-announce.sh role-setup.service.tmpl

## Next task
W03