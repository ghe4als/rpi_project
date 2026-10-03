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
  [[ "$attempts" =~ ^[0-9]+$ ]] && [[ "$attempts" -ge 1 ]] || attempts=1
  [[ "$base" =~ ^[0-9]+$ ]] || base=5
  local n=1 rc=0 delay max="${RETRY_MAX_SEC:-60}"
  while :; do
    if "$@"; then
      return 0
    else
      # Capture the command's real status here; `$?` after the closed `if`
      # would be the compound's own (0) status and would mask the failure.
      rc=$?
    fi
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
