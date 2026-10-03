# R01 — Bounded retry for apt/network steps (hard-fail after budget)

## Goal
Wrap the first-boot `apt-get` calls in a bounded, backoff retry so a transient
network hiccup no longer aborts `role-setup`; a genuine persistent failure
still exits non-zero (unit stays enabled, retried on the next boot).

## Context
Trixie arm64 first boot aborted: `roles/base/install.sh` runs `apt-get update`
under `set -euo pipefail` with **no retry**. When the network was not stably
up, apt failed (exit 100) and the whole role aborted — `role-setup.service`
entered `failed`, the AP interface was never unmanaged/brought up. The same
gap exists in `roles/travel-router/install.sh` (two more apt calls). Upstream
Pi acknowledges the same class of bug and recommends retrying the package
update (RPi-Distro/rpi-cloud-init-mods#3). Owner decision: **bounded retry,
then hard-fail** — never silently exit 0 on a half-provisioned Pi.

## Files touched
- `roles/base/assets/retry.sh` — NEW sourceable `retry()` helper.
- `roles/base/install.sh` — source helper; retry-wrap both apt calls; install
  the helper to `/usr/local/lib/rpi/retry.sh` for other roles.
- `roles/travel-router/install.sh` — source helper (with fallbacks);
  retry-wrap both apt calls.

## Pre-conditions
- [ ] none (first task of the R wave)

## Exact changes required

### Change 1: NEW `roles/base/assets/retry.sh`
Create the file with this content:

```bash
#!/bin/bash
# retry.sh — sourceable bounded-retry helper for transient network steps.
#
# Usage: retry <attempts> <base_delay_sec> <cmd...>
#   Runs <cmd...>; on non-zero exit, sleeps with exponential backoff and
#   retries until <attempts> is reached, then returns the LAST exit status.
#   The caller (under `set -e`) therefore hard-fails only after the whole
#   budget is spent — never on a single transient hiccup.
#
# Env tunables:
#   RETRY_MAX_SEC   cap for a single backoff sleep (default 60; tests use 0)
# Behaviour is dependency-free (bash + sleep only).
retry() {
  local attempts="${1:-3}" base="${2:-5}"
  shift 2 || true
  [[ "$attempts" -ge 1 ]] 2>/dev/null || attempts=1
  [[ "$base" -ge 0 ]] 2>/dev/null || base=5
  local n=1 rc=0 delay max="${RETRY_MAX_SEC:-60}"
  while :; do
    if "$@"; then
      return 0
    fi
    rc=$?
    if [[ "$n" -ge "$attempts" ]]; then
      echo "[retry] giving up on '$*' after ${n} attempt(s) (rc=${rc})" >&2
      return "$rc"
    fi
    delay=$(( base << (n - 1) ))
    [[ "$delay" -gt "$max" ]] && delay="$max"
    echo "[retry] '$*' failed (rc=${rc}); attempt ${n}/${attempts}; retry in ${delay}s" >&2
    sleep "$delay"
    n=$(( n + 1 ))
  done
}
```

### Change 2: `roles/base/install.sh`
(a) Immediately after `ASSETS="$ROLE_DIR/assets"` (line 7), insert:

```bash
# Bounded-retry helper for transient network failures (see assets/retry.sh).
source "$ASSETS/retry.sh"
```

(b) Replace the apt block currently reading:

```bash
echo "[base] apt update"
apt-get update -y

echo "[base] installing common packages"
apt-get install -y --no-install-recommends \
  vim tmux curl ca-certificates htop rsync less \
  avahi-daemon
```

with:

```bash
echo "[base] apt update (bounded retry)"
retry "${RETRY_ATTEMPTS:-3}" "${RETRY_BASE_SEC:-5}" apt-get update -y

echo "[base] installing common packages (bounded retry)"
retry "${RETRY_ATTEMPTS:-3}" "${RETRY_BASE_SEC:-5}" \
  apt-get install -y --no-install-recommends \
  vim tmux curl ca-certificates htop rsync less \
  avahi-daemon

# Make the helper available to later roles (travel-router sources it).
install -d -m 0755 /usr/local/lib/rpi
install -m 0644 "$ASSETS/retry.sh" /usr/local/lib/rpi/retry.sh
```

### Change 3: `roles/travel-router/install.sh`
(a) Immediately after `ASSETS="$ROLE_DIR/assets"` (line 35), insert:

```bash
# Bounded-retry helper: prefer the copy base installed, fall back to the
# sibling base role's staged assets (base always runs first; see step (3)).
for _retry_lib in /usr/local/lib/rpi/retry.sh "$ROLE_DIR/../base/assets/retry.sh" \
                  /boot/firmware/role/base/assets/retry.sh /boot/role/base/assets/retry.sh; do
  [[ -f "$_retry_lib" ]] && { source "$_retry_lib"; break; }
done
```

(b) Replace the two apt calls (currently lines 184-185):

```bash
real_or_log apt-get update
real_or_log apt-get install -y --no-install-recommends hostapd dnsmasq nftables iw
```

with:

```bash
real_or_log retry "${RETRY_ATTEMPTS:-3}" "${RETRY_BASE_SEC:-5}" apt-get update
real_or_log retry "${RETRY_ATTEMPTS:-3}" "${RETRY_BASE_SEC:-5}" \
  apt-get install -y --no-install-recommends hostapd dnsmasq nftables iw
```

(DRY_RUN is unaffected: `real_or_log` logs and returns 0 without invoking
`retry`.)

## Validation plan
```bash
# 1. Suite must stay green (R03 later adds a dedicated §5k3 battery).
bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -3
# Expected: SUITE GREEN

# 2. Helper is syntactically clean if shellcheck is available.
command -v shellcheck >/dev/null && \
  shellcheck -x roles/base/assets/retry.sh roles/base/install.sh || true
# Expected: no new errors

# 3. Manual smoke (macOS, no network): 3 attempts then non-zero.
RETRY_MAX_SEC=0 bash -c 'set -euo pipefail; source roles/base/assets/retry.sh; retry 3 0 false'
# Expected: 3 "[retry] ... failed" lines; exit 1
```

## Success criteria
- [ ] base + travel-router apt calls are retry-wrapped; helper sourced.
- [ ] helper installed to `/usr/local/lib/rpi/retry.sh` by base.
- [ ] persistent failure still exits non-zero (hard-fail preserved).
- [ ] existing suite stays green.

## Rollback
```bash
git checkout roles/base/install.sh roles/travel-router/install.sh
rm -f roles/base/assets/retry.sh
```

## Next task
R02

## Execution note (2026-10-03)
Executed as specified, with one necessary correction to the drafted helper:
`rc=$?` was moved into an `else` branch. The plan's literal snippet captured
`$?` after the closed `if "$@"; then ...; fi`, which yields the compound's own
status (0) and would have masked every failure — violating R01's own
"hard-fail preserved" criterion. Also hardened the arg guards to
`[[ "$attempts" =~ ^[0-9]+$ ]]` (a non-numeric `$attempts` would otherwise make
`[[ "$attempts" -ge 1 ]]` error under `set -e`), and switched the travel-router
fallback to `if [[ -f ... ]]; then source ...; break; fi` (the `[[ ]] && {...}`
form is not `set -e`-exempt and would abort when the loop found no lib and
exited non-zero). Validation: `bash -n` clean ×3; manual smoke returns rc=1
after 3 attempts; suite GREEN 606/0. **Hardware-verified 2026-10-03:** the
owner re-flashed and the Pi came up fine with R01 in place.
