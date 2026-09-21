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
# files; wan-select never re-renders them. ONE EXCEPTION (H03): wan-select
# solely owns /etc/dnsmasq.d/travel-router-portal.conf (captive-portal probe
# hijack, standalone only) — this script stages its TEMPLATE but never renders
# or restarts dnsmasq for it; wan-select restarts dnsmasq only on toggle.
#
# Test seam (REQUIRED): honours TRAVELROUTER_DRY_RUN=1 + DRY_RUN_PREFIX=<dir> so
# the QA battery runs on a non-Pi (macOS) runner: every write lands under the
# prefix and every system-mutating call (apt/systemctl/sysctl/ip/iw/rfkill/nft)
# is skipped/logged while validation + renders still execute.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Pin the locale for the whole script: the validation regexes below use range
# expressions ([ -~]), and glibc grep under a UTF-8 locale (the Pi default,
# LANG=en_US.UTF-8) evaluates ranges by COLLATION order — ASCII letters sort
# after '~', so every letter-bearing SSID/PSK failed the "printable ASCII"
# check on real hardware (rpi-e076fe first boot, GNU grep 3.11). BSD grep on
# the macOS runner is byte-true, so the suite never caught it. LC_ALL=C makes
# the ranges mean raw code points everywhere.
export LC_ALL=C

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
case "${TRAVELROUTER_DRY_RUN:-0}" in
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

# TRAVELROUTER_DEFAULT_PSKS may arrive via the environment (provisioning
# export) OR role.env. Capture the env value BEFORE the role.env sourcing
# below: `set -a` sourcing would overwrite it, and an explicitly exported
# env value must win over the role.env copy (ad-hoc re-runs override the
# staged defaults). Empty/unset means no d-rows to seed (see (4c)).
TR_DEFAULTS_ENV="${TRAVELROUTER_DEFAULT_PSKS:-}"

# --- (1) Source role.env (two-path idiom, mirrors the tailscale role) --------
ROLE_ENV="${TRAVELROUTER_ROLE_ENV:-/run/travel-router/role.env}"
[[ -f "$ROLE_ENV" ]] || ROLE_ENV="/boot/firmware/role/role.env"
[[ -f "$ROLE_ENV" ]] || ROLE_ENV="/boot/role/role.env"
if [[ -f "$ROLE_ENV" ]]; then
  log "loading $ROLE_ENV"
  set -a; source "$ROLE_ENV" 2>/dev/null || true; set +a
else
  log "no role.env found at any known path (continuing with defaults; dry-run ok)"
fi

# --- Defaults --------------------------------------------------------------
: "${TRAVELROUTER_AP_COUNTRY:=${WIFI_COUNTRY:-US}}"
# AP_SSID / AP_PSK intentionally have NO defaults: both are required by the
# role contract (see .env.example). A random PSK would leave an AP nobody can
# discover the key for; a default SSID hides a missing config.

# --- (2) Validate required vars BEFORE apt ---------------------------------
# Render idiom is `sed 's|__X__|$VAL|g'`: a value with | / \ or a newline breaks
# the substitution, so reject those up front with a clear remediation.
fail() {
  log "ERROR: $1"
  log "  remediation: $2"
  exit 1
}

# AP_PSK is REQUIRED (8-63 chars of [A-Za-z0-9._-]); an empty value fails
# below so the AP never comes up with a key nobody knows.
pkey="${TRAVELROUTER_AP_PSK:-}"
sid="${TRAVELROUTER_AP_SSID:-}"
if [[ -z "${sid:-}" ]]; then
  fail "AP_SSID (TRAVELROUTER_AP_SSID) is empty" "set a non-empty TRAVELROUTER_AP_SSID (printable ASCII, <=32 chars)"
fi
if [[ -z "${pkey:-}" ]]; then
  fail "AP_PSK (TRAVELROUTER_AP_PSK) is empty" "set TRAVELROUTER_AP_PSK in role.env (8-63 chars, A-Za-z0-9._- only)"
fi
if [[ "${#sid}" -gt 32 ]]; then
  fail "AP_SSID too long (${#sid} > 32)" "TRAVELROUTER_AP_SSID must be printable ASCII, <=32 chars"
