#!/bin/bash
# Base role: common packages and tweaks. Sourced or exec'd by other roles.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ROLE_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$ROLE_DIR/assets"

# Wait for a sane clock before apt. Pi 3/Zero have no RTC, so on first boot the
# clock starts at the image build date (~1.5y in the past). apt then rejects
# repo metadata as "not valid yet" and fails. Block until NTP sync (or a
# plausibly-recent date) so apt accepts the signed Release files.
echo "[base] waiting for clock/NTP sync before apt"
for _ in $(seq 1 60); do
  if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
    break
  fi
  # Fallback sanity check: year >= 2025 means the clock is plausibly correct.
  [ "$(date +%Y)" -ge 2025 ] && break
  sleep 2
done
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

: "${NATS_URL:=nats://192.168.0.76:4222}"
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
