#!/usr/bin/env bash
# rotate-accounts.sh — push a password rotation for copyparty accounts to a Pi
#
# One command does the whole cycle:
#   1. generate a fresh random password per account (python3 secrets)
#   2. back up /etc/copyparty/args on the Pi, rewrite the -a lines
#   3. restart copyparty, wait for active
#   4. VERIFY every new pair with a real HTTP login (fail-closed: on failure,
#      stop — .env is NOT touched, the old args backup path is printed)
#   5. mirror the new pairs into .env COPYPARTY_ACCOUNTS on this host
#   6. print the new pairs ONCE (you store them; they are not logged here)
#
# Usage:
#   rotate-accounts.sh [user1 user2 ...]     # rotate named accounts (default: all)
#   rotate-accounts.sh --check               # show current accounts + perms, no change
#   rotate-accounts.sh --pi user@host|ip     # target a different Pi (default auto-detect)
#
# SSH auth must already work (your key is authorized for pi@<pi>).
set -euo pipefail

ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd)/.env"
PI_TARGET=""
DO_CHECK=0

log() { echo "[rotate] $*"; }
die() { echo "[rotate] ERROR: $*" >&2; exit 1; }

usage() {
  grep '^#' "$0" | sed 's/^# \{0,2\}//' | sed -n '2,30p'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) DO_CHECK=1; shift ;;
    --pi) PI_TARGET="$2"; shift 2 ;;
    -h|--help|help) usage ;;
    -*) die "unknown flag: $1 (see --help)" ;;
    *) BREAKOUT_USERS+=("$1"); shift ;;
  esac
done

detect_pi() {
  # inventory.yaml last_ip of the copyparty Pi, else common LAN guesses
  local inv
  inv="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd)/inventory.yaml"
  if [[ -f "$inv" ]]; then
    # crude read: first last_ip under the block with notes mentioning copyparty
    awk '/hostname:/{h=$2} /notes:.*copyparty/{print h}' "$inv" | head -1 >/dev/null 2>&1 || true
  fi
  for ip in 192.168.0.106 192.168.0.35; do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "pi@$ip" true 2>/dev/null; then
      echo "$ip"; return 0
    fi
  done
  return 1
}

PI="${PI_TARGET:-$(detect_pi)}" || die "no reachable Pi found (tried LAN guesses). Use --pi user@host"
[[ "$PI" == *@* ]] || PI="pi@$PI"
log "target Pi: $PI"

# ---------------------------------------------------------------------------
current_args() {
  ssh -o ConnectTimeout=8 -o BatchMode=yes "$PI" 'sudo cat /etc/copyparty/args'
}

if [[ "$DO_CHECK" == "1" ]]; then
  echo "current /etc/copyparty/args (password fields redacted):"
  current_args | sed -E 's/^(-a [^:]+):.*/\1:<redacted>/'
  echo
  echo "volume line:"
  current_args | grep '^--usernames' -A10 | grep '^-' | head -5
  exit 0
fi

read args_now < <(current_args)

# collect accounts from the live args (source of truth on the Pi)
mapfile -t ARG_PAIRS < <(current_args | grep -E '^-a ' | sed 's/^-a //')
mapfile -t ENV_PAIRS < <(grep -E '^COPYPARTY_ACCOUNTS=' "$ENV_FILE" | head -1 | sed -E 's/^COPYPARTY_ACCOUNTS="?//; s/"?$//' | tr ',' '\n')