fi
printf '%s' "$sid" | grep -qE "$PRINTABLE_RE" || fail "AP_SSID has illegal characters" "TRAVELROUTER_AP_SSID must be printable ASCII only"
# Same render-breaker battery as the PSK below, plus &: the SSID is sed-rendered
# into hostapd.conf and echoed in the banner. *$'\n'* matches a REAL newline
# (a plain *'\n'* would only match a literal backslash-n).
case "$sid" in
  *'|'*|*'\'*|*'$'*|*'&'*|*$'\n'*) fail "AP_SSID contains a render-breaker char (|, \, $, or &)" \
    "remove | / \ / $ / & from TRAVELROUTER_AP_SSID; they break the sed render" ;;
esac
pkey_len="${#pkey}"
if [[ "$pkey_len" -lt 8 || "$pkey_len" -gt 63 ]]; then
  fail "AP_PSK length ${pkey_len} outside 8-63" "set a TRAVELROUTER_AP_PSK between 8 and 63 characters"
fi
# Disallow the render-breakers and any char outside the allowed whitelist.
case "$pkey" in
  *'|'*|*'\'*|*'$'*|*'&'*|*$'\n'*) fail "AP_PSK contains a render-breaker char (|, \, $, or &)" \
    "remove | / \ / $ / & from TRAVELROUTER_AP_PSK; they break the sed render" ;;
esac
pchars="[^A-Za-z0-9._-]"
printf "%s" "$pkey" | grep -qE "$pchars" && fail "AP_PSK has a char outside A-Za-z0-9._-$" \
  "trim TRAVELROUTER_AP_PSK to letters, digits and . _ -"

# SETUP_PIN is REQUIRED: it gates the phone setup API (deny-by-default in
# status-server when unset — H01; this validation makes it always present).
upin="${TRAVELROUTER_SETUP_PIN:-}"
if [[ -z "$upin" ]]; then
  fail "SETUP_PIN (TRAVELROUTER_SETUP_PIN) is empty" \
    "set TRAVELROUTER_SETUP_PIN in role.env (4-12 chars of A-Za-z0-9; it unlocks the phone setup page)"
fi
if [[ "${#upin}" -lt 4 || "${#upin}" -gt 12 ]]; then
  fail "SETUP_PIN length ${#upin} outside 4-12" "TRAVELROUTER_SETUP_PIN must be 4-12 characters"
fi
printf '%s' "$upin" | grep -qE '^[A-Za-z0-9]+$' || fail "SETUP_PIN has illegal characters" \
  "TRAVELROUTER_SETUP_PIN must be A-Za-z0-9 only (phone-keyboard-friendly)"

# ADMIN_PSK is REQUIRED: it gates the setup page + every change alongside the
# PIN. Same render-breaker battery as the SSID (it is sed-rendered nowhere, but
# the same chars also break the systemd EnvironmentFile printf staging below).
apsk="${TRAVELROUTER_ADMIN_PSK:-}"
if [[ -z "$apsk" ]]; then
  fail "ADMIN_PSK (TRAVELROUTER_ADMIN_PSK) is empty" \
    "set TRAVELROUTER_ADMIN_PSK in role.env (>=8 printable-ASCII chars; it gates the setup page + all changes alongside the PIN)"
fi
if [[ "${#apsk}" -lt 8 ]]; then
  fail "ADMIN_PSK too short (${#apsk} < 8)" "TRAVELROUTER_ADMIN_PSK must be at least 8 printable-ASCII characters"
fi
case "$apsk" in
  *'|'*|*'\'*|*'$'*|*'&'*|*$'\n'*) fail "ADMIN_PSK contains a render-breaker char (|, \, $, &, or a newline)" \
    "remove | / \ / $ / & from TRAVELROUTER_ADMIN_PSK; they break the env staging" ;;
esac
printf '%s' "$apsk" | grep -qE '^[ -~]+$' || fail "ADMIN_PSK has non-printable characters" \
  "TRAVELROUTER_ADMIN_PSK must be printable ASCII only"

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
[[ "$DERIVED_BASE" -eq 0 ]] && log "no base role found at /boot path (base is auto-staged by provisioner)"

