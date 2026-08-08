#!/bin/bash
# tailscale role: install Tailscale from the official repo and bring it up on
# first boot as a subnet router with Tailscale SSH enabled.
#
# Install happens here (now, during role-setup.service). Bring-up happens in
# a separate oneshot service (tailscale-up.service) that waits for
# network-online.target + tailscaled.service before running `tailscale up`
# with the one-time auth key from role.env.
#
# The auth key is scrubbed from role.env on the bootfs after a successful
# `tailscale up` so a re-read of the card can't leak it.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ROLE_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$ROLE_DIR/assets"
LOG_TAG="[tailscale]"
log() { echo "$LOG_TAG $*"; }

# Source role.env for defaults (Trixie: /boot/firmware, Bookworm: /boot).
ROLE_ENV="/boot/firmware/role/role.env"
[[ -f "$ROLE_ENV" ]] || ROLE_ENV="/boot/role/role.env"
if [[ -f "$ROLE_ENV" ]]; then
  log "loading $ROLE_ENV"
  set -a; source "$ROLE_ENV"; set +a
fi

: "${TAILSCALE_SUBNET:=192.168.0.0/24}"
: "${TAILSCALE_HOSTNAME:=$(hostname)}"
: "${TAILSCALE_UP_TIMEOUT_SEC:=120}"

# Run base role first (idempotent: if a prior role already ran base, apt
# update + common packages are already in place).
if [[ -x /boot/firmware/role/base/install.sh ]]; then
  log "running base role"
  bash /boot/firmware/role/base/install.sh
fi

# Install Tailscale via the official installer script. Adds the Tailscale apt
# signing key + source list, then apt-installs the `tailscale` package. Guard
# with command -v so a re-run doesn't re-download.
if command -v tailscale >/dev/null 2>&1; then
  log "tailscale already installed: $(tailscale version 2>/dev/null | awk 'NR==1{print $2}')"
else
  log "installing tailscale via official installer"
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# A subnet router must forward packets. Enable IPv4 (and IPv6) forwarding via
# a sysctl drop-in so it survives reboot, and apply now so this boot works too.
log "enabling IP forwarding for subnet router"
cat >/etc/sysctl.d/99-tailscale.conf <<'EOF'
# Required for Tailscale subnet routing (advertised routes need forwarding).
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
chmod 0644 /etc/sysctl.d/99-tailscale.conf
sysctl --system >/dev/null 2>&1 || log "WARNING: sysctl --system returned non-zero (continuing)"

# Install the bring-up wrapper + service. The service is a oneshot that waits
# for network-online + tailscaled before running `tailscale up` with the auth
# key. We do NOT start it inline (it needs network-online which may not be
# up yet during role-setup); systemd starts it on its own at multi-user.
log "installing tailscale-up wrapper + service"
install -m 0755 "$ASSETS/tailscale-up.sh" /usr/local/bin/tailscale-up

sed -e "s|__SUBNET__|$TAILSCALE_SUBNET|g" \
    -e "s|__HOSTNAME__|$TAILSCALE_HOSTNAME|g" \
    -e "s|__TIMEOUT__|$TAILSCALE_UP_TIMEOUT_SEC|g" \
    "$ASSETS/tailscale-up.service" \
    > /etc/systemd/system/tailscale-up.service
chmod 0644 /etc/systemd/system/tailscale-up.service

systemctl daemon-reload
systemctl enable tailscale-up.service

log "done. tailscale-up.service will run once at boot to join the tailnet."
log "subnet router will advertise: $TAILSCALE_SUBNET"
log "after first boot, approve the node + subnet route at:"
log "  https://login.tailscale.com/admin/machines"
log "logs: journalctl -u tailscale-up.service  or  /var/log/role-setup.log"