# RESUME — copyparty live + accounts real + rotation pusher (2026-10-08)

Last commit: a5a089a feat(copyparty): rotate-accounts.sh pusher + mfu.js asset
committed.

## State
- copyparty role LIVE on rpi-f96245 (192.168.0.106 / tailscale 100.67.183.33):
  auth-only, tailscale-only bind, gocryptfs at-rest under /var/lib/copyparty,
  https via tailscale serve, real-reboot-proofed.
- Accounts are REAL (placeholder `secure:realpassword` gone): al:fubar123 +
  backup:h4Nzl9Q03c3S1FWmF3zA, both `rwmd` (2026-10-07: delete+move granted —
  copied dirs were previously unremovable from the UI).
- Volume line: `-v /var/lib/copyparty::rwmd,al:rwmd,backup`; args backups:
  args.bak-20261007* on the Pi (pre-rotation plaintext — candidates for
  deletion once a rotation pass is done).
- Password rotation is scripted: `roles/copyparty/rotate-accounts.sh`
  (generate → apply → restart → verify logins → mirror .env → print once).
- Tailscale note: `accept-dns=false` on the Mac (2026-10-07) — MagicDNS off
  by design so ollama/cloud lanes keep DNS. Phone↔Pi connects direct over
  tailnet; Mac↔Pi from the office Wi-Fi stays DERP-only (TCP times out;
  use LAN SSH 192.168.0.106 from there).
- Evidence: .omo/evidence/copyparty-at-rest-crypto/ (T1-T6, F1-F4).

## Next human actions (user-side)
1. BACK UP the gocryptfs key (STILL OPEN): /boot/firmware/role/copyparty.crypt.key
   on the Pi + /tmp/opencode/.copyparty.crypt.key on this Mac are the only
   copies. Loss = share unrecoverable. This outranks everything below.
2. Run one real password rotation + store pairs in a password manager, then
   delete the stale args.bak-20261007* files on the Pi (they hold
   pre-rotation plaintext).
3. After UI verification: delete plaintext quarantines on the Pi:
   /var/lib/copyparty.pre-crypt-backup + /var/lib/copyparty.oldplaintext.
4. Optional: stage the fixed role tree to the card (diff-only cleanup; card
   already runs fixed artifacts from the live fixes).

## Parked (user decisions, not started)
- rclone crypt over WebDAV (option B) / LUKS (option D)
- USB hot-plug discovery (stays SSH-by-design)
