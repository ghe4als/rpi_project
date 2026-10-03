# R02 — Wait for a usable network before the NTP/apt gate

## Goal
`roles/base/install.sh` waits (bounded, advisory) for a default route **and**
working DNS before it requires NTP sync and runs apt, so R01's retry budget is
spent against a live link instead of racing WiFi association.

## Context
`role-setup.service` starts at `multi-user.target`; even though it is ordered
after `network-online.target`, WiFi association + DHCP + DNS can still be
30-60s away (and `time-sync.target` is often already active, so it does not
actually wait for NTP). NTP cannot sync without a route, and apt cannot
resolve `deb.debian.org` without DNS — so the first attempts fail for reasons
no retry can fix until the link is up. This adds an advisory wait in front of
the existing NTP gate. It is advisory (warn, don't fail): the NTP hard gate
and R01's apt retry remain the real gates. `NET_WAIT_SEC=0` disables it (tests).

## Files touched
- `roles/base/install.sh` — new bounded net-wait block before the NTP gate.
- `roles/travel-router/assets/validate-local.sh` — §5k2 invocations gain
  `NET_WAIT_SEC=0` so the suite never sleeps.

## Pre-conditions
- [ ] R01 complete (R wave ordering; not strictly required by this change).

## Exact changes required

### Change 1: `roles/base/install.sh` — insert BEFORE the NTP block
Insert immediately before the line
`echo "[base] waiting for NTP sync before apt (bounded; fails if never syncs)"`:

```bash
# --- wait for a usable network path before NTP/apt --------------------------
# On first boot the unit starts at multi-user.target, but WiFi association +
# DHCP + DNS can still be tens of seconds away. NTP cannot sync without a
# route and apt cannot reach mirrors without DNS. Wait (bounded) for a default
# route AND working name resolution before the NTP gate below. Advisory only:
# on expiry we proceed — the NTP hard gate and apt's bounded retry (R01) are
# the hard gates, and the unit retries on the next boot. Tests set
# NET_WAIT_SEC=0 to skip entirely.
NET_WAIT_SEC="${NET_WAIT_SEC:-120}"
net_ready() {
  ip route show default 2>/dev/null | grep -q 'default' || return 1
  getent hosts deb.debian.org >/dev/null 2>&1 || return 1
  return 0
}
if [[ "${NET_WAIT_SEC}" -gt 0 ]]; then
  echo "[base] waiting up to ${NET_WAIT_SEC}s for a usable network (route + DNS)"
  _n=0
  while [[ "$_n" -lt "$NET_WAIT_SEC" ]]; do
    if net_ready; then echo "[base] network ready after ${_n}s"; break; fi
    sleep 3; _n=$(( _n + 3 ))
  done
  if ! net_ready; then
    echo "[base] WARNING: no usable network after ${NET_WAIT_SEC}s; continuing (NTP gate + apt retry remain the hard gates)"
  fi
fi
```

### Change 2: `roles/travel-router/assets/validate-local.sh` — §5k2 invocations
Both `bash "$ROOT/roles/base/install.sh"` calls in §5k2 (currently lines 609
and 620) must gain `NET_WAIT_SEC=0` in the env prefix, e.g.:

```bash
(cd /tmp && PATH="$B2B:$PATH" BASE_NTP_WAIT_SEC=2 NET_WAIT_SEC=0 bash "$ROOT/roles/base/install.sh" >"$TMP/5k2.log" 2>&1); rc=$?
```

Apply the same `NET_WAIT_SEC=0` to the positive-control invocation.

## Validation plan
```bash
# 1. Suite stays green and fast (no 120s net-wait).
time bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -3
# Expected: SUITE GREEN; wall time not inflated by a net-wait

# 2. NTP hard gate unchanged: still refuses with no NTP (NET_WAIT_SEC=0 path).
(cd /tmp && BASE_NTP_WAIT_SEC=2 NET_WAIT_SEC=0 bash roles/base/install.sh; echo "rc=$?")
# Expected: rc=1 (refuses), plus the NTP remediation message
```

## Success criteria
- [ ] base waits for route+DNS, bounded, advisory (never exits non-zero itself).
- [ ] `NET_WAIT_SEC=0` skips the wait; §5k2 stays green and does not sleep.
- [ ] the NTP hard gate behavior is unchanged.

## Rollback
```bash
git checkout roles/base/install.sh roles/travel-router/assets/validate-local.sh
```

## Next task
R03
