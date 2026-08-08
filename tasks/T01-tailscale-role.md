# T01 — Create `tailscale` role: install.sh + systemd bring-up service

## Goal
Add a new `roles/tailscale/` role that installs Tailscale from the official
repo and brings it up on first boot as a **subnet router** with **Tailscale
SSH** enabled, authenticating via a one-time auth key from `role.env`.

## Context
The project provisions Raspberry Pi OS via cloud-init + a one-shot
`role-setup.service` that runs `/boot/firmware/role/install.sh`. The dispatcher
in `provision.sh` execs the selected role's `install.sh`. Roles run base first
(`bash /boot/firmware/role/base/install.sh`). `role.env` on the bootfs
partition carries role-specific vars (populated from `.env` by `provision.sh`).

User decisions:
- Mode: subnet router (advertise `TAILSCALE_SUBNET`, default `192.168.0.0/24`).
- Auth: auth key in `.env` as `TAILSCALE_AUTH_KEY`; scrub from Pi after first up.
- Tailscale SSH: enabled.
- Install: official `https://tailscale.com/install.sh`.

## Files touched
- `roles/tailscale/install.sh` — NEW. Installs Tailscale, writes a bring-up
  service that runs `tailscale up --ssh --advertise-routes=<subnet> --auth-key
  <key>`, scrubs the key after success.
- `roles/tailscale/assets/tailscale-up.service` — NEW. systemd oneshot that
  waits for network, runs the up command, scrubs the auth key.
- `roles/tailscale/assets/tailscale-up.sh` — NEW. Wrapper script invoked by
  the service; does the actual `tailscale up` + key scrub + status logging.
- `roles/tailscale/role.deps` — NEW. Declares `base` so provision.sh stages it.

## Pre-conditions
- [ ] none (first task)

## Exact changes required

### Change 1: `roles/tailscale/role.deps`
File: `roles/tailscale/role.deps`
Action: CREATE

Content:
```
# Roles staged before this one by provision.sh (one name per line).
base
```

### Change 2: `roles/tailscale/install.sh`
File: `roles/tailscale/install.sh`
Action: CREATE

Behaviour:
1. `set -euo pipefail`, `DEBIAN_FRONTEND=noninteractive`.
2. `ROLE_DIR`/`ASSETS` resolution (same idiom as other roles).
3. Run base role: `bash /boot/firmware/role/base/install.sh` if executable
   (idempotent — base already ran if a prior role called it).
4. Source `role.env` if present (`/boot/firmware/role/role.env`, fallback
   `/boot/role/role.env`) with `set -a; source; set +a`.
5. Defaults:
   - `: "${TAILSCALE_SUBNET:=192.168.0.0/24}"`
   - `: "${TAILSCALE_HOSTNAME:=$(hostname)}"` (optional override)
   - `: "${TAILSCALE_UP_TIMEOUT_SEC:=120}"`
6. Install Tailscale via official installer:
   ```
   if ! command -v tailscale >/dev/null 2>&1; then
     curl -fsSL https://tailscale.com/install.sh | sh
   fi
   ```
   Guard with `command -v` so re-runs don't re-download.
7. Ensure IP forwarding is enabled (subnet router requires it). Write a
   sysctl drop-in and apply:
   - `/etc/sysctl.d/99-tailscale.conf`:
     ```
     net.ipv4.ip_forward = 1
     net.ipv6.conf.all.forwarding = 1
     ```
   - `sysctl --system` (best-effort; logs if it fails).
8. Install the bring-up service + wrapper from assets:
   - `install -m 0755 "$ASSETS/tailscale-up.sh" /usr/local/bin/tailscale-up`
   - Render `tailscale-up.service` substituting `__SUBNET__`, `__HOSTNAME__`,
     `__TIMEOUT__` into `/etc/systemd/system/tailscale-up.service`.
9. `systemctl daemon-reload`, `systemctl enable tailscale-up.service`.
   Do NOT start it inline — it must wait for `network-online.target` which
   the service's `After=` handles. (Starting inline could race the network
   and fail the auth-key join.)
