#!/bin/bash
set -euo pipefail

log() { echo "[nats-announce] $*"; }

: "${NATS_URL:=nats://192.168.0.151:4222}"
: "${NATS_SUBJECT_PREFIX:=rpi.nodes}"
: "${NATS_ANNOUNCE_EVENT:=online}"
: "${NATS_ANNOUNCE_ATTEMPTS:=20}"
: "${NATS_ANNOUNCE_RETRY_SEC:=3}"

for role_env in /boot/firmware/role/role.env /boot/role/role.env; do
  if [[ -f "$role_env" ]]; then
    source "$role_env"
    break
  fi
done

json_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

json_string() {
  printf '"%s"' "$(json_escape "${1:-}")"
}

build_payload() {
  local hostname_value role_value os_id os_version_id os_version_codename os_pretty_name
  local model device_type serial uptime_sec ips ips_json macs_json first ip addr_file iface mac timestamp

  hostname_value="$(hostname 2>/dev/null || printf 'unknown')"
  role_value="${ROLE:-unknown}"

  os_id="unknown"
  os_version_id="unknown"
  os_version_codename="unknown"
  os_pretty_name="unknown"
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    os_id="${ID:-unknown}"
    os_version_id="${VERSION_ID:-unknown}"
    os_version_codename="${VERSION_CODENAME:-unknown}"
    os_pretty_name="${PRETTY_NAME:-unknown}"
  fi

  model="unknown"
  if [[ -r /proc/device-tree/model ]]; then
    model="$(tr -d '\0' </proc/device-tree/model)"
  fi

  device_type="linux-device"
  if [[ "$model" == *"Raspberry Pi"* ]]; then
    device_type="raspberry-pi"
  fi

  serial="unknown"
  if [[ -r /proc/cpuinfo ]]; then
    serial="$(awk -F: 'tolower($1) ~ /serial/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' /proc/cpuinfo)"
    serial="${serial:-unknown}"
  fi

  uptime_sec="0"
  if [[ -r /proc/uptime ]]; then
    uptime_sec="$(awk '{print int($1)}' /proc/uptime)"
  fi

  ips_json="[]"
  ips="$(hostname -I 2>/dev/null | tr ' ' '\n' | sed '/^$/d' || true)"
  if [[ -n "$ips" ]]; then
    ips_json="["
    first=1
    while IFS= read -r ip; do
      [[ -n "$ip" ]] || continue
      if [[ $first -eq 0 ]]; then ips_json+=","; fi
      ips_json+="$(json_string "$ip")"
      first=0
    done <<<"$ips"
    ips_json+="]"
  fi

  macs_json="[]"
  first=1
  for addr_file in /sys/class/net/*/address; do
    [[ -r "$addr_file" ]] || continue
    iface="$(basename "$(dirname "$addr_file")")"
    [[ "$iface" == "lo" ]] && continue
    mac="$(tr '[:upper:]' '[:lower:]' <"$addr_file")"
    [[ -n "$mac" && "$mac" != "00:00:00:00:00:00" ]] || continue
    if [[ $first -eq 1 ]]; then
      macs_json="["
    else
      macs_json+=","
    fi
    macs_json+="{\"iface\":$(json_string "$iface"),\"mac\":$(json_string "$mac")}"
    first=0
  done
  if [[ $first -eq 0 ]]; then
    macs_json+="]"
  fi

  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  subject="${NATS_SUBJECT_PREFIX}.${hostname_value}.${NATS_ANNOUNCE_EVENT}"
  payload="{\"event\":$(json_string "$NATS_ANNOUNCE_EVENT"),\"hostname\":$(json_string "$hostname_value"),\"role\":$(json_string "$role_value"),\"device_type\":$(json_string "$device_type"),\"model\":$(json_string "$model"),\"serial\":$(json_string "$serial"),\"os\":{\"id\":$(json_string "$os_id"),\"version_id\":$(json_string "$os_version_id"),\"version_codename\":$(json_string "$os_version_codename"),\"pretty_name\":$(json_string "$os_pretty_name")},\"network\":{\"ips\":$ips_json,\"macs\":$macs_json},\"uptime_sec\":$uptime_sec,\"ts\":$(json_string "$timestamp")}"
}

subject=""
payload=""

if [[ "${NATS_ANNOUNCE_DRY_RUN:-0}" == "1" ]]; then
  build_payload
  printf '%s\n' "$payload"
  exit 0
fi

url_no_scheme="${NATS_URL#*://}"
authority="${url_no_scheme%%/*}"
authority="${authority%%\?*}"
authority="${authority%%#*}"
hostport="${authority##*@}"
host="$hostport"
port="4222"
if [[ "$hostport" == *":"* ]]; then
  host="${hostport%:*}"
  port="${hostport##*:}"
fi

if [[ -z "$host" || -z "$port" ]]; then
  log "invalid NATS_URL: $NATS_URL" >&2
  exit 2
fi

for attempt in $(seq 1 "$NATS_ANNOUNCE_ATTEMPTS"); do
  if exec 3<>"/dev/tcp/$host/$port"; then
    build_payload
    read -r -t 2 _server_info <&3 || true
    printf 'CONNECT {"verbose":false,"pedantic":false}\r\n' >&3
    printf 'PUB %s %d\r\n%s\r\n' "$subject" "${#payload}" "$payload" >&3
    printf 'PING\r\n' >&3
    read -r -t 2 _pong <&3 || true
    exec 3>&-
    exec 3<&-
    touch /run/rpi-nats-announce.sent 2>/dev/null || true
    log "published $subject to $host:$port"
    exit 0
  fi
  log "publish attempt $attempt/$NATS_ANNOUNCE_ATTEMPTS failed for $host:$port"
  sleep "$NATS_ANNOUNCE_RETRY_SEC"
done

log "failed to publish after $NATS_ANNOUNCE_ATTEMPTS attempts" >&2
exit 1
