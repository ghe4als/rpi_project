#!/bin/bash
# role-setup-dump.sh — staged onto bootfs by both provisioners.
#
# Invoked from role-setup.service as an ExecStopPost. systemd exports
# SERVICE_RESULT into that environment; on anything other than "success" we
# mirror the role log + unit state onto the FAT bootfs so a failed first boot
# is diagnosable from macOS (the ext4 log is unreadable there). Best-effort:
# this must never affect the unit's own result.
[[ "${SERVICE_RESULT:-}" == "success" ]] && exit 0

OUT=/boot/firmware/role-setup-debug.log
[[ -d /boot/firmware ]] || OUT=/boot/role-setup-debug.log
{
  echo "=== role-setup.service status ==="
  systemctl status role-setup.service --no-pager 2>&1
  echo
  echo "=== /var/log/role-setup.log (tail 300) ==="
  tail -n 300 /var/log/role-setup.log 2>&1
} > "$OUT" 2>&1 || true
exit 0
