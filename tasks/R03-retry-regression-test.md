# R03 — §5k3 regression battery: bounded retry + hard-fail on apt failure

## Goal
Add a local `validate-local.sh` battery that reproduces (on macOS, mocked) the
exact first-boot failure — `apt-get` returns non-zero — and locks in the R01
contract: **retry N times, then hard-fail (non-zero)**. Also assert the R02
net-wait knob exists and defaults to on.

## Context
The suite's §5k2 stubs `apt-get` to **succeed** (it only tests the NTP gate).
Nothing tested "apt fails" — which is precisely the field failure. This
battery makes the failure path a permanent, CI-able artifact. It lives in
`validate-local.sh` because that is the repo's only runner (no CI, no
container harness; owner chose the local-suite route).

## Files touched
- `roles/travel-router/assets/validate-local.sh` — new section `(5k3)` after
  §5k2 (insert after the §5k2 block that ends near line 622, before
  `# --- (5l) provisioner gating asserts`).

## Pre-conditions
- [ ] R01 complete (retry helper + wiring exist).
- [ ] R02 complete (NET_WAIT_SEC knob exists).

## Exact changes required

### Change 1: `roles/travel-router/assets/validate-local.sh` — add §5k3
Insert this block after §5k2:

```bash
# --- (5k3) apt failure path: bounded retry then HARD-FAIL (R01) ---------------
# Reproduces the field failure: apt-get exits non-zero. Asserts the R01
# contract — retry the budget, then exit non-zero (never silently succeed).
sec "5k3. apt failure path: bounded retry, then hard-fail (R01)"

# (a) helper unit semantics: retry returns non-zero after the budget.
B3="$TMP/5k3bin"; mkdir -p "$B3"
cat > "$B3/always-fail" <<'SH'
#!/bin/bash
exit 100
SH
chmod +x "$B3/always-fail"
n_attempts=0
retry 3 0 "$B3/always-fail"; rc=$?
[[ "$rc" -ne 0 ]] && ok "5k3 retry returns non-zero after budget (rc=$rc)" \
                  || bad "5k3 retry masked a persistent failure (rc=$rc)"

# (b) helper success path: a step that fails twice then succeeds must return 0.
cat > "$B3/flaky.sh" <<'SH'
#!/bin/bash
c="${B3_COUNT:-/tmp/5k3-count.$$}"
n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" >"$c"
[ "$n" -ge 3 ]
SH
chmod +x "$B3/flaky.sh"
B3_COUNT="$TMP/5k3-count" rm -f "$TMP/5k3-count"
B3_COUNT="$TMP/5k3-count" retry 5 0 "$B3/flaky.sh"; rc=$?
[[ "$rc" -eq 0 ]] && ok "5k3 retry recovers a flaky step (rc=$rc)" \
                  || bad "5k3 retry failed to recover a flaky step (rc=$rc)"
[[ "$(cat "$TMP/5k3-count" 2>/dev/null)" == "3" ]] \
  && ok "5k3 retry attempted exactly 3 times before success" \
  || bad "5k3 retry attempt count=$(cat "$TMP/5k3-count" 2>/dev/null)"

# (c) base/install.sh under a FAILING apt must exit non-zero (hard-fail),
#     after the retry budget was actually spent (3 apt-update attempts).
B3B="$TMP/5k3base-apt"; mkdir -p "$B3B"
cat > "$B3B/timedatectl" <<'SH'
#!/bin/bash
echo "NTPSynchronized=yes"
SH
cat > "$B3B/apt-get" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/5k3-apt-calls"
exit 100
EOF
chmod +x "$B3B/timedatectl" "$B3B/apt-get"
rm -f "$TMP/5k3-apt-calls"
(cd /tmp && PATH="$B3B:$PATH" BASE_NTP_WAIT_SEC=2 NET_WAIT_SEC=0 \
  RETRY_ATTEMPTS=3 RETRY_MAX_SEC=0 \
  bash "$ROOT/roles/base/install.sh" >"$TMP/5k3-base.log" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "5k3 base hard-fails when apt keeps failing (rc=$rc)" \
                  || bad "5k3 base masked persistent apt failure (rc=$rc)"
calls=$(grep -c 'update' "$TMP/5k3-apt-calls" 2>/dev/null || echo 0)
[[ "$calls" -eq 3 ]] && ok "5k3 apt update retried 3x before giving up (calls=$calls)" \
                     || bad "5k3 apt update call count=$calls (expected 3)"

# (d) R02 knob: base references NET_WAIT_SEC (advisory net-wait present).
grep -q 'NET_WAIT_SEC' "$ROOT/roles/base/install.sh" \
  && ok "5k3 base has the R02 network-wait knob" \
  || bad "5k3 base is missing NET_WAIT_SEC (R02)"
```

### Change 2: helper availability in the suite
Ensure §5k3 can call `retry`. Directly after the `sec "5k3. ..."` line, add:

```bash
# shellcheck source=/dev/null
source "$ROOT/roles/base/assets/retry.sh"
```

(If the suite already sources helper assets elsewhere, reuse that instead.)

## Validation plan
```bash
bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -5
# Expected: SUITE GREEN; the 5k3 asserts appear and pass

bash roles/travel-router/assets/validate-local.sh 2>&1 | grep '^5k3'
# Expected: six 5k3 lines, all passing (no "bad")
```

## Success criteria
- [ ] §5k3 asserts: retry helper non-zero-after-budget; recovers flaky step;
      base hard-fails with failing apt; apt attempted exactly 3x; net-wait knob present.
- [ ] Whole suite green; no sleep inflation (RETRY_MAX_SEC=0, NET_WAIT_SEC=0).
- [ ] Reverting R01/R02 makes §5k3 fail loudly (the regression lock works).

## Rollback
```bash
git checkout roles/travel-router/assets/validate-local.sh
```

## Next task
R04
