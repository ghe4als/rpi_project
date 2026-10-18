#!/bin/bash
# travel-wan.sh — hotel-WiFi management over SSH.
#
# Installs to /usr/local/bin/travel-wan. Run as the admin (pi) over SSH from a
# device ON the travel SSID to scan/connect/disconnect/forget/hotel networks
# on the travel-router's WAN wifi adapter.
#
# PRIVILEGES: `nmcli` READ (scan, status, dev show) works as any user, but
# `nmcli` WRITE (connect/disconnect/forget/connection delete) touches Network
# Manager, a SYSTEM service, so it requires ROOT. We wrap write commands in
# `sudo`. The provisioning cloud-config (user-data.tmpl) adds the pi user to
# the sudo group; the base image's sudo NOPASSWD (where present, e.g. the
# standard Raspberry Pi image) lets this run unattended. If the base image asks
# for a password, a non-root caller gets a clear hint (see usage text).
#
# SECURITY: the connection profile lives under /etc/NetworkManager/system-
# connections on the Pi's rootfs (NM persists it there) — so the hotel PSK is
# stored on the Pi, not just in transit. We NEVER echo a PSK back in `status`.
# allow: SIZE_OK — one CLI owns every travel-router SSH verb (WAN, psk store,
# AP reconfig, block list); splitting it would split the shared state file.
#
# This CLI WRITES NOTHING under /boot. It has no interactive prompts, so it is
# scriptable over SSH only (matches the brief's Q1: portal auth happens on a
# device ON the travel SSID, not on the Pi).
set -euo pipefail

log() { printf '[travel-wan] %s\n' "$*" >&2; }

# --- Seams: overridable tool binaries so tests can stub them ----------------
NMCLI="${NMCLI:-nmcli}"
IP="${IP:-ip}"
CURL="${CURL:-curl}"
HOSTAPD_CLI="${HOSTAPD_CLI:-hostapd_cli}"
IW="${IW:-iw}"
# Same seam as wan-select.sh: tests fake /sys for the AP-iface rule.
SYSFS_ROOT="${SYSFS_ROOT:-/sys}"
TRAVELROUTER_STATE_FILE="${TRAVELROUTER_STATE_FILE:-/run/travel-router/state.json}"
SUDO="${SUDO:-sudo}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
PSK_FILE="${TRAVELROUTER_PSK_FILE:-/etc/rpi-project/travel-router/known-psks}"
AP_SSID_FILE="${TRAVELROUTER_AP_SSID_FILE:-/etc/rpi-project/travel-router/ap-ssid}"
BLOCK_FILE="${TRAVELROUTER_BLOCK_FILE:-/etc/rpi-project/travel-router/blocked-macs}"
# AP-rename forensics sink. journald is volatile on the Pi, and the admin page
# that requests a rename is served over the radio that rename restarts, so a
# rename that takes the AP down destroys both the journal and the HTTP response
# that would have reported it. logrotate already covers /var/log/travel-router/*.log.
TRAVELROUTER_APCONFIG_LOG="${TRAVELROUTER_APCONFIG_LOG:-/var/log/travel-router/apconfig.log}"
# Budget for reaching AP-ENABLED. Must exceed a Zero W SDIO radio's
# COUNTRY_UPDATE window, otherwise a genuine bind failure is never observed.
TRAVELROUTER_AP_UP_TIMEOUT="${TRAVELROUTER_AP_UP_TIMEOUT:-25}"

# One durable ap-apply log line, mirrored to stderr for the API envelope.
# Callers must never pass a PSK.
aplog() {
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' '-')"
    printf '%s [apconfig] %s\n' "$ts" "$*" >&2
    printf '%s [apconfig] %s\n' "$ts" "$*" >>"$TRAVELROUTER_APCONFIG_LOG" 2>/dev/null || true
}

# Does hostapd report the AP interface ENABLED over its ctrl socket?
# Socket presence is NOT sufficient: hostapd creates <ctrl_interface>/<iface>
# during driver init, while the interface is still UNINITIALIZED/COUNTRY_UPDATE.
# A caller that accepts the bare socket as "up" discards the config backup
# before the radio is beaconing, which leaves an AP-down condition with nothing
# to roll back to. Callers must treat a not-ENABLED radio as DOWN.
AP_RADIO_STATUS=""
_ap_radio_up() {
    local ctrl_dir="$1" ap_iface="$2" cand sock=""
    AP_RADIO_STATUS=""
    for cand in "$ctrl_dir/$ap_iface" "$ctrl_dir/${ap_iface}.1"; do
        if [[ -e "$cand" ]]; then sock="$cand"; break; fi
    done
    [[ -n "$sock" ]] || return 1
    if command -v "$HOSTAPD_CLI" >/dev/null 2>&1; then
        # -p takes the ctrl socket DIRECTORY and -i names the interface; -p on
        # the socket file itself points hostapd_cli at a non-directory, so it
        # finds no socket and answers an empty status.
        # Verdict is taken from the captured string, never from an exit status:
        # piping into `grep -q` risks SIGPIPE surfacing under pipefail as a
        # false "radio down". AP_RADIO_STATUS carries it out for the caller's
        # failure log.
        AP_RADIO_STATUS="$("$HOSTAPD_CLI" -p "$ctrl_dir" -i "$ap_iface" status 2>/dev/null | tr '\n' ' ' | cut -c1-200 || true)"
        # hostapd 2.10 AP mode reports the interface as a bare `state=` key
        # (verified on rpi-8e21bb: `state=ENABLED`, no wpa_state/interface_state
        # in the output at all). Substring-matched so a build that does emit the
        # longer spellings still satisfies it.
        [[ "$AP_RADIO_STATUS" == *"state=ENABLED"* ]]
        return $?
    fi
    # hostapd_cli absent: fall back to socket presence rather than failing every
    # apply. The caller logs which criterion was in force.
    return 0
}

# An empty $1 means there was no prior record; that is a no-op, not a failure.
_ap_restore_ssid() {
    [[ -n "$1" ]] || return 0
    printf '%s\n' "$1" > "$AP_SSID_FILE" 2>/dev/null || return 0
    chmod 0600 "$AP_SSID_FILE" 2>/dev/null || true
    return 0
}

# --- PSK candidate store (wifi-ui-known-psk wave) -----------------------------
# Schema: one row per line, 3 TAB-separated fields:
#   s<TAB><SSID><TAB><PSK>  SSID-specific candidate
#   d<TAB><TAB><PSK>        default candidate (empty SSID field)
# Mode 0600, root-owned. Single owner: this script is the only writer
# (status-server shells out to it). NO sudo in the store path: over SSH the
# caller runs as `pi` and cannot write the root-owned store — that collect
# degrades best-effort (one redacted stderr line, connect rc untouched).
PSK_TAB=$'\t'
PSK_CR=$'\r'
# setup-v2 M2: NM profile names that must never appear in the known list.
EXCLUDED_PROFILES="tr-probe preconfigured"

# Storeable value: non-empty, no TAB/CR/LF (field/row separators).
psk_field_ok() {
    local v="$1"
    [[ -n "$v" ]] || return 1
    case "$v" in
        *"$PSK_TAB"*|*"$PSK_CR"*|*"
"*) return 1 ;;
    esac
    return 0
}

# Well-formed store row: kind s|d, exactly two TABs, non-empty PSK field,
# s-rows carry a non-empty SSID, d-rows an empty one. Malformed lines are
# dropped on rewrite (corrupt-store degradation, never a crash).
psk_row_ok() {
    local r="$1" rest k mid val
    [[ "$r" == *"$PSK_TAB"* ]] || return 1
    rest="${r#*"$PSK_TAB"}"
    [[ "$rest" == *"$PSK_TAB"* ]] || return 1
    k="${r%%"$PSK_TAB"*}"
    mid="${rest%%"$PSK_TAB"*}"
    val="${rest#*"$PSK_TAB"}"
    [[ "$val" == *"$PSK_TAB"* ]] && return 1
    [[ -n "$val" ]] || return 1
    [[ "$k" == "s" || "$k" == "d" ]] || return 1
    if [[ "$k" == "s" ]]; then [[ -n "$mid" ]] || return 1
    else [[ -z "$mid" ]] || return 1
    fi
    return 0
}

