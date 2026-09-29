# Inventory

Local YAML inventory of the Raspberry Pis this project provisions.

## Files

- [`inventory.yaml`](inventory.yaml) — single YAML doc, **gitignored**, keyed by CPU serial
- [`pi`](pi) — bash CLI on top of `yq`, no other runtime deps

## Schema

```yaml
<cpu_serial_16hex>:                          # primary key, from /proc/cpuinfo
  hostname: rpi-<6hex>                       # auto-derived (last 6 of serial)
  model: "Raspberry Pi 3 Model B Rev 1.2"    # /proc/cpuinfo Model
  friendly_name: ""                          # user-set via `pi name`
  mac_eth: "b8:27:eb:..."                    # from /sys/class/net/eth0/address
  mac_wifi: "b8:27:eb:..."                   # from /sys/class/net/wlan0/address
  last_ip: "192.168.0.35"                    # from `pi discover` or `pi register`
  last_seen: "2026-05-30T22:00:00-07:00"     # ISO8601
  notes: ""                                  # free-form, user-editable
  flashes:                                   # ordered, newest last
    - flashed_at: "..."
      instance_id: "rpios-YYYYmmddHHMMSS-NNNN"
      image: "2026-04-21-raspios-trixie-arm64-lite.img.xz"
      disk: "/dev/disk4"
      role: "touchscreen"
      pi_username: "pi"
      wifi_ssid: "Brook"
      touchscreen_overlay: "tinylcd35"        # if role==touchscreen
      touchscreen_overlay_params: "..."
      success: true

pending_flashes:                              # top-level, written by provision.sh
  - flashed_at: "..."                         # before serial is known (Pi
    instance_id: "..."                        # hasn't booted yet); `pi
    role: "..."                               # register` matches by
    ...                                       # instance_id and promotes to
                                              # the matching device entry
```

## Workflow

### Flashing a new Pi

```bash
./flash.sh ~/Downloads/raspios-...img.xz /dev/disk4 touchscreen
./provision.sh touchscreen /Volumes/bootfs    # auto-records to pending_flashes
# (insert SD into Pi, power on, wait for boot)
./pi discover                                  # finds new Pi MAC on LAN
./pi register 192.168.0.42                     # SSHes in, records serial,
                                               # binds matching pending_flash
```

### Reusing config for a re-flash

```bash
./pi show rpi-f96245                           # see last-known config
# manually copy values to .env (or copy-paste)
./flash.sh ... && ./provision.sh ...
./pi register <new-ip>                         # binds the new flash
```

### Discovering devices that aren't tracked yet

```bash
./pi discover                                  # ARP-scan LAN, filter for Pi OUIs
# unknown Pi MAC printed; ssh-copy-id to it, then:
./pi register <ip>                             # records the new Pi
```

## CLI reference

| Command | Purpose |
|---|---|
| `pi list` | Tabular list of all Pis |
| `pi show <serial\|hostname\|friendly_name>` | Full YAML detail |
| `pi discover` | ARP-scan, update last_ip/last_seen for known Pis |
| `pi register <ip\|hostname>` | SSH to Pi, learn serial+MACs, bind pending_flashes |
| `pi name <id> "label"` | Set friendly_name |
| `pi forget <id>` | Remove from inventory |
| `pi help` | This list |

Identity lookup accepts: full 16-hex CPU serial, `rpi-XXXXXX` hostname, or friendly_name.

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
| `monitor` | NATS server (JetStream + :8222 monitoring) + Netdata parent. | `NETDATA_STREAM_API_KEY`, `NATS_URL` |
| `netdata-child` | Netdata agent streaming to the monitor Pi's parent. | `NETDATA_STREAM_API_KEY`, `NETDATA_PARENT_HOST` |
| `travel-router` | Travel WiFi router: onboard radio = private AP; USB adapter = auto WAN. Admin page at `http://192.168.50.1/admin` (login `TRAVELROUTER_ADMIN_PSK`; writes need `TRAVELROUTER_SETUP_PIN`). Public status at `/`. | `TRAVELROUTER_AP_SSID`, `TRAVELROUTER_AP_PSK`, `TRAVELROUTER_ADMIN_PSK`, `TRAVELROUTER_SETUP_PIN` |

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

### Provisioning the monitor Pi + fleet monitoring

1. Generate a shared Netdata stream API key (UUID) and put it in `.env`:
   ```bash
   uuidgen | pbcopy
   ```
   ```
   NETDATA_STREAM_API_KEY="..."
   NATS_URL="nats://192.168.0.151:4222"   # the monitor Pi's IP
   ```
2. Flash the monitor Pi 4 with the `monitor` role (NATS broker + Netdata parent).
3. Flash fleet Pis with `netdata-child` (standalone, or added to a role's `role.deps`).
4. Open `http://<monitor-ip>:19999` (Netdata) and `http://<monitor-ip>:8222/varz` (NATS).
See `README.md` for the full walkthrough.

## Why pending_flashes?

`provision.sh` runs on the Mac. The CPU serial is only readable on the Pi after first boot. So at flash time we record everything we DO know (image, disk, role, env snapshot, instance_id) into `pending_flashes`, then `pi register` later matches by `instance_id` (which lives in `/boot/firmware/meta-data` on the Pi) and promotes the pending entry into the Pi's `flashes` history.

If a Pi is ever re-flashed without going through `pi register`, the old flash history stays — only the device record's `last_ip`/`last_seen` update via `pi discover`.

## Privacy note

`inventory.yaml` is gitignored because it contains:
- WiFi SSIDs (sometimes sensitive)
- Last-known LAN IPs
- MAC addresses
- User-set notes

Don't commit it.
