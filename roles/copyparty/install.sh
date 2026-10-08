#!/bin/bash
# copyparty role: file server reachable ONLY over the Tailscale interface.
#
# Depends on the `tailscale` role (role.deps) which installs tailscaled and
# brings up the tailnet in a separate oneshot (tailscale-up.service). This
# installer stages a wrapped copyparty.service that waits for that bring-up,
# resolves the Pi's Tailscale IPv4 at runtime, and runs copyparty bound to
# that single IP (--i) so nothing listens on LAN/public interfaces.
#
# Facts from copyparty 1.20.24 (github.com/9001/copyparty, commit 74b1737):
#   - pure Python, arm32/arm64 ok; sfx = single file, no pip needed
#   - -i <ip> -p <port>: bind one interface/port (default port 3923)
#   - -v src:dst:perms  -a user:pass: shares/accounts
#   - no /health endpoint; healthcheck = GET /?reset=/._ -> 200
#     (the repo's own docker-compose probe, hidden from logs by /._)
#   - systemd Type=notify: copyparty signals READY=1 when accepting conns
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ROLE_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$ROLE_DIR/assets"
LOG_TAG="[copyparty]"
log() { echo "$LOG_TAG $*"; }

# Source role.env (two-path idiom; Trixie: /boot/firmware, Bookworm: /boot).
ROLE_ENV="/boot/firmware/role/role.env"
[[ -f "$ROLE_ENV" ]] || ROLE_ENV="/boot/role/role.env"
if [[ -f "$ROLE_ENV" ]]; then
  log "loading $ROLE_ENV"
  set -a; source "$ROLE_ENV"; set +a
fi

: "${COPYPARTY_PORT:=3923}"
: "${COPYPARTY_DIR:=/var/lib/copyparty}"
: "${COPYPARTY_SFX_URL:=https://github.com/9001/copyparty/releases/latest/download/copyparty-sfx.py}"
# WAIT must stay < systemd's TimeoutStartSec=300 in copyparty.service, or
# systemd kills the start before the tailnet wait finishes.
: "${COPYPARTY_WAIT_SEC:=180}"
: "${COPYPARTY_CRYPT:=0}"

# -----------------------------------------------------------------------------
# At-rest crypto (opt-in): COPYPARTY_CRYPT=1 puts a gocryptfs volume UNDER the
# share root. The share mountpoint stays $COPYPARTY_DIR; ciphertext backs it.
# Requires COPYPARTY_CRYPT_KEY (staged to bootfs 0600 root, never logged).
# Fail-closed is enforced by copyparty.service ordering + a start guard (todo
# 3 of the plan); re-runs must not re-init (gocryptfs.conf is the marker) and
# must not rotate keys (existing keyfile is left untouched).
# -----------------------------------------------------------------------------
if [[ "$COPYPARTY_CRYPT" == "1" ]]; then
  if [[ -z "${COPYPARTY_CRYPT_KEY:-}" ]]; then
    log "ERROR: COPYPARTY_CRYPT_KEY is required when COPYPARTY_CRYPT=1"
    log "ERROR: set it in .env on the provisioning host and re-provision."
    exit 1
  fi
  if ! command -v gocryptfs >/dev/null 2>&1 || ! command -v age >/dev/null 2>&1; then
    log "installing gocryptfs and age"
    apt-get update && apt-get install -y gocryptfs age
  fi
  KEYFILE_PRIMARY="/boot/firmware/role/copyparty.crypt.key"
  KEYFILE_ALT="/boot/role/copyparty.crypt.key"
  CRYPT_KEYFILE="$KEYFILE_PRIMARY"
  if [[ ! -f "$KEYFILE_PRIMARY" && ! -f "$KEYFILE_ALT" ]]; then
    mkdir -p "$(dirname "$KEYFILE_PRIMARY")"
    install -m 0600 /dev/null "$KEYFILE_PRIMARY"
    printf '%s' "$COPYPARTY_CRYPT_KEY" > "$KEYFILE_PRIMARY"
    chown root:root "$KEYFILE_PRIMARY"
  fi
  [[ -f "$KEYFILE_PRIMARY" ]] || CRYPT_KEYFILE="$KEYFILE_ALT"

  CRYPT_BACKING="$(dirname "$COPYPARTY_DIR")/$(basename "$COPYPARTY_DIR")-crypt"
  if [[ ! -f "$CRYPT_BACKING/gocryptfs.conf" ]]; then
    mkdir -p "$CRYPT_BACKING"
    chown copyparty:copyparty "$CRYPT_BACKING"
    TMPPASS="$(mktemp)"
    chmod 0600 "$TMPPASS"
    printf '%s' "$COPYPARTY_CRYPT_KEY" > "$TMPPASS"
    gocryptfs -init -passfile "$TMPPASS" "$CRYPT_BACKING"
    rm -f "$TMPPASS"
    log "initialized gocryptfs volume at $CRYPT_BACKING"
  fi

  install -m 0755 "$ASSETS/crypt-mount.sh" /usr/local/bin/crypt-mount
  install -m 0644 "$ASSETS/crypt-unlock.service" /etc/systemd/system/crypt-unlock.service
  systemctl daemon-reload
  systemctl enable crypt-unlock.service
  log "crypt volume ready: share=$COPYPARTY_DIR backing=$CRYPT_BACKING"
