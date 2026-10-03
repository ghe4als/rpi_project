# V03 — Document the on-the-fly hide/show toggle

## Goal
Document the "Apply hide/show now" control in the travel-router role manual so
the hide-on-the-fly workflow (and its consequences) is discoverable.

## Context
The role manual (`roles/travel-router/README.md`) documents the AP-rename flow
("Changing the router's own network (AP rename)") and the session self-destruct
on rename/hide. V01 adds a way to change the broadcast state without renaming;
the manual should say so, including the reconnect requirement.

## Files touched
- `roles/travel-router/README.md` — AP-rename section gains a "Hide/show
  without renaming" subsection.

## Pre-conditions
- [ ] V01 complete (the control exists).

## Exact changes required

### Change 1: add a subsection under the AP-rename heading
In `roles/travel-router/README.md`, in the "Changing the router's own network
(AP rename)" section, add after the existing paragraph (before the
`#### WiFi security mode: WPA2 vs WPA3` subsection):

```markdown
#### Hide/show the SSID without renaming

The AP-settings card's **Apply hide/show now** button toggles SSID broadcast
without changing the network name or password: uncheck "Broadcast this SSID"
and apply to hide, recheck and apply to show again. The button only enables
when the checkbox differs from the live state, and a confirmation dialog warns
that all connected devices drop and must re-add the network (hidden networks
never appear in scans). Hiding is an identity change, so your admin session
also ends — log in again on the same SSID. The rename Save path is unchanged;
this is a separate, single-purpose control.
```

### Change 2 (optional): note in the security-features list
If the manual's "Session self-destruct on AP rename/hide" bullet doesn't
already mention the standalone toggle, leave it — it already covers "rename or
hide". No change needed there.

## Validation plan
```bash
grep -qF 'Apply hide/show now' roles/travel-router/README.md && echo "docs OK"
# Suite has a docs cross-check (§4) that pins some strings — ensure it stays green.
bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -3
# Expected: SUITE GREEN
```

## Success criteria
- [ ] Manual documents the hide/show toggle and its reconnect consequences.
- [ ] Suite green (incl. the §4 docs cross-check).

## Rollback
```bash
git checkout roles/travel-router/README.md
```

## Next task
Update `tasks/PLAN.md` (Wave V index); commit V01→V02→V03 in order.

## Execution note (2026-10-03)
Executed as specified. Added the "Hide/show the SSID without renaming"
subsection under the AP-rename heading. Suite §4 docs cross-check stays green
(pins README.md + .env.example vars only). Suite GREEN 626/0.
