# rpi_project

Headless Raspberry Pi OS provisioning pipeline for macOS. Flash a Raspberry
Pi OS image to an SD card, provision it with WiFi, a user, your SSH key, and
a **role** (a bundle of post-install packages/config), then track every Pi
in a local YAML inventory.

```
 .env (WiFi, user, role, secrets)
   |
   v
flash.sh  -->  provision.sh  -->  bootfs/role/{install.sh, role.env}
 (write image)   (render user-data,                       |
                  stage role tree)                         v
                                               role-setup.service (on Pi)
                                                       |
                                                       v
                                              roles/<name>/install.sh
```

## What it does

- `flash.sh` writes a Raspberry Pi OS `.img.xz` to an SD card via `dd`, waits
  for the bootfs partition to mount, and dispatches to the right provisioner:
  - `provision.sh` for Trixie images (cloud-init `user-data` path)
  - `provision-bookworm.sh` for Bookworm images (`firstrun.sh` + `systemd.run=`
    hook path; Bookworm Lite has no cloud-init)
- The provisioner renders WiFi/network config, a user with your SSH key, a
  hashed password, and stages a `role/` tree + `role.env` onto the bootfs
  partition.
- On first boot, a one-shot `role-setup.service` runs the selected role's
  `install.sh` (which runs the `base` role first, then its own logic).
- `pi` is a small bash CLI on top of `yq` that tracks every Pi by CPU serial
  in `inventory.yaml` (gitignored).

## Prerequisites (one-time setup on your Mac)

You need a few tools installed before anything works.

```bash
# 1. Xcode command-line tools (for dd, diskutil, openssl, awk, etc.)
xcode-select --install

# 2. Homebrew packages
brew install yq arp-scan
```

| Tool | Why |
|---|---|
| `yq` | `pi` inventory CLI reads/writes `inventory.yaml`. |
| `arp-scan` | `pi discover` scans the LAN for Pi MAC OUIs. |
| `openssl` | Hashes `PI_PASSWORD` into `/etc/shadow` format (provided by Xcode CLT). |

You also need an SSH key pair on your Mac — the public key gets baked into
every Pi's `authorized_keys` at provisioning time:

```bash
# 3. SSH key (if you don't already have one)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
# Provisioners read id_ed25519.pub / id_rsa.pub / id_ecdsa.pub automatically.
```

## First-time environment setup

