# U01 — Public status page: show the router's LAN address (+ robustness)

## Goal
Add the router's own LAN/AP IP to the public status page (and its backing
`GET /api/status`), and make the status table degrade to a visible row instead
of an empty section when the fetch fails.

## Context
The public status page (`_STATUS_HTML`, served at `/`) currently renders, under
the `<h2>Network</h2>` heading, only `Network name (SSID)` and `Connected to`.
The user wants the router's IP shown. The router's own LAN IP is the right
thing to expose publicly: it is the default `192.168.50.1` (already printed in
the install banner) and is only reachable from the private travel AP — nftables
drops WAN-side traffic to the router, so the page itself cannot be reached from
the untrusted side.

**This deliberately relaxes the S01 privacy assert.** `GET /api/status`
currently returns only `{ap_ssid, wan_ssid, internet}`, and the suite asserts it
leaks no IP (§5p(2), §5ai(1)). We now intentionally expose `lan_ip` (the
router's own AP address) while continuing to withhold `wan_ip` (that stays
admin-only — U02). The `wan_ip` leak asserts MUST remain.

No new subprocess calls: `get_status()` already loads `lan_ip` from
`state.json`, and `_state_field("lan_ip")` reads it directly.

## Files touched
- `roles/travel-router/assets/status-server.py` — `/api/status` adds `lan_ip`;
  `_STATUS_HTML` adds a "Router address" row + a fetch-failure row.
- `roles/travel-router/assets/validate-local.sh` — update §5p + §5ai asserts.

## Pre-conditions
- [ ] none (independent of the R wave).

## Exact changes required

### Change 1: `status-server.py` — `/api/status` (currently ~lines 784-809)
Update the comment (currently says "no WAN IP" — still true; note LAN IP is now
intentionally included) and add `lan_ip` to the response.

Before:
```python
        elif path == "/api/status":
            # Public minimal status — NO auth. Returns only non-sensitive
            # data: AP SSID, WAN SSID, internet status. No client list,
            # no WAN IP, no known networks, no scan results.
            wan_ssid = _state_field("wan_ssid") or ""
```
After:
```python
        elif path == "/api/status":
            # Public minimal status — NO auth. Returns AP SSID, WAN SSID,
            # internet status, and the router's OWN lan_ip (the AP-side
            # address, only reachable from the private AP). Still no client
            # list, no WAN IP, no known networks, no scan results.
            wan_ssid = _state_field("wan_ssid") or ""
```

Before:
```python
            self._send(200, json.dumps({
                "ap_ssid": ap_ssid,
                "wan_ssid": wan_ssid,
                "internet": internet,
            }), "application/json")
```
After:
```python
            self._send(200, json.dumps({
                "ap_ssid": ap_ssid,
                "wan_ssid": wan_ssid,
                "internet": internet,
                "lan_ip": _state_field("lan_ip") or "",
            }), "application/json")
```

### Change 2: `status-server.py` — `_STATUS_HTML` rows (currently ~lines 674-687)
Add the LAN-IP row and a fetch-failure row.

Before:
```js
      while (tbody.firstChild) { tbody.removeChild(tbody.firstChild); }
      cellRow(tbody, "Network name (SSID)", d.ap_ssid || "?");
      cellRow(tbody, "Connected to", d.wan_ssid || "standalone");
      var msg = document.getElementById("status-msg");
```
After:
```js
      while (tbody.firstChild) { tbody.removeChild(tbody.firstChild); }
      cellRow(tbody, "Network name (SSID)", d.ap_ssid || "?");
      cellRow(tbody, "Connected to", d.wan_ssid || "standalone");
      cellRow(tbody, "Router address", d.lan_ip || "?");
      var msg = document.getElementById("status-msg");
```

Before:
```js
    .catch(function () {
      document.getElementById("status-msg").textContent = "status unavailable";
    });
```
After:
```js
    .catch(function () {
      var tbody = document.getElementById("status-rows");
      while (tbody.firstChild) { tbody.removeChild(tbody.firstChild); }
      cellRow(tbody, "Status", "unavailable");
      document.getElementById("status-msg").textContent = "status unavailable";
    });
```

### Change 3: `validate-local.sh` — §5p public endpoint
(a) §5p header comment (~line 3687) — mention lan_ip is now included.
(b) §5p(1) field assert (~line 3701) — add `lan_ip`:
Before:
```bash
echo "$body" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert "ap_ssid" in d and "wan_ssid" in d and "internet" in d' 2>/dev/null \
  && ok "5p(1) /api/status has ap_ssid, wan_ssid, internet" || bad "5p(1) missing fields: $body"
```
After:
```bash
echo "$body" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert "ap_ssid" in d and "wan_ssid" in d and "internet" in d and "lan_ip" in d' 2>/dev/null \
  && ok "5p(1) /api/status has ap_ssid, wan_ssid, internet, lan_ip" || bad "5p(1) missing fields: $body"
```
(c) §5p(2) leak list (~line 3706) — **remove `lan_ip` only** (wan_ip MUST stay):
Before:
```bash
for w in clients wan_ip lan_ip mode standalone ap_state clients_list; do
```
After:
```bash
for w in clients wan_ip mode standalone ap_state clients_list; do
```
(d) Add, after the §5p(2) assert:
```bash
echo "$body" | grep -qF '"lan_ip"' \
  && ok "5p(2b) /api/status exposes lan_ip (router's own AP address)" \
  || bad "5p(2b) lan_ip MISSING"
```

### Change 4: `validate-local.sh` — §5ai minimal page
After the existing `status-rows` assert (~line 2219), add:
```bash
echo "$wh" | grep -qF 'Router address' \
  && ok "5ai(1) minimal page renders a router-address row" \
  || bad "5ai(1) router-address row MISSING"
```
(The §5ai leak loop checks for `wan_ip`; `d.lan_ip` does not match it, so no
other change is needed there.)

## Validation plan
```bash
bash roles/travel-router/assets/validate-local.sh 2>&1 | grep -E '5p\(|5ai\('
# Expected: 5p(1) has ... lan_ip PASS; 5p(2) leaks no sensitive fields PASS;
#           5p(2b) exposes lan_ip PASS; 5ai(1) router-address row PASS
bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -3
# Expected: SUITE GREEN

# Manual (optional): the served page carries the row and the endpoint the field.
python3 - <<'PY'
page = open("roles/travel-router/assets/status-server.py").read()
html = page.split('_STATUS_HTML = """')[1].split('"""')[0]
assert "Router address" in html and "d.lan_ip" in html
print("page OK")
PY
```

## Success criteria
- [ ] `/api/status` returns `lan_ip`; `wan_ip`/`mode`/`standalone`/client data still absent.
- [ ] Public page shows a "Router address" row.
- [ ] A failed `/api/status` fetch renders a "Status: unavailable" row (section never empty).
- [ ] Suite green; `wan_ip` leak assert still present and passing.

## Rollback
```bash
git checkout roles/travel-router/assets/status-server.py roles/travel-router/assets/validate-local.sh
```

## Next task
U02
