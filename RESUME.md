# RESUME — travel-router-ap-stealth (witness run PAUSED — card in Mac, ext4 evidence needed pre-reflash)

<!--
SESSION 2026-09-22. Pi re-flashed and was online; T1 login PASSED. T2
(random rename) exposed a real deploy bug — install.sh never staged
hostapd.conf.tmpl where ap-apply looks for it — repo-fixed in faaff26
(suite 433/0). The retry apply restarted the radio and the AP did NOT
come back (outage #2, same signature as yesterday). POWERCYCLE DID NOT
RECOVER: after a full reboot neither travel-router nor a random SSID
broadcasts; hypothesis (c) wlan0-wedge is dead, rootfs state reproduces.
User pulled the card into the Mac (disk4: FAT bootfs mounted, ext4 rootfs
readable only via sudo debugfs — user chose paste-back over agent sudo).
Template was live-patched on the Pi by hand before the retry apply.
-->

## Current state

Plan `.omo/plans/travel-router-ap-stealth.md`: Todos 1+2 done (`a85bb1b`,
`b3f51ea`, `d71ff81`). Suite monotonic: **436 passed, 0 failed** (431 + 2
template-staging asserts + 3 root-cause asserts). Session commits:
`01984f5` (docs), `faaff26` (stage hostapd.conf.tmpl where ap-apply looks),
`a17bad5` (liveness poll reads the installed conf + is-active gate +
country fallback chain). ROOT CAUSE of outage #2 established by code audit
(see evidence file bottom section): broken liveness poll (dead since
b3f51ea — read $tmp after the mv renamed it away) + empty country_code
render from role.env lacking AP_COUNTRY -> daemon crash-loop, uncaught,
persists across reboots. All three defects fixed with failing-first tests.

Witness-run evidence: `.omo/evidence/travel-router-ap-stealth/
hostapd-probe-fix.txt` ("Witness run 2026-09-22" + "ROOT-CAUSE AUDIT"
sections).

T1 ✅ login 200 + 118-char token; /api/wan/status 200 (routed, WAN=Brook
wlan1, AP up, 2 clients).

T2 ⏸ repo work COMPLETE (both defects fixed + battery). Live half waits on
re-flash (below) then the rejoin.

## Next session steps (card in Mac — disk4, bootfs mounted)

1. OPTIONAL archaeology before re-flash (user paste-back, sudo debugfs —
   confirms which defect fired on-device; predictions in the evidence file):
   sudo /opt/homebrew/opt/e2fsprogs/sbin/debugfs -R "cat /etc/hostapd/hostapd-travel.conf" /dev/disk4s2
   sudo /opt/homebrew/opt/e2fsprogs/sbin/debugfs -R "ls -l /etc/hostapd" /dev/disk4s2
   (expect: ssid=<random 8-char>, country_code= EMPTY, no .bak)
2. Re-flash + provision as usual (HEAD now carries faaff26 + a17bad5).
   Wait ~2-5 min for role-setup; travel SSID `travel-router` should appear.
3. Mac joins travel-router (PSK Password123) → witness run from T2:
   T2 rename (ssid:"random", rejoin generated SSID) → T3 hidden:true +
   scan negative → T4 hidden:false + scan positive → T5 invalid-PSK apply
   → conf restored, radio not dropped → T6 finish evidence + tick plan
   checkbox 3 + final RESUME note.

## Standing rules (do not relearn)

- Mac on `192.168.0.x` = home LAN (Brook) → Pi unreachable; STOP and ask the
  user to switch to the travel SSID (192.168.50.x). Never poll.
- NEVER run hostapd against the live conf or a conf with `interface=wlan0`
  while hostapd-travel runs — use a dead-iface probe copy only.
- Login API needs `X-Requested-With: XMLHttpRequest` from curl.
- Pre-existing owner-call items (unchanged): provision.sh CR-strip hunk
  uncommitted; untracked scratch file tasks/5-session-auth.md.
- Suite gate: monotonic; now 433/0.