1. **Clone the repo** (if you haven't already):
   ```bash
   git clone <this repo url> rpi_project
   cd rpi_project
   ```

2. **Create `.env` from the example**:
   ```bash
   cp .env.example .env
   ```
   `.env` is gitignored — it holds your WiFi password, Pi password, and any
   role secrets (e.g. `TAILSCALE_AUTH_KEY`). Edit every line:

   | Var | What to set |
   |---|---|
   | `WIFI_SSID` / `WIFI_PSK` / `WIFI_COUNTRY` | Your WiFi. `WIFI_COUNTRY` is the ISO 3166-1 alpha-2 code (e.g. `US`). |
   | `PI_USERNAME` / `PI_PASSWORD` | The user created on every Pi. Password is hashed at render time. |
   | `TIMEZONE` / `LOCALE` / `KEYMAP` | e.g. `America/Los_Angeles` / `en_US.UTF-8` / `us`. |
   | `ROLE` | Default role if you don't pass one to `flash.sh`. One of: `base`, `security-camera`, `touchscreen`, `tailscale`. |
   | `NATS_URL` | NATS broker for the node self-announcer installed by `base`. |
   | `TAILSCALE_*` | Only for the `tailscale` role (see below). |
   | `TOUCHSCREEN_*` | Only for the `touchscreen` role. |
   | `OLLAMA_*` / `COOP_*` / `MOTION_PORT` | Only for the `chicken-cam`/`security-camera` roles. |

3. **Download a Raspberry Pi OS image**. This pipeline expects the **Lite**
   (headless) images. Get them from https://www.raspberrypi.com/software/operating-system/
   and leave the `.img.xz` compressed — `flash.sh` streams it through `xz`:
   ```bash
   # Example: Trixie 64-bit Lite (needs a Pi 3 / 4 / 5)
   ~/Downloads/2026-04-21-raspios-trixie-arm64-lite.img.xz

   # Example: Bookworm armhf Lite (works on Pi 3 / Zero W / older)
   ~/Downloads/2026-xx-xx-raspios-bookworm-armhf-lite.img.xz
   ```
   `flash.sh` picks the provisioner from the image filename (`trixie` →
   `provision.sh`, `bookworm` → `provision-bookworm.sh`). If the filename is
   ambiguous, pass `PROVISION_SCRIPT=provision.sh` (or
   `provision-bookworm.sh`) explicitly.

## Your first Pi

```bash
# 1. Flash + provision. ROLE is optional; defaults to .env's ROLE ("base").
#    This ERASES the disk — it will prompt you to confirm.
./flash.sh ~/Downloads/2026-04-21-raspios-trixie-arm64-lite.img.xz /dev/disk4 base

# 2. Eject the card (flash.sh tries to do this for you), insert it in the Pi,
#    and power on. Wait ~2-5 min for first boot + role-setup to finish.

# 3. Find the Pi on your LAN (uses arp-scan):
./pi discover
#   prints:  192.168.0.42  b8:27:eb:..:..:..  -> UNKNOWN Pi (use `pi register 192.168.0.42`)

# 4. The first time, SSH in once so the host key is accepted, then register it:
ssh pi@192.168.0.42          # password from .env's PI_PASSWORD
exit
./pi register 192.168.0.42
#   records the CPU serial + MACs, binds the pending flash to this Pi.

# 5. Verify it's tracked:
./pi list
./pi show rpi-XXXXXX
```

### Reusing config for a re-flash

```bash
./pi show rpi-f96245        # see last-known role + WiFi + overlay config
# copy any values you need back into .env, then:
./flash.sh ~/Downloads/...img.xz /dev/disk4 <role>
./pi register <new-ip>      # binds the new flash to the same Pi
```

## Roles

A role is a directory under `roles/<name>/` with an `install.sh` that runs
once on first boot via `role-setup.service`. Provisioning stages the role
tree + `role.env` onto the SD card's bootfs partition.

| Role | Purpose | Key env vars |
|---|---|---|
| `base` | Common packages (vim, tmux, curl, avahi…) + NATS node announcer. Always staged. | `NATS_URL` |
| `security-camera` | Motion + UVC webcam streamer (`http://<host>:8081`). | `MOTION_PORT` |
| `touchscreen` | SPI 3.5" panel kiosk (cage + foot on the SPI DRM panel). | `TOUCHSCREEN_*` |
| `tailscale` | Remote-access VPN: subnet router + Tailscale SSH. | `TAILSCALE_AUTH_KEY`, `TAILSCALE_SUBNET` |
| `monitor` | NATS server (JetStream + :8222 monitoring) + Netdata parent dashboard. For an always-on Pi 4. | `NATS_URL`, `NETDATA_STREAM_API_KEY` |
| `netdata-child` | Netdata agent that streams this Pi's metrics to the monitor Pi. Add to a fleet Pi's `role.deps`. | `NETDATA_STREAM_API_KEY`, `NETDATA_PARENT_HOST` |

### Provisioning a Tailscale VPN node

1. Generate a one-time auth key at
   https://login.tailscale.com/admin/settings/keys
   (Auth keys → Generate auth key → reusable: off, ephemeral: off).
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
4. After the Pi boots and `tailscale-up.service` runs, approve the node **and**
   its advertised subnet route in the Tailscale admin console:
   https://login.tailscale.com/admin/machines
   (Machines → the new node → **Approve** + **Edit route settings** → enable
   the `192.168.0.0/24` subnet).
5. From any device on your tailnet you can now reach LAN hosts at
   `192.168.0.x` and SSH to the Pi at its Tailscale hostname/IP.

Logs on the Pi: `journalctl -u tailscale-up.service` or
`/var/log/role-setup.log`.

### Provisioning the monitor Pi (NATS + Netdata parent) and fleet monitoring

The `monitor` role turns a always-on Pi 4 into the LAN's NATS broker **and**
a Netdata parent dashboard. The `netdata-child` role goes on every fleet Pi
you want to monitor; it streams metrics to the parent over HTTP.

1. **Generate a shared Netdata stream API key** (a UUID). Use the same value
   on the monitor Pi and every fleet Pi:
   ```bash
   uuidgen | pbcopy        # macOS
   ```
   Paste into `.env`:
   ```
   NETDATA_STREAM_API_KEY="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   NATS_URL="nats://192.168.0.151:4222"          # the monitor Pi's IP
   # NETDATA_PARENT_HOST is optional - defaults to the host in NATS_URL.
   ```

2. **Flash the monitor Pi 4**:
   ```bash
   ./flash.sh ~/Downloads/raspios-...img.xz /dev/disk4 monitor
   ```
   After boot it runs:
   - `nats-server` on `:4222` (JetStream on, no auth) + monitoring on `:8222`
   - `netdata` parent on `:19999` accepting child streams with the shared key

3. **Flash a fleet Pi with monitoring**. Either use `netdata-child` directly,
   or (recommended) add `netdata-child` to that role's `role.deps` so it
   streams automatically:
   ```bash
   # Standalone (Pi whose only job is to be monitored):
   ./flash.sh ~/Downloads/raspios-...img.xz /dev/disk5 netdata-child

   # Or, to monitor a Pi running another role, add to its role.deps:
   #   echo netdata-child >> roles/<that-role>/role.deps
   ```

4. **Open the dashboards**:
   ```bash
   open http://192.168.0.76:19999        # Netdata (all Pis streaming in)
   open http://192.168.0.151:8222/varz     # NATS broker status
   ```
   Every fleet Pi appears as a menu entry in the Netdata dashboard's
   top-right host selector once it has streamed its first metric.

## How it works

- `flash.sh` — writes the image, mounts bootfs, dispatches to the provisioner.
- `provision.sh` (Trixie) — renders cloud-init `user-data` + `network-config`,
  stages the role tree at `/boot/firmware/role/`, bumps `instance_id` so
  cloud-init re-runs on re-provision, records a pending flash to
  `inventory.yaml`.
- `provision-bookworm.sh` (Bookworm) — writes a `firstrun.sh` + `systemd.run=`
  hook (Bookworm Lite has no cloud-init), otherwise stages the same role tree.
- `role-setup.service.tmpl` — oneshot systemd unit that runs
  `/boot/firmware/role/install.sh` after `network-online.target`. The
  dispatcher sources `role.env` and execs the selected role's `install.sh`.
- `roles/<name>/role.deps` — optional file listing dependency roles;
  `provision.sh` stages them before the role itself (base is always staged).
- `inventory.yaml` — gitignored, keyed by CPU serial. `provision.sh` writes a
  `pending_flashes` entry before the Pi boots; `pi register` later binds it
  to a serial after the Pi is reachable. See [`INVENTORY.md`](INVENTORY.md).

## Troubleshooting

- **`bootfs did not mount`** after `dd` finishes — re-insert the SD card (or
  a USB SD reader); macOS sometimes doesn't auto-mount the FAT partition.
- **`role-setup.service` didn't run** — check `/var/log/role-setup.log` on
  the Pi (`journalctl -u role-setup.service`).
- **Pi never joins WiFi** — `WIFI_COUNTRY` must be set; on Bookworm the radio
  stays soft-blocked until the regulatory domain is known.
- **Tailscale node never comes up** — `TAILSCALE_AUTH_KEY` is empty or
  expired; the role exits 0 (doesn't fail the unit) so the Pi is still on
  LAN. Set a fresh key in `.env` and re-provision, or SSH in and run
  `tailscale up --ssh --advertise-routes=$TAILSCALE_SUBNET` by hand.
- **Forgot which Pi is which** — `./pi list` shows all tracked Pis;
  `./pi name rpi-XXXXXX "kitchen"` labels one for easy reference.

## Files

| Path | Purpose |
|---|---|
| `flash.sh` | Flash image + dispatch to provisioner. |
| `provision.sh` | Trixie (cloud-init) provisioner. |
| `provision-bookworm.sh` | Bookworm (firstrun.sh) provisioner. |
| `role-setup.service.tmpl` | Oneshot unit that runs the role on first boot. |
| `roles/<name>/install.sh` | Role installer (runs on the Pi). |
| `.env` / `.env.example` | Per-host secrets + config (gitignored). |
| `pi` | Inventory CLI. See `./pi help`. |
| `inventory.yaml` | Per-Pi state (gitignored). See [`INVENTORY.md`](INVENTORY.md). |
| `user-data.tmpl` / `network-config.tmpl` | Trixie cloud-init templates. |

## Privacy

`.env` and `inventory.yaml` are gitignored because they contain WiFi
passwords, Pi passwords, LAN IPs, MAC addresses, and (for the tailscale
role) a Tailscale auth key. Don't commit them.