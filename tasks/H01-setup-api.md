# H01 — POST API skeleton in status-server.py + retire `no do_POST` assert

## Goal
The setup page's backend exists: JSON POST endpoints under `/api/wan/*` that
shell out to `travel-wan` via the existing TRAVELWAN_BIN seam, PIN-denied by
default (staging lands in H05), with the validation suite's read-only textual
assert deliberately retired and replaced by behavioral asserts.

## Context
`status-server.py` is read-only today: `_make_handler()` binds every write
verb to `_reject_write` (404) and `validate-local.sh:147-150` fails the suite
if the literal `do_POST` appears in the module (comment at status-server.py
lines 32-36 explains the intent). Phone setup requires a writable API; this
is a POSTURE CHANGE, done explicitly and atomically: the textual assert is
retired and behavioral equivalents land in the same commit. Metis consultation
ses_f6219dca4ffedD5s8gaSZMiCt7, decision "POST API is a deliberate posture
change" + "Mandatory setup PIN, deny-by-default".

## Files touched
- `roles/travel-router/assets/status-server.py` — add do_POST dispatcher, PIN gate, subprocess plumbing
- `roles/travel-router/assets/validate-local.sh` — retire textual assert; add §5d API battery

## Pre-conditions
- [x] validate-local.sh SUITE GREEN at HEAD (89/0)
- [x] Suite internals read: stub pattern at §5b/§5c (calls.log argv logging,
      127.0.0.1 bind fixture at srv-state.json, POST /status 404 assert at
      line 253-256 which REMAINS and must stay green)

## Exact changes required

### Change 1: status-server.py — do_POST dispatcher + /api/wan/* endpoints
File: `roles/travel-router/assets/status-server.py`
Action: REPLACE the `_reject_write` architecture with a real dispatcher.

Before (concept, current lines 32-36, 190-191, 205-214):
    WRITE_VERBS = ("POST", "PUT", "PATCH", "DELETE")
    def _reject_write(self): self._send(404, b"404 not found", "text/plain")
    def _make_handler(): ...setattr(h, "do_%s" % verb, h._reject_write)

After:
- `WRITE_VERBS = ("PUT", "PATCH", "DELETE")` stay reject-bound (404) — only
  POST gains a real handler.
- `def do_POST(self)`: single dispatcher. Path routing:
  - `/api/wan/scan`   -> GET-equivalent (no PIN needed; read-only)
  - `/api/wan/status` -> passthrough of get_status() (no PIN; read-only)
  - `/api/wan/connect`, `/api/wan/disconnect`, `/api/wan/forget`, `/api/wan/recheck`
      -> PIN-required (see Change 2)
  - anything else, including `/status`, `/`, `/setup` -> 404 (keeps the
    pre-existing `POST /status -> 404` assert green)
- Request policy (all POST):
  - `Content-Type: application/json` enforced (else 415)
  - header `X-Requested-With: XMLHttpRequest` enforced (CSRF guard: custom
    headers cannot be sent cross-origin without a CORS preflight; server
    emits NO CORS headers)
  - body read with hard cap: `Content-Length` <= 8192 else 413; missing
    Content-Length -> 411
  - JSON parse failure -> 400
- Subprocess plumbing (list-form ONLY, no shell=True):
  - scan: `subprocess.run([WAN_TOOL, "scan"], capture_output=True, timeout=25)`
    -> 200 `{"lines": <stdout splitlines>, "rc": <rc>}` — raw lines, no
    colon-parsing on the server (SSID terse output has escaped colons;
    frontend renders via textContent)
  - connect: validate `{"ssid": str, "psk": str?}`; reject empty/whitespace
    SSID, leading `-`, control chars, len(utf-8 bytes) > 32 (400). Then
    `[WAN_TOOL, "connect", ssid] (+ [psk] if psk)` with `timeout=90`
    -> 200 `{"ok": true, "log": <stderr lines>, "rc": <rc>}`; non-zero rc is
    still HTTP 200 (the API reports rc/log; UI decides) unless rc==2
    (usage error) -> 400.
  - disconnect/forget/recheck: `[WAN_TOOL, <sub>]` (+ ssid for forget),
    `timeout=30` -> same envelope.
  - All write verbs execute under a module-level `threading.Lock` (serialize;
    two phones must not race two `nmcli dev wifi connect`).
