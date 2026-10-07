# RESUME — copyparty crypto wave COMPLETE

Last commit: df32196 feat(copyparty): Tailscale-only file server + gocryptfs
at-rest crypto + age sealing (17 files, incl. roles/tailscale/README.md).

## State
- copyparty role LIVE on rpi-f96245 (192.168.0.106 / tailscale 100.67.183.33):
  auth-only, tailscale-only bind, gocryptfs at-rest under /var/lib/copyparty,
  https via tailscale serve, real-reboot-proofed.
- Evidence: .omo/evidence/copyparty-at-rest-crypto/ (T1-T6, F1-F4).

## Next human actions (user-side)
1. BACK UP the gocryptfs key: /boot/firmware/role/copyparty.crypt.key on the Pi
   + /tmp/opencode/.copyparty.crypt.key on this Mac (only copies in existence).
2. Swap placeholder creds al:pw -> real (runbook: roles/copyparty/README.md
   "Credential rotation" §1) + mirror in .env COPYPARTY_ACCOUNTS.
3. After UI verification: delete plaintext quarantines on the Pi:
   /var/lib/copyparty.pre-crypt-backup + /var/lib/copyparty.oldplaintext.
4. Optional: stage the fixed role tree to the card (diff-only cleanup; card
   already runs fixed artifacts from the live fixes).

## Parked (user decisions, not started)
- rclone crypt over WebDAV (option B) / LUKS (option D)
- USB hot-plug discovery (stays SSH-by-design)
