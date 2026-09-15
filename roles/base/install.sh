#!/bin/bash
# Base role: common packages and tweaks. Sourced or exec'd by other roles.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ROLE_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$ROLE_DIR/assets"

# Wait for a real NTP sync before apt. Pi 3/Zero have no RTC, so on first
# boot the clock starts at the image build date — possibly a WRONG-but-recent
# year (e.g. a build from Jun 2026 booted in Sep 2026), which a plain
# "year >= 2025" fallback would wrongly accept. apt then rejects repo metadata
# as "not valid yet" and fails. There is no trusted clock source without NTP,
# so require an actual NTPSynchronized=yes; if it never syncs (e.g. no NTP
# route at first boot), FAIL the unit rather than run apt on a wrong clock —
# a failed role-setup stays enabled and is retried on the next boot once NTP
# is reachable. The wait window is bounded by BASE_NTP_WAIT_SEC (default 120,
# settable by tests so a no-sync run doesn't sleep the full 2 minutes).
echo "[base] waiting for NTP sync before apt (bounded; fails if never syncs)"
wait_sec="${BASE_NTP_WAIT_SEC:-120}"
# ceil(wait_sec/2) iterations of a 2s sleep per pass
for _ in $(seq 1 $(((wait_sec + 1) / 2))); do
  if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
    echo "[base] NTP synchronized"
    break
  fi
  sleep 2
done
if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
  echo "[base] ERROR: NTP did not synchronize within the wait window; refusing to run apt on an unverified clock."
  echo "[base] remediation: ensure the network/upstream allows NTP (udp/123 to the configured servers), then reboot or re-run role-setup."
  exit 1
fi
echo "[base] clock now: $(date)"

echo "[base] apt update"
apt-get update -y

echo "[base] installing common packages"
apt-get install -y --no-install-recommends \
  vim tmux curl ca-certificates htop rsync less \
  avahi-daemon

ROLE_ENV="/boot/firmware/role/role.env"
[[ -f "$ROLE_ENV" ]] || ROLE_ENV="/boot/role/role.env"
if [[ -f "$ROLE_ENV" ]]; then
  echo "[base] loading $ROLE_ENV"
  set -a
  source "$ROLE_ENV"
  set +a
fi

: "${NATS_URL:=nats://192.168.0.151:4222}"
: "${NATS_SUBJECT_PREFIX:=rpi.nodes}"
: "${NATS_ANNOUNCE_ATTEMPTS:=20}"
: "${NATS_ANNOUNCE_RETRY_SEC:=3}"

if [[ -d "$ASSETS" ]]; then
  echo "[base] installing NATS node announcer"
  install -d -m 0755 /etc/rpi-project
  cat > /etc/rpi-project/nats-announce.env <<EOF
NATS_URL=$NATS_URL
NATS_SUBJECT_PREFIX=$NATS_SUBJECT_PREFIX
NATS_ANNOUNCE_ATTEMPTS=$NATS_ANNOUNCE_ATTEMPTS
NATS_ANNOUNCE_RETRY_SEC=$NATS_ANNOUNCE_RETRY_SEC
EOF
  chmod 0644 /etc/rpi-project/nats-announce.env

  install -m 0755 "$ASSETS/nats-announce.sh" /usr/local/bin/rpi-nats-announce
  install -m 0644 "$ASSETS/nats-announce.service" /etc/systemd/system/nats-announce.service
  systemctl daemon-reload
  systemctl enable nats-announce.service
  systemctl start --no-block nats-announce.service || true
fi

echo "[base] done"