fi

# Run base role first (idempotent).
if [[ -x /boot/firmware/role/base/install.sh ]]; then
  log "running base role"
  bash /boot/firmware/role/base/install.sh
fi

# Run the tailscale dependency role. The dispatcher execs only the SELECTED
# role's install.sh, so each role must run its own dep roles explicitly
# (same pattern as every role running base). The tailscale installer stages
# tailscaled + tailscale-up.service; the bring-up itself happens at
# multi-user in tailscale-up.service using the auth key from role.env.
for dep in $(cat "$ROLE_DIR/role.deps" 2>/dev/null); do
  case "$dep" in ''|\#*) continue ;; esac
  if [[ -x "/boot/firmware/role/$dep/install.sh" ]]; then
    log "running dependency role: $dep"
    bash "/boot/firmware/role/$dep/install.sh"
  elif [[ -x "/boot/role/$dep/install.sh" ]]; then
    log "running dependency role: $dep"
    bash "/boot/role/$dep/install.sh"
  else
    log "ERROR: dependency role '$dep' staged but no install.sh found"
    exit 1
  fi
done

# Service account: system user+group, no login shell. Idempotent for re-runs.
if ! id copyparty >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$COPYPARTY_DIR" \
    --shell /usr/sbin/nologin copyparty
  log "created system user copyparty"
fi

# Share root: the default (/var/lib/copyparty) is created here so a fresh
# flash needs no hand-steps. A CUSTOM COPYPARTY_DIR (e.g. a USB mount) must
# exist already — mkdir-on-missing would land on the SD card and get shadowed
# once the real mount shows up.
# NOTE: with COPYPARTY_CRYPT=1 the share is a gocryptfs FUSE mount owned by
# the copyparty user — root cannot write into it, so asset staging must run
# as copyparty (mobile-folder-upload.js proven on hardware).
if [[ ! -d "$COPYPARTY_DIR" && "$COPYPARTY_DIR" == "/var/lib/copyparty" ]]; then
  mkdir -p "$COPYPARTY_DIR"
fi
if [[ ! -d "$COPYPARTY_DIR" ]]; then
  log "ERROR: COPYPARTY_DIR '$COPYPARTY_DIR' does not exist."
  log "ERROR: mount/prepare it, or leave COPYPARTY_DIR unset for /var/lib/copyparty."
  exit 1
fi
chown copyparty:copyparty "$COPYPARTY_DIR"

# -----------------------------------------------------------------------------
# Browser JS: mobile-folder-upload.js restores the folder picker on Android
# (upstream hard-codes files-only on touch devices; modern Android engines
# support the webkitdirectory input). Served from inside the share as
# /.res/mfu.js and injected via --js-browser in the args file.
# -----------------------------------------------------------------------------
RES_DIR="$COPYPARTY_DIR/.res"
if [[ ! -d "$RES_DIR" ]]; then
  sudo -u copyparty mkdir -p "$RES_DIR"
fi
install -m 0644 "$ASSETS/mobile-folder-upload.js" "$RES_DIR/mfu.js.tmp"
chown copyparty:copyparty "$RES_DIR/mfu.js.tmp"
sudo -u copyparty mv "$RES_DIR/mfu.js.tmp" "$RES_DIR/mfu.js"

# -----------------------------------------------------------------------------
# Accounts are REQUIRED (auth-only posture: every request needs a login):
# COPYPARTY_ACCOUNTS="user:pass,user2:pass2".
# Empirical note (copyparty 1.20.24): without --usernames each account logs
# in with the PASSWORD ALONE (-u :pw1 → 200), so usernames must be required.
# -----------------------------------------------------------------------------
ACC_ARGS=()
if [[ -z "${COPYPARTY_ACCOUNTS:-}" ]]; then
  log "ERROR: COPYPARTY_ACCOUNTS is required (auth-only posture)."
  log "ERROR: set it in .env, e.g. COPYPARTY_ACCOUNTS=\"user:pass\" and re-provision."
  exit 1
fi
IFS=',' read -r -a PAIRS <<< "$COPYPARTY_ACCOUNTS"
for pair in "${PAIRS[@]}"; do
  pair="${pair//[[:space:]]/}"
  [[ "$pair" == *:* ]] || { log "ERROR: bad account pair '$pair' (expect user:pass)"; exit 1; }
  u="${pair%%:*}"; p="${pair#*:}"
  [[ -n "$u" && -n "$p" ]] || { log "ERROR: empty user or pass in '$pair'"; exit 1; }
  ACC_ARGS+=(-a "$u:$p")
done
log "accounts configured: ${#ACC_ARGS[@]} user(s) (creds staged from .env, not logged)"

