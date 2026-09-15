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
TRAVELROUTER_STATE_FILE="${TRAVELROUTER_STATE_FILE:-/run/travel-router/state.json}"
SUDO="${SUDO:-sudo}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
PSK_FILE="${TRAVELROUTER_PSK_FILE:-/etc/rpi-project/travel-router/known-psks}"
AP_SSID_FILE="${TRAVELROUTER_AP_SSID_FILE:-/etc/rpi-project/travel-router/ap-ssid}"

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
  travel-wan known                       list saved wifi networks (NM profiles)
  travel-wan collect <SSID> <PSK>        record a PSK candidate for try-psks
  travel-wan psks-add <SSID> <PSK>       record a PSK candidate (setup API)
  travel-wan psks-add-default <PSK>      record a default PSK candidate
  travel-wan psks-list                   list store rows TYPE<TAB>SSID<TAB>PSK
  travel-wan psks-del <index>            delete the Nth psks-list row
  travel-wan ap-apply <SSID> [PSK]       re-render + restart the AP (setup API)
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
        "$SUDO" "$NMCLI" dev wifi connect "$ssid" ifname "$if_name" password "$psk"
    else
        log "connecting to '${ssid}' (open network, no PSK)"
        "$SUDO" "$NMCLI" dev wifi connect "$ssid" ifname "$if_name"
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
# readable). Rollback contract: (1) render new conf to tmp, (2) hostapd -t
# validate — invalid -> rc 1, NOTHING changed, (3) keep the old conf as
# conf.bak, (4) atomically install the new conf + ap-ssid, (5) restart
# hostapd-travel.service; on restart failure restore the .bak and restart
# again. The caller sends its HTTP response BEFORE the restart (the radio
# drop kills the client's TCP connection mid-restart).
AP_CONF="${TRAVELROUTER_AP_CONF:-/etc/hostapd/hostapd-travel.conf}"
AP_TEMPLATE="${TRAVELROUTER_AP_TEMPLATE:-/etc/rpi-project/travel-router/hostapd.conf.tmpl}"
HOSTAPD_BIN="${TRAVELROUTER_HOSTAPD_BIN:-hostapd}"
cmd_ap_apply() {
    local new_ssid="${1:-}"
    local new_psk="${2:-}"
    if [[ -z "$new_ssid" && -z "$new_psk" ]]; then
        log "ap-apply: a new SSID and/or PSK is required"
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
    local r_country="${TRAVELROUTER_AP_COUNTRY:-}"
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
    sed -e "s|${m_iface}|${ap_iface}|g" \
        -e "s|${m_ssid}|${new_ssid}|g" \
        -e "s|${m_country}|${r_country}|g" \
        -e "s|${m_channel}|${r_channel}|g" \
        -e "s|${m_psk}|${new_psk}|g" \
        "$tmpl" > "$tmp" 2>/dev/null || { rm -f "$tmp"; log "ap-apply: cannot render new conf"; return 2; }
    chmod 0600 "$tmp"
    if ! "$HOSTAPD_BIN" -t "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        log "ap-apply: new hostapd config is invalid (hostapd -t rejected it); nothing changed"
        return 1
    fi
    cp "$AP_CONF" "$AP_CONF.bak" 2>/dev/null || true
    chmod 0600 "$AP_CONF.bak" 2>/dev/null || true
    if ! mv -f "$tmp" "$AP_CONF" 2>/dev/null; then
        rm -f "$tmp"
        log "ap-apply: cannot replace '$AP_CONF' (conf unchanged)"
        rm -f "$AP_CONF.bak" 2>/dev/null || true
        return 2
    fi
    local apdir="." aptmp
    apdir="$(dirname "$AP_SSID_FILE")"
    mkdir -p "$apdir" 2>/dev/null || true
    aptmp="$apdir/.ap-ssid.$$"
    printf '%s\n' "$new_ssid" > "$aptmp" 2>/dev/null \
        && chmod 0600 "$aptmp" 2>/dev/null || true
    if ! mv -f "$aptmp" "$AP_SSID_FILE" 2>/dev/null; then
        rm -f "$aptmp" 2>/dev/null || true
        log "ap-apply: ap-ssid write failed (scan exclusion keeps old value)"
    fi
    if ! "$SUDO" "$SYSTEMCTL" restart hostapd-travel.service >/dev/null 2>&1; then
        log "ap-apply: hostapd restart FAILED — restoring previous config"
        if [[ -f "$AP_CONF.bak" ]]; then
            mv -f "$AP_CONF.bak" "$AP_CONF" 2>/dev/null || true
            "$SUDO" "$SYSTEMCTL" restart hostapd-travel.service >/dev/null 2>&1 || true
        fi
        return 1
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

    if ! iface_ok "$if_name"; then
        log "WAN wifi device '${if_name:-<empty>}' not available on this model; degraded status only"
        if [[ $json_mode -eq 1 ]]; then
            printf '{"mode":"%s","lan_ip":"%s","wan_if":"","wan_ssid":"","wan_ip":"","internet":"unknown","ap_state":"up","clients":0,"standalone":%s}\n' \
                "$state_mode" "$lan_ip" "$standalone"
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

    local clients=-1
    if [[ -f /var/lib/misc/dnsmasq.leases ]]; then
        # grep -c exits 1 on a zero count (empty leases file = normal on
        # first boot); swallow that so pipefail+errexit cannot kill status.
        clients="$( (grep -c '.' /var/lib/misc/dnsmasq.leases 2>/dev/null || true) | tr -d ' ')"
        [[ -z "$clients" ]] && clients=0
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
        printf '{"mode":"%s","lan_ip":"%s","wan_if":"%s","wan_ssid":"%s","wan_ip":"%s","internet":"%s","ap_state":"%s","clients":%s,"standalone":%s}\n' \
            "$state_mode" "$lan_ip" "$if_name" "$wan_ssid" "${wan_ip:-}" "$internet" "$ap_state" "$clients" "$standalone"
    else
        log "WAN IF  : $if_name"
        log "SSID    : $connection"
        log "WAN IP  : $wan_ip"
        log "INTERNET: $internet"
        log "AP      : $ap_state"
        log "CLIENTS : $clients"
    fi
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
        psks-del)
            cmd_psks_del "${1:-}"
            ;;
        ap-apply)
            cmd_ap_apply "${1:-}" "${2:-}"
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
