# WS05 — Docs close-out + suite docs-truth pins (final WS task)

## Goal
Make the role manual match the shipped WS features (env-driven security mode,
detection, ban on rotation) and pin the truths in the suite.

## Context
WS01–WS04 shipped code + their own batteries (§5as/§5at/§5au/§5av). WS05 is the
close-out: the README's security-mode section still says "edit the template",
which WS02 replaced with `TRAVELROUTER_AP_SECURITY`. This task updates the docs
and adds docs-truth pins so they cannot silently drift.

## Files touched
- `roles/travel-router/README.md` — security-mode rewrite + SAE buy-guide + rotation framing
- `roles/travel-router/assets/validate-local.sh` — §5aw docs-truth pins

## Pre-conditions
- [ ] WS04 committed (`4f926ce`); suite green at 699/0.

## Exact changes required

### Change 1: README — security-mode section
REPLACE the "If the radio supports SAE, the config change in
`hostapd.conf.tmpl` is: ..." paragraph + the manual `iw phy` block wording so
the procedure is: set `TRAVELROUTER_AP_SECURITY=wpa3-transition|wpa3` and
re-provision (install validates + fails loud). Keep the `iw phy` recipe as the
"how the gate decides" explanation, and keep the `wifi-capabilities` verb.

### Change 2: README — SAE-capable hardware buy-guide
ADD a short guide (Pi 4 onboard is the known-good AP radio):

| Hardware | AP radio | WPA2 | WPA3/PMF | Notes |
|---|---|---|---|---|
| Pi Zero W v1.1 | BCM43430A1 | yes | **no** | chip ceiling; detection-only |
| Pi 3B+ | BCM43455 (2.4 only) | yes | **no** | no SAE in the phy |
| **Pi 4** | BCM43455 (2.4+5) | yes | **yes** | SAE + CMAC; the WQ target |
| Pi 5 | (verify) | yes | probe first | run `wifi-capabilities` |

Rule: probe with `travel-wan wifi-capabilities` before committing hardware;
`"wpa3":true` is the only signal that matters.

### Change 3: README — rotation framing
ADD a short, blunt block in both the security-mode section and the detection
section: **SSID rotation is not a defense and never happens automatically** —
the attacker does not need the SSID, and rotation drops every client and the
admin session (self-DoS). It is a manual, human decision at most.

### Change 4: suite §5aw — docs-truth pins
- (a) README documents `TRAVELROUTER_AP_SECURITY` with all three modes.
- (b) README contains the "rotation is not a defense" phrase.
- (c) README references `travel-wan wifi-capabilities`.
- (d) `.env.example` carries `TRAVELROUTER_AP_SECURITY=` (already true; pin it).
- (e) the stale phrase "Re-provision after editing" is GONE from the README
  (the env-driven flow replaced it).

## Validation plan
    bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -5
    # Expected: SUITE GREEN, 0 failed

## Success criteria
- [ ] Suite green; §5aw passes.
- [ ] README no longer instructs template editing for the mode.
- [ ] Buy-guide + rotation framing present.
- [ ] `git diff` touches only the 2 files.

## Rollback
    git checkout roles/travel-router/README.md \
      roles/travel-router/assets/validate-local.sh

## Next task
WS wave code-complete. WQ hardware QA remains USER-GATED (Pi 4).
