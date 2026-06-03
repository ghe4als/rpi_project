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

if [[ -n "$ROLE" ]]; then
  "$REPO/provision.sh" "$ROLE" /Volumes/bootfs
else
  "$REPO/provision.sh" /Volumes/bootfs
fi
