---
name: firstrun-diagnostic
description: Diagnose a Raspberry Pi that failed first-boot provisioning. Use when the user has re-inserted a Pi's SD card into their Mac after a failed Bookworm or Trixie flash, or says the Pi isn't showing up on the network / pi discover can't find it / firstrun.log / bootfs / cmdline.txt. Reads the diagnostic logs off the mounted FAT bootfs partition without booting the Pi.
---

# firstrun-diagnostic

Diagnose a Raspberry Pi OS SD card that failed first-boot provisioning,
**without booting the Pi**. The card's FAT bootfs partition is readable from
macOS and carries everything needed to diagnose most first-boot failures.

This project (`rpi_project`) provisions Pis two ways, and each leaves
different artifacts on bootfs:

| Distro  | Provisioner              | First-boot mechanism                 |
|---------|--------------------------|--------------------------------------|
| Trixie  | `provision.sh`           | cloud-init `user-data` + `network-config` |
| Bookworm| `provision-bookworm.sh`  | `firstrun.sh` via `systemd.run=` hook in `cmdline.txt` |

## When to use this skill

Trigger when the user says any of:
- "the Pi isn't showing up on the network" / "`pi discover` can't find it"
- "I re-inserted the SD card" / "put the card back in"
- "can you read the firstrun log" / "check bootfs"
- "the flash failed" / "the Pi never came up"

Do NOT use for: a Pi that is on the network but misbehaving (that's
`journalctl` on the Pi over SSH, not this skill), or a card that won't
mount at all on the Mac (hardware issue).

## Procedure

### Step 0 — Confirm bootfs is mounted

```bash
ls /Volumes/bootfs >/dev/null 2>&1
```

If not mounted, tell the user: re-insert the SD card (or a USB SD reader),
and dismiss the "what do you want to do with this disk?" Finder prompt
without initializing it. If macOS offers to initialize, the FAT partition
is corrupt — that's a different problem. Re-check with `ls /Volumes/bootfs`
and `lsblk`/`diskutil list`.

Do not run `sudo` commands — this skill runs unprivileged.

### Step 1 — Identify which provisioner was used

Read `cmdline.txt` and check for the `systemd.run=` hook:

```bash
cat /Volumes/bootfs/cmdline.txt
```

- Contains `systemd.run=/boot/firmware/firstrun.sh` → **Bookworm path**.
  First-boot logic is in `firstrun.sh`; its output goes to `firstrun.log`.
- No `systemd.run=` → likely **Trixie path** (cloud-init). First-boot logic
  is in `user-data` + `network-config`; cloud-init logs are on the ext4
  root partition (NOT readable from macOS), but you can still sanity-check
  the rendered cloud-init files.

### Step 2 — Read the relevant diagnostic logs (Bookworm)

```bash
# The single most useful file. firstrun.sh redirects all its output here
# (provision-bookworm.sh:158) and only deletes the script, not the log.
cat /Volumes/bootfs/firstrun.log
```

Look for, in order, and report which step succeeded / failed:

