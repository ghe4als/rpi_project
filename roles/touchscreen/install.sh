#!/bin/bash
# touchscreen role: bring up a SuziPi/MHS35-class 3.5" SPI touch display
# (ILI9486 + XPT2046 resistive touch) on Pi 4 / Trixie 64-bit using the
# native DRM/KMS path - no LCD-show, no Xorg, no fbcp.
#
# After install: cage + foot fullscreen terminal autostarts on the SPI panel
# under the configured pi user. HDMI/SSH stay untouched so the box is always
# recoverable, and rollback assets are dropped on /boot/firmware so the SD
# card can be fixed from a Mac.
#
# Reboot is scheduled (not exec'd) at the very end so this script exits 0,
# role-setup.service's ExecStartPost disables itself cleanly, and cloud-init
# gets to finish whatever it's still doing.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ROLE_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$ROLE_DIR/assets"
if [[ ! -d "$ASSETS" && -d "$ROLE_DIR/touchscreen/assets" ]]; then
  ROLE_DIR="$ROLE_DIR/touchscreen"
  ASSETS="$ROLE_DIR/assets"
fi
BOOTFS="/boot/firmware"
LOG_TAG="[touchscreen]"

log() { echo "$LOG_TAG $*"; }

ROLE_ENV="$BOOTFS/role/role.env"
if [[ -f "$ROLE_ENV" ]]; then
  log "loading $ROLE_ENV"
  set -a; source "$ROLE_ENV"; set +a
fi
# TOUCHSCREEN_DRIVER selects the display path:
#   drm        - native DRM/KMS overlay (real ILI9486/ST7796/etc panels, Trixie)
#   kedei-fbcp - KeDei v6.3 (MPI3501, 74HC4094 shift register) via fbcp-ili9341
#                userspace HDMI mirror; REQUIRES Bookworm (needs DispmanX).
: "${TOUCHSCREEN_DRIVER:=drm}"
: "${TOUCHSCREEN_OVERLAY:=tinylcd35}"
: "${TOUCHSCREEN_OVERLAY_PARAMS:=rotate=90,fps=30,touch,touchgpio=17}"
: "${TOUCHSCREEN_TOUCH_OVERLAY:=ads7846}"
: "${TOUCHSCREEN_TOUCH_PARAMS:=cs=1,penirq=17,speed=1000000,swapxy=1,invx=1}"
log "driver = $TOUCHSCREEN_DRIVER"

