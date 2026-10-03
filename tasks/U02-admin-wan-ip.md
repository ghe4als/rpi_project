# U02 — Admin page: show the WAN (hotel) IP

## Goal
Show the WAN/hotel-assigned IP (and WAN interface + connected SSID) on the
session-gated admin page, keeping the WAN IP off the public page.

## Context
U01 exposes only the router's own LAN IP publicly. The WAN IP is
semi-sensitive (it identifies the router on the hotel network), so it belongs
behind the admin session. No backend change is needed: `GET /status`
(session-gated) already returns `wan_ip`, `wan_if`, and `wan_ssid` via
`get_status()`. This is a pure admin.html render addition.

## Files touched
- `roles/travel-router/assets/admin.html` — new "Network" status section +
  populate it in `refreshStatus()`.
- `roles/travel-router/assets/validate-local.sh` — static asserts on admin.html.

## Pre-conditions
- [ ] U01 complete (public page owns `lan_ip`; this adds the admin-side view).
      Not strictly required — U02 does not depend on U01's code.

## Exact changes required

### Change 1: `admin.html` — add a Network status section
Insert after the PIN section (currently ends ~line 132) and before the WiFi
networks section (~line 134):

```html
  <section id="net-status-section">
    <h2>Network</h2>
    <table><tbody id="net-status-rows"></tbody></table>
  </section>
```

### Change 2: `admin.html` — populate it in `refreshStatus()` (~line 784)
`cellRow` already exists in admin.html (~line 298).

Before:
```js
function refreshStatus() {
  return statusFetch().then(function (d) {
    if (!d) { return; }
    LAST_STATUS = d;
    renderClients(d.clients_list || []);
```
After:
```js
function refreshStatus() {
  return statusFetch().then(function (d) {
    if (!d) { return; }
    LAST_STATUS = d;
    var nt = document.getElementById("net-status-rows");
    while (nt.firstChild) { nt.removeChild(nt.firstChild); }
    cellRow(nt, "LAN address", d.lan_ip || "?");
    cellRow(nt, "WAN address", d.wan_ip || "(none)");
    cellRow(nt, "WAN interface", d.wan_if || "(none)");
    cellRow(nt, "Connected to", d.wan_ssid || "standalone");
    renderClients(d.clients_list || []);
```

### Change 3: `validate-local.sh` — admin.html static battery (§5al)
Add asserts in the existing admin.html static battery (section `5al`):
```bash
grep -qF 'id="net-status-rows"' "$A/admin.html" \
  && ok "5al net-status section present" || bad "5al net-status section MISSING"
grep -qF 'd.wan_ip' "$A/admin.html" \
  && ok "5al admin renders WAN address" || bad "5al admin WAN address MISSING"
```
(Use whatever variable the suite already uses for the assets dir — `$A` in the
surrounding §5ai/§5c fixture idiom; if the §5al battery uses a different path
variable, match it.)

## Validation plan
```bash
grep -qF 'id="net-status-rows"' roles/travel-router/assets/admin.html && echo "section OK"
grep -qF 'd.wan_ip' roles/travel-router/assets/admin.html && echo "wan render OK"
python3 -c "import html,sys; print('html parses')"  # sanity (optional)
bash roles/travel-router/assets/validate-local.sh 2>&1 | grep -E '5al'
# Expected: both new 5al asserts PASS
bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -3
# Expected: SUITE GREEN
```

## Success criteria
- [ ] Admin page shows LAN address, WAN address, WAN interface, connected SSID.
- [ ] WAN IP appears ONLY on the admin page, never on the public page/endpoint.
- [ ] Suite green.

## Rollback
```bash
git checkout roles/travel-router/assets/admin.html roles/travel-router/assets/validate-local.sh
```

## Next task
Update `tasks/PLAN.md` (Wave U index) and commit each task separately.
