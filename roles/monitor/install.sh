#!/bin/bash
# monitor role: NATS server (JetStream + :8222 monitoring) + Netdata parent.
# Intended for a always-on Pi 4 on the LAN that acts as the local message
# broker and metrics aggregation point for the fleet.
#
# NATS:  single static binary from GitHub releases, armhf/arm64 auto-detected.
#        JetStream persistence under /var/lib/nats/jetstream, HTTP monitoring
#        endpoint on :8222 (/varz), no auth (trusted LAN).
# Netdata: official kickstart.sh, stable channel, telemetry off. Configured
#        as a parent that accepts child streams authenticating with the
#        shared NETDATA_STREAM_API_KEY from role.env.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ROLE_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$ROLE_DIR/assets"
LOG_TAG="[monitor]"
log() { echo "$LOG_TAG $*"; }

# Source role.env (Trixie: /boot/firmware, Bookworm: /boot).
ROLE_ENV="/boot/firmware/role/role.env"
[[ -f "$ROLE_ENV" ]] || ROLE_ENV="/boot/role/role.env"
if [[ -f "$ROLE_ENV" ]]; then
  log "loading $ROLE_ENV"
  set -a; source "$ROLE_ENV"; set +a
fi

# Run base role first (idempotent).
if [[ -x /boot/firmware/role/base/install.sh ]]; then
  log "running base role"
  bash /boot/firmware/role/base/install.sh
fi

# -----------------------------------------------------------------------------
# 1. NATS server
# -----------------------------------------------------------------------------
log "installing NATS server"

# Pick the right prebuilt binary for the board's arch. nats-server ships
# single-file Go binaries for arm64 and armhf on every release.
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) NATS_ARCH="arm64" ;;
  armv7l|armhf)  NATS_ARCH="arm7"  ;;
  x86_64)        NATS_ARCH="amd64" ;;
  *) log "ERROR: unsupported arch for nats-server: $ARCH"; exit 1 ;;
esac

: "${NATS_VERSION:=2.14.4}"
NATS_BIN="/usr/local/bin/nats-server"
NATS_URL="https://github.com/nats-io/nats-server/releases/download/v${NATS_VERSION}/nats-server-v${NATS_VERSION}-linux-${NATS_ARCH}.tar.gz"

if [[ -x "$NATS_BIN" ]] && "$NATS_BIN" -v 2>/dev/null | grep -q "^nats-server v${NATS_VERSION}"; then
  log "nats-server $NATS_VERSION already installed"
else
  log "downloading nats-server v${NATS_VERSION} ($NATS_ARCH)"
  apt-get update -y
  apt-get install -y --no-install-recommends tar
  tmp="$(mktemp -d)"
  curl -fsSL "$NATS_URL" -o "$tmp/nats.tar.gz"
  tar -xzf "$tmp/nats.tar.gz" -C "$tmp"
  install -m 0755 "$tmp/nats-server-v${NATS_VERSION}-linux-${NATS_ARCH}/nats-server" "$NATS_BIN"
  rm -rf "$tmp"
  log "nats-server $("$NATS_BIN" -v)"
fi

# Dedicated nats user + storage dir.
if ! getent passwd nats >/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin nats
fi
install -d -o nats -g nats -m 0755 /var/lib/nats /var/lib/nats/jetstream

install -d -m 0755 /etc/nats
install -m 0644 "$ASSETS/nats/nats-server.conf" /etc/nats/nats-server.conf

install -m 0644 "$ASSETS/nats/nats-server.service" /etc/systemd/system/nats-server.service
systemctl daemon-reload
systemctl enable nats-server.service

# Don't start inline - role-setup runs early; let systemd bring it up at
# multi-user. We do restart it if already running (re-provision case).
systemctl restart nats-server.service 2>/dev/null || true

log "NATS:  listening :4222  monitoring :8222/varz  JetStream /var/lib/nats/jetstream"

# -----------------------------------------------------------------------------
# 2. Netdata parent
# -----------------------------------------------------------------------------
log "installing Netdata (parent)"

if ! command -v netdata >/dev/null 2>&1; then
  log "running netdata kickstart (stable channel, telemetry off)"
  curl -fsSL https://my-netdata.io/kickstart.sh | sh -s -- --stable-channel --disable-telemetry
else
  log "netdata already installed: $(netdata -v 2>/dev/null | head -1)"
fi

# Parent stream config: accept children with the shared API key. If the key
# is missing, children won't authenticate - warn loudly but continue (the
# parent dashboard still shows the monitor Pi's own metrics).
NETDATA_CONF_DIR="/etc/netdata"
if [[ -d "$NETDATA_CONF_DIR" ]]; then
  if [[ -z "${NETDATA_STREAM_API_KEY:-}" ]]; then
    log "WARNING: NETDATA_STREAM_API_KEY not set in role.env."
    log "WARNING: children will not be able to stream to this parent."
    log "WARNING: generate one with: uuidgen"
    log "WARNING: put it in .env as NETDATA_STREAM_API_KEY and re-provision."
  else
    log "writing parent stream.conf with API key (children can stream)"
    sed "s|__API_KEY__|$NETDATA_STREAM_API_KEY|g" \
      "$ASSETS/netdata/stream.conf.parent" \
      > "$NETDATA_CONF_DIR/stream.conf"
    chmod 0640 "$NETDATA_CONF_DIR/stream.conf"
    chgrp netdata "$NETDATA_CONF_DIR/stream.conf" 2>/dev/null || true
  fi
else
  log "WARNING: $NETDATA_CONF_DIR not found - netdata install may have failed"
fi

# Enable + (re)start netdata so it picks up the new stream.conf.
systemctl enable netdata 2>/dev/null || true
systemctl restart netdata 2>/dev/null || log "WARNING: netdata restart returned non-zero"

log "Netdata parent: dashboard on :19999  (children stream to :19999 with the shared API key)"
log "done. dashboards:"
log "  Netdata:    http://<this-host>:19999"
log "  NATS /varz: http://<this-host>:8222/varz"