#!/bin/bash
# deauth-watch.sh — Tier-1 forged-deauth detection (WS03, WS decision D3).
#
# Heuristic ONLY: counts AP-interface station disconnects in a sliding window
# and, on a burst, writes a labelled alert file + publishes a NATS
# deauth-alert. WPA2 management frames are unauthenticated, so this detects a
# likely forged-deauth/disassoc attack; it is NOT proof and NEVER auto-rotates
# the SSID (rotation is not a defense and self-DoSes — see WS-decisions.md).
#
# Sourced by no one; run as a Type=simple systemd service. Exits nonzero when
# the event source ends so systemd restarts it.
set -uo pipefail

log() { printf '[deauth-watch] %s\n' "$*" >&2; }

IW="${IW:-iw}"
HOSTNAME_BIN="${HOSTNAME_BIN:-hostname}"
NATS_URL="${NATS_URL:-nats://192.168.0.151:4222}"
NATS_SUBJECT_PREFIX="${NATS_SUBJECT_PREFIX:-rpi.nodes}"

THRESHOLD="${TRAVELROUTER_DEAUTH_THRESHOLD:-5}"
WINDOW_SEC="${TRAVELROUTER_DEAUTH_WINDOW_SEC:-10}"
COOLDOWN_SEC="${TRAVELROUTER_DEAUTH_COOLDOWN_SEC:-60}"
SUPPRESS_SEC="${TRAVELROUTER_DEAUTH_SUPPRESS_SEC:-15}"
ALERT_FILE="${TRAVELROUTER_DEAUTH_ALERT_FILE:-/run/travel-router/deauth-alert.json}"
SUPPRESS_FILE="${TRAVELROUTER_DEAUTH_SUPPRESS_FILE:-/run/travel-router/deauth-suppress}"
EVENT_SRC="${TRAVELROUTER_DEAUTH_EVENT_SRC:-}"
DRY_RUN="${TRAVELROUTER_DEAUTH_DRY_RUN:-0}"

now() { date +%s; }

# Portable mtime (BSD stat first, then GNU). Echoes 0 when the file is absent.
mtime_of() {
  local f="$1"
  [[ -f "$f" ]] || { printf '0'; return; }
  stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || printf '0'
}

host="$( "$HOSTNAME_BIN" 2>/dev/null || printf 'unknown' )"
subject="${NATS_SUBJECT_PREFIX}.${host}.deauth-alert"

json_escape() {
  local v="${1:-}"
  v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
  v=$(printf '%s' "$v" | LC_ALL=C tr -d '\001-\037')
  printf '%s' "$v"
}

write_alert() {
  local count="$1" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$ALERT_FILE")" 2>/dev/null || true
  printf '{"event":"deauth-alert","count":%s,"window_sec":%s,"threshold":%s,"host":"%s","ts":"%s"}\n' \
    "$count" "$WINDOW_SEC" "$THRESHOLD" "$(json_escape "$host")" "$ts" > "$ALERT_FILE.tmp" 2>/dev/null \
    && mv -f "$ALERT_FILE.tmp" "$ALERT_FILE" 2>/dev/null || true
  chmod 0644 "$ALERT_FILE" 2>/dev/null || true
}

publish_alert() {
  local count="$1" payload
  payload="$(cat "$ALERT_FILE" 2>/dev/null || printf '{}')"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run: would publish $subject count=$count payload=$payload"
    return 0
  fi
  local url_no_scheme authority hostport h p
  url_no_scheme="${NATS_URL#*://}"
  authority="${url_no_scheme%%/*}"; authority="${authority%%\?*}"; authority="${authority%%#*}"
  hostport="${authority##*@}"; h="$hostport"; p="4222"
  if [[ "$hostport" == *":"* ]]; then h="${hostport%:*}"; p="${hostport##*:}"; fi
  [[ -n "$h" ]] || { log "invalid NATS_URL: $NATS_URL"; return 0; }
  if exec 3<>"/dev/tcp/$h/$p"; then
    read -r -t 2 _info <&3 || true
    printf 'CONNECT {"verbose":false,"pedantic":false}\r\n' >&3
    printf 'PUB %s %d\r\n%s\r\n' "$subject" "${#payload}" "$payload" >&3
    printf 'PING\r\n' >&3
    read -r -t 2 _pong <&3 || true
    exec 3>&-; exec 3<&-
    log "published $subject count=$count to $h:$p"
  else
    log "publish failed (no route to $h:$p); alert file remains"
  fi
  return 0
}

fire() {
  local count="$1"
  write_alert "$count"
  publish_alert "$count"
}

if [[ -n "$EVENT_SRC" ]]; then
  [[ -r "$EVENT_SRC" ]] || { log "event source '$EVENT_SRC' not readable"; exit 1; }
  event_stream() { cat "$EVENT_SRC"; }
else
  command -v "$IW" >/dev/null 2>&1 || { log "'$IW' not available (cannot watch); AP detection needs iw or TRAVELROUTER_DEAUTH_EVENT_SRC"; exit 1; }
  event_stream() { "$IW" event; }
fi

log "watching for disconnect bursts (threshold=${THRESHOLD} window=${WINDOW_SEC}s cooldown=${COOLDOWN_SEC}s)"

win=()
event_stream | while IFS= read -r line; do
  case "$line" in
    *"del station"*|*"AP-STA-DISCONNECTED"*|*"DISCONNECTED"*) ;;
    *) continue ;;
  esac
  # Self-suppression: our own ap-apply restart / MAC block kick is not an attack.
  s_mt="$(mtime_of "$SUPPRESS_FILE")"
  if [[ "$s_mt" != "0" ]]; then
    s_age=$(( $(now) - s_mt ))
    if [[ "$s_age" -lt "$SUPPRESS_SEC" ]]; then
      log "disconnect ignored (self-suppression active, age=${s_age}s)"
      continue
    fi
  fi
  t="$(now)"
  win+=("$t")
  # Prune entries outside the window.
  kept=()
  for e in "${win[@]}"; do
    [[ $(( t - e )) -lt "$WINDOW_SEC" ]] && kept+=("$e")
  done
  win=("${kept[@]}")
  if [[ "${#win[@]}" -ge "$THRESHOLD" ]]; then
    # Cooldown: the alert file mtime is the last-fire clock (persists across restarts).
    a_mt="$(mtime_of "$ALERT_FILE")"
    in_cd=0
    if [[ "$a_mt" != "0" ]]; then
      [[ $(( t - a_mt )) -lt "$COOLDOWN_SEC" ]] && in_cd=1
    fi
    if [[ "$in_cd" -eq 1 ]]; then
      log "burst of ${#win[@]} within window but in cooldown; not firing"
    else
      fire "${#win[@]}"
      log "DEAUTH BURST: ${#win[@]} disconnects in ${WINDOW_SEC}s -> alert"
    fi
    win=()
  fi
done

log "event source ended; exiting so systemd restarts the watcher"
exit 1
