# Travel-Router HTTP Route Review & Security Assessment

**Date**: 2026-09-27
**Scope**: `status-server.py` (1564 lines), `setup.html` (843 lines), `admin.html` (1153 lines)
**Verdict**: Sensitive data is exposed on PIN-gated routes. The PIN is a guest credential but reveals client lists, known networks, and scan results. A minimal public status page is needed; everything else should move behind admin session auth.

---

## 1. Route Inventory

### 1.1 GET Routes

| Route | Current Auth | Data Returned | Sensitive? |
|---|---|---|---|
| `/` | None | Static warning page ("Private travel network") | No |
| `/health` | None | `{"status":"ok"}` | No |
| `/status` | PIN (X-Pin) | mode, lan_ip, wan_if, wan_ssid, wan_ip, internet, ap_state, clients_count, **clients_list** (MACs/IPs/hostnames), standalone | **YES** |
| `/setup` | None (shell) | HTML shell; all API calls PIN-gated | Shell safe; APIs expose sensitive data |
| `/admin` | None (shell) | HTML shell; all API calls session-gated | Shell safe |
| `/api/wan/known` | PIN (X-Pin) | Known network names, timestamps, autoconnect status | **YES** |
| `/api/wan/log` | Session | DHCP log (MACs/IPs/hostnames) | Yes — already session-gated |
| `/api/wan/psks-manage` | Session | PSK store metadata (type/index/ssid) | Yes — already session-gated |
| `/api/admin/audit` | Session | Auth failure attempts (ts/ip/kind/code) | Yes — already session-gated |
| `/api/admin/stealth` | Session | WAN stealth check result | No — already session-gated |
| `/api/admin/dns` | Session | Blocked domains + local-only state | Yes — already session-gated |
| `/api/admin/blocked` | Session | Blocked MAC list | Yes — already session-gated |
| `/api/admin/killswitch` | Session | Kill switch on/off | No — already session-gated |
| `/api/admin/sshlockdown` | Session | SSH lockdown on/off | No — already session-gated |
| `/api/admin/ap-info` | Session | Live AP SSID + hidden state | No — already session-gated |

### 1.2 POST Routes

| Route | Current Auth | Action | Sensitive? |
|---|---|---|---|
| `/api/auth/login` | None | Trades admin PSK for session token | No |
| `/api/wan/scan` | PIN (body.pin) | Returns ALL nearby WiFi networks (SSID/signal/security) | **YES** |
| `/api/wan/status` | PIN (body.pin) | Returns full status (same as GET /status) | **YES** |
| `/api/wan/connect` | PIN (body.pin) | Connects to WiFi network | **YES** (core UX) |
| `/api/wan/psks` | PIN (body.pin) | Tries saved passwords | **YES** (core UX) |
| `/api/wan/disconnect` | PIN (body.pin) | Disconnects WAN | No |
| `/api/wan/forget` | PIN (body.pin) | Forgets network | No |
| `/api/wan/recheck` | PIN (body.pin) | Triggers wan-select | No |
| `/api/wan/psks-manage` | Session + PIN | Manages saved passwords | Yes — already session-gated |
| `/api/wan/apconfig` | Session + PIN | Changes AP SSID/PSK/hidden | Yes — already session-gated |
| `/api/admin/killswitch` | Session + PIN | Toggles kill switch | No — already session-gated |
| `/api/admin/rotate-sessions` | Session + PIN | Rotates session salt | No — already session-gated |
| `/api/admin/sshlockdown` | Session + PIN | Toggles SSH lockdown | No — already session-gated |
| `/api/admin/dns` | Session + PIN | Edits DNS settings | Yes — already session-gated |
| `/api/admin/blocked` | Session + PIN | Blocks/unblocks MACs | Yes — already session-gated |
| `/api/admin/apconfig/preview` | Session + PIN | Previews random AP credentials | No — already session-gated |

---

## 2. The Core Problem

**The PIN is a guest credential.** It is meant to be shared with anyone who joins the travel AP (hotel roommates, family, friends). But the following sensitive data is accessible with just the PIN:

| Data | Route | Why It's Sensitive |
|---|---|---|
| **Client list** (MACs, IPs, hostnames) | `/status` | Other guests can see who's connected, their device names, and IPs |
| **Known networks** (SSID names) | `/api/wan/known` | Reveals every network the router has connected to (hotel names, home WiFi, etc.) |
| **WiFi scan results** | `/api/wan/scan` | Reveals all nearby networks with signal strength and security type |
| **WAN IP** | `/status` | The router's IP on the upstream network |
| **Full status** (mode, lan_ip, wan_if, internet) | `/status` | Complete device state |

### 2.1 What the Setup Page Exposes to PIN Holders

The `/setup` page (PIN-gated) currently provides:
- Status section: full `/status` data including **client list**
- Networks section: **scan results** + **connect/forget** functionality
- Known networks section: **known network names** + timestamps
- Connect manual section: SSID + PSK entry

### 2.2 What the Admin Page Exposes to Session Holders

The `/admin` page (session-gated) currently provides:
- Connected clients (from `/status` via X-Pin — **inconsistent**: uses PIN not session)
- Blocked devices (from `/api/admin/blocked`)
- Kill switch, DNS hardening, audit, sessions, SSH lockdown, stealth
- Saved passwords management
- AP settings (rename, change PSK, hide)

---

## 3. Inconsistencies Found