# Upsert one SSID candidate. rc 0 = stored/dedup/dry-run, 1 = validation
# reject, 2 = write failure. NEVER echoes the PSK anywhere.
psk_store_upsert() {
    local ssid="$1" psk="$2"
    psk_field_ok "$ssid" && psk_field_ok "$psk" || return 1
    local row="s$PSK_TAB$ssid$PSK_TAB$psk"
    local rows=() r
    if [[ -f "$PSK_FILE" ]]; then
        while IFS= read -r r || [[ -n "$r" ]]; do
            [[ -n "$r" ]] || continue
            psk_row_ok "$r" || continue
            [[ "$r" == "$row" ]] && return 0
            rows[${#rows[@]}]="$r"
        done < "$PSK_FILE"
    fi
    rows[${#rows[@]}]="$row"
    local n=0 r2 out=() drop
    for r2 in ${rows[@]+"${rows[@]}"}; do
        [[ "$r2" == "s$PSK_TAB$ssid$PSK_TAB"* ]] && n=$((n+1))
    done
    drop=$((n-4)); [[ "$drop" -lt 0 ]] && drop=0
    for r2 in ${rows[@]+"${rows[@]}"}; do
        if [[ "$drop" -gt 0 && "$r2" == "s$PSK_TAB$ssid$PSK_TAB"* ]]; then
            drop=$((drop-1)); continue
        fi
        out[${#out[@]}]="$r2"
    done
    local ntot=0 r3 out2=()
    for r3 in ${out[@]+"${out[@]}"}; do
        [[ "$r3" == "s$PSK_TAB"* ]] && ntot=$((ntot+1))
    done
    drop=$((ntot-32)); [[ "$drop" -lt 0 ]] && drop=0
    for r3 in ${out[@]+"${out[@]}"}; do
        if [[ "$drop" -gt 0 && "$r3" == "s$PSK_TAB"* ]]; then
            drop=$((drop-1)); continue
        fi
        out2[${#out2[@]}]="$r3"
    done
    if [[ "${TRAVELROUTER_DRY_RUN:-0}" == "1" ]]; then
        log "psk store: dry-run: would record candidate for '${ssid}'"
        return 0
    fi
    local dir="." tmp
    case "$PSK_FILE" in */*) dir="${PSK_FILE%/*}" ;; esac
    tmp="$dir/.known-psks.$$"
    if ! { for r3 in ${out2[@]+"${out2[@]}"}; do printf '%s\n' "$r3"; done; } > "$tmp" 2>/dev/null; then
        log "psk store: cannot write '$dir' (store unchanged)"
        return 2
    fi
    chmod 0600 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$PSK_FILE" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        log "psk store: cannot replace '$PSK_FILE' (store unchanged)"
        return 2
    fi
    return 0
}

# Candidate order for try-psks: SSID s-rows in file order, then d-rows.
# Prints PSK values only (the caller must never log them).
psk_candidates() {
    local ssid="$1" r k rest val
    if [[ -f "$PSK_FILE" ]]; then
        while IFS= read -r r || [[ -n "$r" ]]; do
            [[ -n "$r" ]] || continue
            psk_row_ok "$r" || continue
            k="${r%%"$PSK_TAB"*}"
            if [[ "$k" == "s" ]]; then
                if [[ "$r" == "s$PSK_TAB$ssid$PSK_TAB"* ]]; then
                    val="${r#*"s$PSK_TAB$ssid$PSK_TAB"}"
                    printf '%s\n' "$val"
                fi
            fi
        done < "$PSK_FILE"
    fi
    if [[ -f "$PSK_FILE" ]]; then
        while IFS= read -r r || [[ -n "$r" ]]; do
            [[ -n "$r" ]] || continue
            psk_row_ok "$r" || continue
            if [[ "$r" == "d$PSK_TAB$PSK_TAB"* ]]; then
                val="${r#*"d$PSK_TAB$PSK_TAB"}"
                printf '%s\n' "$val"
            fi
        done < "$PSK_FILE"
    fi
    return 0
}

# Best-effort collect (connect path): never echoes the PSK, always rc 0.
psk_collect() {
    local ssid="$1" psk="$2" rc=0
    psk_store_upsert "$ssid" "$psk" || rc=$?
    case "$rc" in
        0) log "psk store: recorded candidate for '${ssid}'" ;;
        1) log "psk store: rejected candidate for '${ssid}' (SSID/PSK must not contain TAB/CR/LF)" ;;
        2) : ;;
    esac
    return 0
}

# Upsert one DEFAULT candidate (d-row). Same contract as psk_store_upsert:
# rc 0 = stored/dedup/dry-run, 1 = validation reject, 2 = write failure.
# Exact-row dedup (no dupes); global cap 32 d-rows, oldest evicted.
psk_store_upsert_default() {
    local psk="$1"
    psk_field_ok "$psk" || return 1
    local row="d$PSK_TAB$PSK_TAB$psk"
    local rows=() r
    if [[ -f "$PSK_FILE" ]]; then
        while IFS= read -r r || [[ -n "$r" ]]; do
            [[ -n "$r" ]] || continue
            psk_row_ok "$r" || continue
            [[ "$r" == "$row" ]] && return 0
            rows[${#rows[@]}]="$r"
        done < "$PSK_FILE"
    fi
    rows[${#rows[@]}]="$row"
    local ntot=0 r2 out=() drop
    for r2 in ${rows[@]+"${rows[@]}"}; do
        [[ "$r2" == "d$PSK_TAB$PSK_TAB"* ]] && ntot=$((ntot+1))
    done
    drop=$((ntot-32)); [[ "$drop" -lt 0 ]] && drop=0
    for r2 in ${rows[@]+"${rows[@]}"}; do
        if [[ "$drop" -gt 0 && "$r2" == "d$PSK_TAB$PSK_TAB"* ]]; then
            drop=$((drop-1)); continue
        fi
        out[${#out[@]}]="$r2"
    done
    if [[ "${TRAVELROUTER_DRY_RUN:-0}" == "1" ]]; then
        log "psk store: dry-run: would record default candidate"
        return 0
    fi
    local dir="." tmp
    case "$PSK_FILE" in */*) dir="${PSK_FILE%/*}" ;; esac
    tmp="$dir/.known-psks.$$"
    if ! { for r2 in ${out[@]+"${out[@]}"}; do printf '%s\n' "$r2"; done; } > "$tmp" 2>/dev/null; then
        log "psk store: cannot write '$dir' (store unchanged)"
        return 2
    fi
    chmod 0600 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$PSK_FILE" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        log "psk store: cannot replace '$PSK_FILE' (store unchanged)"
        return 2
    fi
    return 0
}

# --- helpers ---------------------------------------------------------------

# Read a JSON string field from the state file (the one wan-select writes).
json_field() {
    local key="$1" val=""
    if [[ -f "$TRAVELROUTER_STATE_FILE" ]]; then
        # Portable parser (BSD sed lacks [[:space:]]); split JSON on double
        # quotes and print the value field that follows the requested key.
        val=$(awk -F'"' -v k="$key" '{ for (i=1;i<=NF;i++) { if ($i==k && $(i+2)!="" ) { print $(i+2); exit } } }' "$TRAVELROUTER_STATE_FILE" 2>/dev/null)
    fi
    printf '%s' "$val"
}

WIFI_WAN_IF="$(json_field wan_if 2>/dev/null || true)"

# json_escape VAL : make a shell string safe to interpolate into a JSON
# double-quoted string (same idiom as wan-select.sh's state.json heredoc).
# ORDER IS LOAD-BEARING: backslash-then-quote — escaping the quote first would
# turn the NEW backslash into \\ on the second pass, double-escaping the JSON.
# Control characters (< 0x20, incl. tab/lf/cr in a hostile hostname) are
# dropped, never truncated or rejected, so the row still parses as JSON.
json_escape() {
    local v="${1:-}"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v=$(printf '%s' "$v" | LC_ALL=C tr -d '\001-\037')
    printf '%s' "$v"
}

LEASES_FILE="${TRAVELROUTER_LEASES_FILE:-/var/lib/misc/dnsmasq.leases}"

# lease_rows : emit one TAB-separated row per DHCP lease
#   lease_expires<TAB>mac<TAB>ip<TAB>hostname
# The leases file splits on whitespace: [expires, mac, ip, hostname, ...rest];
# the remainder is joined back with spaces because hostnames may contain them
# (a fixed-column awk would mangle those). A missing file degrades to no rows
# (status must never abort on it); a line with too few fields is skipped.
lease_rows() {
    [[ -f "$LEASES_FILE" ]] || return 0
    local row expires mac ip hostname rest
    while IFS= read -r row || [[ -n "$row" ]]; do
        [[ -n "$row" ]] || continue
        expires="${row%%[[:space:]]*}"; row="${row#"$expires"}"
        row="${row#[[:space:]]}"
        [[ -n "$row" ]] || continue
        mac="${row%%[[:space:]]*}"; row="${row#"$mac"}"
        row="${row#[[:space:]]}"
        [[ -n "$row" ]] || continue
        ip="${row%%[[:space:]]*}"; row="${row#"$ip"}"
        row="${row#[[:space:]]}"
        [[ -n "$row" ]] || continue
        hostname="${row%%[[:space:]]*}"; rest="${row#"$hostname"}"
        rest="${rest#[[:space:]]}"
        hostname="$hostname${rest:+ $rest}"
        printf '%s\t%s\t%s\t%s\n' "$expires" "$mac" "$ip" "$hostname"
    done < "$LEASES_FILE"
    return 0
}

# Print this script's header comment block as the usage banner.
usage() {
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Usage:
  travel-wan scan                         list hotel networks (read-only)
  travel-wan status [--json]              show WAN/SSID/IP/internet/clients
  travel-wan connect <SSID> [PSK]         connect the WAN wifi adapter
  travel-wan disconnect                   drop the WAN wifi adapter
  travel-wan forget <SSID>                delete a saved hotel profile
  travel-wan wipe-stale [--dry-run] [--with-psks] [--auto] [--include-ethernet]
                                        remove stale WiFi profiles except active/bootstrap
  travel-wan known                       list saved wifi networks (NM profiles)
  travel-wan collect <SSID> <PSK>        record a PSK candidate for try-psks
  travel-wan psks-add <SSID> <PSK>       record a PSK candidate (setup API)
  travel-wan psks-add-default <PSK>      record a default PSK candidate
  travel-wan psks-list                   list store rows TYPE<TAB>SSID<TAB>PSK
  travel-wan clients [--json]            list connected clients (leases + AP assoc)
  travel-wan block <MAC>                 block a device by MAC (firewall drop + kick now)
  travel-wan unblock <MAC>               remove a MAC from the block list
  travel-wan blocked                     list blocked MACs (one per line)
  travel-wan psks-del <index>            delete the Nth psks-list row
  travel-wan ap-apply <SSID> [PSK] [HIDDEN]  re-render + restart the AP (setup API; HIDDEN: 2=hide, 0=visible, empty=keep)
  travel-wan ap-info [--json]            current AP SSID + broadcast state (JSON)
  travel-wan stealth-check               read-only WAN-side management-port check (JSON)
  travel-wan wifi-capabilities           AP-radio WPA3/PMF capability probe (JSON)
  travel-wan ap-ssid                     print the live AP SSID
  travel-wan try-psks <SSID>             try stored PSK candidates for a network
  travel-wan recheck                      trigger wan-select now (also runs every 30s)

PSKs are stored on this Pi under /etc/NetworkManager/system-connections.
EOF
}

# Interface is usable to talk to nmcli only when the device actually exists.
iface_ok() {
    local if_name="$1"
    [[ -n "$if_name" ]] || return 1
    [[ -e "/sys/class/net/${if_name}" ]] || return 1
}

# --- subcommands -----------------------------------------------------------

cmd_scan() {
    local if_name="$1"
    if ! iface_ok "$if_name"; then
        log "scan: WAN wifi device '${if_name:-<empty>}' not available on this model"
        return 2
    fi
    log "scanning WiFi on '${if_name}' ..."
    # stderr (nmcli warnings) must NOT become a row: it flows to our stderr
    # (status-server routes it to the envelope `log` field), never into sort.
    # setup-v2 M3: rows whose SSID equals the AP's own SSID are dropped (the
    # WAN radio can see our own travel AP; connecting to it would be a trap).
    # Missing/empty AP_SSID_FILE -> no filtering (never an error).
    local scan_apssid=""
    [[ -s "$AP_SSID_FILE" ]] && scan_apssid="$(head -1 "$AP_SSID_FILE" 2>/dev/null || true)"
    if [[ -n "$scan_apssid" ]]; then
        "$NMCLI" -t -f SSID,SIGNAL,SECURITY dev wifi list ifname "$if_name" \
            | grep -vF "${scan_apssid}:" | sort -t: -k2 -nr
    else
        "$NMCLI" -t -f SSID,SIGNAL,SECURITY dev wifi list ifname "$if_name" | sort -t: -k2 -nr
    fi
}

cmd_connect() {
    local if_name="$1"
    local ssid="${2:-}"
    local psk="${3:-}"
    if [[ -z "$ssid" ]]; then
        log "connect: SSID is required"
        usage
        return 2
    fi
    if [[ "$ssid" =~ ^[[:space:]]*$ ]]; then
        log "connect: empty SSID"
        return 2
    fi
    # Auto-collect the PSK candidate (M8) at attempt time, best-effort: a
    # store failure (SSH path runs as `pi` vs root-owned 0600 store, or a
    # TAB/CR/LF value) never changes connect's rc or messages.
    if [[ -n "$psk" ]]; then
        psk_collect "$ssid" "$psk" || true
    fi
    # No WAN device on this model — give a clear, non-cryptographic hint.
    if ! iface_ok "$if_name"; then
        log "no WAN wifi adapter detected on this model; a USB/WiFi dongle is required to join hotel networks"
        return 1
    fi
    if [[ -n "$psk" ]]; then
        log "connecting to '${ssid}' — the network may offer captive-portal auth, in which case finish login from a device ON the travel SSID"
        # PSK-in-argv accepted risk: nmcli gets the PSK as a command-line argument,
        # so it is world-readable via /proc/<pid>/cmdline for the duration of this
        # connect (the status-server write path allows up to API_WRITE_TIMEOUT=90s).
        # Exposure is local-only: only the `pi` and root accounts exist on the unit,
        # both already privileged, so no privilege boundary is crossed. Accepted
        # risk; the proper fix (stdin or NM D-Bus password delivery) is deferred.
        # NM >=1.52 (Trixie) rejects `dev wifi connect ... password` when a profile
        # for the SSID exists — its update path sets wifi-sec.psk without
        # wifi-sec.key-mgmt and the validator answers "property is missing". Use
        # the explicit ensure-profile + connection-up idiom instead (same shape as
        # the install.sh seed and the try-psks probe), which stays correct on
        # every NM version.
        if "$SUDO" "$NMCLI" -t -f NAME connection show 2>/dev/null | grep -Fxq "$ssid"; then
            "$SUDO" "$NMCLI" connection modify "$ssid" \
                wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$psk" connection.autoconnect yes
        else
            "$SUDO" "$NMCLI" connection add type wifi ifname "$if_name" \
                con-name "$ssid" ssid "$ssid" \
                wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$psk" connection.autoconnect yes
        fi
        "$SUDO" "$NMCLI" --wait 30 connection up "$ssid"
    else
        log "connecting to '${ssid}' (open network, no PSK)"
        if "$SUDO" "$NMCLI" -t -f NAME connection show 2>/dev/null | grep -Fxq "$ssid"; then
            # A stale WPA profile for a now-open network must be downgraded.
            "$SUDO" "$NMCLI" connection modify "$ssid" -wifi-sec 2>/dev/null || true
            "$SUDO" "$NMCLI" connection modify "$ssid" connection.autoconnect yes
        else
            "$SUDO" "$NMCLI" connection add type wifi ifname "$if_name" \
                con-name "$ssid" ssid "$ssid" connection.autoconnect yes
        fi
        "$SUDO" "$NMCLI" --wait 30 connection up "$ssid"
    fi
    log "connected to '${ssid}' (profile now persisted under /etc/NetworkManager/system-connections)"
}

cmd_disconnect() {
    local if_name="$1"
    if ! iface_ok "$if_name"; then
        log "disconnect: no WAN wifi adapter detected on this model"
        return 1
    fi
    log "disconnecting WAN wifi '${if_name}' ..."
    "$SUDO" "$NMCLI" dev disconnect "$if_name"
}

cmd_forget() {
    local if_name="$1"
    local ssid="${2:-}"
    # M6 (wifi-ui-known-psk): forget deletes ONLY the NM profile; the
    # saved-psk candidate row in $PSK_FILE is KEPT so try-psks can
    # re-establish the profile from a candidate without re-typing.
    if [[ -z "$ssid" ]]; then
        log "forget: SSID is required"
        usage
        return 2
    fi
    if iface_ok "$if_name"; then
        "$SUDO" "$NMCLI" dev disconnect "$if_name" 2>/dev/null || true
    fi
    log "forgetting profile '${ssid}' ..."
    "$SUDO" "$NMCLI" connection delete "$ssid"
}

# --- Stale-WAN cleanup (hotel-change helper) ---------------------------------
# Protects bootstrap profiles (UUIDs recorded at install) and the currently
# active connection; removes other remembered hotel/ethernet profiles.
BOOTSTRAP_UUID_FILE="${TRAVELROUTER_BOOTSTRAP_UUID_FILE:-/etc/rpi-project/travel-router/bootstrap-uuids}"

_bootstrap_uuids() {
    if [[ -r "$BOOTSTRAP_UUID_FILE" ]]; then
        while IFS= read -r r || [[ -n "$r" ]]; do
            [[ -n "$r" ]] || continue
            printf '%s\n' "$r"
        done < "$BOOTSTRAP_UUID_FILE"
    fi
}

_active_connection_uuids() {
    "$NMCLI" -t -f UUID,TYPE connection show --active 2>/dev/null \
      | awk -F: '$2 != "loopback" && $2 != "vpn" {print $1}'
}

_all_connection_profiles() {
    "$NMCLI" -t -f NAME,UUID,TYPE,ACTIVE connection show 2>/dev/null
}

_psk_store_del_by_ssids() {
    local ssids_csv="$1"
    [[ -n "$ssids_csv" && -r "$PSK_FILE" ]] || return 0
    local rows=() r k ssid
    while IFS= read -r r || [[ -n "$r" ]]; do
        [[ -n "$r" ]] || continue
        psk_row_ok "$r" || continue
        rows[${#rows[@]}]="$r"
    done < "$PSK_FILE"
    local tmp dir="."
    case "$PSK_FILE" in */*) dir="${PSK_FILE%/*}" ;; esac
    tmp="$dir/.known-psks.$$"
    for r in ${rows[@]+"${rows[@]}"}; do
        k="${r%%"$PSK_TAB"*}"
        if [[ "$k" == "s" ]]; then
            ssid="${r#s$PSK_TAB}"
            ssid="${ssid%%"$PSK_TAB"*}"
            [[ ",${ssids_csv}," == *",${ssid},"* ]] && continue
        fi
        printf '%s\n' "$r"
    done > "$tmp" 2>/dev/null || { rm -f "$tmp"; log "wipe-stale: cannot write '$dir' (PSK store unchanged)"; return 1; }
    chmod 0600 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$PSK_FILE" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        log "wipe-stale: cannot replace '$PSK_FILE' (PSK store unchanged)"
        return 1
    fi
    return 0
}

json_escape() {
    local v="${1:-}"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v=$(printf '%s' "$v" | LC_ALL=C tr -d '\001-\037')
    printf '%s' "$v"
}

cmd_wipe_stale() {
    local dry_run=0 with_psks=0 auto=0 include_ethernet=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=1 ;;
            --with-psks) with_psks=1 ;;
            --auto) auto=1 ;;
            --include-ethernet) include_ethernet=1 ;;
            *) log "wipe-stale: unknown flag '$1'"; usage; return 2 ;;
        esac
        shift
    done

    local protected_uuids=() protected_reasons=() active_uuids=""
    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] || continue
        active_uuids="${active_uuids}${active_uuids:+,}${uuid}"
        protected_uuids[${#protected_uuids[@]}]="$uuid"
        protected_reasons[${#protected_reasons[@]}]="active"
    done < <(_active_connection_uuids)

    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] || continue
        [[ ",${active_uuids}," == *",${uuid},"* ]] && continue
        protected_uuids[${#protected_uuids[@]}]="$uuid"
        protected_reasons[${#protected_reasons[@]}]="bootstrap"
    done < <(_bootstrap_uuids)

    local all_profiles
    all_profiles="$(_all_connection_profiles)" || true
    if [[ -z "$all_profiles" ]]; then
        printf '{"dry_run":%s,"protected":[],"removed":[],"psks_removed":0,"errors":[]}\n' \
            "$([[ "$dry_run" -eq 1 ]] && echo 'true' || echo 'false')"
        return 0
    fi

    local protected_out=() removed_out=() errors=() removed_ssids=()
    local line pname puuid ptype
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        pname="${line%%:*}"
        local rest="${line#*:}"
        puuid="${rest%%:*}"
        ptype="${rest#*:}"
        ptype="${ptype%%:*}"

        local is_protected=0 reason=""
        for i in "${!protected_uuids[@]}"; do
            if [[ "${protected_uuids[$i]}" == "$puuid" ]]; then
                is_protected=1
                reason="${protected_reasons[$i]}"
                break
            fi
        done

        if [[ "$is_protected" -eq 1 ]]; then
            [[ "$auto" -eq 1 ]] || log "wipe-stale: keeping '${pname}' (${reason})"
            protected_out[${#protected_out[@]}]="{\"name\":\"$(json_escape "$pname")\",\"uuid\":\"$(json_escape "$puuid")\",\"reason\":\"${reason}\"}"
            continue
        fi

        [[ "$ptype" == "802-11-wireless" ]] || { [[ "$ptype" == "802-3-ethernet" && "$include_ethernet" -eq 1 ]] || continue; }

        removed_ssids[${#removed_ssids[@]}]="$pname"
        if [[ "$dry_run" -eq 1 ]]; then
            log "wipe-stale: dry-run: would delete '${pname}' (${puuid})"
            removed_out[${#removed_out[@]}]="{\"name\":\"$(json_escape "$pname")\",\"uuid\":\"$(json_escape "$puuid")\"}"
        else
            log "wipe-stale: deleting '${pname}' (${puuid}) ..."
            if "$SUDO" "$NMCLI" connection delete "$puuid" 2>/dev/null; then
                removed_out[${#removed_out[@]}]="{\"name\":\"$(json_escape "$pname")\",\"uuid\":\"$(json_escape "$puuid")\"}"
            else
                errors[${#errors[@]}]="\"$(json_escape "failed to delete '${pname}'")\""
            fi
        fi
    done <<< "$all_profiles"

    local psks_removed=0
    if [[ "$with_psks" -eq 1 && ${#removed_ssids[@]} -gt 0 ]]; then
        local ssids_csv=""
        for s in ${removed_ssids[@]+"${removed_ssids[@]}"}; do
            ssids_csv="${ssids_csv}${ssids_csv:+,}${s}"
        done
        if [[ "$dry_run" -eq 1 ]]; then
            local would_del=0
            while IFS= read -r r; do
                [[ -n "$r" ]] || continue
                psk_row_ok "$r" || continue
                local k="${r%%"$PSK_TAB"*}"
                if [[ "$k" == "s" ]]; then
                    ssid="${r#s$PSK_TAB}"
                    ssid="${ssid%%"$PSK_TAB"*}"
                    [[ ",${ssids_csv}," == *",${ssid},"* ]] && would_del=$((would_del+1))
                fi
            done < "$PSK_FILE"
            psks_removed=$would_del
            log "wipe-stale: dry-run: would remove ${would_del} saved PSK row(s)"
        else
            local before=0 after=0
            [[ -r "$PSK_FILE" ]] && before=$(grep -c '^s	' "$PSK_FILE" 2>/dev/null || echo 0)
            if _psk_store_del_by_ssids "$ssids_csv"; then
                [[ -r "$PSK_FILE" ]] && after=$(grep -c '^s	' "$PSK_FILE" 2>/dev/null || echo 0)
                psks_removed=$((before-after))
                log "wipe-stale: removed ${psks_removed} saved PSK row(s)"
            else
                errors[${#errors[@]}]="\"failed to prune saved PSKs\""
            fi
        fi
    fi

    local dry_json="false"
    [[ "$dry_run" -eq 1 ]] && dry_json="true"
    local prot_json=""
    for o in ${protected_out[@]+"${protected_out[@]}"}; do
        prot_json="${prot_json}${prot_json:+,}${o}"
    done
    local rem_json=""
    for o in ${removed_out[@]+"${removed_out[@]}"}; do
        rem_json="${rem_json}${rem_json:+,}${o}"
    done
    local err_json=""
    for e in ${errors[@]+"${errors[@]}"}; do
        err_json="${err_json}${err_json:+,}${e}"
    done
    printf '{"dry_run":%s,"protected":[%s],"removed":[%s],"psks_removed":%d,"errors":[%s]}\n' \
        "$dry_json" "$prot_json" "$rem_json" "$psks_removed" "$err_json"
    return 0
}

cmd_collect() {
    local ssid="${1:-}"
    local psk="${2:-}"
    if [[ -z "$ssid" || -z "$psk" ]]; then
        log "collect: SSID and PSK are required"
        usage
        return 2
    fi
    local rc=0
    psk_store_upsert "$ssid" "$psk" || rc=$?
    case "$rc" in
        0) log "psk store: recorded candidate for '${ssid}'" ;;
        1) log "psk store: rejected candidate for '${ssid}' (SSID/PSK must not contain TAB/CR/LF)" ;;
        2) log "psk store: write failed (see stderr above)" ;;
    esac
    [[ "$rc" -eq 0 ]] || return 1
    return 0
}

# --- setup-v2 M5: runtime PSK-store management --------------------------------
# psks-add / psks-add-default / psks-list / psks-del operate on the same
# 0600 store as collect/try-psks. No sudo (unchanged posture: SSH callers
# run as pi and degrade with a clear note when the store is root-owned).
cmd_psks_add() {
    local ssid="${1:-}"
    local psk="${2:-}"
    if [[ -z "$ssid" || -z "$psk" ]]; then
        log "psks-add: SSID and PSK are required"
        usage
        return 2
    fi
    local rc=0
    psk_store_upsert "$ssid" "$psk" || rc=$?
    case "$rc" in
        0) log "psk store: recorded candidate for '${ssid}'" ;;
        1) log "psk store: rejected candidate for '${ssid}' (SSID/PSK must not contain TAB/CR/LF)" ;;
        2) log "psk store: write failed (see stderr above)" ;;
    esac
    [[ "$rc" -eq 0 ]] || return 1
    return 0
}

cmd_psks_add_default() {
    local psk="${1:-}"
    if [[ -z "$psk" ]]; then
        log "psks-add-default: PSK is required"
        usage
        return 2
    fi
    local rc=0
    psk_store_upsert_default "$psk" || rc=$?
    case "$rc" in
        0) log "psk store: recorded default candidate" ;;
        1) log "psk store: rejected default candidate (PSK must not contain TAB/CR/LF)" ;;
        2) log "psk store: write failed (see stderr above)" ;;
    esac
    [[ "$rc" -eq 0 ]] || return 1
    return 0
}

cmd_psks_list() {
    # Prints every valid row as TYPE<TAB>SSID<TAB>PSK (d-row SSID column
    # empty). Root-only surface: the store is 0600 root; a non-root caller
    # degrades with rc 1 (never a crash).
    if [[ ! -r "$PSK_FILE" ]]; then
        log "psks-list: store '$PSK_FILE' missing or not readable (root-owned 0600; run as root or via the setup API)"
        return 1
    fi
    local r
    while IFS= read -r r || [[ -n "$r" ]]; do
        [[ -n "$r" ]] || continue
        psk_row_ok "$r" || continue
        printf '%s\n' "$r"
    done < "$PSK_FILE"
    return 0
}

cmd_psks_del() {
    local n="${1:-}"
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [[ "$n" -lt 1 ]]; then
        log "psks-del: a 1-based row index from 'psks-list' is required"
        usage
        return 2
    fi
    if [[ ! -r "$PSK_FILE" ]]; then
        log "psks-del: store '$PSK_FILE' missing or not readable (root-owned 0600; run as root or via the setup API)"
        return 1
    fi
    local rows=() r keep=0
    while IFS= read -r r || [[ -n "$r" ]]; do
        [[ -n "$r" ]] || continue
        psk_row_ok "$r" || continue
        rows[${#rows[@]}]="$r"
    done < "$PSK_FILE"
    if [[ "$n" -gt ${#rows[@]} ]]; then
        log "psks-del: index ${n} out of range (store has ${#rows[@]} rows; run 'travel-wan psks-list')"
        return 1
    fi
    local dir="." tmp
    case "$PSK_FILE" in */*) dir="${PSK_FILE%/*}" ;; esac
    tmp="$dir/.known-psks.$$"
    for r in ${rows[@]+"${rows[@]}"}; do
        keep=$((keep+1))
        [[ "$keep" == "$n" ]] && continue
        printf '%s\n' "$r"
    done > "$tmp" 2>/dev/null || { rm -f "$tmp"; log "psks-del: cannot write '$dir'"; return 2; }
    chmod 0600 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$PSK_FILE" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        log "psks-del: cannot replace '$PSK_FILE' (store unchanged)"
        return 2
    fi
    return 0
}

# --- setup-v2 M8: AP reconfigure (runtime owner of the hostapd render) --------
# ap-apply [NEW_SSID] [NEW_PSK]: re-renders hostapd-travel.conf from the
# TEMPLATE (never by parsing the rendered file), with country/channel/iface
# sourced from role.env (same two-path idiom as install.sh:64-67; root
# readable). Rollback contract: (1) render new conf to tmp, (2) PARSE-probe it
# with a hostapd -t run against a COPY whose interface= is rewritten to a
# nonexistent device: hostapd (2.10, Trixie) has NO parse-only mode — plain
# `hostapd -t <conf>` runs the full daemon and would collide with the live AP
# (rc 1 on ANY run while hostapd-travel holds wlan0) and, worse, a second
# daemon can knock the running radio down. On the probe copy, parse errors
# are reported BEFORE driver init (marker: "errors found in configuration
# file") so a bad conf exits nonzero quickly on the dead iface, while a
# parse-valid conf fails harmlessly at nl80211 init on that dead iface
# (wlan0 is never touched). The daemon rc is NOT trusted: it cannot
# distinguish parse-validity from hardware failure, so the gate is the
# stderr marker (hostapd prints "N errors found in configuration file" and
# exits) — absent marker + nonzero rc = parse-valid (driver-init failure).
# (3) keep the old conf as conf.bak, (4) atomically install the new conf +
# ap-ssid, (5) restart hostapd-travel.service and confirm liveness: the unit
# is Type=simple, so restart rc 0 does NOT prove the daemon parsed the new
# conf — is-active is re-checked after a grace pause, and a dead daemon
# restores the .bak (and restarts it) like any other failure. The caller sends its HTTP response BEFORE the restart (the radio
# drop kills the client's TCP connection mid-restart).
AP_CONF="${TRAVELROUTER_AP_CONF:-/etc/hostapd/hostapd-travel.conf}"
AP_TEMPLATE="${TRAVELROUTER_AP_TEMPLATE:-/etc/rpi-project/travel-router/hostapd.conf.tmpl}"
HOSTAPD_BIN="${TRAVELROUTER_HOSTAPD_BIN:-hostapd}"
cmd_ap_apply() {
    local new_ssid="${1:-}"
    local new_psk="${2:-}"
    local new_hidden="${3:-}"
    if [[ -z "$new_ssid" && -z "$new_psk" && -z "$new_hidden" ]]; then
        log "ap-apply: a new SSID, PSK, and/or hidden flag is required"
        usage
        return 2
    fi
    # Source role.env for the unchanged render fields (country/channel/iface).
    local renv=""
    local cand
    for cand in /run/travel-router/role.env /boot/firmware/role/role.env /boot/role/role.env; do
        [[ -f "$cand" ]] && { renv="$cand"; break; }
    done
    if [[ -n "$renv" ]]; then
        set -a; source "$renv" 2>/dev/null || true; set +a
    fi
    local r_ssid="${TRAVELROUTER_AP_SSID:-}"
    local r_psk="${TRAVELROUTER_AP_PSK:-}"
    # Mirror install.sh's default chain: role.env may omit AP_COUNTRY (card
    # reality 2026-09-22) — an EMPTY country_code= line is a render defect,
    # not a choice (hostapd 2.10 parse-errors on it; reg domain undefined).
    local r_country="${TRAVELROUTER_AP_COUNTRY:-${WIFI_COUNTRY:-US}}"
    local r_channel="${TRAVELROUTER_AP_CHANNEL:-6}"
    local r_iface="${TRAVELROUTER_AP_INTERFACE:-}"
    [[ -n "$r_ssid" && -n "$r_psk" ]] || { log "ap-apply: current AP SSID/PSK unknown (role.env missing or incomplete)"; return 1; }
    # Missing optional args keep the LIVE value: the SSID comes from the
    # ap-ssid file (updated by every ap-apply), NOT from role.env — otherwise
    # a psk-only change would silently revert a prior runtime SSID rename.
    [[ -n "$new_ssid" ]] || { if [[ -s "$AP_SSID_FILE" ]]; then new_ssid="$(head -1 "$AP_SSID_FILE" 2>/dev/null || true)"; else new_ssid="$r_ssid"; fi; }
    [[ -n "$new_psk" ]] || new_psk="$r_psk"
    [[ -n "$new_ssid" ]] || { log "ap-apply: live AP SSID unknown (ap-ssid file missing)"; return 1; }
    # Locate the template: ASSETS dir next to this script, or the staged copy.
    local tmpl="$AP_TEMPLATE"
    if [[ ! -f "$tmpl" ]]; then
        local self_dir
        self_dir="$(cd "$(dirname "$0")" && pwd)"
        [[ -f "$self_dir/hostapd.conf.tmpl" ]] && tmpl="$self_dir/hostapd.conf.tmpl"
    fi
    [[ -f "$tmpl" ]] || { log "ap-apply: hostapd template not found"; return 1; }
    local ap_iface="$r_iface"
    if [[ -z "$ap_iface" ]]; then
        # Derive the AP interface from the CURRENT rendered conf (uap/interface
        # line), else the state file's ap_interface.
        ap_iface="$(sed -n 's/^interface=//p' "$AP_CONF" 2>/dev/null | head -1)"
        [[ -z "$ap_iface" ]] && ap_iface="$(json_field ap_interface 2>/dev/null || true)"
    fi
    [[ -n "$ap_iface" ]] || { log "ap-apply: AP interface unknown"; return 1; }
    local dir tmp
    dir="$(dirname "$AP_CONF")"
    tmp="$AP_CONF.new.$$"
    # Placeholder names are COMPOSED at runtime so this script (which is
    # staged to /usr/local/bin) never carries literal dunder-underscore
    # template markers — the §2 battery rejects any staged file still
    # carrying them.
    local m_iface="__AP_""INTERFACE__"
    local m_ssid="__AP_""SSID__"
    local m_country="__AP_""COUNTRY__"
    local m_channel="__AP_""CHANNEL__"
    local m_psk="__AP_""PSK__"
    local m_hidden="__AP_""HIDDEN__"
    local m_key_mgmt="__AP_""KEY_MGMT__"
    local m_ieee80211w="__AP_""IEEE80211W__"
    # AP security mode (D2): same table as install.sh. ap-apply must render the
    # same key-mgmt/PMF placeholders the template now carries, or a runtime
    # rename would leave them unsubstituted (hostapd parse error).
    local r_security="${TRAVELROUTER_AP_SECURITY:-wpa2}"
    local r_key_mgmt r_ieee80211w_expr
    case "$r_security" in
        wpa2)            r_key_mgmt="WPA-PSK";     r_ieee80211w_expr="/${m_ieee80211w}/d" ;;
        wpa3-transition) r_key_mgmt="WPA-PSK SAE"; r_ieee80211w_expr="s|${m_ieee80211w}|ieee80211w=1|" ;;
        wpa3)            r_key_mgmt="SAE";         r_ieee80211w_expr="s|${m_ieee80211w}|ieee80211w=2|" ;;
        *) log "ap-apply: invalid TRAVELROUTER_AP_SECURITY='${r_security}' (want wpa2|wpa3-transition|wpa3)"; return 1 ;;
    esac
    # Hidden flag: "" = keep the CURRENT conf's value (preserve an existing
    # ignore_broadcast_ssid line on a psk-/ssid-only change; absent = stay
    # visible). "2" = hidden (hostapd stops the SSID beacon; clients must add
    # the network manually). "0" = visible (directive omitted). The
    # placeholder is a full-line marker in the template: when hidden, replace
    # the marker line with the directive; when visible, delete the marker
    # line entirely so the conf carries no ignore_broadcast_ssid.
    local hidden_sed_expr
    if [[ "$new_hidden" == "2" ]]; then
        hidden_sed_expr="s|${m_hidden}|ignore_broadcast_ssid=2|"
    elif [[ -z "$new_hidden" ]]; then
        local cur_hidden
        cur_hidden="$(sed -n 's/^\(ignore_broadcast_ssid=.*\)$/\1/p' "$AP_CONF" 2>/dev/null | head -1)"
        if [[ -n "$cur_hidden" ]]; then
            hidden_sed_expr="s|${m_hidden}|${cur_hidden}|"
        else
            hidden_sed_expr="/${m_hidden}/d"
        fi
    else
        hidden_sed_expr="/${m_hidden}/d"
    fi
    aplog "render: ssid=${new_ssid} iface=${ap_iface} country=${r_country} channel=${r_channel} hidden='${new_hidden:-keep}' psk=SET template=${tmpl}"
    sed -e "s|${m_iface}|${ap_iface}|g" \
        -e "s|${m_ssid}|${new_ssid}|g" \
        -e "s|${m_country}|${r_country}|g" \
        -e "s|${m_channel}|${r_channel}|g" \
        -e "s|${m_psk}|${new_psk}|g" \
        -e "s|${m_key_mgmt}|${r_key_mgmt}|g" \
        -e "$r_ieee80211w_expr" \
        -e "$hidden_sed_expr" \
        "$tmpl" > "$tmp" 2>/dev/null || { rm -f "$tmp"; aplog "FAIL: cannot render new conf from ${tmpl}"; log "ap-apply: cannot render new conf"; return 2; }
    chmod 0600 "$tmp"
    aplog "render: wrote ${tmp}"
    # Parse-probe on a COPY (dead iface) — see the ap-apply block comment:
    # the gate is the stderr marker hostapd prints for parse errors, NOT the
    # daemon rc (rc 1 for BOTH parse errors and nl80211 init failure).
    local probe="$AP_CONF.probe.$$"
    sed -e "s|^interface=.*|interface=ap0probe|" "$tmp" > "$probe" 2>/dev/null \
        || { rm -f "$tmp" "$probe" 2>/dev/null || true; log "ap-apply: cannot build parse-probe conf"; return 2; }
    chmod 0600 "$probe" 2>/dev/null || true
    local probe_out
    probe_out="$("$HOSTAPD_BIN" "$probe" </dev/null 2>&1 >/dev/null || true)"
    rm -f "$probe" 2>/dev/null || true
    if [[ "$probe_out" == *"errors found in configuration file"* ]]; then
        rm -f "$tmp"
        aplog "probe: REJECT - hostapd parse errors: $(printf '%s' "$probe_out" | tr '\n' ' ' | cut -c1-200)"
        log "ap-apply: new hostapd config is invalid (hostapd parse errors); nothing changed"
        return 1
    fi
    aplog "probe: accept (no parse-error marker in hostapd output)"
    cp "$AP_CONF" "$AP_CONF.bak" 2>/dev/null || true
    chmod 0600 "$AP_CONF.bak" 2>/dev/null || true
    if ! mv -f "$tmp" "$AP_CONF" 2>/dev/null; then
        rm -f "$tmp"
        aplog "FAIL: cannot replace ${AP_CONF} (conf unchanged)"
        log "ap-apply: cannot replace '$AP_CONF' (conf unchanged)"
        rm -f "$AP_CONF.bak" 2>/dev/null || true
        return 2
    fi
    aplog "installed: ${AP_CONF} (pre-rename copy at ${AP_CONF}.bak)"
    local apdir="." aptmp
    apdir="$(dirname "$AP_SSID_FILE")"
    mkdir -p "$apdir" 2>/dev/null || true
    # Keep the pre-apply identity so a failed apply can put it back. Leaving
    # the aborted SSID here makes ap-info report a name that is not
    # broadcasting, and ap-apply reads this file to fill an omitted SSID slot -
    # so the next psk-only change would render the aborted rename for real.
    local ap_ssid_prev=""
    [[ -f "$AP_SSID_FILE" ]] && ap_ssid_prev="$(head -1 "$AP_SSID_FILE" 2>/dev/null || true)"
    aptmp="$apdir/.ap-ssid.$$"
    printf '%s\n' "$new_ssid" > "$aptmp" 2>/dev/null \
        && chmod 0600 "$aptmp" 2>/dev/null || true
    if ! mv -f "$aptmp" "$AP_SSID_FILE" 2>/dev/null; then
        rm -f "$aptmp" 2>/dev/null || true
        aplog "WARN: ap-ssid write failed (${AP_SSID_FILE}); ap-info will report an empty SSID"
        log "ap-apply: ap-ssid write failed (scan exclusion keeps old value)"
    else
        aplog "ap-ssid: recorded '${new_ssid}' in ${AP_SSID_FILE}"
    fi
    local restart_rc=0
    deauth_suppress_stamp
    "$SUDO" "$SYSTEMCTL" restart hostapd-travel.service >/dev/null 2>&1 || restart_rc=$?
    aplog "restart: systemctl restart hostapd-travel rc=${restart_rc} (Type=simple: rc0 proves exec only, not bind)"
    if [[ $restart_rc -ne 0 ]]; then
        log "ap-apply: hostapd restart FAILED — restoring previous config"
        _ap_restore_ssid "$ap_ssid_prev"
        if [[ -f "$AP_CONF.bak" ]]; then
            mv -f "$AP_CONF.bak" "$AP_CONF" 2>/dev/null || true
            "$SUDO" "$SYSTEMCTL" restart hostapd-travel.service >/dev/null 2>&1 || true
            aplog "rollback: previous config + ap-ssid restored after restart rc!=0"
        else
            aplog "rollback INCOMPLETE after restart rc!=0: no ${AP_CONF}.bak on disk"
        fi
        return 1
    fi
    # Liveness = hostapd reporting the interface ENABLED (see _ap_radio_up).
    # The ctrl dir is read from the INSTALLED conf, never $tmp: the mv above
    # already consumed $tmp, so a $tmp read yields an empty ctrl dir and skips
    # the poll entirely.
    local ctrl_dir="${TRAVELROUTER_CTRL_DIR:-$(sed -n 's/^ctrl_interface=//p' "$AP_CONF" 2>/dev/null | head -1)}"
    local verified=no
    if [[ -n "$ctrl_dir" && -z "${TRAVELROUTER_SKIP_CTRL_POLL:-}" ]]; then
        command -v "$HOSTAPD_CLI" >/dev/null 2>&1 \
            || aplog "WARN: $HOSTAPD_CLI unavailable - liveness degrades to socket presence, which a not-yet-ENABLED radio satisfies"
        local wait_i alive=0
        for ((wait_i = 1; wait_i <= TRAVELROUTER_AP_UP_TIMEOUT; wait_i++)); do
            sleep 1
            if _ap_radio_up "$ctrl_dir" "$ap_iface"; then
                alive=1
                aplog "poll: AP-ENABLED after ${wait_i}s (ctrl=${ctrl_dir} iface=${ap_iface})"
                break
            fi
        done
        # A Restart=on-failure crash loop recreates the socket on every attempt,
        # so require the unit to be active and not mid-restart as well.
        if [[ $alive -eq 1 ]]; then
            local ustate usub
            ustate="$("$SUDO" "$SYSTEMCTL" is-active hostapd-travel.service 2>/dev/null || true)"
            usub="$("$SUDO" "$SYSTEMCTL" show hostapd-travel.service -p SubState --value 2>/dev/null || true)"
            if [[ "$ustate" != "active" || "$usub" == "auto-restart" ]]; then
                aplog "poll: unit unhealthy (is-active=${ustate} sub=${usub}) - treating AP as down"
                alive=0
            fi
        fi
        if [[ $alive -ne 1 ]]; then
            local have_bak=no rb_i
            [[ -f "$AP_CONF.bak" ]] && have_bak=yes
            aplog "FAIL: no AP-ENABLED within ${TRAVELROUTER_AP_UP_TIMEOUT}s; backup_present=${have_bak}; last_hostapd_cli_status='${AP_RADIO_STATUS:-<none-captured>}'"
            log "ap-apply: hostapd did not come up after restart — restoring previous config"
            _ap_restore_ssid "$ap_ssid_prev"
            if [[ "$have_bak" == yes ]]; then
                mv -f "$AP_CONF.bak" "$AP_CONF" 2>/dev/null || true
                "$SUDO" "$SYSTEMCTL" restart hostapd-travel.service >/dev/null 2>&1 || true
                for ((rb_i = 1; rb_i <= TRAVELROUTER_AP_UP_TIMEOUT; rb_i++)); do
                    sleep 1
                    if _ap_radio_up "$ctrl_dir" "$ap_iface"; then
                        aplog "rollback OK: previous config + ap-ssid restored, radio beaconing again after ${rb_i}s"
                        break
                    fi
                    if [[ "$rb_i" -eq "$TRAVELROUTER_AP_UP_TIMEOUT" ]]; then
                        # This check can be UNANSWERABLE (wrong ctrl dir, absent
                        # hostapd_cli), so failing it is not evidence of an outage.
                        aplog "rollback UNVERIFIED: previous config + ap-ssid restored and hostapd restarted, but the radio could not be CONFIRMED beaconing within ${rb_i}s. Liveness is unproven, not disproven - check the AP from a client before re-flashing."
                    fi
                done
            else
                aplog "rollback INCOMPLETE: no backup on disk; the installed conf is the NEW one and the AP identity is unverified"
            fi
            return 1
        fi
        verified=yes
    fi
    # $AP_CONF.bak is the only copy of the pre-rename config, so it must
    # outlive the window in which the radio can still fail to bind.
    if [[ "$verified" == yes ]]; then
        aplog "OK: AP verified beaconing; dropping backup $AP_CONF.bak"
    else
        aplog "poll skipped (ctrl_dir='${ctrl_dir}' skip='${TRAVELROUTER_SKIP_CTRL_POLL:-}'); dropping backup with no liveness proof"
    fi
    rm -f "$AP_CONF.bak" 2>/dev/null || true
    log "ap-apply: AP reconfigured (clients are rejoining)"
    return 0
}

# try-psks (M4): probe each stored candidate for SSID (SSID s-rows in file
# order, then d-row defaults) via a throwaway probe profile. Reserved con-name
# `tr-probe` (autoconnect no) is deleted before AND after every attempt, so it
# never leaks and never auto-activates (NM facts, draft Findings Q2). On a
# working candidate: delete the probe, record the candidate, then run the
# NORMAL connect path so NM persists the real profile. Wall budget ~60s:
# stop issuing NEW attempts once SECONDS >= 60 (finish the current delete).
# rc 0 iff some candidate connected. NEVER log the PSK value (index only).
# NOTE: like collect, attempts are NOT gated on iface_ok (attempt-time
# semantics; the runner has no /sys/class/net, and on the Pi the failure mode
# of a missing adapter must surface from nmcli itself, rc 1).
cmd_try_psks() {
    local ssid="$1"
    if [[ -z "$ssid" ]]; then
        log "try-psks: SSID is required"
        usage
        return 2
    fi
    if [[ "$ssid" =~ ^[[:space:]]*$ ]]; then
        log "try-psks: empty SSID"
        return 2
    fi
    local cands
    cands="$(psk_candidates "$ssid")"
    if [[ -z "$cands" ]]; then
        log "try-psks: no stored candidates for '${ssid}'"
        return 1
    fi
    local total=0
    total="$(printf '%s\n' "$cands" | grep -c .)"
    local idx=0 rc=1 cand t0 now
    t0="$(date +%s)"
    while IFS= read -r cand; do
        [[ -n "$cand" ]] || continue
        now="$(date +%s)"
        if (( now - t0 >= 60 )); then
            log "try-psks: wall budget reached (${idx}/${total} candidates tried)"
            break
        fi
        idx=$((idx+1))
        "$SUDO" "$NMCLI" connection delete tr-probe >/dev/null 2>&1 || true
        # PSK-in-argv accepted risk: each candidate PSK is passed as a command-line
        # argument (`wifi-sec.psk`), so it is world-readable via /proc/<pid>/cmdline
        # while this probe profile exists (try-psks runs within a 60s wall budget).
        # Exposure is local-only: only the `pi` and root accounts exist on the unit,
        # both already privileged, so no privilege boundary is crossed. Accepted
        # risk; the proper fix (stdin or NM D-Bus password delivery) is deferred.
        if "$SUDO" "$NMCLI" connection add type wifi ifname '*' con-name tr-probe ssid "$ssid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$cand" connection.autoconnect no >/dev/null 2>&1; then
            if "$SUDO" "$NMCLI" --wait 15 connection up tr-probe >/dev/null 2>&1; then
                log "try-psks: candidate ${idx}/${total} OK — connected to '${ssid}'"
                "$SUDO" "$NMCLI" connection delete tr-probe >/dev/null 2>&1 || true
                psk_collect "$ssid" "$cand" || true
                cmd_connect "${WIFI_WAN_IF:-}" "$ssid" "$cand"
                return $?
            fi
        fi
        log "try-psks: candidate ${idx}/${total} failed"
        "$SUDO" "$NMCLI" connection delete tr-probe >/dev/null 2>&1 || true
    done < <(printf '%s\n' "$cands")
    log "try-psks: no candidate connected to '${ssid}' (${idx}/${total} tried)"
    return 1
}

cmd_known() {
    # Known wifi networks = NM profiles (the store is NOT consulted here).
    # Reserved probe profile `tr-probe` (try-psks, M4) is excluded.
    # Output: one line per network: NAME<TAB>TIMESTAMP<TAB>AUTOCONNECT.
    local out r name type ts ac nameu rest
    out="$("$NMCLI" -t -f NAME,TYPE,TIMESTAMP,AUTOCONNECT connection show 2>/dev/null)" || true
    printf '%s\n' "$out" | while IFS= read -r r || [[ -n "$r" ]]; do
        [[ -n "$r" ]] || continue
        # Split right-anchored: TYPE/TIMESTAMP/AUTOCONNECT are colon-free, so
        # the last three : fields are theirs; NAME (may contain escaped \:)
        # is everything before them.
        ac="${r##*:}"
        rest="${r%:*}"
        ts="${rest##*:}"
        rest="${rest%:*}"
        type="${rest##*:}"
        name="${rest%:*}"
        [[ "$type" == "802-11-wireless" ]] || continue
        # setup-v2 M2: boilerplate profiles never belong in the known list —
        # the reserved probe (tr-probe) and the Pi Imager helper's seed profile
        # (preconfigured) are dropped before any rendering.
        case " $EXCLUDED_PROFILES " in *" $name "*) continue ;; esac
        # Unescape nmcli terse escaping (\\ -> \, \: -> :) in NAME.
        nameu=""
        while [[ "$name" == *'\'* ]]; do
            nameu="${nameu}${name%%'\'*}"
            name="${name#*'\'}"
            nameu="${nameu}${name%"${name#?}"}"
            name="${name#?}"
        done
        nameu="$nameu$name"
        printf '%s\t%s\t%s\n' "$nameu" "$ts" "$ac"
    done | sort -t "$(printf '\t')" -k2,2 -nr
    return 0
}

cmd_status() {
    local json_mode=0
    local if_name="$1"
    if [[ "$2" == "--json" ]]; then json_mode=1; fi

    # mode + lan_ip come from wan-select's state file; standalone derives from
    # the state mode (never hardcoded). Defaults cover a missing state file.
    local state_mode="" lan_ip=""
    state_mode="$(json_field mode)"
    lan_ip="$(json_field lan_ip)"
    [[ -z "$state_mode" ]] && state_mode="standalone"
    local standalone="false"
    [[ "$state_mode" != "routed" ]] && standalone="true"

    # Connected clients: lease rows joined with hostapd's associated MACs
    # (associated iff the MAC appears in `hostapd_cli all_sta`). Computed
    # BEFORE the degraded-WAN early return: a missing WAN adapter says nothing
    # about the AP side, whose clients must still be listed (one all_sta run,
    # cached — a per-lease call would multiply the process cost).
    local assoc_list=""
    if [[ -x "$(command -v "$HOSTAPD_CLI" 2>/dev/null || true)" ]]; then
        assoc_list="$("$HOSTAPD_CLI" all_sta 2>/dev/null || true)"
    fi

    local clients=0 clients_list=""
    local row expires mac ip hostname sep="" associated
    while IFS= read -r row; do
        IFS=$'\t' read -r expires mac ip hostname <<<"$row"
        clients=$((clients + 1))
        associated="false"
        if [[ -n "$assoc_list" && -n "$mac" && "$assoc_list" == *"$mac"* ]]; then
            associated="true"
        fi
        clients_list="${clients_list}${sep}{\"mac\":\"$(json_escape "$mac")\",\"ip\":\"$(json_escape "$ip")\",\"hostname\":\"$(json_escape "$hostname")\",\"lease_expires\":\"$(json_escape "$expires")\",\"associated\":${associated}}"
        sep=","
    done < <(lease_rows)

    if ! iface_ok "$if_name"; then
        log "WAN wifi device '${if_name:-<empty>}' not available on this model; degraded status only"
        if [[ $json_mode -eq 1 ]]; then
            printf '{"mode":"%s","lan_ip":"%s","wan_if":"","wan_ssid":"","wan_ip":"","internet":"unknown","ap_state":"up","clients":%s,"clients_list":[%s],"standalone":%s}\n' \
                "$state_mode" "$lan_ip" "$clients" "$clients_list" "$standalone"
        else
            log "wan_if='': no WAN wifi adapter present on this model (check the USB dongle)"
        fi
        return 0
    fi

    # NM connection name (read; OK for a non-root caller).
    local connection="" wan_ip=""
    connection="$("$NMCLI" -t -f GENERAL.CONNECTION dev show "$if_name" 2>/dev/null | awk -F: '{print $2}' | head -1)"
    wan_ip="$("$IP" -4 -o addr show dev "$if_name" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    [[ -z "$wan_ip" ]] && wan_ip="$("$IP" route get 1.1.1.1 2>/dev/null | awk '/1.1.1.1/{print $1}' | head -1)"

    local ap_state="up"
    if [[ -x "$(command -v "$HOSTAPD_CLI" 2>/dev/null || true)" ]]; then
        local n
        n="$("$HOSTAPD_CLI" all_sta 2>/dev/null | wc -l | tr -d ' ')"
        ap_state="_sta_count:${n:-0}"
    fi

    local internet="unknown"
    if "$CURL" -4 -fsS -m 5 https://1.1.1.1 >/dev/null 2>&1; then
        internet="yes"
    else
        if "$IP" route get 1.1.1.1 >/dev/null 2>&1; then internet="reachable"; else internet="no"; fi
    fi

    if [[ $json_mode -eq 1 ]]; then
        # Strip quote/backslash so adversarial SSIDs cannot break the JSON.
        local wan_ssid="${connection//\"/}"
        wan_ssid="${wan_ssid//\\/}"
        printf '{"mode":"%s","lan_ip":"%s","wan_if":"%s","wan_ssid":"%s","wan_ip":"%s","internet":"%s","ap_state":"%s","clients":%s,"clients_list":[%s],"standalone":%s}\n' \
            "$state_mode" "$lan_ip" "$if_name" "$wan_ssid" "${wan_ip:-}" "$internet" "$ap_state" "$clients" "$clients_list" "$standalone"
    else
        log "WAN IF  : $if_name"
        log "SSID    : $connection"
        log "WAN IP  : $wan_ip"
        log "INTERNET: $internet"
        log "AP      : $ap_state"
        log "CLIENTS : $clients"
    fi
}

# ap-info: current AP SSID + broadcast (hidden) state as one JSON line. The
# SSID is the LIVE value (AP_SSID_FILE, updated by every ap-apply); the
# hidden state is parsed from the LIVE hostapd conf's ignore_broadcast_ssid
# line — 1 AND 2 both mean hidden (1 = empty beacon, answers probes; 2 =
# fully hidden). Read-only, and every source degrades: missing/empty SSID
# file -> ssid "", missing/unreadable conf -> hidden=false (never an error,
# so the admin page can preload the dialog from a degraded AP).
cmd_ap_info() {
    local ssid="" hidden="false" line=""
    if [[ -s "$AP_SSID_FILE" ]]; then
        ssid="$(head -1 "$AP_SSID_FILE" 2>/dev/null || true)"
    fi
    # set -e makes a failed sed (missing/unreadable conf) abort the whole
    # verb: guard readability, and || true the pipeline so the degrade path
    # (missing/unreadable -> hidden=false) is exercised, never an abort.
    if [[ -r "$AP_CONF" ]]; then
        line="$(sed -n 's/^ignore_broadcast_ssid=//p' "$AP_CONF" 2>/dev/null | head -1 || true)"
    fi
    if [[ -n "$line" && "$line" != "0" ]]; then
        hidden="true"
    fi
    printf '{"ssid":"%s","hidden":%s}\n' "$(json_escape "$ssid")" "$hidden"
}

# stealth-check: READ-ONLY WAN-side management-port self-check. Greps the
# RENDERED ruleset (NFTABLES_TARGET — the same file wan-select writes every
# tick and loads with `nft -f`) for input-chain rules that ACCEPT traffic
# arriving on the WAN interface (iifname "<wan_if>") destined to a management
# port (80/22/53/67). Never mutates anything: no nft call, no file writes.
# Only input-hook accepts count as exposure — a forward accept (LAN->WAN
# routing) and a postrouting masquerade (NAT, no iifname) are NOT reachable
# from the WAN side and must not trip the check.
NFTABLES_TARGET="${NFTABLES_TARGET:-/etc/nftables.conf}"
STEALTH_MGMT_PORTS="80 22 53 67"

# stealth_wan_accept_ports : echo the management ports found in rule lines
# (comments and leading whitespace stripped FIRST — a #comment mentioning
# iifname/accept must never count as a rule) that match iifname "<wan_if>"
# AND contain `accept`. Missing ruleset -> empty (default-deny == stealth).
# A management port counts only as a WHOLE dport number (dport 8080 must
# never report 80): each dport set is cut on its delimiters.
stealth_wan_accept_ports() {
    local wan="$1" line stripped ports p found=""
    [[ -r "$NFTABLES_TARGET" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"            # strip comments (incl. trailing)
        stripped="$(printf '%s' "$line" | tr -d '[:space:]')"
        [[ -n "$stripped" ]] || continue
        case "$stripped" in
            *'iifname"'"$wan"'"'*) ;;
            *) continue ;;
        esac
        case "$stripped" in
            *accept*) ;;
            *) continue ;;
        esac
        case "$stripped" in
            *"dport{"*"}"*)
                ports="${stripped#*dport{}"   # set form: dport{53,67}
                ports="${ports%%\}*}"
                ;;
            *"dport"*)
                # Single form: the whole number right after the first dport
                # (trailing text like comment "dport 80" must not leak in).
                ports="${stripped#*dport}"
                ports="$(printf '%s' "$ports" | sed 's/^[^0-9]*//; s/[^0-9].*//')"
                ;;
            *) continue ;;
        esac
        found=""
        for p in $STEALTH_MGMT_PORTS; do
            case ",$ports," in
                *",$p,"*) found="${found}${found:+,}$p" ;;
            esac
        done
        [[ -n "$found" ]] && printf '%s\n' "$found"
    done < "$NFTABLES_TARGET"
    return 0
}