# -----------------------------------------------------------------------------
# KeDei v6.3 path: build fbcp-ili9341 with the MPI3501 target. The KeDei panel
# can't be driven by any DRM/fbtft overlay (3-wire SPI, 32-bit framed packets
# via a 74HC4094 shift register, LCD on CE1). fbcp mirrors the HDMI framebuffer
# to it. This needs Bookworm's legacy DispmanX userland (absent on Trixie).
# -----------------------------------------------------------------------------
install_kedei_fbcp() {
  log "KeDei path: installing build deps"
  apt-get update -y
  apt-get install -y --no-install-recommends cmake git build-essential libraspberrypi-dev raspberrypi-kernel-headers

  local SRC=/opt/fbcp-ili9341
  if [[ ! -d "$SRC" ]]; then
    log "cloning fbcp-ili9341"
    git clone --depth 1 https://github.com/juj/fbcp-ili9341.git "$SRC"
  fi

  # Patch CMakeLists for aarch64 toolchains (harmless on armhf - the guard only
  # strips the 32-bit-only flags when building on aarch64).
  if ! grep -q 'NOT CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64"' "$SRC/CMakeLists.txt"; then
    sed -i 's|^set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -marm.*|if (NOT CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64")\n&\nelse()\n  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -funsafe-math-optimizations")\nendif()|' "$SRC/CMakeLists.txt"
  fi

  log "building fbcp-ili9341 (KEDEI_V63_MPI3501, DMA off)"
  rm -rf "$SRC/build" && mkdir -p "$SRC/build"
  ( cd "$SRC/build"
    cmake -DKEDEI_V63_MPI3501=ON -DUSE_DMA_TRANSFERS=OFF \
          -DSPI_BUS_CLOCK_DIVISOR=20 -DSTATISTICS=0 -DBACKLIGHT_CONTROL=ON ..
    make -j"$(nproc)"
  )
  install -m 0755 "$SRC/build/fbcp-ili9341" /usr/local/bin/fbcp-ili9341

  log "configuring HDMI 480x320 + spi for KeDei in config.txt"
  local CFG="$BOOTFS/config.txt"
  [[ -f "$BOOTFS/config.txt.pre-touchscreen" ]] || cp "$CFG" "$BOOTFS/config.txt.pre-touchscreen"
  sed -i "/# BEGIN role-touchscreen/,/# END role-touchscreen/d" "$CFG"
  # fbcp-ili9341 uses DispmanX, which only works with the LEGACY graphics stack.
  # Bookworm defaults to dtoverlay=vc4-kms-v3d (open KMS driver) which makes
  # vc_dispmanx_display_open() fail (no /dev/fb0, no DispmanX display). Disable
  # KMS so the firmware framebuffer + DispmanX are available for fbcp to mirror.
  sed -i 's/^dtoverlay=vc4-kms-v3d/#dtoverlay=vc4-kms-v3d  # disabled for fbcp DispmanX/' "$CFG"
  sed -i 's/^dtoverlay=vc4-fkms-v3d/#dtoverlay=vc4-fkms-v3d  # disabled for fbcp DispmanX/' "$CFG"
  cat >>"$CFG" <<'KEDEICFG'

# BEGIN role-touchscreen
# KeDei 3.5 v6.3 (MPI3501) - driven by fbcp-ili9341 userspace HDMI mirror.
# KMS disabled above; fbcp needs the legacy firmware framebuffer + DispmanX.
dtparam=spi=on
hdmi_force_hotplug=1
hdmi_group=2
hdmi_mode=87
hdmi_cvt=480 320 60 6 0 0 0
hdmi_drive=2
# END role-touchscreen
KEDEICFG

  log "installing fbcp-ili9341 systemd service"
  cat >/etc/systemd/system/fbcp-ili9341.service <<'UNIT'
[Unit]
Description=fbcp-ili9341 KeDei SPI display mirror
After=multi-user.target
[Service]
Type=simple
ExecStart=/usr/local/bin/fbcp-ili9341
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable fbcp-ili9341.service

  log "KeDei fbcp install complete; reboot will start the mirror"
}

if [[ "$TOUCHSCREEN_DRIVER" == "kedei-fbcp" ]]; then
  if [[ -x /boot/firmware/role/base/install.sh ]]; then
    log "running base role"
    bash /boot/firmware/role/base/install.sh
  fi
  install_kedei_fbcp
  log "scheduling reboot to activate KeDei display"
  systemd-run --on-active=20s --unit=role-touchscreen-reboot /sbin/shutdown -r now "activate KeDei display" || true
  exit 0
fi

log "overlay = $TOUCHSCREEN_OVERLAY,$TOUCHSCREEN_OVERLAY_PARAMS"
log "touch   = $TOUCHSCREEN_TOUCH_OVERLAY,$TOUCHSCREEN_TOUCH_PARAMS"

# -----------------------------------------------------------------------------
# 0. Wait for cloud-init to finish so we don't race user/hostname/wifi setup.
# -----------------------------------------------------------------------------
if command -v cloud-init >/dev/null 2>&1; then
  log "waiting for cloud-init to finish before touching the system"
  cloud-init status --wait || log "cloud-init status returned non-zero (continuing)"
fi

# -----------------------------------------------------------------------------
# 1. Run base role first (idempotent: apt update + common tools).
# -----------------------------------------------------------------------------
if [[ -x /boot/firmware/role/base/install.sh ]]; then
  log "running base role"
  bash /boot/firmware/role/base/install.sh
fi

# -----------------------------------------------------------------------------
# 2. Install the Wayland kiosk stack: cage (compositor) + foot (terminal) +
#    libinput tools for touch debugging. seatd is what cage uses for DRM/input
#    access without logind seat plumbing fights.
# -----------------------------------------------------------------------------
log "installing wayland kiosk packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  cage \
  foot \
  seatd \
  libinput-tools \
  evtest \
  fonts-dejavu-core

systemctl enable seatd.service

# -----------------------------------------------------------------------------
# 3. Edit /boot/firmware/config.txt: enable SPI, load piscreen DRM overlay,
#    load ads7846 touch overlay. Backup and use a marked block so rollback
#    is a one-line edit.
# -----------------------------------------------------------------------------
CONFIG_TXT="$BOOTFS/config.txt"
BACKUP="$BOOTFS/config.txt.pre-touchscreen"
BEGIN_MARK="# BEGIN role-touchscreen"
END_MARK="# END role-touchscreen"

