#!/bin/bash
# copyparty-start: wait for the tailnet interface to get its IP, then exec
# copyparty bound ONLY to that IP (+ loopback for local health checks).
# Invoked by copyparty.service (Type=notify). Fails loudly if tailscale
# never comes up — the service stays failed with a clear journal message.
#
# Resolution reads the tailscale0 interface IP directly (unprivileged, no
# tailscaled-socket dependency) instead of `tailscale ip`, which needs
# socket access the copyparty service user may not have. Waiting on the
# interface rather than tailscale-up.service because that unit is a oneshot
# that goes inactive/dead AFTER succeeding — is-active would never fire.
set -euo pipefail

ARGFILE=/etc/copyparty/args
WAIT_SEC="${COPYPARTY_WAIT_SEC:-180}"
LOG_TAG="[copyparty-start]"
log() { echo "$LOG_TAG $*"; }

deadline=$(( $(date +%s) + WAIT_SEC ))
TS_IP=""
while :; do
  TS_IP="$(ip -4 -o addr show dev tailscale0 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}')"
  [[ -n "$TS_IP" ]] && break
  if [[ $(date +%s) -ge $deadline ]]; then
    log "ERROR: tailscale0 has no IPv4 after ${WAIT_SEC}s (tailnet not up?)."
    log "Check: journalctl -u tailscale-up.service; approve the node at"
    log "https://login.tailscale.com/admin/machines, then systemctl restart copyparty"
    exit 1
  fi
  sleep 5
done
log "resolved Tailscale IPv4: $TS_IP — binding copyparty to it"

# Bind ONLY to loopback + the Tailscale IP. Never 0.0.0.0 / ::.
exec /usr/bin/python3 /usr/local/bin/copyparty \
  -i "$TS_IP,127.0.0.1" \
  -c "$ARGFILE"