# --- (4) apt BEFORE unmanaging wlan0 (network still up, NM still manages it) --
# NOTE: the stock dnsmasq package AUTO-STARTS dnsmasq.service here with the
# empty stock config. That is expected and inert; step (8) restarts it.
log "installing hostapd dnsmasq nftables iw (network still up at this point)"
real_or_log apt-get update
real_or_log apt-get install -y --no-install-recommends hostapd dnsmasq nftables iw

# --- (4b) Seed the bootstrap WAN profile (WIFI_SSID as the initial "hotel") --
# The provisioning WiFi (wired into role.env by the provisioners) becomes the
# FIRST WAN profile: NM auto-activates it on any MANAGED wifi device (the USB
# dongle), exactly as if it had been picked on the setup page. The AP
# interface is unmanaged in step (6), so it can never activate there.
# Idempotent: skip when a profile with id=WIFI_SSID already exists (Bookworm
# firstrun.sh seeds one). DRY_RUN logs the command with the PSK redacted.
if [[ -n "${WIFI_SSID:-}" ]]; then
  if [[ "$DRY_RUN" -ne 1 ]] && nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$WIFI_SSID"; then
    log "WAN bootstrap profile '${WIFI_SSID}' already exists (provisioner seed); skipping"
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: nmcli connection add type wifi con-name '${WIFI_SSID}' ssid '${WIFI_SSID}' wifi-sec.psk <redacted> connection.autoconnect yes"
  elif [[ -n "${WIFI_PSK:-}" ]]; then
    nmcli connection add type wifi ifname '*' con-name "$WIFI_SSID" ssid "$WIFI_SSID" \
      wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PSK" connection.autoconnect yes
    log "seeded WAN bootstrap profile '${WIFI_SSID}' (autoconnect, any managed wifi device)"
  else
    nmcli connection add type wifi ifname '*' con-name "$WIFI_SSID" ssid "$WIFI_SSID" \
      connection.autoconnect yes
    log "seeded WAN bootstrap profile '${WIFI_SSID}' (open network)"
  fi
else
  log "no WIFI_SSID in role.env — skipping WAN bootstrap profile (standalone AP first boot)"
fi

# --- (4c) Seed the known-psks store (default PSK candidates) -----------------
# Store: TAB-schema rows at /etc/rpi-project/travel-router/known-psks (0600,
# root). d-rows (d<TAB><TAB><psk>) are the defaults from
# TRAVELROUTER_DEFAULT_PSKS (comma-separated; env-exported at provisioning,
# pre-captured above so env wins over role.env). Re-runs PRESERVE all s-rows
# (collected candidates) and refresh only the d-rows. Like every render in
# this script, the REAL file lands under DRY_RUN_PREFIX in dry-run mode.
KPSK_DIR="${DRY_RUN_PREFIX}/etc/rpi-project/travel-router"
KPSK_FILE="$KPSK_DIR/known-psks"
mkdir -p "$KPSK_DIR"
# parse + validate defaults: reject TAB/CR/LF in any PSK value (TAB is the
# store's row/column delimiter; CR/LF would forge rows)
KPSK_BAD=0
KPSK_VALS=""
IFS=',' read -r -a KPSK_ARR <<< "${TR_DEFAULTS_ENV:-${TRAVELROUTER_DEFAULT_PSKS:-}}"
for kv in ${KPSK_ARR[@]+"${KPSK_ARR[@]}"}; do
    kv="${kv#"${kv%%[![:space:]]*}"}"
    kv="${kv%"${kv##*[![:space:]]}"}"
    [[ -n "$kv" ]] || continue
    case "$kv" in
        *$'\t'*|*$'\r'*|*$'\n'*|*$'\v'*|*$'\f'*) KPSK_BAD=1 ;;
    esac
    KPSK_VALS+="${KPSK_VALS:+$'\n'}$kv"
done
# setup-v2 M4: optional .psksecret seed file — TRAVELROUTER_PSKSECRET_FILE
# env wins; default lookup uses the same two-path idiom as ROLE_ENV (the
# provisioner stages .psksecret next to role.env). Absent -> no file d-rows.
PSKSECRET_SRC="${TRAVELROUTER_PSKSECRET_FILE:-}"
if [[ -z "$PSKSECRET_SRC" ]]; then
  for cand in "${ROLE_ENV%/*}/.psksecret" /boot/firmware/role/.psksecret /boot/role/.psksecret; do
    [[ -f "$cand" ]] && { PSKSECRET_SRC="$cand"; break; }
  done
