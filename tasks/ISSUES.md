# Travel-Router Issues & Fixes

**Last updated**: 2026-09-28 (S-wave complete: S01-S03 c6f45fe, S04
6af72e6, S05 76862a7, S06 1d9dd15)

## Security — HTTP Route Assessment (2026-09-27)

| # | Severity | Issue | Status |
|---|---|---|---|
| S1 | **Medium** | **Sensitive data on PIN-gated routes**: `/status` returns client list (MACs/IPs/hostnames), `/api/wan/known` reveals travel history, `/api/wan/scan` reveals RF environment — all accessible with just the guest PIN | ✅ RESOLVED c6f45fe (S01-S03: /api/status public minimal; /status + all /api/wan/* session-gated) |
| S2 | **Medium** | **Admin page uses PIN for /status instead of session**: `admin.html:358` fetches `/status` with `X-Pin`, not `X-Session`. Inconsistent with the admin/session split | ✅ RESOLVED c6f45fe (S02: statusFetch is sessionFetch) |
| S3 | **Low** | **No public status endpoint**: `/` is a static warning page (security through obscurity). No unauthenticated endpoint for a minimal status page | ✅ RESOLVED c6f45fe (S01: public /api/status + minimal page at /) |
| S4 | **Info** | **/setup shell is unauthenticated**: The HTML loads without auth; only the API calls are PIN-gated. Should be session-gated if setup moves behind admin | ✅ RESOLVED 6af72e6 (S04: merged into /admin, route removed → 404; S05 76862a7 retargeted the portal redirect to /) |
| S5 | Info | PIN fate after the restructure (S06): original task premise was FALSE (PIN live as admin-write second factor); corrected plan kept it and removed the dead GET-bucket gate | ✅ RESOLVED 1d9dd15 |

**TBD-001**: Create implementation plan for HTTP route restructure:
1. Add `GET /api/status` (no auth) → `{ap_ssid, wan_ssid, internet}` — DONE c6f45fe
2. Create minimal status page at `/` (no auth, with helpful links) — DONE c6f45fe
3. Move `/status` from PIN-gated to session-gated — DONE c6f45fe
4. Move `/api/wan/known` from PIN-gated to session-gated — DONE c6f45fe
5. Move all `/api/wan/*` POST verbs from PIN-gated to session-gated — DONE c6f45fe
6. Move `/setup` shell to session-gated — DONE 6af72e6 (merged; route 404)
7. Update `admin.html` to use `X-Session` for `/status` — DONE c6f45fe
8. Update `validate-local.sh` for new auth posture — DONE all commits
9. Decide: keep PIN for future use or remove — DONE 1d9dd15 (KEEP as
   admin-write second factor; dead GET gate removed)
10. Decide: merge `/setup` into `/admin` or keep separate — DONE 6af72e6 (merged)

**Open questions:** all resolved (see above).

---

## Code Quality — Role Review (2026-09-27)

| # | Severity | Issue | Status |
|---|---|---|---|
| C1 | **Low** | **Stale comment in validate-local.sh §5o**: "Seam TRAVELROUTER_PSK_FILE does not exist yet in travel-wan.sh" — but the seam IS defined at `travel-wan.sh:37`. Test is valid; comment is wrong | ✅ RESOLVED c6f45fe (comment corrected in the S03 suite rework) |
| C2 | **Low** | **In-memory throttle resets on restart**: `_PIN_FAILS` is a dict in status-server.py. A restart clears all backoff state. Documented but worth noting for threat model | KEPT open — in-memory throttle is a documented design tradeoff; revisit if field data shows restart abuse |
| C3 | **Info** | **PSK-in-argv exposure window**: `API_WRITE_TIMEOUT=90s` means a PSK can be visible in `/proc/<pid>/cmdline` for up to 90s during connect. Accepted risk, but the window is non-trivial | Accepted |
| C4 | **Info** | **nftables flush every 30s**: `flush ruleset` + re-load could briefly drop established connections. The `ct state established,related accept` rules mitigate this, but it's a design tradeoff | Accepted |
| C5 | **Info** | **Large single-file sizes**: `status-server.py` (1564 lines) and `travel-wan.sh` (1438 lines) are large but cohesive. Splitting would add complexity without clear benefit for a Pi role | Accepted |

---

## Summary

| Category | Count | Actionable |
|---|---|---|
| Security (HTTP routes) | 5 | 0 (all resolved) |
| Code quality | 5 | 0 resolved beyond C1; C2 kept open (documented tradeoff) |
| Accepted risks | 3 | 0 (C3, C4, C5) |
| **Total** | **12** | **closed this wave: S1-S5, C1** |

**Priority**: none outstanding from this review.
