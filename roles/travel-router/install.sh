#!/bin/bash
# travel-router: apt + render-once + systemd bring-up of the travel-router role.
#
# Install happens during role-setup.service. It (1) installs hostapd/dnsmasq/
# nftables/iw BEFORE touching NetworkManager, (2) resolves the AP iface the same
# way wan-select does, (3) renders the unit configs exactly once, (4) enables/
# restarts the systemd units incl. the mandatory `systemctl restart dnsmasq`
# (the stock package auto-starts an inert dnsmasq that a plain enable would
# leave running), and (5) prints a final banner.
#
# Single-owner rule: THIS script is the sole owner of the hostapd/dnsmasq/sysctl
# files; wan-select never re-renders them.
#
# Test seam (REQUIRED): honours TRAWELROUTER_DRY_RUN=1 + DRY_RUN_PREFIX=<dir> so
# the QA battery runs on a non-Pi (macOS) runner: every write lands under the
# prefix and every system-mutating call (apt/systemctl/sysctl/ip/iw/rfkill/nft)
# is skipped/logged while validation + renders still execute.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

ROLE_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$ROLE_DIR/assets"
LOG_TAG="[travel-router]"
# bash 3.2 (/bin/bash on older macOS) chokes on [[ =~ ]] with a literal
# character range that begins with a space ([ -~]). Put the pattern behind a
# variable so it works there and on 5.x.
PRINTABLE_RE='^[ -~]{1,32}$'

log() { echo "$LOG_TAG $*"; }

# --- DRY RUN ---------------------------------------------------------------
# truthy check: 1 | true | yes | on
DRY_RUN=0
case "${TRAWELROUTER_DRY_RUN:-0}" in
  1|true|yes|on) DRY_RUN=1 ;;
esac
DRY_RUN_PREFIX="${DRY_RUN_PREFIX:-/}"
# Collapse a trailing slash but keep a lone "/".
while [[ "${DRY_RUN_PREFIX}" == */ && "${DRY_RUN_PREFIX}" != "/" ]]; do
  DRY_RUN_PREFIX="${DRY_RUN_PREFIX%/}"
done

# real_or_log CMD... : execute for real; in DRY_RUN log it and return without
# mutating the host. Every system-mutating action goes through here.
real_or_log() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run: $*"
    return 0
  fi
  "$@"
}

# --- (1) Source role.env (two-path idiom, mirrors the tailscale role) --------
ROLE_ENV="${TRAWELROUTER_ROLE_ENV:- /run/travel-router/role.env}"
[[ -f "$ROLE_ENV" ]] || ROLE_ENV="/boot/firmware/role/role.env"
[[ -f "$ROLE_ENV" ]] || ROLE_ENV="/boot/role/role.env"
if [[ -f "$ROLE_ENV" ]]; then
  log "loading $ROLE_ENV"
  set -a; source "$ROLE_ENV" 2>/dev/null || true; set +a
else
  log "no role.env found at any known path (continuing with defaults; dry-run ok)"
fi

# --- Defaults --------------------------------------------------------------
: "${TRAWELROUTER_AP_COUNTRY:=US}"
: "${TRAWELROUTER_AP_NAME:=travel-router}"

# --- (2) Validate required vars BEFORE apt ---------------------------------
# Render idiom is `sed 's|__X__|$VAL|g'`: a value with | / \ or a newline breaks
# the substitution, so reject those up front with a clear remediation.
fail() {
  log "ERROR: $1"
  log "  remediation: $2"
  exit 1
}