- PSK invariant: psk NEVER appears in any response, log line, or exception.
- PIN gate (Change 2) runs BEFORE any subprocess for write verbs.
- Update the module docstring (currently promises "read-only ... no POST";
  now: read-only GETs + a PIN-gated /api/wan write surface, posture changed
  in H01) and the `_STATUS_HTML` copy ("There are no web forms on this page")
  — the page copy update itself is H02's job, but the docstring must be
  truthful in this commit.

### Change 2: PIN gate, deny-by-default
File: `roles/travel-router/assets/status-server.py`
Action: INSERT alongside Change 1.
- `SETUP_PIN = os.environ.get("TRAVELROUTER_SETUP_PIN", "")`
- `_pin_ok(req_body_dict)`: returns False when SETUP_PIN == "" (deny-by-
  default: an un-provisioned Pi NEVER grants write access — H05 makes the
  var mandatory at provision time); compares `req["pin"]` to SETUP_PIN with
  `hmac.compare_digest` (import hmac); PIN is read from the JSON body key
  `pin` (the UI stores it in localStorage after first entry — no cookies, no
  sessions).
- 403 `{"error":"pin"}` on failure.

### Change 3: validate-local.sh — retire textual assert, add §5d battery
File: `roles/travel-router/assets/validate-local.sh`
Action: REPLACE lines 147-150 and APPEND a new section after §5c.

Before (lines 147-150):
    python3 - <<'PY' && ok "no literal do_POST" || bad "do_POST literal present"
    src = open("roles/travel-router/assets/status-server.py").read()
    raise SystemExit(0 if "do_POST" not in src else 1)
    PY

After:
    # POST API posture change (H01): write surface is deliberate now; the
    # textual `no do_POST` assert is retired. Behavior is asserted in §5d.
    grep -q 'def do_POST' "$A/status-server.py" && ok "POST dispatcher present (posture change H01)" || bad "do_POST missing"

New §5d (insert before §6 scope assert; reuse §5c fixtures: `$B/srv-state.json`
lan_ip=127.0.0.1, `$STW` stub travel-wan):
- Extend the `$STW` stub to APPEND its argv to `$B/tw-args.log` (printf into
  a log file) so call shapes are assertable.
- `POST /api/wan/connect` with PIN unset in env -> 403 (deny-by-default).
- With `TRAVELROUTER_SETUP_PIN=1234`: POST without/with wrong `pin` -> 403;
  right pin -> 200 AND `$B/tw-args.log` contains `connect HotelNet secret1`
  (list-form, exact argv); missing ssid -> 400; leading-dash ssid `-
  evil` -> 400; oversized body (9000 bytes) -> 413; wrong Content-Type ->
  415; missing X-Requested-With -> 415/403 (pick one, assert it).
- `POST /api/wan/scan` (no pin) -> 200 with `"lines"`.
- `POST /status` -> 404 (pre-existing assert stays green).
- PSK-echo assert: connect response body does NOT contain `secret1`.
- Suite §3 loop (line 117): NOTE — `SETUP_PIN` is added to `.env.example` in
  H05, NOT here; H05 extends that loop in the same commit.

## Validation plan
    bash roles/travel-router/assets/validate-local.sh
    # Expected: SUITE GREEN, PASS count >= 89 + ~10 new §5d asserts

    python3 -m py_compile roles/travel-router/assets/status-server.py
    # Expected: exit 0

    # Manual smoke (optional): TRAVELROUTER_SETUP_PIN=x TRAVELWAN_BIN=<stub>
    #   python3 status-server.py & ; curl -X POST -H 'Content-Type: application/json'
    #   -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"x","ssid":"A","psk":"b"}'
    #   http://127.0.0.1:18080/api/wan/connect  -> {"ok":true,...}

## Success criteria
- [ ] Suite GREEN with the §5d battery in place
- [ ] POST /status still 404; PUT/PATCH/DELETE still 404
- [ ] No PSK in any response; no shell=True anywhere in status-server.py
- [ ] git diff scoped to the two touched files

## Rollback
    git checkout roles/travel-router/assets/status-server.py roles/travel-router/assets/validate-local.sh

## Next task
H02 — /setup phone UI (blocked by H01).