fi
KPSK_SECRET_STAGE="$KPSK_DIR/psksecret"
if [[ -n "$PSKSECRET_SRC" && -f "$PSKSECRET_SRC" ]]; then
    while IFS= read -r kv; do
        kv="${kv#"${kv%%[![:space:]]*}"}"
        kv="${kv%"${kv##*[![:space:]]}"}"
        [[ -n "$kv" ]] || continue
        case "$kv" in
            '#'*) continue ;;
            *$'\t'*|*$'\r'*|*$'\n'*|*$'\v'*|*$'\f'*) KPSK_BAD=1; continue ;;
        esac
        KPSK_VALS+="${KPSK_VALS:+$'\n'}$kv"
    done < "$PSKSECRET_SRC"
elif [[ -n "${TRAVELROUTER_PSKSECRET_FILE:-}" ]]; then
  fail "TRAVELROUTER_PSKSECRET_FILE points at a missing file ($TRAVELROUTER_PSKSECRET_FILE)" \
    "stage .psksecret next to role.env (or set TRAVELROUTER_PSKSECRET_FILE to an existing file)"
fi
# de-dupe d-row values (env first, file appended; keep first occurrence)
if [[ -n "$KPSK_VALS" ]]; then
    KPSK_DEDUPED=""
    while IFS= read -r kv; do
        [[ -n "$kv" ]] || continue
        KPSK_DEDUPED+="${KPSK_DEDUPED:+$'\n'}$kv"
    done <<< "$(printf '%s\n' "$KPSK_VALS" | awk '!seen[$0]++')"
    KPSK_VALS="$KPSK_DEDUPED"
fi
if [[ "$KPSK_BAD" -eq 1 ]]; then
  fail "TRAVELROUTER_DEFAULT_PSKS/.psksecret contains a PSK with TAB/CR/LF" \
    "remove the offending PSK value and re-run (store not modified)"
fi
# build the new store content: existing s-rows first (preserved verbatim),
# then fresh d-rows from the defaults
KPSK_OUT=""
if [[ -f "$KPSK_FILE" ]]; then
    while IFS= read -r KROW || [[ -n "$KROW" ]]; do
        case "$KROW" in
            s$'\t'*) KPSK_OUT+="${KROW}"$'\n' ;;
        esac
    done < "$KPSK_FILE"
fi
while IFS= read -r kv; do
    [[ -n "$kv" ]] || continue
    KPSK_OUT+="d"$'\t'$'\t'"${kv}"$'\n'
done <<< "$KPSK_VALS"
KPSK_TMP="$KPSK_DIR/.known-psks.$$"
printf '%s' "$KPSK_OUT" > "$KPSK_TMP"
chmod 0600 "$KPSK_TMP"
mv -f "$KPSK_TMP" "$KPSK_FILE"
if [[ -n "$KPSK_VALS" ]]; then
  log "known-psks store seeded with $(printf '%s\n' "$KPSK_VALS" | grep -c .) default PSK candidate(s) from env + .psksecret (values redacted)"
else
  touch "$KPSK_FILE" && chmod 0600 "$KPSK_FILE"
  log "known-psks store present, no default PSK candidates to seed"
fi
# setup-v2 M4: stage the psksecret copy itself (0600) for runtime provenance;
# absent source -> skip staging quietly (never an error).
if [[ -n "$PSKSECRET_SRC" && -f "$PSKSECRET_SRC" ]]; then
    cp "$PSKSECRET_SRC" "$KPSK_SECRET_STAGE"
    chmod 0600 "$KPSK_SECRET_STAGE"
    log "staged .psksecret copy (0600) from '$PSKSECRET_SRC' (values redacted)"
fi

