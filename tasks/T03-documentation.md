# T03 — Document the tailscale role and add end-to-end usage notes

## Goal
Tell the user how to actually use the new role: generate an auth key, fill in
`.env`, flash, and approve the node in the Tailscale admin console (including
approving the advertised subnet route).

## Context
The repo's main user-facing docs are `INVENTORY.md` (inventory workflow) and
inline comments in `.env.example` / role scripts. There's no top-level README.
The most discoverable place to document a role's usage is `.env.example`
(already covered in T02) and a short note in `INVENTORY.md`'s workflow
section. This task adds a "Roles" section to `INVENTORY.md` listing all roles
and their one-line purpose + key vars, with the tailscale entry pointing at
the admin-console approval step.

## Files touched
- `INVENTORY.md` — add a "Roles" reference section.

## Pre-conditions
- [ ] T01 complete.
- [ ] T02 complete.

## Exact changes required

### Change 1: `INVENTORY.md` — add Roles section
File: `INVENTORY.md`
Action: EDIT (insert a new section after the "## CLI reference" table, before
"## Why pending_flashes?")

Insert:
```
## Roles

A role is a directory under `roles/<name>/` with an `install.sh` that runs
once on first boot via `role-setup.service`. Provisioning stages the role
tree + `role.env` onto the SD card's bootfs partition.

| Role | Purpose | Key env vars |
|---|---|---|
| `base` | Common packages + NATS node announcer. Always staged. | `NATS_URL` |
| `security-camera` | Motion + UVC webcam streamer. | `MOTION_PORT` |
| `touchscreen` | SPI 3.5" panel kiosk (cage + foot). | `TOUCHSCREEN_*` |
| `tailscale` | Remote-access VPN: subnet router + Tailscale SSH. | `TAILSCALE_AUTH_KEY`, `TAILSCALE_SUBNET` |

### Provisioning a Tailscale VPN node

1. Generate a one-time auth key at
   https://login.tailscale.com/admin/settings/keys
   (reusable: off, ephemeral: off).
2. Put it in `.env`:
   ```
   TAILSCALE_AUTH_KEY="tskey-auth-..."
   TAILSCALE_SUBNET="192.168.0.0/24"   # your LAN subnet
   ROLE="tailscale"
   ```
3. Flash + provision:
   ```bash
   ./flash.sh ~/Downloads/raspios-...img.xz /dev/disk4 tailscale
   ```
4. After the Pi boots and `tailscale-up.service` runs, approve the node AND
   its advertised subnet route in the Tailscale admin console:
   https://login.tailscale.com/admin/machines
   (Machines -> the new node -> "Approve" + "Edit route settings" -> enable
   the `192.168.0.0/24` subnet).
5. From any device on your tailnet, you can now reach LAN hosts at
   `192.168.0.x` and SSH to the Pi at its Tailscale hostname/IP.

Logs: `journalctl -u tailscale-up.service` or `/var/log/role-setup.log`.
```

## Validation plan

```bash
# 1. INVENTORY.md has the new section.
grep -c 'tailscale' INVENTORY.md
# Expected: >= 3 (table row, provisioning heading, env var mention)

# 2. Markdown still looks balanced (rough check).
grep -c '^## ' INVENTORY.md
# Expected: >= previous count + 1
```

## Success criteria
- [ ] `INVENTORY.md` has a "Roles" section with a table including tailscale.
- [ ] Provisioning steps for the tailscale role are documented.
- [ ] `git diff` shows only the INVENTORY.md addition.

## Rollback
```bash
git checkout INVENTORY.md
```

## Next task
None — project complete. Commit all three tasks.