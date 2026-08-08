#!/bin/bash
# Bring Tailscale up on first boot: join the tailnet with an auth key, enable
# Tailscale SSH, and advertise the LAN subnet as a subnet router. Invoked by
# tailscale-up.service (oneshot, runs once thanks to ConditionPathExists on a
# done-marker). On success we scrub the one-time auth key from role.env on
# the bootfs partition so it can't be reused if the card is re-provisioned.
set -euo pipefail

log() { echo "[tailscale-up] $*"; }

# Load role.env (two-path idiom matches the rest of the project: Trixie uses
# /boot/firmware, Bookworm uses /boot).
for role_env in /boot/firmware/role/role.env /boot/role/role.env; do
  if [[ -f "$role_env" ]]; then
    set -a; source "$role_env"; set +a
    break
  fi
done

: "${TAILSCALE_SUBNET:=192.168.0.0/24}"
: "${TAILSCALE_HOSTNAME:=$(hostname)}"
: "${TAILSCALE_ACCEPT_ROUTES:=1}"

# No auth key = nothing we can do. Exit 0 (not a failure) so the Pi still
# boots and is reachable on LAN for the user to fix .env and re-run.
if [[ -z "${TAILSCALE_AUTH_KEY:-}" ]]; then
  log "ERROR: TAILSCALE_AUTH_KEY not set in role.env."
  log "Set it in .env on the provisioning host and re-provision, or run:"
  log "  tailscale up --ssh --advertise-routes=$TAILSCALE_SUBNET --hostname=$TAILSCALE_HOSTNAME"
  touch /run/tailscale-up.done
  exit 0
fi

# Build the tailscale up argv. --accept-routes lets the Pi honour other subnet
# routers on the same tailnet (default on; pass TAILSCALE_ACCEPT_ROUTES=0 off).
args=(--ssh --advertise-routes="$TAILSCALE_SUBNET" --hostname="$TAILSCALE_HOSTNAME")
if [[ "$TAILSCALE_ACCEPT_ROUTES" == "1" ]]; then
  args+=(--accept-routes)
fi
args+=(--auth-key="$TAILSCALE_AUTH_KEY")

log "running: tailscale up --ssh --advertise-routes=$TAILSCALE_SUBNET --hostname=$TAILSCALE_HOSTNAME --auth-key=<redacted>"
if ! tailscale up "${args[@]}" 2>&1; then
  log "FAILED to bring Tailscale up. Check /var/log/role-setup.log and the admin console."
  log "Common causes: expired/used auth key, tailnet policy blocks the key, or no internet."
  exit 1
fi

# Scrub the one-time auth key from role.env on the bootfs so it can't leak if
# the SD card is later re-read on another host. Rewrite the file without the
# TAILSCALE_AUTH_KEY line.
for role_env in /boot/firmware/role/role.env /boot/role/role.env; do
  if [[ -f "$role_env" ]]; then
    tmp="$(mktemp)"
    grep -v '^TAILSCALE_AUTH_KEY=' "$role_env" >"$tmp" || true
    # Preserve mode; source file is 0644.
    cat "$tmp" >"$role_env"
    rm -f "$tmp"
    log "scrubbed TAILSCALE_AUTH_KEY from $role_env"
    break
  fi
done

touch /run/tailscale-up.done
log "Tailscale is up. Tailscale IPv4: $(tailscale ip -4 2>/dev/null || echo unknown)"
log "Remember to approve the node AND its $TAILSCALE_SUBNET subnet route at:"
log "  https://login.tailscale.com/admin/machines"
log "  (Machines -> this node -> Approve + Edit route settings -> enable $TAILSCALE_SUBNET)"