# --- (5) Install scripts to their final locations --------------------------
mkdir -p "${DRY_RUN_PREFIX}/usr/local/lib/travel-router" "${DRY_RUN_PREFIX}/usr/local/bin"
if [[ "$DRY_RUN" -ne 1 ]]; then
  mkdir -p /usr/local/lib/travel-router
  install -m 0755 "$ASSETS/wan-select.sh"      /usr/local/lib/travel-router/wan-select.sh
  install -m 0755 "$ASSETS/status-server.py"   /usr/local/lib/travel-router/status-server.py
  install -m 0755 "$ASSETS/travel-wan.sh"      /usr/local/bin/travel-wan
  install -m 0644 "$ASSETS/setup.html"         /usr/local/lib/travel-router/setup.html
  install -m 0644 "$ASSETS/nftables.conf.tmpl" /usr/local/lib/travel-router/nftables.conf.tmpl
  install -m 0644 "$ASSETS/portal-dnsmasq.conf.tmpl" /usr/local/lib/travel-router/portal-dnsmasq.conf.tmpl
  mkdir -p /etc/systemd/system
  for unit in wan-select.service wan-select.timer hostapd-travel.service travel-router-status.service; do
    install -m 0644 "$ASSETS/$unit" "/etc/systemd/system/$unit"
  done
  log "installed travel-router scripts to /usr/local/{bin,lib/travel-router}"
else
  cp "$ASSETS/wan-select.sh"     "${DRY_RUN_PREFIX}/usr/local/lib/travel-router/wan-select.sh"
  cp "$ASSETS/status-server.py"  "${DRY_RUN_PREFIX}/usr/local/lib/travel-router/status-server.py"
  cp "$ASSETS/travel-wan.sh"     "${DRY_RUN_PREFIX}/usr/local/bin/travel-wan"
  cp "$ASSETS/setup.html"        "${DRY_RUN_PREFIX}/usr/local/lib/travel-router/setup.html"
  cp "$ASSETS/nftables.conf.tmpl" "${DRY_RUN_PREFIX}/usr/local/lib/travel-router/nftables.conf.tmpl"
  cp "$ASSETS/portal-dnsmasq.conf.tmpl" "${DRY_RUN_PREFIX}/usr/local/lib/travel-router/portal-dnsmasq.conf.tmpl"
  chmod 0755 "${DRY_RUN_PREFIX}/usr/local/lib/travel-router/wan-select.sh"
  chmod 0755 "${DRY_RUN_PREFIX}/usr/local/lib/travel-router/status-server.py"
  chmod 0755 "${DRY_RUN_PREFIX}/usr/local/bin/travel-wan"
  mkdir -p "${DRY_RUN_PREFIX}/etc/systemd/system"
  for unit in wan-select.service wan-select.timer hostapd-travel.service travel-router-status.service; do
    cp "$ASSETS/$unit" "${DRY_RUN_PREFIX}/etc/systemd/system/$unit"
  done
  log "dry-run: staged scripts under prefix"
fi

# --- (6) Resolve the AP iface + unmanage it --------------------------------
# SAME rule as wan-select: first wireless whose /sys/class/net/<if>/device path
# does NOT contain /usb (onboard SDIO radio), fallback wlan0. On a non-Pi the
# enumeration is empty so this degrades gracefully to wlan0.
ap=""
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
    -e "s|__AP_SSID__|${TRAVELROUTER_AP_SSID}|g" \
    -e "s|__AP_COUNTRY__|${TRAVELROUTER_AP_COUNTRY}|g" \
    -e "s|__AP_CHANNEL__|${TRAVELROUTER_AP_CHANNEL:-6}|g" \
    -e "s|__AP_PSK__|${pkey}|g" \
    -e '/__AP_HIDDEN__/d' \
    "$ASSETS/hostapd.conf.tmpl" > "$hostapd_conf"
chmod 0600 "$hostapd_conf"

dnsmasq_conf="${DRY_RUN_PREFIX}/etc/dnsmasq.d/travel-router.conf"
sed -e "s|__LAN_INTERFACE__|${ap}|g" \
    -e "s|__DHCP_RANGE__|${TRAVELROUTER_DHCP_RANGE:-192.168.50.100,192.168.50.200,12h}|g" \
    "$ASSETS/dnsmasq.conf.tmpl" > "$dnsmasq_conf"

