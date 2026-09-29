#!/usr/bin/env python3
"""LAN status + session/PIN-gated API server for the travel-router.

Stdlib only (http.server + json). Serves:
  GET /            -> public minimal status page (S01; /api/status only)
  GET /status      -> session-gated JSON status (S02; shells out to
                      `travel-wan status --json`, reachability cached
                      in-process with a 30s TTL so an offline WAN does not
                      stall every page load)
  GET /health      -> 200 {"status":"ok"}
  GET /admin       -> admin page shell (session-gated APIs; S04 merged the
                       setup page into it — /setup is gone)
  GET /api/wan/known -> session-gated known-networks JSON (S03; travel-wan
                       known rows: NAME/TIMESTAMP/AUTOCONNECT metadata,
                       never a PSK)
  GET /api/wan/psks-manage -> session-gated metadata read (admin bucket)
  GET /api/wan/log -> session-gated DHCP log read (admin)
  GET /api/admin/audit -> session-gated auth-failure attempts (401/403/429
                      metadata rows: ts/ip/kind/code only, never a PSK/PIN;
                      also appended best-effort to a JSON-lines audit file)
  GET /api/admin/stealth -> session-gated read-only WAN stealth self-check
                      (travel-wan stealth-check pass-through; degraded run
                      answers 200 {"stealth":true,...}, never a 5xx)
  GET /api/admin/dns -> session-gated DNS hardening read (blocked-domains
                      rows + local-only presence)
  POST /api/admin/dns -> admin write {pin, action:add|del|set-local,
                      domain?, on?}: edits the wan-select-owned DNS stores,
                      then triggers ONE wan-select reload
  GET/POST /api/admin/blocked -> admin read (travel-wan blocked rows) /
                      write {pin, action:add|del, mac} (travel-wan
                      block/unblock verbs)
  POST /api/wan/*  -> client verbs session-gated, admin verbs
                       session+PIN (S03; admin writes carry body.pin as
                       the second factor — see below)
  Anything else (other path or method) -> 404.

POSTURE SPLIT (S03 re-grouped the H01/admin-split buckets): the /api/wan
surface has two buckets.
CLIENT (session-only — S03 moved every client verb/read off PIN):
  GET /api/wan/known + /api/wan/scan/status reads and the POST verbs
  /api/wan/{connect,psks,disconnect,forget,recheck} — X-Session is the
  credential; an X-Pin header is NEVER consulted (a stale X-Pin is
  inert, not rejected).
ADMIN (X-Session via PSK login, PLUS body.pin as the second factor on
writes): /api/wan/apconfig, /api/wan/psks-manage, every /api/admin/*
write. A wrong/absent PIN on an admin write is 403 "pin"/"pin_unset"
and feeds the shared per-IP _PIN_FAILS throttle (C1).
JSON-only bodies (8KB cap) + the X-Requested-With CSRF header still
guard every JSON POST; no CORS headers are ever emitted. SETUP_PIN
unset/empty -> every admin write 403s deny-by-default so
un-provisioned Pis never grant access.
PUT/PATCH/DELETE stay reject-bound (404).

HISTORY: H01 made the server writable (session + body.pin); the admin
split (Todo 1) grouped the gates; S01-S03 moved ALL client reads/writes
and /status to session-gated; S04 removed the /setup page (merged into
/admin); S05 retargeted the captive portal; S06 deleted the dead
GET-bucket PIN gate (this change) and left the PIN as the admin-write
second factor.

The server binds the IP in the wan-select state file so the bind never goes
stale; port comes from TRAVELROUTER_STATUS_PORT (default 80).
"""

import base64
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

STATE_PATH_ENV = "TRAVELROUTER_STATE_FILE"
DEFAULT_STATE_PATH = "/run/travel-router/state.json"
DEFAULT_HOST = "192.168.50.1"
TTL_SECONDS = 30.0
WAN_TOOL = os.environ.get("TRAVELWAN_BIN", "/usr/local/bin/travel-wan")
SETUP_PIN = os.environ.get("TRAVELROUTER_SETUP_PIN", "")
# Admin PSK gates /status + every /api surface (auth plan Todo 6). Empty ->
# deny-by-default, same posture as SETUP_PIN: /api/auth/login never issues a
# token, so no session can exist. Supplied at runtime via the tmpfs
# EnvironmentFile install.sh stages (same seam as the PIN).
ADMIN_PSK = os.environ.get("TRAVELROUTER_ADMIN_PSK", "")
SESSION_TTL_SECONDS = 43200  # 12h: one hotel-setup window, then re-login
_ASSET_DIR = os.path.dirname(os.path.abspath(__file__))
ADMIN_PAGE = os.path.join(_ASSET_DIR, "admin.html")
# Captive-portal hijack drop-in (wan-select owns + toggles it; H03). When it
# exists, OS connectivity-probe Hosts arriving here are 302'd to / (the
# public minimal status page; S05).
PORTAL_CONF = os.environ.get(
    "TRAVELROUTER_PORTAL_CONF", "/etc/dnsmasq.d/travel-router-portal.conf")
# Internet kill-switch flag (security plan todo 4). PRESENT = cut client->WAN
# forwarding; ABSENT = internet flows. A fresh flash has no file, so the
# default is always the ONLINE state — absence is the safe default, never
# inverted. 0600/root like every other store under this dir.
KILLSWITCH_FILE = os.environ.get(
    "TRAVELROUTER_KILLSWITCH_FILE",
    "/etc/rpi-project/travel-router/killswitch")
# SSH-lockdown flag (security plan todo 9). PRESENT = the render drops
# LAN-side tcp/22; ABSENT = the tcp { 53, 80, 22 } accept renders unchanged
# (a fresh flash has no file, so the default is unchanged). 0600/root like
# every other store under this dir.
SSHLOCKDOWN_FILE = os.environ.get(
    "TRAVELROUTER_SSHLOCKDOWN_FILE",
    "/etc/rpi-project/travel-router/ssh-lockdown")
# DNS hardening stores (security plan todo 6, wired by todo 11): both are
# wan-select-owned — the server only EDITS them (same atomic 0600 idiom as
# the flags above) and triggers the wan-select reload; wan-select renders the
# dnsmasq drop-ins on the next tick and restarts dnsmasq only when a
# drop-in's PRESENCE toggles (a list-content rewrite alone never restarts).
# BLOCKED: one hostname row per line (wan-select's regex); LOCAL: presence =
# local-only mode. Both default OFF/empty on a fresh flash.
BLOCKED_DOMAINS_FILE = os.environ.get(
    "TRAVELROUTER_BLOCKED_DOMAINS_FILE",
    "/etc/rpi-project/travel-router/blocked-domains")
DNS_LOCAL_FILE = os.environ.get(
    "TRAVELROUTER_DNS_LOCAL_FILE",
    "/etc/rpi-project/travel-router/dns-local")
# Session-salt file (security plan todo 7, force-relogin). Mixed into the
# session-token fingerprint; regenerated on the Pi at /run/travel-router/
# (tmpfs — a reboot re-salts and drops stale tokens for free). Rotating this
# file is what `POST /api/admin/rotate-sessions` does to log out every device.
SALT_FILE = os.environ.get(
    "TRAVELROUTER_SALT_FILE", "/run/travel-router/session-salt")
# Auth-failure audit log (security plan todo 8). JSON-lines, best-effort
# append per 401/403/429 auth rejection; /var/log/travel-router/*.log is
# bounded by the role's logrotate drop-in (no rotation logic here). The env
# seam lets the dev runner point at a fixture path.
AUDIT_FILE = os.environ.get(
    "TRAVELROUTER_AUDIT_FILE", "/var/log/travel-router/audit.log")
