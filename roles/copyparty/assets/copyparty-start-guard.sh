#!/bin/bash
set -euo pipefail

LOG_TAG="[copyparty-start-guard]"
log() { echo "$LOG_TAG $*"; }

# Read environment variables (provided by systemd unit)
COPYPARTY_CRYPT="${COPYPARTY_CRYPT:-0}"
COPYPARTY_DIR="${COPYPARTY_DIR:-/var/lib/copyparty}"
# Marker path can be overridden for testing
CRYPT_MARKER="${CRYPT_MARKER:-/run/copyparty-crypt.mounted}"

# If crypto is disabled, succeed immediately
if [[ "$COPYPARTY_CRYPT" != "1" ]]; then
  exit 0
fi

# Verify the mountpoint exists
if ! mountpoint -q "$COPYPARTY_DIR"; then
  log "FATAL: crypt mount missing - refusing to serve plaintext"
  exit 1
fi

# Verify the marker file exists
if [[ ! -f "$CRYPT_MARKER" ]]; then
  log "FATAL: crypt mount marker missing - refusing to serve plaintext"
  exit 1
fi

exit 0
