#!/bin/bash
# Launch cage with a fullscreen terminal on the SuziPi 3.5" SPI panel.
#
# We try to bind to the SPI DRM card explicitly so cage doesn't grab the
# HDMI output by accident on hosts that have both. The SPI panel shows up
# as a separate /dev/dri/cardN whose driver is "tinydrm"-style (drv=panel-
# mipi-dbi-spi or ili9486 depending on overlay/kernel). HDMI is vc4.
#
# Strategy:
#   1. Find every /dev/dri/cardN.
#   2. Pick the first one whose driver is NOT "vc4".
#   3. Fall back to whatever's there if we can't tell them apart.
set -euo pipefail

pick_drm_card() {
  local card drv
  for card in /dev/dri/card*; do
    [[ -e "$card" ]] || continue
    local n="${card##*/card}"
    drv="$(readlink -f "/sys/class/drm/card${n}/device/driver" 2>/dev/null | xargs -n1 basename || true)"
    if [[ -n "$drv" && "$drv" != "vc4" ]]; then
      echo "$card"
      return 0
    fi
  done
  # Fallback: whatever exists.
  for card in /dev/dri/card*; do
    [[ -e "$card" ]] && { echo "$card"; return 0; }
  done
  return 1
}

DRM_CARD="$(pick_drm_card || true)"
if [[ -n "${DRM_CARD:-}" ]]; then
  export WLR_DRM_DEVICES="$DRM_CARD"
fi

# Hide the cursor on a touch-only display, but leave it available for HDMI debug.
export WLR_NO_HARDWARE_CURSORS=1

# foot config: pick a font size that's actually readable on 480x320.
mkdir -p "$HOME/.config/foot"
cat >"$HOME/.config/foot/foot.ini" <<'INI'
font=monospace:size=10
pad=2x2
[colors]
background=000000
foreground=d0d0d0
[scrollback]
lines=2000
INI

# cage runs ONE app fullscreen and exits when the app exits. -s = single window.
exec /usr/bin/cage -s -- /usr/bin/foot --title="touchscreen" -- /bin/bash -l
