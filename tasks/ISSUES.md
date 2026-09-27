# Travel-Router Issues & Fixes

**Last updated**: 2026-09-27

## Security — HTTP Route Assessment (2026-09-27)

| # | Severity | Issue | Status |
|---|---|---|---|
| S1 | **Medium** | **Sensitive data on PIN-gated routes**: `/status` returns client list (MACs/IPs/hostnames), `/api/wan/known` reveals travel history, `/api/wan/scan` reveals RF environment — all accessible with just the guest PIN | TBD |
| S2 | **Medium** | **Admin page uses PIN for /status instead of session**: `admin.html:358` fetches `/status` with `X-Pin`, not `X-Session`. Inconsistent with the admin/session split | TBD |
| S3 | **Low** | **No public status endpoint**: `/` is a static warning page (security through obscurity). No unauthenticated endpoint for a minimal status page | TBD |
| S4 | **Info** | **/setup shell is unauthenticated**: The HTML loads without auth; only the API calls are PIN-gated. Should be session-gated if setup moves behind admin | TBD |

**TBD-001**: Create implementation plan for HTTP route restructure:
1. Add `GET /api/status` (no auth) → `{ap_ssid, wan_ssid, internet}`
2. Create minimal status page at `/` (no auth, with helpful links)
3. Move `/status` from PIN-gated to session-gated
4. Move `/api/wan/known` from PIN-gated to session-gated
5. Move all `/api/wan/*` POST verbs from PIN-gated to session-gated
6. Move `/setup` shell to session-gated
7. Update `admin.html` to use `X-Session` for `/status`
8. Update `validate-local.sh` for new auth posture
9. Decide: keep PIN for future use or remove
10. Decide: merge `/setup` into `/admin` or keep separate

**Open questions:**
- Minimal status page: static HTML or server-rendered?
- `/setup` merged into `/admin` or separate?
- PIN kept for future guest-facing functionality?
- Captive portal redirect target: `/setup` (admin-gated) or new minimal page?

---

## Code Quality — Role Review (2026-09-27)

| # | Severity | Issue | Status |
|---|---|---|---|
| C1 | **Low** | **Stale comment in validate-local.sh §5o**: "Seam TRAVELROUTER_PSK_FILE does not exist yet in travel-wan.sh" — but the seam IS defined at `travel-wan.sh:37`. Test is valid; comment is wrong | TBD |
| C2 | **Low** | **In-memory throttle resets on restart**: `_PIN_FAILS` is a dict in status-server.py. A restart clears all backoff state. Documented but worth noting for threat model | TBD |
| C3 | **Info** | **PSK-in-argv exposure window**: `API_WRITE_TIMEOUT=90s` means a PSK can be visible in `/proc/<pid>/cmdline` for up to 90s during connect. Accepted risk, but the window is non-trivial | Accepted |
| C4 | **Info** | **nftables flush every 30s**: `flush ruleset` + re-load could briefly drop established connections. The `ct state established,related accept` rules mitigate this, but it's a design tradeoff | Accepted |
| C5 | **Info** | **Large single-file sizes**: `status-server.py` (1564 lines) and `travel-wan.sh` (1438 lines) are large but cohesive. Splitting would add complexity without clear benefit for a Pi role | Accepted |

---

## Summary

| Category | Count | Actionable |
|---|---|---|
| Security (HTTP routes) | 4 | 4 (TBD-001) |
| Code quality | 5 | 2 (C1, C2) |
| Accepted risks | 3 | 0 (C3, C4, C5) |
| **Total** | **12** | **6** |

**Priority**: S1/S2 (medium security) → C1/C2 (low) → S3/S4 (info, part of TBD-001)
