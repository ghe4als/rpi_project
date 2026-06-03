# LCD Screen Debug — Session Handoff

State as of the last working point in this session, in case we pick this back up later.

## What's working (verified end-to-end on the Pi side)

- **Pi 3** at `192.168.0.35` / `rpi-f96245.local`, SSH key auth, role=touchscreen
- **panel-mipi-dbi-spi** DRM driver bound to `spi0.0` — `/dev/dri/card0`, `/dev/fb1`
- **ST7796 init firmware** at `/lib/firmware/panel.bin` (variant A)
- **/dev/fb1** is 320x480, 16bpp; reads back the bytes we write (verified)
- **SPI bus traffic** confirmed: each fb1 frame write produces ~307,200 bytes on `/sys/class/spi_master/spi0/statistics/bytes`
- **GPIO backlight** (`/sys/class/backlight/backlight_gpio`) — `bl_power=0`, `brightness=1`, `max_brightness=1`
- **ads7846 touch driver** registered as `input0`, ADS7846 touch chip confirmed by user
- **No driver-level errors** in dmesg this boot

The data path **kernel → SPI bus → controller IC** is fully functional and verified objectively. Whatever's wrong is at the panel-init or pixel-format layer.

## What's on the LCD right now

A 6-bar diagnostic pattern was painted via `dd /tmp/diag.bin → /dev/fb1`:

```
+----------------------+
| RED                  |  ← top bar
+----------------------+
| GREEN                |
+----------------------+
| BLUE                 |
+----------------------+
| WHITE                |
+----------------------+
| BLACK                |
+----------------------+
| GRAY                 |  ← bottom bar
+----------------------+
```

Plus 5×5 white marker dots on the left edge, one per bar (1 dot pattern actually — same dot repeated, just stacked).

## What the user reported BEFORE the variant-A change

Quote: *"like a larger dark square and 4 smaller lighter squares in a row"* — i.e. the screen had a large dark area and a horizontal strip of 4 brighter rectangles, NOT the 4-equal-quadrant pattern I painted.

Diagnosis at that point: dimension/rotation/format mismatch. Pixels reaching panel, but mapped to wrong region.

## What was changed in variant A (current state)

In `/lib/firmware/panel.bin` (md5 `57dd4c3868bd5e7aec2543158a3e66e3`), compiled from [`roles/touchscreen/assets/panel-st7796-variant-a.txt`](roles/touchscreen/assets/panel-st7796-variant-a.txt):

| Init register | Value before | Value after | Effect |
|---|---|---|---|
| `0x36` MADCTL | `0x48` | `0x28` | Rotate 180° + landscape orientation |
| `0x3A` Pixel Format | `0x55` (16bpp) | `0x66` (18bpp init, 16bpp data) | Cheap-clone compatibility |
| `0x21` Display Inversion | absent | added | Some panels are wired with inverse polarity |

Backlight forced ON via sysfs (will reset on reboot — see Open Issues below).

## How to resume

1. **Find out what the LCD currently shows** (the 6-bar pattern). Possible outcomes and the next move for each:

| User reports | Diagnosis | Next move |
|---|---|---|
| "6 horizontal bars: red, green, blue, white, black, gray top→bottom" | ✅ SUCCESS — variant A works | Bake variant A into the role permanently. See "Bake-in steps" below. |
| "6 horizontal bars but colors look wrong/swapped" | RGB byte-order or BGR vs RGB | Tweak `0x36` MADCTL bit 3 (BGR↔RGB): try `0x20` (BGR off) or `0x68` (BGR on with rotation) |
| "6 vertical bars instead of horizontal" | Rotation 90° off | `0x36 = 0x48` or `0x36 = 0xE8` (try in that order) |
| "Bars but only fills part of the screen" | Window/dimension mismatch | Add explicit Column/Row Address Set commands `0x2A`/`0x2B` with full panel bounds in init |
| "Solid color, no bars" | Init not taking effect | ILI9488 init seq (different chip) — write `panel-ili9488.txt` |
| "Scrambled noise / static" | Pixel format mismatch | Try `0x3A=0x55` (back to 16bpp init) with current `0x36` |
| "Same as before (small bright strip + dark)" | Variant A didn't help; controller may not be ST7796 | ILI9488 init seq |

2. **Reload variant A or any new variant**:
   ```bash
   # local: edit roles/touchscreen/assets/panel-st7796-variant-X.txt
   scp roles/touchscreen/assets/panel-st7796-variant-X.txt pi@192.168.0.35:/tmp/init.txt
   ssh pi@192.168.0.35 'cd /tmp && python3 ./mipi-dbi-cmd panel.bin init.txt && \
                        sudo install -m 0644 panel.bin /lib/firmware/panel.bin && \
                        sudo systemctl reboot'
   ```