# Generate a charset-VALID random PSK when none is supplied: openssl rand
# -base64 can emit + / =, which the validation below rejects. Pull from
# /dev/urandom filtered to the exact allowed alphabet so the default is always
# 8-63 chars of [A-Za-z0-9._-] and contains no | \ & or newline.
pkey="${TRAWELROUTER_PSK:-}"
if [[ -z "$pkey" ]]; then
  # No PSK supplied: generate one that is already validation-safe. Using a
  # fixed-count dd (no pipeline early-close/SIGPIPE) means we don't trip
  # `set -euo pipefail`. A fallback covers the (extremely unlikely) case of
  # zero printable bytes, so the generated default is always 8-63 chars of
  # [A-Za-z0-9._-] and contains no | / & or newline.
  p_30="$(LC_ALL=C dd if=/dev/urandom count=4 bs=16 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9._-')"
  # tr may filter the random bytes down below 8 chars; retry until the key
  # is at least the minimum accepted length, then truncate to a safe length
  # (still well within 8-63) if it somehow exceeds it.
  while [[ -n "$p_30" && ${#p_30} -lt 8 && ${p_30_runs:-0} -lt 64 ]]; do
    p_30="$(LC_ALL=C dd if=/dev/urandom count=4 bs=16 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9._-')"
    p_30_runs=$((p_30_runs + 1))
  done
  [[ -n "$p_30" ]] || p_30="$(printf %s "${RANDOM:-$$}${RANDOM:-$$}" | tr -dc 'A-Za-z0-9._-')"
  [[ -n "$p_30" ]] || p_30="travelrouter"
  [[ ${#p_30} -gt 63 ]] && p_30="${p_30:0:63}"
  pkey="$p_30"
fi
sid="${TRAWELROUTER_AP_NAME}"
if [[ -z "${sid:-}" ]]; then
  fail "AP_SSID (TRAWELROUTER_AP_NAME) is empty" "set a non-empty TRAWELROUTER_AP_NAME (printable ASCII, <=32 chars)"
fi
if [[ -z "${pkey:-}" ]]; then
  fail "AP_PSK (TRAWELROUTER_PSK) is empty" "set TRAWELROUTER_PSK in role.env (8-63 chars, A-Za-z0-9._- only)"
fi
if [[ "${#sid}" -gt 32 ]]; then
  fail "AP_SSID too long (${#sid} > 32)" "TRAWELROUTER_AP_NAME must be printable ASCII, <=32 chars"
fi
printf '%s' "$sid" | grep -qE "$PRINTABLE_RE" || fail "AP_SSID has illegal characters" "TRAWELROUTER_AP_NAME must be printable ASCII only"
pkey_len="${#pkey}"
if [[ "$pkey_len" -lt 8 || "$pkey_len" -gt 63 ]]; then
  fail "AP_PSK length ${pkey_len} outside 8-63" "set a TRAWELROUTER_PSK between 8 and 63 characters"
fi
# Disallow the render-breakers and any char outside the allowed whitelist.
case "$pkey" in
  *'|'*|*'\\'*|*'$'*|*'\n'*) fail "AP_PSK contains a render-breaker char (|, \, or $)" \
    "remove | / \ / $ from TRAWELROUTER_PSK; they break the sed render" ;;
esac
pchars="[^A-Za-z0-9._-]"
printf "%s" "$pkey" | grep -qE "$pchars" && fail "AP_PSK has a char outside A-Za-z0-9._-$" \
  "trim TRAWELROUTER_PSK to letters, digits and . _ -"

# --- (3) Run the base role first (tailscale idiom) -------------------------
# Idempotent: if a prior role already ran base, apt + common packages exist.
# base is auto-staged by the provisioner; call it here so prerequisites exist
# before we pull hostapd/dnsmasq. Run BEFORE the unmanage step.
DERIVED_BASE=0
for base in /boot/firmware/role/base/install.sh /boot/role/base/install.sh; do
  if [[ -x "$base" ]]; then
    DERIVED_BASE=1
    log "running base role"
    real_or_log bash "$base"
    break
  fi
done
[[ "$DERIVED_BASE" -eq 0 ]] || log "no base role found at /boot path (base is auto-staged by provisioner)"

# --- (4) apt BEFORE unmanaging wlan0 (network still up, NM still manages it) --
# NOTE: the stock dnsmasq package AUTO-STARTS dnsmasq.service here with the
# empty stock config. That is expected and inert; step (8) restarts it.
log "installing hostapd dnsmasq nftables iw (network still up at this point)"
real_or_log apt-get update
real_or_log apt-get install -y --no-install-recommends hostapd dnsmasq nftables iw

# --- (5) Install scripts to their final locations --------------------------
mkdir -p "${DRY_RUN_PREFIX}/usr/local/lib/travel-router" "${DRY_RUN_PREFIX}/usr/local/bin"
if [[ "$DRY_RUN" -ne 1 ]]; then
  mkdir -p /usr/local/lib/travel-router
  install -m 0644 "$ASSETS/wan-select.sh"      /usr/local/lib/travel-router/wan-select.sh
  install -m 0755 "$ASSETS/status-server.py"   /usr/local/lib/travel-router/status-server.py
  install -m 0755 "$ASSETS/travel-wan.sh"      /usr/local/bin/travel-wan
  log "installed travel-router scripts to /usr/local/{bin,lib/travel-router}"
else
  cp "$ASSETS/wan-select.sh"     "${DRY_RUN_PREFIX}/usr/local/lib/travel-router/wan-select.sh"
  cp "$ASSETS/status-server.py"  "${DRY_RUN_PREFIX}/usr/local/lib/travel-router/status-server.py"
  cp "$ASSETS/travel-wan.sh"     "${DRY_RUN_PREFIX}/usr/local/bin/travel-wan"
  chmod 0644 "${DRY_RUN_PREFIX}/usr/local/lib/travel-router/wan-select.sh"
  chmod 0644 "${DRY_RUN_PREFIX}/usr/local/lib/travel-router/status-server.py"
  chmod 0755 "${DRY_RUN_PREFIX}/usr/local/bin/travel-wan"
  log "dry-run: staged scripts under prefix"
fi

# --- (6) Resolve the AP iface + unmanage it --------------------------------
# SAME rule as wan-select: first wireless whose /sys/class/net/<if>/device path
# does NOT contain /usb (onboard SDIO radio), fallback wlan0. On a non-Pi the
# enumeration is empty so this degrades gracefully to wlan0.
ap="${TRAWELROUTER_AP_IFACE:-}"
if [[ -z "$ap" && -d /sys/class/net ]]; then
  for d in /sys/class/net/*; do
    [[ -d "$d" ]] || continue
    name=$(basename "$d")
    if [[ -d "${d}/wireless" ]]; then
      dev=""
      [[ -e "${d}/device" ]] && dev=$(readlink -f "${d}/device" 2>/dev/null || true)
      if [[ "$dev" != *usb* ]] && [[ -z "$ap" ]]; then
        ap="$name"
      fi
    fi
  done
fi
[[ -z "$ap" ]] && ap="wlan0"
log "AP interface: '${ap}'"

# # NM unmanaged drop-in (rendered once from assets/unmanaged.conf so the
# AP interface name is written exactly once, in one place). Names only the AP
# iface, so the Pi's home-WiFi client connection stays managed for recovery.
# Written AFTER apt (step 4) so the network did not flap during install.
unmanaged="${DRY_RUN_PREFIX}/etc/NetworkManager/conf.d/90-travel-router-unmanaged.conf"
mkdir -p "${DRY_RUN_PREFIX}/etc/NetworkManager/conf.d"
sed -e "s|__AP_INTERFACE__|${ap}|g" "$ASSETS/unmanaged.conf" > "$unmanaged"
chmod 0644 "$unmanaged"
real_or_log systemctl restart NetworkManager
log "NM unmanaged conf (iface=${ap}) -> ${unmanaged}"

# --- (7) Render ONCE (hostapd, dnsmasq, sysctl) ----------------------------
# install.sh is the sole owner of these files; wan-select never re-renders.
mkdir -p "${DRY_RUN_PREFIX}/etc/hostapd" "${DRY_RUN_PREFIX}/etc/dnsmasq.d" "${DRY_RUN_PREFIX}/etc/sysctl.d"
hostapd_conf="${DRY_RUN_PREFIX}/etc/hostapd/hostapd-travel.conf"
sed -e "s|__AP_INTERFACE__|${ap}|g" \
    -e "s|__AP_SSID__|${TRAWELROUTER_AP_NAME}|g" \
    -e "s|__AP_COUNTRY__|${TRAWELROUTER_AP_COUNTRY}|g" \
    -e "s|__AP_CHANNEL__|${TRAWELROUTER_AP_CHANNEL:-6}|g" \
    -e "s|__AP_PSK__|${pkey}|g" \
    "$ASSETS/hostapd.conf.tmpl" > "$hostapd_conf"

dnsmasq_conf="${DRY_RUN_PREFIX}/etc/dnsmasq.d/travel-router.conf"
sed -e "s|__LAN_INTERFACE__|${ap}|g" \
    -e "s|__DHCP_RANGE__|${TRAWELROUTER_DHCP_RANGE:-192.168.50.100,192.168.50.200,12h}|g" \
    "$ASSETS/dnsmasq.conf.tmpl" > "$dnsmasq_conf"

sysctl_conf="${DRY_RUN_PREFIX}/etc/sysctl.d/90-travel-router.conf"
# sysctl has no render substitutions; copy verbatim (sed needs an expression
# and would error on a bare filename).
cp "$ASSETS/90-travel-router.conf.sysctl" "$sysctl_conf"
chmod 0644 "$sysctl_conf"
real_or_log sysctl --system
log "rendered hostapd/dnsmasq/sysctl to ${DRY_RUN_PREFIX}"

# --- (8) systemd units: daemon-reload, enable, RESTART dnsmasq -------------
real_or_log systemctl daemon-reload
real_or_log systemctl enable --now wan-select.service
# MANDATORY restart: the stock-config dnsmasq from apt is already active; a
# plain enable is a no-op on an already-running unit. The rendered config only
# loads on (re)start.
real_or_log systemctl restart dnsmasq.service
real_or_log systemctl enable --now hostapd-travel.service
real_or_log systemctl enable --now wan-select.timer
real_or_log systemctl enable --now travel-router-status.service
log "system wiring done: wan-select + hostapd-travel enabled, dnsmasq restarted"

# --- (9) Sanity-assert stock dnsmasq is inert ------------------------------
dnsmasq_d="${DRY_RUN_PREFIX}/etc/dnsmasq.d"
[[ -d "$dnsmasq_d" ]] || { log "ERROR: ${dnsmasq_d} does not exist"; exit 1; }
# RPi OS ships dnsmasq.conf fully commented out; an active listen-address here
# means a second dnsmasq instance would be listening -> conflict. Abort before
# bringing up hostapd/dnsmasq on top of it (skip in dry-run).
if [[ "$DRY_RUN" -ne 1 && -r /etc/dnsmasq.conf ]]; then
  if grep -Eq '^[[:space:]]*listen-address' /etc/dnsmasq.conf; then
    log "ERROR: stock /etc/dnsmasq.conf has an active listen-address (not inert)"
    log "  remediation: comment that line out in /etc/dnsmasq.conf, then re-run role-setup"
    exit 1
  fi
fi
log "sanity: dnsmasq.d present, stock config inert"

# --- (10) Final banner -----------------------------------------------------
lan_ip=$(printf "%s" "${TRAWELROUTER_LAN_CIDR:-192.168.50.1/24}" | sed "s|/.*||")
status_port="${TRAWELROUTER_STATUS_PORT:-80}"
if [[ "$status_port" == "80" ]]; then
  status_url="http://${lan_ip}"
else
  status_url="http://${lan_ip}:${status_port}"
fi
echo "-----------------------------------------------"
echo "travel-router installed"
echo "  AP SSID     : ${TRAWELROUTER_AP_NAME}"
echo "  AP iface    : ${ap}"
echo "  LAN IP      : ${lan_ip}"
echo "  Status page : ${status_url}"
echo "  Manage      : ssh pi@${lan_ip} 'travel-wan connect <SSID> <PSK>'"
echo "NOTE: the Pi is only reachable over the ${TRAWELROUTER_AP_NAME}"
echo "  SSID or a USB Ethernet adapter (restores NM-managed connectivity)."
echo "-----------------------------------------------"
log "travel-router install complete"