| # | Issue | Detail |
|---|---|---|
| 1 | **Admin page uses PIN for /status** | `admin.html:358` fetches `/status` with `X-Pin`, not `X-Session`. The admin already has a session — this should use session auth. |
| 2 | **/status is PIN-gated but returns client list** | The client list (MACs/IPs/hostnames) is the most sensitive data on the server, yet it's accessible with just the PIN. |
| 3 | **/api/wan/known is PIN-gated** | Known network names reveal travel history. Should be session-gated. |
| 4 | **/api/wan/scan is PIN-gated** | Scan results reveal the RF environment. Should be session-gated. |
| 5 | **/ is a static warning page** | The current `/` page is a "security through obscurity" measure. It should be replaced with a useful minimal status page. |
| 6 | **No public status endpoint** | There's no unauthenticated endpoint for the minimal status page to fetch from. |

---

## 4. Proposed Fix

### 4.1 New Minimal Status Page (No Auth)

Replace the current `/` warning page with a minimal status page:

**Content:**
- Travel AP SSID (e.g., "TravelNet")
- WAN SSID (e.g., "HotelWifi" or "standalone")
- Internet status (yes/no/unknown)
- Helpful links:
  - Cloudflare speed test: `https://speed.cloudflare.com`
  - DNS leak test: `https://www.dnsleaktest.com`
  - 1.1.1.1: `https://1.1.1.1`

**NOT included:**
- Client list
- WAN IP
- Known networks
- Scan results
- Any config/settings

**Implementation:**
- New endpoint: `GET /api/status` (no auth) → `{"ap_ssid": "...", "wan_ssid": "...", "internet": "..."}`
- New static HTML page at `/` that fetches from `/api/status`
- Preserve captive portal redirect (probe hosts → 302 to `/setup`)

### 4.2 Move /setup Behind Admin Auth

- `/setup` shell requires a valid session (401 without one)
- All `/api/wan/*` client verbs require a session:
  - `/api/wan/scan`, `/api/wan/status`, `/api/wan/connect`, `/api/wan/psks`
  - `/api/wan/disconnect`, `/api/wan/forget`, `/api/wan/recheck`
- `/api/wan/known` requires a session

### 4.3 Move /status Behind Admin Auth

- `/status` (GET) requires a session (not PIN)
- The admin page already has a session — use `X-Session` instead of `X-Pin`
- The minimal status page uses the new `/api/status` endpoint instead

### 4.4 Keep /admin As Is

- Already session-gated
- Update `/status` calls to use `X-Session` instead of `X-Pin`

### 4.5 PIN Becomes Unnecessary (For Now)

- The minimal status page needs no auth
- Everything else needs a session (admin PSK)
- The PIN can be kept for future guest-facing functionality or removed
- If kept, the PIN gate in `_pin_gate` can remain but won't be used by any route

---

## 5. Summary of Changes Needed

| File | Change |
|---|---|
| `status-server.py` | Add `GET /api/status` (no auth); move `/status` to session-gated; move `/api/wan/known` to session-gated; move all `/api/wan/*` POST verbs to session-gated; move `/setup` shell to session-gated |
| `setup.html` | Either remove (if /setup is merged into admin) or update to use session auth |
| `admin.html` | Update `/status` calls to use `X-Session` instead of `X-Pin` |
| New file | Minimal status page HTML (or render from status-server.py) |
| `validate-local.sh` | Update all PIN-gated route tests to session-gated; add tests for new `/api/status` endpoint |

---

## 6. TBD: Implementation Plan

**TBD-001**: Create implementation plan for the HTTP route restructure.

**Tasks:**
1. Add `GET /api/status` endpoint (no auth) returning `{ap_ssid, wan_ssid, internet}`
2. Create minimal status page HTML (no auth) at `/`
3. Move `/status` from PIN-gated to session-gated
4. Move `/api/wan/known` from PIN-gated to session-gated
5. Move all `/api/wan/*` POST verbs from PIN-gated to session-gated
6. Move `/setup` shell from unauthenticated to session-gated
7. Update `admin.html` to use `X-Session` for `/status` instead of `X-Pin`
8. Update `validate-local.sh` to test new auth posture
9. Decide: keep PIN for future use or remove entirely
10. Decide: merge `/setup` into `/admin` or keep as separate page

**Open questions:**
- Should the minimal status page be a static HTML file or rendered by the server?
- Should `/setup` be merged into `/admin` or kept as a separate page?
- Should the PIN be kept for future guest-facing functionality?
- Should the captive portal redirect go to `/setup` (now admin-gated) or to the new minimal status page?

---

## 7. Honest Assessment

**What's good:**
- The admin/session split is well-designed
- The CSRF protection (X-Requested-With) is solid
- The brute-force throttle is well-implemented
- The session token design (stateless HMAC + salt rotation) is sound
- The XSS prevention (textContent-only) is enforced by tests

**What's bad:**
- The PIN is a guest credential but exposes client lists, known networks, and scan results
- The admin page uses PIN for `/status` instead of session (inconsistent)
- The `/` page is a static warning page (security through obscurity)
- There's no public status endpoint for a minimal page

**Risk level**: Medium. The PIN is shared with guests, and guests can see:
- Who's connected (client list)
- Where the router has been (known networks)
- What networks are nearby (scan results)

This is information disclosure, not a direct exploit. But it's a privacy violation and could aid targeted attacks (e.g., knowing a specific device is connected).
