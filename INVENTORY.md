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
