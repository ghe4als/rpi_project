#!/usr/bin/env python3
"""LAN status + PIN-gated setup API for the travel-router.

Stdlib only (http.server + json). Serves:
  GET /            -> small static HTML page that polls /status
  GET /status      -> JSON status (shells out to `travel-wan status --json`,
                      reachability cached in-process with a 30s TTL so an
                      offline WAN does not stall every page load)
  GET /health      -> 200 {"status":"ok"}
  GET /api/wan/known -> PIN-gated known-networks JSON (C6; X-Pin, same
                      throttle as POST / psks-manage; travel-wan known rows:
                      NAME/TIMESTAMP/AUTOCONNECT metadata, never a PSK)
  GET /api/wan/psks-manage -> PIN-gated metadata read (X-Pin, throttled)
  POST /api/wan/*  -> PIN-gated setup API (H01 posture change; see below)
Anything else (other path or method) -> 404.

POSTURE CHANGE (H01): this server used to be strictly read-only (every write
verb 404). The phone setup feature requires a writable surface, so
POST /api/wan/{scan,status,connect,disconnect,forget,recheck,psks} is now a
real dispatch. It stays gated: JSON-only bodies (8KB cap) + X-Requested-With
header (CSRF guard; no CORS headers are ever emitted) +, for write verbs,
TRAVELROUTER_SETUP_PIN from the environment compared in constant time. PIN
unset/empty -> every write verb 403s (deny-by-default; un-provisioned Pis
never grant write access). PUT/PATCH/DELETE stay reject-bound (404).

The server binds the IP in the wan-select state file so the bind never goes
stale; port comes from TRAVELROUTER_STATUS_PORT (default 80).
"""

import base64
import hashlib
import hmac
import ipaddress
import json
import os
import secrets
import subprocess
import sys
import threading
import time
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
SETUP_PAGE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "setup.html")
# Captive-portal hijack drop-in (wan-select owns + toggles it; H03). When it
# exists, OS connectivity-probe Hosts arriving here are 302'd to /setup.
PORTAL_CONF = os.environ.get(
    "TRAVELROUTER_PORTAL_CONF", "/etc/dnsmasq.d/travel-router-portal.conf")

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


def _psk_fingerprint():
    return hashlib.sha256(ADMIN_PSK.encode("utf-8")).hexdigest()[:16]


def _b64e(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


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
    handler._send(401, json.dumps({"error": "auth"}), "application/json",
                  extra_headers=[("Connection", "close")])
    handler.close_connection = True
    return False


# C2 (auth plan Todo 5): the LAN-facing root page is a STRICT generic warning.
# It must stay static and data-free: no device fields (wan_ssid/wan_ip/
# clients/ap_state), no /status polling — anyone on the travel AP sees it.
# The /setup link is the only way onward; the setup page itself carries the
# management UI (gated client-side from auth Todo 7).
_WARNING_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Private Travel Network</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 2rem; max-width: 40rem; }
</style>
</head>
<body>
<h1>Private travel network</h1>
<p>This is a private travel network. Authorized users only.
Unauthorized access is prohibited.</p>
<p>Configure the network at <a href="/setup">/setup</a>.</p>
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

    def _serve_setup(self):
        try:
            with open(SETUP_PAGE, "rb") as fh:
                body = fh.read()
        except OSError:
            sys.stderr.write("[status-server] setup page missing: %s\n" % SETUP_PAGE)
            self._send(500, b"setup page missing on this install", "text/plain")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        # The page must never be cached: WAN state and PIN behavior change
        # between captive-portal phases.
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _portal_redirect(self):
        """302 a connectivity-probe request to /setup. Target is the numeric
        LAN IP (captive webviews cannot rely on mDNS); the port is included
        whenever it is not 80, using the actually-bound port."""
        host = _state_field("lan_ip") or DEFAULT_HOST
        port = self.server.server_address[1]
        if port != 80:
            host = "%s:%d" % (host, port)
        self.send_response(302)
        self.send_header("Location", "http://%s/setup" % host)
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
        elif path == "/status":
            # C2/C4: /status is session-gated (Todo 5 stub, Todo 6 real
            # verify). The device JSON (mode/wan_ssid/wan_ip/clients_list) is
            # LAN-visible data; without a session the answer is a bare 401 —
            # same body for missing and invalid tokens (no oracle).
            if not _require_session(self):
                return
            self._send(200, json.dumps(get_status()), "application/json")
        elif path == "/api/wan/known":
            # Session-gated metadata read: the session is the read credential.
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
            # Session-gated metadata read: the X-Session token is also the
            # CSRF gate (a cross-site form/fetch cannot set a custom header
            # without a preflight this server never answers).
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
            # Session-gated "recently connected" read (auth plan Todo 7): the
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
        elif path == "/setup" or path == "/setup/":
            self._serve_setup()
        elif path == "/" or path == "/index.html":
            self._send(200, _WARNING_HTML, "text/html")
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
            # CORS preflight, and this server never answers preflight.
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
            # Session-gated reads (Todo 6): the check fires before any work,
            # and _require_session closes the connection on 401 so an unread
            # body cannot smuggle. These branches never read their request
            # body, so with HTTP/1.1 keep-alive an unsent body would be parsed
            # as the next (smuggled) request on the same socket. Close the
            # connection instead: header must be emitted between
            # send_response and end_headers (send_header buffers in call
            # order), and close_connection=True is defense-in-depth.
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
                or path == "/api/wan/forget" or path == "/api/wan/recheck"):
            self._send(404, b"404 not found", "text/plain")
            return
        # C1 PIN throttle: a blocked source gets 429 BEFORE the body is even
        # parsed. A blocked attempt is still a PIN guess, so it also advances
        # the fail count (lets a persistent brute-forcer escalate tiers).
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
            self._send(429, json.dumps({"error": "rate_limited"}),
                       "application/json", extra_headers=[("Connection", "close")])
            self.close_connection = True
            return
        body, err_code = self._read_json_body()
        if err_code is not None:
            self._send(err_code, json.dumps({"error": _code_msg(err_code)}),
                       "application/json")
            return
        # Two-factor writes (Todo 6): a valid session AND a correct body.pin.
        # The session check comes first and is pin_unset-aware so a session
        # holder sees 403 {"error":"pin_unset"} on an unprovisioned router,
        # while the same request without a session stays a bare 401 — a guest
        # cannot probe the PIN's existence (the pin_unset distinction never
        # leaks pre-session). SETUP_PIN-empty is pinned False for the whole
        # process, so caching the auth state does not change behavior.
        session_authed = getattr(self, "_session_authed", None)
        if session_authed is None:
            session_authed = _session_ok(self.headers.get("X-Session"))
            self._session_authed = session_authed
        if not session_authed:
            self._send(401, json.dumps({"error": "auth"}), "application/json",
                       extra_headers=[("Connection", "close")])
            self.close_connection = True
            return
        if not self._pin_ok(body):
            with _PIN_THROTTLE_LOCK:
                entry = _PIN_FAILS.setdefault(ip_key, [0, 0.0])
                entry[0] += 1
                tier = _pin_backoff_tier(entry[0])
                if tier:
                    entry[1] = time.time() + tier
            err_key = "pin" if SETUP_PIN else "pin_unset"
            self._send(403, json.dumps({"error": err_key}), "application/json")
            return
        with _PIN_THROTTLE_LOCK:
            _PIN_FAILS.pop(ip_key, None)
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
                rc, out, err = self._run_tool(args, API_WRITE_TIMEOUT)
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
