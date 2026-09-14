#!/bin/bash
# wan-select.sh — travel-router WAN auto-detection + nftables render/load.
#
# Installed to /usr/local/lib/travel-router/wan-select.sh and run every 30s by
# wan-select.timer (via wan-select.service). Fully idempotent and safe to
# re-run: it (a) classifies every netdev, (b) picks a USB WAN according to
# TRAVELROUTER_WAN_PREFER, (c) prepares the AP (LAN) interface, and (d) renders
# nftables.conf for the current WAN state and loads it atomically.
#
# HARDWARE NOTE: target hardware is the Pi Zero W v1.1 (no onboard Ethernet,
# single 2.4 GHz onboard radio). On boards whose built-in NIC is USB-attached
# (Pi 3B / 3B+, some Pi Zero W v1.1 with a USB dongle) that NIC may be selected
# as the WAN under `auto` — by design, and documented in the spec. On the Zero
# W v1.1 the onboard brcfmac radio lives on an SDIO/platform path, so the
# device symlink does NOT contain /usb; the wireless-classification test then
# cleanly keeps it OFF the WAN path and lets it serve as the AP.
#
# Security: THIS SCRIPT NEVER restarts NetworkManager (a 30s-tick NM restart
# would flap the WAN link and DHCP every tick). It never restarts hostapd or
# dnsmasq (install.sh owns their render + restarts; their inputs are static).
# It never creates a bridge, and never starts a WAN-side DHCP client (NM owns
# the WAN).
set -euo pipefail

log() { printf '[wan-select] %s\n' "$*"; }

# --- Test seams: overridable tools and roots so this runs on a non-Pi/CI
# runner where none of the real tools exist (use DRY_RUN + fake SYSFS_ROOT).
SYSFS_ROOT="${SYSFS_ROOT:-/sys}"
IP="${IP:-ip}"
IW="${IW:-iw}"
NFT="${NFT:-nft}"
NMCLI="${NMCLI:-nmcli}"
RFKILL="${RFKILL:-rfkill}"
TRAVELROUTER_STATE_FILE="${TRAVELROUTER_STATE_FILE:-/run/travel-router/state.json}"
TRAVELROUTER_WAN_PREFER="${TRAVELROUTER_WAN_PREFER:-auto}"
TRAVELROUTER_LAN_CIDR="${TRAVELROUTER_LAN_CIDR:-192.168.50.1/24}"
TRAVELROUTER_AP_COUNTRY="${TRAVELROUTER_AP_COUNTRY:-}"
NFTABLES_TARGET="${NFTABLES_TARGET:-/etc/nftables.conf}"

# nftables template location. When run by the service ASSETS may not be set;
# derive it from this script's own path as a fallback.
if [[ -z "${ASSETS:-}" ]]; then
  _SELF_DIR="${BASH_SOURCE[0]%/*}"
  ASSETS="$_SELF_DIR"
fi

# --- Helpers ----------------------------------------------------------------

# run_or_log : in DRY_RUN mode, log the call (incl. an `nft -f` line) without
# executing; otherwise execute it for real.
run_or_log() {
  if [[ "${TRAVELROUTER_DRY_RUN:-0}" == "1" ]]; then
    log "dry-run: $*"
    return 0
  fi
  "$@"
}

