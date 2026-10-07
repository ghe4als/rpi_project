#!/bin/bash
set -euo pipefail
LOG_TAG="[crypt-mount]"
log() { echo "$LOG_TAG $*"; }

# Load role.env (two-path idiom)
ROLE_ENV="/boot/firmware/role/role.env"
[[ -f "$ROLE_ENV" ]] || ROLE_ENV="/boot/role/role.env"
if [[ -f "$ROLE_ENV" ]]; then
  log "loading $ROLE_ENV"
  set -a; source "$ROLE_ENV"; set +a
fi

# Ensure required vars
: "${COPYPARTY_DIR:=/var/lib/copyparty}"
: "${COPYPARTY_CRYPT:=0}"

if [[ "$COPYPARTY_CRYPT" != "1" ]]; then
  log "COPYPARTY_CRYPT not enabled; exiting"
  exit 0
fi

# Determine keyfile path (primary then alternate)
KEYFILE_PRIMARY="/boot/firmware/role/copyparty.crypt.key"
KEYFILE_ALT="/boot/role/copyparty.crypt.key"
if [[ -f "$KEYFILE_PRIMARY" ]]; then
  CRYPT_KEYFILE="$KEYFILE_PRIMARY"
elif [[ -f "$KEYFILE_ALT" ]]; then
  CRYPT_KEYFILE="$KEYFILE_ALT"
else
  log "ERROR: crypt keyfile not found"
  exit 1
fi

# Backing directory
CRYPT_BACKING="$(dirname "$COPYPARTY_DIR")/$(basename "$COPYPARTY_DIR")-crypt"

# No-op if already mounted
if mountpoint -q "$COPYPARTY_DIR"; then
  log "already mounted"
  exit 0
fi

# Ensure backing exists and owned by copyparty (init should have set this)
if [[ ! -d "$CRYPT_BACKING" ]]; then
  log "ERROR: backing dir $CRYPT_BACKING missing"
  exit 1
fi

# Mount using stored key. Must run AS the copyparty user (FUSE mounts are
# per-user; a root mount stonewalls the unprivileged service user and root
# cannot itself access copyparty-owned FUSE - proven on hardware). Falls back
# to plain gocryptfs if runuser is unavailable (non-Pi dev boxes).
if command -v runuser >/dev/null 2>&1 && id copyparty >/dev/null 2>&1; then
  runuser -u copyparty -- gocryptfs -extpass "cat $CRYPT_KEYFILE" "$CRYPT_BACKING" "$COPYPARTY_DIR"
else
  gocryptfs -extpass "cat $CRYPT_KEYFILE" "$CRYPT_BACKING" "$COPYPARTY_DIR"
fi

# Write marker
mkdir -p /run
touch /run/copyparty-crypt.mounted
log "mount succeeded"