if [[ ${#ARG_PAIRS[@]} -eq 0 ]]; then
  die "no -a lines found in /etc/copyparty/args on $PI — is copyparty installed?"
fi

# usernames to rotate: explicit list, else all live accounts
if [[ "${BREAKOUT_USERS[@]+x}" == "x" && ${#BREAKOUT_USERS[@]} -gt 0 ]]; then
  WANTED=("${BREAKOUT_USERS[@]}")
else
  WANTED=()
  for pair in "${ARG_PAIRS[@]}"; do WANTED+=("${pair%%:*}"); done
fi

# ---------------------------------------------------------------------------
# 1. generate passwords
declare -A NEWPW
for u in "${WANTED[@]}"; do
  [[ " ${ARG_PAIRS[*]} " == *" $u:"* ]] || die "account '$u' not present on Pi (existing: ${ARG_PAIRS[*]%%:*})"
  NEWPW[$u]="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
done

TMPARGS="$(mktemp)"
trap 'rm -f "$TMPARGS" "$TMPENV"' EXIT

# 2. build the new args content locally (rewrite -a lines for rotated users)
current_args | while IFS= read -r line; do
  for u in "${WANTED[@]}"; do
    if [[ "$line" == "-a $u:"* ]]; then
      printf -- "-a %s:%s\n" "$u" "${NEWPW[$u]}"
      continue 2
    fi
  done
  printf '%s\n' "$line"
done > "$TMPARGS"

[[ -s "$TMPARGS" ]] || die "rendered args file empty — aborting before anything touched"
bash -n "$TMPARGS" 2>/dev/null || true   # not a script; just a non-empty sanity gate

# 3. push + restart over a single sudo sh -c
log "pushing new args + restarting copyparty on $PI …"
scp -q -o ConnectTimeout=8 -o BatchMode=yes "$TMPARGS" "$PI:/tmp/args.new" \
  || die "scp failed"
ssh -o ConnectTimeout=8 -o BatchMode=yes "$PI" '
  set -e
  sudo cp /etc/copyparty/args /etc/copyparty/args.bak-$(date +%Y%m%d-%H%M%S)-rotation
  sudo sh -c "cat /tmp/args.new > /etc/copyparty/args && rm -f /tmp/args.new"
  sudo systemctl restart copyparty
  for i in $(seq 1 20); do
    sleep 1
    if systemctl is-active --quiet copyparty; then exit 0; fi
  done
  systemctl is-active copyparty
' || { echo "restore with:"; echo "  ssh $PI 'sudo cp \$(ls -t /etc/copyparty/args.bak-* | head -1) /etc/copyparty/args && sudo systemctl restart copyparty'"; die "restart failed"; }
log "service active"

# need the bind IP for verification: copyparty binds tailscale-ip + 127.0.0.1;
# from the Mac, reach it via a local port-forward through the LAN SSH session.
TMPENV="$(mktemp)"
PORT=$(( (RANDOM % 5000) + 20000 ))
ssh -o ConnectTimeout=8 -o BatchMode=yes -f -N -L "$PORT:127.0.0.1:3923" "$PI"
TUNNEL_PID="$(pgrep -f "ssh.*-L $PORT:" | tail -1)"
trap 'rm -f "$TMPARGS" "$TMPENV"; [[ -n "${TUNNEL_PID:-}" ]] && kill "$TUNNEL_PID" 2>/dev/null' EXIT
sleep 1

# 4. fail-closed verification: EVERY rotated pair must log in
log "verifying logins …"
for u in "${WANTED[@]}"; do
  code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -u "$u:${NEWPW[$u]}" "http://127.0.0.1:$PORT/")" \
    || code=000
  if [[ "$code" != "200" ]]; then
    die "login FAILED for $u (HTTP $code). .env NOT modified. Args backup exists on the Pi."
  fi
done
log "all ${#WANTED[@]} account(s) verified with new passwords"

# 5. mirror into .env: rebuild COPYPARTY_ACCOUNTS from live args (now new)
NEW_PAIRS_CSV="$(current_args | grep -E '^-a ' | sed 's/^-a //' | paste -sd, -)"
TMPENV="$(mktemp)"
python3 - "$ENV_FILE" "$NEW_PAIRS_CSV" <<'PYEOF'
import re, sys
path, csv = sys.argv[1], sys.argv[2]
s = open(path).read()
if "COPYPARTY_ACCOUNTS=" in s:
    s = re.sub(r'COPYPARTY_ACCOUNTS=.*', f'COPYPARTY_ACCOUNTS="{csv}"', s)
else:
    s += f'\nCOPYPARTY_ACCOUNTS="{csv}"\n'
open(path, "w").write(s)
PYEOF
log ".env mirrored (COPYPARTY_ACCOUNTS updated to match Pi)"

# 6. report once
echo
echo "=============================================================="
echo " ROTATION COMPLETE — store these now (printed once):"
for u in "${WANTED[@]}"; do
  echo "   $u : ${NEWPW[$u]}"
done
echo " (.env updated to match; older args backups remain on the Pi)"
echo "=============================================================="