# Read-only AP-radio capability probe (WS01). Reports whether the onboard AP
# radio can do WPA3/PMF so install (WS02) and the admin page can gate on it.
# Never needs root; a missing iw degrades to "iw":false instead of aborting.
cmd_wifi_capabilities() {
    local ap_iface="" d name dev
    if [[ -d "$SYSFS_ROOT/class/net" ]]; then
        # Same rule as install.sh step (6) / wan-select.sh (3): first wireless
        # whose device path is NOT /usb (the onboard radio), fallback wlan0.
        for d in "$SYSFS_ROOT"/class/net/*; do
            [[ -d "$d" && -d "$d/wireless" ]] || continue
            name="$(basename "$d")"
            dev="$(readlink "$d/device" 2>/dev/null || true)"
            [[ -z "$dev" ]] && dev="$(readlink -f "$d/device" 2>/dev/null || true)"
            if [[ "$dev" != *usb* ]]; then ap_iface="$name"; break; fi
        done
    fi
    [[ -n "$ap_iface" ]] || ap_iface="wlan0"

    local phy=""
    if [[ -e "$SYSFS_ROOT/class/net/$ap_iface/phy80211" ]]; then
        phy="$(basename "$(readlink "$SYSFS_ROOT/class/net/$ap_iface/phy80211" 2>/dev/null || true)")"
        [[ "$phy" == "phy80211" ]] && phy=""
    fi

    if ! command -v "$IW" >/dev/null 2>&1; then
        log "wifi-capabilities: '$IW' not available (cannot probe phy)"
        printf '{"iface":"%s","phy":"%s","ap_mode":false,"sae":false,"pmf":false,"wpa3":false,"bands":[],"iw":false}\n' \
            "$(json_escape "$ap_iface")" "$(json_escape "$phy")"
        return 3
    fi

    [[ -n "$phy" ]] || phy="$("$IW" dev "$ap_iface" info 2>/dev/null | sed -n 's/.*wiphy \([0-9][0-9]*\).*/phy\1/p' | head -1)"

    local dump=""
    if [[ -n "$phy" ]]; then
        dump="$("$IW" phy "$phy" info 2>/dev/null || true)"
    else
        dump="$("$IW" phy 2>/dev/null || true)"
    fi

    local ap_mode=false sae=false pmf=false bandlist=""
    if [[ -n "$dump" ]]; then
        # POSIX classes only: the suite runs on macOS BSD grep (no \s).
        grep -qE '^[[:space:]]+\* AP[[:space:]]*$' <<<"$dump" && ap_mode=true
        if grep -qF 'Device supports SAE' <<<"$dump" || grep -qF '00-0f-ac:8' <<<"$dump"; then
            sae=true
        fi
        # CMAC (00-0f-ac:6) is the BIP cipher = management-frame protection.
        grep -qF 'CMAC' <<<"$dump" && pmf=true
        grep -qE '^[[:space:]]*Band 1:' <<<"$dump" && bandlist="2.4"
        grep -qE '^[[:space:]]*Band 2:' <<<"$dump" && bandlist="${bandlist:+$bandlist,}5"
        grep -qE '^[[:space:]]*Band 4:' <<<"$dump" && bandlist="${bandlist:+$bandlist,}6"
    fi
    local wpa3=false
    [[ "$sae" == "true" && "$ap_mode" == "true" ]] && wpa3=true

    local bands_json=""
    [[ -n "$bandlist" ]] && bands_json="$(printf '%s' "$bandlist" | awk -F, '{for(i=1;i<=NF;i++){printf "%s\"%s\"",(i>1?",":""),$i}}')"

    printf '{"iface":"%s","phy":"%s","ap_mode":%s,"sae":%s,"pmf":%s,"wpa3":%s,"bands":[%s],"iw":true}\n' \
        "$(json_escape "$ap_iface")" "$(json_escape "$phy")" \
        "$ap_mode" "$sae" "$pmf" "$wpa3" "$bands_json"
    return 0
}

