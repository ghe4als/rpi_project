# R04 — Capture role-setup failure diagnostics on bootfs

## Goal
When `role-setup` fails, mirror its log (and unit status) onto the FAT bootfs
so the next failure is diagnosable from the Mac with zero ext4 tooling — the
same pattern already used for `cloud-init-debug.log`.

## Context
We could not read `/var/log/role-setup.log` from macOS (ext4 root is
unreadable), which is why the definitive apt error lines were lost. The
Trixie cloud-init `runcmd` diagnostic bundle already runs *after*
`systemctl start role-setup.service` (a blocking call for a oneshot), but it
only captured cloud-init's own logs — not role-setup's. Extending it is the
smallest fix; a systemd `ExecStopPost` covers the Bookworm path too.

## Files touched
- `user-data.tmpl` — extend the bootfs diagnostic subshell to include the
  role-setup unit status + log tail (Trixie/cloud-init path).
- `role-setup.service.tmpl` — add an `ExecStopPost` that mirrors the log on
  failure (covers both paths; survives even if cloud-init diagnostics don't).
- `provision.sh` — stale-file cleanup: also remove `role-setup-debug.log`.
- `provision-bookworm.sh` — same stale-file cleanup.

## Pre-conditions
- [ ] none (independent of R01-R03; can land first if preferred).

## Exact changes required

### Change 1: `user-data.tmpl` — extend the diagnostics subshell
In the final `runcmd` diagnostics block (the `( ... ) > /boot/firmware/cloud-init-debug.log`
subshell), add these lines just before its closing `) > ...`:

```bash
      echo
      echo "=== role-setup unit status ==="
      systemctl status role-setup.service --no-pager 2>&1
      echo
      echo "=== role-setup log tail (first-boot provisioning) ==="
      tail -200 /var/log/role-setup.log 2>&1
```

### Change 2: `role-setup.service.tmpl` — mirror the log on failure
Add, after the existing `ExecStartPost=-/usr/local/bin/rpi-nats-announce setup-complete`
line (and before `StandardOutput=append:`):

```ini
# Diagnostics: on a NON-success exit, snapshot the role log + unit state to
# the FAT bootfs (readable from macOS). Best-effort; failure ignored.
ExecStopPost=-/bin/sh -c 'if [ "${SERVICE_RESULT:-}" != "success" ]; then { echo "=== role-setup.service status ==="; systemctl status role-setup.service --no-pager; echo; echo "=== /var/log/role-setup.log (tail 300) ==="; tail -n 300 /var/log/role-setup.log; } > /boot/firmware/role-setup-debug.log 2>&1 || true; fi'
```

(One line; systemd accepts it. `SERVICE_RESULT` is exported in `ExecStopPost`
for `Type=oneshot`; it is `exit-code` on a failing script.)

### Change 3: `provision.sh` — stale cleanup
Extend the existing cleanup (currently line 218) so a stale diagnostic from a
prior flash never misleads:

```bash
rm -f "$BOOT/custom.toml" "$BOOT/firstrun.sh" "$BOOT/firstrun.log" \
      "$BOOT/wpa_supplicant.conf" "$BOOT/role-setup-debug.log"
```

### Change 4: `provision-bookworm.sh` — stale cleanup
Extend the existing cleanup (currently line 325):

```bash
rm -f "$BOOT/user-data" "$BOOT/network-config" "$BOOT/meta-data" \
      "$BOOT/role-setup-debug.log"
```

## Validation plan
```bash
# 1. Unit file is structurally valid (systemd not available on macOS; assert text).
grep -q 'role-setup-debug.log' role-setup.service.tmpl && echo "unit: OK"
# Expected: unit: OK

# 2. Provisioner cleanup includes the new file.
grep -q 'role-setup-debug.log' provision.sh provision-bookworm.sh && echo "provisioners: OK"
# Expected: provisioners: OK

# 3. Cloud-init debug bundle now tails role-setup.log.
grep -q 'role-setup log tail' user-data.tmpl && echo "user-data: OK"
# Expected: user-data: OK

# 4. Suite stays green (structural asserts may need a matching line — see R03).
bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -3
# Expected: SUITE GREEN
```

## Success criteria
- [ ] A failed `role-setup` leaves `/boot/firmware/role-setup-debug.log` on bootfs.
- [ ] Both provisioners delete a stale debug log before staging.
- [ ] The Trixie cloud-init bundle includes the role-setup log tail.
- [ ] Suite green.

## Rollback
```bash
git checkout user-data.tmpl role-setup.service.tmpl provision.sh provision-bookworm.sh
```

## Next task
Update `tasks/PLAN.md` (R-wave index) and, if desired, commit each task separately.

## Execution note (2026-10-03)
Executed with one deliberate deviation: instead of the inline `ExecStopPost`
from the plan, the SERVICE_RESULT check lives in a new staged helper
`role-setup-dump.sh` (copied to bootfs by BOTH provisioners, referenced by the
unit). Reason: systemd performs its own `$`/`${}` expansion on `Exec*` lines
and `:-` default syntax is not valid systemd specifier syntax, so an inline
`[ "${SERVICE_RESULT:-}" != success ]` risks misexpansion; a helper keeps all
shell logic in one testable place and is present even when role-setup fails
before installing anything to `/usr/local/bin`. Also updated the suite's §6
scope allowlist to permit `user-data.tmpl` and `role-setup-dump.sh` (otherwise
the scope assert fails — those files must be in-scope for R04 to land).
Validation: `bash -n` clean (helper + both provisioners); plan greps OK
(helper/unit/provisioners/user-data/cleanup); suite GREEN **612/0** with the
scope assert PASS.
