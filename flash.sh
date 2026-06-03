#!/bin/bash
# Full pipeline: flash a Raspberry Pi OS image to an SD card and provision it.
#
# Usage: ./flash.sh <image.img.xz> <disk>
#   e.g. ./flash.sh 2026-04-21-raspios-trixie-armhf-lite.img.xz /dev/disk4
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <image.img.xz> <disk e.g. /dev/disk4> [role]" >&2
  exit 2
fi

IMG="$1"; DISK="$2"; ROLE="${3:-}"
RDISK="${DISK/disk/rdisk}"

[[ -f "$IMG" ]] || { echo "Image not found: $IMG" >&2; exit 1; }
[[ "$DISK" =~ ^/dev/disk[0-9]+$ ]] || { echo "Disk must look like /dev/diskN" >&2; exit 1; }

echo "About to ERASE $DISK with $IMG"
diskutil list "$DISK"
read -r -p "Type the disk name to confirm (e.g. disk4): " CONFIRM
[[ "/dev/$CONFIRM" == "$DISK" ]] || { echo "Mismatch; aborting." >&2; exit 1; }

diskutil unmountDisk "$DISK"

echo "Writing image (this takes a few minutes)..."
xz -dc "$IMG" | sudo dd of="$RDISK" bs=4m status=progress
sync

echo "Waiting for bootfs to mount..."
for i in {1..30}; do
  [[ -d /Volumes/bootfs ]] && break
  sleep 1
done
[[ -d /Volumes/bootfs ]] || { echo "bootfs did not mount" >&2; exit 1; }

# Dispatch to the correct provisioner based on image filename.
# - Bookworm images use provision-bookworm.sh (firstrun.sh mechanism); stock
#   Bookworm has NO cloud-init, so provision.sh's user-data is silently ignored.
# - Trixie images use provision.sh (cloud-init path).
# - Unknown images default to provision-bookworm.sh (the currently-proven path)
#   with a loud warning telling the user to set PROVISION_SCRIPT explicitly.
# Override: PROVISION_SCRIPT=provision-bookworm.sh ./flash.sh ...
IMG_BASENAME_LC="$(basename "$IMG" | tr '[:upper:]' '[:lower:]')"
if [[ -n "${PROVISION_SCRIPT:-}" ]]; then
  PROVISIONER="$PROVISION_SCRIPT"
  echo "Using PROVISION_SCRIPT override: $PROVISIONER"
elif [[ "$IMG_BASENAME_LC" == *bookworm* ]]; then
  PROVISIONER="provision-bookworm.sh"
  echo "Detected Bookworm image -> $PROVISIONER"
elif [[ "$IMG_BASENAME_LC" == *trixie* ]]; then
  PROVISIONER="provision.sh"
  echo "Detected Trixie image -> $PROVISIONER"
else
  PROVISIONER="provision-bookworm.sh"
  echo "WARNING: cannot detect distro from image name '$(basename "$IMG")'." >&2
  echo "WARNING: defaulting to $PROVISIONER (the currently-stable Bookworm path)." >&2
  echo "WARNING: pass PROVISION_SCRIPT=provision.sh (or provision-bookworm.sh) to override." >&2
fi

[[ -x "$REPO/$PROVISIONER" ]] || { echo "Provisioner not found or not executable: $REPO/$PROVISIONER" >&2; exit 1; }

if [[ -n "$ROLE" ]]; then
  "$REPO/$PROVISIONER" "$ROLE" /Volumes/bootfs
else
  "$REPO/$PROVISIONER" /Volumes/bootfs
fi