3. **Re-paint diagnostic pattern after each reboot**:
   ```bash
   ssh pi@192.168.0.35 'echo 0 | sudo tee /sys/class/backlight/backlight_gpio/bl_power >/dev/null
                        echo 1 | sudo tee /sys/class/backlight/backlight_gpio/brightness >/dev/null
                        sudo dd if=/tmp/diag.bin of=/dev/fb1 bs=4096 2>/dev/null'
   ```
   (The `/tmp/diag.bin` file gets wiped on reboot. Re-paint by re-running the python loop in `roles/touchscreen/assets/diag-paint.sh` — I'll write that next time.)

## Bake-in steps (only when user confirms the bars display correctly)

1. **Pick the working init txt** as the canonical:
   ```bash
   cp roles/touchscreen/assets/panel-st7796-variant-a.txt \
      roles/touchscreen/assets/panel.txt
   ```
2. **Update `roles/touchscreen/install.sh`** to:
   - Compile `panel.txt` → `panel.bin` at install time (apt: `python3`, `wget` to fetch `mipi-dbi-cmd`)
   - Install `panel.bin` to `/lib/firmware/panel.bin`
   - Use `mipi-dbi-spi` overlay (matching what `.env`'s `TOUCHSCREEN_OVERLAY` should be set to)
3. **Update `.env`** to:
   ```
   TOUCHSCREEN_OVERLAY="mipi-dbi-spi"
   TOUCHSCREEN_OVERLAY_PARAMS="spi0-0,speed=32000000"
   # plus dtparams in install.sh: width=320 height=480 reset-gpio=25 dc-gpio=24 backlight-gpio=18 write-only
   ```
4. **Add a backlight-on systemd unit** (the GPIO backlight forgets state on reboot):
   ```ini
   [Unit]
   Description=Force GPIO backlight on
   After=systemd-modules-load.service
   [Service]
   Type=oneshot
   ExecStart=/bin/sh -c 'echo 0 > /sys/class/backlight/backlight_gpio/bl_power'
   ExecStart=/bin/sh -c 'echo 1 > /sys/class/backlight/backlight_gpio/brightness'
   [Install]
   WantedBy=multi-user.target
   ```
5. **Update `touchscreen-kiosk.service`** to point at `/dev/dri/card0` (SPI panel) — already does this via `WLR_DRM_DEVICES` discovery in `touchscreen-kiosk.sh`, no change needed if card numbering is stable.
6. **Re-flash a clean SD card** end-to-end to validate the role works from scratch.

## Open issues

- **Backlight resets on every boot.** Currently we force it via sysfs after boot. Either add the systemd unit above OR investigate why the dt-overlay's `default-on` property isn't sticking. Could also add `gpio = 18,op,dh` to config.txt under `[all]` to drive the GPIO HIGH at firmware boot before the kernel even loads.
- **The `pi register` flow doesn't auto-update notes.** When variant A becomes the bake-in, update the Pi 3's notes to "ST7796 panel (canonical init): working".
- **No `pi reflash`** — there's no command yet that pulls a Pi's last-known config from inventory.yaml and pre-fills `.env`. Would close the loop on "re-flash this Pi with the same config it had".

## Variants tried (chronological)

1. ❌ `dtoverlay=piscreen,drm,rotate=90,speed=32000000` — `ili9486` driver: `Error applying setting, reverse things back`
2. ❌ `dtoverlay=pitft35-resistive,drm,rotate=90` — HX8357D driver: silent no-bind, no fb1
3. ❌ `dtoverlay=tft35a` — overlay missing in Trixie
4. ⚠️ `dtoverlay=tinylcd35,rotate=90,touch,touchgpio=17` — `fb_tinylcd` bound, fb1 created, but **no visible pixels on LCD** (panel ack'd protocol but rejected pixel data)
5. ❌ `dtoverlay=piscreen,rotate=90,speed=32000000` (legacy fbtft path) — same `ili9486` reject
6. 🟡 `dtoverlay=mipi-dbi-spi` + `panel-st7796.txt` (canonical init) — fb1 bound cleanly, SPI traffic verified, **partial display: "dark area + 4 small bright squares in a row"**
7. ❓ `dtoverlay=mipi-dbi-spi` + `panel-st7796-variant-a.txt` (MADCTL=0x28, PIXFMT=0x66, +invert) — **awaiting user observation** of the 6-bar diagnostic pattern

## Key file paths

- [roles/touchscreen/assets/panel-st7796.txt](roles/touchscreen/assets/panel-st7796.txt) — canonical ST7796 init
- [roles/touchscreen/assets/panel-st7796-variant-a.txt](roles/touchscreen/assets/panel-st7796-variant-a.txt) — variant A (currently active)
- `/lib/firmware/panel.bin` on Pi — md5 `57dd4c3868bd5e7aec2543158a3e66e3` = variant A
- `/tmp/mipi-dbi-cmd` on Pi — wget'd from notro/panel-mipi-dbi (gets wiped on reboot)
- `/boot/firmware/config.txt` on Pi — current `BEGIN role-touchscreen` block uses mipi-dbi-spi
- `/boot/firmware/config.txt.try-st7796` on Pi — backup before mipi-dbi-spi swap
- `/boot/firmware/config.txt.pre-touchscreen` on Pi — backup from initial role install (pre-everything)