10. Echo final status line with the Tailscale IP / admin URL hint.

### Change 3: `roles/tailscale/assets/tailscale-up.sh`
File: `roles/tailscale/assets/tailscale-up.sh`
Action: CREATE

Behaviour:
1. `set -euo pipefail`.
2. Source `role.env` (same two-path idiom).
3. Defaults: `TAILSCALE_SUBNET`, `TAILSCALE_HOSTNAME`.
4. Require `TAILSCALE_AUTH_KEY` — if missing/empty, log a clear error telling
   the user to set it in `.env` and exit 0 (don't fail the unit; we want the
   Pi to still boot and be reachable on LAN so the user can fix it).
5. Build the `tailscale up` args:
   - `--ssh`
   - `--advertise-routes="$TAILSCALE_SUBNET"`
   - `--hostname="$TAILSCALE_HOSTNAME"` (if set)
   - `--auth-key="$TAILSCALE_AUTH_KEY"`
   - `--accept-routes` (so the Pi also honours any other subnet routers)
6. Run `tailscale up` with the args. Capture output. On success:
   - Scrub the auth key from `role.env` on the bootfs (rewrite the file
     without the `TAILSCALE_AUTH_KEY=` line). This is the one-time-key model.
   - `touch /run/tailscale-up.done`
   - Log `tailscale ip -4` output.
7. On failure: log the error, exit non-zero (systemd will not auto-restart a
   oneshot, which is what we want — a bad key shouldn't hammer the API).

### Change 4: `roles/tailscale/assets/tailscale-up.service`
File: `roles/tailscale/assets/tailscale-up.service`
Action: CREATE

Content (template — `__SUBNET__`/`__HOSTNAME__`/`__TIMEOUT__` substituted by
install.sh):
```
[Unit]
Description=Tailscale first-boot bring-up (subnet router + SSH)
Wants=network-online.target tailscaled.service
After=network-online.target tailscaled.service
ConditionPathExists=!/run/tailscale-up.done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tailscale-up
StandardOutput=append:/var/log/role-setup.log
StandardError=append:/var/log/role-setup.log
TimeoutStartSec=__TIMEOUT__

[Install]
WantedBy=multi-user.target
```

## Validation plan

Shell commands (run from repo root on the Mac — this is a staging/provision
project, so "validation" = the provisioner accepts the role and stages it):

```bash
# 1. Sanity: files exist and install.sh is syntactically valid bash.
ls roles/tailscale/install.sh roles/tailscale/assets/tailscale-up.sh \
   roles/tailscale/assets/tailscale-up.service roles/tailscale/role.deps
bash -n roles/tailscale/install.sh
bash -n roles/tailscale/assets/tailscale-up.sh

# 2. provision.sh role resolution: role is found by the ROLES_PATHS search.
#    (Run against a fake bootfs dir so we don't need a real SD card.)
TMP=$(mktemp -d)
mkdir -p "$TMP/role"
touch "$TMP/user-data" "$TMP/network-config" "$TMP/meta-data"
# provision.sh needs .env; skip the full run and just confirm the role is
# discoverable:
test -x roles/tailscale/install.sh && echo "role discoverable: OK"
rm -rf "$TMP"
```
Expected:
- `ls` prints all four paths, exit 0.
- `bash -n` for both scripts: no output, exit 0.
- `role discoverable: OK`

Full end-to-end validation requires a real SD card flash + Pi boot, which is
out of scope for this task (the user will do that manually with
`./flash.sh <img> /dev/diskN tailscale` after adding `TAILSCALE_AUTH_KEY` to
`.env`).

## Success criteria
- [ ] All four files exist with correct modes.
- [ ] `bash -n` passes on both shell scripts.
- [ ] `roles/tailscale/install.sh` is executable (`-x`), so provision.sh's
      `find_role_src` search finds it.
- [ ] `git diff` shows only the new `roles/tailscale/` tree.

## Rollback
```bash
rm -rf roles/tailscale
```

## Next task
After confirmed complete: execute T02 (wire TAILSCALE_* into .env.example +
provision.sh role.env staging).