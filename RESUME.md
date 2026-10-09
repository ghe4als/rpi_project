# RESUME — travel-router webui restyle delivered (2026-10-08)

Last commit: a5a089a feat(copyparty): rotate-accounts.sh pusher + mfu.js asset
committed. NEW UNCOMMITTED WORK IN TREE (reviewed, user-accepted 2026-10-08):
- roles/travel-router/assets/admin.html — 80s retro CSS theme (purple/pink/cyan
  vars), saved-passwords -> .psktable rows, live try-progress ticker
  ("trying i of N…", clearProgress on dialog close). Contract battery 707/0.
- roles/travel-router/README.md — try-saved-passwords paragraph updated.
- Commit pending user request. Review verdict PASSED (5-lane review-work;
  one bug found+fixed in review: stale tick row on dialog close).

## Travel-router testing in progress
- User is running bandwidth tests against the Pi Zero W travel router.
  Context: Zero W is single-band 2.4 GHz 802.11n — through-NAT throughput is
  realistically ~20-40 Mbps; low numbers are the hardware ceiling, not a bug.

## Parked from previous workstream (copyparty, rpi-f96245)
- copyparty is LIVE (auth-only, tailscale-only, gocryptfs at-rest; accounts
  al + backup, both rwmd). Rotation scripted: roles/copyparty/rotate-accounts.sh.
- STILL OPEN (user-side): 1) BACK UP gocryptfs key — /boot/firmware/role/
  copyparty.crypt.key on the Pi + /tmp/opencode/.copyparty.crypt.key on the
  Mac are the ONLY copies; loss = share unrecoverable. Outranks everything.
  2) Run one real rotation + store pairs, then delete stale args.bak-20261007*
  (pre-rotation plaintext). 3) Delete /var/lib/copyparty.pre-crypt-backup +
  .oldplaintext after UI verification.
- Parked ideas: rclone crypt over WebDAV / LUKS; USB hot-plug discovery.
- Evidence: .omo/evidence/copyparty-at-rest-crypto/ (T1-T6, F1-F4).