# DHCP connection log: log-dhcp events land in a dedicated bounded file (not
# journald — a Zero W needs a small window). logrotate owns the bound:
# size 1M + rotate 5 + copytruncate, so dnsmasq keeps writing without a
# signal (it has no built-in rotation). Metadata only: hostname/MAC/IP.
log_dir="${DRY_RUN_PREFIX}/var/log/travel-router"
mkdir -p "$log_dir"
touch "$log_dir/dhcp.log"
chmod 0644 "$log_dir/dhcp.log"
logrotate_conf="${DRY_RUN_PREFIX}/etc/logrotate.d/travel-router-dhcp"
mkdir -p "${DRY_RUN_PREFIX}/etc/logrotate.d"
cat > "$logrotate_conf" <<'EOF'
/var/log/travel-router/*.log {
    size 1M
    rotate 5
    copytruncate
    missingok
    notifempty
    compress
}
EOF
chmod 0644 "$logrotate_conf"

sysctl_conf="${DRY_RUN_PREFIX}/etc/sysctl.d/90-travel-router.conf"
# sysctl has no render substitutions; copy verbatim (sed needs an expression
# and would error on a bare filename).
cp "$ASSETS/90-travel-router.conf.sysctl" "$sysctl_conf"
chmod 0644 "$sysctl_conf"
real_or_log sysctl --system

# PIN delivery: the status unit reads it from a tmpfs EnvironmentFile (H05).
# Written BEFORE the unit enable below; 0600 (secret); /run is tmpfs so it
# does not persist on disk. Missing file -> unit still starts (deny-by-default).
pin_env_dir="${DRY_RUN_PREFIX}/run/travel-router/role-env"
mkdir -p "$pin_env_dir"
printf 'TRAVELROUTER_SETUP_PIN="%s"\n' "$upin" > "${pin_env_dir}/travel-router-setup.env"
printf 'TRAVELROUTER_ADMIN_PSK="%s"\n' "$apsk" >> "${pin_env_dir}/travel-router-setup.env"
chmod 0600 "${pin_env_dir}/travel-router-setup.env"
log "staged PIN+PSK EnvironmentFile (0600, tmpfs) -> ${pin_env_dir}/travel-router-setup.env"
log "rendered hostapd/dnsmasq/sysctl to ${DRY_RUN_PREFIX}"

# --- (8) Sanity-assert stock dnsmasq is inert (BEFORE any enable/restart) ----
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

# --- (9) systemd units: daemon-reload, enable, RESTART dnsmasq -------------
real_or_log systemctl daemon-reload
real_or_log systemctl enable --now wan-select.service
real_or_log systemctl enable dnsmasq.service
# MANDATORY restart: the stock-config dnsmasq from apt is already active; a
# plain enable is a no-op on an already-running unit. The rendered config only
# loads on (re)start.
real_or_log systemctl restart dnsmasq.service
real_or_log systemctl enable --now hostapd-travel.service
real_or_log systemctl enable --now wan-select.timer
real_or_log systemctl enable --now travel-router-status.service
log "system wiring done: wan-select + hostapd-travel enabled, dnsmasq enabled+restarted"

# --- (10) Final banner -----------------------------------------------------
lan_ip=$(printf "%s" "${TRAVELROUTER_LAN_CIDR:-192.168.50.1/24}" | sed "s|/.*||")
status_port="${TRAVELROUTER_STATUS_PORT:-80}"
if [[ "$status_port" == "80" ]]; then
  status_url="http://${lan_ip}"
else
  status_url="http://${lan_ip}:${status_port}"
fi
echo "-----------------------------------------------"
echo "travel-router installed"
echo "  AP SSID     : ${TRAVELROUTER_AP_SSID}"
echo "  AP iface    : ${ap}"
echo "  LAN IP      : ${lan_ip}"
echo "  Status page : ${status_url}"
echo "  Setup       : ${status_url}/setup (PIN required)"
echo "  Fallback    : ssh pi@${lan_ip} 'travel-wan connect <SSID> <PSK>'"
[[ -n "${WIFI_SSID:-}" ]] && echo "  WAN bootstrap: '${WIFI_SSID}' profile seeded (auto-connects on USB adapter)"
echo "NOTE: the Pi is only reachable over the ${TRAVELROUTER_AP_SSID}"
echo "  SSID or a USB Ethernet adapter (restores NM-managed connectivity)."
echo "-----------------------------------------------"
log "travel-router install complete"