1. `[firstrun] start <timestamp>` — if missing, `firstrun.sh` never ran
   (the `systemd.run=` hook didn't fire — check `cmdline.txt`).
2. **Hostname set** — `set_hostname rpi-<6hex>` or the fallback echo path.
3. **SSH enabled** — `enable_ssh` or `systemctl enable ssh`.
4. **User creation** — `/usr/lib/userconf-pi/userconf "$PI_USERNAME" '$PI_PASSWORD_HASH'`.
   If `$PI_PASSWORD_HASH` is literally empty or `$6$` is missing, the
   password-hash step on the Mac failed (see `provision-bookworm.sh:56` —
   macOS LibreSSL doesn't support `openssl passwd -6`; the `hash_password`
   helper falls back to brew's openssl@3 or python3 crypt).
5. **SSH pubkey** — `mkdir .ssh` + `echo $SSH_PUBKEY >> authorized_keys`.
6. **WiFi country + radio unblock** — `iw reg set` + `rfkill unblock wifi`.
   **Common failure**: if WiFi country isn't set before `set_wlan`, the
   wlan0 radio stays soft-blocked and `set_wlan` silently fails to
   associate. This is THE most common reason a Bookworm Pi never shows up
   on the network.
7. **WiFi join** — `set_wlan $SSID $PSK $COUNTRY` + the NetworkManager
   keyfile write.
8. **Timezone/locale** — `ln -sf .../zoneinfo/...` + `LANG=...`.
9. **role-setup.service install** — `install -m 0644 ... role-setup.service`
   + `systemctl enable role-setup.service`.
10. **cmdline.txt cleanup** — `sed -i 's| systemd.run.*||g'`. If this line
    is missing the run never finished (or it crashed before reaching it).
11. `[firstrun] done <timestamp>` — the success sentinel.

If `firstrun.log` is absent entirely, `firstrun.sh` never executed. Check
`cmdline.txt` for the `systemd.run=` hook and check that `firstrun.sh`
itself exists on bootfs (it deletes itself on success, so its absence
after a successful run is expected — but absence + no log = never ran).

### Step 3 — Read the relevant diagnostic files (Trixie)

Trixie's cloud-init logs (`/var/log/cloud-init.log`,
`/var/log/cloud-init-output.log`) live on the ext4 root partition and are
NOT readable from macOS. On the FAT bootfs you can only sanity-check the
rendered inputs:

```bash
cat /Volumes/bootfs/user-data        # the cloud-config that ran
cat /Volumes/bootfs/network-config   # the netplan v2 WiFi config
cat /Volumes/bootfs/meta-data        # should show instance_id: rpios-...
```

Look for:
- `passwd:` line in user-data — if it's empty or `$6$` is missing, the
  password-hash step failed (same `openssl passwd -6` bug as Bookworm).
- `wifi_ssid` / `psk` in network-config matching the user's `.env`.
- A bumped `instance_id` — if it's stale, cloud-init said "already ran"
  and skipped everything on re-provision (see `provision.sh:96-103`).

For a real Trixie first-boot failure, tell the user to SSH in (if SSH
came up) and run `sudo cloud-init status --long` + `sudo journalctl -u
cloud-init-local.service -u cloud-init.service`. If SSH didn't come up,
they need a monitor+keyboard or to re-flash.

### Step 4 — Check the role setup

```bash
ls /Volumes/bootfs/role/                 # should contain base/ + the selected role
cat /Volumes/bootfs/role/role.env         # ROLE=... + TAILSCALE_*/TOUCHSCREEN_*/NETDATA_*
ls /Volumes/bootfs/role-setup.service     # the oneshot unit (staged by provisioner)
```

- If `role/` is missing, the provisioner's role-staging step failed.
- If `role.env` is missing `TAILSCALE_*` (or other expected prefix vars),
  the env-prefix awk pattern in the provisioner didn't include them (see
  `provision.sh:180` / `provision-bookworm.sh:141` — should include
  `TOUCHSCREEN|NATS|OLLAMA|COOP|MOTION|TAILSCALE|NETDATA`).
- If `role-setup.service` is missing, the `cp role-setup.service.tmpl`
  step failed.

### Step 5 — Report findings

Structure the report as:

1. **What ran** — which provisioner, how far it got (by step number above).
2. **What failed** — the exact line/step where the log stops or errors.
3. **Likely cause** — the most probable root cause (see "Common failures"
   below for the usual suspects).
4. **Fix** — concrete next step: edit `.env`, re-run the provisioner on
   the still-mounted card, or re-flash.

## Common failures (ranked by frequency)

1. **WiFi never associates (Bookworm)** — regulatory domain not set before
   `set_wlan`, so wlan0 stays soft-blocked. `firstrun.log` shows the wifi
   steps but `pi discover` finds nothing. Fix: confirm `WIFI_COUNTRY` is
   set in `.env`; `provision-bookworm.sh:202-208` does `iw reg set` +
   `rfkill unblock wifi` before `set_wlan` — if it still fails, the user
   may need to re-flash or set the country via `raspi-config` on the Pi.

2. **Password hash empty** — `openssl passwd -6` fails on macOS LibreSSL.
   `user-data` / `firstrun.log` shows `passwd:` empty or `$6$` missing.
   Fix: the `hash_password` helper in both provisioners falls back to
   brew's `openssl@3` then `python3 crypt`. If all three fail, install
   `brew install openssl@3`.

3. **Pi using USB ethernet adapter** — `pi discover` misses it because
   the adapter's MAC is not a Pi OUI. Fix: `./pi discover --all` shows
   all unknown devices; or `sudo arp-scan -I en0 --localnet` and look
   for an unfamiliar IP.

4. **cloud-init already ran (Trixie)** — re-provisioning the same card
   without bumping `instance_id` makes cloud-init skip everything.
   `meta-data` shows an old `instance_id`. Fix: `provision.sh` auto-bumps
   it, so this only happens if provision.sh wasn't re-run after the last
   flash.

5. **role-setup never ran** — the oneshot unit needs
   `network-online.target`; if WiFi never came up, the unit never fires.
   Symptom: Pi is reachable (e.g. via HDMI) but the role's packages aren't
   installed. Root cause is upstream (WiFi, step 6).

## What this skill cannot do

- Read ext4 partition files from macOS (Trixie cloud-init logs, the
  Pi's `/var/log/role-setup.log`). For those, the user needs a Linux
  machine, or to boot the Pi with a monitor and log in locally.
- Mount the card if macOS won't mount it (hardware fault, corrupt FAT).
- Diagnose a Pi that's on the network but misconfigured — that needs SSH
  + `journalctl`, not this skill.