AUDIT_CAP = 200
_AUDIT_LOCK = threading.Lock()
_AUDIT_RING = deque(maxlen=AUDIT_CAP)

# HTTP-probe hosts whose DNS the H03 drop-in points at this server. Mirrors
# portal-dnsmasq.conf.tmpl (dns.msftncsi.com is a DNS-value probe, never here).
PROBE_HOSTS = frozenset((
    "captive.apple.com",
    "connectivitycheck.gstatic.com",
    "www.google.com",
    "www.msftncsi.com",
    "detectportal.firefox.com",
    "nmcheck.gnome.org",
))

# Write verbs WITHOUT a handler stay reject-bound (404). Only POST gained a
# real dispatcher (H01 posture change; see module docstring).
WRITE_VERBS = ("PUT", "PATCH", "DELETE")

# POST policy caps (Zero W, 512MB): small bodies, hard subprocess timeouts.
MAX_BODY_BYTES = 8192
WRITE_LOCK = threading.Lock()

# C1 PIN brute-force throttle: per-source-IP fail counter with exponential
# backoff, keyed ip -> [fail_count, blocked_until_ts]. In-memory only (resets
# on restart), dedicated lock so a blocked-IP check never queues behind an
# in-flight WRITE_LOCK subprocess write.
_PIN_THROTTLE_LOCK = threading.Lock()
_PIN_FAILS = {}


def _pin_backoff_tier(count):
    """Block seconds owed at the given consecutive-fail count: 5th fail -> 5s,
    25th -> 30s, 51st -> 120s. No permanent lockout (120s is the ceiling)."""
    if count >= 51:
        return 120.0
    if count >= 25:
        return 30.0
    if count >= 5:
        return 5.0
    return 0.0

API_SCAN_TIMEOUT = 25
API_WRITE_TIMEOUT = 90
API_QUICK_TIMEOUT = 30

# SSID policy: nmcli treats a leading dash as an option, control chars and
# over-long SSIDs are never legitimate 802.11 SSIDs (max 32 bytes).
SSID_MAX_BYTES = 32


def _audit_kind(path, method):
    """Audit bucket (security plan todo 8), derived mechanically from the
    request line only (never the body): login -> "login", other POST ->
    "write", everything else (GET reads) -> "read". A wrong PIN on a GET is
    still an auth attempt; the bucket is where it landed, not what it hoped
    to touch."""
    if method == "POST":
        return "login" if path == "/api/auth/login" else "write"
    return "read"


def _auth_audit(handler, kind, code):
    """Record one auth rejection (401/403/429) in the bounded in-memory ring
    and the bounded audit file. Observe-only: never alters the response, and
    a row carries ONLY {ts, ip, kind, code} — body content (PSKs/PINs) is
    structurally absent because this signature never accepts it. ts is ISO
    8601 UTC ("YYYY-MM-DDTHH:MM:SSZ", second resolution — attempts are
    security metadata, not a stopwatch). File append is best-effort: an
    unwritable file skips the write, never the request."""
    row = {"ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "ip": handler.client_address[0], "kind": kind, "code": code}
    with _AUDIT_LOCK:
        _AUDIT_RING.append(row)
    try:
        with open(AUDIT_FILE, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, separators=(",", ":")) + "\n")
    except OSError:
        pass


def _load_state_file():
    env_val = os.environ.get(STATE_PATH_ENV)
    return env_val if env_val else DEFAULT_STATE_PATH


def _json_field(text, key):
    """Pull one JSON string field by key (first match wins); returns None if
    absent. Cheap enough for the tiny state file; avoids a full parse that
    would trip on the malformed edge cases in some runners' state files."""
    if text is None:
        return None
    needle = '"%s"' % key
    pos = text.find(needle)
    if pos == -1:
        return None
    after = text[pos + len(needle):]
    i = 0
    while i < len(after) and after[i] in " \t\r\n":
        i += 1
    if i >= len(after) or after[i] != ":":
        return None
    i += 1
    while i < len(after) and after[i] in " \t\r\n":
        i += 1
    if i >= len(after) or after[i] != '"':
        return None
    i += 1
    out = []
    while i < len(after) and after[i] != '"':
        out.append(after[i])
        i += 1
    return "".join(out)


def _state_field(key):
    state_file = _load_state_file()
    try:
        with open(state_file, "r", encoding="utf-8") as fh:
            return _json_field(fh.read(), key)
    except OSError:
        return None


def _killswitch_on():
    """Kill switch state (security plan todo 4): the flag file PRESENT means
    cut internet (ON); ABSENT means internet flows (OFF). Absence is the
    safe default — a fresh flash must serve clients, never a locked-out
    router. Never inverted."""
    return os.path.exists(KILLSWITCH_FILE)