if [[ ! -f "$BACKUP" ]]; then
  log "backing up config.txt -> $(basename "$BACKUP")"
  cp "$CONFIG_TXT" "$BACKUP"
fi

# Strip any prior block (idempotent re-run).
if grep -q "$BEGIN_MARK" "$CONFIG_TXT"; then
  log "removing previous role-touchscreen block from config.txt"
  sed -i "/$BEGIN_MARK/,/$END_MARK/d" "$CONFIG_TXT"
fi

log "appending role-touchscreen block to config.txt"
cat >>"$CONFIG_TXT" <<EOF

# BEGIN role-touchscreen
# SPI panel + touch overlays. Driven by /boot/firmware/role/role.env.
# If the panel stays dark or the wrong driver binds, see
# /boot/firmware/role/ROLLBACK_TOUCHSCREEN.txt and overlay-candidates.txt.
# Edit role.env on the bootfs partition (visible from a Mac) to swap overlays
# without re-flashing.
dtparam=spi=on
dtoverlay=$TOUCHSCREEN_OVERLAY,$TOUCHSCREEN_OVERLAY_PARAMS
dtoverlay=$TOUCHSCREEN_TOUCH_OVERLAY,$TOUCHSCREEN_TOUCH_PARAMS
# END role-touchscreen
EOF

# -----------------------------------------------------------------------------
# 4. Drop rollback / debug helpers into /boot/firmware/role/ where a Mac can
#    edit them by re-inserting the SD card.
# -----------------------------------------------------------------------------
log "writing rollback + overlay-candidate notes"
install -m 0644 "$ASSETS/ROLLBACK_TOUCHSCREEN.txt" "$BOOTFS/role/ROLLBACK_TOUCHSCREEN.txt"
install -m 0644 "$ASSETS/overlay-candidates.txt"   "$BOOTFS/role/overlay-candidates.txt"

# -----------------------------------------------------------------------------
# 5. Pick the autologin user. cloud-init's user is named in /etc/cloud's
#    rendered config; in our pipeline it matches PI_USERNAME from .env, but
#    we'd rather discover it than hardcode. Fall back to 'pi'.
# -----------------------------------------------------------------------------
TARGET_USER=""
for u in $(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1}'); do
  TARGET_USER="$u"; break
done
TARGET_USER="${TARGET_USER:-pi}"
log "kiosk session will run as user: $TARGET_USER"

# Make sure that user can talk to DRM, input, and seatd.
usermod -a -G video,render,input,seat "$TARGET_USER" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 6. Install the cage kiosk service. It runs as the target user, on tty1, and
#    binds to the *second* DRM card if present (the SPI panel), otherwise
#    falls back to whatever DRM card exists. cage launches `foot` fullscreen.
# -----------------------------------------------------------------------------
log "installing /usr/local/bin/touchscreen-kiosk"
install -m 0755 "$ASSETS/touchscreen-kiosk.sh" /usr/local/bin/touchscreen-kiosk

log "installing /etc/systemd/system/touchscreen-kiosk.service"
sed "s/__TARGET_USER__/$TARGET_USER/g" \
  "$ASSETS/touchscreen-kiosk.service" \
  > /etc/systemd/system/touchscreen-kiosk.service
chmod 0644 /etc/systemd/system/touchscreen-kiosk.service

systemctl daemon-reload
systemctl enable touchscreen-kiosk.service

# -----------------------------------------------------------------------------
# 7. Schedule a clean reboot so config.txt overlays take effect. We schedule
#    via systemd-run (NOT `reboot` inline) so this script exits 0, the
#    role-setup unit's ExecStartPost runs and disables itself, and cloud-init
#    is not killed mid-stage.
# -----------------------------------------------------------------------------
log "done. scheduling reboot in 20s so config.txt overlays load."
log "after reboot: SPI screen should show a fullscreen terminal."
log "if it doesn't: see /boot/firmware/role/ROLLBACK_TOUCHSCREEN.txt"

systemd-run --on-active=20s --unit=role-touchscreen-reboot \
  /sbin/shutdown -r now "applying touchscreen overlays" || true