cmd_stealth_check() {
    # wan_if comes from the state file (wan-select writes it every tick;
    # standalone mode -> empty string = nothing to accept from = stealth).
    local wan_if="$(json_field wan_if 2>/dev/null || true)"
    local open_ports="" stealth="true"
    if [[ -z "$wan_if" ]]; then
        log "stealth-check: wan_if empty (standalone mode): no WAN-facing input accepts possible"
    elif [[ ! -r "$NFTABLES_TARGET" ]]; then
        # Absence of the ruleset file means default-deny (nothing loaded that
        # accepts from the WAN): treat as stealth, never an error.
        log "stealth-check: ruleset '$NFTABLES_TARGET' missing/unreadable: treating as default-deny (stealth)"
    else
        open_ports="$(stealth_wan_accept_ports "$wan_if" | paste -sd, -)"
        [[ -n "$open_ports" ]] && stealth="false"
    fi
    printf '{"stealth":%s,"wan_if":"%s","open_ports":[%s]}\n' \
        "$stealth" "$(json_escape "$wan_if")" "$open_ports"
}

cmd_clients() {
    # Connected-clients rows as a JSON array (or human TAB lines). Same live
    # derivation as status's clients_list; no interface check, so it works
    # regardless of the WAN adapter.
    local json_mode=0
    [[ "${1:-}" == "--json" ]] && json_mode=1
    local assoc_list=""
    if [[ -x "$(command -v "$HOSTAPD_CLI" 2>/dev/null || true)" ]]; then
        assoc_list="$("$HOSTAPD_CLI" all_sta 2>/dev/null || true)"
    fi
    local row expires mac ip hostname sep="" buf="" associated
    while IFS= read -r row; do
        IFS=$'\t' read -r expires mac ip hostname <<<"$row"
        associated="false"
        if [[ -n "$assoc_list" && -n "$mac" && "$assoc_list" == *"$mac"* ]]; then
            associated="true"
        fi
        if [[ $json_mode -eq 1 ]]; then
            buf="${buf}${sep}{\"mac\":\"$(json_escape "$mac")\",\"ip\":\"$(json_escape "$ip")\",\"hostname\":\"$(json_escape "$hostname")\",\"lease_expires\":\"$(json_escape "$expires")\",\"associated\":${associated}}"
            sep=","
        else
            printf '%s\t%s\t%s\t%s\n' "$mac" "$ip" "$hostname" "$expires"
        fi
    done < <(lease_rows)
    if [[ $json_mode -eq 1 ]]; then printf '[%s]\n' "$(printf '%s' "$buf")"; fi
    return 0
}