# -----------------------------------------------------------------------------
# Install copyparty as a single-file sfx (pure Python; needs only python3,
# which base already guarantees). Idempotent: skip if the binary exists.
# -----------------------------------------------------------------------------
BIN=/usr/local/bin/copyparty
if [[ -f "$BIN" ]]; then
  log "copyparty sfx already present: $BIN"
else
  log "downloading copyparty sfx from $COPYPARTY_SFX_URL"
  curl -fsSL "$COPYPARTY_SFX_URL" -o "$BIN"
  chmod 0755 "$BIN"
fi

# -----------------------------------------------------------------------------
# Runtime args file (upstream CLI arg syntax, one flag per line — verified on
# copyparty 1.20.24: -c files accept dash-style flags verbatim; colon-style
# "p:"/"v:" keys only work in ini-format sections like upstream's example.conf).
# The service reads this so secrets never sit in argv (ps-visible) and stays
# easy to edit by hand.
# -----------------------------------------------------------------------------
# Auth-only share perms: NO anonymous access at all — the volume grants
# r+w+m+d ONLY to the listed accounts (first = r/w/m/d owner; later ones
# read-only until you add them after another :rwmd, seg). "m" enables the
# UI's rename/move buttons, "d" enables the delete button; without "d" a
# copied-to-Pi folder cannot be removed from the UI (2026-10-07 report).
# Verified on 1.20.24/1.20.25: anon → 401.
VOL_LINE="-v $COPYPARTY_DIR::rwmd,$(echo "$COPYPARTY_ACCOUNTS" | cut -d',' -f1 | cut -d':' -f1)"

install -d -m 0750 /etc/copyparty
{
  echo "# Written by roles/copyparty/install.sh; passed to copyparty via -c."
  echo "# Shares + accounts. Bind IP is resolved at runtime by copyparty-start."
  echo "--usernames"
  echo "-p $COPYPARTY_PORT"
  echo "--js-browser /.res/mfu.js"
  echo "$VOL_LINE"
  printf '%s\n' "${ACC_ARGS[@]}"
} > /etc/copyparty/args
# The service runs as user copyparty and must read this file (it holds
# account creds): root-owned, group copyparty, 0640.
chown root:copyparty /etc/copyparty /etc/copyparty/args
chmod 0750 /etc/copyparty
chmod 0640 /etc/copyparty/args

# -----------------------------------------------------------------------------
# Start wrapper: waits for the tailscale0 interface to get its IPv4, then
# execs copyparty bound to ONLY that IP. Exec via /usr/bin/python3 so the
# sfx runs even without an exec-bit/shebang path.
# -----------------------------------------------------------------------------
install -m 0755 "$ASSETS/copyparty-start.sh" /usr/local/bin/copyparty-start
install -m 0755 "$ASSETS/copyparty-start-guard.sh" /usr/local/bin/copyparty-start-guard

# -----------------------------------------------------------------------------
# systemd unit (Type=notify like upstream contrib/systemd/copyparty.service;
# wrapped through copyparty-start which binds the Tailscale IP).
# -----------------------------------------------------------------------------
# Render the unit with the real share dir (template token __COPYPARTY_DIR__;
# sed-safe because COPYPARTY_DIR cannot contain | or & by role.env policy).
# Also render __CRYPT_ORDERING__ and __CRYPT_STATE__ based on COPYPARTY_CRYPT.
# Newline-in-sed is non-portable (BSD sed rejects it — proven in the idempotency
# harness), so the token line carries the WHOLE wants/after pair semicolon-
# separated, then a second sed splits it into two lines.
ORDERING_TOKEN=''
if [[ "$COPYPARTY_CRYPT" == "1" ]]; then
  ORDERING_TOKEN='Wants=crypt-unlock.service XX After=crypt-unlock.service'
fi
sed -e "s|__COPYPARTY_DIR__|$COPYPARTY_DIR|g" \
    -e "s|__CRYPT_STATE__|$COPYPARTY_CRYPT|g" \
    -e "s|__CRYPT_ORDERING__|$ORDERING_TOKEN|g" \
    "$ASSETS/copyparty.service" \
| sed -e 's| XX |\
|g' \
    > /etc/systemd/system/copyparty.service
chmod 0644 /etc/systemd/system/copyparty.service

systemctl daemon-reload
systemctl enable --now copyparty.service

log "copyparty.service enabled. It waits for the tailscale0 interface,"
log "resolves its IPv4, and binds ONLY to that IP on port $COPYPARTY_PORT."
log "TLS upgrade guide (one-time, done manually on the Pi): enable HTTPS"
log "at the tailnet level with your admin console URL, then:"
log "  sudo tailscale serve --bg 127.0.0.1:$COPYPARTY_PORT"
log "  curl -s https://<pi>.<tailnet>.ts.net/  -> 200 (auto LE cert)"
log "verify from a tailnet device: curl -s http://<pi-tailscale-hostname>:$COPYPARTY_PORT/?reset=/._"
log "on-Pi check: journalctl -u copyparty.service  or  ss -ltnp | grep :$COPYPARTY_PORT"