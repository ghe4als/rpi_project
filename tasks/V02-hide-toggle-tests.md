# V02 — Regression tests for the on-the-fly hide toggle

## Goal
Lock V01 into the suite: hidden-only apconfig reaches the tool correctly, the
session self-destruct fires on a hidden change (and NOT on a hidden no-op), and
the admin page carries the new button/dialog wiring.

## Context
No test currently exercises a hidden-only change (no ssid, no psk); §5ar(f)
covers PSK-only, SSID-only and failed applies but never hidden-only. The
server/tool already behave correctly, so these tests are a regression lock for
the contract V01 depends on, not a driver for new backend code.

## Files touched
- `roles/travel-router/assets/validate-local.sh` — extend §5an (API/tool) and
  §5ar(f) (session rotation) + admin.html static asserts.

## Pre-conditions
- [ ] V01 complete (new admin ids exist — the static asserts need them).

## Exact changes required

### Change 1: §5an — hidden-only through the API
In the §5an server battery (the `apconfig accepts random + hidden` block,
~lines 2850-2978), add after the existing (iii-4)/(iii-5) asserts. Reuse the
section's existing session+pin helpers and its `AP_LOG`/argv seam (mirror the
(iii-2) assert's capture idom). Add:

```bash
# (iii-7) hidden-only (no ssid, no psk) -> 200; tool argv slots 1/2 empty, slot3="2"
hid7=$(api_post_sess_apconfig "$hport" '{"pin":"1234","hidden":true}')
echo "$hid7" | grep -qF '"ok"' \
  && ok "5an(iii-7) hidden-only accepted (200)" || bad "5an(iii-7) hidden-only rejected: $hid7"
# argv captured by the section's ap-apply stub must read: ap-apply  "" "" "2"
grep -qF 'ap-apply|""|""|2' "$AP_ARGV_LOG" \
  && ok "5an(iii-7) hidden-only argv = ap-apply '' '' 2" \
  || bad "5an(iii-7) hidden-only argv wrong: $(tail -1 "$AP_ARGV_LOG" 2>/dev/null)"

# (iii-8) hidden-only show -> slot3="0"
hid8=$(api_post_sess_apconfig "$hport" '{"pin":"1234","hidden":false}')
echo "$hid8" | grep -qF '"ok"' \
  && ok "5an(iii-8) hidden-only show accepted (200)" || bad "5an(iii-8) rejected: $hid8"
grep -qF 'ap-apply|""|""|0' "$AP_ARGV_LOG" \
  && ok "5an(iii-8) hidden-only show argv = ap-apply '' '' 0" \
  || bad "5an(iii-8) argv wrong: $(tail -1 "$AP_ARGV_LOG" 2>/dev/null)"
```
Adapt the exact helper names / capture file to whatever §5an already uses (the
(iii-2) assert already inspects argv, so its seam exists). If §5an has no
session-carrying POST helper, use its established `api(...)`/curl idiom.

### Change 2: §5ar(f) — session rotation on hidden-toggle
In the §5ar(f) session-destruct block (~lines 3642-3688), add after the
PSK-only assert:

```bash
# hidden-only toggle where hidden != live -> salt rotates (session dies)
r_rot=$(api_post_sess_apconfig_rot "$hport" '{"pin":"1357","hidden":true}')
# pre-toggle token must now 401 (salt rotated)
code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Session: $PRE_TOKEN" \
  http://127.0.0.1:$hport/status 2>/dev/null)
[[ "$code" == "401" ]] && ok "5ar(f) hidden toggle rotates sessions (pre-token 401)" \
                       || bad "5ar(f) hidden toggle did NOT rotate (code=$code)"

# hidden-only NO-OP (hidden == live) -> salt unchanged
r_noop=$(api_post_sess_apconfig_rot "$hport" '{"pin":"1357","hidden":true}')
code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Session: $POST_TOKEN" \
  http://127.0.0.1:$hport/status 2>/dev/null)
[[ "$code" != "401" ]] && ok "5ar(f) hidden no-op does NOT rotate (post-token valid)" \
                       || bad "5ar(f) hidden no-op wrongly rotated (code=$code)"
```
Again, match §5ar(f)'s existing token-capture idiom (it already mints and
compares a token around a rename/psk change).

### Change 3: §5an(iv) — admin.html static wiring
In the §5an(iv) static block (~lines 2985-3000), add:

```bash
grep -qF 'id="ap-hidden-apply"' "$A/admin.html" \
  && ok "5an(iv) on-the-fly hide apply button present" || bad "5an(iv) hide apply button MISSING"
grep -qF 'id="ap-hide-confirm"' "$A/admin.html" \
  && ok "5an(iv) hide confirm dialog present" || bad "5an(iv) hide confirm dialog MISSING"
grep -qF 'doApSave({ pin: pin, hidden: desiredHidden })' "$A/admin.html" \
  && ok "5an(iv) hide toggle posts hidden-only {pin, hidden}" \
  || bad "5an(iv) hidden-only post MISSING"
```

## Validation plan
```bash
bash roles/travel-router/assets/validate-local.sh 2>&1 | grep -E '5an\(iii-[78]\)|5an\(iv\).*hide|5ar\(f\).*hidden'
# Expected: all new asserts PASS
bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -3
# Expected: SUITE GREEN
```

## Success criteria
- [ ] hidden-only → `ap-apply "" "" "2"` and `"" "" "0"` asserted.
- [ ] hidden toggle rotates sessions; hidden no-op does not.
- [ ] admin static wiring asserted.
- [ ] Suite green.

## Rollback
```bash
git checkout roles/travel-router/assets/validate-local.sh
```

## Next task
V03
