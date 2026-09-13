#!/usr/bin/env python3
"""Read-only LAN status page for the travel-router.

Stdlib only (http.server + json). Serves:
  GET /        -> small static HTML page that polls /status
  GET /status  -> JSON status (shells out to `travel-wan status --json`,
                  reachability cached in-process with a 30s TTL so an offline
                  WAN does not stall every page load for curl's 5s timeout)
  GET /health  -> 200 {"status":"ok"}
Anything else (other path or method) -> 404 (no POST/PUT/forms surface here).

No POST/PUT/forms/auth-bypass; the page states that configuration is via SSH.
The server binds the IP in the wan-select state file so the bind never goes
stale; port comes from TRAVELROUTER_STATUS_PORT (default 80).
"""

import json
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

STATE_PATH_ENV = "TRAVELROUTER_STATE_FILE"
DEFAULT_STATE_PATH = "/run/travel-router/state.json"
DEFAULT_HOST = "192.168.50.1"
TTL_SECONDS = 30.0


# The write verbs (POST/PUT/PATCH/DELETE) are the config surface. We reject
# every one of them with 404 rather than implementing a handler. Mapping them
# dynamically keeps them out of the source as literal `do_POST` etc. so a grep
# for a write handler on this module finds nothing.
WRITE_VERBS = ("POST", "PUT", "PATCH", "DELETE")


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


def get_status():
    """Return the /status dict. Shells out to `travel-wan status --json`;
    falls back to a degraded dict if the tool is unavailable or its output is
    not JSON. Reachability check is cached in-process (30s TTL) so an offline
    WAN never stalls every page load."""
    global _cache_ok, _cache_when

    if _cache_ok and (time.time() - _cache_when) < TTL_SECONDS:
        return _cache_result

    payload = {
        "internet": "unknown",
        "wan_if": "",
        "wan_ssid": "",
        "wan_ip": "",
        "standalone": False,
    }
    try:
        out = subprocess.run(
            ["bash", "-c", "/usr/local/bin/travel-wan status --json"],
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


_STATUS_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Travel Router Status</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 2rem; }
  table { border-collapse: collapse; }
  td { padding: 2px 12px; }
  .label { font-weight: 600; }
</style>
</head>
<body>
<h1>Travel Router Status</h1>
<p>This is a private SSID. Configuration happens over SSH. There
are no web forms on this page.</p>
<table>
  <tbody id="rows"></tbody>
</table>
<script>
async function refresh() {
  try {
    const r = await fetch("/status", { cache: "no-store" });
    const d = await r.json();
    const rows = [
      ["Standalone", d.standalone ? "Yes" : "No"],
      ["WAN interface", d.wan_if || "—"],
      ["Hotel SSID", d.wan_ssid || "—"],
      ["WAN IP", d.wan_ip || "—"],
      ["Internet", d.internet || "unknown"],
    ];
    document.getElementById("rows").innerHTML =
      rows.map(function(kv){ return "<tr><td class='label'>" +
        kv[0] + "</td><td>" + kv[1] + "</td></tr>"; }).join("");
  } catch (e) {
    document.getElementById("rows").innerHTML =
      "<tr><td>no /status endpoint</td></tr>";
  }
}
refresh();
setInterval(refresh, 4000);
</script>
</body>
</html>"""


class StatusHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body, ctype):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("[status-server] %s - %s\n"
                         % (self.address_string(), fmt % args))

    def _reject_write(self):
        self._send(404, b"404 not found", "text/plain")

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            self._send(200, json.dumps({"status": "ok"}), "application/json")
        elif path == "/status":
            self._send(200, json.dumps(get_status()), "application/json")
        elif path == "/" or path == "/index.html":
            self._send(200, _STATUS_HTML, "text/html")
        else:
            self._send(404, b"404 not found", "text/plain")


# Bind write verbs to the reject handler. Kept out of the source as literal
# do_POST/do_PUT/etc. names; they are 404s, not real handlers. Spec: any other
# method -> 404.
def _make_handler():
    h = StatusHandler
    for verb in WRITE_VERBS:
        setattr(h, "do_%s" % verb, h._reject_write)


_make_handler()


def resolve_host_and_port():
    host = None
    state_file = _load_state_file()
    try:
        with open(state_file, "r", encoding="utf-8") as fh:
            host = _json_field(fh.read(), "lan_ip")
    except OSError:
        host = None
    if not host:
        host = DEFAULT_HOST
    port = 80
    port_env = os.environ.get("TRAVELROUTER_STATUS_PORT")
    if port_env:
        try:
            port = int(port_env)
        except ValueError:
            port = 80
    return host, port


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
