#!/bin/bash
# netdata-child role: install Netdata and stream this Pi's metrics to the
# monitor Pi's Netdata parent. Intended to be added to a fleet Pi's
# role.deps so it runs alongside that Pi's primary role, or used directly
# as the role for a Pi whose only job is to be monitored.
#
# Requires NETDATA_STREAM_API_KEY (shared with the parent) and optionally
# NETDATA_PARENT_HOST (defaults to the host extracted from NATS_URL, since
# the monitor Pi runs both NATS and the Netdata parent).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ROLE_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$ROLE_DIR/assets"
LOG_TAG="[netdata-child]"
log() { echo "$LOG_TAG $*"; }

# Source role.env (two-path idiom).
ROLE_ENV="/boot/firmware/role/role.env"
[[ -f "$ROLE_ENV" ]] || ROLE_ENV="/boot/role/role.env"
if [[ -f "$ROLE_ENV" ]]; then
  log "loading $ROLE_ENV"
  set -a; source "$ROLE_ENV"; set +a
fi

# Run base role first (idempotent). base also installs the NATS announcer,
# so this Pi will publish its identity to the monitor Pi's broker.
if [[ -x /boot/firmware/role/base/install.sh ]]; then
  log "running base role"
  bash /boot/firmware/role/base/install.sh
fi

# -----------------------------------------------------------------------------
# Resolve parent host. Default: derive from NATS_URL (strip nats:// + port).
# e.g. nats://192.168.0.151:4222  ->  192.168.0.151
# -----------------------------------------------------------------------------
if [[ -z "${NETDATA_PARENT_HOST:-}" ]]; then
  if [[ -n "${NATS_URL:-}" ]]; then
    NETDATA_PARENT_HOST="$(echo "$NATS_URL" | sed -E 's|^[a-z]+://||; s|[:/].*||')"
    log "NETDATA_PARENT_HOST unset; derived '$NETDATA_PARENT_HOST' from NATS_URL"
  else
    NETDATA_PARENT_HOST=""
  fi
fi

if [[ -z "$NETDATA_PARENT_HOST" ]]; then
  log "ERROR: NETDATA_PARENT_HOST not set and NATS_URL not available to derive it."
  log "ERROR: set NATS_URL (or NETDATA_PARENT_HOST) in .env and re-provision."
  log "ERROR: netdata will install but won't stream anywhere until fixed."
fi

if [[ -z "${NETDATA_STREAM_API_KEY:-}" ]]; then
  log "ERROR: NETDATA_STREAM_API_KEY not set in role.env."
  log "ERROR: generate one with: uuidgen"
  log "ERROR: put it in .env as NETDATA_STREAM_API_KEY (same value as the monitor Pi)."
  log "ERROR: netdata will install but the parent will reject the stream."
fi

# -----------------------------------------------------------------------------
# Install Netdata via the official kickstart. Idempotent: if already
# installed, kickstart.sh detects it and exits cleanly. We pass
# --stable-channel --disable-telemetry to match the parent role.
# -----------------------------------------------------------------------------
log "installing netdata (child)"
if ! command -v netdata >/dev/null 2>&1; then
  log "running netdata kickstart (stable channel, telemetry off)"
  curl -fsSL https://my-netdata.io/kickstart.sh | sh -s -- --stable-channel --disable-telemetry
else
  log "netdata already installed: $(netdata -v 2>/dev/null | head -1)"
fi

# -----------------------------------------------------------------------------
# Write child stream.conf pointing at the parent. Only write if we have
# both required values; otherwise leave netdata running with its default
# (local-only) config so the Pi's own dashboard still works on :19999.
# -----------------------------------------------------------------------------
NETDATA_CONF_DIR="/etc/netdata"
if [[ -d "$NETDATA_CONF_DIR" && -n "$NETDATA_PARENT_HOST" && -n "${NETDATA_STREAM_API_KEY:-}" ]]; then
  log "writing child stream.conf -> $NETDATA_PARENT_HOST:19999"
  sed -e "s|__PARENT_HOST__|$NETDATA_PARENT_HOST|g" \
      -e "s|__API_KEY__|$NETDATA_STREAM_API_KEY|g" \
      "$ASSETS/stream.conf.child" \
      > "$NETDATA_CONF_DIR/stream.conf"
  chmod 0640 "$NETDATA_CONF_DIR/stream.conf"
  chgrp netdata "$NETDATA_CONF_DIR/stream.conf" 2>/dev/null || true
else
  log "WARNING: not writing stream.conf (missing parent host or API key)"
  log "WARNING: netdata is running with local-only config (dashboard on :19999)"
fi

systemctl enable netdata 2>/dev/null || true
systemctl restart netdata 2>/dev/null || log "WARNING: netdata restart returned non-zero"

if [[ -n "$NETDATA_PARENT_HOST" && -n "${NETDATA_STREAM_API_KEY:-}" ]]; then
  log "done. streaming to http://$NETDATA_PARENT_HOST:19999"
  log "view this Pi's metrics on the parent's dashboard (the parent aggregates all children)."
else
  log "done (local-only). fix NETDATA_PARENT_HOST/NETDATA_STREAM_API_KEY in .env and re-provision to stream."
fi