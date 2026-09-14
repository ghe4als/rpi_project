# T09 — Repair travel-wan.sh + status-server.py + dnsmasq template: status parity, real recheck, seam, self-DNS

## Goal
Make status output truthful and spec-complete, make `recheck` actually trigger
wan-select, add the QA seam for the status server, and fix the DNS-option bug.

## Context
Audit lane bg_a6e2cd6a + oracle bg_0366335d; ledger B8/B9. `status --json` lacks
mode/lan_ip and hardcodes standalone (ethernet-WAN Pi self-contradictory); recheck
is a logged no-op (spec: trigger wan-select once); status-server hardcodes
/usr/local/bin/travel-wan (no seam); dnsmasq template's bare `dhcp-option=6` does
not advertise self-DNS (dnsmasq does that by default; a valueless option is at best
redundant, per dnsmasq semantics suppressed/misused — delete it).

## Files touched
- `roles/travel-router/assets/travel-wan.sh`
- `roles/travel-router/assets/status-server.py`
- `roles/travel-router/assets/dnsmasq.conf.tmpl`

## Exact changes (plan todo 9 is authoritative)
a. cmd_status: read mode + lan_ip from TRAVELROUTER_STATE_FILE; derive standalone
   from state mode (never hardcode); both JSON paths carry mode/lan_ip/standalone;
   strip `"` and `\` from the connection name before JSON interpolation.
b. recheck: `"$SUDO" "$SYSTEMCTL" start wan-select.service` with new seam
   `SYSTEMCTL="${SYSTEMCTL:-systemctl}"`; keep the explanatory log.
c. nmcli syntax: `dev wifi list ifname <if>` (was `dev <if>`); connect gains
   `ifname "$if_name"`.
d. status-server.py: `WAN_TOOL = os.environ.get("TRAVELWAN_BIN",
   "/usr/local/bin/travel-wan")`; `subprocess.run([WAN_TOOL, "status", "--json"], …)`
   (drop the bash -c wrapper); seed fallback payload mode/lan_ip from state.json so
   /status ALWAYS carries those keys.
e. dnsmasq.conf.tmpl: delete the bare `dhcp-option=6` line; fix the comment
   (dnsmasq advertises itself as DNS by default).

## Pre-conditions
- [x] T01–T06 committed; audit ledger recorded. File-disjoint from T07/T08.

## Validation plan
    bash -n roles/travel-router/assets/travel-wan.sh       # exit 0
    python3 -c "import ast; ast.parse(open('roles/travel-router/assets/status-server.py').read())"  # exit 0
    # status --json with stub tools + fixture state.json (mode=standalone, lan_ip=192.168.50.1):
    #   parses via python3 -m json.tool AND contains mode/lan_ip/standalone matching fixture
    # recheck with SYSTEMCTL stub → stub log contains a start call for wan-select.service
    # status-server with TRAVELWAN_BIN=<stub> on port 18080: /status JSON contains mode; POST → 404
    # grep: no bare 'dhcp-option=6' in dnsmasq.conf.tmpl; no 'do_POST' literal in status-server.py

## Success criteria
- [ ] Battery green; connect-missing-SSID regression still rc=2; no PSK in status output.

## Rollback
    git checkout roles/travel-router/assets/travel-wan.sh roles/travel-router/assets/status-server.py roles/travel-router/assets/dnsmasq.conf.tmpl

## Next task
T10 (docs) — blocked by T07+T08+T09.