def _killswitch_write(on):
    """Set/clear the kill-switch flag. on=True -> write an empty flag file
    (0600); on=False -> remove it. Returns False only when the persist step
    itself failed (the toggle did not stick)."""
    if on:
        try:
            fd = os.open(KILLSWITCH_FILE,
                         os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.close(fd)
        except OSError:
            return False
    else:
        try:
            os.remove(KILLSWITCH_FILE)
        except FileNotFoundError:
            pass
        except OSError:
            return False
    return True


def _killswitch_reload():
    """Trigger the immediate re-render (+ `nft -f`) via wan-select, the same
    mechanism the block-list verbs use. Best-effort: True when the reload
    command returned 0; a failure still converges on the 30s timer tick.
    The seam is read per call so a fixture harness can point it at a stub
    without re-importing the module."""
    reload_cmd = os.environ.get("TRAVELROUTER_WAN_SELECT_RELOAD",
                                "sudo systemctl start wan-select.service")
    try:
        proc = subprocess.run(reload_cmd, shell=True, timeout=30,
                              capture_output=True, text=True)
    except (OSError, subprocess.SubprocessError):
        return False
    return proc.returncode == 0


def _sshlockdown_on():
    """SSH-lockdown state (security plan todo 9): the flag file PRESENT means
    the rendered firewall drops LAN-side tcp/22 (ON); ABSENT means the tcp
    { 53, 80, 22 } accept renders unchanged (OFF). Absence is the safe
    default — a fresh flash must keep the pre-lockdown management behavior.
    Never inverted."""
    return os.path.exists(SSHLOCKDOWN_FILE)


def _sshlockdown_write(on):
    """Set/clear the SSH-lockdown flag. on=True -> write an empty flag file
    (0600, same dir tmp + atomic replace); on=False -> remove it. Returns
    False only when the persist step itself failed (the toggle did not
    stick)."""
    if on:
        try:
            fd = os.open(SSHLOCKDOWN_FILE + ".tmp",
                         os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.close(fd)
            os.replace(SSHLOCKDOWN_FILE + ".tmp", SSHLOCKDOWN_FILE)
        except OSError:
            return False
    else:
        try:
            os.remove(SSHLOCKDOWN_FILE)
        except FileNotFoundError:
            pass
        except OSError:
            return False
    return True


# --- DNS hardening (security plan todo 6, wired by todo 11) ------------------
# wan-select owns the drop-in RENDER; the server only edits its two input
# stores (same tmp + os.replace idiom as _sshlockdown_write) and fires the
# shared wan-select reload. A list edit that keeps a drop-in PRESENT never
# restarts dnsmasq here — presence-toggle semantics live entirely in
# wan-select's apply_dns_dropin, which the reload re-runs.
# Hostname shape mirrors wan-select's blocked_domains_lines reader regex
# EXACTLY (rows failing it are skipped by the reader anyway, so a permissive
# writer would let rows silently vanish into a stderr note): label chars
# only, dot-separated with at least TWO labels (a bare single label like
# "localhost" is never a valid row here — the reader's `(\.…)+` requires
# one dot), each label starting/ending alphanumeric.
_DOMAIN_RE = re.compile(
    r"[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+")


def _domain_valid(domain):
    if not isinstance(domain, str) or not domain.strip():
        return False
    if len(domain) > 253 or any(ord(c) < 32 or ord(c) == 127 for c in domain):
        return False
    return _DOMAIN_RE.fullmatch(domain.strip().lower()) is not None


def _blocked_domains_rows():
    """Raw rows of the blocked-domains store (trimmed, blanks dropped). The
    shape check is deliberately NOT re-applied: wan-select's reader is the
    gatekeeper for what reaches dnsmasq, and this read is an admin-page
    echo of the file, not a re-validation."""
    try:
        with open(BLOCKED_DOMAINS_FILE, "r", encoding="utf-8",
                  errors="replace") as fh:
            return [r.strip() for r in fh.read().splitlines() if r.strip()]
    except OSError:
        return []


def _flag_store_write(path, on):
    """Set (empty 0600 file) or clear a presence flag, atomically. Shared by
    the dns-local store (todo 6) — killswitch/sshlockdown keep their own
    bodies because their write paths predate this helper."""
    if on:
        try:
            fd = os.open(path + ".tmp",
                         os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.close(fd)
            os.replace(path + ".tmp", path)
        except OSError:
            return False
    else:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        except OSError:
            return False
    return True


def _blocked_domains_write(rows):
    """Rewrite the blocked-domains store atomically (0600). An EMPTY list
    clears the file (wan-select renders no drop-in for an empty/missing
    store, so an emptied list turns the feature off). Returns False only on
    a persist failure."""
    try:
        os.makedirs(os.path.dirname(BLOCKED_DOMAINS_FILE), exist_ok=True)
        fd = os.open(BLOCKED_DOMAINS_FILE + ".tmp",
                     os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            for row in rows:
                fh.write(row + "\n")
        os.replace(BLOCKED_DOMAINS_FILE + ".tmp", BLOCKED_DOMAINS_FILE)
    except OSError:
        return False
    return True


def get_status():
    """Return the /status dict. Shells out to `travel-wan status --json`;
    falls back to a degraded dict if the tool is unavailable or its output is
    not JSON. Reachability check is cached in-process (30s TTL) so an offline
    WAN never stalls every page load."""
    global _cache_ok, _cache_when, _cache_result

    if _cache_ok and (time.time() - _cache_when) < TTL_SECONDS:
        return _cache_result

    state_mode = _state_field("mode") or "standalone"
    payload = {
        "mode": state_mode,
        "lan_ip": _state_field("lan_ip") or "",
        "internet": "unknown",
        "wan_if": "",
        "wan_ssid": "",
        "wan_ip": "",
        "standalone": state_mode != "routed",
    }
    try:
        out = subprocess.run(
            [WAN_TOOL, "status", "--json"],
            capture_output=True, text=True, timeout=20,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        out = ""

    if out:
        try:
            payload.update(json.loads(out))
        except ValueError:
            pass

    _cache_ok = True
    _cache_when = time.time()
    _cache_result = payload
    return payload


_cache_ok = False
_cache_when = 0.0
_cache_result = {}


# --- C3/C4 (auth plan Todo 6): stateless HMAC session -------------------------
# Token = base64url(payload_json).base64url(HMAC-SHA256). The payload carries
# {exp, psk_fingerprint}; the signing key is derived from ADMIN_PSK. No
# server-side store: the systemd unit restarts on Restart=always and on
# wan-select try-restart (lan_ip attach), and an in-memory map would drop every
# live session mid-hotel-setup. A signed token survives process restarts and
# rotates implicitly whenever the admin PSK changes. Logout = the client drops
# the token; expiry is enforced at verify time.
def _session_key():
    return hmac.new(b"tr-session-v1", ADMIN_PSK.encode("utf-8"),
                    hashlib.sha256).digest()


def _load_salt():
    """Session-salt bytes, RE-READ from disk on every call (review MAJOR on
    todo 7: a cache would let _session_ok accept tokens minted before a salt
    rotation — the whole invalidation point dies). Missing file -> generate a
    fresh 32-byte salt, write it 0600, and use it; on the Pi this fires on the
    first verify after each boot (tmpfs), so every boot re-salts naturally.
    Read failure with the file present falls back to a fixed prefix rather
    than crashing a verify."""
    try:
        with open(SALT_FILE, "rb") as fh:
            data = fh.read()
        if data:
            return data
    except OSError:
        pass
    salt = secrets.token_hex(32).encode("ascii")
    try:
        os.makedirs(os.path.dirname(SALT_FILE), exist_ok=True)
        fd = os.open(SALT_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, salt)
        os.close(fd)
    except FileExistsError:
        pass
    except OSError:
        pass
    return salt


def _psk_fingerprint():
    """16-hex session fingerprint. Format stays 16 hex (the token payload
    shape never changes); the salt is mixed in so rotating the salt file
    invalidates every outstanding token in _session_ok's fingerprint compare.
    Salt first: rotating the salt must change the digest while ADMIN_PSK is
    untouched (rotation is force-relogin, never a PSK change)."""
    return hashlib.sha256(_load_salt() + b"-" + ADMIN_PSK.encode("utf-8")
                          ).hexdigest()[:16]


def _rotate_session_salt():
    """Regenerate the salt file (security plan todo 7). Every outstanding
    token fails _session_ok's payload fingerprint compare at the NEXT verify —
    the outer HMAC key derives from ADMIN_PSK only, which this never touches.
    Atomic write (tmp + os.replace) so a verifier that reads mid-rotation
    never sees a torn salt. Returns False only when the persist step itself
    failed. Shared by the rotate-sessions endpoint (todo 7) and the apconfig
    self-destruct path (todo 10)."""
    fresh = secrets.token_hex(32).encode("ascii")
    try:
        fd = os.open(SALT_FILE + ".tmp", os.O_WRONLY | os.O_CREAT
                     | os.O_TRUNC, 0o600)
        os.write(fd, fresh)
        os.close(fd)
        os.replace(SALT_FILE + ".tmp", SALT_FILE)
    except OSError:
        return False
    return True


def _b64e(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _ap_info_now(handler):
    """LIVE AP identity probe via `travel-wan ap-info --json` (admin plan
    todo 4). Returns {"ap_ssid", "hidden"}; any failed/degraded tool run
    degrades to the empty state (""/False) — same semantics the GET route
    served inline before factoring (todo 10 needs the same pre-apply read)."""
    rc, out, err = handler._run_tool(["ap-info", "--json"], API_QUICK_TIMEOUT)
    info = {"ap_ssid": "", "hidden": False}
    if rc == 0 and out:
        try:
            parsed = json.loads(out[0])
            if (isinstance(parsed, dict)
                    and isinstance(parsed.get("ssid"), str)
                    and isinstance(parsed.get("hidden"), bool)):
                info = {"ap_ssid": parsed["ssid"],
                        "hidden": parsed["hidden"]}
        except ValueError:
            pass
    return info


def _b64d(text):
    pad = "=" * ((4 - len(text) % 4) % 4)
    return base64.urlsafe_b64decode(text + pad)


def _make_session_token():
    payload = json.dumps(
        {"exp": int(time.time()) + SESSION_TTL_SECONDS,
         "psk_fingerprint": _psk_fingerprint()},
        separators=(",", ":")).encode("utf-8")
    pb = _b64e(payload)
    return "%s.%s" % (pb, _b64e(hmac.new(_session_key(), pb.encode("ascii"),
                                         hashlib.sha256).digest()))


def _session_ok(token):
    if not ADMIN_PSK or not isinstance(token, str) or token.count(".") != 1:
        return False
    pb, sb = token.split(".", 1)
    try:
        sig = _b64d(sb)
        payload = json.loads(_b64d(pb).decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return False
    want = hmac.new(_session_key(), pb.encode("ascii"), hashlib.sha256).digest()
    if not hmac.compare_digest(sig, want):
        return False
    if not isinstance(payload, dict):
        return False
    exp = payload.get("exp")
    if isinstance(exp, bool) or not isinstance(exp, int) or exp < time.time():
        return False
    fp = payload.get("psk_fingerprint")
    if not isinstance(fp, str):
        return False
    # Constant-time compare: a token minted under a previous admin PSK fails
    # here even though its outer HMAC is already invalid; the digest match
    # keeps the response independent of which check rejected it.
    return hmac.compare_digest(fp, _psk_fingerprint())


def _require_session(handler):
    """True when the request carries a valid X-Session token; otherwise the
    401 has already been sent. Same body for missing/invalid/expired (no
    oracle). Connection: close so an unread body under keep-alive cannot be
    parsed as a smuggled follow-up request (mirrors the scan/status idiom)."""
    if _session_ok(handler.headers.get("X-Session")):
        return True
    _auth_audit(handler, _audit_kind(urlparse(handler.path).path,
                                     handler.command), 401)
    handler._send(401, json.dumps({"error": "auth"}), "application/json",
                  extra_headers=[("Connection", "close")])
    handler.close_connection = True
    return False


# C2 (auth plan Todo 5) → S01: the LAN-facing root page is the PUBLIC minimal
# status page. No auth; only the /api/status fields (ap_ssid/wan_ssid/
# internet). No client list, no WAN IP, no known networks.
_STATUS_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Travel Router Status</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui, sans-serif; margin: 0; padding: 1rem;
         background: #101418; color: #e8eaed; }
  main { max-width: 30rem; margin: 0 auto; }
  h1 { font-size: 1.25rem; }
  section { background: #1a2027; border-radius: 10px; padding: 0.9rem;
            margin-bottom: 0.9rem; }
  h2 { font-size: 1rem; margin: 0 0 0.5rem; }
  table { border-collapse: collapse; width: 100%; }
  td { padding: 2px 8px 2px 0; }
  .label { font-weight: 600; }
  .msg { min-height: 1.2em; font-size: 0.9rem; color: #9aa5b1; }
  .ok { color: #5dd879; }
  .warn { color: #ffb84d; }
  a { color: #2d7ff9; }
</style>
</head>
<body>
<main>
  <h1>Travel Router Status</h1>
  <section>
    <h2>Network</h2>
    <table><tbody id="status-rows"></tbody></table>
    <p class="msg" id="status-msg"></p>
  </section>
  <section>
    <h2>Helpful Links</h2>
    <ul id="links-list"></ul>
  </section>
</main>
<script>
"use strict";
// DOM built with createElement/textContent only (same rule as admin.html).

function cellRow(tbody, label, value) {
  var tr = document.createElement("tr");
  var l = document.createElement("td");
  l.className = "label";
  l.textContent = label;
  var v = document.createElement("td");
  v.textContent = value;
  tr.appendChild(l); tr.appendChild(v);
  tbody.appendChild(tr);
}

function refreshStatus() {
  fetch("/api/status", { cache: "no-store" })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      var tbody = document.getElementById("status-rows");
      while (tbody.firstChild) { tbody.removeChild(tbody.firstChild); }
      cellRow(tbody, "Network name (SSID)", d.ap_ssid || "?");
      cellRow(tbody, "Connected to", d.wan_ssid || "standalone");
      var msg = document.getElementById("status-msg");
      if (d.internet === "yes") {
        msg.textContent = "Internet: connected";
        msg.className = "msg ok";
      } else if (d.internet === "reachable") {
        msg.textContent = "Internet: connected (finish login if needed)";
        msg.className = "msg warn";
      } else {
        msg.textContent = "Internet: not connected";
        msg.className = "msg";
      }
    })
    .catch(function () {
      document.getElementById("status-msg").textContent = "status unavailable";
    });
}

function buildLinks() {
  var links = [
    ["Cloudflare Speed Test", "https://speed.cloudflare.com"],
    ["DNS Leak Test", "https://www.dnsleaktest.com"],
    ["1.1.1.1", "https://1.1.1.1"],
    ["Admin", "/admin"]
  ];
  var list = document.getElementById("links-list");
  links.forEach(function (pair) {
    var li = document.createElement("li");
    var a = document.createElement("a");
    a.href = pair[1];
    a.textContent = pair[0];
    li.appendChild(a);
    list.appendChild(li);
  });
}

buildLinks();
refreshStatus();
setInterval(refreshStatus, 10000);
</script>
</body>
</html>"""


class StatusHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body, ctype, extra_headers=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for h, v in (extra_headers or []):
            self.send_header(h, v)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("[status-server] %s - %s\n"
                         % (self.address_string(), fmt % args))

    def _reject_write(self):
        self._send(404, b"404 not found", "text/plain")

    def _serve_page(self, page_path, page_name):
        """Serve a static shell page (admin.html) with
        Cache-Control: no-store. The page must never be cached: WAN state and
        credential behavior change between captive-portal phases."""
        try:
            with open(page_path, "rb") as fh:
                body = fh.read()
        except OSError:
            sys.stderr.write("[status-server] %s page missing: %s\n"
                             % (page_name, page_path))
            msg = ("%s page missing on this install" % page_name).encode("ascii")
            self._send(500, msg, "text/plain")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _portal_redirect(self):
        """302 a connectivity-probe request to / (public minimal status page,
        S05). Target is the numeric LAN IP (captive webviews cannot rely on
        mDNS); the port is included whenever it is not 80, using the
        actually-bound port."""
        host = _state_field("lan_ip") or DEFAULT_HOST
        port = self.server.server_address[1]
        if port != 80:
            host = "%s:%d" % (host, port)
        self.send_response(302)
        self.send_header("Location", "http://%s/" % host)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def do_GET(self):
        probe_host = (self.headers.get("Host") or "").split(":")[0].strip().lower()
        if probe_host in PROBE_HOSTS and os.path.exists(PORTAL_CONF):
            self._portal_redirect()
            return
        path = urlparse(self.path).path
        if path == "/health":
            self._send(200, json.dumps({"status": "ok"}), "application/json")
        elif path == "/api/status":
            # Public minimal status — NO auth. Returns only non-sensitive
            # data: AP SSID, WAN SSID, internet status. No client list,
            # no WAN IP, no known networks, no scan results.
            wan_ssid = _state_field("wan_ssid") or ""
            ap_ssid = ""
            ap_ssid_file = "/etc/rpi-project/travel-router/ap-ssid"
            if os.path.isfile(ap_ssid_file):
                try:
                    with open(ap_ssid_file, "r") as fh:
                        ap_ssid = fh.read().strip()
                except OSError:
                    pass
            if not ap_ssid:
                ap_ssid = _state_field("ap_ssid") or ""
            internet = "unknown"
            try:
                full = get_status()
                internet = full.get("internet", "unknown")
            except Exception:
                pass
            self._send(200, json.dumps({
                "ap_ssid": ap_ssid,
                "wan_ssid": wan_ssid,
                "internet": internet,
            }), "application/json")
        elif path == "/status":
            # Full status (incl. client list) is ADMIN-ONLY — session required.
            # The public minimal status is GET /api/status (S01, no auth).
            if not _require_session(self):
                return
            self._send(200, json.dumps(get_status()), "application/json")
        elif path == "/api/wan/known":
            # Known networks reveal travel history — ADMIN-ONLY (S03).
            if not _require_session(self):
                return
            rc, out, err = self._run_tool(["known"], API_QUICK_TIMEOUT)
            if rc is None:
                self._send(504, json.dumps({"error": "timeout"}), "application/json")
                return
            known = []
            for line in out:
                parts = line.split("\t")
                if len(parts) == 3:
                    known.append({"name": parts[0], "timestamp": parts[1],
                                  "autoconnect": parts[2]})
            self._send(200, json.dumps({"known": known}), "application/json")
        elif path == "/api/wan/psks-manage":
            # Admin bucket: session-gated metadata read. The X-Session token
            # is also the CSRF gate (a cross-site form/fetch cannot set a
            # custom header without a preflight this server never answers).
            if not _require_session(self):
                return
            rc, out, err = self._run_tool(["psks-list"], API_QUICK_TIMEOUT)
            if rc is None:
                self._send(504, json.dumps({"error": "timeout"}), "application/json")
                return
            rows = []
            for i, line in enumerate(out, start=1):
                parts = line.split("\t")
                if len(parts) == 3:
                    rows.append({"type": parts[0], "index": i, "ssid": parts[1]})
            self._send(200, json.dumps({"rows": rows}), "application/json")
        elif path == "/api/wan/log":
            # Admin bucket — session-gated "recently connected" read: the
            # last ~50 non-empty lines of the bounded DHCP log (Todo 3). The
            # env seam lets the dev runner point at a fixture; absence of the
            # file degrades to an empty array, never a 5xx. DHCP rows are
            # MAC/IP/hostname metadata only (no PSKs) — the text is passed
            # through uninterpreted and json.dumps escapes it, so a hostile
            # lease hostname cannot break the response.
            if not _require_session(self):
                return
            log_path = os.environ.get("TRAVELROUTER_LOG_FILE",
                                      "/var/log/travel-router/dhcp.log")
            lines = []
            try:
                with open(log_path, "r", encoding="utf-8",
                          errors="replace") as fh:
                    lines = [l for l in fh.read().splitlines() if l.strip()][-50:]
            except OSError:
                lines = []
            self._send(200, json.dumps({"log": lines}), "application/json")
        elif path == "/api/admin/killswitch":
            # Admin bucket (security plan todo 4): session-gated read — the
            # kill-switch state is management-plane metadata a guest must
            # not learn (it reveals whether the box is being throttled).
            if not _require_session(self):
                return
            self._send(200, json.dumps({"on": _killswitch_on()}),
                       "application/json")
        elif path == "/api/admin/sshlockdown":
            # Admin bucket (security plan todo 9): session-gated read — the
            # lockdown state is management-plane metadata a guest must not
            # learn (same posture as the kill-switch state read).
            if not _require_session(self):
                return
            self._send(200, json.dumps({"on": _sshlockdown_on()}),
                       "application/json")
        elif path == "/api/admin/ap-info":
            # Admin bucket (admin plan todo 4): session-gated read-only probe
            # of the LIVE AP identity (current SSID + broadcast state) via
            # travel-wan ap-info. A failed/degraded tool run answers 200 with
            # an empty current state — the page preloads it, and a 5xx for a
            # cosmetic read would break the dialog for no security gain.
            if not _require_session(self):
                return
            self._send(200, json.dumps(_ap_info_now(self)),
                       "application/json")
        elif path == "/api/admin/audit":
            # Admin bucket (security plan todo 8): session-gated read of the
            # auth-failure ring, most recent first. Rows are ts/ip/kind/code
            # metadata only — PSKs and PINs never enter the ring. Absent file
            # degrades like /api/wan/log: empty list, never a 5xx.
            if not _require_session(self):
                return
            with _AUDIT_LOCK:
                attempts = list(reversed(_AUDIT_RING))
            self._send(200, json.dumps({"attempts": attempts}),
                       "application/json")
        elif path == "/api/admin/stealth":
            # Admin bucket (security plan todo 5, wired by todo 11): the
            # read-only self-check via `travel-wan stealth-check` (todo 5
            # verb). Pass-through; a failed/absent tool run degrades to the
            # stealth posture — never a 5xx for a cosmetic read (same
            # degrade posture as ap-info above).
            if not _require_session(self):
                return
            rc, out, err = self._run_tool(["stealth-check"], API_QUICK_TIMEOUT)
            stealth = {"stealth": True, "wan_if": "", "open_ports": []}
            if rc == 0 and out:
                try:
                    parsed = json.loads(out[0])
                    if (isinstance(parsed, dict)
                            and isinstance(parsed.get("stealth"), bool)
                            and isinstance(parsed.get("wan_if"), str)
                            and isinstance(parsed.get("open_ports"), list)):
                        stealth = parsed
                except ValueError:
                    pass
            self._send(200, json.dumps(stealth), "application/json")
        elif path == "/api/admin/dns":
            # Admin bucket (security plan todo 6, wired by todo 11):
            # session-gated read of the two hardening stores. Absent/empty
            # store -> empty list / False (default OFF on a fresh flash).
            if not _require_session(self):
                return
            self._send(200, json.dumps({
                "blocked_domains": _blocked_domains_rows(),
                "local_only": os.path.exists(DNS_LOCAL_FILE),
            }), "application/json")
        elif path == "/api/admin/blocked":
            # Admin bucket (security plan todo 3, wired by todo 11):
            # session-gated read of the block store via `travel-wan blocked`
            # (one normalized MAC per line; empty store -> empty list).
            if not _require_session(self):
                return
            rc, out, err = self._run_tool(["blocked"], API_QUICK_TIMEOUT)
            macs = []
            if rc == 0:
                macs = [m for m in out]
            self._send(200, json.dumps({"blocked": macs}),
                       "application/json")
        elif path == "/admin" or path == "/admin/":
# Admin page shell (admin plan Todo 2): unauthenticated to LOAD.
# Every data path is a session/PIN-gated API, so the HTML itself carries no
# device data. S04: /setup was merged into this page; the setup.html route is
# gone (404 below).
            self._serve_page(ADMIN_PAGE, "admin")
        elif path == "/" or path == "/index.html":
            # Public minimal status page (S01) — no auth. Shows AP SSID,
            # WAN SSID, internet status, and helpful links. No client list,
            # no WAN IP, no known networks.
            self._send(200, _STATUS_HTML, "text/html",
                       extra_headers=[("Cache-Control", "no-store")])
        else:
            self._send(404, b"404 not found", "text/plain")

    # --- POST API (H01) --------------------------------------------------------

    def _read_json_body(self):
        """Return (dict, None) or (None, error_code). Enforces the body cap
        and Content-Type; returns None dict only on policy failures."""
        length_hdr = self.headers.get("Content-Length")
        if not length_hdr:
            return None, 411
        try:
            length = int(length_hdr)
        except ValueError:
            return None, 400
        if length <= 0 or length > MAX_BODY_BYTES:
            return None, 413
        ctype = self.headers.get("Content-Type", "")
        if ctype.split(";")[0].strip() != "application/json":
            return None, 415
        if self.headers.get("X-Requested-With") != "XMLHttpRequest":
            # Custom header: a cross-site form/fetch cannot set it without a
            # CORS preflight, and this server never answers preflight. Auth-
            # surface rejection (todo 8) — audited here at the single choke
            # point; body-shape errors below stay unlogged (not auth).
            _auth_audit(self, _audit_kind(urlparse(self.path).path,
                                          self.command), 403)
            return None, 403
        body = self.rfile.read(length)
        try:
            parsed = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None, 400
        if not isinstance(parsed, dict):
            return None, 400
        return parsed, None

    @staticmethod
    def _ssid_valid(ssid):
        if not isinstance(ssid, str) or not ssid.strip() or ssid.startswith("-"):
            return False
        if any(ord(c) < 32 or ord(c) == 127 for c in ssid):
            return False
        return len(ssid.encode("utf-8")) <= SSID_MAX_BYTES

    @staticmethod
    def _random_ap_ssid():
        # 8 chars over the no-lookalike alphabet (no I/L/O/0/1), secrets.choice
        # so the name is unpredictable; no separators so it sorts as noise.
        return "".join(secrets.choice("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
                       for _ in range(8))

    @staticmethod
    def _random_ap_psk():
        # 12 chars over [A-Za-z0-9._-] (the apconfig validator's accepted
        # set, len 8-63) so a previewed PSK saves as-is; deliberately NOT the
        # no-lookalike SSID alphabet.
        return "".join(secrets.choice(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
            for _ in range(12))

    @staticmethod
    def _pin_ok(body):
        if not SETUP_PIN:
            return False
        supplied = body.get("pin")
        if not isinstance(supplied, str):
            return False
        return hmac.compare_digest(supplied, SETUP_PIN)

    def _run_tool(self, args, timeout):
        """Shells out to travel-wan in list form (never a shell). Returns
        (rc, out_lines, err_lines). NEVER puts a PSK into a log line."""
        try:
            proc = subprocess.run(
                [WAN_TOOL] + args, capture_output=True, text=True, timeout=timeout,
            )
        except (OSError, subprocess.SubprocessError):
            return None, [], ["travel-wan invocation failed"]
        out = [l for l in (proc.stdout or "").splitlines() if l.strip()]
        err = [l for l in (proc.stderr or "").splitlines() if l.strip()]
        return proc.returncode, out, err

    def _api_response(self, rc, out, err, http_ok=200, extra_headers=None):
        """Standard envelope. PSKs never pass through here (travel-wan never
        echoes them; stderr from our own wrappers carries no PSK either)."""
        if rc is None:
            self._send(504, json.dumps({"error": "timeout"}), "application/json",
                       extra_headers=extra_headers)
            return
        self._send(200, json.dumps({"ok": rc == 0, "rc": rc, "lines": out, "log": err}),
                   "application/json", extra_headers=extra_headers)

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/auth/login":
            # Trades the admin PSK for a stateless session token. A PSK guess
            # is exactly as valuable as a PIN guess, so attempts feed the SAME
            # per-IP _PIN_FAILS counter/backoff instead of becoming a second,
            # unlimited oracle. A blocked attempt still advances the count and
            # answers 429 before the body is parsed (mirrors the write throttle).
            ip_key = self.client_address[0]
            now = time.time()
            with _PIN_THROTTLE_LOCK:
                entry = _PIN_FAILS.get(ip_key)
                blocked_until = entry[1] if entry else 0.0
                if now < blocked_until:
                    entry[0] += 1
                    pin_fails = entry[0]
                else:
                    pin_fails = None
            if pin_fails is not None:
                _auth_audit(self, "login", 429)
                self._send(429, json.dumps({"error": "rate_limited"}),
                           "application/json",
                           extra_headers=[("Connection", "close")])
                self.close_connection = True
                return
            body, err_code = self._read_json_body()
            if err_code is not None:
                # Malformed/absent body degrades to 401, not a parser-error
                # oracle: a login attempt without a parseable psk is simply a
                # failed login. Not counted as a guess (no PSK was compared).
                # NOT audited here: body-shape codes (411/400/413/415) are not
                # auth rejections, and the CSRF 403 was already audited at the
                # _read_json_body choke point — logging again would double-row
                # one rejection.
                self._send(401, json.dumps({"error": "auth"}),
                           "application/json",
                           extra_headers=[("Connection", "close")])
                self.close_connection = True
                return
            supplied = body.get("psk")
            if not ADMIN_PSK or not isinstance(supplied, str) \
                    or not hmac.compare_digest(supplied, ADMIN_PSK):
                with _PIN_THROTTLE_LOCK:
                    entry = _PIN_FAILS.setdefault(ip_key, [0, 0.0])
                    entry[0] += 1
                    tier = _pin_backoff_tier(entry[0])
                    if tier:
                        entry[1] = time.time() + tier
                _auth_audit(self, "login", 401)
                self._send(401, json.dumps({"error": "auth"}),
                           "application/json",
                           extra_headers=[("Connection", "close")])
                self.close_connection = True
                return
            with _PIN_THROTTLE_LOCK:
                _PIN_FAILS.pop(ip_key, None)
            self._send(200, json.dumps({"token": _make_session_token()}),
                       "application/json")
            return
        if path == "/api/wan/scan" or path == "/api/wan/status":
            # Scan results + full status are ADMIN-ONLY (S03) — session required.
            if not _require_session(self):
                return
            if path == "/api/wan/status":
                self._send(200, json.dumps(get_status()), "application/json",
                           extra_headers=[("Connection", "close")])
                self.close_connection = True
                return
            rc, out, err = self._run_tool(["scan"], API_SCAN_TIMEOUT)
            self._api_response(rc, out, err, extra_headers=[("Connection", "close")])
            self.close_connection = True
            return
        if not (path == "/api/wan/connect" or path == "/api/wan/psks"
                or path == "/api/wan/psks-manage"
                or path == "/api/wan/apconfig"
                or path == "/api/wan/disconnect"
                or path == "/api/wan/forget" or path == "/api/wan/recheck"
                or path == "/api/admin/killswitch"
                or path == "/api/admin/rotate-sessions"
                or path == "/api/admin/sshlockdown"
                or path == "/api/admin/dns"
                or path == "/api/admin/blocked"
                or path == "/api/admin/apconfig/preview"):
            self._send(404, b"404 not found", "text/plain")
            return
        # C1 PIN throttle: a blocked source gets 429 BEFORE the body is even
        # parsed. A blocked attempt is still a PIN guess, so it also advances
        # the fail count (lets a persistent brute-forcer escalate tiers).
        # S03: EVERY write verb below is session-gated; the admin_write set
        # ADDITIONALLY requires body.pin (second factor). The shared per-IP
        # counter/backoff fires a 429 before the body is parsed for both paths.
        admin_write = path in ("/api/wan/psks-manage", "/api/wan/apconfig",
                               "/api/admin/killswitch",
                               "/api/admin/rotate-sessions",
                               "/api/admin/sshlockdown",
                               "/api/admin/dns",
                               "/api/admin/blocked",
                               "/api/admin/apconfig/preview")
        ip_key = self.client_address[0]
        now = time.time()
        with _PIN_THROTTLE_LOCK:
            entry = _PIN_FAILS.get(ip_key)
            blocked_until = entry[1] if entry else 0.0
            if now < blocked_until:
                entry[0] += 1
                pin_fails = entry[0]
            else:
                pin_fails = None
        if pin_fails is not None:
            # 429 fires before the body is read; like the scan/status
            # branches, an unread body under keep-alive would be parsed as
            # the next (smuggled) request. Close the connection instead.
            _auth_audit(self, _audit_kind(path, "POST"), 429)
            self._send(429, json.dumps({"error": "rate_limited"}),
                       "application/json", extra_headers=[("Connection", "close")])
            self.close_connection = True
            return
        body, err_code = self._read_json_body()
        if err_code is not None:
            self._send(err_code, json.dumps({"error": _code_msg(err_code)}),
                       "application/json")
            return
        # All write verbs are ADMIN-ONLY (S03) — session required.
        # Client verbs: /api/wan/{connect,psks,disconnect,forget,recheck}
        # Admin verbs: /api/wan/{psks-manage,apconfig}, /api/admin/*
        session_authed = getattr(self, "_session_authed", None)
        if session_authed is None:
            session_authed = _session_ok(self.headers.get("X-Session"))
            self._session_authed = session_authed
        if not session_authed:
            _auth_audit(self, _audit_kind(path, "POST"), 401)
            self._send(401, json.dumps({"error": "auth"}),
                       "application/json",
                       extra_headers=[("Connection", "close")])
            self.close_connection = True
            return
        if admin_write and not self._pin_ok(body):
            with _PIN_THROTTLE_LOCK:
                entry = _PIN_FAILS.setdefault(ip_key, [0, 0.0])
                entry[0] += 1
                tier = _pin_backoff_tier(entry[0])
                if tier:
                    entry[1] = time.time() + tier
            _auth_audit(self, _audit_kind(path, "POST"), 403)
            err_key = "pin" if SETUP_PIN else "pin_unset"
            self._send(403, json.dumps({"error": err_key}), "application/json")
            return
        with _PIN_THROTTLE_LOCK:
            _PIN_FAILS.pop(ip_key, None)
        if path == "/api/admin/apconfig/preview":
            # Mints credentials but touches NOTHING: no travel-wan call, no
            # WRITE_LOCK, no file. The response body is the only channel —
            # the generated PSK is never logged anywhere.
            self._send(200, json.dumps({"ssid": self._random_ap_ssid(),
                                        "psk": self._random_ap_psk()}),
                       "application/json")
            return
        with WRITE_LOCK:
            if path == "/api/wan/connect":
                ssid = body.get("ssid")
                if not self._ssid_valid(ssid):
                    self._send(400, json.dumps({"error": "ssid"}), "application/json")
                    return
                psk = body.get("psk")
                args = ["connect", ssid] + ([psk] if isinstance(psk, str) and psk else [])
                rc, out, err = self._run_tool(args, API_WRITE_TIMEOUT)
            elif path == "/api/wan/psks":
                ssid = body.get("ssid")
                if not self._ssid_valid(ssid):
                    self._send(400, json.dumps({"error": "ssid"}), "application/json")
                    return
                rc, out, err = self._run_tool(["try-psks", ssid], API_WRITE_TIMEOUT)
            elif path == "/api/wan/psks-manage":
                action = body.get("action")
                if action == "add":
                    ssid = body.get("ssid")
                    psk = body.get("psk")
                    if not self._ssid_valid(ssid) or not isinstance(psk, str) or not psk.strip():
                        self._send(400, json.dumps({"error": "psks-manage"}), "application/json")
                        return
                    rc, out, err = self._run_tool(["psks-add", ssid, psk], API_WRITE_TIMEOUT)
                elif action == "add-default":
                    psk = body.get("psk")
                    if not isinstance(psk, str) or not psk.strip():
                        self._send(400, json.dumps({"error": "psks-manage"}), "application/json")
                        return
                    rc, out, err = self._run_tool(["psks-add-default", psk], API_WRITE_TIMEOUT)
                elif action == "del":
                    n = body.get("n")
                    if not isinstance(n, int) or isinstance(n, bool) or n < 1:
                        self._send(400, json.dumps({"error": "psks-manage"}), "application/json")
                        return
                    rc, out, err = self._run_tool(["psks-del", str(n)], API_WRITE_TIMEOUT)
                else:
                    self._send(400, json.dumps({"error": "psks-manage"}), "application/json")
                    return
            elif path == "/api/wan/apconfig":
                ssid = body.get("ssid")
                psk = body.get("psk")
                hidden = body.get("hidden")
                if ssid is None and psk is None and hidden is None:
                    self._send(400, json.dumps({"error": "apconfig"}), "application/json")
                    return
                if hidden is not None and not isinstance(hidden, bool):
                    self._send(400, json.dumps({"error": "apconfig"}), "application/json")
                    return
                # Reserved word "random": the server generates the name so the
                # client never invents one. Anything else (including a literal
                # trailing space, e.g. "random ") falls through to the normal
                # SSID validation below untouched.
                generated_ssid = None
                if ssid == "random":
                    generated_ssid = self._random_ap_ssid()
                    ssid = generated_ssid
                if ssid is not None:
                    if not self._ssid_valid(ssid) or len(ssid) > 32 \
                            or not all(c.isprintable() and c not in '|\\$&' for c in ssid):
                        self._send(400, json.dumps({"error": "apconfig"}), "application/json")
                        return
                if psk is not None:
                    if not isinstance(psk, str) or not (8 <= len(psk) <= 63) \
                            or not all(c.isalnum() or c in '._-' for c in psk):
                        self._send(400, json.dumps({"error": "apconfig"}), "application/json")
                        return
                args = ["ap-apply"]
                # Always 3 args in fixed slots: empty string = "keep current"
                # (a psk-only change must not land in the SSID slot; a hidden-
                # absent change must not land in the PSK slot).
                args.append(ssid if ssid is not None else "")
                args.append(psk if psk is not None else "")
                if hidden is None:
                    args.append("")
                elif hidden:
                    args.append("2")
                else:
                    args.append("0")
                # Session self-destruct (security plan todo 10): snapshot the
                # LIVE AP identity BEFORE ap-apply so the post-apply decision
                # compares against reality, not body presence. A degraded read
                # (""/False) compares the same way the GET route answers and
                # never blocks the apply.
                pre_apply = _ap_info_now(self)
                rc, out, err = self._run_tool(args, API_WRITE_TIMEOUT)
                if rc == 0:
                    # Rotate ONLY on a real identity change: the submitted
                    # SSID (already expanded from "random") differs from the
                    # live one, or hidden is EXPLICITLY set and its bool
                    # differs. PSK-only and no-op renames never rotate; a
                    # failed ap-apply restored the old config, so rc != 0
                    # must not rotate either.
                    rotate_needed = (
                        (ssid is not None and ssid != pre_apply["ap_ssid"])
                        or (hidden is not None
                            and hidden != pre_apply["hidden"]))
                    if rotate_needed and _rotate_session_salt():
                        sys.stderr.write(
                            "[status-server] apconfig: AP identity changed, "
                            "all sessions rotated\n")
                # Random-rename responses carry the generated name so the
                # client can show + store it BEFORE the restart drops the
                # radio. Other branches keep the bare _api_response shape.
                if generated_ssid is not None and rc == 0:
                    self._send(200, json.dumps({"ok": True, "rc": rc,
                                                "lines": out, "log": err,
                                                "ssid": generated_ssid}),
                               "application/json")
                    return
            elif path == "/api/wan/disconnect":
                rc, out, err = self._run_tool(["disconnect"], API_QUICK_TIMEOUT)
            elif path == "/api/wan/forget":
                ssid = body.get("ssid")
                if not self._ssid_valid(ssid):
                    self._send(400, json.dumps({"error": "ssid"}), "application/json")
                    return
                rc, out, err = self._run_tool(["forget", ssid], API_QUICK_TIMEOUT)
            elif path == "/api/admin/killswitch":
                # Security plan todo 4. on=True -> write the flag (cut);
                # on=False -> clear it (internet flows; absence = safe
                # default, never inverted). Persist first, then re-render
                # immediately (same reload path the block verbs use) so the
                # cut is live now, not on the next 30s tick. A failed reload
                # does NOT fail the request: the write stuck and the timer
                # converges — the response carries a "render" hint instead.
                on = body.get("on")
                if not isinstance(on, bool):
                    self._send(400, json.dumps({"error": "killswitch"}),
                               "application/json")
                    return
                if not _killswitch_write(on):
                    self._send(500, json.dumps({"error": "persist"}),
                               "application/json")
                    return
                rendered = _killswitch_reload()
                if not rendered:
                    sys.stderr.write(
                        "[status-server] killswitch: wan-select re-render "
                        "FAILED (applies on the next 30s tick)\n")
                self._send(200, json.dumps(
                    {"ok": True, "on": on,
                     **({} if rendered else {"render": "failed"})}),
                    "application/json")
                return
            elif path == "/api/admin/sshlockdown":
                # Security plan todo 9. on=True -> write the flag (the render
                # drops LAN-side tcp/22 and keeps the WAN path untouched);
                # on=False -> clear it (the default tcp { 53, 80, 22 } accept
                # returns; absence = safe default, never inverted). Persist
                # first, then re-render immediately via the same wan-select
                # seam the killswitch uses so the drop is live now, not on
                # the next 30s tick. A failed reload does NOT fail the
                # request: the write stuck and the timer converges — the
                # response carries a "render" hint instead.
                on = body.get("on")
                if not isinstance(on, bool):
                    self._send(400, json.dumps({"error": "sshlockdown"}),
                               "application/json")
                    return
                if not _sshlockdown_write(on):
                    self._send(500, json.dumps({"error": "persist"}),
                               "application/json")
                    return
                rendered = _killswitch_reload()
                if not rendered:
                    sys.stderr.write(
                        "[status-server] sshlockdown: wan-select re-render "
                        "FAILED (applies on the next 30s tick)\n")
                self._send(200, json.dumps(
                    {"ok": True, "on": on,
                     **({} if rendered else {"render": "failed"})}),
                    "application/json")
                return
            elif path == "/api/admin/dns":
                # Security plan todo 6 (wired by todo 11). Same
                # persist-then-one-reload posture as killswitch/sshlockdown:
                # the wan-select-owned stores are edited atomically (0600),
                # then ONE shared reload fires so the drop-ins re-render on
                # the next tick (wan-select restarts dnsmasq only when a
                # drop-in's PRESENCE toggled — an add to an already-active
                # list rewrites the file without a restart, by design).
                # set-local is a presence flag; add/del edit the list. A
                # failed reload does NOT fail the request (same "render"
                # hint as the flags).
                action = body.get("action")
                if action == "set-local":
                    on = body.get("on")
                    if not isinstance(on, bool):
                        self._send(400, json.dumps({"error": "dns"}),
                                   "application/json")
                        return
                    if not _flag_store_write(DNS_LOCAL_FILE, on):
                        self._send(500, json.dumps({"error": "persist"}),
                                   "application/json")
                        return
                elif action in ("add", "del"):
                    domain = body.get("domain")
                    if not _domain_valid(domain):
                        self._send(400, json.dumps({"error": "dns"}),
                                   "application/json")
                        return
                    d = domain.strip().lower()
                    rows = _blocked_domains_rows()
                    if action == "add":
                        if d not in rows:
                            rows.append(d)
                            if not _blocked_domains_write(rows):
                                self._send(500, json.dumps(
                                    {"error": "persist"}),
                                    "application/json")
                                return
                    else:
                        if d not in rows:
                            self._send(400, json.dumps({"error": "dns"}),
                                       "application/json")
                            return
                        if not _blocked_domains_write(
                                [r for r in rows if r != d]):
                            self._send(500, json.dumps(
                                {"error": "persist"}),
                                "application/json")
                            return
                else:
                    self._send(400, json.dumps({"error": "dns"}),
                               "application/json")
                    return
                rendered = _killswitch_reload()
                if not rendered:
                    sys.stderr.write(
                        "[status-server] dns: wan-select re-render FAILED "
                        "(applies on the next 30s tick)\n")
                self._send(200, json.dumps(
                    {"ok": True, "action": action,
                     "blocked_domains": _blocked_domains_rows(),
                     "local_only": os.path.exists(DNS_LOCAL_FILE),
                     **({} if rendered else {"render": "failed"})}),
                    "application/json")
                return
            elif path == "/api/admin/blocked":
                # Security plan todo 3 (wired by todo 11): the MAC block
                # verbs live in travel-wan (block/unblock/blocked, todo 2) —
                # the server is a pass-through, no store of its own. add on
                # an already-blocked MAC is idempotent (rc 0); del of an
                # unknown MAC is rc 1 -> 404 ("not blocked"). Validation is
                # also here so a malformed MAC never reaches the tool
                # (mirror of travel-wan's mac_ok).
                action = body.get("action")
                mac = body.get("mac")
                if action not in ("add", "del") or not isinstance(mac, str) \
                        or not re.fullmatch(
                            r"[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}", mac):
                    self._send(400, json.dumps({"error": "blocked"}),
                               "application/json")
                    return
                rc, out, err = self._run_tool(
                    ["block" if action == "add" else "unblock",
                     mac.lower()], API_QUICK_TIMEOUT)
                if rc is None:
                    self._send(504, json.dumps({"error": "timeout"}),
                               "application/json")
                    return
                if rc != 0:
                    self._send(404, json.dumps({"error": "blocked"}),
                               "application/json")
                    return
                self._send(200, json.dumps({"ok": True}), "application/json")
                return
            elif path == "/api/admin/rotate-sessions":
                # Security plan todo 7 (force-relogin): regenerate the salt
                # file via the shared atomic write (todo 10 reuses it on AP
                # rename/hide). Same invalidation semantics as before.
                if not _rotate_session_salt():
                    self._send(500, json.dumps({"error": "persist"}),
                               "application/json")
                    return
                sys.stderr.write(
                    "[status-server] rotate-sessions: salt rotated, all "
                    "sessions invalidated\n")
                self._send(200, json.dumps({"ok": True}),
                           "application/json")
                return
            else:
                rc, out, err = self._run_tool(["recheck"], API_QUICK_TIMEOUT)
        self._api_response(rc, out, err)


# Write verbs without a dispatcher stay reject-bound (404) — only POST is a
# real handler now (H01 posture change). Spec: any other method/path -> 404.
def _make_handler():
    h = StatusHandler
    for verb in WRITE_VERBS:
        setattr(h, "do_%s" % verb, h._reject_write)


_API_CODE_MSG = {
    400: "bad request",
    403: "forbidden",
    411: "length required",
    413: "payload too large",
    415: "unsupported media type",
}


def _code_msg(code):
    return _API_CODE_MSG.get(code, "error")


_make_handler()


def resolve_host_and_port():
    # C2 test-only bind seam: TRAVELROUTER_BIND_HOST (TEST-ONLY, never set in
    # the systemd unit) forces the bind address and IGNORES the state-file
    # lan_ip. Permits loopback deliberately -- that is its whole purpose (the
    # 255-assertion suite binds 127.0.0.1), so it does NOT reuse the strict
    # lan_ip allowlist below (loopback is rejected there by design). Any other
    # non-IPv4/multicast/reserved/unspecified value falls through to the
    # state-file path instead of being honored.
    seam = os.environ.get("TRAVELROUTER_BIND_HOST")
    if seam:
        try:
            sv = ipaddress.ip_address(seam)
            if (sv.version == 4 and not sv.is_unspecified
                    and not sv.is_multicast and not sv.is_reserved):
                return str(sv), _resolve_port()
        except ValueError:
            pass
    host = _state_field("lan_ip")
    try:
        v = ipaddress.ip_address(host) if host else None
    except ValueError:
        v = None
    if (v is None
            or v.version != 4
            or not v.is_private
            or v.is_loopback or v.is_link_local or v.is_multicast
            or v.is_reserved or v.is_unspecified
            or str(v) == "255.255.255.255"):
        host = DEFAULT_HOST
    return host, _resolve_port()


def _resolve_port():
    port = 80
    port_env = os.environ.get("TRAVELROUTER_STATUS_PORT")
    if port_env:
        try:
            port = int(port_env)
        except ValueError:
            port = 80
    return port


def main():
    host, port = resolve_host_and_port()
    httpd = ThreadingHTTPServer((host, port), StatusHandler)
    print("[status-server] listening on %s:%d" % (host, port))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
