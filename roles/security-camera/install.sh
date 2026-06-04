#!/bin/bash
# security-camera role: install and configure Motion for a USB UVC webcam.
# Assumes /dev/video0 on first boot; logs to /var/log/role-setup.log via the
# role-setup.service that invokes us.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ROLE_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$ROLE_DIR/assets"

# Run base role first (idempotent).
if [[ -x /boot/firmware/role/base/install.sh ]]; then
  bash /boot/firmware/role/base/install.sh
fi

echo "[security-camera] installing motion + v4l-utils from bundled .debs (offline)"
DEBS_DIR="$ASSETS/debs"
if [[ -d "$DEBS_DIR" ]] && compgen -G "$DEBS_DIR/*.deb" >/dev/null; then
  # dpkg -i in one shot; ignore mid-stream dep ordering errors, then resolve.
  dpkg -i "$DEBS_DIR"/*.deb 2>&1 | tail -20 || true
  # Use already-cached debs to satisfy any leftover deps without hitting network.
  apt-get install -fy --no-download 2>&1 | tail -10 || true
else
  echo "[security-camera] no bundled debs found, falling back to apt (needs network)"
  apt-get update -y
  apt-get install -y --no-install-recommends motion v4l-utils
fi

echo "[security-camera] writing /etc/motion/motion.conf"
install -m 0644 "$ASSETS/motion.conf" /etc/motion/motion.conf

echo "[security-camera] enabling motion daemon"
install -m 0644 "$ASSETS/motion.defaults" /etc/default/motion

echo "[security-camera] preparing recordings dir"
install -d -o motion -g motion -m 0755 /var/lib/motion

echo "[security-camera] preparing log dir (motion 4.5+ does not auto-create)"
install -d -o motion -g motion -m 0755 /var/log/motion

echo "[security-camera] allowing 'pi' to view motion's recordings"
usermod -a -G motion pi || true

systemctl daemon-reload
systemctl enable motion
systemctl restart motion

echo "[security-camera] done. Stream: http://<host>:8081  Web UI: http://<host>:8080"
