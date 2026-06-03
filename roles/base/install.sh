#!/bin/bash
# Base role: common packages and tweaks. Sourced or exec'd by other roles.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

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

echo "[base] done"