# --- block list (MAC block wave) ---------------------------------------------
# The block store is the SAME file wan-select renders into the nftables
# blocked_macs set every 30s tick (TRAVELROUTER_BLOCK_FILE, one MAC per
# line, 0600 root). One row per MAC, stored lowercase (the render
# normalizes case, but a canonical file keeps dedupe trivial).

# mac_ok MAC : full 6-group colon MAC (case-insensitive). The single gate
# for every verb argument; a malformed MAC must never reach the store.
mac_ok() {
    [[ "$1" =~ ^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$ ]]
}

# block_file_rows : echo each valid MAC row of the block file (lowercased,
# blanks/comments/junk dropped). Missing file -> empty. Never aborts.
block_file_rows() {
    [[ -r "$BLOCK_FILE" ]] || return 0
    local row m
    while IFS= read -r row || [[ -n "$row" ]]; do
        m="$(printf '%s' "$row" | tr -d '[:space:]')"
        [[ -n "$m" ]] || continue
        case "$m" in "#"*) continue ;; esac
        m="$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')"
        [[ "$m" =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]] || continue
        printf '%s\n' "$m"
    done < "$BLOCK_FILE"
    return 0
}

# block_file_write ROWS... : atomically replace the store with the given
# rows (0600, same-dir tmp + mv — the psk-store idiom). rc 2 on write
# failure so the caller can fail WITHOUT mutating the store.
block_file_write() {
    local dir="." tmp r
    case "$BLOCK_FILE" in */*) dir="${BLOCK_FILE%/*}" ;; esac
    tmp="$dir/.blocked-macs.$$"
    { for r in "$@"; do printf '%s\n' "$r"; done; } > "$tmp" 2>/dev/null \
        || { rm -f "$tmp" 2>/dev/null || true; log "block: cannot write '$dir' (store unchanged)"; return 2; }
    chmod 0600 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$BLOCK_FILE" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        log "block: cannot replace '$BLOCK_FILE' (store unchanged)"
        return 2
    fi
    return 0
}

# block_reload : make the new block set live NOW (no 30s-tick wait). The
# render is owned by wan-select, so this only (re)starts wan-select.service
# (its 30s work is idempotent and it renders + `nft -f` every run). Needs
# root on the Pi: routed through the SUDO seam like every other privileged
# call in this script.
block_reload() {
    if [[ "${TRAVELROUTER_DRY_RUN:-0}" == "1" ]]; then
        log "block: dry-run: would restart wan-select.service (re-render + nft -f)"
        return 0
    fi
    if ! "$SUDO" "$SYSTEMCTL" start wan-select.service >/dev/null 2>&1; then
        log "block: wan-select restart FAILED (set applies on the next 30s tick)"
        return 1
    fi
    return 0
}

# deauth_suppress_stamp : tell the WS03 watcher the disconnect(s) we are about
# to cause are self-inflicted (AP restart / MAC kick), not a forged-deauth
# burst. Best-effort: a failed stamp must never change a verb's rc.
deauth_suppress_stamp() {
    local f="${TRAVELROUTER_DEAUTH_SUPPRESS_FILE:-/run/travel-router/deauth-suppress}"
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    : > "$f" 2>/dev/null || true
    chmod 0600 "$f" 2>/dev/null || true
}

# block_kick MAC AP_IFACE : deauthenticate a connected station NOW via
# hostapd_cli on the AP (LAN) interface. Best-effort: rc is deliberately
# ignored (radio down / station already gone / hostapd busy must never flip
# the block verb's rc — the firewall drop is the enforcement, the kick is a
# courtesy). Needs root: SUDO seam, same as systemctl above.
block_kick() {
    local mac="$1" ap="$2"
    [[ -n "$ap" ]] || return 0
    if [[ "${TRAVELROUTER_DRY_RUN:-0}" == "1" ]]; then
        log "block: dry-run: hostapd_cli -i $ap deauthenticate $mac"
        return 0
    fi
    deauth_suppress_stamp
    "$SUDO" "$HOSTAPD_CLI" -i "$ap" deauthenticate "$mac" >/dev/null 2>&1 || true
}

# ap_iface_for_kick : the AP interface to kick on. Same derivation as
# ap-apply/state (hostapd conf's interface= line, else the state file's
# ap_interface), no hardcoding.
ap_iface_for_kick() {
    local ap=""
    ap="$(sed -n 's/^interface=//p' "$AP_CONF" 2>/dev/null | head -1)"
    if [[ -z "$ap" ]]; then
        ap="$(json_field ap_interface 2>/dev/null || true)"
    fi
    printf '%s' "$ap"
}

cmd_block() {
    local mac="${1:-}"
    if [[ -z "$mac" ]]; then
        log "block: MAC is required"
        usage
        return 2
    fi
    if ! mac_ok "$mac"; then
        log "block: malformed MAC '${mac}' (want aa:bb:cc:dd:ee:ff)"
        return 2
    fi
    mac="$(printf '%s' "$mac" | tr '[:upper:]' '[:lower:]')"
    local rows=() r found=0
    while IFS= read -r r || [[ -n "$r" ]]; do
        [[ -n "$r" ]] || continue
        [[ "$r" == "$mac" ]] && found=1
        rows[${#rows[@]}]="$r"
    done < <(block_file_rows)
    if [[ $found -eq 1 ]]; then
        log "block: '${mac}' already blocked"
        block_reload || true
        return 0
    fi
    rows[${#rows[@]}]="$mac"
    if [[ "${TRAVELROUTER_DRY_RUN:-0}" == "1" ]]; then
        log "block: dry-run: would record '${mac}' in '$BLOCK_FILE'"
        return 0
    fi
    block_file_write ${rows[@]+"${rows[@]}"} || return 1
    log "block: '${mac}' added (firewall drop applies on reload)"
    block_reload || true
    # Kick now (best-effort) so a live station drops immediately.
    block_kick "$mac" "$(ap_iface_for_kick)"
    return 0
}

cmd_unblock() {
    local mac="${1:-}"
    if [[ -z "$mac" ]]; then
        log "unblock: MAC is required"
        usage
        return 2
    fi
    if ! mac_ok "$mac"; then
        log "unblock: malformed MAC '${mac}' (want aa:bb:cc:dd:ee:ff)"
        return 2
    fi
    mac="$(printf '%s' "$mac" | tr '[:upper:]' '[:lower:]')"
    local rows=() r found=0
    while IFS= read -r r || [[ -n "$r" ]]; do
        [[ -n "$r" ]] || continue
        if [[ "$r" == "$mac" ]]; then found=1; continue; fi
        rows[${#rows[@]}]="$r"
    done < <(block_file_rows)
    if [[ $found -eq 0 ]]; then
        log "unblock: '${mac}' is not blocked"
        return 1
    fi
    if [[ "${TRAVELROUTER_DRY_RUN:-0}" == "1" ]]; then
        log "unblock: dry-run: would remove '${mac}' from '$BLOCK_FILE'"
        return 0
    fi
    if [[ ${#rows[@]} -eq 0 ]]; then
        rm -f "$BLOCK_FILE" 2>/dev/null || true
    else
        block_file_write ${rows[@]+"${rows[@]}"} || return 1
    fi
    log "unblock: '${mac}' removed (allow applies on reload)"
    block_reload || true
    return 0
}

cmd_blocked() {
    # Prints one blocked MAC per line (normalized). Empty store -> rc 0, no
    # output (the admin UI renders an empty list, not an error).
    block_file_rows
    return 0
}

main() {
    local sub="${1:-}"
    if [[ -z "$sub" ]]; then
        usage
        return 1
    fi
    shift || true
    case "$sub" in
        scan)
            local if_name="${1:-$WIFI_WAN_IF}"
            cmd_scan "$if_name"
            ;;
        connect)
            local s="${1:-}" p="${2:-}"
            cmd_connect "${WIFI_WAN_IF:-}" "$s" "$p"
            ;;
        disconnect)
            cmd_disconnect "${WIFI_WAN_IF:-}"
            ;;
        forget)
            cmd_forget "${WIFI_WAN_IF:-}" "$@"
            ;;
        wipe-stale)
            cmd_wipe_stale "$@"
            ;;
        known)
            cmd_known
            ;;
        collect)
            cmd_collect "$@"
            ;;
        psks-add)
            cmd_psks_add "${1:-}" "${2:-}"
            ;;
        psks-add-default)
            cmd_psks_add_default "${1:-}"
            ;;
        psks-list)
            cmd_psks_list
            ;;
        clients)
            cmd_clients "${1:-}"
            ;;
        block)
            cmd_block "${1:-}"
            ;;
        unblock)
            cmd_unblock "${1:-}"
            ;;
        blocked)
            cmd_blocked
            ;;
        psks-del)
            cmd_psks_del "${1:-}"
            ;;
        ap-apply)
            cmd_ap_apply "${1:-}" "${2:-}" "${3:-}"
            ;;
        ap-info)
            cmd_ap_info "${1:-}"
            ;;
        stealth-check)
            cmd_stealth_check
            ;;
        wifi-capabilities)
            cmd_wifi_capabilities
            ;;
        ap-ssid)
            if [[ -s "$AP_SSID_FILE" ]]; then
                head -1 "$AP_SSID_FILE" 2>/dev/null || true
                return 0
            fi
            log "ap-ssid: no live AP SSID recorded ('$AP_SSID_FILE' missing or empty)"
            return 1
            ;;
        try-psks)
            cmd_try_psks "${1:-}"
            ;;
        status)
            cmd_status "${WIFI_WAN_IF:-}" "${1:-}"
            ;;
        recheck)
            log "recheck: triggering wan-select now (it also re-runs every 30s via wan-select.timer; wan-if=${WIFI_WAN_IF:-none})"
            "$SUDO" "$SYSTEMCTL" start wan-select.service
            ;;
        --help|-h|help)
            usage
            ;;
        *)
            usage
            echo "ERROR: unknown subcommand '${sub}'"
            return 2
            ;;
    esac
}

main "$@"