# read_state_json KEY : echo the string value of a top-level JSON key from the
# state file (best effort; empty when absent, unreadable, or a truncated file).
# The grep is non-fatal: a corrupted state file must degrade, never abort the
# 30s tick (a failure here under pipefail+set -e would loop forever).
read_state_json() {
  key="$1"
  val=""
  if [[ -r "$TRAVELROUTER_STATE_FILE" ]]; then
    val=$( (grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$TRAVELROUTER_STATE_FILE" 2>/dev/null || true) | head -1 | sed -E "s/.*:[[:space:]]*\"([^\"]*)\".*/\1/" )
  fi
  printf '%s' "$val"
}

# iface_addr IF : echo the first IPv4 addr of an interface, or "".
iface_addr() {
  "$IP" -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

# --- Load role.env defensively (two-path idiom matches tailscale-up.sh) -----
for role_env in /boot/firmware/role/role.env /boot/role/role.env; do
  if [[ -f "$role_env" ]]; then
    set -a; source "$role_env" 2>/dev/null || true; set +a
    break
  fi
done
# Re-read with the same seeds so role-env values win when present.
TRAVELROUTER_WAN_PREFER="${TRAVELROUTER_WAN_PREFER:-auto}"
TRAVELROUTER_LAN_CIDR="${TRAVELROUTER_LAN_CIDR:-192.168.50.1/24}"

# --- (1) Enumerate + classify every netdev ----------------------------------
declare -a IF_NAMES=()
declare -a IF_WIRELESS=()      # 1 if an 802.11 radio ($d/wireless exists)
declare -a IF_USB=()           # 1 if the resolved device symlink mentions /usb
classify_ifaces() {
  d="$SYSFS_ROOT/class/net"
  if [[ ! -d "$d" ]]; then
    return
  fi
  for iface in "$d"/*; do
    [[ -d "$iface" ]] || continue
    name=$(basename "$iface")
    IF_NAMES+=("$name")
    IF_WIRELESS+=(0)
    USB_HIT=0
    if [[ -d "${iface}/wireless" ]]; then
      IF_WIRELESS+=(1)
    fi
    if [[ -e "${iface}/device" ]]; then
      dev=$(readlink -f "${iface}/device" 2>/dev/null || true)
      [[ -z "$dev" ]] && dev=$(readlink "${iface}/device" 2>/dev/null || true)
      case "$dev" in
        *usb*) USB_HIT=1 ;;
      esac
    fi
    IF_USB+=("$USB_HIT")
  done
}
classify_ifaces

log "wan_prefer='${TRAVELROUTER_WAN_PREFER}'; enumerated ${#IF_NAMES[@]} netdev(s): ${IF_NAMES[*]:-<none>}"

# --- (2) WAN selection per TRAVELROUTER_WAN_PREFER ---------------------------
# find_wan WANT_WIRELESS : first USB interface matching the wireless flag.
find_wan() {
  want="$1"
  for i in "${!IF_NAMES[@]}"; do
    # USB attached (interface 1 in IF_USB) plus the requested wireless bit.
    if [[ "${IF_USB[$i]}" == "1" && "${IF_WIRELESS[$i]}" == "$want" ]]; then
      printf '%s' "${IF_NAMES[$i]}"
      return 0
    fi
  done
  return 1
}

WAN_IF=""
case "$TRAVELROUTER_WAN_PREFER" in
  ethernet)
    WAN_IF=$(find_wan 0 || true)
    [[ -z "$WAN_IF" ]] && log "ethernet requested but no USB ethernet adapter found"
    ;;
  wifi)
    WAN_IF=$(find_wan 1 || true)
    [[ -z "$WAN_IF" ]] && log "wifi requested but no USB wifi adapter found"
    ;;
  none)
    WAN_IF=""
    log "wan_prefer=none -> force standalone mode"
    ;;
  auto|"")
    WAN_IF=$(find_wan 0 || true)
    [[ -z "$WAN_IF" ]] && WAN_IF=$(find_wan 1 || true)
    log "wan_prefer=auto -> tried USB ethernet then USB wifi"
    ;;
  *)
    log "unknown WAN_PREFER='${TRAVELROUTER_WAN_PREFER}', defaulting to auto"
    WAN_IF=$(find_wan 0 || true)
    [[ -z "$WAN_IF" ]] && WAN_IF=$(find_wan 1 || true)
    ;;
esac
[[ -z "${WAN_IF+x}" ]] && WAN_IF=""

# --- (3) AP (LAN) interface: first wireless whose device path has no /usb ---
LAN_IF=""
for i in "${!IF_NAMES[@]}"; do
  if [[ "${IF_WIRELESS[$i]}" == "1" && "${IF_USB[$i]}" == "0" ]]; then
    LAN_IF="${IF_NAMES[$i]}"
    break
  fi
done
[[ -z "$LAN_IF" ]] && LAN_IF="wlan0"
log "AP/LAN interface: '${LAN_IF}'${WAN_IF:+  (WAN: '$WAN_IF')}"

# Ensure the AP interface carries the LAN subnet.
run_or_log "$IP" addr replace "${TRAVELROUTER_LAN_CIDR}" dev "$LAN_IF"

# Regdom: explicit country, else parse `iw reg get`; reject 00/world -> US.
# The awk program is stored in a variable so the parser never has to match a
# nested $() around the '/^country /' regex directly.
REG_COUNTRY=""
if [[ -n "$TRAVELROUTER_AP_COUNTRY" ]]; then
  REG_COUNTRY="$TRAVELROUTER_AP_COUNTRY"
else
  _REGPROG='/^country /{sub(/:$/,"",$2); print $2; exit}'
  REG_COUNTRY=$(set +e; "$IW" reg get 2>/dev/null | awk "$_REGPROG" || true)
  [[ -z "$REG_COUNTRY" ]] && REG_COUNTRY="00"
fi
case "$(printf '%s' "$REG_COUNTRY" | tr '[:upper:]' '[:lower:]')" in
  00|""|world) LOG_COUNTRY="${REG_COUNTRY:-<empty>}"; log "regdom '${LOG_COUNTRY}' rejected; defaulting to US"; REG_COUNTRY="US" ;;
  *) log "regdom set to '${REG_COUNTRY}'" ;;
esac
run_or_log "$IW" reg set "$REG_COUNTRY"

# Unblock the wifi radio.
run_or_log "$RFKILL" unblock wifi

# Disable power_save on the AP radio (stable LAN broadcast). iw owns dev
# power_save; `ip link` has no such argument and would abort every run.
run_or_log "$IW" dev "$LAN_IF" set power_save off

# --- (4) Render + load nftables for current WAN state ------------------------
RENDER_TMP=$(mktemp 2>/dev/null || echo "/tmp/wan-select-nft.$$")
if [[ -n "$WAN_IF" ]]; then
  sed -e "s|__LAN_INTERFACE__|${LAN_IF}|g" \
      -e "s|__WAN_INTERFACE__|${WAN_IF}|g" \
      "$ASSETS/nftables.conf.tmpl" >"$RENDER_TMP"
else
  # Standalone: replace the WAN placeholder with a literal string, then strip
  # the two WAN-facing rule lines entirely so the file still parses.
  sed -e "s|__LAN_INTERFACE__|${LAN_IF}|g" \
      -e 's|__WAN_INTERFACE__|standalone-none|g' \
      "$ASSETS/nftables.conf.tmpl" \
    | grep -v 'oifname "standalone-none"' \
        >"$RENDER_TMP"
fi
# Safety: the ONLY file wan-select renders must still begin with `flush ruleset`.
if ! head -1 "$RENDER_TMP" | grep -qx 'flush ruleset'; then
  log "render lost its leading flush ruleset; aborting"
  rm -f "$RENDER_TMP"
  exit 1
fi

# Copy the fresh render to the nft target BEFORE loading it, so `nft -f`
# always reads the file this tick rendered (never in dry-run).
if [[ "${TRAVELROUTER_DRY_RUN:-0}" != "1" ]]; then
  cp "$RENDER_TMP" "$NFTABLES_TARGET"
fi
run_or_log "$NFT" -f "$NFTABLES_TARGET"
rm -f "$RENDER_TMP"

# --- (5) Emit state.json + try-restart status server on LAN IP change --------
PREV_LAN=$(read_state_json lan_ip)

WAN_SSID=""
WAN_IP=""
if [[ -n "$WAN_IF" ]]; then
  WAN_SSID=$(set +e; "$NMCLI" -t -f GENERAL.CONNECTION dev show "$WAN_IF" 2>/dev/null | grep -m1 '^GENERAL.CONNECTION:' | cut -d: -f2- || true)
  WAN_IP=$(iface_addr "$WAN_IF" || true)
fi

mkdir -p "$(dirname "$TRAVELROUTER_STATE_FILE")" 2>/dev/null || true
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)
LAN_IP=$(iface_addr "$LAN_IF" || true)
LAN_IP="${LAN_IP:-${TRAVELROUTER_LAN_CIDR%%/*}}"

STATE_MODE="standalone"
[[ -n "$WAN_IF" ]] && STATE_MODE="routed"

# Atomic write: tmp file in the SAME directory (same filesystem) + mv, so a
# crash mid-write can never leave a truncated state.json behind.
STATE_TMP="${TRAVELROUTER_STATE_FILE}.tmp.$$"
cat >"$STATE_TMP" <<EOF
{
  "mode": "${STATE_MODE}",
  "wan_if": "${WAN_IF}",
  "wan_ssid": "${WAN_SSID}",
  "wan_ip": "${WAN_IP}",
  "lan_ip": "${LAN_IP}",
  "ap_interface": "${LAN_IF}",
  "wan_pref": "${TRAVELROUTER_WAN_PREFER}",
  "timestamp": "${TS}"
}
EOF
mv -f "$STATE_TMP" "$TRAVELROUTER_STATE_FILE"

if [[ "$PREV_LAN" != "$LAN_IP" ]]; then
  log "lan_ip changed ($PREV_LAN -> $LAN_IP): try-restart travel-router-status.service"
  run_or_log systemctl try-restart travel-router-status.service
fi

log "wan_select_done mode=${STATE_MODE} wan_if='${WAN_IF}' lan_if='${LAN_IF}' lan_ip='${LAN_IP}'"
exit 0
