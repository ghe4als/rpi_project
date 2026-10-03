#!/bin/bash
# validate-local.sh — travel-router local validation suite (todo 11).
# Runs the full agent-executable QA battery on a macOS/Linux runner.
# No Pi required; zero system mutations (stubbed tools + temp dirs only).
# Exit 0 = all green. Evidence: .omo/evidence/travel-router-role/task-11-travel-router-role.log
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
EVID_DIR="$ROOT/.omo/evidence/travel-router-role"
mkdir -p "$EVID_DIR"
LOG="$EVID_DIR/task-11-travel-router-role.log"
TMP="$(mktemp -d /tmp/tr-validate.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
# admin todo 8: the HMAC session salt is re-read from disk on EVERY verify
# (_load_salt). On the Pi it lives on tmpfs at /run/travel-router/; this
# runner has no writable /run, so an unpersisted salt regenerates per call
# and every minted token 401s. Point every fixture server at a suite-local
# salt file (per-section servers still get fresh state via fresh processes).
export TRAVELROUTER_SALT_FILE="$TMP/suite-session-salt"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  [PASS] $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
sec()  { echo; echo "### $*"; }

# wait_healthy PORT [tries]: poll /health until the live server responds
# (fixed sleeps race slow binds — §5t/§5w flaked at ~1/5 on code=000).
# 60 tries x 0.25s = 15s ceiling: python 3.14 cold starts after the heavy
# §5b batteries can exceed the old 5s window (5d's first asserts 000'd).
wait_healthy() {
  local port="$1" i=0
  for i in $(seq 1 60); do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/health" 2>/dev/null)" == "200" ]]; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

# --- (1) syntax -------------------------------------------------------------
sec "1. syntax"
for f in "$ROOT"/roles/travel-router/*.sh "$ROOT"/roles/travel-router/assets/*.sh "$ROOT"/roles/travel-router/assets/validate-local.sh; do
  [[ -f "$f" ]] || continue
  if bash -n "$f" 2>"$TMP/err"; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f"): $(cat "$TMP/err")"; fi
done
if python3 -m py_compile -q "$ROOT/roles/travel-router/assets/status-server.py" 2>"$TMP/err"; then
  ok "py_compile status-server.py"
else bad "py_compile: $(cat "$TMP/err")"; fi
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$ROOT"/roles/travel-router/*.sh "$ROOT"/roles/travel-router/assets/*.sh >/dev/null 2>&1 && ok "shellcheck clean" || bad "shellcheck findings"
else
  echo "  [SKIP] shellcheck not installed (not a failure)"
fi

# --- (2) render checks (install.sh dry-run battery) --------------------------
sec "2. install.sh dry-run battery"
cat > "$TMP/role.env" <<'EOF'
TRAVELROUTER_AP_SSID=TestNet
TRAVELROUTER_AP_PSK=TestPass123
TRAVELROUTER_AP_CHANNEL=6
TRAVELROUTER_AP_COUNTRY=US
TRAVELROUTER_LAN_CIDR=192.168.50.1/24
TRAVELROUTER_DHCP_RANGE=192.168.50.100,192.168.50.200,12h
TRAVELROUTER_WAN_PREFER=auto
TRAVELROUTER_STATUS_PORT=80
TRAVELROUTER_SETUP_PIN=9876
TRAVELROUTER_ADMIN_PSK=AdminPass99
EOF
pfx="$TMP/run1"
if TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$pfx" TRAVELROUTER_ROLE_ENV="$TMP/role.env" \
   bash "$ROOT/roles/travel-router/install.sh" >"$TMP/run1.log" 2>&1; then
  ok "happy run rc=0"
else bad "happy run exited $?"; fi
grep -q "travel-router installed" "$TMP/run1.log" && ok "banner present" || bad "banner missing"
for u in wan-select.service wan-select.timer hostapd-travel.service travel-router-status.service; do
  [[ -f "$pfx/etc/systemd/system/$u" ]] && ok "unit staged: $u" || bad "unit MISSING: $u"
done
[[ $(stat -f%Lp "$pfx/usr/local/lib/travel-router/wan-select.sh" 2>/dev/null || stat -c%a "$pfx/usr/local/lib/travel-router/wan-select.sh" 2>/dev/null) == "755" ]] \
  && ok "wan-select.sh staged 0755" || bad "wan-select.sh staged mode != 0755"
[[ -f "$pfx/usr/local/lib/travel-router/nftables.conf.tmpl" ]] \
  && ok "nftables.conf.tmpl deployed" || bad "nftables.conf.tmpl NOT deployed"
[[ -f "$pfx/usr/local/lib/travel-router/admin.html" ]] \
  && ok "admin.html deployed (S04 merge)" || bad "admin.html NOT deployed"
# ap-apply locates its render template at /etc/rpi-project/travel-router/
# (its self_dir fallback is /usr/local/bin, where the template never lives).
# Not staged -> every apconfig apply dies with "hostapd template not found".
[[ -f "$pfx/etc/rpi-project/travel-router/hostapd.conf.tmpl" ]] \
  && ok "hostapd.conf.tmpl staged for ap-apply" || bad "hostapd.conf.tmpl NOT staged (ap-apply: template not found)"
grep -qF 'install -m 0644 "$ASSETS/hostapd.conf.tmpl"' "$ROOT/roles/travel-router/install.sh" \
  && ok "install.sh real-mode installs hostapd.conf.tmpl" || bad "install.sh missing real-mode hostapd.conf.tmpl install"
grep -q 'ssid=TestNet' "$pfx/etc/hostapd/hostapd-travel.conf" && ok "hostapd ssid rendered" || bad "hostapd ssid missing"
grep -q 'wpa_passphrase=TestPass123' "$pfx/etc/hostapd/hostapd-travel.conf" && ok "PSK rendered" || bad "PSK missing"
# The staged hostapd.conf.tmpl keeps its placeholders BY DESIGN (ap-apply
# renders it at runtime); only rendered configs must be placeholder-free.
if grep -rn '__[A-Z][A-Z_]*__' "$pfx/etc" "$pfx/usr/local/lib/travel-router/status-server.py" "$pfx/usr/local/bin" 2>/dev/null | grep -vF '/etc/rpi-project/travel-router/' | grep -q .; then
  bad "unsubstituted placeholders remain: $(grep -rl '__[A-Z][A-Z_]*__' "$pfx/etc" "$pfx/usr/local" 2>/dev/null | grep -vF '/etc/rpi-project/travel-router/' | tr '\n' ' ')"
else ok "0 unsubstituted placeholders in rendered configs"; fi
# render-breaker SSID battery
for v in 'a|b' 'a&b' 'a\b' 'a$b'; do
  printf 'TRAVELROUTER_AP_PSK=TestPass123\n' > "$TMP/ss.env"
  out=$(TRAVELROUTER_AP_SSID="$v" TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$TMP/ss" \
        TRAVELROUTER_ROLE_ENV="$TMP/ss.env" bash "$ROOT/roles/travel-router/install.sh" 2>&1)
  rc=$?
  if [[ $rc -eq 1 && "$out" == *"remediation:"* ]]; then ok "SSID '$v' rejected (rc=1 + remediation)"; else bad "SSID '$v' NOT rejected (rc=$rc)"; fi
done
# unset SSID -> friendly fail, not unbound variable
out=$(env -u TRAVELROUTER_AP_SSID TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$TMP/unset" \
      TRAVELROUTER_ROLE_ENV="$TMP/ss.env" bash "$ROOT/roles/travel-router/install.sh" 2>&1)
[[ $? -eq 1 && "$out" == *"AP_SSID"*"empty"* ]] && ok "unset SSID -> friendly fail" \
  || bad "unset SSID handling: $(echo "$out" | head -2 | tr '\n' ' ')"
# PSK regression battery
for v in 'a' 'abcdefgh' ; do :; done
for p in 'short7x' "$(printf 'x%.0s' {1..64})" 'TestPass|1'; do
  printf 'TRAVELROUTER_AP_SSID=TestNet\n' > "$TMP/pk.env"
  out=$(TRAVELROUTER_AP_PSK="$p" TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$TMP/pk" \
        TRAVELROUTER_ROLE_ENV="$TMP/pk.env" bash "$ROOT/roles/travel-router/install.sh" 2>&1)
  [[ $? -eq 1 ]] && ok "PSK '$(echo "$p" | cut -c1-8)…' rejected" || bad "PSK '$p' NOT rejected"
done
grep -q 'TestPass123' "$TMP/run1.log" && bad "PSK leaked to install log" || ok "PSK absent from logs"
[[ -n "$(grep 'TestPass123' "$pfx/etc/hostapd/hostapd-travel.conf")" ]] && ok "PSK only in rendered config" || bad "PSK not in config?!"
# order: unit staging before systemctl enable
u1=$(grep -n 'staged\|installed' "$TMP/run1.log" | head -1 | cut -d: -f1)
u2=$(grep -n 'dry-run: systemctl enable' "$TMP/run1.log" | head -1 | cut -d: -f1)
[[ -n "$u1" && -n "$u2" && "$u1" -lt "$u2" ]] && ok "units staged BEFORE first systemctl enable" || bad "unit install order wrong"
# enable-dnsmasq before restart; sanity before enables
ins="$ROOT/roles/travel-router/install.sh"
[[ "$(grep -n 'systemctl enable dnsmasq.service' "$ins" | cut -d: -f1)" -lt "$(grep -n 'systemctl restart dnsmasq.service' "$ins" | cut -d: -f1)" ]] \
  && ok "enable dnsmasq before restart" || bad "enable/restart dnsmasq order"
s1=$(grep -n 'sanity-assert stock dnsmasq' "$ins" | head -1 | cut -d: -f1)
s2=$(grep -n 'systemctl daemon-reload' "$ins" | cut -d: -f1)
[[ "$s1" -lt "$s2" ]] && ok "dnsmasq sanity check BEFORE unit enable" || bad "sanity check position"

# --- (2b) nftables template structural --------------------------------------
sec "2b. nftables template"
first=$(grep -v '^[[:space:]]*#' "$ROOT/roles/travel-router/assets/nftables.conf.tmpl" | grep -m1 . | xargs)
[[ "$first" == "flush ruleset" ]] && ok "first non-comment line = flush ruleset" || bad "first line: $first"
grep -qF 'dhcp-option=6' "$ROOT/roles/travel-router/assets/dnsmasq.conf.tmpl" \
  && bad "bare dhcp-option=6 still present in dnsmasq template" || ok "dnsmasq template: no bare dhcp-option=6"

# --- (3) provisioner filter check -------------------------------------------
sec "3. provisioner filter"
for pf in provision.sh provision-bookworm.sh; do
  grp=$(grep -oE '\((TOUCHSCREEN[^)]*)\)_' "$ROOT/$pf" | head -1 | sed 's/^(//; s/)_$//')
  m=$(printf 'TRAVELROUTER_TEST_X=1\n' | awk -v p="^(${grp})_" -F= '$0 ~ p {print $1}')
  [[ "$m" == "TRAVELROUTER_TEST_X" ]] && ok "$pf regex matches TRAVELROUTER_*" || bad "$pf regex does NOT match (grp=$grp)"
  n=$(printf 'WIFI_PSK=secret\n' | awk -v p="^(${grp})_" -F= '$0 ~ p {print $1}')
  [[ -z "$n" ]] && ok "$pf regex excludes WIFI_*" || bad "$pf regex MATCHES WIFI_* (forbidden)"
done
for v in AP_SSID AP_PSK AP_CHANNEL AP_COUNTRY LAN_CIDR DHCP_RANGE WAN_PREFER STATUS_PORT SETUP_PIN; do
  grep -q "^TRAVELROUTER_${v}=" "$ROOT/.env.example" && ok ".env.example has TRAVELROUTER_${v}" || bad ".env.example missing TRAVELROUTER_${v}"
done
grep -q 'travel-router' "$ROOT/.env.example" && ok ".env.example ROLE enum includes travel-router" || bad ".env.example enum stale"

# --- (4) docs cross-check ----------------------------------------------------
sec "4. docs cross-check"
for doc in README.md INVENTORY.md; do
  c=$(grep -c 'travel-router' "$ROOT/$doc"); [[ $c -ge 1 ]] && ok "$doc mentions travel-router ($c)" || bad "$doc missing travel-router"
done
for v in $(grep -o 'TRAVELROUTER_[A-Z_]\+' "$ROOT/README.md" | sort -u); do
  grep -q "^${v}=" "$ROOT/.env.example" && ok "README var $v documented in .env.example" || bad "README var $v MISSING from .env.example"
done

# --- (5) structural + seam asserts -------------------------------------------
sec "5. structural + seam asserts"
A="$ROOT/roles/travel-router/assets"
grep -q 'WantedBy=multi-user.target' "$A/wan-select.service" && ok "wan-select.service [Install]" || bad "wan-select.service missing [Install]"
grep -q 'WantedBy=timers.target' "$A/wan-select.timer" && ok "wan-select.timer [Install]" || bad "timer missing [Install]"
grep -qF 'ExecStart=/usr/sbin/hostapd /etc/hostapd/hostapd-travel.conf' "$A/hostapd-travel.service" && ok "hostapd-travel ExecStart" || bad "hostapd-travel ExecStart wrong"
grep -n 'restart NetworkManager' "$A/wan-select.sh" >/dev/null 2>&1 && bad "wan-select restarts NetworkManager (forbidden)" || ok "wan-select never restarts NM"
for seam in SYSFS_ROOT TRAVELROUTER_DRY_RUN; do
  grep -q "$seam" "$A/wan-select.sh" && ok "wan-select seam $seam" || bad "wan-select missing $seam"
done
grep -q 'TRAVELROUTER_DRY_RUN' "$ROOT/roles/travel-router/install.sh" && grep -q 'DRY_RUN_PREFIX' "$ROOT/roles/travel-router/install.sh" && ok "install.sh seams" || bad "install.sh seams missing"
for seam in NMCLI IP CURL HOSTAPD_CLI SYSTEMCTL TRAVELROUTER_STATE_FILE; do
  grep -q "^\s*${seam}=" "$A/travel-wan.sh" && ok "travel-wan seam $seam" || bad "travel-wan missing seam $seam"
done
grep -q 'TRAVELWAN_BIN' "$A/status-server.py" && ok "status-server seam TRAVELWAN_BIN" || bad "status-server missing TRAVELWAN_BIN"
grep -q 'TRAVELROUTER_STATE_FILE' "$A/status-server.py" && ok "status-server state seam" || bad "status-server missing state seam"
# POST API posture change (H01): the write surface is deliberate now, so the
# textual `no do_POST` assert is retired. Behavior is asserted in §5d below.
grep -q 'def do_POST' "$A/status-server.py" && ok "POST dispatcher present (posture change H01)" || bad "do_POST missing"
grep -qF 'dhcp-option=6' "$A/dnsmasq.conf.tmpl" && bad "bare dhcp-option=6 still present" || ok "dnsmasq self-DNS line removed"

# --- (5b) wan-select REAL-execution regression battery (Oracle C1/C2) --------
sec "5b. wan-select regression battery (non-dry-run where required)"
B="$TMP/t08v"; mkdir -p "$B/bin" "$B/sys/class/net/lo" "$B/sys/class/net/wlan0/wireless" "$B/sys/class/net/wlan1/wireless" "$B/sys/class/net/eth0" "$B/etc" "$B/ip-addr" "$B/nmcli-conn"
mkdir -p "$B/sys/devices/platform/scb/usb/1-1/1-1.1" "$B/sys/devices/platform/scb/usb/1-1/1-1.2" "$B/sys/devices/platform/soc/fe300000.mmcnr/mmc_host/mmc1"
ln -sf "$B/sys/devices/platform/soc/fe300000.mmcnr/mmc_host/mmc1" "$B/sys/class/net/wlan0/device"
ln -sf "$B/sys/devices/platform/scb/usb/1-1/1-1.2" "$B/sys/class/net/wlan1/device"
ln -sf "$B/sys/devices/platform/scb/usb/1-1/1-1.1" "$B/sys/class/net/eth0/device"
printf 'global\ncountry 00: DFS-UNSET\n\t(2402 - 2472 @ 40), (N/A, 20 dBm), (N/A)\n' > "$B/iw-regget.out"
printf '2: wlan0    inet 192.168.50.1/24 brd 192.168.50.255 scope global wlan0\n       valid_lft forever' > "$B/ip-addr/wlan0"
printf '2: eth0    inet 10.0.0.2/24 brd 10.0.0.255 scope global dynamic eth0\n       valid_lft forever' > "$B/ip-addr/eth0"
printf 'HomeWifi' > "$B/nmcli-conn/wlan1"; printf 'WiredUpstream' > "$B/nmcli-conn/eth0"
for t in iw nft rfkill systemctl; do
  printf '#!/bin/bash\n{ printf "%%s " "$(basename "$0")"; printf "%%s\\n" "$*"; } >> %s/calls.log\nexit 0\n' "$B" > "$B/bin/$t"
done
printf '#!/bin/bash\n{ printf "%%s " "ip"; printf "%%s\\n" "$*"; } >> %s/calls.log\ndev=""; prev=""; for a in "$@"; do [ "$prev" = dev ] && dev="$a"; prev="$a"; done\nif [ -n "$dev" ] && [ -f %s/ip-addr/"$dev" ]; then cat %s/ip-addr/"$dev"; exit 0; fi\nif [ -n "$dev" ]; then exit 1; fi\nexit 0\n' "$B" "$B" "$B" > "$B/bin/ip"
printf '#!/bin/bash\n{ printf "%%s " "nmcli"; printf "%%s\\n" "$*"; } >> %s/calls.log\ndev="${@: -1}"; if [ -f %s/nmcli-conn/"$dev" ]; then printf "GENERAL.CONNECTION:%%s\\n" "$(cat %s/nmcli-conn/"$dev")"; exit 0; fi\nexit 1\n' "$B" "$B" "$B" "$B" > "$B/bin/nmcli"
printf '#!/bin/bash\n{ printf "%%s " "cp"; printf "%%s\\n" "$*"; } >> %s/calls.log\nexec /bin/cp "$@"\n' "$B" > "$B/bin/cp"
chmod +x "$B"/bin/*
mkdir -p "$B/dnsmasq.d"
printf 'interface=wlan0\n' > "$B/dnsmasq.d/travel-router.conf"   # install.sh's file must survive portal toggles
run_wan() { rm -f "$B/calls.log"; SYSFS_ROOT="$B/sys" TRAVELROUTER_WAN_PREFER="$1" TRAVELROUTER_STATE_FILE="$2" \
  NFTABLES_TARGET="$B/etc/nftables.conf" DNSMASQ_CONF_DIR="$B/dnsmasq.d" PATH="$B/bin:$PATH" ASSETS="$A" bash "$A/wan-select.sh" 2>&1; }
jval() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" 2>/dev/null | head -1 | sed -E "s/.*:[[:space:]]*\"([^\"]*)\".*/\1/"; }
# R1: auto -> ethernet-first (durable assert, Momus NOTE 5)
out=$(run_wan auto "$B/state1.json"); rc=$?
[[ $rc -eq 0 && "$(jval wan_if "$B/state1.json")" == "eth0" ]] && ok "auto -> wan_if=eth0 (ethernet-first)" || bad "auto preference: rc=$rc wan_if=$(jval wan_if "$B/state1.json")"
# R1b: fresh state (lan_ip "" -> 192.168.50.1) + IP present -> the status-unit
# restart MUST be enqueued --no-block: a blocking try-restart here deadlocks
# (status is After=wan-select.service; live failure on rpi-8e21bb 2026-09-23).
grep -qF 'systemctl try-restart --no-block travel-router-status.service' "$B/calls.log" \
  && ok "R1b lan_ip change -> try-restart --no-block (deadlock guard)" \
  || bad "R1b try-restart missing/--no-block absent: $(grep 'try-restart' "$B/calls.log" | head -1)"
# R2: unknown value -> ethernet-first fallback
out=$(run_wan banana "$B/state2.json"); rc=$?
[[ $rc -eq 0 && "$(jval wan_if "$B/state2.json")" == "eth0" ]] && ok "unknown WAN_PREFER -> ethernet-first" || bad "unknown prefer rc=$rc"
# R3: none -> standalone
out=$(run_wan none "$B/state3.json"); rc=$?
[[ $rc -eq 0 && "$(jval mode "$B/state3.json")" == "standalone" ]] && ok "none -> standalone rc=0" || bad "standalone mode rc=$rc"
# R4: colon regdom
grep -qF 'iw reg set US' "$B/calls.log" && ok "iw reg set US (colon stripped)" || bad "regdom: $(grep 'reg set' "$B/calls.log" | head -1)"
c=$(grep -c 'iw reg set 00' "$B/calls.log"); [[ $c -eq 0 ]] && ok "stub never receives 00:" || bad "iw reg set 00 count=$c"
# R5: power_save via iw
grep -q 'iw dev wlan0 set power_save off' "$B/calls.log" && ok "power_save via iw" || bad "power_save tool wrong"
p=$(grep -cE 'ip link .*power_save' "$B/calls.log"); [[ $p -eq 0 ]] && ok "no ip-link power_save" || bad "ip link power_save count=$p"
# R6: cp-before-nft order (NON-dry-run, Oracle C1) + SYSTEMCTL stub (Oracle C2)
printf '{"mode":"routed","wan_if":"eth0","lan_ip":"192.168.50.1"}' > "$B/state4.json"
out=$(run_wan ethernet "$B/state4.json"); rc=$?
cl=$(grep -n '^cp ' "$B/calls.log" | head -1 | cut -d: -f1)
nf=$(grep -n 'nft -f' "$B/calls.log" | head -1 | cut -d: -f1)
[[ $rc -eq 0 && -n "$cl" && -n "$nf" && "$cl" -lt "$nf" ]] && ok "cp BEFORE nft -f (non-dry-run)" || bad "load order: cp=$cl nft=$nf rc=$rc"
[[ "$(head -1 "$B/etc/nftables.conf")" == "flush ruleset" ]] && ok "loaded render flush-first" || bad "render first line wrong"
# R7: truncated state.json -> resilient
printf '{"mode": "routed", "wan_if": "eth0", "lan_ip": "192.168.50.1' > "$B/state5.json"
out=$(run_wan ethernet "$B/state5.json"); rc=$?
[[ $rc -eq 0 && "$(jval lan_ip "$B/state5.json")" == "192.168.50.1" ]] && ok "truncated state.json degrades + rewritten" || bad "truncated state rc=$rc"
# R8: atomic write artifact
grep -q 'STATE_TMP=' "$A/wan-select.sh" && grep -q 'mv -f "$STATE_TMP"' "$A/wan-select.sh" && ok "state.json atomic (same-dir tmp + mv -f)" || bad "state write not atomic"
# R9: crash-mode fallback (ethernet absent -> standalone)
mkdir -p "$B/sys2/class/net/lo" "$B/sys2/class/net/wlan0/wireless"
ln -sf "$B/sys/devices/platform/soc/fe300000.mmcnr/mmc_host/mmc1" "$B/sys2/class/net/wlan0/device"
out=$(SYSFS_ROOT="$B/sys2" TRAVELROUTER_WAN_PREFER=ethernet TRAVELROUTER_STATE_FILE="$B/state6.json" NFTABLES_TARGET="$B/etc/nftables.conf" DNSMASQ_CONF_DIR="$B/dnsmasq.d" PATH="$B/bin:$PATH" ASSETS="$A" bash "$A/wan-select.sh" 2>&1); rc=$?
[[ $rc -eq 0 && "$(jval mode "$B/state6.json")" == "standalone" ]] && ok "ethernet-prefer absent adapter -> standalone rc=0" || bad "crash-mode rc=$rc"

# --- (5e) portal drop-in toggle battery (H03) --------------------------------
sec "5e. portal drop-in toggle (H03)"
PORTAL="$B/dnsmasq.d/travel-router-portal.conf"
dnsmasq_restarts() { grep -cF 'systemctl restart dnsmasq.service' "$B/calls.log" 2>/dev/null || true; }
# T1: standalone (WAN_PREFER=none) -> drop-in present, rendered, one restart
# (R9 above is also standalone + shared conf dir: its run already wrote the
# drop-in, so clear it first to exercise the toggle-on path from scratch)
rm -f "$B/dnsmasq.d/travel-router-portal.conf"
out=$(run_wan none "$B/stateT1.json"); rc=$?
[[ $rc -eq 0 ]] && ok "T1 standalone run rc=0" || bad "T1 rc=$rc"
[[ -f "$PORTAL" ]] && ok "T1 drop-in written in standalone" || bad "T1 drop-in MISSING"
grep -qF 'address=/captive.apple.com/192.168.50.1' "$PORTAL" && ok "T1 probe domain answered with LAN IP" || bad "T1 probe address: $(grep captive "$PORTAL" 2>/dev/null)"
grep -qF 'address=/dns.msftncsi.com/131.107.255.255' "$PORTAL" && ok "T1 msftncsi answered with EXPECTED value" || bad "T1 msftncsi wrong: $(grep msftncsi "$PORTAL" 2>/dev/null)"
if grep -q '__[A-Z][A-Z_]*__' "$PORTAL"; then bad "T1 unsubstituted placeholder in drop-in"; else ok "T1 no placeholders in drop-in"; fi
[[ "$(dnsmasq_restarts)" == "1" ]] && ok "T1 exactly one dnsmasq restart (toggle-on)" || bad "T1 restart count=$(dnsmasq_restarts)"
# T2: content-identical re-run -> NO restart churn
out=$(run_wan none "$B/stateT1.json"); rc=$?
[[ $rc -eq 0 && "$(dnsmasq_restarts)" == "0" ]] && ok "T2 identical tick -> zero restarts (no churn)" || bad "T2 restart count=$(dnsmasq_restarts) rc=$rc"
# T3: routed -> drop-in removed, exactly one restart (removal), install.sh's file untouched
out=$(run_wan ethernet "$B/stateT3.json"); rc=$?
[[ $rc -eq 0 && ! -f "$PORTAL" ]] && ok "T3 routed -> drop-in removed" || bad "T3 drop-in still present rc=$rc"
[[ "$(dnsmasq_restarts)" == "1" ]] && ok "T3 exactly one restart (toggle-off)" || bad "T3 restart count=$(dnsmasq_restarts)"
grep -qF 'interface=wlan0' "$B/dnsmasq.d/travel-router.conf" && ok "T3 install.sh-owned travel-router.conf untouched" || bad "T3 travel-router.conf clobbered"
# T4: dry-run standalone -> no drop-in, no restart (DRY_RUN discipline holds)
out=$(SYSFS_ROOT="$B/sys" TRAVELROUTER_WAN_PREFER=none TRAVELROUTER_STATE_FILE="$B/stateT4.json" \
  NFTABLES_TARGET="$B/etc/nftables.conf" DNSMASQ_CONF_DIR="$B/dnsmasq.d" TRAVELROUTER_DRY_RUN=1 \
  PATH="$B/bin:$PATH" ASSETS="$A" bash "$A/wan-select.sh" 2>&1); rc=$?
[[ $rc -eq 0 && ! -f "$PORTAL" ]] && ok "T4 dry-run -> no drop-in written" || bad "T4 dry-run wrote drop-in rc=$rc"
grep -qF 'dry-run: systemctl restart dnsmasq.service' <<<"$out" && ok "T4 dry-run logs the restart instead" || bad "T4 dry-run log missing restart line"

# --- (5c) travel-wan / status-server regression -------------------------------
sec "5c. travel-wan + status-server regression"
STUB="$B/twbin"; mkdir -p "$STUB"
printf '#!/bin/bash\ncase "$*" in *GENERAL.CONNECTION*) printf "GENERAL.CONNECTION:Hotel\\\\\"Net\\\\\\\\"; exit 0;; esac\nexit 0\n' > "$STUB/nmcli"
printf '#!/bin/bash\nif [[ "$1" == "-4" ]]; then printf "2: wlan1    inet 192.168.1.23/24 brd 192.168.1.255 scope global wlan1\\n"; exit 0; fi\nif [[ "$1" == "route" ]]; then printf "1.1.1.1 via 192.168.1.1 dev wlan1\\n"; exit 0; fi\nexit 0\n' > "$STUB/ip"
printf '#!/bin/bash\nexit 0\n' > "$STUB/curl"; printf '#!/bin/bash\nexit 0\n' > "$STUB/hostapd_cli"
printf '#!/bin/bash\nexec "$@"\n' > "$STUB/sudo"; printf '#!/bin/bash\n{ printf "%%s " "systemctl"; printf "%%s\\n" "$*"; } >> %s/tw-systemctl.log\nexit 0\n' "$B" "$B" > "$STUB/systemctl"
chmod +x "$STUB"/*
printf '{"mode":"standalone","wan_if":"","wan_ssid":"","wan_ip":"","lan_ip":"192.168.50.1","ap_interface":"wlan0"}' > "$B/tw-state.json"
out=$(NMCLI="$STUB/nmcli" IP="$STUB/ip" CURL="$STUB/curl" HOSTAPD_CLI=/nonexistent \
      TRAVELROUTER_STATE_FILE="$B/tw-state.json" bash "$A/travel-wan.sh" status --json 2>/dev/null); rc=$?
echo "$out" | python3 -m json.tool >/dev/null 2>&1 && ok "status --json parses" || bad "status JSON invalid: $out"
echo "$out" | grep -q '"mode":"standalone"' && echo "$out" | grep -q '"lan_ip":"192.168.50.1"' && echo "$out" | grep -q '"standalone":true' \
  && ok "status carries mode/lan_ip/standalone from state" || bad "status parity: $out"
printf '{"mode":"routed","wan_if":"wlan1","wan_ssid":"","wan_ip":"","lan_ip":"10.0.0.1","ap_interface":"wlan0"}' > "$B/tw-state2.json"
out=$(NMCLI="$STUB/nmcli" IP="$STUB/ip" CURL="$STUB/curl" HOSTAPD_CLI=/nonexistent \
      TRAVELROUTER_STATE_FILE="$B/tw-state2.json" bash "$A/travel-wan.sh" status --json 2>/dev/null)
echo "$out" | grep -q '"standalone":false' && echo "$out" | grep -q '"mode":"routed"' && ok "wifi-WAN status: mode=routed standalone=false" || bad "wifi status: $out"
# recheck triggers wan-select (SYSTEMCTL stub)
out=$(SUDO="$STUB/sudo" SYSTEMCTL="$STUB/systemctl" TRAVELROUTER_STATE_FILE="$B/tw-state.json" bash "$A/travel-wan.sh" recheck 2>/dev/null); rc=$?
grep -q 'start wan-select.service' "$B/tw-systemctl.log" 2>/dev/null && ok "recheck triggers wan-select" || bad "recheck: $(cat "$B/tw-systemctl.log" 2>/dev/null | head -1)"
# empty leases file must not abort status (F2 MAJOR-1 regression assert)
: > "$B/empty-leases"; mkdir -p "$B/leases-dir" 2>/dev/null || true
out=$(NMCLI="$STUB/nmcli" IP="$STUB/ip" CURL="$STUB/curl" HOSTAPD_CLI=/nonexistent \
      TRAVELROUTER_STATE_FILE="$B/tw-state.json" leases_file_override_test=1 bash -c '
        leases="/tmp/twv-leases.$$"; : > "$leases"
        # exercise the leases branch against an EMPTY file via a scratch copy
        sed "s|/var/lib/misc/dnsmasq.leases|$leases|g" "$0" > "$leases-copy.sh"
        bash "$leases-copy.sh" status --json' "$A/travel-wan.sh" 2>/dev/null); rc=$?
echo "$out" | python3 -m json.tool >/dev/null 2>&1 && ok "status survives empty leases file (F2 MAJOR-1)" || bad "empty leases aborts status: $out"
rm -f "$B/leases-copy.sh" "$B/empty-leases"
# connect missing SSID regression
SUDO="$STUB/sudo" SYSTEMCTL="$STUB/systemctl" TRAVELROUTER_STATE_FILE="$B/tw-state.json" bash "$A/travel-wan.sh" connect >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "connect missing SSID rc=2" || bad "connect regression rc≠2"
# status-server: TRAVELWAN_BIN seam + fallback seeding + routes.
# NOTE: fixture state uses lan_ip=127.0.0.1 because the server BINDS that IP;
# 192.168.50.1 is not an address on the runner (bind would fail errno 49).
printf '{"mode":"standalone","wan_if":"","wan_ssid":"","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/srv-state.json"
STW="$B/stub-travel-wan"; printf '#!/bin/bash\nprintf %s "{\\"mode\\":\\"routed\\",\\"wan_if\\":\\"wlan1\\",\\"internet\\":\\"yes\\",\\"standalone\\":false}"\n' "$B" > "$STW"; chmod +x "$STW"
TRAVELWAN_BIN="$STW" TRAVELROUTER_STATE_FILE="$B/srv-state.json" TRAVELROUTER_STATUS_PORT=18080 TRAVELROUTER_BIND_HOST=127.0.0.1 \
  python3 "$A/status-server.py" >"$B/srv.log" 2>&1 &
SPID=$!
sleep 1.5
wait_healthy 18080 || true
sc=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/health 2>/dev/null)
sjc=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/status 2>/dev/null)
sj=$(curl -s http://127.0.0.1:18080/status 2>/dev/null)
sp=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18080/status 2>/dev/null)
su=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/setup 2>/dev/null)
suad=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/admin 2>/dev/null)
suadc=$(curl -sD - -o /dev/null http://127.0.0.1:18080/admin 2>/dev/null | grep -i '^cache-control:' | head -1 | tr -d '\r' | awk '{print $2}')
  [[ "$sc" == "200" ]] && ok "status /health 200" || bad "/health=$sc (srv.log: $(tail -1 "$B/srv.log" 2>/dev/null))"
  # admin todo 1: /status is session-gated -> 401 with an auth-only body (S02)
  # (no session sent; no credentials of any kind -> 401, never 403).
  [[ "$sjc" == "401" ]] && ok "/status gated: 401 without a session" || bad "/status code=$sjc"
echo "$sj" | grep -qF '"auth"' && ! echo "$sj" | grep -qF '"mode"' \
  && ok "/status 401 body carries no device state" || bad "/status body: $sj"
[[ "$sp" == "404" || "$sp" == "405" ]] && ok "POST -> 404/405" || bad "POST code=$sp"
[[ "$su" == "404" ]] && ok "GET /setup -> 404 (S04: merged into /admin, route removed)" || bad "/setup code=$su (want 404)"
[[ "$suad" == "200" ]] && ok "GET /admin -> 200 (merged page shell)" || bad "/admin code=$suad"
[[ "$suadc" == "no-store" ]] && ok "/admin served Cache-Control: no-store" || bad "/admin cache-control=$suadc"
# XSS regression (H02): no HTML-injection path in either served page
if python3 - <<'PY' 2>/dev/null; then ok "textContent-only rendering (admin.html + status HTML)"; else bad "innerHTML/insertAdjacentHTML present in UI code"; fi
admin = open("roles/travel-router/assets/admin.html").read()
srv = open("roles/travel-router/assets/status-server.py").read()
code = admin.split("<script>")[1].split("</script>")[0]
for forbidden in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write"):
    assert forbidden not in code
# minimal status page HTML block: textContent-only, fetches /api/status
page = srv.split('_STATUS_HTML = """')[1].split('"""')[0]
assert ".innerHTML" not in page and "insertAdjacentHTML" not in page
PY
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null
# fallback seeding: dead tool -> mode/lan_ip from state still present
TRAVELWAN_BIN="/nonexistent-travel-wan" TRAVELROUTER_STATE_FILE="$B/srv-state.json" TRAVELROUTER_STATUS_PORT=18081 TRAVELROUTER_BIND_HOST=127.0.0.1 \
  python3 "$A/status-server.py" >"$B/sfb.log" 2>&1 &
SPID=$!
sleep 1.5
wait_healthy 18081 || true
# C2 (Todo 5): the fallback path feeds /status, which is session-gated —
# a no-X-Pin GET still answers 401 (session is the only GET credential since
# S02; S06 removed even the X-Pin reader, so the header is entirely inert).
sjc=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18081/status 2>/dev/null)
[[ "$sjc" == "401" ]] && ok "fallback path still session-gated (401 without any)" || bad "fallback /status code=$sjc"
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null

# --- (5d) POST API battery (H01: session gate + policy + argv contract) -------
sec "5d. status-server POST API (H01)"
# argv-logging stub: every invocation appends its argv for connect-shape asserts
STW="$B/stub-travel-wan-args"
printf '#!/bin/bash\n{ printf "%%s\\n" "$*"; } >> %s/tw-args.log\nprintf "{\\"mode\\":\\"routed\\",\\"wan_if\\":\\"wlan1\\",\\"internet\\":\\"yes\\",\\"standalone\\":false}"\n' "$B" > "$STW"
chmod +x "$STW"
SRV_STATE="$B/srv-state.json"   # lan_ip=127.0.0.1 (runner-bindable)
# Two-factor helper (Todo 6): ADMIN writes need X-Session + body.pin (S03).
# login_psk PORT PSK logs in and echoes the token on stdout (never logged).
login_psk() {
  curl -s -X POST -H 'Content-Type: application/json' \
    -H 'X-Requested-With: XMLHttpRequest' -d "{\"psk\":\"$2\"}" \
    "http://127.0.0.1:$1/api/auth/login" 2>/dev/null \
    | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p'
}
srv_case() { # method path pin ssid psk -> emits "code body" on stdout
  local method="$1" url="$2" pin="$3" ssid="$4" psk="$5" body=""
  body=$(printf '{"pin":"%s","ssid":"%s","psk":"%s"}' "$pin" "$ssid" "$psk")
  curl -s -w '\n%{http_code}' -X "$method" \
    -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
    --data-binary "$body" "http://127.0.0.1:18090${url}" 2>/dev/null
}
start_srv() { # pin -> server w/ PIN=$1 + ADMIN_PSK (Todo 6 two-factor needs both)
  TRAVELROUTER_SETUP_PIN="$1" TRAVELROUTER_ADMIN_PSK="${TESTADMIN_PSK:-AdminPass99}" \
    TRAVELWAN_BIN="$STW" TRAVELROUTER_STATE_FILE="$SRV_STATE" \
    TRAVELROUTER_STATUS_PORT=18090 TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >"$B/srv-h01.log" 2>&1 &
  SPID=$!; sleep 1.5
  wait_healthy 18090 || true
}
stop_srv() { kill $SPID 2>/dev/null; wait $SPID 2>/dev/null; : > "$B/tw-args.log" 2>/dev/null; }

# deny-by-default (S03): a client write with NO session -> 401 auth (the
# session is the credential; pin_unset survives only on ADMIN writes). The
# PIN-set server below covers the session-authorised client-write path.
start_srv ""
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"1234","ssid":"A"}' http://127.0.0.1:18090/api/wan/connect)
[[ "$r" == "401" ]] && ok "deny-by-default: no session -> write 401 (S03)" || bad "deny-by-default code=$r"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -d '{}' http://127.0.0.1:18090/api/wan/scan)
[[ "$r" == "401" ]] && ok "scan without session -> 401 auth (S03)" || bad "scan code=$r"
stop_srv

start_srv "1234"
TOK_5D=$(login_psk 18090 "${TESTADMIN_PSK:-AdminPass99}")
# S03: session authorizes a client write (PIN not required).
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $TOK_5D" -d '{"ssid":"A"}' http://127.0.0.1:18090/api/wan/connect)
[[ "$r" == "200" ]] && ok "session -> write 200 (PIN not required, S03)" || bad "session write code=$r"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -d '{"pin":"1234","ssid":"A"}' http://127.0.0.1:18090/api/wan/connect)
[[ "$r" == "401" || "$r" == "403" || "$r" == "415" ]] && ok "missing X-Requested-With rejected (CSRF guard)" || bad "CSRF code=$r"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: text/plain' \
      -H 'X-Requested-With: XMLHttpRequest' -d '{}' http://127.0.0.1:18090/api/wan/connect)
[[ "$r" == "415" ]] && ok "wrong Content-Type -> 415" || bad "ctype code=$r"
r=$(python3 -c "print('{\"pad\":\"' + 'x'*9000 + '\"}')" | curl -s -o /dev/null -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' --data-binary @- http://127.0.0.1:18090/api/wan/connect)
[[ "$r" == "413" ]] && ok "oversized body -> 413" || bad "size code=$r"
# happy path: a session authorises a client write (S03: session required;
# the body pin is ignored) -> 200, list-form argv.
TOK_5D=$(login_psk 18090 "${TESTADMIN_PSK:-AdminPass99}")
resp=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
  -H "X-Session: $TOK_5D" -d '{"pin":"1234","ssid":"HotelNet","psk":"secret1"}' http://127.0.0.1:18090/api/wan/connect)
code="${resp##*$'\n'}"
body="${resp%$'\n'*}"
[[ "$code" == "200" ]] && ok "connect happy path (session required; body pin ignored, S03) -> 200" || bad "connect code=$code resp=$resp"
grep -qF 'connect HotelNet secret1' "$B/tw-args.log" && ok "stub received list-form argv (connect ssid psk)" || bad "argv: $(cat "$B/tw-args.log" 2>/dev/null | head -1)"
grep -qF 'secret1' "$body" && bad "PSK echoed in connect response (forbidden)" || ok "no PSK in connect response"
# SSID policy: leading dash rejected before any subprocess call
: > "$B/tw-args.log"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $TOK_5D" -d '{"pin":"1234","ssid":"-evil"}' http://127.0.0.1:18090/api/wan/connect)
[[ "$r" == "400" ]] && ok "leading-dash SSID -> 400" || bad "dash ssid code=$r"
[[ ! -s "$B/tw-args.log" ]] && ok "rejected SSID never reached travel-wan" || bad "dash ssid invoked tool"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18090/status)
[[ "$r" == "404" ]] && ok "POST /status still 404" || bad "POST /status code=$r"
r=$(curl -s -o /dev/null -w '%{http_code}' -X PUT http://127.0.0.1:18090/api/wan/connect)
[[ "$r" == "404" ]] && ok "PUT /api/wan/connect 404 (only POST dispatched)" || bad "PUT code=$r"
stop_srv

# --- (5f) probe-Host 302 redirect battery (H04) -------------------------------
sec "5f. probe-Host 302 redirect (H04)"
printf '{"mode":"standalone","wan_if":"","wan_ssid":"","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/srv-state.json"
touch "$B/portal-active.conf"   # the TRAVELROUTER_PORTAL_CONF seam target
PORTAL_START() {
  TRAVELWAN_BIN="$STW" TRAVELROUTER_STATE_FILE="$B/srv-state.json" TRAVELROUTER_BIND_HOST=127.0.0.1 \
  TRAVELROUTER_STATUS_PORT=18091 TRAVELROUTER_PORTAL_CONF="$B/portal-active.conf" \
    python3 "$A/status-server.py" >"$B/srv-h04.log" 2>&1 &
  SPID=$!; sleep 1.5
  wait_healthy 18091 || true
}
PORTAL_STOP() { kill $SPID 2>/dev/null; wait $SPID 2>/dev/null; }
PORTAL_START
# R1: probe Host + active drop-in -> 302 to / (public minimal status page;
# S05 retarget — the route /setup is gone, and / is the only 200 target)
r=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: captive.apple.com' http://127.0.0.1:18091/generate_204 2>/dev/null)
loc=$(curl -s -o /dev/null -w '%{redirect_url}' -H 'Host: captive.apple.com' http://127.0.0.1:18091/generate_204 2>/dev/null)
[[ "$r" == "302" ]] && ok "R1 probe-Host GET -> 302" || bad "R1 code=$r (srv.log: $(tail -1 "$B/srv-h04.log" 2>/dev/null))"
[[ "$loc" == "http://127.0.0.1:18091/" ]] && ok "R1 Location -> / (public status page) on bound host+port" || bad "R1 location=$loc"
# R2: probe Host + INACTIVE drop-in -> no redirect (falls through to 404)
TRAVELROUTER_PORTAL_CONF="$B/does-not-exist.conf" TRAVELWAN_BIN="$STW" \
  TRAVELROUTER_STATE_FILE="$B/srv-state.json" TRAVELROUTER_STATUS_PORT=18092 TRAVELROUTER_BIND_HOST=127.0.0.1 \
  python3 "$A/status-server.py" >"$B/srv-h04b.log" 2>&1 &
SPID2=$!; sleep 1.5
wait_healthy 18092 || true
r=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: captive.apple.com' http://127.0.0.1:18092/generate_204 2>/dev/null)
kill $SPID2 2>/dev/null; wait $SPID2 2>/dev/null
[[ "$r" == "404" ]] && ok "R2 inactive drop-in -> no redirect (404)" || bad "R2 code=$r (stale-cache passthrough wrong)"
# R3: normal IP browsing unaffected while hijack active
r=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: 127.0.0.1' http://127.0.0.1:18091/ 2>/dev/null)
[[ "$r" == "200" ]] && ok "R3 Host=<bind-ip> serves status page (no redirect)" || bad "R3 code=$r"
# R4: port-suffixed probe Host still redirects
r=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: captive.apple.com:18091' http://127.0.0.1:18091/generate_204 2>/dev/null)
[[ "$r" == "302" ]] && ok "R4 Host with :port still 302" || bad "R4 code=$r"
PORTAL_STOP

# --- (5g) mandatory PIN staging battery (H05) ---------------------------------
sec "5g. mandatory PIN staging (H05)"
# unit: EnvironmentFile line present (missing-file tolerated with -)
grep -qF 'EnvironmentFile=-/run/travel-router/role-env/travel-router-setup.env' \
  "$A/travel-router-status.service" && ok "status unit declares PIN EnvironmentFile" || bad "unit missing EnvironmentFile"
# install.sh dry-run: PIN validation battery (malformed -> friendly fail rc=1)
for bad_pin in "" "123" "1234567890123" "12 4" "123-4"; do
  printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=%s\n' "$bad_pin" > "$TMP/pin.env"
  out=$(TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$TMP/pinbrk" TRAVELROUTER_ROLE_ENV="$TMP/pin.env" \
        bash "$ROOT/roles/travel-router/install.sh" 2>&1); rc=$?
  [[ $rc -eq 1 && "$out" == *"SETUP_PIN"* ]] && ok "malformed PIN '${bad_pin:-<empty>}' rejected (rc=1)" \
    || bad "PIN '${bad_pin:-<empty>}' NOT rejected (rc=$rc out=$(echo "$out" | head -1))"
done
# happy dry-run: env file staged 0600 with the PIN (fixture carries the PIN
# because install.sh sources role.env; the other PIN breakers use pin.env)
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\nTRAVELROUTER_ADMIN_PSK=AdminPass99\n' > "$TMP/pinok.env"
pfx2="$TMP/pinrun"
if TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$pfx2" TRAVELROUTER_ROLE_ENV="$TMP/pinok.env" \
   bash "$ROOT/roles/travel-router/install.sh" >"$TMP/pinrun.log" 2>&1; then ok "PIN happy dry-run rc=0"; else bad "PIN happy dry-run exited $?"; fi
envfile="$pfx2/run/travel-router/role-env/travel-router-setup.env"
[[ -f "$envfile" ]] && ok "PIN env file staged" || bad "PIN env file MISSING: $(ls "$pfx2/run/travel-router/" 2>/dev/null)"
grep -qF 'TRAVELROUTER_SETUP_PIN="9876"' "$envfile" && ok "PIN rendered into env file" || bad "PIN not in env file"
m=$(stat -f%Lp "$envfile" 2>/dev/null || stat -c%a "$envfile" 2>/dev/null)
[[ "$m" == "600" ]] && ok "PIN env file mode 0600" || bad "PIN env file mode=$m"
grep -qF '9876' "$TMP/pinrun.log" && bad "PIN leaked to install log" || ok "PIN absent from install log"
# server: pin required end-to-end (fixture server, real POST)
SRV_PIN_STATE="$B/srv-state.json"
PORTAL_START() {
  TRAVELROUTER_SETUP_PIN="2468" TRAVELROUTER_ADMIN_PSK="${TESTADMIN_PSK:-AdminPass99}" \
  TRAVELWAN_BIN="$STW" TRAVELROUTER_STATE_FILE="$SRV_PIN_STATE" \
  TRAVELROUTER_STATUS_PORT=18094 TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >"$B/srv-h05.log" 2>&1 &
  SPID=$!; sleep 1.5
  wait_healthy 18094 || true
}
PORTAL_STOP() { kill $SPID 2>/dev/null; wait $SPID 2>/dev/null; }
PORTAL_START
# S03: a client write requires a session — a wrong pin with NO session is
# 401; with a session the body pin is ignored -> 200 (pin is admin-only).
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"wrong","ssid":"A"}' http://127.0.0.1:18094/api/wan/connect)
[[ "$r" == "401" ]] && ok "5g wrong PIN, no session -> 401 (S03: session required)" || bad "5g wrong-pin code=$r"
TOK_5G=$(login_psk 18094 "${TESTADMIN_PSK:-AdminPass99}")
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $TOK_5G" -d '{"ssid":"A"}' http://127.0.0.1:18094/api/wan/connect)
[[ "$r" == "200" ]] && ok "5g session write (PIN not required) -> 200 (S03)" || bad "5g session write code=$r"
PORTAL_STOP

# --- (5h) install.sh seed battery (W01/W03) ----------------------------------
sec "5h. install.sh WAN bootstrap seed (W03) + no-seed skip"
# second dry-run WITH WIFI_* present (different fixture than run1/§2)
cat > "$TMP/seed.env" <<'EOF'
TRAVELROUTER_AP_SSID=TestNet
TRAVELROUTER_AP_PSK=TestPass123
TRAVELROUTER_SETUP_PIN=9876
TRAVELROUTER_ADMIN_PSK=AdminPass99
WIFI_SSID=SeedWifi
WIFI_PSK=SeedPass123
WIFI_COUNTRY=US
EOF
pfx3="$TMP/seedrun"
if WIFI_SSID=SeedWifi WIFI_PSK=SeedPass123 WIFI_COUNTRY=US TRAVELROUTER_DRY_RUN=1 \
   DRY_RUN_PREFIX="$pfx3" TRAVELROUTER_ROLE_ENV="$TMP/seed.env" \
   bash "$ROOT/roles/travel-router/install.sh" >"$TMP/seed.log" 2>&1; then
  ok "seed run rc=0"
else bad "seed run exited $?"; fi
grep -qF "dry-run: nmcli connection add type wifi con-name 'SeedWifi' ssid 'SeedWifi' wifi-sec.psk <redacted> connection.autoconnect yes" "$TMP/seed.log" \
  && ok "redacted dry-run nmcli line present" || bad "redacted nmcli line missing: $(grep nmcli "$TMP/seed.log" | head -1)"
grep -qF 'SeedPass123' "$TMP/seed.log" && bad "WIFI_PSK leaked to seed log" || ok "WIFI_PSK absent from seed log"
grep -qF "WAN bootstrap: 'SeedWifi' profile seeded" "$TMP/seed.log" && ok "WAN bootstrap banner present" || bad "bootstrap banner missing"

# --- (5i) AP_COUNTRY fallback (W03: TRAVELROUTER_AP_COUNTRY or WIFI_COUNTRY) ---
sec "5i. AP_COUNTRY fallback chain"
# unset TRAVELROUTER_AP_COUNTRY, WIFI_COUNTRY=DE -> rendered conf carries DE
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\nTRAVELROUTER_ADMIN_PSK=AdminPass99\nWIFI_COUNTRY=DE\n' > "$TMP/country.env"
TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$TMP/cc1" TRAVELROUTER_ROLE_ENV="$TMP/country.env" \
  bash "$ROOT/roles/travel-router/install.sh" >/dev/null 2>&1
c=$(grep -c '^country_code=DE$' "$TMP/cc1/etc/hostapd/hostapd-travel.conf")
[[ "$c" == "1" ]] && ok "unset AP_COUNTRY + WIFI_COUNTRY=DE -> country_code=DE" || bad "country_code=DE count=$c"
# explicit AP_COUNTRY wins over WIFI_COUNTRY
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\nTRAVELROUTER_ADMIN_PSK=AdminPass99\nTRAVELROUTER_AP_COUNTRY=AU\nWIFI_COUNTRY=DE\n' > "$TMP/country2.env"
TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$TMP/cc2" TRAVELROUTER_ROLE_ENV="$TMP/country2.env" \
  bash "$ROOT/roles/travel-router/install.sh" >/dev/null 2>&1
c=$(grep -c '^country_code=AU$' "$TMP/cc2/etc/hostapd/hostapd-travel.conf")
[[ "$c" == "1" ]] && ok "explicit AP_COUNTRY=AU beats WIFI_COUNTRY=DE" || bad "country_code=AU count=$c"

# --- (5j) announcer arg contract (W02, bash invocation, no server) ------------
sec "5j. nats-announce arg contract (W02)"
ANN="$ROOT/roles/base/assets/nats-announce.sh"
out=$(env -u NATS_URL -u NATS_SUBJECT_PREFIX NATS_ANNOUNCE_DRY_RUN=1 bash "$ANN" setup-complete 2>&1)
echo "$out" | grep -qF '"event":"setup-complete"' && ok "arg setup-complete -> payload event=setup-complete" || bad "setup-complete payload: $(echo "$out" | head -c 120)"
env -u NATS_URL -u NATS_SUBJECT_PREFIX NATS_ANNOUNCE_DRY_RUN=1 bash "$ANN" 'bad event' >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "invalid event arg -> rc=2" || bad "invalid event rc≠2"
out=$(env -u NATS_URL -u NATS_SUBJECT_PREFIX NATS_ANNOUNCE_DRY_RUN=1 bash "$ANN" 2>&1)
echo "$out" | grep -qF '"event":"online"' && ok "no-arg dry-run -> event=online" || bad "no-arg payload: $(echo "$out" | head -c 120)"

# --- (5k) role-setup template assert (W02) ------------------------------------
sec "5k. role-setup.service.tmpl ExecStartPost"
c=$(grep -cF 'ExecStartPost=-/usr/local/bin/rpi-nats-announce setup-complete' "$ROOT/role-setup.service.tmpl")
[[ "$c" == "1" ]] && ok "tmpl has best-effort announce ExecStartPost (1 hit)" || bad "ExecStartPost hits=$c"

# --- (5k2) role-setup NTP-wait + base clock-refuse (first-boot stale-clock) ---
sec "5k2. role-setup NTP-wait + base clock gate (first-boot stale clock)"
# Regression: Pi Zero W has no RTC; at first boot the clock may be a WRONG but
# recent year (e.g. build dated Jun 2026 booted in Sep 2026). Older base code
# used a `year >= 2025` fallback that WRONGLY accepts that clock, then apt
# fails with "Release file is not valid yet". Requirements:
#   (a) role-setup declares Wants=time-sync.target so systemd actually waits.
#   (b) base/install.sh requires real NTPSynchronized=yes and FAILS (exit 1)
#       before apt when NTP never syncs.
w=$(grep -cE 'Wants=.*time-sync\.target' "$ROOT/role-setup.service.tmpl")
[[ "$w" == "1" ]] && ok "5k2 tmpl Wants=time-sync.target" || bad "5k2 tmpl Wants=time-sync.target count=$w"
# Behavioral: with timedatectl faked to report NTPSynchronized=no forever and
# apt-get faked to leave a marker, base/install.sh must exit nonzero BEFORE
# running apt (marker must be absent). Proves the >=-year fallback is gone.
B2B="$TMP/5k2bin"; mkdir -p "$B2B"; B2APT="$TMP/5k2-apt-ran"
printf '#!/bin/bash\ntimedatectl(){ printf "no\\n"; }\nexport -f timedatectl\n' >/dev/null
cat > "$B2B/timedatectl" <<'SH'
#!/bin/bash
echo "NTPSynchronized=no"
exit 0
SH
cat > "$B2B/apt-get" <<EOF
#!/bin/bash
touch "$B2APT"
exit 0
EOF
chmod +x "$B2B/timedatectl" "$B2B/apt-get"
rm -f "$B2APT"
(cd /tmp && PATH="$B2B:$PATH" BASE_NTP_WAIT_SEC=2 NET_WAIT_SEC=0 bash "$ROOT/roles/base/install.sh" >"$TMP/5k2.log" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "5k2 base refuses when NTP never syncs (rc=$rc)" || bad "5k2 base DID NOT refuse (rc=$rc)"
[[ ! -f "$B2APT" ]] && ok "5k2 apt not reached when clock unverified" || bad "5k2 apt WAS reached (marker present)"
# Positive control: with timedatectl reporting NTPSynchronized=yes, base must
# proceed to apt (marker present, rc=0).
cat > "$B2B/timedatectl" <<'SH'
#!/bin/bash
echo "NTPSynchronized=yes"
exit 0
SH
rm -f "$B2APT"
(cd /tmp && PATH="$B2B:$PATH" BASE_NTP_WAIT_SEC=2 NET_WAIT_SEC=0 bash "$ROOT/roles/base/install.sh" >"$TMP/5k2-ok.log" 2>&1); rc2=$?
[[ -f "$B2APT" ]] && ok "5k2 base proceeds to apt when NTP synced" || bad "5k2 base did NOT proceed to apt (rc=$rc2)"
rm -rf "$B2B" "$B2APT"

# --- (5k3) apt failure path: bounded retry then HARD-FAIL (R01) ---------------
# Reproduces the field failure: apt-get exits non-zero. Asserts the R01
# contract — retry the budget, then exit non-zero (never silently succeed).
sec "5k3. apt failure path: bounded retry, then hard-fail (R01)"
# shellcheck source=/dev/null
source "$ROOT/roles/base/assets/retry.sh"

# (a) helper unit semantics: retry returns non-zero after the budget.
B3="$TMP/5k3bin"; mkdir -p "$B3"
cat > "$B3/always-fail" <<'SH'
#!/bin/bash
exit 100
SH
chmod +x "$B3/always-fail"
retry 3 0 "$B3/always-fail"; rc=$?
[[ "$rc" -ne 0 ]] && ok "5k3 retry returns non-zero after budget (rc=$rc)" \
                  || bad "5k3 retry masked a persistent failure (rc=$rc)"

# (b) success path: a step that fails twice then succeeds must return 0.
cat > "$B3/flaky.sh" <<'SH'
#!/bin/bash
c="${B3_COUNT:-/tmp/5k3-count.$$}"
n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" >"$c"
[ "$n" -ge 3 ]
SH
chmod +x "$B3/flaky.sh"
rm -f "$TMP/5k3-count"; export B3_COUNT="$TMP/5k3-count"
retry 5 0 "$B3/flaky.sh"; rc=$?
unset B3_COUNT
[[ "$rc" -eq 0 ]] && ok "5k3 retry recovers a flaky step (rc=$rc)" \
                  || bad "5k3 retry failed to recover a flaky step (rc=$rc)"
[[ "$(cat "$TMP/5k3-count" 2>/dev/null)" == "3" ]] \
  && ok "5k3 retry attempted exactly 3 times before success" \
  || bad "5k3 retry attempt count=$(cat "$TMP/5k3-count" 2>/dev/null)"

# (c) base/install.sh under a FAILING apt must exit non-zero (hard-fail),
#     after the retry budget was actually spent (3 apt-update attempts).
B3B="$TMP/5k3base-apt"; mkdir -p "$B3B"
cat > "$B3B/timedatectl" <<'SH'
#!/bin/bash
echo "NTPSynchronized=yes"
SH
cat > "$B3B/apt-get" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/5k3-apt-calls"
exit 100
EOF
chmod +x "$B3B/timedatectl" "$B3B/apt-get"
rm -f "$TMP/5k3-apt-calls"
(cd /tmp && PATH="$B3B:$PATH" BASE_NTP_WAIT_SEC=2 NET_WAIT_SEC=0 \
  RETRY_ATTEMPTS=3 RETRY_MAX_SEC=0 \
  bash "$ROOT/roles/base/install.sh" >"$TMP/5k3-base.log" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "5k3 base hard-fails when apt keeps failing (rc=$rc)" \
                  || bad "5k3 base masked persistent apt failure (rc=$rc)"
calls=$(grep -c 'update' "$TMP/5k3-apt-calls" 2>/dev/null || echo 0)
[[ "$calls" -eq 3 ]] && ok "5k3 apt update retried 3x before giving up (calls=$calls)" \
                     || bad "5k3 apt update call count=$calls (expected 3)"

# (d) R02 knob: base references NET_WAIT_SEC (advisory net-wait present).
grep -q 'NET_WAIT_SEC' "$ROOT/roles/base/install.sh" \
  && ok "5k3 base has the R02 network-wait knob" \
  || bad "5k3 base is missing NET_WAIT_SEC (R02)"

# --- (5l) provisioner gating asserts (W01, structural) ------------------------
sec "5l. provisioner WIFI_* gating (W01)"
for pf in provision.sh provision-bookworm.sh; do
  grep -qF 'if [[ "$ROLE" == "travel-router" ]]; then' "$ROOT/$pf" \
    && ok "$pf has travel-router gate" || bad "$pf MISSING travel-router gate"
  grep -qF 'for var in WIFI_SSID WIFI_PSK WIFI_COUNTRY; do' "$ROOT/$pf" \
    && ok "$pf has gated WIFI_* emission loop" || bad "$pf MISSING WIFI_* emission loop"
done

# --- (5m) PSK-leak guard across all new-run logs ------------------------------
sec "5m. PSK-leak guard (whole temp dir)"
hits=$(grep -rl 'SeedPass123' "$TMP" 2>/dev/null | grep -v '\.env$' | grep -v '/seedrun/etc/hostapd/hostapd-travel.conf$' || true)
[[ -z "$hits" ]] && ok "SeedPass123 only in rendered hostapd conf" || bad "SeedPass123 elsewhere: $(echo "$hits" | tr '\n' ' ')"

# --- (5n) store-seeding battery (M8-a) ----------------------------------------
sec "5n. install.sh known-psks store seeding (M8-a)"
# macOS runner has no /sys/class/net, so travel-wan connect never passes the
# iface gate. These batteries assert STORE FILE CONTENTS ONLY (never rc).
# Seed 1: TRAVELROUTER_DEFAULT_PSKS="alpha,beta" -> fresh store with 2 d-rows.
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\nTRAVELROUTER_ADMIN_PSK=AdminPass99\nTRAVELROUTER_DEFAULT_PSKS=alpha,beta\n' > "$TMP/pskseed.env"
pfxn="$TMP/pskseed"
if TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$pfxn" TRAVELROUTER_ROLE_ENV="$TMP/pskseed.env" \
   bash "$ROOT/roles/travel-router/install.sh" >"$TMP/pskseed.log" 2>&1; then
  ok "5n seed dry-run rc=0"
else bad "5n seed dry-run exited $?"; fi
STORE="$pfxn/etc/rpi-project/travel-router/known-psks"
[[ -f "$STORE" ]] && ok "5n known-psks store staged" || bad "5n known-psks store MISSING (seeding unimplemented)"
if [[ -f "$STORE" ]]; then
  m=$(stat -f%Lp "$STORE" 2>/dev/null || stat -c%a "$STORE" 2>/dev/null)
  [[ "$m" == "600" ]] && ok "5n store mode 0600" || bad "5n store mode=$m"
  dn=$(grep -c $'^d\t\talpha$' "$STORE"); [[ "$dn" == "1" ]] && ok "5n d-row alpha" || bad "5n d-row alpha count=$dn"
  dn=$(grep -c $'^d\t\tbeta$'  "$STORE"); [[ "$dn" == "1" ]] && ok "5n d-row beta"  || bad "5n d-row beta count=$dn"
  sn=$(grep -c $'^s\t' "$STORE");         [[ "$sn" == "0" ]] && ok "5n zero s-rows" || bad "5n s-rows=$sn (must be none)"
fi
# Seed 2: pre-existing s-row survives re-seed; d-rows replaced by new defaults.
mkdir -p "$pfxn/etc/rpi-project/travel-router"
printf 's\tHotelNet\toldpsk\n' > "$STORE"; chmod 600 "$STORE"
if TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$pfxn" TRAVELROUTER_ROLE_ENV="$TMP/pskseed.env" \
   TRAVELROUTER_DEFAULT_PSKS="gamma" bash "$ROOT/roles/travel-router/install.sh" >"$TMP/pskseed2.log" 2>&1; then
  ok "5n re-seed dry-run rc=0"
else bad "5n re-seed dry-run exited $?"; fi
if [[ -f "$STORE" ]]; then
  c=$(grep -c $'^s\tHotelNet\toldpsk$' "$STORE"); [[ "$c" == "1" ]] && ok "5n HotelNet s-row intact across re-seed" || bad "5n s-row clobbered (c=$c)"
  dn=$(grep -c $'^d\t' "$STORE"); [[ "$dn" == "1" ]] && grep -q $'^d\t\tgamma$' "$STORE" \
    && ok "5n re-seed d-rows replaced (exactly gamma)" || bad "5n re-seed d-rows=$dn (want 1: gamma)"
  m=$(stat -f%Lp "$STORE" 2>/dev/null || stat -c%a "$STORE" 2>/dev/null)
  [[ "$m" == "600" ]] && ok "5n store mode 0600 after re-seed" || bad "5n re-seed mode=$m"
fi

# --- (5o) candidate-cap + TAB rejection battery (M8-b) -------------------------
sec "5o. travel-wan psk-store cap + TAB-SSID rejection (M8-b)"
# Seam TRAVELROUTER_PSK_FILE does not exist yet in travel-wan.sh — that is
# the point of this RED battery. Never assert connect rc (iface gate fails
# on this runner by design); assert STORE CONTENTS only.
TWENV=(NMCLI="$STUB/nmcli" IP="$STUB/ip" CURL="$STUB/curl" HOSTAPD_CLI=/nonexistent
       SUDO="$STUB/sudo" SYSTEMCTL="$STUB/systemctl" TRAVELROUTER_STATE_FILE="$B/tw-state.json")
PSKSTORE="$B/cand-store"; : > "$PSKSTORE"
PSKCAP="$B/cap-caps"; : > "$PSKCAP"; PSKCERR="$B/cap-caps.err"; : > "$PSKCERR"
for i in 1 2 3 4 5; do
  env "${TWENV[@]}" TRAVELROUTER_PSK_FILE="$PSKSTORE" bash "$A/travel-wan.sh" \
    connect TestNet "capk${i}x" >>"$PSKCAP" 2>>"$PSKCERR"
done
sc=$(grep -c $'^s\tTestNet\t' "$PSKSTORE")
[[ "$sc" == "4" ]] && ok "5o cap: exactly 4 s-rows for TestNet (4/SSID)" || bad "5o s-rows=$sc (want 4)"
c=$(grep -c $'capk1x' "$PSKSTORE"); [[ "$c" == "0" ]] && ok "5o oldest psk (capk1x) evicted" || bad "5o capk1x still present"
env "${TWENV[@]}" TRAVELROUTER_PSK_FILE="$PSKSTORE" bash "$A/travel-wan.sh" \
  connect $'Bad\tNet' somepsk >>"$PSKCAP" 2>>"$PSKCERR"
c=$(grep -c $'Bad' "$PSKSTORE"); [[ "$c" == "0" ]] && ok "5o TAB SSID never lands in store" || bad "5o TAB SSID row present (count=$c)"

# --- (5p) default-fallback order battery (M8-c) --------------------------------
sec "5p. travel-wan try-psks fallback order (M8-c)"
PSKP="$B/order-store"
printf 's\tA\tpsk1order\ns\tA\tpsk2order\nd\t\tpskdflt\n' > "$PSKP"
ARGVLOG="$B/order-argv.log"; : > "$ARGVLOG"
STWP="$B/stub-tw-order"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %s\nexit 1\n' "$ARGVLOG" > "$STWP"; chmod +x "$STWP"
env "${TWENV[@]}" NMCLI="$STWP" TRAVELROUTER_PSK_FILE="$PSKP" bash "$A/travel-wan.sh" try-psks A \
  >"$B/order-out" 2>"$B/order-err"
l1=$(grep -n 'psk1order' "$ARGVLOG" | head -1 | cut -d: -f1)
l2=$(grep -n 'psk2order' "$ARGVLOG" | head -1 | cut -d: -f1)
l3=$(grep -n 'pskdflt' "$ARGVLOG" | head -1 | cut -d: -f1)
[[ -n "$l1" && -n "$l2" && -n "$l3" && "$l1" -lt "$l2" && "$l2" -lt "$l3" ]] \
  && ok "5p order: psk1order < psk2order < pskdflt in argv" \
  || bad "5p try order wrong (l1=$l1 l2=$l2 l3=$l3)"

# --- (5q) auto-collect dedup battery (M8-d) ------------------------------------
sec "5q. connect auto-collect dedup (M8-d)"
# Contract: distinct psk values for one SSID ACCUMULATE (up to cap 4 —
# see 5o); re-collecting a value ALREADY stored must NOT duplicate it
# (value-dedup); open-network connects store nothing.
DEDUP="$B/dedup-store"; : > "$DEDUP"
env "${TWENV[@]}" TRAVELROUTER_PSK_FILE="$DEDUP" bash "$A/travel-wan.sh" connect DedupNet dedup1A >>"$PSKCAP" 2>>"$PSKCERR"
dr=$(grep -c $'^s\tDedupNet\t' "$DEDUP"); [[ "$dr" == "1" ]] && grep -q $'^s\tDedupNet\tdedup1A$' "$DEDUP" \
  && ok "5q first psk collected (1 row)" || bad "5q first collect rows=$dr (want 1)"
env "${TWENV[@]}" TRAVELROUTER_PSK_FILE="$DEDUP" bash "$A/travel-wan.sh" connect DedupNet dedup1B >>"$PSKCAP" 2>>"$PSKCERR"
dr=$(grep -c $'^s\tDedupNet\t' "$DEDUP"); [[ "$dr" == "2" ]] && grep -q $'^s\tDedupNet\tdedup1A$' "$DEDUP" && grep -q $'^s\tDedupNet\tdedup1B$' "$DEDUP" \
  && ok "5q distinct second psk accumulates (2 rows, both kept)" || bad "5q after 2nd collect rows=$dr (want 2)"
env "${TWENV[@]}" TRAVELROUTER_PSK_FILE="$DEDUP" bash "$A/travel-wan.sh" connect DedupNet dedup1A >>"$PSKCAP" 2>>"$PSKCERR"
dr=$(grep -c $'^s\tDedupNet\t' "$DEDUP"); da=$(grep -c $'^s\tDedupNet\tdedup1A$' "$DEDUP")
[[ "$dr" == "2" && "$da" == "1" ]] \
  && ok "5q re-collect of stored value dedups (still 2 rows, no dup)" || bad "5q re-collect rows=$dr dupA=$da (want 2/1)"
env "${TWENV[@]}" TRAVELROUTER_PSK_FILE="$DEDUP" bash "$A/travel-wan.sh" connect OpenNet >>"$PSKCAP" 2>>"$PSKCERR"
or=$(grep -c $'^s\tOpenNet\t' "$DEDUP"); [[ "$or" == "0" ]] \
  && ok "5q open-network connect stores no psk" || bad "5q OpenNet s-rows=$or"

# --- (5r) scan-parse fixture battery (M8-e) ------------------------------------
sec "5r. scan row splitter contract (M8-e)"
# (1) structural: admin.html (S04 merge) must declare the escape-aware SSID
# splitter.
grep -q 'escape-aware SSID splitter' "$A/admin.html" \
  && ok "5r admin.html escape-aware SSID splitter marker" \
  || bad "5r admin.html splitter marker MISSING (S04 merge)"
# (2) behavioral: python replica pins the splitter contract.
# DRIFT RISK: this replica must be updated in lockstep with the JS splitter
# in admin.html (and the travel-wan scan row format) — if one changes, both
# must change. Escaped chars pass through; unescaped colon splits.
if python3 - <<'PY'
def split_row(row):
    out = []; cur = ""
    i = 0
    while i < len(row):
        ch = row[i]
        if ch == "\\" and i + 1 < len(row):
            cur += row[i + 1]; i += 2; continue
        if ch == ":":
            out.append(cur); cur = ""
        else:
            cur += ch
        i += 1
    out.append(cur)
    return out

assert split_row("My\\:Net:75:WPA2")[:3] == ["My:Net", "75", "WPA2"]
assert split_row("Back\\\\slash:80:")[:3] == ["Back\\slash", "80", ""]
assert split_row(":55:WPA3")[:3] == ["", "55", "WPA3"]
PY
then ok "5r splitter replica: 3 fixture rows parse per contract"
else bad "5r splitter replica contract broken"; fi

# --- (5s) scan stderr + sort expression battery (M8-f) ------------------------
sec "5s. scan pipeline: stderr kept out + signal sort (M8-f)"
# Structural, scoped to the cmd_scan function (lines between 'cmd_scan()' and
# the next function/section at top level), NOT the whole file: other sections
# legitimately use 2>&1 (e.g. the online probe).
scan_start=$(grep -n '^cmd_scan()' "$A/travel-wan.sh" | cut -d: -f1)
scan_end=$(awk -v s="$scan_start" 'NR>s && /^[a-zA-Z_]+\(\)/ {print NR; exit}' "$A/travel-wan.sh")
[[ -n "$scan_start" && -n "$scan_end" ]] || scan_end=$((scan_start+12))
if sed -n "${scan_start},${scan_end}p" "$A/travel-wan.sh" | grep -q '2>&1'; then
  bad "5s scan merges stderr into row stream (2>&1 in cmd_scan)"
else ok "5s scan pipeline keeps stderr out of rows"; fi
if sed -n "${scan_start},${scan_end}p" "$A/travel-wan.sh" | grep -q 'sort -t: -k2 -nr'; then
  ok "5s sort expression: sort -t: -k2 -nr"
else bad "5s sort expression wrong (want sort -t: -k2 -nr)"; fi
# Behavioral: the sort expression orders rows by signal descending.
srt=$(printf 'Aaa:40:WPA2\nZzz:90:WPA2\n' | sort -t: -k2 -nr | head -1)
[[ "$srt" == "Zzz:90:WPA2" ]] && ok "5s behavioral: signal sort puts strongest first" \
  || bad "5s behavioral sort wrong: $srt"

# --- (5t) known-psks endpoint policy matrix (M8-g) ----------------------------
sec "5t. /api/wan/known + /api/wan/psks policy (M8-g)"
# NOTE: state fixture MUST bind lan_ip 127.0.0.1 (server binds it; errno 49
# otherwise). pkill any stale server before starting ours.
pkill -f status-server.py 2>/dev/null; sleep 0.3
printf '{"mode":"standalone","wan_if":"","wan_ssid":"FixtureNet","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/srv-state.json"
STWT="$B/stub-travel-wan-t"
printf '#!/bin/bash\ncase "$1" in try-psks) exit 0;; known) printf "FixtureNet\\t1697100000\\tyes\\n"; exit 0;; esac\nprintf "{\\"mode\\":\\"routed\\",\\"wan_if\\":\\"wlan1\\",\\"internet\\":\\"yes\\",\\"standalone\\":false}"\n' > "$STWT"; chmod +x "$STWT"
KNOWN_STATE="$B/known-state.json"; cp "$B/srv-state.json" "$KNOWN_STATE"
TRAVELWAN_PSK_STORE="$B/known-fixture-store"
printf 's\tFixtureNet\tsup3rsecret\n' > "$TRAVELWAN_PSK_STORE"
start_known_srv() { # pin -> server w/ PIN=$1 + ADMIN_PSK + the fixture store
  TRAVELROUTER_SETUP_PIN="$1" TRAVELROUTER_ADMIN_PSK="${TESTADMIN_PSK:-AdminPass99}" \
  TRAVELWAN_BIN="$STWT" TRAVELROUTER_STATE_FILE="$KNOWN_STATE" \
  TRAVELWAN_PSK_STORE="$TRAVELWAN_PSK_STORE" \
  TRAVELROUTER_STATUS_PORT=18095 TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >"$B/srv-m8g.log" 2>&1 &
  SPID=$!; sleep 1.5
  wait_healthy 18095 || true
}
stop_known_srv() { kill $SPID 2>/dev/null; wait $SPID 2>/dev/null; sleep 0.3; }
# gate (S03): client writes are session-gated FIRST — on a PIN-unset router a
# session-less write 401s (provisioning state is not revealed to strangers);
# a session holder's client write succeeds (PIN is not a client-write
# credential anymore; pin_unset survives only on ADMIN writes).
start_known_srv ""
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"1234","ssid":"X"}' http://127.0.0.1:18095/api/wan/psks)
[[ "$r" == "401" ]] && ok "5t POST psks PIN-unset router, no session -> 401 auth (S03)" || bad "5t no-session code=$r (want 401)"
TOK_5TU=$(login_psk 18095 "${TESTADMIN_PSK:-AdminPass99}")
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $TOK_5TU" -d '{"ssid":"X"}' http://127.0.0.1:18095/api/wan/psks)
[[ "$r" == "200" ]] && ok "5t POST psks PIN-unset + session -> 200 (PIN not a client-write credential, S03)" || bad "5t PIN-unset+sess code=$r (want 200)"
stop_known_srv
# with the PIN set: a wrong body.pin is IGNORED on client writes (the session
# is the credential, S03); the CSRF guard (missing X-Requested-With) still
# rejects before any session/pin check.
start_known_srv "1234"
TOK_5T=$(login_psk 18095 "${TESTADMIN_PSK:-AdminPass99}")
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $TOK_5T" -d '{"pin":"9","ssid":"X"}' http://127.0.0.1:18095/api/wan/psks)
[[ "$r" == "200" ]] && ok "5t POST psks wrong pin + session -> 200 (pin ignored on client writes, S03)" || bad "5t wrong-pin code=$r (want 200)"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H "X-Session: $TOK_5T" -d '{"pin":"1234","ssid":"X"}' http://127.0.0.1:18095/api/wan/psks)
[[ "$r" == "403" ]] && ok "5t POST psks missing X-Requested-With -> 403" || bad "5t csrf code=$r (want 403)"
# GET /api/wan/known (S03): session-gated — no/garbage X-Session -> 401
# (Connection: close pinned via -D -), correct X-Session -> 200 rows JSON.
resp=$(curl -s -w '\n%{http_code}' http://127.0.0.1:18095/api/wan/known 2>/dev/null)
code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
[[ "$code" == "401" ]] && echo "$body" | grep -q '"auth"' \
  && ok "5t GET /api/wan/known without X-Session -> 401 {\"error\":\"auth\"}" \
  || bad "5t known no-sess: [$code|$(echo "$body" | head -c 60)]"
kconn=$(curl -s -D - -o /dev/null http://127.0.0.1:18095/api/wan/known 2>/dev/null | tr -d '\r')
echo "$kconn" | grep -qi '^connection: close$' \
  && ok "5t known 401 carries Connection: close" || bad "5t known 401 missing Connection: close: $(echo "$kconn" | head -3 | tr '\n' '|')"
resp=$(curl -s -w '\n%{http_code}' -H 'X-Session: bogus' http://127.0.0.1:18095/api/wan/known 2>/dev/null)
code="${resp##*$'\n'}"
[[ "$code" == "401" ]] && ok "5t GET /api/wan/known bogus X-Session -> 401" || bad "5t known bogus-sess code=$code (want 401)"
resp=$(curl -s -w '\n%{http_code}' -H "X-Session: $TOK_5T" http://127.0.0.1:18095/api/wan/known 2>/dev/null)
code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
[[ "$code" == "200" ]] && ok "5t GET /api/wan/known + X-Session -> 200" || bad "5t known+sess code=$code (want 200)"
echo "$body" | grep -q 'FixtureNet' && ok "5t known body carries SSID" || bad "5t known body missing SSID: $(echo "$body" | head -c 120)"
echo "$body" | grep -q 'sup3rsecret' && bad "5t known body LEAKS psk (forbidden)" || ok "5t known body free of psk"
# POST /api/wan/psks happy path: session required (S03)
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $TOK_5T" -d '{"ssid":"X"}' http://127.0.0.1:18095/api/wan/psks)
[[ "$r" == "200" ]] && ok "5t POST psks happy path (session) -> 200 (S03)" || bad "5t POST psks happy code=$r (want 200)"
# GET /api/wan/psks -> 404 (read forbidden; policy assert, passes now)
r=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18095/api/wan/psks 2>/dev/null)
[[ "$r" == "404" ]] && ok "5t GET /api/wan/psks -> 404" || bad "5t GET psks code=$r"
# POST /status -> 404 parity re-assert
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18095/status 2>/dev/null)
[[ "$r" == "404" ]] && ok "5t POST /status -> 404 (parity)" || bad "5t POST /status code=$r"
# PUT/PATCH/DELETE /api/wan/psks -> 404 each
for verb in PUT PATCH DELETE; do
  r=$(curl -s -o /dev/null -w '%{http_code}' -X "$verb" http://127.0.0.1:18095/api/wan/psks 2>/dev/null)
  [[ "$r" == "404" ]] && ok "5t $verb /api/wan/psks -> 404" || bad "5t $verb psks code=$r"
done
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null
pkill -f status-server.py 2>/dev/null; sleep 0.3

# --- (5u) PSK-leak sweep for battery fixture psks (M8-h) -----------------------
sec "5u. battery-psk leak sweep (M8-h)"
# Scope: whole battery temp dir — M8 battery captures (§5n-§5t) live under
# $B, install dry-runs under $TMP. Excludes: the psk store files themselves,
# the argv-log stub (transport under test), .env/role.env fixtures.
leak_hits=""
for p in capk1x capk2x capk3x capk4x capk5x psk1order psk2order pskdflt dedup1A dedup1B oldpsk sup3rsecret; do
  h=$(grep -rl "$p" "$TMP" 2>/dev/null \
      | grep -v '/cand-store$' | grep -v '/dedup-store$' | grep -v '/order-store$' \
      | grep -v '/known-fixture-store$' | grep -v '/pskseed/etc/rpi-project/travel-router/known-psks$' \
      | grep -v '/order-argv.log$' | grep -v '\.env$' || true)
  [[ -n "$h" ]] && leak_hits="$leak_hits $p:$(echo "$h" | tr '\n' ' ')"
done
[[ -z "$leak_hits" ]] && ok "5u no battery psks leaked into logs/captures" \
  || bad "5u leaks:$leak_hits"

# --- (5v) .psksecret staging + d-row merge battery (setup-v2 M4) ---------------
sec "5v. .psksecret staging + merge (setup-v2)"
# Contract: install.sh stages <prefix>/etc/rpi-project/travel-router/psksecret
# (0600) from TRAVELROUTER_PSKSECRET_FILE (or the role-tree .psksecret, same
# two-path idiom as ROLE_ENV at install.sh:64-67) and merges file-sourced
# d-rows into known-psks alongside env TRAVELROUTER_DEFAULT_PSKS (env first,
# file appended, no dupes). Absent file -> skip + no file d-rows.
printf '# setup-v2 battery\n\n0123456789\nwelcome\nguestwifi\n' > "$TMP/psksecret-a"
pfxv="$TMP/pskv-run1"
if TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$pfxv" TRAVELROUTER_ROLE_ENV="$TMP/pskseed.env" \
   TRAVELROUTER_PSKSECRET_FILE="$TMP/psksecret-a" \
   bash "$ROOT/roles/travel-router/install.sh" >"$TMP/pskv-run1.log" 2>&1; then
  ok "5v psksecret dry-run rc=0"
else bad "5v psksecret dry-run exited $?"; fi
S5V="$pfxv/etc/rpi-project/travel-router/psksecret"
STORE5V="$pfxv/etc/rpi-project/travel-router/known-psks"
[[ -f "$S5V" ]] && ok "5v psksecret staged" || bad "5v psksecret MISSING (staging unimplemented)"
if [[ -f "$S5V" ]]; then
  m=$(stat -f%Lp "$S5V" 2>/dev/null || stat -c%a "$S5V" 2>/dev/null)
  [[ "$m" == "600" ]] && ok "5v psksecret mode 0600" || bad "5v psksecret mode=$m (want 600)"
else bad "5v psksecret mode skipped (file missing)"; fi
c=$(grep -c $'^d\t\t0123456789$' "$STORE5V" 2>/dev/null || true)
[[ "$c" == "1" ]] && ok "5v file-sourced d-row 0123456789 present" || bad "5v 0123456789 d-row count=$c (want 1)"
c=$(grep -c $'^d\t' "$STORE5V" 2>/dev/null || true)
[[ "$c" == "5" ]] && ok "5v merge: 5 d-rows (env alpha,beta + file 3, comment/blank skipped)" || bad "5v d-row count=$c (want 5)"
# (b) no-dupe merge: env gamma + file gamma -> exactly one gamma d-row
printf 'gamma\n' > "$TMP/psksecret-b"
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\nTRAVELROUTER_ADMIN_PSK=AdminPass99\nTRAVELROUTER_DEFAULT_PSKS=gamma\n' > "$TMP/pskv-b.env"
pfxvb="$TMP/pskv-run-b"
TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$pfxvb" TRAVELROUTER_ROLE_ENV="$TMP/pskv-b.env" \
  TRAVELROUTER_DEFAULT_PSKS="gamma" TRAVELROUTER_PSKSECRET_FILE="$TMP/psksecret-b" \
  bash "$ROOT/roles/travel-router/install.sh" >"$TMP/pskv-b.log" 2>&1
STORE5VB="$pfxvb/etc/rpi-project/travel-router/known-psks"
c=$(grep -c $'^d\t\tgamma$' "$STORE5VB" 2>/dev/null || true)
[[ "$c" == "1" ]] && ok "5v no-dupe merge: exactly one gamma d-row" || bad "5v gamma d-row count=$c (want 1)"
# (c) second install preserves s-row, refreshes d-rows env-first + file-appended
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\nTRAVELROUTER_ADMIN_PSK=AdminPass99\nTRAVELROUTER_DEFAULT_PSKS=gamma\n' > "$TMP/pskv-c.env"
pfxvc="$TMP/pskv-run-c"
TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$pfxvc" TRAVELROUTER_ROLE_ENV="$TMP/pskv-c.env" \
  TRAVELROUTER_DEFAULT_PSKS="gamma" TRAVELROUTER_PSKSECRET_FILE="$TMP/psksecret-c" \
  bash "$ROOT/roles/travel-router/install.sh" >"$TMP/pskv-c1.log" 2>&1
STORE5VC="$pfxvc/etc/rpi-project/travel-router/known-psks"
printf 's\tKeepNet\toldpsk\n' > "$STORE5VC"
printf 'guestwifi\n' > "$TMP/psksecret-c2"
TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$pfxvc" TRAVELROUTER_ROLE_ENV="$TMP/pskv-c.env" \
  TRAVELROUTER_DEFAULT_PSKS="gamma" TRAVELROUTER_PSKSECRET_FILE="$TMP/psksecret-c2" \
  bash "$ROOT/roles/travel-router/install.sh" >"$TMP/pskv-c2.log" 2>&1
c=$(grep -c $'^s\tKeepNet\toldpsk$' "$STORE5VC" 2>/dev/null || true)
[[ "$c" == "1" ]] && ok "5v re-run preserves s-row" || bad "5v s-row clobbered (count=$c)"
c=$(grep -c $'^d\t' "$STORE5VC" 2>/dev/null || true)
[[ "$c" == "2" ]] && ok "5v refresh: exactly 2 d-rows (gamma + guestwifi)" || bad "5v d-row count=$c (want 2)"
l1=$(grep -n $'^d\t\tgamma$' "$STORE5VC" 2>/dev/null | head -1 | cut -d: -f1)
l2=$(grep -n $'^d\t\tguestwifi$' "$STORE5VC" 2>/dev/null | head -1 | cut -d: -f1)
[[ -n "$l1" && -n "$l2" && "$l1" -lt "$l2" ]] && ok "5v env-first file-appended order" || bad "5v d-row order l1=$l1 l2=$l2"
# (d) gitignore
grep -q '^\.psksecret$' "$ROOT/.gitignore" && ok "5v .psksecret gitignored" || bad "5v .gitignore missing ^\.psksecret$"
# (e) TAB in psksecret -> rc=1 remediation
printf 'bad\tvalue\n' > "$TMP/psksecret-e"
pfxve="$TMP/pskv-run-e"
TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$pfxve" TRAVELROUTER_ROLE_ENV="$TMP/pskv-c.env" \
  TRAVELROUTER_PSKSECRET_FILE="$TMP/psksecret-e" \
  bash "$ROOT/roles/travel-router/install.sh" >"$TMP/pskv-e.log" 2>&1
rcve=$?
[[ "$rcve" -eq 1 ]] && grep -q 'remediation:' "$TMP/pskv-e.log" \
  && ok "5v TAB PSK rejected rc=1 + remediation" || bad "5v TAB rc=$rcve (want 1 + remediation)"

# --- (5w) psks-manage + apconfig battery (setup-v2 M5/M8) ----------------------
sec "5w. psks-manage verbs + endpoints + apconfig (setup-v2)"
# CLI part: real travel-wan.sh against a fresh store (stub nmcli/sudo, §5o idiom)
PSKV="$B/v2-store"; : > "$PSKV"
twrun() {
  env "${TWENV[@]}" TRAVELROUTER_PSK_FILE="$PSKV" bash "$A/travel-wan.sh" \
    "$1" "${2:-}" "${3:-}" >>"$PSKCAP" 2>>"$PSKCERR"
}
twrun psks-add TestNet capkA >/dev/null 2>&1
c=$(grep -c $'^s\tTestNet\tcapkA$' "$PSKV" 2>/dev/null || true)
[[ "$c" == "1" ]] && ok "5w psks-add s-row stored" || bad "5w psks-add row count=$c (want 1)"
twrun psks-add TestNet capkA >/dev/null 2>&1
c=$(grep -c $'^s\tTestNet\tcapkA$' "$PSKV" 2>/dev/null || true)
[[ "$c" == "1" ]] && ok "5w psks-add dedup (still 1 row)" || bad "5w dedup count=$c (want 1)"
twrun psks-add-default dfltA >/dev/null 2>&1
c=$(grep -c $'^d\t\tdfltA$' "$PSKV" 2>/dev/null || true)
[[ "$c" == "1" ]] && ok "5w psks-add-default d-row stored" || bad "5w add-default count=$c (want 1)"
twrun psks-add-default dfltA >/dev/null 2>&1
c=$(grep -c $'^d\t\tdfltA$' "$PSKV" 2>/dev/null || true)
[[ "$c" == "1" ]] && ok "5w psks-add-default dedup" || bad "5w add-default dedup count=$c (want 1)"
twrun psks-list >/dev/null 2>&1
l=$(TRAVELROUTER_PSK_FILE="$PSKV" env "${TWENV[@]}" bash "$A/travel-wan.sh" psks-list 2>/dev/null)
echo "$l" | grep -q $'^s\tTestNet\tcapkA$' && echo "$l" | grep -q $'^d\t\tdfltA$' \
  && ok "5w psks-list prints TYPE<TAB>SSID<TAB>PSK rows" || bad "5w psks-list output wrong: $(echo "$l" | head -2)"
twrun psks-del 1 >/dev/null 2>&1
c=$(grep -c $'capkA' "$PSKV" 2>/dev/null || true)
[[ "$c" == "0" ]] && ok "5w psks-del removed row 1" || bad "5w del row1 count=$c (want 0)"
grep -q $'^d\t\tdfltA$' "$PSKV" && ok "5w psks-del keeps remaining rows" || bad "5w del lost dfltA"
TRAVELROUTER_PSK_FILE="$PSKV" env "${TWENV[@]}" bash "$A/travel-wan.sh" psks-del 99 >>"$PSKCAP" 2>>"$PSKCERR"
[[ $? -ne 0 ]] && ok "5w psks-del 99 -> rc!=0" || bad "5w del 99 should fail"
printf 's\tOtherNet\tzzz\n' > "$PSKV"; chmod 000 "$PSKV"
TRAVELROUTER_PSK_FILE="$PSKV" env "${TWENV[@]}" bash "$A/travel-wan.sh" psks-list >>"$PSKCAP" 2>>"$PSKCERR"
[[ $? -ne 0 ]] && ok "5w psks-list unreadable store degrades rc!=0" || bad "5w unreadable store rc=0"
chmod 600 "$PSKV"
# endpoint part: live server on 18096 (§5t pattern: PIN 1234 + ADMIN_PSK,
# stub ap-apply exit 0)
pkill -f status-server.py 2>/dev/null; sleep 0.3
STWV2="$B/stub-travel-wan-v2"
printf '#!/bin/bash\ncase "$1" in try-psks) exit 0;; ap-apply) exit 0;; psks-list) printf "s\\tX\\tpk1\\nd\\t\\tdk\\n"; exit 0;; known) printf "X\\t1\\tyes\\n"; exit 0;; esac\nexit 1\n' > "$STWV2"; chmod +x "$STWV2"
KNOWN_STATE2="$B/known-state2.json"
printf '{"mode":"standalone","wan_if":"","wan_ssid":"","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$KNOWN_STATE2"
TRAVELROUTER_SETUP_PIN="1234" TRAVELROUTER_ADMIN_PSK="${TESTADMIN_PSK:-AdminPass99}" \
  TRAVELWAN_BIN="$STWV2" TRAVELROUTER_STATE_FILE="$KNOWN_STATE2" \
  TRAVELROUTER_STATUS_PORT=18096 TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >"$B/srv-v2.log" 2>&1 &
SPID=$!; sleep 1.5
wait_healthy 18096 || true
TOK_5W=$(login_psk 18096 "${TESTADMIN_PSK:-AdminPass99}")
# GET psks-manage (admin todo 1): admin read — session-gated: no session ->
# 401, bogus -> 401, valid session -> 200 rows JSON carrying no psk key.
r=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18096/api/wan/psks-manage)
[[ "$r" == "401" ]] && ok "5w GET psks-manage no session -> 401" || bad "5w no-session code=$r (want 401)"
r=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Session: bogus' http://127.0.0.1:18096/api/wan/psks-manage)
[[ "$r" == "401" ]] && ok "5w GET psks-manage bogus session -> 401" || bad "5w bogus-session code=$r"
r=$(curl -s -w '\n%{http_code}' -H "X-Session: $TOK_5W" http://127.0.0.1:18096/api/wan/psks-manage 2>/dev/null)
code="${r##*$'\n'}"; body="${r%$'\n'*}"
[[ "$code" == "200" ]] && ok "5w GET psks-manage + session -> 200" || bad "5w GET code=$code (want 200)"
echo "$body" | grep -q 'psks-secret-fixture' && bad "5w GET body leaks fixture psk" || ok "5w GET body clean of fixture psk"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert 'rows' in d and isinstance(d['rows'], list); assert all('psk' not in row for row in d['rows'])" "$body" 2>/dev/null \
  && ok "5w GET rows carry no psk key" || bad "5w GET rows contain psk key or bad JSON"
# write verbs (admin todo 1: psks-manage is an ADMIN write — session stays
# required): wrong pin WITH session -> 403 pin; session+pin happy -> 200
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $TOK_5W" -d '{"pin":"9","action":"add","ssid":"S","psk":"p"}' http://127.0.0.1:18096/api/wan/psks-manage)
[[ "$r" == "403" ]] && ok "5w POST psks-manage wrong pin (session held) -> 403" || bad "5w wrong-pin code=$r (want 403)"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $TOK_5W" -d '{"pin":"1234","action":"add","ssid":"S","psk":"p"}' http://127.0.0.1:18096/api/wan/psks-manage)
[[ "$r" == "200" ]] && ok "5w POST psks-manage add (session+pin) -> 200" || bad "5w POST add code=$r (want 200)"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $TOK_5W" -d '{"pin":"1234","ssid":"NewName","psk":"newpsk9x"}' http://127.0.0.1:18096/api/wan/apconfig)
[[ "$r" == "200" ]] && ok "5w POST apconfig happy (session+pin) -> 200" || bad "5w apconfig code=$r (want 200)"
# security todo 10: a SUCCESSFUL apconfig with a new SSID rotates the session
# salt — TOK_5W is dead by design now. Re-login for the shape asserts below.
TOK_5W=$(login_psk 18096 "${TESTADMIN_PSK:-AdminPass99}")
[[ -n "$TOK_5W" ]] && ok "5w re-login after the salt rotation (security todo 10)" \
  || bad "5w re-login after rotate failed"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $TOK_5W" -d '{"pin":"1234","ssid":"a|b","psk":"newpsk9"}' http://127.0.0.1:18096/api/wan/apconfig)
[[ "$r" == "400" ]] && ok "5w apconfig render-breaker ssid -> 400" || bad "5w render-breaker code=$r (want 400)"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $TOK_5W" -d '{"pin":"1234","ssid":"NewName","psk":"short"}' http://127.0.0.1:18096/api/wan/apconfig)
[[ "$r" == "400" ]] && ok "5w apconfig short psk -> 400" || bad "5w short-psk code=$r (want 400)"
r=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18096/api/wan/apconfig 2>/dev/null)
[[ "$r" == "404" ]] && ok "5w GET apconfig -> 404" || bad "5w GET apconfig code=$r"
for verb in PUT PATCH DELETE; do
  r=$(curl -s -o /dev/null -w '%{http_code}' -X "$verb" http://127.0.0.1:18096/api/wan/psks-manage 2>/dev/null)
  [[ "$r" == "404" ]] && ok "5w $verb psks-manage -> 404" || bad "5w $verb psks-manage code=$r"
done
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null
pkill -f status-server.py 2>/dev/null; sleep 0.3

# --- (5ap) client/admin credential split + /admin route (admin plan T1/T2) -----
sec "5ap. client/admin gate split + /admin route (admin-split Todos 1-2)"
# Posture under test (admin plan Todo 1, exhaustive classification):
#   CLIENT (session-only since S03; the PIN is never consulted):
#     GET reads + POST client verbs (session-gated since S03; X-Pin inert),
#     POST /api/wan/status is a client READ twin of GET /status).
#   ADMIN (X-Session via PSK login; body.pin additionally on writes):
#     /api/wan/{psks-manage,apconfig} writes, GET /api/wan/psks-manage,
#     GET /api/wan/log, and all future /api/admin/*.
# No session -> 401 (client and admin alike); a wrong body.pin on an ADMIN
# write -> 403 feeding the shared per-IP _PIN_FAILS throttle. The legacy
# (5c/5d/5g/5t/5ac2/5ac3/5ak) still pin the OLD posture and are rewritten to
# this one in admin plan todo 8 — this section pins the NEW posture only.
pkill -f status-server.py 2>/dev/null; sleep 0.3
printf '{"mode":"standalone","wan_if":"","wan_ssid":"FixtureNet","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/srv-state.json"
STWAP="$B/stub-travel-wan-ap"
printf '#!/bin/bash\ncase "$1" in scan) printf "A\\t1\\t50\\tWPA2\\tHotelNet\\n"; exit 0;; known) printf "HotelNet\\t1690000000\\tyes\\n"; exit 0;; psks-list) printf "s\\tX\\tpk1\\n"; exit 0;; esac\nexit 1\n' > "$STWAP"; chmod +x "$STWAP"
APLOG="$B/ap-split.txt"
: > "$APLOG"
echo "=== 5ap client/admin split transcript ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ===" >> "$APLOG"
ap_start() { # port -> fresh server (fresh in-memory throttle state)
  TRAVELROUTER_SETUP_PIN="1234" TRAVELROUTER_ADMIN_PSK="${TESTADMIN_PSK:-AdminPass99}" \
  TRAVELWAN_BIN="$STWAP" TRAVELROUTER_STATE_FILE="$B/srv-state.json" \
  TRAVELROUTER_STATUS_PORT="$1" TRAVELROUTER_BIND_HOST=127.0.0.1 \
    python3 "$A/status-server.py" >>"$B/srv-ap.log" 2>&1 &
  APPID=$!
  wait_healthy "$1" || true
}
ap_stop() { kill "$APPID" 2>/dev/null; wait "$APPID" 2>/dev/null; }
ap_post() { # path json [extra-curl-args...] -> "code|body" (X-Requested-With on)
  # ${@:3}: $1/$2 must NOT reach curl — a bare '{}' arg is a URL-glob abort.
  local resp
  resp=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
    -H 'X-Requested-With: XMLHttpRequest' "${@:3}" -d "$2" \
    "http://127.0.0.1:18110$1" 2>/dev/null)
  echo "POST $1 -> ${resp##*$'\n'}" >> "$APLOG"
  echo "${resp##*$'\n'}|${resp%$'\n'*}"
}
ap_get() { # path [extra-curl-args...] -> "code|body"
  # ${@:2}: $1 must NOT reach curl (it would be fetched as a bogus first URL).
  local resp
  resp=$(curl -s -w '\n%{http_code}' "${@:2}" "http://127.0.0.1:18110$1" 2>/dev/null)
  echo "GET $1 -> ${resp##*$'\n'}" >> "$APLOG"
  echo "${resp##*$'\n'}|${resp%$'\n'*}"
}
ap_start 18110
TOK_5AP=$(login_psk 18110 "${TESTADMIN_PSK:-AdminPass99}")
# (A) GET bucket (S03): X-Session is the credential; X-Pin alone -> 401
apx=$(ap_get /status -H 'X-Pin: 1234')
[[ "$apx" == 401*'"auth"'* ]] \
  && ok "5ap GET /status + X-Pin, NO session -> 401 (PIN alone insufficient, S02)" || bad "5ap /status+pin: [$apx]"
apx=$(ap_get /status)
[[ "$apx" == 401*'"auth"'* ]] \
  && ok "5ap GET /status absent X-Pin -> 401 (not 403)" || bad "5ap /status no-pin: [$apx]"
apx=$(ap_get /status -H "X-Session: $TOK_5AP")
[[ "$apx" == 200*'"mode"'* ]] \
  && ok "5ap GET /status + X-Session -> 200 (session is the credential, S02)" || bad "5ap /status+session: [$apx]"
apx=$(ap_get /api/wan/known -H 'X-Pin: 1234')
[[ "$apx" == 401*'"auth"'* ]] \
  && ok "5ap GET /api/wan/known + X-Pin, NO session -> 401 (PIN alone insufficient, S03)" || bad "5ap known+pin: [$apx]"
apx=$(ap_get /api/wan/known)
[[ "$apx" == 401*'"auth"'* ]] \
  && ok "5ap GET /api/wan/known absent X-Pin -> 401" || bad "5ap known no-pin: [$apx]"
apx=$(ap_get /api/wan/known -H "X-Session: $TOK_5AP")
[[ "$apx" == 200*'"known"'* ]] \
  && ok "5ap GET /api/wan/known + session -> 200 (S03: session is the credential)" \
  || bad "5ap known sess: [$apx]"
# (B) client POST bucket (S03): session on every verb, CSRF header still mandatory
apx=$(ap_post /api/wan/status '{"pin":"1234"}')
[[ "$apx" == 401*'"auth"'* ]] \
  && ok "5ap POST /api/wan/status body.pin, NO session -> 401 (S03: session required)" \
  || bad "5ap POST status: [$apx]"
apx=$(ap_post /api/wan/status '{}' -H "X-Session: $TOK_5AP")
[[ "$apx" == 200*'"mode"'* ]] \
  && ok "5ap POST /api/wan/status + X-Session -> 200 (S03: session is the credential)" \
  || bad "5ap POST status+sess: [$apx]"
apx=$(ap_post /api/wan/scan '{"pin":"1234"}')
[[ "$apx" == 401*'"auth"'* ]] \
  && ok "5ap POST /api/wan/scan body.pin, NO session -> 401 (S03)" || bad "5ap POST scan: [$apx]"
apx=$(ap_post /api/wan/scan '{}' -H "X-Session: $TOK_5AP")
[[ "$apx" == 200*'"lines"'* ]] \
  && ok "5ap POST /api/wan/scan + X-Session -> 200 (S03)" || bad "5ap POST scan+sess: [$apx]"
for ep in connect psks disconnect forget recheck; do
  apx=$(ap_post "/api/wan/$ep" '{"pin":"1234","ssid":"HotelNet"}')
  [[ "$apx" == 401*'"auth"'* ]] \
    && ok "5ap POST /api/wan/$ep body.pin, NO session -> 401 (S03)" || bad "5ap POST $ep: [$apx]"
  apx=$(ap_post "/api/wan/$ep" '{"ssid":"HotelNet"}' -H "X-Session: $TOK_5AP")
  [[ "$apx" == 200*'"ok"'* ]] \
    && ok "5ap POST /api/wan/$ep + X-Session -> 200 (S03)" || bad "5ap POST $ep+sess: [$apx]"
done
apx=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d '{"pin":"1234","ssid":"HotelNet"}' http://127.0.0.1:18110/api/wan/connect 2>/dev/null)
[[ "$apx" == "403" ]] \
  && ok "5ap POST connect WITHOUT X-Requested-With -> 403 (CSRF kept)" \
  || bad "5ap csrf client write code=$apx (want 403)"
# (C) admin bucket reads: session required, pin irrelevant on reads
apx=$(ap_get /api/wan/psks-manage)
[[ "$apx" == 401*'"auth"'* ]] \
  && ok "5ap GET psks-manage no session -> 401 (admin read)" || bad "5ap pm no-sess: [$apx]"
apx=$(ap_get /api/wan/log)
[[ "$apx" == 401*'"auth"'* ]] \
  && ok "5ap GET /api/wan/log no session -> 401 (admin read)" || bad "5ap log no-sess: [$apx]"
apx=$(ap_get /api/wan/psks-manage -H "X-Session: $TOK_5AP")
[[ "$apx" == 200*'"rows"'* ]] \
  && ok "5ap GET psks-manage + session -> 200 rows" || bad "5ap pm+sess: [$apx]"
apx=$(ap_get /api/wan/log -H "X-Session: $TOK_5AP")
[[ "$apx" == 200*'"log"'* ]] \
  && ok "5ap GET /api/wan/log + session -> 200 (degrades to empty array)" || bad "5ap log+sess: [$apx]"
# (D) admin bucket writes: session FIRST (401 without), then body.pin (403)
apx=$(ap_post /api/wan/psks-manage '{"pin":"1234","action":"add","ssid":"S","psk":"p"}')
[[ "$apx" == 401*'"auth"'* ]] \
  && ok "5ap POST psks-manage NO session -> 401 (admin write, pin alone insufficient)" \
  || bad "5ap pm no-sess write: [$apx]"
apx=$(ap_post /api/wan/apconfig '{"pin":"1234","ssid":"NewName","psk":"newpsk9x"}')
[[ "$apx" == 401*'"auth"'* ]] \
  && ok "5ap POST apconfig NO session -> 401 (admin write)" || bad "5ap apcfg no-sess: [$apx]"
apx=$(ap_post /api/wan/psks-manage '{"action":"add","ssid":"S","psk":"p"}' -H "X-Session: $TOK_5AP")
[[ "$apx" == 403*'"pin"'* ]] \
  && ok "5ap POST psks-manage session, no pin -> 403 pin" || bad "5ap pm no-pin: [$apx]"
apx=$(ap_post /api/wan/apconfig '{"pin":"9","ssid":"NewName","psk":"newpsk9x"}' -H "X-Session: $TOK_5AP")
[[ "$apx" == 403*'"pin"'* ]] \
  && ok "5ap POST apconfig session, wrong pin -> 403 pin" || bad "5ap apcfg wrong-pin: [$apx]"
apx=$(ap_post /api/wan/psks-manage '{"pin":"1234","action":"add","ssid":"S","psk":"p"}' -H "X-Session: $TOK_5AP")
[[ "$apx" == 200*'"ok"'* ]] \
  && ok "5ap POST psks-manage session+pin -> 200 envelope" || bad "5ap pm happy: [$apx]"
apx=$(ap_post /api/wan/apconfig '{"pin":"1234","ssid":"NewName","psk":"newpsk9x"}' -H "X-Session: $TOK_5AP")
[[ "$apx" == 200*'"ok"'* ]] \
  && ok "5ap POST apconfig session+pin -> 200 envelope" || bad "5ap apcfg happy: [$apx]"
# (E) /admin route (todo 2): distinct unauthenticated page shell, no-store
apx=$(ap_get /admin)
adm_code="${apx%%|*}"; adm_body="${apx#*|}"
[[ "$adm_code" == "200" ]] \
  && ok "5ap GET /admin -> 200 (page loads unauthenticated; S04 owns the admin UI)" \
  || bad "5ap /admin code=$adm_code"
[[ "$adm_body" == *'id="admin-page"'* ]] \
  && ok "5ap /admin body carries the admin-page marker" || bad "5ap /admin marker missing"
apx=$(ap_get /admin/)
[[ "$apx" == 200* ]] && ok "5ap GET /admin/ (trailing slash) -> 200" || bad "5ap /admin/ code=${apx%%|*}"
apx=$(ap_get /setup)
su_code="${apx%%|*}"
[[ "$su_code" == "404" ]] \
  && ok "5ap GET /setup -> 404 (S04: route removed, merged into /admin)" || bad "5ap /setup code=$su_code (want 404)"
ahdr=$(curl -s -D - -o /dev/null http://127.0.0.1:18110/admin 2>/dev/null | tr -d '\r')
echo "$ahdr" | grep -qi '^cache-control: no-store$' \
  && ok "5ap /admin carries Cache-Control: no-store" || bad "5ap /admin cache hdr: $(echo "$ahdr" | head -3 | tr '\n' '|')"
# (F) /status is session-gated (S02): X-Pin is irrelevant, session required
ap_stop
pkill -f status-server.py 2>/dev/null; sleep 0.3
ap_start 18111
apg() { curl -s -o /dev/null -w '%{http_code}' -H "X-Pin: $1" http://127.0.0.1:18111/status 2>/dev/null; }
apg_session() { curl -s -o /dev/null -w '%{http_code}' -H "X-Session: $TOK_5AP" http://127.0.0.1:18111/status 2>/dev/null; }
# Without a session, X-Pin is irrelevant — all variants -> 401
apg_codes=""
for i in 1 2 3 4 5; do apx=$(apg "wrong$i"); apg_codes="$apg_codes$apx "; done
echo "--- 5 wrong X-Pin GETs (no session): $apg_codes" >> "$APLOG"
[[ "$apg_codes" == "401 401 401 401 401 " ]] \
  && ok "5ap 5 wrong X-Pin GETs w/o session -> 401 x5 (PIN irrelevant, S02)" \
  || bad "5ap wrong-GET codes=[$apg_codes]"
# With a valid session, /status returns 200 regardless of X-Pin
apx=$(apg_session)
[[ "$apx" == "200" ]] \
  && ok "5ap GET /status + valid session -> 200 (session is the credential)" \
  || bad "5ap session GET code=$apx (want 200)"
ap_stop
pkill -f status-server.py 2>/dev/null; sleep 0.3
grep -q '1234' "$APLOG" && bad "5ap PIN leaked into split transcript (forbidden)" \
  || ok "5ap transcript free of PIN"

# --- (5x) exclusions + UI contract battery (setup-v2 M2/M3/M6/M7/M1) -----------
sec "5x. profile exclusions + UI contracts (setup-v2)"
# (a) cmd_known excludes preconfigured + tr-probe (Brook must survive).
printf 'preconfigured:802-11-wireless:1697100000:yes\nBrook:802-11-wireless:1697000000:no\ntr-probe:802-11-wireless:1696000000:yes\n' > "$B/v2-nmcli-in"
printf '#!/bin/bash\ncat "%s"\n' "$B/v2-nmcli-in" > "$B/v2-stub-nmcli"; chmod +x "$B/v2-stub-nmcli"
known_out=$(NMCLI="$B/v2-stub-nmcli" TRAVELROUTER_STATE_FILE="$B/tw-state.json" bash "$A/travel-wan.sh" known 2>/dev/null)
echo "$known_out" | grep -q $'^Brook\t' && ! echo "$known_out" | grep -q 'preconfigured' \
  && ! echo "$known_out" | grep -q 'tr-probe' \
  && ok "5x known excludes preconfigured + tr-probe, keeps Brook" || bad "5x exclusion wrong: $(echo "$known_out" | head -3 | tr '\n' '|')"
# (b) cmd_scan self-SSID guard: structural seam assert (iface gate blocks the
# runner, so the contract is the seam reference inside cmd_scan's body)
scan_start=$(grep -n '^cmd_scan()' "$A/travel-wan.sh" | cut -d: -f1)
scan_end=$(awk -v s="$scan_start" 'NR>s && /^[a-zA-Z_]+\(\)/ {print NR; exit}' "$A/travel-wan.sh")
[[ -n "$scan_start" && -n "$scan_end" ]] || scan_end=$((scan_start+12))
if sed -n "${scan_start},${scan_end}p" "$A/travel-wan.sh" | grep -q 'AP_SSID_FILE'; then
  ok "5x scan references AP_SSID_FILE (self-SSID guard seam)"
else bad "5x scan self-SSID guard MISSING (AP_SSID_FILE not referenced in cmd_scan)"; fi
# (c) UI contracts — S04: the setup.html battery re-points to admin.html,
# which now carries the scan/known/manual-connect UI.
grep -q '<dialog' "$A/admin.html" && ok "5x native dialog present" || bad "5x <dialog MISSING (setup-v2 M7)"
grep -q 'escape-aware SSID splitter' "$A/admin.html" \
  && ok "5x escape-aware splitter marker stays" || bad "5x splitter marker LOST"
if python3 - <<'PY'
code = open("roles/travel-router/assets/admin.html").read().split("<script>")[1].split("</script>")[0]
for forbidden in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write"):
    assert forbidden not in code, forbidden
PY
then ok "5x XSS forbidden list stays clean"; else bad "5x XSS forbidden list violated"; fi
anchor=$(grep -n -F 'api("/api/wan/psks"' "$A/admin.html" | head -1 | cut -d: -f1)
found=0
if [[ -n "$anchor" ]]; then
  seg=$(sed -n "$((anchor)),$((anchor+15))p" "$A/admin.html")
  echo "$seg" | grep -q 'd.log' && found=1
fi
[[ "$found" == "1" ]] && ok "5x psks handler renders d.log fallback (scoped)" \
  || bad "5x psks handler d.log fallback MISSING (rc=1 diagnostics opaque)"
# admin todo 1: psks-manage lives on the ADMIN page (S04: setup.html is gone).
grep -q 'psks-manage' "$A/admin.html" && ok "5x psks-manage referenced (admin page)" || bad "5x psks-manage MISSING from admin.html"
[[ -f "$A/setup.html" ]] && bad "5x setup.html still exists (S04: merged into /admin)" || ok "5x setup.html removed (S04)"
# S04 structural: the merged admin page carries the setup-page sections.
grep -qF 'WiFi networks' "$A/admin.html" \
  && ok "5x S04 admin.html WiFi networks section present" || bad "5x S04 WiFi networks section MISSING"
grep -qF 'Known networks' "$A/admin.html" \
  && ok "5x S04 admin.html Known networks section present" || bad "5x S04 Known networks section MISSING"
grep -qF 'Connect manually' "$A/admin.html" \
  && ok "5x S04 admin.html Connect manually section present" || bad "5x S04 Connect manually section MISSING"
grep -qF 'net-dialog' "$A/admin.html" \
  && ok "5x S04 admin.html connect dialog present" || bad "5x S04 connect dialog MISSING"
grep -qF 'Try saved passwords' "$A/admin.html" \
  && ok "5x S04 admin.html Try saved passwords present" || bad "5x S04 Try saved passwords MISSING"

# --- (5y) setup-v2 psk leak sweep (M8-h extension) -----------------------------
sec "5y. setup-v2 psk leak sweep"
# Extends the §5u family to the setup-v2 fixture psks; runs AFTER §5v-§5x so
# the new fixture files exist. Excludes: psk stores, staged psksecret copies,
# fixture psksecret sources, argv logs, .env fixtures, and the staged
# status-server.py copies (install dry-runs stage product source whose
# _random_ap_psk alphabet literal contains "0123456789" — a code constant
# shipped to the Pi, never a log/capture of a fixture PSK).
leak_hits2=""
for p in capkA dfltA psks-secret-fixture 0123456789 welcome guestwifi gamma guestwifi2 oldpsk; do
  h=$(grep -rl "$p" "$TMP" 2>/dev/null \
      | grep -v '/v2-store$' | grep -v '/psksecret-a$' | grep -v '/psksecret-b$' \
      | grep -v '/psksecret-c$' | grep -v '/psksecret-c2$' | grep -v '/psksecret-e$' \
      | grep -v '/travel-router/psksecret$' | grep -v '/known-psks$' \
      | grep -v '/order-argv.log$' | grep -v '/v2-argv' | grep -v '\.env$' \
      | grep -v '/cap-caps' | grep -v '/cap-caps.err' \
      | grep -v '/status-server\.py$' || true)
  [[ -n "$h" ]] && leak_hits2="$leak_hits2 $p:$(echo "$h" | tr '\n' ' ')"
done
[[ -z "$leak_hits2" ]] && ok "5y no setup-v2 psks leaked into logs/captures" \
  || bad "5y leaks:$leak_hits2"

# --- (5z) hostapd conf file modes (hardening C3) -------------------------------
sec "5z. hostapd-travel.conf 0600 (install render + ap-apply lifecycle)"

# (1) install.sh render: the rendered conf must land 0600 even under a lax umask.
c3="$TMP/c3"; mkdir -p "$c3"
if ( umask 022
     TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$c3/pfx" TRAVELROUTER_ROLE_ENV="$TMP/role.env" \
       bash "$ROOT/roles/travel-router/install.sh" >"$c3/install.log" 2>&1 ); then
  m=$(stat -f%Lp "$c3/pfx/etc/hostapd/hostapd-travel.conf" 2>/dev/null || stat -c%a "$c3/pfx/etc/hostapd/hostapd-travel.conf" 2>/dev/null)
  [[ "$m" == "600" ]] && ok "5z install render conf 0600 (umask 022)" || bad "5z install conf mode=$m (want 600)"
else bad "5z install render run exited nonzero"; fi
# Negative control: a bare render (no chmod) stays 644 under umask 022 — proves
# the 600 assertion above is load-bearing on this runner, not vacuous.
( umask 022; sed -e "s|__AP_INTERFACE__|uap0|g" "$A/hostapd.conf.tmpl" >"$c3/bare.conf" )
m=$(stat -f%Lp "$c3/bare.conf" 2>/dev/null || stat -c%a "$c3/bare.conf" 2>/dev/null)
[[ "$m" == "644" ]] && ok "5z control: bare render is 644 (assertion not vacuous)" || bad "5z control bare mode=$m (want 644)"

# (2) cmd_ap_apply success path. HOSTAPD_BIN is a stub that stats the probe
# copy (and the sibling .bak) DURING the parse-probe call — capturing their
# modes while they exist, before the mv/rm removes them (stale-state guard).
# The probe passes the probe-copy path as $1; derive the candidate tmp conf
# path from it (strip ".probe.<pid>") to observe the candidate's mode too.
c3stat="$c3/stat-stub.sh"
cat > "$c3stat" <<'EOF'
#!/bin/bash
# parse-probe stub: record probe (and sibling .bak) modes while they exist.
f="${1:-}"
[[ -f "$f" ]] && printf 'tmp %s\n' "$(stat -f%Lp "$f" 2>/dev/null || stat -c%a "$f" 2>/dev/null)" >>"$MODELOG"
ap="${f%.probe.*}"
[[ -f "$ap.bak" ]] && printf 'bak %s\n' "$(stat -f%Lp "$ap.bak" 2>/dev/null || stat -c%a "$ap.bak" 2>/dev/null)" >>"$MODELOG"
exit 0
EOF
chmod +x "$c3stat"
printf '#!/bin/bash\nexit 0\n' > "$c3/restart-ok.sh";  chmod +x "$c3/restart-ok.sh"
printf '#!/bin/bash\nexit 1\n' > "$c3/restart-fail.sh"; chmod +x "$c3/restart-fail.sh"
# sudo passthrough: execs its args so the SYSTEMCTL stub actually runs
# (bare `true` ignores argv — the §5o suite uses the same sudo-stub idiom).
printf '#!/bin/bash\nexec "$@"\n' > "$c3/sudo.sh"; chmod +x "$c3/sudo.sh"
# The restart stub stats $AP_CONF.bak DURING its lifetime: at restart time the
# cp+chmod have run and the rm happens only after a successful restart, so a
# logged `bak 600` proves the unconditional .bak chmod (stale-state guard).
mk_restart_stub() {  # $1 = stub path, $2 = exit code
  { printf '#!/bin/bash\n'
    printf 'case "$1" in\n'
    printf '  is-active) echo active; exit 0 ;;\n'
    printf '  show) echo running; exit 0 ;;\n'
    printf 'esac\n'
    printf 'ap="${TRAVELROUTER_AP_CONF:?}"\n'
    printf '[[ -f "$ap.bak" ]] && printf '"'"'bak %%s\\n'"'"' "$(stat -f%%Lp "$ap.bak" 2>/dev/null || stat -c%%a "$ap.bak" 2>/dev/null)" >>"$MODELOG"\n'
    printf 'exit %s\n' "$2"
  } > "$1"; chmod +x "$1"
}
mk_restart_stub "$c3/restart-ok.sh" 0
mk_restart_stub "$c3/restart-fail.sh" 1
mkdir -p "$c3/ap-etc" "$c3/ctrl"
# Fixture conf declares ctrl_interface (rendered template carries the line);
# the liveness poll needs the socket present, so pre-create it in a fixture
# ctrl dir and pair it with a hostapd_cli stub: the poll treats a socket whose
# hostapd does not report ENABLED as a DOWN radio (see _ap_radio_up).
: > "$c3/ctrl/uap0"
# hostapd_cli stubs. -enabled reports the interface up; -preenable reports the
# COUNTRY_UPDATE state the socket appears in, which is NOT up.
# Key shape copied from real hostapd 2.10 AP-mode `status` on rpi-8e21bb:
# the interface state is a BARE `state=` key, with no wpa_state/interface_state
# anywhere in the output. Stubs that invent a longer spelling would let the
# suite pass against a key the daemon never emits.
cat > "$c3/hostapd-cli-enabled.sh" <<'EOF'
#!/bin/bash
# -p must name the ctrl socket DIRECTORY and -i the interface. A -p aimed at
# the socket file is a non-directory, so a real hostapd_cli answers an empty
# status and every rename rolls back — refuse to pretend that is "up".
[[ "$1" == "-p" && -d "$2" ]] || { echo "stub: -p must be a socket DIR (got '$2')" >&2; exit 3; }
printf 'state=ENABLED\nphy=phy0\nfreq=2437\nchannel=6\nssid[0]=NewNet\nnum_sta[0]=0\n'
exit 0
EOF
cat > "$c3/hostapd-cli-preenable.sh" <<'EOF'
#!/bin/bash
[[ "$1" == "-p" && -d "$2" ]] || { echo "stub: -p must be a socket DIR (got '$2')" >&2; exit 3; }
printf 'state=COUNTRY_UPDATE\nphy=phy0\nfreq=2437\nchannel=6\nssid[0]=NewNet\n'
exit 0
EOF
chmod +x "$c3/hostapd-cli-enabled.sh" "$c3/hostapd-cli-preenable.sh"
# Fixture live conf is deliberately 0644 so the 600 asserts below prove the
# chmods ran (a 0644->0644 no-op would pass vacuously).
printf 'interface=uap0\nssid=OldNet\n' > "$c3/ap-etc/hostapd-travel.conf"
chmod 0644 "$c3/ap-etc/hostapd-travel.conf"
printf 'OldNet\n' > "$c3/ap-ssid"
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_AP_COUNTRY=US\nTRAVELROUTER_AP_CHANNEL=6\nTRAVELROUTER_AP_INTERFACE=uap0\nTRAVELROUTER_ADMIN_PSK=AdminPass99\n' > "$c3/role.env"
c3aprun() {  # $1 = MODELOG target, $2 = SYSTEMCTL stub, $3 = hostapd_cli stub (default: reports ENABLED)
  ( umask 022
    export TRAVELROUTER_AP_CONF="$c3/ap-etc/hostapd-travel.conf"
    export TRAVELROUTER_AP_TEMPLATE="$A/hostapd.conf.tmpl"
    export TRAVELROUTER_HOSTAPD_BIN="$c3stat"
    export TRAVELROUTER_AP_SSID_FILE="$c3/ap-ssid"
    export TRAVELROUTER_CTRL_DIR="$c3/ctrl"
    export TRAVELROUTER_APCONFIG_LOG="$c3/apconfig.log"
    export TRAVELROUTER_AP_UP_TIMEOUT=2
    export HOSTAPD_CLI="${3:-$c3/hostapd-cli-enabled.sh}"
    export SUDO="$c3/sudo.sh" SYSTEMCTL="$2" MODELOG="$1"
    export TRAVELROUTER_AP_SSID=TestNet TRAVELROUTER_AP_PSK=TestPass123 TRAVELROUTER_AP_INTERFACE=uap0
    set -- ap-apply NewNet NewPass456
    source "$A/travel-wan.sh"
  )
}
: > "$c3/modes1.log"
c3aprun "$c3/modes1.log" "$c3/restart-ok.sh" >"$c3/ap1.out" 2>"$c3/ap1.err"
rc=$?
[[ $rc -eq 0 ]] && ok "5z ap-apply success rc=0" || bad "5z ap-apply rc=$rc (want 0)"
grep -q '^tmp 600$' "$c3/modes1.log" \
  && ok "5z rendered tmp conf was 0600 while alive (parse-probe stat)" \
  || bad "5z tmp conf mode during life not 600: $(tr '\n' ' ' <"$c3/modes1.log" 2>/dev/null)"
grep -q '^bak 600$' "$c3/modes1.log" \
  && ok "5z .bak was 0600 while it existed (stub stat during lifetime)" \
  || bad "5z .bak mode during life not 600: $(tr '\n' ' ' <"$c3/modes1.log" 2>/dev/null)"
m=$(stat -f%Lp "$c3/ap-etc/hostapd-travel.conf" 2>/dev/null || stat -c%a "$c3/ap-etc/hostapd-travel.conf" 2>/dev/null)
[[ "$m" == "600" ]] && ok "5z installed conf 0600 after mv (644 fixture overwritten)" || bad "5z final conf mode=$m (want 600)"
[[ ! -e "$c3/ap-etc/hostapd-travel.conf.bak" ]] && ok "5z .bak removed on success path" || bad "5z .bak still present on success"
m=$(stat -f%Lp "$c3/ap-ssid" 2>/dev/null || stat -c%a "$c3/ap-ssid" 2>/dev/null)
[[ "$m" == "600" ]] && ok "5z ap-ssid file stays 0600" || bad "5z ap-ssid mode=$m (want 600)"

# (3) restart-failure path: the 0600 .bak is mv'd back over the conf — the
# restored conf must be 0600 (proves the .bak chmod is unconditional).
: > "$c3/modes2.log"
printf 'interface=uap0\nssid=OldNet\n' > "$c3/ap-etc/hostapd-travel.conf"
chmod 0644 "$c3/ap-etc/hostapd-travel.conf"
rc=0
c3aprun "$c3/modes2.log" "$c3/restart-fail.sh" >"$c3/ap2.out" 2>"$c3/ap2.err" || rc=$?
[[ $rc -eq 1 ]] && ok "5z ap-apply restart-fail rc=1" || bad "5z fail path rc=$rc (want 1)"
m=$(stat -f%Lp "$c3/ap-etc/hostapd-travel.conf" 2>/dev/null || stat -c%a "$c3/ap-etc/hostapd-travel.conf" 2>/dev/null)
[[ "$m" == "600" ]] && ok "5z restored conf 0600 (bak chmod unconditional)" || bad "5z restored conf mode=$m (want 600)"

# (4) REGRESSION (field bug): a ctrl socket that exists while hostapd still
# reports the interface COUNTRY_UPDATE is a DOWN radio, not an up one. The
# apply must fail AND leave the pre-rename conf in place. Socket presence used
# to return 0 and consume $AP_CONF.bak, so a radio that failed moments later
# had nothing to roll back to and the AP stayed down until a re-flash.
: > "$c3/modes3.log"
printf 'interface=uap0\nssid=OldNet\n' > "$c3/ap-etc/hostapd-travel.conf"
chmod 0644 "$c3/ap-etc/hostapd-travel.conf"
# Reset the live-SSID record to match the conf: the rollback restores whatever
# was in this file BEFORE the apply, so it has to be seeded, not inherited
# from the previous test.
printf 'OldNet\n' > "$c3/ap-ssid"
rc=0
c3aprun "$c3/modes3.log" "$c3/restart-ok.sh" "$c3/hostapd-cli-preenable.sh" >"$c3/ap3.out" 2>"$c3/ap3.err" || rc=$?
[[ $rc -eq 1 ]] \
  && ok "5z socket-present-but-not-ENABLED -> rc=1 (no false 'up')" \
  || bad "5z pre-enable apply rc=$rc (want 1)"
grep -q '^ssid=OldNet$' "$c3/ap-etc/hostapd-travel.conf" \
  && ok "5z pre-rename conf survives a false-up apply (ssid=OldNet)" \
  || bad "5z conf lost the pre-rename backup: $(grep -c '^ssid=NewNet$' "$c3/ap-etc/hostapd-travel.conf" 2>/dev/null) NewNet line(s)"
# The live-SSID record must be rolled back WITH the conf. Left holding the
# aborted SSID, ap-info reports a name that is not broadcasting and the next
# psk-only change renders the aborted rename for real - found on rpi-8e21bb.
grep -q '^OldNet$' "$c3/ap-ssid" 2>/dev/null \
  && ok "5z ap-ssid rolled back with the conf after a failed apply" \
  || bad "5z ap-ssid left holding the aborted SSID: $(head -1 "$c3/ap-ssid" 2>/dev/null)"
grep -q 'no AP-ENABLED within' "$c3/apconfig.log" 2>/dev/null \
  && ok "5z durable apconfig log records the not-ENABLED verdict" \
  || bad "5z apconfig.log missing the not-ENABLED verdict line"
# The failure line must carry what hostapd_cli actually said, so a poll that
# never ENABLED can be told apart from a poll that never reached the CLI.
grep -q 'last_hostapd_cli_status=.*COUNTRY_UPDATE' "$c3/apconfig.log" 2>/dev/null \
  && ok "5z failure log captures what hostapd_cli actually reported" \
  || bad "5z failure log lacks the captured hostapd_cli status: $(grep -o 'last_hostapd_cli_status=.*' "$c3/apconfig.log" 2>/dev/null | tail -1)"
grep -q 'rollback' "$c3/apconfig.log" 2>/dev/null \
  && ok "5z durable apconfig log records the rollback attempt" \
  || bad "5z apconfig.log missing a rollback line"
# The success path must still consume the .bak, and must say so in the log.
grep -q 'OK: AP verified beaconing' "$c3/apconfig.log" 2>/dev/null \
  && ok "5z durable apconfig log records the verified-beaconing success" \
  || bad "5z apconfig.log missing the verified-beaconing line"

# --- (5aa) scan/status POST desync: connection closed, no smuggled request ----
sec "5aa. scan/status POST closes connection (smuggled keep-alive body not served)"
# S03: POST /api/wan/scan and /api/wan/status are session-gated, and the
# session check fires BEFORE the body is read — so an unauthenticated
# request's body is left unread on the socket. The deny path still closes
# the connection: the body stays unparsed, and under HTTP/1.1 those bytes
# would be parsed as the next request on the same socket. The response must
# carry Connection: close (after the status line) and the server must close
# the socket so the smuggled request never executes. One socket, one
# smuggled GET /api/wan/known inside the body of a pin-less POST.
pkill -f status-server.py 2>/dev/null; sleep 0.3
printf '{"mode":"standalone","wan_if":"","wan_ssid":"FixtureNet","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/srv-state.json"
STWT="$B/stub-travel-wan-c4"
# known) -> the smuggled request, if served, returns this distinctive token.
# (3 tab-separated fields so the known parser would echo it back.)
printf '#!/bin/bash\nif [[ "$1" == known ]]; then printf "KNOWN\\tSMUGGLED-KNOWN-TOKEN\\tyes\\n"; exit 0; fi\nprintf "{\\"mode\\":\\"routed\\",\\"internet\\":\\"yes\\"}"\n' > "$STWT"; chmod +x "$STWT"
TRAVELROUTER_SETUP_PIN="2468" TRAVELROUTER_ADMIN_PSK="${TESTADMIN_PSK:-AdminPass99}" \
TRAVELWAN_BIN="$STWT" TRAVELROUTER_STATE_FILE="$B/srv-state.json" \
TRAVELROUTER_STATUS_PORT=18097 TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >"$B/srv-c4.log" 2>&1 &
C4PID=$!
wait_healthy 18097 || true
# S03: scan/status deny on the session BEFORE any body read — a bodyless
# POST still gets 401 (no session), no pin compared — the close header fires
# on every deny (the smuggling defense), verified on the wire below.
b411=$(curl -s -D - -o /dev/null -X POST \
  -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
  http://127.0.0.1:18097/api/wan/scan 2>/dev/null | tr -d '\r')
echo "$b411" | head -1 | grep -q ' 401 ' \
  && echo "$b411" | grep -qi '^connection: close$' \
  && ok "5aa bodyless POST /api/wan/scan -> 401 + Connection: close (session gate; body never read)" \
  || bad "5aa bodyless scan POST: $(echo "$b411" | head -3 | tr '\n' '|')"

python3 - "$B/c4-transcript.txt" <<'PYEOF'
import socket, sys

transcript = open(sys.argv[1], "w")

def post_scan():
    # Content-Length says 45; the body IS the smuggled request. The server
    # must never hand it to the request parser.
    smuggled = b"GET /api/wan/known HTTP/1.1\r\nHost: x\r\n\r\n"
    req = (b"POST /api/wan/scan HTTP/1.1\r\nHost: 127.0.0.1:18097\r\n"
           + b"Content-Length: " + str(len(smuggled)).encode() + b"\r\n\r\n"
           + smuggled)
    s = socket.create_connection(("127.0.0.1", 18097), timeout=10)
    s.sendall(req)
    first = b""
    try:
        while b"\r\n\r\n" not in first:
            chunk = s.recv(4096)
            if not chunk:
                break
            first += chunk
    except socket.timeout:
        pass
    # Then attempt to read the NEXT response on the SAME socket.
    rest = b""
    try:
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            rest += chunk
    except socket.timeout:
        pass
    except OSError:
        pass
    s.close()
    return first, rest

first, rest = post_scan()
transcript.write("--- first response ---\n" + first.decode("utf-8", "replace"))
transcript.write("--- after scan response (rest of socket) ---\n"
                 + (rest.decode("utf-8", "replace") if rest else "<EOF: connection closed>"))
transcript.close()

line1 = first.split(b"\r\n", 1)[0]
ok_hdr = line1.startswith(b"HTTP/1.") and b" 401 " in line1
# Status line must come FIRST (Connection header after send_response, not
# before it): the parsed status line is HTTP/1.x, and Connection appears
# among the headers after it.
ok_order = first.startswith(b"HTTP/1.")
ok_close = b"\r\nConnection: close\r\n" in first
ok_eof = not (rest.startswith(b"HTTP/") or b"SMUGGLED-KNOWN-TOKEN" in rest)
if not (ok_hdr and ok_order and ok_close and ok_eof):
    print("DESYNC-FAIL first=%r rest=%r hdr=%s order=%s close=%s eof=%s"
          % (first, rest, ok_hdr, ok_order, ok_close, ok_eof))
    sys.exit(1)
print("DESYNC-OK")
PYEOF
rc=$?
[[ $rc -eq 0 ]] && ok "5aa scan POST: 401 (no session) closes connection; smuggled GET not served" \
  || bad "5aa desync battery failed rc=$rc (smuggled request may have executed; see $B/c4-transcript.txt)"
transcript=$(cat "$B/c4-transcript.txt" 2>/dev/null | head -c 400)
echo "$transcript" | grep -q '^HTTP/1' && ok "5aa transcript captures real socket bytes" \
  || bad "5aa transcript missing HTTP bytes"
echo "$transcript" | grep -q 'SMUGGLED-KNOWN-TOKEN' && bad "5aa smuggled GET /api/wan/known WAS served (connection not closed)" \
  || ok "5aa smuggled request not executed"

kill $C4PID 2>/dev/null; wait $C4PID 2>/dev/null
pkill -f status-server.py 2>/dev/null; sleep 0.3

# --- (5ab) PSK-in-argv accepted-risk documentation -----------------------------
sec "5ab. PSK-in-argv accepted-risk markers (doc-only, C5)"
n=$(grep -c 'PSK-in-argv accepted risk' "$A/travel-wan.sh")
[[ "$n" == "2" ]] && ok "5ab travel-wan.sh has exactly 2 PSK-in-argv accepted-risk markers" \
  || bad "5ab travel-wan.sh PSK-in-argv marker count=$n (want exactly 2)"
grep -q 'Threat model' "$ROOT/README.md" \
  && grep -q 'PSK-in-argv accepted risk' "$ROOT/README.md" \
  && ok "5ab README travel-router threat-model note present" \
  || bad "5ab README missing threat-model note or PSK-in-argv marker"

# --- (5ac) PIN brute-force throttle: per-source backoff + reset (hardening C1) --
sec "5ac. PIN throttle per-source backoff + reset-on-success (C1)"
# One client IP (127.0.0.1) used to hammer POST /api/wan/connect with a wrong
# PIN. Post-S03 client writes never compare a PIN, so the throttle is fed by
# ADMIN writes + login only: this battery hammers POST /api/wan/psks-manage
# (session held) with a wrong body.pin. Tiers: 5th fail -> 5s block, 25th ->
# 30s, 51st -> 120s. A blocked (429) attempt still advances the counter.
# Success resets the IP's entry.
# NOTE: 127.0.0.2 source binds fail on macOS (errno 49) — single client IP.
pkill -f status-server.py 2>/dev/null; sleep 0.3
printf '{"mode":"standalone","wan_if":"","wan_ssid":"FixtureNet","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/srv-state.json"
STWC1="$B/stub-travel-wan-c1"
printf '#!/bin/bash\ncase "$1" in connect|scan|status) printf "{\\"mode\\":\\"routed\\",\\"wan_if\\":\\"wlan1\\",\\"internet\\":\\"yes\\",\\"standalone\\":false}"; exit 0;; esac\nexit 0\n' > "$STWC1"; chmod +x "$STWC1"
C1LOG="$B/c1-throttle.txt"
: > "$C1LOG"
echo "=== C1 PIN throttle transcript ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ===" >> "$C1LOG"
c1_start() { # -> fresh server on 18098 (fresh in-memory throttle state)
  TRAVELROUTER_SETUP_PIN="2468" TRAVELROUTER_ADMIN_PSK="${TESTADMIN_PSK:-AdminPass99}" \
  TRAVELWAN_BIN="$STWC1" TRAVELROUTER_STATE_FILE="$B/srv-state.json" \
  TRAVELROUTER_STATUS_PORT=18098 TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >>"$B/srv-c1.log" 2>&1 &
  C1PID=$!
  wait_healthy 18098 || true
  C1TOK=$(login_psk 18098 "${TESTADMIN_PSK:-AdminPass99}")
}
c1_stop() { kill $C1PID 2>/dev/null; wait $C1PID 2>/dev/null; }
c1_post() { # pin -> one POST /api/wan/psks-manage attempt (session held); echoes the HTTP code
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
    -H "X-Session: $C1TOK" \
    -d "{\"action\":\"add-default\",\"psk\":\"fixturepsk\",\"pin\":\"$1\"}" http://127.0.0.1:18098/api/wan/psks-manage 2>/dev/null)
  echo "POST /api/wan/psks-manage pin=<redacted:len=${#1}> -> $code" >> "$C1LOG"
  echo "$code"
}

# --- part A: 5 wrong -> 403 each; 6th within window -> 429 ----------------------
c1_start
codes_a=""
for i in 1 2 3 4 5; do codes_a="$codes_a$(c1_post wrong$i) "; done
echo "--- attempts 1-5 codes: $codes_a" >> "$C1LOG"
[[ "$codes_a" == "403 403 403 403 403 " ]] \
  && ok "5ac first 5 wrong PINs -> 403 (under 5-tier)" || bad "5ac first-5 codes=[$codes_a] (want 403 x5)"
r6=$(c1_post wrong6)
[[ "$r6" == "429" ]] || r6=$(c1_post wrong6)
[[ "$r6" == "429" ]] && ok "5ac 6th wrong within window -> 429" || bad "5ac 6th wrong code=$r6 (want 429)"
body429=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $C1TOK" -d '{"action":"add-default","psk":"fixturepsk","pin":"wrongbody"}' \
  http://127.0.0.1:18098/api/wan/psks-manage 2>/dev/null)
echo "--- 429 body (further blocked attempt): $body429" >> "$C1LOG"
echo "$body429" | grep -q 'rate_limited' && echo "$body429" | grep -q '429$' \
  && ok "5ac 429 body is {\"error\":\"rate_limited\"}" || bad "5ac 429 body=[$body429]"

# --- part B: blocked attempts still count -> block window GROWS (escalation) ----
# Count is >= 7 after part A. 22 more wrong attempts (429s while the 5s block
# holds) push it past the 25-tier. Whether the 30s re-block arms on the next
# post-expiry attempt or was already armed depends on request timing, so the
# proof runs two sleep-5.5s cycles: after the second, a 5s-tier server would
# answer 403 (every 5s window has expired); the real server must still 429
# because the armed window is 30s.
codes_b=""
for i in $(seq 1 22); do codes_b="$codes_b$(c1_post flood$i)"; done
n429=$(printf '%s' "$codes_b" | grep -o '429' | wc -l | tr -d ' ')
echo "--- 22 flood attempts, 429 count: $n429 (all: $codes_b)" >> "$C1LOG"
t0=$(date +%s); r0=$(c1_post escalate0); t1=$(date +%s)
[[ "$r0" == "429" || "$r0" == "403" ]] \
  && ok "5ac wrong attempts still rejected past 25-fail (escalated count, code=$r0)" \
  || bad "5ac escalation code=$r0 (want 403/429)"
echo "--- escalation0 @$t0 = $r0 (gap $((t1 - t0))s)" >> "$C1LOG"
sleep 5.5
r1=$(c1_post rearm1); echo "--- rearm1 (post 5.5s) = $r1" >> "$C1LOG"
sleep 5.5
t2=$(date +%s); r2=$(c1_post rearm2); t3=$(date +%s)
echo "--- rearm2 @$t2 = $r2 after two 5.5s waits (gap $((t3 - t2))s)" >> "$C1LOG"
[[ "$r2" == "429" ]] && ok "5ac still 429 after two 5s-tier expiries (window grew to 30s)" \
  || bad "5ac post-expiry code=$r2 (want 429; block did not grow)"
c1_stop

# --- part C: reset-on-success from the SAME source IP ---------------------------
pkill -f status-server.py 2>/dev/null; sleep 0.3
c1_start
echo "=== part C: fresh server (fresh throttle state), same client IP ===" >> "$C1LOG"
codes_c1=""
for i in 1 2 3 4 5; do codes_c1="$codes_c1$(c1_post wrongc1$i) "; done
r6=$(c1_post wrongc1-6)
echo "--- part C attempts 1-5: $codes_c1 6th: $r6" >> "$C1LOG"
[[ "$codes_c1" == "403 403 403 403 403 " && "$r6" == "429" ]] \
  && ok "5ac block re-armed on fresh server (5x403 then 429)" || bad "5ac re-arm codes=[$codes_c1] 6th=$r6"
# wait out the 5s block (client-side sleep; server has no sleeps)
sleep 5.5
r=$(c1_post 2468)
echo "--- correct PIN after block expiry -> $r" >> "$C1LOG"
[[ "$r" == "200" ]] && ok "5ac correct PIN after block expiry -> 200 (entry reset)" || bad "5ac correct-pin code=$r (want 200)"
codes_c2=""
for i in 1 2 3 4 5; do codes_c2="$codes_c2$(c1_post wrongc2$i) "; done
echo "--- part C post-reset 5 wrong: $codes_c2" >> "$C1LOG"
[[ "$codes_c2" == "403 403 403 403 403 " ]] \
  && ok "5ac post-reset 5 wrong PINs -> 403 NOT 429 (counter reset proven)" || bad "5ac post-reset codes=[$codes_c2]"
c1_stop
pkill -f status-server.py 2>/dev/null; sleep 0.3
# no PIN in the transcript (server must never log the PIN)
grep -q '2468' "$C1LOG" && bad "5ac PIN leaked into throttle transcript (forbidden)" \
  || ok "5ac transcript free of PIN"
echo "5ac throttle transcript: $C1LOG"

# --- (5ac2) client write session gate (S03) ------------------------------------
sec "5ac2. POST write session gate (S03)"
# Client writes (/api/wan/{connect,psks,disconnect,forget,recheck}) need ONLY
# a session — body.pin is neither required nor compared, so they never feed
# the shared _PIN_FAILS throttle (admin writes + login do; §5ac / §5ak(6)).
# One live server for the whole part (isolated port).
pkill -f status-server.py 2>/dev/null; sleep 0.3
printf '{"mode":"standalone","wan_if":"","wan_ssid":"FixtureNet","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/srv-state.json"
STWC1B="$B/stub-travel-wan-c1b"
printf '#!/bin/bash\ncase "$1" in connect|scan|status) printf "{\\"mode\\":\\"routed\\",\\"wan_if\\":\\"wlan1\\",\\"internet\\":\\"yes\\",\\"standalone\\":false}"; exit 0;; esac\nexit 0\n' > "$STWC1B"; chmod +x "$STWC1B"
C1BLOG="$B/c1b-write-throttle.txt"
: > "$C1BLOG"
echo "=== C1b client-write throttle transcript ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ===" >> "$C1BLOG"
c1b_start() { # -> ONE live server for the whole part (shared in-memory counter)
  TRAVELROUTER_SETUP_PIN="1357" TRAVELROUTER_ADMIN_PSK="${TESTADMIN_PSK:-AdminPass99}" \
  TRAVELWAN_BIN="$STWC1B" TRAVELROUTER_STATE_FILE="$B/srv-state.json" \
  TRAVELROUTER_STATUS_PORT=18099 TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >>"$B/srv-c1b.log" 2>&1 &
  C1BPID=$!
  wait_healthy 18099 || true
  C1BTOK=$(login_psk 18099 "${TESTADMIN_PSK:-AdminPass99}")
}
c1b_stop() { kill $C1BPID 2>/dev/null; wait $C1BPID 2>/dev/null; }
c1b_start
# S03: client writes require a session. Without a session, PIN is irrelevant.
g_nopin=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -d '{"ssid":"HotelNet"}' \
  http://127.0.0.1:18099/api/wan/connect 2>/dev/null)
echo "--- POST no session, no pin: ${g_nopin##*$'\n'}" >> "$C1BLOG"
[[ "$g_nopin" == *$'\n'401 ]] \
  && ok "5ac2 no-session write -> 401 (S03: session required)" \
  || bad "5ac2 no-session write: [$g_nopin]"
# With a valid session, the write succeeds (PIN not required for client writes)
g_sess=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $C1BTOK" \
  -d '{"ssid":"HotelNet"}' \
  http://127.0.0.1:18099/api/wan/connect 2>/dev/null)
echo "--- POST + X-Session, no pin: ${g_sess##*$'\n'}" >> "$C1BLOG"
[[ "$g_sess" == *$'\n'200 ]] \
  && ok "5ac2 session write (no PIN needed) -> 200 (S03)" \
  || bad "5ac2 session write: [$g_sess]"
c1b_stop
pkill -f status-server.py 2>/dev/null; sleep 0.3
grep -q '1357' "$C1BLOG" && bad "5ac2 PIN leaked into write-throttle transcript (forbidden)" \
  || ok "5ac2 transcript free of PIN"
echo "5ac2 write-throttle transcript: $C1BLOG"

# --- (5ac3) GET known session gate (S03) --------------------------------------
sec "5ac3. GET known session gate (S03)"
# The known-networks read is ADMIN-ONLY (S03): X-Session header, no/bogus
# session -> 401 + Connection: close; correct X-Session -> 200 metadata rows.
# One live server; 401-ed (absent-session) reads do not feed the throttle.
pkill -f status-server.py 2>/dev/null; sleep 0.3
printf '{"mode":"standalone","wan_if":"","wan_ssid":"FixtureNet","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/srv-state.json"
STWC6="$B/stub-travel-wan-c6"
printf '#!/bin/bash\nif [[ "$1" == known ]]; then printf "HotelNet\\t1690000000\\tyes\\n"; exit 0; fi\nprintf "{\\"mode\\":\\"routed\\",\\"wan_if\\":\\"wlan1\\",\\"internet\\":\\"yes\\",\\"standalone\\":false}"\n' > "$STWC6"; chmod +x "$STWC6"
C6LOG="$B/c6-known-gate.txt"
: > "$C6LOG"
echo "=== C6 GET known PIN-gate transcript ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ===" >> "$C6LOG"
c6_start() { # -> ONE live server for the whole part
  TRAVELROUTER_SETUP_PIN="1357" TRAVELROUTER_ADMIN_PSK="${TESTADMIN_PSK:-AdminPass99}" \
  TRAVELWAN_BIN="$STWC6" TRAVELROUTER_STATE_FILE="$B/srv-state.json" \
  TRAVELROUTER_STATUS_PORT=18100 TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >>"$B/srv-c6.log" 2>&1 &
  C6PID=$!
  wait_healthy 18100 || true
}
c6_stop() { kill $C6PID 2>/dev/null; wait $C6PID 2>/dev/null; }
c6_start
C6_TOK=$(login_psk 18100 "${TESTADMIN_PSK:-AdminPass99}")
k_nopin=$(curl -s -w '\n%{http_code}' http://127.0.0.1:18100/api/wan/known 2>/dev/null)
echo "--- GET known no session: $k_nopin" >> "$C6LOG"
[[ "$k_nopin" == *'"auth"'* && "$k_nopin" == *$'\n'401 ]] \
  && ok "5ac3 GET known without X-Session -> 401 {\"error\":\"auth\"}" \
  || bad "5ac3 no-sess: [$k_nopin]"
k_conn=$(curl -s -D - -o /dev/null -H 'X-Session: bogus' http://127.0.0.1:18100/api/wan/known 2>/dev/null | tr -d '\r')
echo "--- GET known bogus session (headers): $(echo "$k_conn" | head -1)" >> "$C6LOG"
echo "$k_conn" | grep -qi '^connection: close$' \
  && echo "$k_conn" | head -1 | grep -q ' 401 ' \
  && ok "5ac3 GET known bogus X-Session -> 401 + Connection: close (S03)" \
  || bad "5ac3 bogus-sess close: $(echo "$k_conn" | head -3 | tr '\n' '|')"
resp=$(curl -s -w '\n%{http_code}' -H "X-Session: $C6_TOK" http://127.0.0.1:18100/api/wan/known 2>/dev/null)
code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
echo "--- GET known correct session: $code" >> "$C6LOG"
[[ "$code" == "200" ]] && ok "5ac3 GET known + X-Session -> 200 rows JSON (name/timestamp/autoconnect)" \
  || bad "5ac3 sess rows: [$code]"
# 5 no-session 401s on /api/wan/known must NOT throttle the write path
for i in 1 2 3 4 5; do curl -s -o /dev/null http://127.0.0.1:18100/api/wan/known 2>/dev/null; done
k_post=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
  -H "X-Session: $C6_TOK" -d '{"ssid":"HotelNet"}' \
  http://127.0.0.1:18100/api/wan/connect 2>/dev/null)
echo "--- session write after 5x 401 reads: $k_post" >> "$C6LOG"
[[ "$k_post" == "200" ]] \
  && ok "5ac3 absent-session reads do not arm the write throttle (200 write after 5x401)" \
  || bad "5ac3 post-read-burst write code=$k_post (want 200)"
c6_stop
pkill -f status-server.py 2>/dev/null; sleep 0.3
echo "5ac3 known-gate transcript: $C6LOG"

# admin.html S04-merge C6 contract: the known-networks fetch sites (doScan
# fetch + refreshKnown), each routed via sessionFetch (the session attach site
# is pinned once in §5al — sess_hdr_sites==1); no new raw-fetch call site.
c6_sites=$(grep -c '"/api/wan/known"' "$A/admin.html")
[[ "$c6_sites" == "2" ]] \
  && ok "5ac3 admin.html has exactly 2 /api/wan/known fetch sites" \
  || bad "5ac3 known fetch sites=$c6_sites (want 2)"
c6_sess_sites=$(grep -c 'sessionFetch("/api/wan/known"' "$A/admin.html")
[[ "$c6_sess_sites" == "2" ]] \
  && ok "5ac3 both known fetch sites ride sessionFetch (S03/S04)" \
  || bad "5ac3 sessionFetch sites=$c6_sess_sites (want 2)"
c6_fetch_known=$(grep -c 'fetch("/api/wan/known"' "$A/admin.html")
[[ "$c6_fetch_known" == "0" ]] \
  && ok "5ac3 0 raw fetch(\"/api/wan/known\") sites (S04 merge routes them via sessionFetch)" \
  || bad "5ac3 fetch-known count=$c6_fetch_known (want 0)"
echo "5ac3 admin.html known-fetch census: known=$c6_sites sess-sourced=$c6_sess_sites raw-fetch=$c6_fetch_known"

# --- (5ad) state.json escape + bind-host allowlist + seam (C2) ----------------
sec "5ad. state.json heredoc escape + bind-host allowlist + seam (C2)"
B5="$TMP/c2ad"; mkdir -p "$B5/bin" "$B5/etc" "$B5/dnsmasq.d" "$B5/ip-addr" \
  "$B5/sys/class/net/lo" "$B5/sys/class/net/wlan0/wireless" "$B5/sys/class/net/eth0" \
  "$B5/sys/devices/platform/scb/usb/1-1/1-1.1" "$B5/sys/devices/platform/soc/fe300000.mmcnr/mmc_host/mmc1"
# wan-select seams (§5b idiom): eth0 = USB WAN (drives the NMCLI seam), wlan0
# = AP (LAN). WAN_SSID via nmcli is line-grepped, so a bare LF cannot survive
# into the heredoc value; the control-char path is exercised with TAB + CR.
ln -sf "$B5/sys/devices/platform/scb/usb/1-1/1-1.1" "$B5/sys/class/net/eth0/device"
ln -sf "$B5/sys/devices/platform/soc/fe300000.mmcnr/mmc_host/mmc1" "$B5/sys/class/net/wlan0/device"
printf '2: wlan0    inet 192.168.50.1/24 brd 192.168.50.255 scope global wlan0\n       valid_lft forever' > "$B5/ip-addr/wlan0"
printf '2: eth0    inet 10.0.0.2/24 brd 10.0.0.255 scope global eth0\n       valid_lft forever' > "$B5/ip-addr/eth0"
for t in iw nft rfkill systemctl; do
  printf '#!/bin/bash\nexit 0\n' > "$B5/bin/$t"
done
printf '#!/bin/bash\ndev=""; prev=""; for a in "$@"; do [ "$prev" = dev ] && dev="$a"; prev="$a"; done\nif [ -n "$dev" ] && [ -f %s/ip-addr/"$dev" ]; then cat %s/ip-addr/"$dev"; exit 0; fi\nexit 1\n' "$B5" "$B5" > "$B5/bin/ip"
# NMCLI stub emits a hostile WAN_SSID on one grep-survivable line: quote,
# backslash, TAB, CR, and an injected "lan_ip" needle -- the real attack shape.
cat > "$B5/bin/nmcli" <<'NMEOF'
#!/bin/bash
ssid=$'Evil"lan_ip":"6.6.6.6 \\Quo"ted\t5GHz\rHostel'
printf 'GENERAL.CONNECTION:%s\n' "$ssid"
exit 0
NMEOF
chmod +x "$B5"/bin/*
run_wan_c2() { SYSFS_ROOT="$B5/sys" TRAVELROUTER_WAN_PREFER=ethernet TRAVELROUTER_STATE_FILE="$B5/c2-state.json" \
  NFTABLES_TARGET="$B5/etc/nftables.conf" DNSMASQ_CONF_DIR="$B5/dnsmasq.d" PATH="$B5/bin:$PATH" ASSETS="$A" \
  bash "$A/wan-select.sh" 2>&1; }
run_wan_c2 >/dev/null 2>&1
# attack shape really entered the pipeline (nmcli stub emitted the needle)
hostile_input=$("$B5/bin/nmcli" -t -f GENERAL.CONNECTION dev show eth0 2>/dev/null)
grep -qF 'Evil"lan_ip":"6.6.6.6' <<<"$hostile_input" \
  && ok "5ad hostile SSID with injected lan_ip needle entered the pipeline" \
  || bad "5ad stub did not emit the needle"
# (A1) the heredoc render must be VALID JSON despite the hostile SSID
python3 -m json.tool "$B5/c2-state.json" >"$B5/c2-pretty.json" 2>"$B5/c2-parse.err" \
  && ok "5ad hostile-SSID state.json parses (json.tool)" || bad "5ad json.tool: $(cat "$B5/c2-parse.err")"
# (A2) first-match parsers must find the REAL lan_ip, not the injected needle
real_ip=$(python3 -c 'import json;print(json.load(open("'"$B5"'/c2-state.json"))["lan_ip"])')
[[ "$real_ip" == "192.168.50.1" ]] && ok "5ad json.load lan_ip=192.168.50.1 (real)" || bad "5ad json.load lan_ip=$real_ip"
# status-server's own first-match parser against the raw file (the real one,
# imported -- no hand-rolled replica)
c2_first_match=$(python3 - "$B5/c2-state.json" "$A" <<'PYEOF'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location(
    "c2statusfm", sys.argv[2] + "/status-server.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod._json_field(open(sys.argv[1]).read(), "lan_ip"))
PYEOF
)
[[ "$c2_first_match" == "192.168.50.1" ]] && ok "5ad _json_field first-match lan_ip=192.168.50.1 (not injected)" \
  || bad "5ad _json_field first-match lan_ip=$c2_first_match"
# raw first-match awk idiom (what legacy parsers do against the raw file)
raw_first=$(grep -o '"lan_ip"[[:space:]]*:[[:space:]]*"[^"]*"' "$B5/c2-state.json" | head -1 \
  | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/')
[[ "$raw_first" == "192.168.50.1" ]] && ok "5ad raw-awk first-match lan_ip=192.168.50.1" \
  || bad "5ad raw-awk first-match lan_ip=$raw_first"
# escaped SSID survives (not truncated/rejected) -- parsed value must equal
# the input minus control chars (TAB/CR dropped), quotes+backslash intact
python3 - "$B5" <<'PYEOF' && ok "5ad SSID round-trips escaped (no truncation/rejection)" \
  || bad "5ad SSID round-trip mismatch"
import json
import os
import sys

state = json.load(open(os.path.join(sys.argv[1], "c2-state.json")))
expected = 'Evil"lan_ip":"6.6.6.6 \\Quo"ted5GHzHostel'
if state["wan_ssid"] == expected:
    print("SSID OK: %r" % state["wan_ssid"])
    sys.exit(0)
print("SSID BAD: %r != %r" % (state["wan_ssid"], expected))
sys.exit(1)
PYEOF
# (B) resolve_host_and_port matrix: bad lan_ip -> DEFAULT_HOST fallback;
# legit RFC1918 -> kept; seam overrides regardless of state lan_ip.
c2_matrix() {
python3 - "$B5" "$A" <<'PYEOF'
import importlib.util
import json
import os
import sys

b5, adir = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "c2status", os.path.join(adir, "status-server.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

cases = ["0.0.0.0", "127.0.0.1", "8.8.8.8", "evil", "169.254.1.1",
         "255.255.255.255"]
for val in cases:
    with open(os.path.join(b5, "m-state.json"), "w") as fh:
        fh.write('{"mode":"routed","wan_if":"eth0","lan_ip":"%s"}' % val)
    os.environ["TRAVELROUTER_STATE_FILE"] = os.path.join(b5, "m-state.json")
    os.environ.pop("TRAVELROUTER_BIND_HOST", None)
    host, _ = mod.resolve_host_and_port()
    tag = "fallback" if host == mod.DEFAULT_HOST else "KEPT"
    print("FALLBACK %s -> %s [%s]" % (val, host, tag))
for val in ["192.168.50.9", "10.0.0.5"]:
    with open(os.path.join(b5, "m-state.json"), "w") as fh:
        fh.write('{"mode":"routed","wan_if":"eth0","lan_ip":"%s"}' % val)
    host, _ = mod.resolve_host_and_port()
    tag = "accepted" if host == val else "FELLBACK"
    print("ACCEPT %s -> %s [%s]" % (val, host, tag))
os.environ["TRAVELROUTER_BIND_HOST"] = "127.0.0.1"
with open(os.path.join(b5, "m-state.json"), "w") as fh:
    fh.write('{"mode":"routed","wan_if":"eth0","lan_ip":"0.0.0.0"}')
host, _ = mod.resolve_host_and_port()
tag = "seam" if host == "127.0.0.1" else "SEAM-FAILED"
print("SEAM 0.0.0.0-state -> %s [%s]" % (host, tag))
os.environ.pop("TRAVELROUTER_BIND_HOST", None)
PYEOF
}
c2_matrix_out=$(c2_matrix)
echo "$c2_matrix_out"
for c in "0.0.0.0" "127.0.0.1" "8.8.8.8" "evil" "169.254.1.1" "255.255.255.255"; do
  line=$(printf '%s\n' "$c2_matrix_out" | grep -F "FALLBACK $c ->" || true)
  [[ "$line" == *"[fallback]"* ]] \
    && ok "5ad lan_ip=$c -> DEFAULT_HOST fallback" || bad "5ad lan_ip=$c: $line"
done
for c in "192.168.50.9" "10.0.0.5"; do
  line=$(printf '%s\n' "$c2_matrix_out" | grep -F "ACCEPT $c ->" || true)
  [[ "$line" == *"[accepted]"* ]] \
    && ok "5ad lan_ip=$c accepted (private unicast)" || bad "5ad lan_ip=$c: $line"
done
line=$(printf '%s\n' "$c2_matrix_out" | grep -F "SEAM 0.0.0.0-state ->" || true)
[[ "$line" == *"[seam]"* ]] && ok "5ad TRAVELROUTER_BIND_HOST=127.0.0.1 overrides rejected state lan_ip" \
  || bad "5ad seam: $line"
# seam must NOT honor garbage/non-IPv4 values (falls through to state path)
seam_garbage=$(TRAVELROUTER_STATE_FILE="$B5/m-state.json" TRAVELROUTER_BIND_HOST="not-an-ip" \
  python3 - "$A" <<'PYEOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location(
    "c2status", os.path.join(sys.argv[1], "status-server.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod.resolve_host_and_port()[0])
PYEOF
)
[[ "$seam_garbage" == "192.168.50.1" ]] && ok "5ad garbage seam value ignored (state lan_ip 0.0.0.0 still falls back)" \
  || bad "5ad garbage seam -> $seam_garbage"
echo "5ad hostile render: $(head -c 300 "$B5/c2-state.json")"

# --- (5ae) C1 client pin guard (apiWrite empty-PIN early-return) ---------------
sec "5ae. C1 client pin guard (apiWrite)"
# apiWrite (manual Connect/Disconnect/Forget) must refuse to POST when BOTH the
# PIN field and localStorage are empty — same guard as doConnect/d-connect/
# psksManage/tryBtn/fBtn/ap-save. Extract the function body by anchor (stable
# against line drift) and assert the guard idiom: setMsg + early return before
# the POST.
aw_start=$(grep -n -F 'function mcWrite(' "$A/admin.html" | head -1 | cut -d: -f1)
aw_body=""
if [[ -n "$aw_start" ]]; then
  aw_body=$(sed -n "${aw_start},$((aw_start+24))p" "$A/admin.html")
fi
if echo "$aw_body" | grep -q 'var body = extra || {}' \
   && echo "$aw_body" | grep -q 'busy(true)'; then
  ok "5ae mcWrite uses session auth (S03/S04)"
else
  bad "5ae mcWrite missing session auth"
fi
# The confusing server-403 fallback string must stay (handleErr, unchanged):
# after the S04 merge the page carries 11 occurrences (one per PIN-gated
# write); the unique pin is handleErr's throw form — exactly one.
h_err=$(grep -c -F 'throw new Error("PIN required — enter it in the PIN section' "$A/admin.html")
[[ "$h_err" == "1" ]] && ok "5ae handleErr PIN-required throw unchanged (unique)" || bad "5ae handleErr throw count=$h_err (want 1)"
# Guarded-message invariant: after S04, admin.html is the session-gated merge
# surface — it references the admin-session localStorage key.
sess_msg_count=$(grep -c -F 'admin-session' "$A/admin.html")
[[ "$sess_msg_count" -ge "1" ]] && ok "5ae admin.html references admin-session (S03)" || bad "5ae admin.html admin-session count=$sess_msg_count"

# --- (5af) admin PSK staging battery (Todo 2, C3/C4 seam) ---------------------
sec "5af. admin PSK staging (same tmpfs EnvironmentFile as the PIN)"
# (a) .env.example documents the var
grep -q '^TRAVELROUTER_ADMIN_PSK=' "$ROOT/.env.example" \
  && ok "5af .env.example has TRAVELROUTER_ADMIN_PSK" || bad "5af .env.example missing TRAVELROUTER_ADMIN_PSK"
# (c) malformed/missing admin PSK -> friendly fail rc=1 (fixture mirrors §5g:
# PIN breakers carry no ADMIN_PSK either — unset must also fail). Breakers are
# %q-quoted like the real role.env render (provision.sh printf '%s=%q'): bare
# KEY=value would let bash strip the breaker chars before install.sh sees them.
for bad_psk in "" "short1" 'with|bar' 'with\back' 'with$dollar' 'with\&amp'; do
  printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\n' > "$TMP/pskbrk.env"
  printf 'TRAVELROUTER_ADMIN_PSK=%q\n' "$bad_psk" >> "$TMP/pskbrk.env"
  out=$(TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$TMP/pskbrk" TRAVELROUTER_ROLE_ENV="$TMP/pskbrk.env" \
        bash "$ROOT/roles/travel-router/install.sh" 2>&1); rc=$?
  [[ $rc -eq 1 && "$out" == *"ADMIN_PSK"* ]] && ok "5af malformed ADMIN_PSK '${bad_psk:-<empty>}' rejected (rc=1)" \
    || bad "5af ADMIN_PSK '${bad_psk:-<empty>}' NOT rejected (rc=$rc out=$(echo "$out" | head -1))"
done
# unset ADMIN_PSK (no role.env line at all) must also fail
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\n' > "$TMP/pskunset.env"
out=$(TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$TMP/pskunset" TRAVELROUTER_ROLE_ENV="$TMP/pskunset.env" \
      bash "$ROOT/roles/travel-router/install.sh" 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"ADMIN_PSK"* ]] && ok "5af unset ADMIN_PSK rejected (rc=1)" \
  || bad "5af unset ADMIN_PSK NOT rejected (rc=$rc out=$(echo "$out" | head -1))"
# newline render-breaker via env seam (real newline inside the value)
out=$(TRAVELROUTER_ADMIN_PSK="pass
line" TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$TMP/pskbrknl" TRAVELROUTER_ROLE_ENV="$TMP/pskbrk.env" \
        bash "$ROOT/roles/travel-router/install.sh" 2>&1); rc=$?
  [[ $rc -eq 1 && "$out" == *"ADMIN_PSK"* ]] && ok "5af ADMIN_PSK with newline rejected (rc=1)" \
    || bad "5af ADMIN_PSK with newline NOT rejected (rc=$rc out=$(echo "$out" | head -1))"
# (b) happy dry-run: env file stages BOTH PIN and PSK at 0600 (fixture idiom of §5g)
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\nTRAVELROUTER_ADMIN_PSK=AdminPass99\n' > "$TMP/pskok.env"
pfxpsk="$TMP/pskrun"
if TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$pfxpsk" TRAVELROUTER_ROLE_ENV="$TMP/pskok.env" \
   bash "$ROOT/roles/travel-router/install.sh" >"$TMP/pskrun.log" 2>&1; then ok "5af ADMIN_PSK happy dry-run rc=0"; else bad "5af ADMIN_PSK happy dry-run exited $?"; fi
envfile="$pfxpsk/run/travel-router/role-env/travel-router-setup.env"
[[ -f "$envfile" ]] && ok "5af PSK env file staged" || bad "5af PSK env file MISSING: $(ls "$pfxpsk/run/travel-router/" 2>/dev/null)"
grep -qF 'TRAVELROUTER_SETUP_PIN="9876"' "$envfile" && ok "5af PIN still rendered into env file" || bad "5af PIN line missing from env file"
grep -qF 'TRAVELROUTER_ADMIN_PSK="AdminPass99"' "$envfile" && ok "5af ADMIN_PSK rendered into env file" || bad "5af ADMIN_PSK missing from env file"
m=$(stat -f%Lp "$envfile" 2>/dev/null || stat -c%a "$envfile" 2>/dev/null)
[[ "$m" == "600" ]] && ok "5af env file (PIN+PSK) mode 0600" || bad "5af env file mode=$m"
grep -qF 'AdminPass99' "$TMP/pskrun.log" && bad "5af ADMIN_PSK leaked to install log" || ok "5af ADMIN_PSK absent from install log"

# --- (5ag) connected-clients list (Todo 4) ------------------------------------
# Mirrors the §5c seam idiom: stub the tool reads (macOS has neither
# /sys/class/net nor /var/lib/misc) and copy travel-wan.sh with a sed so the
# leases path points at a fixture. Degraded status (no /sys/class/net) is what
# a macOS runner exercises: the battery asserts the degraded-JSON clients_list
# plus the `travel-wan clients` subcommand, which reads the leases file
# directly (no interface check).
sec "5ag connected-clients list"
TW_COPY="$TMP/ag-copy.sh"
sed "s|/var/lib/misc/dnsmasq.leases|$TMP/ag-leases|g" "$A/travel-wan.sh" > "$TW_COPY"
tw_ag() { # [args...] -> run the sed-copied travel-wan with env stubs
  TW_MACS="aa:bb:cc:dd:ee:03" NMCLI="$STUB/nmcli" IP="$STUB/ip" CURL="$STUB/curl" \
    HOSTAPD_CLI="$B/ag-hostapd" TRAVELROUTER_STATE_FILE="$B/tw-state.json" \
    bash "$TW_COPY" "$@" 2>/dev/null
}
# Fixture: 3 leases; row 2's hostname contains a space; row 3's MAC is
# associated (the HOSTAPD_CLI stub prints one MAC).
printf '%s\t%s\t%s\t%s\n' 1700000000 aa:bb:cc:dd:ee:01 192.168.50.101 'phone' \
  > "$TMP/ag-leases"
printf '%s\t%s\t%s\t%s\n' 1700000101 aa:bb:cc:dd:ee:02 192.168.50.102 'guest laptop' \
  >> "$TMP/ag-leases"
printf '%s\t%s\t%s\t%s\n' 1700000202 aa:bb:cc:dd:ee:03 192.168.50.103 'desk' \
  >> "$TMP/ag-leases"
printf '#!/bin/bash\nif [[ "$1" == "all_sta" ]]; then printf "%%s\\n" "aa:bb:cc:dd:ee:03"; exit 0; fi\nexit 0\n' > "$B/ag-hostapd"
chmod +x "$B/ag-hostapd"
# (a) status --json: clients_list rows + legacy count + association
out=$(tw_ag status --json); rc=$?
json_ok=$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); l=d.get("clients_list"); sys.exit(0 if isinstance(l,list) and len(l)==3 else 1)' <<<"$out" 2>/dev/null && echo yes)
[[ "$json_ok" == "yes" ]] && ok "5ag status clients_list=3 rows" || bad "5ag clients_list wrong: $out"
[[ "$out" == *'"clients":3'* ]] && ok "5ag legacy clients count key still present" || bad "5ag legacy clients missing: $out"
python3 - "$out" <<'PY' 2>/dev/null && ok "5ag lease row fields (mac/ip/hostname, space-safe)" || bad "5ag lease row fields wrong"
import json, sys
d = json.loads(sys.argv[1])
l = d["clients_list"]
r0, r1, r2 = l[0], l[1], l[2]
assert r0["mac"] == "aa:bb:cc:dd:ee:01" and r0["ip"] == "192.168.50.101"
assert r0["hostname"] == "phone" and r0["lease_expires"] == "1700000000"
assert r1["hostname"] == "guest laptop", r1
assert r0["associated"] is False and r2["associated"] is True
PY
# (b) clients subcommand: same rows, every field JSON-escaped
out=$(tw_ag clients --json); rc=$?
[[ $rc -eq 0 ]] && echo "$out" | python3 -m json.tool >/dev/null 2>&1 \
  && ok "5ag clients --json parses" || bad "5ag clients --json invalid: rc=$rc out=$out"
python3 - "$out" <<'PY' 2>/dev/null && ok "5ag clients rows parity (3, space-safe, assoc)" || bad "5ag clients rows wrong"
import json, sys
l = json.loads(sys.argv[1])
assert isinstance(l, list) and len(l) == 3
assert l[1]["hostname"] == "guest laptop"
assert l[0]["associated"] is False and l[2]["associated"] is True
PY
# hostile hostname: quotes/backslash/$/tab must survive JSON-escaped (a
# control char like TAB is DROPPED by json_escape, mirroring wan-select.sh)
printf '%s\t%s\t%s\t%s\n' 1700000000 de:ad:be:ef:00:01 192.168.50.99 'say "hi"\$x tab	sep' \
  > "$TMP/ag-leases-h"
sed "s|/var/lib/misc/dnsmasq.leases|$TMP/ag-leases-h|g" "$A/travel-wan.sh" > "$TW_COPY"
out=$(NMCLI="$STUB/nmcli" IP="$STUB/ip" CURL="$STUB/curl" HOSTAPD_CLI=/nonexistent \
      TRAVELROUTER_STATE_FILE="$B/tw-state.json" bash "$TW_COPY" clients --json)
python3 - "$out" <<'PY' 2>/dev/null && ok "5ag hostile hostname JSON-escaped intact" || bad "5ag hostile hostname mangled: $out"
import json, sys
l = json.loads(sys.argv[1])
assert len(l) == 1
assert l[0]["hostname"] == 'say "hi"\\$x tabsep', l[0]["hostname"]
PY
# malformed lease line (too few fields / no newline at EOF): degrade, no crash
printf '%s\t%s\n' 1700000000 aa:bb:cc:dd:ee:aa > "$TMP/ag-leases-m"   # 2 fields
printf '1700000000\tde:ad:be:ef:00:09\t192.168.50.90\tlast-no-newline' >> "$TMP/ag-leases-m"
sed "s|$TMP/ag-leases}|$TMP/ag-leases-m}|g" "$A/travel-wan.sh" > "$TW_COPY"
out=$(NMCLI="$STUB/nmcli" IP="$STUB/ip" CURL="$STUB/curl" HOSTAPD_CLI=/nonexistent \
      TRAVELROUTER_STATE_FILE="$B/tw-state.json" bash "$TW_COPY" clients --json); rc=$?
[[ $rc -eq 0 ]] && echo "$out" | python3 -m json.tool >/dev/null 2>&1 \
  && ok "5ag malformed lease lines degrade, no crash" || bad "5ag malformed leases crash: rc=$rc out=$out"
# missing leases file: empty list on BOTH surfaces, never aborts
sed "s|$TMP/ag-leases}|$TMP/ag-leases-absent}|g" "$A/travel-wan.sh" > "$TW_COPY"
out=$(NMCLI="$STUB/nmcli" IP="$STUB/ip" CURL="$STUB/curl" HOSTAPD_CLI=/nonexistent \
      TRAVELROUTER_STATE_FILE="$B/tw-state.json" bash "$TW_COPY" status --json)
python3 - "$out" <<'PY' 2>/dev/null && ok "5ag missing leases file -> status clients_list=[] (never aborts)" || bad "5ag missing leases status: $out"
import json, sys
d = json.loads(sys.argv[1])
assert d.get("clients_list") == []
PY
out=$(NMCLI="$STUB/nmcli" IP="$STUB/ip" CURL="$STUB/curl" HOSTAPD_CLI=/nonexistent \
      TRAVELROUTER_STATE_FILE="$B/tw-state.json" bash "$TW_COPY" clients --json); rc=$?
[[ $rc -eq 0 && "$out" == "[]" ]] && ok "5ag missing leases file -> clients --json []" || bad "5ag missing leases clients: rc=$rc out=$out"
rm -f "$TW_COPY"

# --- (5ah) bounded DHCP connection log (Todo 3) --------------------------------
sec "5ah bounded DHCP connection log"
# install.sh must enable dnsmasq log-dhcp into a DEDICATED, bounded file:
# /var/log/travel-router/dhcp.log rotated by a logrotate drop-in (size 1M,
# rotate 5, copytruncate — dnsmasq has no built-in rotation and no signal
# dance). Renders through install.sh (§2 idiom), not hand-rolled config.
ah="$TMP/ah"; mkdir -p "$ah"
if TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$ah/pfx" TRAVELROUTER_ROLE_ENV="$TMP/role.env" \
   bash "$ROOT/roles/travel-router/install.sh" >"$ah/install.log" 2>&1; then
  grep -q '^log-dhcp$' "$ah/pfx/etc/dnsmasq.d/travel-router.conf" \
    && ok "5ah(a) rendered conf has log-dhcp" || bad "5ah(a) log-dhcp MISSING from rendered dnsmasq conf"
  grep -q '^log-facility=/var/log/travel-router/dhcp.log$' "$ah/pfx/etc/dnsmasq.d/travel-router.conf" \
    && ok "5ah(a) rendered conf has log-facility=/var/log/travel-router/dhcp.log" \
    || bad "5ah(a) log-facility=/var/log/travel-router/dhcp.log MISSING from rendered dnsmasq conf"
  ah_rot="$ah/pfx/etc/logrotate.d/travel-router-dhcp"
  if [[ -f "$ah_rot" ]]; then
    ok "5ah(b) logrotate drop-in staged"
    grep -q 'size 1M' "$ah_rot" && ok "5ah(b) drop-in rotates at size 1M" || bad "5ah(b) drop-in missing 'size 1M'"
    grep -q 'rotate 5' "$ah_rot" && ok "5ah(b) drop-in keeps rotate 5" || bad "5ah(b) drop-in missing 'rotate 5'"
    grep -q 'copytruncate' "$ah_rot" && ok "5ah(b) drop-in uses copytruncate (no signal needed)" || bad "5ah(b) drop-in missing 'copytruncate'"
    grep -q '/var/log/travel-router/\*.log' "$ah_rot" && ok "5ah(b) drop-in covers /var/log/travel-router/*.log" || bad "5ah(b) drop-in does not glob /var/log/travel-router/*.log"
  else
    bad "5ah(b) logrotate drop-in MISSING: $ah_rot"
  fi
  [[ -d "$ah/pfx/var/log/travel-router" ]] && ok "5ah(c) /var/log/travel-router created" \
    || bad "5ah(c) /var/log/travel-router NOT created under prefix"
  m=$(stat -f%Lp "$ah/pfx/var/log/travel-router/dhcp.log" 2>/dev/null || stat -c%a "$ah/pfx/var/log/travel-router/dhcp.log" 2>/dev/null)
  [[ "$m" == "644" ]] && ok "5ah(d) dhcp.log 0644 (MAC/IP metadata only, no PSKs)" || bad "5ah(d) dhcp.log mode=$m (want 644)"
  m=$(stat -f%Lp "$ah/pfx/var/log/travel-router/apconfig.log" 2>/dev/null || stat -c%a "$ah/pfx/var/log/travel-router/apconfig.log" 2>/dev/null)
  [[ "$m" == "644" ]] && ok "5ah(f) apconfig.log pre-created 0644 (durable AP-rename forensics)" \
    || bad "5ah(f) apconfig.log mode=$m (want 644) - install must pre-create it for the radio restart to log into"
  # The live-SSID record that ap-info/ap-apply read must be seeded by install and
  # must AGREE with the SSID actually rendered into the conf: an unwritten or
  # divergent ap-ssid is why the admin page reported ap_ssid:"" on a healthy AP.
  ah_ap_ssid="$ah/pfx/etc/rpi-project/travel-router/ap-ssid"
  if [[ -f "$ah_ap_ssid" ]]; then
    ok "5ah(e) install seeds the ap-ssid live-SSID record"
    m=$(stat -f%Lp "$ah_ap_ssid" 2>/dev/null || stat -c%a "$ah_ap_ssid" 2>/dev/null)
    [[ "$m" == "600" ]] && ok "5ah(e) ap-ssid 0600" || bad "5ah(e) ap-ssid mode=$m (want 600)"
    ah_rendered="$(sed -n 's/^ssid=//p' "$ah/pfx/etc/hostapd/hostapd-travel.conf" 2>/dev/null | head -1)"
    ah_seeded="$(head -1 "$ah_ap_ssid" 2>/dev/null)"
    [[ -n "$ah_rendered" && "$ah_seeded" == "$ah_rendered" ]] \
      && ok "5ah(e) ap-ssid agrees with the rendered conf SSID" \
      || bad "5ah(e) ap-ssid '$ah_seeded' != rendered conf ssid '$ah_rendered'"
  else
    bad "5ah(e) install did NOT seed $ah_ap_ssid"
  fi
else
  bad "5ah dry-run render run exited nonzero"
fi

# --- (5ai) minimal status page at / + /status gate (S01 rework) ---------------
sec "5ai minimal status page + /status gate (S01)"
# Fixture mirrors §5c/§5f: state with lan_ip=127.0.0.1 (the server BINDS that
# IP; 192.168.50.1 is not an address on the runner). §5f reuses $STW for the
# TRAVELWAN_BIN seam, but STW is a §5d-args stub; this battery writes its own
# tool seam at $B (mirrors the §5c fixture idiom).
printf '{"mode":"standalone","wan_if":"","wan_ssid":"HotelNet","wan_ip":"10.9.8.7","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/warn-state.json"
STW="$B/stub-travel-wan-warn"; printf '#!/bin/bash\nprintf %s "{\\"mode\\":\\"routed\\",\\"wan_if\\":\\"wlan1\\",\\"internet\\":\\"yes\\",\\"standalone\\":false}"\n' "$B" > "$STW"; chmod +x "$STW"
TRAVELWAN_BIN="$STW" TRAVELROUTER_STATE_FILE="$B/warn-state.json" TRAVELROUTER_STATUS_PORT=18101 TRAVELROUTER_BIND_HOST=127.0.0.1 \
  python3 "$A/status-server.py" >"$B/srv-warn.log" 2>&1 &
SPID1=$!
sleep 1.5
wait_healthy 18101 || true
# (1) / serves the minimal status page (S01): no sensitive device data
wh=$(curl -s http://127.0.0.1:18101/ 2>/dev/null)
wcode=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18101/ 2>/dev/null)
# Sensitive fields that must NOT appear in the public page
leak=""
for w in wan_ip "Hotel SSID" Standalone clients ap_state "clients_list"; do
  echo "$wh" | grep -qF "$w" && leak="$leak [$w]"
done
[[ "$wcode" == "200" ]] && ok "5ai(1) GET / -> 200" || bad "5ai(1) GET / code=$wcode (srv.log: $(tail -1 "$B/srv-warn.log" 2>/dev/null))"
[[ -n "$wh" ]] && [[ -z "$leak" ]] && ok "5ai(1) minimal page leaks no sensitive fields" || bad "5ai(1) sensitive data in / body: leak=$leak"
# The new page has the status-rows container + links-list + fetches /api/status
echo "$wh" | grep -qF 'id="status-rows"' && ok "5ai(1) minimal page has status-rows container" || bad "5ai(1) status-rows MISSING: $wh"
echo "$wh" | grep -qF 'Router address' && ok "5ai(1) minimal page renders a router-address row" || bad "5ai(1) router-address row MISSING"
echo "$wh" | grep -qF 'id="links-list"' && ok "5ai(1) minimal page has links-list" || bad "5ai(1) links-list MISSING"
# S06b F7: the Admin entry must reach the client. The rendered <a> is drawn by
# client-side JS (browser-only), but / serves _STATUS_HTML verbatim, so the served
# script source carries the array entry — assert on the SERVED body, not just the
# file, so an entry added to a non-served string cannot pass. -F is mandatory: the
# pattern contains [ and ] (regex metachars).
echo "$wh" | grep -qF '["Admin", "/admin"]' \
  && ok "5ai(1) served / carries the buildLinks Admin entry (rendered anchor is browser-only)" \
  || bad "5ai(1) served / MISSING the buildLinks /admin entry"
echo "$wh" | grep -qF '/api/status' && ok "5ai(1) minimal page fetches /api/status" || bad "5ai(1) /api/status fetch MISSING"
# The old warning phrase is GONE (replaced by the minimal status page)
echo "$wh" | grep -qF 'private travel network' && bad "5ai(1) old warning phrase still present" || ok "5ai(1) old warning phrase gone"
# (2) /health stays open
r=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18101/health 2>/dev/null)
[[ "$r" == "200" ]] && ok "5ai(2) /health 200 (unauthenticated)" || bad "5ai(2) /health code=$r"
# (3) /status is session-gated (S02): no session -> 401, body must not leak state
r=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18101/status 2>/dev/null)
sb=$(curl -s http://127.0.0.1:18101/status 2>/dev/null)
[[ "$r" == "401" ]] && ok "5ai(3) GET /status without session -> 401" || bad "5ai(3) GET /status code=$r (body: $sb)"
echo "$sb" | grep -qF 'wan_ip' && bad "5ai(3) 401 body leaks state: $sb" || ok "5ai(3) 401 body carries no state"
r=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Session: garbage-token' http://127.0.0.1:18101/status 2>/dev/null)
[[ "$r" == "401" ]] && ok "5ai(3) GET /status bogus X-Session -> 401" || bad "5ai(3) bogus X-Session code=$r"
# (4) captive-portal redirect intact (reuse the §5f R-test fixture idiom)
printf '{"mode":"standalone","wan_if":"","wan_ssid":"","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/warn-portal-state.json"
touch "$B/warn-portal-active.conf"
TRAVELWAN_BIN="$STW" TRAVELROUTER_STATE_FILE="$B/warn-portal-state.json" TRAVELROUTER_BIND_HOST=127.0.0.1 \
TRAVELROUTER_STATUS_PORT=18102 TRAVELROUTER_PORTAL_CONF="$B/warn-portal-active.conf" \
  python3 "$A/status-server.py" >"$B/srv-warn-portal.log" 2>&1 &
SPID2=$!
sleep 1.5
wait_healthy 18102 || true
r=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: captive.apple.com' http://127.0.0.1:18102/generate_204 2>/dev/null)
loc=$(curl -s -o /dev/null -w '%{redirect_url}' -H 'Host: captive.apple.com' http://127.0.0.1:18102/generate_204 2>/dev/null)
[[ "$r" == "302" ]] && ok "5ai(4) probe-Host + active PORTAL_CONF -> 302" || bad "5ai(4) code=$r (srv.log: $(tail -1 "$B/srv-warn-portal.log" 2>/dev/null))"
[[ "$loc" == "http://127.0.0.1:18102/" ]] && ok "5ai(4) Location -> / (public status page) on bound host+port" || bad "5ai(4) location=$loc"
kill $SPID1 2>/dev/null; wait $SPID1 2>/dev/null
kill $SPID2 2>/dev/null; wait $SPID2 2>/dev/null

# --- (5aj) locale pin: [ -~] ranges are collation-safe (glibc grep) -----------
# Pi evidence (rpi-e076fe, Debian trixie, GNU grep 3.11, LANG=en_US.UTF-8):
# printf 'travel-router' | grep -qE '^[ -~]{1,32}$'  -> NO MATCH (exit 1).
# glibc evaluates range expressions by COLLATION order, where ASCII letters
# sort AFTER '~', so every letter-bearing SSID/PSK failed the printable-ASCII
# validation on first boot. BSD grep (macOS runner) is byte-true, which is why
# this only surfaced on real hardware. install.sh must pin LC_ALL=C before any
# validation grep runs.
sec "5aj. locale pin (glibc collation breaks [ -~] ranges)"
INS="$ROOT/roles/travel-router/install.sh"
if grep -q 'export LC_ALL=C' "$INS"; then
  ok "5aj(1) install.sh pins LC_ALL=C"
else
  bad "5aj(1) LC_ALL=C pin MISSING (glibc collation rejects letter SSIDs on Pi)"
fi
pin_ln=$(grep -n 'export LC_ALL=C' "$INS" | head -1 | cut -d: -f1)
val_ln=$(grep -n 'grep -qE "$PRINTABLE_RE"' "$INS" | head -1 | cut -d: -f1)
[[ -n "${pin_ln:-}" && -n "${val_ln:-}" && "$pin_ln" -lt "$val_ln" ]] \
  && ok "5aj(2) pin exported BEFORE the SSID validation grep" \
  || bad "5aj(2) LC_ALL=C must be exported before the PRINTABLE_RE check"
# behavioral: a dashy ASCII SSID must validate with a hostile inherited locale
printf 'TRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\nTRAVELROUTER_ADMIN_PSK=AdminPass99\n' > "$TMP/aj.env"
out=$(LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 TRAVELROUTER_AP_SSID=travel-router \
      TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$TMP/aj" TRAVELROUTER_ROLE_ENV="$TMP/aj.env" \
      bash "$INS" 2>&1)
rc=$?
[[ $rc -eq 0 && "$out" == *"travel-router installed"* ]] \
  && ok "5aj(3) letter+dash SSID passes under hostile locale" \
  || bad "5aj(3) hostile-locale run rc=$rc: $(echo "$out" | head -2 | tr '\n' ' ')"
# the pin must not lobotomize rejection: a UTF-8 multibyte SSID is still illegal
out=$(LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 TRAVELROUTER_AP_SSID='Travel-Neté' \
      TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$TMP/aj2" TRAVELROUTER_ROLE_ENV="$TMP/aj.env" \
      bash "$INS" 2>&1)
rc=$?
[[ $rc -eq 1 && "$out" == *"remediation:"* ]] \
  && ok "5aj(4) multibyte SSID still rejected under the pin" \
  || bad "5aj(4) multibyte SSID rejection: rc=$rc (out: $(echo "$out" | head -2 | tr '\n' ' '))"

# --- (5ak) admin-PSK login + stateless HMAC session + two-factor writes -------
# Auth plan Todo 6 (C3/C4 server): POST /api/auth/login trades the admin PSK
# (constant-time compare, throttled by the SAME _PIN_FAILS counter) for a
# stateless HMAC-signed X-Session token (survives a process restart — no
# server-side store). Gated reads accept the token; every write needs a valid
# session, and ADMIN writes additionally need a correct body.pin;
# SETUP_PIN-unset -> 403 pin_unset on those admin writes. /health and / stay open.
sec "5ak. admin-PSK login + stateless session + two-factor writes"
printf '{"mode":"standalone","wan_if":"","wan_ssid":"FixtureNet","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/srv-state.json"
STWAK="$B/stub-travel-wan-ak"
printf '#!/bin/bash\ncase "$1" in known) printf "HotelNet\\t1690000000\\tyes\\n"; exit 0;; status) printf "{\\"mode\\":\\"routed\\",\\"wan_if\\":\\"wlan1\\",\\"internet\\":\\"yes\\",\\"standalone\\":false}"; exit 0;; connect|scan|recheck) exit 0;; esac\nexit 0\n' > "$STWAK"; chmod +x "$STWAK"
AKLOG="$B/c34-auth.txt"
: > "$AKLOG"
echo "=== 5ak admin-PSK/session transcript ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ===" >> "$AKLOG"
ak_start() { # port pin psk -> fresh server with PIN + ADMIN_PSK set
  TRAVELROUTER_SETUP_PIN="$2" TRAVELROUTER_ADMIN_PSK="$3" TRAVELWAN_BIN="$STWAK" \
  TRAVELROUTER_STATE_FILE="$B/srv-state.json" TRAVELROUTER_STATUS_PORT="$1" \
  TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >>"$B/srv-ak.log" 2>&1 &
  AKPID=$!
  wait_healthy "$1" || true
}
ak_start_nopin() { # port psk -> fresh server with SETUP_PIN UNSET
  env -u TRAVELROUTER_SETUP_PIN TRAVELROUTER_ADMIN_PSK="$2" TRAVELWAN_BIN="$STWAK" \
  TRAVELROUTER_STATE_FILE="$B/srv-state.json" TRAVELROUTER_STATUS_PORT="$1" \
  TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >>"$B/srv-ak-nopin.log" 2>&1 &
  AKNP_PID=$!
  wait_healthy "$1" || true
}
ak_stop() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
# login: psk(or empty) -> "code|body"; redaction: PSK body bytes never logged
ak_login() {
  local resp data
  data='{}'
  [[ -n "$1" ]] && data="{\"psk\":\"$1\"}"
  resp=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
    -H 'X-Requested-With: XMLHttpRequest' -d "$data" \
    http://127.0.0.1:18310/api/auth/login 2>/dev/null)
  echo "POST /api/auth/login psk=<redacted:len=${#1}> -> ${resp##*$'\n'}" >> "$AKLOG"
  echo "${resp##*$'\n'}|${resp%$'\n'*}"
}
# write: session pin -> "code|body" (pin "" = key omitted); secrets redacted
ak_write() {
  local data
  data='{"ssid":"HotelNet"}'
  [[ -n "$2" ]] && data="{\"pin\":\"$2\",\"ssid\":\"HotelNet\"}"
  resp=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
    -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $1" -d "$data" \
    http://127.0.0.1:18310/api/wan/connect 2>/dev/null)
  echo "POST /api/wan/connect sess=<redacted:len=${#1}> pin=<redacted:len=${#2}> -> ${resp##*$'\n'}" >> "$AKLOG"
  echo "${resp##*$'\n'}|${resp%$'\n'*}"
}
# admin write: session pin -> HTTP code (two-factor path: session AND body.pin;
# post-S03 the ONLY write bucket whose wrong pin feeds the _PIN_FAILS throttle)
ak_awrite() {
  local data resp
  data='{"action":"add-default","psk":"fixturepsk"}'
  [[ -n "$2" ]] && data="{\"action\":\"add-default\",\"psk\":\"fixturepsk\",\"pin\":\"$2\"}"
  resp=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $1" -d "$data" \
    http://127.0.0.1:18310/api/wan/psks-manage 2>/dev/null)
  echo "POST /api/wan/psks-manage sess=<redacted:len=${#1}> pin=<redacted:len=${#2}> -> $resp" >> "$AKLOG"
  echo "$resp"
}
ak_start 18310 2468 AdminPass99
# (1) login: correct PSK -> 200 + token; wrong/absent -> 401 {"error":"auth"}
l_ok=$(ak_login AdminPass99)
[[ "$l_ok" == 200'|'*'"token"'* ]] && ok "5ak(1) login correct PSK -> 200 + token" || bad "5ak(1) login good: [$l_ok]"
TOK=$(printf '%s' "$l_ok" | cut -d'|' -f2 | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
[[ -n "$TOK" ]] && ok "5ak(1) token extracted" || bad "5ak(1) token extraction failed"
l_wrong=$(ak_login WrongPsk1)
[[ "$l_wrong" == 401'|'*'"auth"'* ]] && ok "5ak(1) login wrong PSK -> 401 auth" || bad "5ak(1) login wrong: [$l_wrong]"
l_absent=$(ak_login "")
[[ "$l_absent" == 401'|'*'"auth"'* ]] && ok "5ak(1) login absent PSK -> 401 auth" || bad "5ak(1) login absent: [$l_absent]"
# (2) S03: /status + /api/wan/known are SESSION-gated reads — the session
# alone unlocks them; X-Pin without a session is not a credential anymore.
r=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Session: $TOK" http://127.0.0.1:18310/api/wan/known 2>/dev/null)
[[ "$r" == "200" ]] && ok "5ak(2) GET known + session -> 200 (S03: session is the credential)" || bad "5ak(2) known+session code=$r (want 200)"
r=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Session: $TOK" http://127.0.0.1:18310/status 2>/dev/null)
[[ "$r" == "200" ]] && ok "5ak(2) GET /status + session -> 200 (session is the credential, S02)" || bad "5ak(2) /status+session code=$r (want 200)"
r=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Pin: 2468' http://127.0.0.1:18310/api/wan/known 2>/dev/null)
[[ "$r" == "401" ]] && ok "5ak(2) GET /api/wan/known + X-Pin only -> 401 (PIN alone insufficient, S03)" || bad "5ak(2) known+pin code=$r (want 401)"
r=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Session: $TOK" http://127.0.0.1:18310/api/wan/psks-manage 2>/dev/null)
[[ "$r" == "200" ]] && ok "5ak(2) GET psks-manage + session -> 200 (admin read)" || bad "5ak(2) psks-manage+session code=$r"
EXPTOK=$(A="$A" python3 - <<'PYEOF'
import base64, hashlib, hmac, importlib.util, json, os
spec = importlib.util.spec_from_file_location(
    "ss", os.path.join(os.environ["A"], "status-server.py"))
m = spec.loader.load_module()
p = {"exp": 1000000000, "psk_fingerprint": m._psk_fingerprint()}
pb = base64.urlsafe_b64encode(json.dumps(p, separators=(",", ":")).encode()).rstrip(b"=")
sig = hmac.new(m._session_key(), pb, hashlib.sha256).digest()
print(pb.decode() + "." + base64.urlsafe_b64encode(sig).rstrip(b"=").decode())
PYEOF
)
for ep in status api/wan/known api/wan/psks-manage; do
  for t in garbage-token "$EXPTOK" ""; do
    r=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Session: $t" "http://127.0.0.1:18310/$ep" 2>/dev/null)
    if [[ "$ep" == "api/wan/psks-manage" ]]; then
      want="401"   # admin read: no/bad session -> 401
    else
      want="401"   # client read: no valid session token -> 401 auth (S03)
    fi
    [[ "$r" == "$want" ]] && ok "5ak(2) GET /$ep bad/expired/missing session -> $want" || bad "5ak(2) /$ep token=<len=${#t}> code=$r"
    cb=$(curl -s -H "X-Session: garbage-token" "http://127.0.0.1:18310/$ep" 2>/dev/null)
    [[ "$cb" == *'"auth"'* ]] || bad "5ak(2) /$ep 401 body=[$cb]"
  done
done
# (3) client writes need the session alone (body.pin ignored, S03); psks-manage
#     /apconfig are admin writes and stay two-factor. session -> 200 envelope
#     for a client write; an ADMIN write answers 403 {"error":"pin"} on a bad pin.
w_ok=$(ak_write "$TOK" "")
[[ "$w_ok" == 200'|'*'"lines"'* ]] && ok "5ak(3) write + session -> 200 envelope (S03: PIN not required)" || bad "5ak(3) write good: [$w_ok]"
for ep in scan status disconnect recheck; do
  r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $TOK" -d '{"pin":"2468"}' \
    "http://127.0.0.1:18310/api/wan/$ep" 2>/dev/null)
  [[ "$r" == "200" ]] && ok "5ak(3) POST /api/wan/$ep + session + pin -> 200" || bad "5ak(3) /$ep code=$r"
done
# (4) SETUP_PIN unset (unprovisioned): login still works; a session holder's
# CLIENT write -> 200 (pin_unset is an ADMIN-write concern post-S03), and a
# no-session write -> 401. The session (plus PIN on ADMIN writes) decides
# WHO may learn the router's provisioning state.
ak_start_nopin 18311 AdminPass99
np=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -d '{"psk":"AdminPass99"}' \
  http://127.0.0.1:18311/api/auth/login 2>/dev/null)
echo "nopin-login -> ${np##*$'\n'}" >> "$AKLOG"
[[ "$np" == *'"token"'* ]] && [[ "$np" == *$'\n'200 ]] && ok "5ak(4) login still works when PIN unset" || bad "5ak(4) nopin login: [$np]"
NPTOK=$(printf '%s' "$np" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p' | head -1)
npw=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $NPTOK" -d '{"ssid":"HotelNet"}' \
  http://127.0.0.1:18311/api/wan/connect 2>/dev/null)
echo "nopin-write -> ${npw##*$'\n'} body=${npw%$'\n'*}" >> "$AKLOG"
[[ "$npw" == *$'\n'200 ]] && ok "5ak(4) PIN unset + session -> 200 (S03: PIN not required)" || bad "5ak(4) nopin write: [$npw]"
# Post-S03 a client write on an un-provisioned router is a session question,
# not a pin one: with a session -> 200 (above), without one -> 401 (below).
# pin_unset is answered only on ADMIN writes, and the 403-vs-401 split for
# WRONG pins is covered on the PIN-set servers above.
npns=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -d '{"ssid":"HotelNet"}' \
  http://127.0.0.1:18311/api/wan/connect 2>/dev/null)
[[ "$npns" == *'"auth"'* && "$npns" == *$'\n'401 ]] \
  && ok "5ak(4) no-session write -> 401 auth (S03: session required)" || bad "5ak(4) no-session write: [$npns]"
ak_stop $AKNP_PID
# (5) /health + / stay open on the main server
r=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18310/health 2>/dev/null)
[[ "$r" == "200" ]] && ok "5ak(5) /health 200 with no session" || bad "5ak(5) /health code=$r"
wh5=$(curl -s http://127.0.0.1:18310/ 2>/dev/null)
leak5=""
for w in wan_ip "Hotel SSID" Standalone clients ap_state "clients_list"; do
  echo "$wh5" | grep -qF "$w" && leak5="$leak5 [$w]"
done
[[ -z "$leak5" ]] && ok "5ak(5) / minimal page leaks no sensitive fields" || bad "5ak(5) / leak=$leak5"
# (6) throttle escalates on wrong pins even with a valid session (same _PIN_FAILS)
ak_stop $AKPID  # part-1 done; relaunch fresh so count starts at 0 (127.0.0.1 shared key)
ak_start 18310 2468 AdminPass99
lt=$(ak_login AdminPass99)
TOK6=$(printf '%s' "$lt" | cut -d'|' -f2 | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
codes6=""
for i in 1 2 3 4 5; do codes6="$codes6$(ak_awrite "$TOK6" "badpin$i") "; done
[[ "$codes6" == "403 403 403 403 403 " ]] \
  && ok "5ak(6) 5 wrong pins w/ session -> 403 pin x5 (arming throttle)" || bad "5ak(6) codes=[$codes6]"
r6=$(ak_awrite "$TOK6" badpin6)
[[ "$r6" == "429" ]] || r6=$(ak_awrite "$TOK6" badpin6)
[[ "$r6" == "429" ]] && ok "5ak(6) 6th wrong pin w/ session -> 429 (throttle armed despite session)" \
  || bad "5ak(6) 6th=$r6 (want 429; session bypassed throttle?)"
r429=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $TOK6" -d '{"psk":"AdminPass99"}' \
  http://127.0.0.1:18310/api/auth/login 2>/dev/null)
echo "blocked-login -> ${r429##*$'\n'} body=${r429%$'\n'*}" >> "$AKLOG"
[[ "$r429" == *'"rate_limited"'* && "$r429" == *$'\n'429 ]] \
  && ok "5ak(6) login shares the _PIN_FAILS throttle (429 rate_limited when armed)" \
  || bad "5ak(6) login while armed: [$r429]"
sleep 5.5
rok=$(ak_awrite "$TOK6" 2468)
[[ "$rok" == "200" ]] && ok "5ak(6) session + correct pin after tier expiry -> 200 (no bypass, no lockout)" \
  || bad "5ak(6) post-expiry write=$rok (want 200)"
ak_stop $AKPID
grep -qE 'AdminPass99|2468|badpin[0-9]' "$AKLOG" && bad "5ak secret material leaked into transcript (forbidden)" \
  || ok "5ak transcript free of PSK/PIN/token"
grep -qE 'AdminPass99|2468|badpin[0-9]' "$AKLOG" && bad "5ak secret material leaked into transcript (forbidden)" \
  || ok "5ak transcript free of PSK/PIN/token"
echo "5ak auth transcript: $AKLOG"

# --- (5al) admin.html login gate + session header + clients UI -----------------
# Admin plan todos 5-7: the login/session/clients machinery MOVED from
# setup.html to admin.html; S04 removed setup.html entirely (merged). The
# "Recently connected" /api/wan/log UI was replaced by the audit table
# (security plan todo 8) — re-pointed at the /api/admin/audit fetch.
sec "5al. admin.html login gate + X-Session + clients + audit sections"
# (1) static contract asserts (grep-style, mirroring the §5x batteries)
grep -qF 'fetch("/api/auth/login"' "$A/admin.html" \
  && ok "5al(1) admin.html wires the login fetch call site" || bad "5al(1) login endpoint fetch MISSING"
# S06: the dead GET-bucket PIN gate is GONE — _pin_gate/_require_pin_header
# had zero call sites since S03 (X-Pin on GETs is never consulted). The LIVE
# pins (SETUP_PIN/_pin_ok/_PIN_FAILS/403-pin admin writes) must all survive.
# Grep shape is match-or-not (never `grep -c | grep -q`: under pipefail a
# zero-match count exits 1 and poisons the pipe even when 0 is the wanted
# answer). Single-quoted symbols guard regex metachars.
if grep -qE '_pin_gate\(|_require_pin_header\(' "$A/status-server.py"; then
  bad "5al(1) zombie _pin_gate/_require_pin_header present"
else
  ok "5al(1) S06 dead GET-pin gate removed (0 call-site/def hits)"
fi
for sym in 'SETUP_PIN' '_pin_ok' '_PIN_FAILS' '"pin"' '"pin_unset"'; do
  grep -qF "$sym" "$A/status-server.py" \
    && ok "5al(1) S06 admin-write PIN seam kept: $sym" || bad "5al(1) admin PIN seam MISSING: $sym"
done
sess_sites=$(grep -c -F 'X-Session' "$A/admin.html")
[[ "$sess_sites" == "5" ]] && ok "5al(1) X-Session present at exactly $sess_sites sites (impl + doc comments; S06 poll-comment rewrite dropped one incidental prose hit)" \
  || bad "5al(1) X-Session sites=$sess_sites (want 5)"
sess_hdr_sites=$(grep -c -F '"X-Session"' "$A/admin.html")
[[ "$sess_hdr_sites" == "1" ]] && ok "5al(1) sessionFetch attaches X-Session at its single impl site" \
  || bad "5al(1) explicit X-Session header sites=$sess_hdr_sites (want 1; a dropped attach site is invisible to sessionFetch)"
grep -qF 'admin-session' "$A/admin.html" \
  && ok "5al(1) localStorage key admin-session present" || bad "5al(1) admin-session key MISSING"
grep -qE 'id="rotate-sessions-btn"' "$A/admin.html" \
  && ok "5al(1) session-drop control present (rotate-sessions-btn; logout = salt rotation)" \
  || bad "5al(1) session-drop control MISSING"
grep -qF 'Connected clients' "$A/admin.html" && grep -qF 'clients_list' "$A/admin.html" \
  && ok "5al(1) Connected clients section + /status clients_list fetch" \
  || bad "5al(1) Connected clients section/clients_list MISSING"
grep -qF '/api/admin/audit' "$A/admin.html" \
  && ok "5al(1) audit section + /api/admin/audit fetch (replaces the /api/wan/log UI)" \
  || bad "5al(1) audit section/audit fetch MISSING"
grep -qF 'id="net-status-rows"' "$A/admin.html" \
  && ok "5al(1) Network status section present (U02)" || bad "5al(1) net-status section MISSING"
grep -qF 'd.wan_ip' "$A/admin.html" \
  && ok "5al(1) admin renders WAN address (U02)" || bad "5al(1) admin WAN address MISSING"
sink_hits=$(grep -c -E 'innerHTML|insertAdjacentHTML|document\.write' "$A/admin.html")
[[ "$sink_hits" == "0" ]] && ok "5al(1) no innerHTML/insertAdjacentHTML/document.write" \
  || bad "5al(1) forbidden DOM sink count=$sink_hits"
grep -qF 'PIN required — enter it in the PIN section' "$A/admin.html" \
  && ok "5al(1) mcWrite PIN-guard string still present" || bad "5al(1) PIN-guard string GONE"
# server must expose the session-gated log read this UI consumes
if awk '/elif path == "\/api\/wan\/psks-manage"/{f=1} f && /elif path == "\/api\/wan\/log"/{g=1} f && /elif path == "\/admin"/{exit} END{exit !(f&&g)}' "$A/status-server.py"; then
  ok "5al(1) status-server.py has session-gated GET /api/wan/log after psks-manage"
else
  bad "5al(1) GET /api/wan/log branch MISSING (or misplaced) in do_GET"
fi
# (3) simulated-401 client path: a shared handleAuth clears the session so the
#     UI drops back to login (static evidence — browser E2E is user-gated)
if grep -qF 'function handleAuth' "$A/admin.html" \
   && grep -qF 'localStorage.removeItem("admin-session")' "$A/admin.html"; then
  # handleAuth's call sites sit below a 401 discriminator within the same
  # handler chain (sessionFetch's 401 branch); grep the SESSIONFETCH body
  # for the discrimination instead of handleAuth's own 3 preceding lines.
  n401=$(sed -n "/function sessionFetch/,/^}/p" "$A/admin.html" | grep -c -F '401')
  [[ "$n401" -ge 1 ]] && ok "5al(3) handleAuth clears admin-session on 401" \
    || bad "5al(3) handleAuth has no 401 discrimination"
else
  bad "5al(3) handleAuth / localStorage.removeItem(\"admin-session\") MISSING"
fi
# (2) runtime session flow against the REAL server: login -> X-Session ->
#     GET /api/admin/audit returns the fixture ring rows (the admin-page UI's
#     authed read); GET /api/wan/log stays the session-gated server read the
#     section documents; no session -> 401.
printf '{"mode":"standalone","wan_if":"","wan_ssid":"","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/srv-state-al.json"
printf 'Oct  1 12:00:00 dnsmasq-dhcp: DHCPACK(wlan0) 192.168.50.101 aa:bb:cc:dd:ee:01 phone\n' > "$B/al-dhcp.log"
printf 'Oct  1 12:01:00 dnsmasq-dhcp: DHCPACK(wlan0) 192.168.50.102 aa:bb:cc:dd:ee:02 laptop\n' >> "$B/al-dhcp.log"
printf '\n' >> "$B/al-dhcp.log"
printf 'Oct  1 12:02:00 dnsmasq-dhcp: DHCPDISCOVER(wlan0) aa:bb:cc:dd:ee:03\n' >> "$B/al-dhcp.log"
al_start() { # port logfile(pin+psk fixed below)
  TRAVELROUTER_SETUP_PIN=2468 TRAVELROUTER_ADMIN_PSK=AdminPass99 TRAVELWAN_BIN="$STWAK" \
  TRAVELROUTER_STATE_FILE="$B/srv-state-al.json" TRAVELROUTER_STATUS_PORT="$1" \
  TRAVELROUTER_LOG_FILE="$2" \
  TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >>"$B/srv-al.log" 2>&1 &
  ALPID=$!
  wait_healthy "$1" || true
}
al_stop() { kill "$ALPID" 2>/dev/null; wait "$ALPID" 2>/dev/null; }
al_start 18410 "$B/al-dhcp.log"
al_login=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -d '{"psk":"AdminPass99"}' \
  http://127.0.0.1:18410/api/auth/login 2>/dev/null)
[[ "$al_login" == *'"token"'* && "$al_login" == *$'\n'200 ]] \
  && ok "5al(2) login correct PSK -> 200 token (log-server)" || bad "5al(2) login: [$al_login]"
ALTOK=$(printf '%s' "$al_login" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p' | head -1)
# a WRONG-psk login is an auth failure -> audited (given/when/then live)
al_bad=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -d '{"psk":"WrongPsk1"}' \
  http://127.0.0.1:18410/api/auth/login 2>/dev/null)
[[ "$al_bad" == "401" ]] && ok "5al(2) wrong-psk login -> 401" || bad "5al(2) wrong-psk login code=$al_bad"
al_audit=$(curl -s -w '\n%{http_code}' -H "X-Session: $ALTOK" http://127.0.0.1:18410/api/admin/audit 2>/dev/null)
[[ "$al_audit" == *'"attempts"'* && "$al_audit" == *$'\n'200 ]] \
  && ok "5al(2) GET /api/admin/audit + session -> 200 {\"attempts\":[...]}" || bad "5al(2) audit+session: [$al_audit]"
al_arows=$(printf '%s' "$al_audit" | sed -n '1p' | grep -o '"code": *40[139]' | wc -l | tr -d ' ')
[[ "$al_arows" -ge 1 ]] && ok "5al(2) audit ring carries the login-failure row (kind/code)" \
  || bad "5al(2) audit ring empty: [$(printf '%s' "$al_audit" | head -1)]"
al_ns=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18410/api/admin/audit 2>/dev/null)
[[ "$al_ns" == "401" ]] && ok "5al(2) GET /api/admin/audit NO session -> 401" || bad "5al(2) audit no-session code=$al_ns"
al_stop
# missing log file degrades to an empty array, never a 5xx (same contract the
# /api/admin/audit read gives an absent AUDIT_FILE)
al_start 18411 "$B/al-dhcp-absent.log"
al_login2=$(curl -s -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -d '{"psk":"AdminPass99"}' \
  http://127.0.0.1:18411/api/auth/login 2>/dev/null)
ALTOK2=$(printf '%s' "$al_login2" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p' | head -1)
al_miss=$(curl -s -w '\n%{http_code}' -H "X-Session: $ALTOK2" http://127.0.0.1:18411/api/wan/log 2>/dev/null)
[[ "$al_miss" == *'"log": []'* && "$al_miss" == *$'\n'200 ]] \
  && ok "5al(2) missing log file -> 200 {\"log\": []}" || bad "5al(2) missing-file: [$al_miss]"
al_audit_miss=$(curl -s -w '\n%{http_code}' -H "X-Session: $ALTOK2" http://127.0.0.1:18411/api/admin/audit 2>/dev/null)
[[ "$al_audit_miss" == *'"attempts": []'* && "$al_audit_miss" == *$'\n'200 ]] \
  && ok "5al(2) empty audit ring -> 200 {\"attempts\": []}" || bad "5al(2) missing-audit: [$al_audit_miss]"
al_stop
# (4) covered by the suite green gate at the end of this file.

# --- (5am) cmd_connect explicit-profile upsert (NM 1.52 key-mgmt fix) ---------
# Pi evidence (rpi-e076fe, NetworkManager 1.52.1, Trixie): `nmcli dev wifi
# connect <SSID> ... password <psk>` fails when a profile for that SSID
# already exists — NM's update path writes wifi-sec.psk WITHOUT key-mgmt and
# the profile validator rejects it: "802-11-wireless-security.key-mgmt:
# property is missing" (reproduced live; AP lookup itself is fine). The fix
# keeps cmd_connect on the explicit ensure-profile + connection-up idiom the
# seed (install.sh 4b) and try-psks probe already use. The battery stubs
# NMCLI and asserts the exact argv classes cmd_connect must emit.
sec "5am. connect uses explicit profile upsert (no dev wifi connect)"
AMB="$B/5am"; mkdir -p "$AMB/sys/class/net/wlan1"
AMSH="$AMB/tw-am.sh"
sed "s|/sys/class/net|$AMB/sys/class/net|g" "$A/travel-wan.sh" > "$AMSH"
cat > "$AMB/nmcli" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$(dirname "$0")/nmcli.log"
case " $* " in
  *" connection show "*|*"-f NAME connection show"*)
    [[ -f "$(dirname "$0")/names" ]] && cat "$(dirname "$0")/names"
    ;;
esac
exit 0
EOF
printf '#!/bin/bash\nexec "$@"\n' > "$AMB/sudo"; chmod +x "$AMB/nmcli" "$AMB/sudo"
amenv=(NMCLI="$AMB/nmcli" SUDO="$AMB/sudo" IP=/nonexistent CURL=/nonexistent HOSTAPD_CLI=/nonexistent
       TRAVELROUTER_PSK_FILE="$B/5am-psks" TRAVELROUTER_STATE_FILE="$B/am-state.json")
printf '{"mode":"standalone","wan_if":"wlan1","wan_ssid":"","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/am-state.json"
# (1) PSK connect, NO existing profile -> connection add WITH key-mgmt + up
: > "$AMB/names"; rm -f "$AMB/nmcli.log"
env "${amenv[@]}" bash "$AMSH" connect FixNet fixpsk1 >/dev/null 2>&1
am_add=$(grep 'connection add' "$AMB/nmcli.log" | head -1)
am_up=$(grep -F 'connection up FixNet' "$AMB/nmcli.log" | head -1)
if [[ -n "$am_add" ]] && printf '%s' "$am_add" | grep -qF 'wifi-sec.key-mgmt wpa-psk' \
   && printf '%s' "$am_add" | grep -qF 'wifi-sec.psk fixpsk1' \
   && grep -qF 'connection up FixNet' "$AMB/nmcli.log" \
   && ! grep -qF 'dev wifi connect' "$AMB/nmcli.log"; then
  ok "5am(1) psk connect: explicit profile add with key-mgmt+psk, then up (no dev wifi connect)"
else
  bad "5am(1) create-path argv wrong: add=[$am_add] up=[$am_up] (dev-wifi-connect present: $(grep -cF 'dev wifi connect' "$AMB/nmcli.log" 2>/dev/null))"
fi
# (2) PSK connect when the profile EXISTS -> modify with key-mgmt, then up
: > "$AMB/nmcli.log"; printf 'FixNet\n' > "$AMB/names"
env "${amenv[@]}" bash "$AMSH" connect FixNet fixpsk1 >/dev/null 2>&1
if grep -qF 'connection modify FixNet' "$AMB/nmcli.log" \
   && grep -F 'connection modify' "$AMB/nmcli.log" | grep -qF 'wifi-sec.key-mgmt wpa-psk' \
   && grep -F 'connection modify' "$AMB/nmcli.log" | grep -qF 'wifi-sec.psk fixpsk1' \
   && grep -qF 'connection up FixNet' "$AMB/nmcli.log" \
   && ! grep -qF 'connection add' "$AMB/nmcli.log" \
   && ! grep -qF 'dev wifi connect' "$AMB/nmcli.log"; then
  ok "5am(2) existing profile: modify (key-mgmt preserved) + up, no duplicate add"
else
  bad "5am(2) modify-path argv wrong: $(tail -2 "$AMB/nmcli.log" | tr '\n' '|')"
fi
# (3) open-network connect -> profile WITHOUT any wifi-sec, still no one-shot
: > "$AMB/nmcli.log"; : > "$AMB/names"
env "${amenv[@]}" bash "$AMSH" connect OpenNet >/dev/null 2>&1
am_open=$(grep 'connection add' "$AMB/nmcli.log" | head -1)
if [[ -n "$am_open" ]] && ! printf '%s' "$am_open" | grep -qF 'wifi-sec' \
   && grep -qF 'connection up OpenNet' "$AMB/nmcli.log" \
   && ! grep -qF 'dev wifi connect' "$AMB/nmcli.log"; then
  ok "5am(3) open network: add without wifi-sec, then up (no dev wifi connect)"
else
  bad "5am(3) open-path argv wrong: add=[$am_open]"
fi

# --- (5an) travel-router ap-stealth: random SSID + hide-AP through apconfig ---
# Plan .omo/plans/travel-router-ap-stealth.md, Todos 1+2:
#   (i)   travel-wan ap-apply renders ignore_broadcast_ssid=2 when the 3rd slot
#         is "2", omits the line when "0"/"", and PRESERVES an existing flag
#         when the slot is "".
#   (ii)  the rollback contract still holds with the new render (hostapd -t
#         reject -> nothing installed; restart fail -> .bak restored).
#   (iii) /api/wan/apconfig accepts ssid:"random" -> the SERVER generates the
#         name (secrets.choice over A-HJ-NP-Z2-9, 8 chars) and returns it in
#         the response envelope; hidden:true/false/absent post to the tool's
#         3rd slot as "2"/"0"/"".
#   (iv)  admin.html static contract (S04: setup.html merged): Random button,
#         hidden checkbox -> hidden:true post, rejoin warning, localStorage
#         "admin-last-ssid", no innerHTML sinks, X-Session census.
sec "5an. random SSID + hide-AP in the apconfig flow"

# --------- (i) RENDER: ap-apply [SSID] [PSK] [HIDDEN] against fixtures -------
ANB="$B/5an"; mkdir -p "$ANB/ap-etc" "$ANB/sys/class/net"
ANSH="$ANB/tw-an.sh"
ANRENV="$ANB/role.env"
# Fixture role.env deliberately omits TRAVELROUTER_AP_COUNTRY: that mirrors
# the card's role.env (read off disk 2026-09-22) — the render must fall back
# (WIFI_COUNTRY, then US), never emit an empty country_code= line.
printf 'TRAVELROUTER_AP_SSID=BaseNet\nTRAVELROUTER_AP_PSK=BasePass123\nWIFI_COUNTRY=US\nTRAVELROUTER_AP_CHANNEL=6\nTRAVELROUTER_AP_INTERFACE=uap0\nTRAVELROUTER_ADMIN_PSK=AdminPass99\n' > "$ANRENV"
# sed-copy the script: rewire the role.env two-path discovery (hardcoded
# /run/travel-router/role.env candidates) + the state file to our fixtures.
# ctrl_interface= is neutered: the fixture confs declare none, so the
# liveness poll self-skips instead of polling /var/run/hostapd on this Mac.
sed -e "s|/run/travel-router/role.env|$ANRENV|g" \
    -e "s|/boot/firmware/role/role.env|/nonexistent-role.env|g" \
    -e "s|/boot/role/role.env|/nonexistent-role.env|g" \
    -e "s|/sys/class/net|$ANB/sys/class/net|g" \
    -e "s|/run/travel-router/state.json|$ANB/state.json|g" \
    -e "s|ctrl_interface=/var/run/hostapd|ctrl_interface=|g" \
    "$A/travel-wan.sh" > "$ANSH"
ap_iface_fixture() { : > "$1"; } # no-op doc anchor; interface comes from role.env fixture above
# HOSTAPD stub that emulates a parse error: prints the marker hostapd prints
# BEFORE driver init and exits 1 (parse gate trips -> ap-apply aborts).
ANHAP_BAD="$ANB/hostapd-bad"
printf '#!/bin/bash\ncat <<MSG >&2\nConfiguration file: %s\nLine 12: unknown configuration item bogus_xyz\n1 errors found in configuration file\nMSG\nexit 1\n' '$1' > "$ANHAP_BAD"
# HOSTAPD stub that emulates a parse-VALID conf dying at driver init on the
# dead probe iface: rc 1, NO parse-error marker (ap-apply must proceed).
ANHAP_OK="$ANB/hostapd-ok"
printf '#!/bin/bash\ncat <<MSG\nnl80211: Could not configure driver mode\nnl80211 driver initialization failed.\nMSG\nexit 1\n' > "$ANHAP_OK"
chmod +x "$ANHAP_OK" "$ANHAP_BAD"
# SUDO passthrough (same idiom as §5am/§5z) and SYSTEMCTL stubs
ANSUDO="$ANB/sudo"; printf '#!/bin/bash\nexec "$@"\n' > "$ANSUDO"; chmod +x "$ANSUDO"
ANCTL_OK="$ANB/systemctl-ok"
printf '#!/bin/bash\nprintf "systemctl %%s\\n" "$*" >> "$(dirname "$0")/systemctl.log"\ncase "$1" in is-active) echo active; exit 0;; show) echo running; exit 0;; esac\nexit 0\n' > "$ANCTL_OK"
chmod +x "$ANCTL_OK"
ANCTL_BAD="$ANB/systemctl-bad"
printf '#!/bin/bash\nprintf "systemctl %%s\\n" "$*" >> "$(dirname "$0")/systemctl.log"\nexit 1\n' > "$ANCTL_BAD"
chmod +x "$ANCTL_BAD"
anenv=(SUDO="$ANSUDO" HOSTAPD_CLI=/nonexistent NMCLI=/nonexistent IP=/nonexistent CURL=/nonexistent
       TRAVELROUTER_AP_CONF="$ANB/ap-etc/hostapd-travel.conf"
       TRAVELROUTER_AP_TEMPLATE="$A/hostapd.conf.tmpl"
       TRAVELROUTER_AP_SSID_FILE="$ANB/ap-ssid"
       TRAVELROUTER_STATE_FILE="$ANB/state.json")
# baseline conf BEFORE ap-apply: a "currently visible" render (no ignore_broadcast_ssid line).
printf 'interface=uap0\nssid=BaseNet\n' > "$ANB/ap-etc/hostapd-travel.conf"
printf 'BaseNet\n' > "$ANB/ap-ssid"
printf '{"mode":"standalone","wan_if":"","wan_ssid":"","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"uap0"}' > "$ANB/state.json"

# (i-a) hidden slot "2" -> rendered conf contains ignore_broadcast_ssid=2
: > "$ANB/hostapd.log"; : > "$ANB/systemctl.log"
TRAVELROUTER_HOSTAPD_BIN="$ANHAP_OK" SYSTEMCTL="$ANCTL_OK" TRAVELROUTER_SKIP_CTRL_POLL=1 \
  env "${anenv[@]}" bash "$ANSH" ap-apply Net1234 Net1234psk "2" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 ]] && grep -qF 'ignore_broadcast_ssid=2' "$ANB/ap-etc/hostapd-travel.conf"; then
  ok "5an(i-a) ap-apply hidden slot '2' renders ignore_broadcast_ssid=2"
else
  bad "5an(i-a) hidden slot '2' rc=$rc conf=[$(cat "$ANB/ap-etc/hostapd-travel.conf" | grep -E 'ignore_broadcast_ssid' || echo none)]"
fi

# (i-b) hidden slot "" with NO existing ignore_broadcast_ssid -> line stays absent
printf 'interface=uap0\nssid=BaseNet\n' > "$ANB/ap-etc/hostapd-travel.conf"
printf 'BaseNet\n' > "$ANB/ap-ssid"
TRAVELROUTER_HOSTAPD_BIN="$ANHAP_OK" SYSTEMCTL="$ANCTL_OK" TRAVELROUTER_SKIP_CTRL_POLL=1 \
  env "${anenv[@]}" bash "$ANSH" ap-apply NextNet NextPass1 "" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 ]] && ! grep -qF 'ignore_broadcast_ssid' "$ANB/ap-etc/hostapd-travel.conf"; then
  ok "5an(i-b) empty hidden slot + no prior flag -> directive absent (visible)"
else
  bad "5an(i-b) empty slot rc=$rc conf=[$(grep -E 'ignore_broadcast_ssid' "$ANB/ap-etc/hostapd-travel.conf" || echo none)]"
fi

# (i-c) hidden slot "0" -> directive absent even if fixture currently has one
printf 'interface=uap0\nssid=BaseNet\n' > "$ANB/ap-etc/hostapd-travel.conf"
printf 'BaseNet\n' > "$ANB/ap-ssid"
TRAVELROUTER_HOSTAPD_BIN="$ANHAP_OK" SYSTEMCTL="$ANCTL_OK" TRAVELROUTER_SKIP_CTRL_POLL=1 \
  env "${anenv[@]}" bash "$ANSH" ap-apply NextNet NextPass1 "0" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 ]] && ! grep -qF 'ignore_broadcast_ssid' "$ANB/ap-etc/hostapd-travel.conf"; then
  ok "5an(i-c) hidden slot '0' -> directive absent (explicit visible)"
else
  bad "5an(i-c) slot '0' rc=$rc conf=[$(grep -E 'ignore_broadcast_ssid' "$ANB/ap-etc/hostapd-travel.conf" || echo none)]"
fi

# (i-d) empty hidden slot MUST PRESERVE an existing ignore_broadcast_ssid=2
# (psk-only change must not silently un-hide). STALE_STATE probe case.
printf 'interface=uap0\nssid=BaseNet\nignore_broadcast_ssid=2\n' > "$ANB/ap-etc/hostapd-travel.conf"
printf 'BaseNet\n' > "$ANB/ap-ssid"
TRAVELROUTER_HOSTAPD_BIN="$ANHAP_OK" SYSTEMCTL="$ANCTL_OK" TRAVELROUTER_SKIP_CTRL_POLL=1 \
  env "${anenv[@]}" bash "$ANSH" ap-apply "" NewPskOnly9 "" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 ]] && grep -qF 'ignore_broadcast_ssid=2' "$ANB/ap-etc/hostapd-travel.conf"; then
  ok "5an(i-d) empty hidden slot preserves existing ignore_broadcast_ssid=2"
else
  bad "5an(i-d) preserve rc=$rc conf=[$(grep -E 'ignore_broadcast_ssid' "$ANB/ap-etc/hostapd-travel.conf" || echo none)]"
fi

# (i-f) country fallback: role.env carries NO TRAVELROUTER_AP_COUNTRY (card
# reality 2026-09-22) -> the render must fall back to WIFI_COUNTRY (US) and
# NEVER emit an empty country_code= line (the outage-#2 render suspect).
printf 'interface=uap0\nssid=BaseNet\n' > "$ANB/ap-etc/hostapd-travel.conf"
printf 'BaseNet\n' > "$ANB/ap-ssid"
TRAVELROUTER_HOSTAPD_BIN="$ANHAP_OK" SYSTEMCTL="$ANCTL_OK" TRAVELROUTER_SKIP_CTRL_POLL=1 \
  env "${anenv[@]}" bash "$ANSH" ap-apply CtryNet CtryPass1 "" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 ]] && grep -qF 'country_code=US' "$ANB/ap-etc/hostapd-travel.conf"; then
  ok "5an(i-f) country falls back to WIFI_COUNTRY when AP_COUNTRY unset"
else
  bad "5an(i-f) country rc=$rc line=[$(grep -E '^country_code=' "$ANB/ap-etc/hostapd-travel.conf" 2>/dev/null || echo none)]"
fi

# (i-e) ap-apply forwards 3 args correctly: '2'/'0'/'' land in slot 3, not 2
# A psk-ONLY change with hidden:"" must keep the SSID from the ap-ssid file,
# and the hidden slot must reach the tool's $3 (never $2 which is psk).
printf 'hidden3=%s\n' "${3:-MISSING}" > "$ANB/argv-capture" 2>/dev/null || true

# --------- (ii) ROLLBACK: hostapd -t reject and restart-fail ----------------
# (ii-a) hostapd -t rejects -> rc nonzero, AP_CONF unchanged, no .bak swap
printf 'interface=uap0\nssid=BaseNet\n' > "$ANB/ap-etc/hostapd-travel.conf"
printf 'BaseNet\n' > "$ANB/ap-ssid"
cp "$ANB/ap-etc/hostapd-travel.conf" "$ANB/ap-etc/pre-reject.conf"
TRAVELROUTER_HOSTAPD_BIN="$ANHAP_BAD" SYSTEMCTL="$ANCTL_OK" \
  env "${anenv[@]}" bash "$ANSH" ap-apply ChangedNet ChangedPass1 "2" >/dev/null 2>&1
rc=$?
if [[ $rc -ne 0 ]] && cmp -s "$ANB/ap-etc/hostapd-travel.conf" "$ANB/ap-etc/pre-reject.conf" \
   && [[ ! -e "$ANB/ap-etc/hostapd-travel.conf.bak" ]]; then
  ok "5an(ii-a) hostapd -t reject -> rc!=0, conf unchanged, no .bak"
else
  bad "5an(ii-a) reject rc=$rc conf-diff=$(cmp -s "$ANB/ap-etc/hostapd-travel.conf" "$ANB/ap-etc/pre-reject.conf"; echo $?) bak=$( [[ -e "$ANB/ap-etc/hostapd-travel.conf.bak" ]] && echo present || echo absent)"
fi

# (ii-b) restart failure -> .bak restored and restart retried (rollback contract)
printf 'interface=uap0\nssid=BaseNet\n' > "$ANB/ap-etc/hostapd-travel.conf"
printf 'BaseNet\n' > "$ANB/ap-ssid"
cp "$ANB/ap-etc/hostapd-travel.conf" "$ANB/ap-etc/pre-fail.conf"
TRAVELROUTER_HOSTAPD_BIN="$ANHAP_OK" SYSTEMCTL="$ANCTL_BAD" \
  env "${anenv[@]}" bash "$ANSH" ap-apply ChangedNet ChangedPass1 "2" >/dev/null 2>&1
rc=$?
if [[ $rc -ne 0 ]] && cmp -s "$ANB/ap-etc/hostapd-travel.conf" "$ANB/ap-etc/pre-fail.conf"; then
  ok "5an(ii-b) restart-fail -> .bak restored over the new conf (rollback)"
else
  bad "5an(ii-b) restart-fail rc=$rc conf-diff=$(cmp -s "$ANB/ap-etc/hostapd-travel.conf" "$ANB/ap-etc/pre-fail.conf"; echo $?)"
fi

# (ii-c) Type=simple liveness: ctrl socket NEVER appears (daemon died after a
# rc-0 restart) -> liveness gate trips, .bak restored, rc nonzero.
printf 'interface=uap0\nssid=BaseNet\n' > "$ANB/ap-etc/hostapd-travel.conf"
printf 'BaseNet\n' > "$ANB/ap-ssid"
cp "$ANB/ap-etc/hostapd-travel.conf" "$ANB/ap-etc/pre-dead.conf"
mkdir -p "$ANB/ctrl-empty"
TRAVELROUTER_HOSTAPD_BIN="$ANHAP_OK" SYSTEMCTL="$ANCTL_OK" TRAVELROUTER_CTRL_DIR="$ANB/ctrl-empty" \
  env "${anenv[@]}" bash "$ANSH" ap-apply ChangedNet ChangedPass1 "2" >/dev/null 2>&1
rc=$?
if [[ $rc -ne 0 ]] && cmp -s "$ANB/ap-etc/hostapd-travel.conf" "$ANB/ap-etc/pre-dead.conf"; then
  ok "5an(ii-c) dead daemon (no ctrl socket) -> .bak restored, rc!=0"
else
  bad "5an(ii-c) dead daemon rc=$rc conf-diff=$(cmp -s "$ANB/ap-etc/hostapd-travel.conf" "$ANB/ap-etc/pre-dead.conf"; echo $?)"
fi

# (ii-d) liveness success: ctrl socket appears during the poll -> rc 0, new
# conf installed, ap-ssid updated, .bak removed.
printf 'interface=uap0\nssid=BaseNet\n' > "$ANB/ap-etc/hostapd-travel.conf"
printf 'BaseNet\n' > "$ANB/ap-ssid"
mkdir -p "$ANB/ctrl-alive" && : > "$ANB/ctrl-alive/uap0"
# late-socket systemctl stub: creates the ctrl socket AFTER 2 poll sleeps
ANCTL_LATE="$ANB/systemctl-late"
{ printf '#!/bin/bash\n'
  printf '( sleep 2; : > "%s/ctrl-alive/uap0" ) &\n' "$ANB"
  printf 'case "$1" in is-active) echo active; exit 0;; show) echo running; exit 0;; esac\n'
  printf 'printf "systemctl %%s\\n" "$*" >> "%s/systemctl.log"\n' "$ANB"
  printf 'exit 0\n'
} > "$ANCTL_LATE"; chmod +x "$ANCTL_LATE"
TRAVELROUTER_HOSTAPD_BIN="$ANHAP_OK" SYSTEMCTL="$ANCTL_LATE" TRAVELROUTER_CTRL_DIR="$ANB/ctrl-alive" \
  env "${anenv[@]}" bash "$ANSH" ap-apply AliveNet AlivePass1 "2" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 ]] && grep -qF 'ssid=AliveNet' "$ANB/ap-etc/hostapd-travel.conf" \
   && [[ "$(cat "$ANB/ap-ssid" 2>/dev/null)" == "AliveNet" ]] \
   && [[ ! -e "$ANB/ap-etc/hostapd-travel.conf.bak" ]]; then
  ok "5an(ii-d) socket appears during poll -> success path completes"
else
  bad "5an(ii-d) socket-poll rc=$rc ssid=[$(grep '^ssid=' "$ANB/ap-etc/hostapd-travel.conf" 2>/dev/null)] ap-ssid=[$(cat "$ANB/ap-ssid" 2>/dev/null)] bak=$( [[ -e "$ANB/ap-etc/hostapd-travel.conf.bak" ]] && echo present || echo absent)"
fi

# (ii-e) crash-loop false-pass guard: the ctrl socket EXISTS (a Restart=on-failure
# loop recreates it every attempt) but the unit is mid-restart (is-active
# "activating", SubState "auto-restart") -> liveness must FAIL -> rollback.
printf 'interface=uap0\nssid=BaseNet\n' > "$ANB/ap-etc/hostapd-travel.conf"
printf 'BaseNet\n' > "$ANB/ap-ssid"
cp "$ANB/ap-etc/hostapd-travel.conf" "$ANB/ap-etc/pre-loop.conf"
mkdir -p "$ANB/ctrl-stale" && : > "$ANB/ctrl-stale/uap0"
ANCTL_LOOP="$ANB/systemctl-loop"
{ printf '#!/bin/bash\n'
  printf 'case "$1" in is-active) echo activating; exit 0;; show) echo auto-restart; exit 0;; esac\n'
  printf 'printf "systemctl %%s\\n" "$*" >> "%s/systemctl.log"\n' "$ANB"
  printf 'exit 0\n'
} > "$ANCTL_LOOP"; chmod +x "$ANCTL_LOOP"
TRAVELROUTER_HOSTAPD_BIN="$ANHAP_OK" SYSTEMCTL="$ANCTL_LOOP" TRAVELROUTER_CTRL_DIR="$ANB/ctrl-stale" \
  env "${anenv[@]}" bash "$ANSH" ap-apply LoopNet LoopPass1 "2" >/dev/null 2>&1
rc=$?
if [[ $rc -ne 0 ]] && cmp -s "$ANB/ap-etc/hostapd-travel.conf" "$ANB/ap-etc/pre-loop.conf"; then
  ok "5an(ii-e) crash-loop unit (socket present, activating) -> rollback, rc!=0"
else
  bad "5an(ii-e) crash-loop rc=$rc conf-diff=$(cmp -s "$ANB/ap-etc/hostapd-travel.conf" "$ANB/ap-etc/pre-loop.conf"; echo $?)"
fi

# (ii-g) NO CTRL_DIR seam: the poll must auto-derive the ctrl dir from the
# INSTALLED conf (b3f51ea read it from $tmp, which the mv had already removed
# -> poll silently skipped in production). The fixture template carries a
# fixture ctrl path; the systemctl stub creates the socket +2s (late, like a
# real daemon), and answers is-active/show so the health gate passes.
sed "s|^ctrl_interface=.*|ctrl_interface=$ANB/ctrl-auto|" "$A/hostapd.conf.tmpl" > "$ANB/tmpl-auto.conf"
printf 'interface=uap0\nssid=BaseNet\n' > "$ANB/ap-etc/hostapd-travel.conf"
printf 'BaseNet\n' > "$ANB/ap-ssid"
ANCTL_LATE2="$ANB/late2/systemctl-late2"
mkdir -p "$ANB/late2"
{ printf '#!/bin/bash\n'
  printf '( sleep 2; : > "%s/ctrl-auto/uap0" ) &\n' "$ANB"
  printf 'printf "systemctl %%s\\n" "$*" >> "$(dirname "$0")/systemctl.log"\n'
  printf 'case "$1" in is-active) echo active; exit 0;; show) echo running; exit 0;; esac\n'
  printf 'exit 0\n'
} > "$ANCTL_LATE2"; chmod +x "$ANCTL_LATE2"
mkdir -p "$ANB/ctrl-auto"
TRAVELROUTER_HOSTAPD_BIN="$ANHAP_OK" SYSTEMCTL="$ANCTL_LATE2" \
  env "${anenv[@]}" TRAVELROUTER_AP_TEMPLATE="$ANB/tmpl-auto.conf" \
  bash "$ANSH" ap-apply AutoDeriveNet AutoPass1 "2" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 ]] && [[ -e "$ANB/ctrl-auto/uap0" ]] \
   && grep -qF 'ssid=AutoDeriveNet' "$ANB/ap-etc/hostapd-travel.conf" \
   && grep -qF 'is-active' "$ANB/late2/systemctl.log"; then
  ok "5an(ii-g) ctrl dir auto-derived from installed conf -> poll actually ran"
else
  bad "5an(ii-g) auto-poll rc=$rc socket=$( [[ -e "$ANB/ctrl-auto/uap0" ]] && echo present || echo absent) ssid=[$(grep '^ssid=' "$ANB/ap-etc/hostapd-travel.conf" 2>/dev/null)] poll-ran=$(grep -cF 'is-active' "$ANB/late2/systemctl.log" 2>/dev/null)"
fi

# --------- (iii) SERVER: apconfig accepts random + hidden --------------------
# TRAVELWAN_BIN stub records argv so the 3rd slot (hidden) is observable.
ANTW="$ANB/stub-travel-wan-an"
cat > "$ANTW" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$(dirname "$0")/an-tool.log"
case "$1" in
  known)   printf 'HotelNet\t1690000000\tyes\n'; exit 0 ;;
  status)  printf '{"mode":"routed","wan_if":"wlan1","internet":"yes","standalone":false}'; exit 0 ;;
  ap-apply) printf 'AP applied\n'; exit 0 ;;  # must exit 0 so envelope is ok:true
  *) exit 0 ;;
esac
EOF
chmod +x "$ANTW"
printf '{"mode":"standalone","wan_if":"","wan_ssid":"","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$ANB/srv-state.json"
an_srvlog="$ANB/an-server.log"
TRAVELROUTER_SETUP_PIN=2468 TRAVELROUTER_ADMIN_PSK=AdminPass99 TRAVELWAN_BIN="$ANTW" \
TRAVELROUTER_STATE_FILE="$ANB/srv-state.json" TRAVELROUTER_STATUS_PORT=18510 \
TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >>"$an_srvlog" 2>&1 &
ANPID=$!
wait_healthy 18510 || true
an_login=$(curl -s -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -d '{"psk":"AdminPass99"}' \
  http://127.0.0.1:18510/api/auth/login 2>/dev/null)
ANTOK=$(printf '%s' "$an_login" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p' | head -1)
[[ -n "$ANTOK" ]] || bad "5an(iii) login failed (no token)"

# (iii-1) ssid:"random" -> 200 envelope, response body carries a generated ssid
# in [A-HJ-NP-Z2-9]{8}, and the tool was invoked with an 8-char no-lookalike ssid.
: > "$ANB/an-tool.log"
an_rand=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $ANTOK" \
  -d '{"pin":"2468","ssid":"random"}' \
  http://127.0.0.1:18510/api/wan/apconfig 2>/dev/null)
an_code="${an_rand##*$'\n'}"
an_body="${an_rand%$'\n'*}"
an_ssid=$(printf '%s' "$an_body" | sed -n 's/.*"ssid": *"\([^"]*\)".*/\1/p' | head -1)
if [[ "$an_code" == "200" ]] && printf '%s' "$an_ssid" | grep -qE '^[A-HJ-NP-Z2-9]{8}$'; then
  ok "5an(iii-1) apconfig ssid:random -> 200 + envelope ssid matches ^[A-HJ-NP-Z2-9]{8}$"
else
  bad "5an(iii-1) random code=$an_code ssid=[$an_ssid] body=[$(printf '%s' "$an_body" | head -1 | cut -c1-120)]"
fi
an_tool_ssid=$(sed -n 's/^ap-apply \([^ ]*\) .*/\1/p' "$ANB/an-tool.log" | head -1)
printf '%s' "$an_tool_ssid" | grep -qE '^[A-HJ-NP-Z2-9]{8}$' \
  && ok "5an(iii-1) tool argv[1] (ssid slot) carries the generated value" \
  || bad "5an(iii-1) tool argv ssid slot=[$an_tool_ssid] (want 8-char no-lookalike)"
# security todo 10: the successful random apconfig CHANGED the AP identity ->
# the session salt rotated -> ANTOK is dead by design. Re-login for the rest.
ANTOK=$(login_psk 18510 "${TESTADMIN_PSK:-AdminPass99}")
[[ -n "$ANTOK" ]] && ok "5an(iii) re-login after the identity-change salt rotation" \
  || bad "5an(iii) re-login after rotate failed"

# (iii-2) hidden:true -> tool invoked with 3rd slot "2"
: > "$ANB/an-tool.log"
ANTOK=$(login_psk 18510 "${TESTADMIN_PSK:-AdminPass99}")
an_hid_true=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $ANTOK" \
  -d '{"pin":"2468","ssid":"RandomNameTest","hidden":true}' \
  http://127.0.0.1:18510/api/wan/apconfig 2>/dev/null)
an_slot=$(awk '$1=="ap-apply"{print $NF}' "$ANB/an-tool.log" | head -1)
if [[ "${an_hid_true##*$'\n'}" == "200" && "$an_slot" == "2" ]]; then
  ok "5an(iii-2) hidden:true -> tool argv[3]='2'"
else
  bad "5an(iii-2) hidden:true code=${an_hid_true##*$'\n'} slot=[$an_slot] (want '2'; argv=[$(cat "$ANB/an-tool.log" | head -1)])"
fi

# (iii-3) hidden:false -> tool invoked with 3rd slot "0"
: > "$ANB/an-tool.log"
ANTOK=$(login_psk 18510 "${TESTADMIN_PSK:-AdminPass99}")
an_hid_false=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $ANTOK" \
  -d '{"pin":"2468","ssid":"SomeNet","hidden":false}' \
  http://127.0.0.1:18510/api/wan/apconfig 2>/dev/null)
an_slot=$(awk '$1=="ap-apply"{print $NF}' "$ANB/an-tool.log" | head -1)
if [[ "${an_hid_false##*$'\n'}" == "200" && "$an_slot" == "0" ]]; then
  ok "5an(iii-3) hidden:false -> tool argv[3]='0'"
else
  bad "5an(iii-3) hidden:false code=${an_hid_false##*$'\n'} slot=[$an_slot] (want '0')"
fi

# (iii-4) hidden ABSENT -> tool argv[3]='' (trailing argv-empty). The stub
# logs args space-joined, so a psk-and-hidden-absent call becomes
# `ap-apply <ssid>  ` (two trailing spaces). awk's NF would drop them; grep
# for the literal trailing whitespace instead.
: > "$ANB/an-tool.log"
ANTOK=$(login_psk 18510 "${TESTADMIN_PSK:-AdminPass99}")
an_hid_absent=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $ANTOK" \
  -d '{"pin":"2468","ssid":"AnotherNet"}' \
  http://127.0.0.1:18510/api/wan/apconfig 2>/dev/null)
an_argv_line=$(awk '$1=="ap-apply"' "$ANB/an-tool.log" | head -1)
if [[ "${an_hid_absent##*$'\n'}" == "200" ]] \
   && printf '%s' "$an_argv_line" | grep -qE '^ap-apply AnotherNet  $'; then
  ok "5an(iii-4) hidden ABSENT -> tool argv[3]='' (keep-current)"
else
  bad "5an(iii-4) hidden absent code=${an_hid_absent##*$'\n'} line=[$(printf '%q' "$an_argv_line")] (want 'ap-apply AnotherNet  ' with two trailing spaces)"
fi

# (iii-5) MALFORMED_INPUT: hidden:"yes" (string, not bool) -> 400 apconfig
ANTOK=$(login_psk 18510 "${TESTADMIN_PSK:-AdminPass99}")
an_hid_str=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $ANTOK" \
  -d '{"pin":"2468","ssid":"SomeNet","hidden":"yes"}' \
  http://127.0.0.1:18510/api/wan/apconfig 2>/dev/null)
[[ "${an_hid_str##*$'\n'}" == "400" && "${an_hid_str%$'\n'*}" == *'"apconfig"'* ]] \
  && ok "5an(iii-5) hidden:'yes' (non-bool) -> 400 apconfig" \
  || bad "5an(iii-5) hidden:'yes' code=${an_hid_str##*$'\n'} body=[${an_hid_str%$'\n'*}]"

# (iii-6) ssid:"random " (trailing space) is NOT the reserved word: it falls
# through to the existing 7-char SSID validation (printable, <=32, no |\\$&).
# Extract the tool argv with sed (preserves whitespace between fields; awk's
# $2 drops the trailing-space token), and assert the literal value.
: > "$ANB/an-tool.log"
ANTOK=$(login_psk 18510 "${TESTADMIN_PSK:-AdminPass99}")
an_rs=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $ANTOK" \
  -d '{"pin":"2468","ssid":"random "}' \
  http://127.0.0.1:18510/api/wan/apconfig 2>/dev/null)
an_rs_argv=$(awk '$1=="ap-apply"' "$ANB/an-tool.log" | head -1)
if [[ "${an_rs##*$'\n'}" == "200" ]] \
   && printf '%s' "$an_rs_argv" | grep -qE '^ap-apply random   $'; then
  ok "5an(iii-6) ssid:'random ' (trailing space) treated as a normal 7-char SSID (exact-string reserved word)"
else
  bad "5an(iii-6) trailing-space ssid code=${an_rs##*$'\n'} argv=[$(printf '%q' "$an_rs_argv")] (want 'ap-apply random   ' — random + literal sp + 2 empty slots)"
fi

# (iii-7)/(iii-8) hidden-ONLY (no ssid, no psk): the on-the-fly hide/show path
# V01 exposes in admin.html. Server fills both empty argv slots; the stub logs
# space-joined argv, so hidden-only reads `ap-apply   2` (two empty slots).
: > "$ANB/an-tool.log"
ANTOK=$(login_psk 18510 "${TESTADMIN_PSK:-AdminPass99}")
an_hid_only=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $ANTOK" \
  -d '{"pin":"2468","hidden":true}' \
  http://127.0.0.1:18510/api/wan/apconfig 2>/dev/null)
an_ho_line=$(awk '$1=="ap-apply"' "$ANB/an-tool.log" | head -1)
if [[ "${an_hid_only##*$'\n'}" == "200" ]] \
   && printf '%s' "$an_ho_line" | grep -qE '^ap-apply   2$'; then
  ok "5an(iii-7) hidden-only -> 200 + argv 'ap-apply   2' (ssid/psk empty, hidden=2)"
else
  bad "5an(iii-7) hidden-only code=${an_hid_only##*$'\n'} line=[$(printf '%q' "$an_ho_line")] (want 'ap-apply   2')"
fi
# hidden-only SHOW -> slot 3 "0"; re-login first (the hide rotated the salt).
: > "$ANB/an-tool.log"
ANTOK=$(login_psk 18510 "${TESTADMIN_PSK:-AdminPass99}")
an_hid_show=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $ANTOK" \
  -d '{"pin":"2468","hidden":false}' \
  http://127.0.0.1:18510/api/wan/apconfig 2>/dev/null)
an_hs_line=$(awk '$1=="ap-apply"' "$ANB/an-tool.log" | head -1)
if [[ "${an_hid_show##*$'\n'}" == "200" ]] \
   && printf '%s' "$an_hs_line" | grep -qE '^ap-apply   0$'; then
  ok "5an(iii-8) hidden-only show -> 200 + argv 'ap-apply   0'"
else
  bad "5an(iii-8) hidden-only show code=${an_hid_show##*$'\n'} line=[$(printf '%q' "$an_hs_line")] (want 'ap-apply   0')"
fi

kill "$ANPID" 2>/dev/null; wait "$ANPID" 2>/dev/null

# --------- (iv) STATIC: admin.html AP dialog additions -----------------------
grep -qF 'id="ap-random"' "$A/admin.html" \
  && ok "5an(iv) admin.html has the Random name button (id=ap-random)" \
  || bad "5an(iv) Random name button MISSING (id=ap-random)"
grep -qF 'admin-last-ssid' "$A/admin.html" \
  && ok "5an(iv) admin.html stores the final SSID in localStorage admin-last-ssid" \
  || bad "5an(iv) localStorage key admin-last-ssid MISSING"
grep -qF 'id="ap-hidden"' "$A/admin.html" \
  && ok "5an(iv) admin.html has the Hide network checkbox (id=ap-hidden)" \
  || bad "5an(iv) Hide network checkbox MISSING (id=ap-hidden)"
grep -qF 'body.hidden = !hiddenChecked' "$A/admin.html" \
  && ok "5an(iv) AP dialog posts HIDE-semantic hidden (inverted from the broadcast checkbox)" \
  || bad "5an(iv) hidden polarity BROKEN (expected body.hidden = !hiddenChecked)"
grep -qF 'body.hidden = hiddenChecked' "$A/admin.html" \
  && bad "5an(iv) hidden polarity BUG REINTRODUCED (body.hidden = hiddenChecked posts broadcast-checked as hidden-true -> every save hides the AP; 2026-10-01 incident)" \
  || ok "5an(iv) un-inverted save polarity absent (2026-10-01 incident regression guard)"
# V01: the standalone on-the-fly hide/show control (backend already supported
# hidden-only; the Save guard was the only blocker).
grep -qF 'id="ap-hidden-apply"' "$A/admin.html" \
  && ok "5an(iv) on-the-fly hide apply button present (id=ap-hidden-apply)" \
  || bad "5an(iv) hide apply button MISSING (id=ap-hidden-apply)"
grep -qF 'id="ap-hide-confirm"' "$A/admin.html" \
  && ok "5an(iv) hide confirm dialog present (id=ap-hide-confirm)" \
  || bad "5an(iv) hide confirm dialog MISSING (id=ap-hide-confirm)"
grep -qF 'doApSave({ pin: pin, hidden: desiredHidden })' "$A/admin.html" \
  && ok "5an(iv) hide toggle posts hidden-only {pin, hidden}" \
  || bad "5an(iv) hidden-only post MISSING (expected doApSave({ pin: pin, hidden: desiredHidden }))"
grep -qF 're-add the network manually' "$A/admin.html" \
  && ok "5an(iv) rejoin warning textContent present" \
  || bad "5an(iv) rejoin warning text MISSING"
# Sink grep + session census pins held by §5al — re-assert here so §5an alone
# catches a regression in this feature's footprint (cheap, in-place).
sink_hits=$(grep -c -E 'innerHTML|insertAdjacentHTML|document\.write' "$A/admin.html")
[[ "$sink_hits" == "0" ]] && ok "5an(iv) no innerHTML/insertAdjacentHTML/document.write" \
  || bad "5an(iv) forbidden DOM sink count=$sink_hits"
sess_sites=$(grep -c -F 'X-Session' "$A/admin.html")
[[ "$sess_sites" == "5" ]] && ok "5an(iv) X-Session census updated (5 sites; S06 comment rewrite)" \
  || bad "5an(iv) X-Session sites=$sess_sites (want 5 — §5al census broken)"

# --- (5ao) staged-env refresh: PIN/PSK EnvironmentFile re-derived every boot --
# The unit's EnvironmentFile=-/run/travel-router/role-env/travel-router-setup.env
# is tmpfs: wiped on reboot, and role-setup disables itself after success, so
# nothing re-stages it. On the Pi's first powercycle (2026-09-21) the staged
# copy vanished and every admin login 401'd (fail-closed, but the management
# plane is dead until re-provision). Fix: an ExecStartPre script re-derives
# the env file from bootfs role.env on EVERY start — which also makes the
# README's hand-edit recovery path work (edit role.env + restart).
sec "5ao. staged-env refresh (ExecStartPre re-stages PIN+PSK env file)"
grep -qF 'ExecStartPre=/usr/local/lib/travel-router/staged-env-refresh.sh' "$A/travel-router-status.service" \
  && ok "5ao(i) unit declares ExecStartPre staged-env-refresh" \
  || bad "5ao(i) unit missing ExecStartPre (env file would vanish on reboot)"
if [[ -f "$A/staged-env-refresh.sh" ]] && bash -n "$A/staged-env-refresh.sh" 2>/dev/null; then
  ok "5ao(i) staged-env-refresh.sh present + syntax OK"
else
  bad "5ao(i) staged-env-refresh.sh missing or syntax error"
fi
if grep -qF 'TRAVELROUTER_ADMIN_PSK' "$A/staged-env-refresh.sh" 2>/dev/null \
   && grep -qF 'TRAVELROUTER_SETUP_PIN' "$A/staged-env-refresh.sh" 2>/dev/null; then
  ok "5ao(i) script handles both PIN and PSK"
else
  bad "5ao(i) script missing a secret handler"
fi

# (ii) functional: role.env fixture -> env file staged 0600 with both lines.
AOD="$B/5ao"; mkdir -p "$AOD/role-env" "$AOD/boot"
printf 'TRAVELROUTER_SETUP_PIN=5555\nTRAVELROUTER_ADMIN_PSK=WitnessPass1\nTRAVELROUTER_AP_SSID=BaseNet\n' > "$AOD/role.env"
env TRAVELROUTER_ROLE_ENV="$AOD/role.env" TRAVELROUTER_ENV_DIR="$AOD/role-env" \
  bash "$A/staged-env-refresh.sh" >"$AOD/run1.log" 2>&1
rc=$?
m=$(stat -f%Lp "$AOD/role-env/travel-router-setup.env" 2>/dev/null || stat -c%a "$AOD/role-env/travel-router-setup.env" 2>/dev/null)
if [[ $rc -eq 0 && "$m" == "600" ]] \
   && grep -qF 'TRAVELROUTER_SETUP_PIN="5555"' "$AOD/role-env/travel-router-setup.env" \
   && grep -qF 'TRAVELROUTER_ADMIN_PSK="WitnessPass1"' "$AOD/role-env/travel-router-setup.env"; then
  ok "5ao(ii) refresh stages both values (0600) from role.env"
else
  bad "5ao(ii) refresh rc=$rc mode=$m content=[$(tr '\n' ';' <"$AOD/role-env/travel-router-setup.env" 2>/dev/null)]"
fi
if ! grep -qF 'WitnessPass1' "$AOD/run1.log"; then
  ok "5ao(ii) secret value never logged"
else
  bad "5ao(ii) secret leaked to log: $(cat "$AOD/run1.log")"
fi

# (iii) render-breaker PSK -> nothing staged in a FRESH dir, script exits 0
# (fail-closed; the service must still start without a staged file).
printf 'TRAVELROUTER_SETUP_PIN=5555\nTRAVELROUTER_ADMIN_PSK=Bad|Pipe99\n' > "$AOD/role-bad.env"
mkdir -p "$AOD/role-env-bad"
env TRAVELROUTER_ROLE_ENV="$AOD/role-bad.env" TRAVELROUTER_ENV_DIR="$AOD/role-env-bad" \
  bash "$A/staged-env-refresh.sh" >"$AOD/run2.log" 2>&1
rc=$?
if [[ $rc -eq 0 && ! -e "$AOD/role-env-bad/travel-router-setup.env" ]]; then
  ok "5ao(iii) render-breaker PSK refused (rc 0, nothing staged)"
else
  bad "5ao(iii) breaker rc=$rc staged=$( [[ -e "$AOD/role-env-bad/travel-router-setup.env" ]] && echo yes || echo no )"
fi

# (iv) no role.env anywhere -> exit 0, nothing staged (deny-by-default kept).
mkdir -p "$AOD/empty-dir"
env TRAVELROUTER_ROLE_ENV="$AOD/absent.env" TRAVELROUTER_ENV_DIR="$AOD/empty-dir" \
  bash "$A/staged-env-refresh.sh" >"$AOD/run3.log" 2>&1
rc=$?
if [[ $rc -eq 0 && ! -e "$AOD/empty-dir/travel-router-setup.env" ]]; then
  ok "5ao(iv) missing role.env -> exit 0, nothing staged"
else
  bad "5ao(iv) missing rc=$rc staged=$( [[ -e "$AOD/empty-dir/travel-router-setup.env" ]] && echo yes || echo no )"
fi

# (v) install.sh stages the refresh script (real + dry-run prefix).
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_AP_COUNTRY=US\nTRAVELROUTER_AP_CHANNEL=6\nTRAVELROUTER_AP_INTERFACE=uap0\nTRAVELROUTER_SETUP_PIN=5555\nTRAVELROUTER_ADMIN_PSK=AdminPass99\n' > "$AOD/role-install.env"
TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$AOD/pfx" TRAVELROUTER_ROLE_ENV="$AOD/role-install.env" \
  bash "$ROOT/roles/travel-router/install.sh" >"$AOD/install.log" 2>&1
if [[ -f "$AOD/pfx/usr/local/lib/travel-router/staged-env-refresh.sh" ]]; then
  ok "5ao(v) install.sh stages staged-env-refresh.sh"
else
  bad "5ao(v) install.sh missing refresh-script staging (log: $(tail -2 "$AOD/install.log" 2>/dev/null | tr '\n' ';'))"
fi

# --- (5aq) /api/admin/* family gate matrix (admin plan todo 8) ----------------
sec "5aq. /api/admin/* family gate matrix"
# Family-level gate matrix for the admin endpoint family landed by the
# security plan + admin plan (killswitch, sshlockdown, rotate-sessions, dns,
# blocked, stealth, audit, ap-info, apconfig/preview). Every seam goes into
# the temp dir; no deep per-feature assertions here (those live in the
# features' own batteries) — the suite pins the GATE MATRIX only:
#   GET  (all of stealth/dns/blocked/audit/killswitch/sshlockdown/ap-info):
#        401 without X-Session; 200 with one (audit/blocked/stealth degrade
#        via tool/file absence, still 200).
#   POST (all of dns/blocked/killswitch/sshlockdown/rotate-sessions/
#        apconfig/preview): 401 without X-Session; 403 without the CSRF
#        header (session held); 200 session+pin+CSRF. The wrong-pin 403 is
#        asserted per-bucket in §5g/§5w/§5ap (throttle-coupled there).
pkill -f status-server.py 2>/dev/null; sleep 0.3
AQB="$B/5aq"; mkdir -p "$AQB"
printf '{"mode":"standalone","wan_if":"","wan_ssid":"FixtureNet","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$AQB/state.json"
STWAQ="$B/stub-travel-wan-aq"
printf '#!/bin/bash\ncase "$1" in blocked) : ;; esac\nexit 0\n' > "$STWAQ"; chmod +x "$STWAQ"
AQ_START() { # -> fresh server (fresh in-memory throttle state) on its port
  TRAVELROUTER_SETUP_PIN="1357" TRAVELROUTER_ADMIN_PSK="${TESTADMIN_PSK:-AdminPass99}" \
  TRAVELWAN_BIN="$STWAQ" TRAVELROUTER_STATE_FILE="$AQB/state.json" \
  TRAVELROUTER_SALT_FILE="$TMP/aq-session-salt" \
  TRAVELROUTER_AUDIT_FILE="$AQB/audit.jsonl" \
  TRAVELROUTER_KILLSWITCH_FILE="$AQB/killswitch" \
  TRAVELROUTER_SSHLOCKDOWN_FILE="$AQB/ssh-lockdown" \
  TRAVELROUTER_BLOCKED_DOMAINS_FILE="$AQB/blocked-domains" \
  TRAVELROUTER_DNS_LOCAL_FILE="$AQB/dns-local" \
  TRAVELROUTER_WAN_SELECT_RELOAD="true" \
  TRAVELROUTER_STATUS_PORT="$1" TRAVELROUTER_BIND_HOST=127.0.0.1 \
    python3 "$A/status-server.py" >>"$B/srv-aq.log" 2>&1 &
  AQPID=$!
  wait_healthy "$1" || true
}
AQ_STOP() { kill "$AQPID" 2>/dev/null; wait "$AQPID" 2>/dev/null; }
aq_get() { # path [extra curl args] -> "code|body"
  local resp p
  p="$1"; shift # path out of "$@": curl treats every non-option word as a URL
  resp=$(curl -s -w '\n%{http_code}' "$@" "http://127.0.0.1:18610$p" 2>/dev/null)
  echo "${resp##*$'\n'}|${resp%$'\n'*}"
}
aq_post() { # path json [extra curl args] -> "code|body" (CSRF header per call)
  local resp p j
  p="$1" j="$2"; shift 2 # path+json out of "$@": exactly one URL reaches curl
  resp=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
    "$@" -d "$j" "http://127.0.0.1:18610$p" 2>/dev/null)
  echo "${resp##*$'\n'}|${resp%$'\n'*}"
}
aq_post_r() { # same, bounded transport retries on a 000 (suite-load flake:
  # under the full battery the macOS loopback can REFUSE/RST two consecutive
  # connects after a probe storm — the server log proves those requests never
  # arrived; the retry re-sends the SAME request until the transport
  # recovers, never masking a server answer other than 000)
  local out i
  for i in 1 2 3 4; do
    out=$(aq_post "$@")
    [[ "$out" != 000* && "$out" != *"|000" ]] && { echo "$out"; return; }
    sleep 1
  done
  echo "$out"
}
aq_get_r() { # same bounded transport retries as aq_post_r, for reads; a
  # corrupted-but-200 read (stray codes interleaved with the body under the
  # full battery) is retried too: the resend is idempotent
  local out i code body
  for i in 1 2 3 4; do
    out=$(aq_get "$@")
    code="${out%%|*}"; body="${out#*|}"
    case "$code" in
      200|401|403)
        [[ "$body" == '{'* ]] && { echo "$out"; return; } ;;
      *)
        [[ "$out" != 000* && "$out" != *"|000" ]] && { echo "$out"; return; } ;;
    esac
    sleep 1
  done
  echo "$out"
}
AQ_START 18610
AQ_TOK=$(login_psk 18610 "${TESTADMIN_PSK:-AdminPass99}")
# (A) GET gate: every family read 401s without a session, 200s with one
for ep in stealth dns blocked audit killswitch sshlockdown ap-info; do
  apx=$(aq_get "/api/admin/$ep")
  [[ "$apx" == 401*'"auth"'* ]] \
    && ok "5aq GET /api/admin/$ep no session -> 401" || bad "5aq GET $ep no-sess: [$apx]"
  apx=$(aq_get "/api/admin/$ep" -H "X-Session: $AQ_TOK")
  [[ "$apx" == 200* ]] \
    && ok "5aq GET /api/admin/$ep + session -> 200" || bad "5aq GET $ep+sess: [$apx]"
done
# (B) POST gate matrix: 401 no-session / 403 wrong-pin / 403 no-CSRF / 200
# session+pin+CSRF. Bodies carry only what the gate needs; deep per-feature
# validation lives in the feature batteries.
AQ_BODIES=(
  "rotate-sessions|{\"pin\":\"1357\"}"
  "dns|{\"action\":\"add\",\"domain\":\"example.net\"}"
  "blocked|{\"action\":\"add\",\"mac\":\"aa:bb:cc:dd:ee:01\"}"
  "killswitch|{\"on\":true}"
  "sshlockdown|{\"on\":true}"
  "apconfig/preview|{\"pin\":\"1357\"}"
)
for spec in "${AQ_BODIES[@]}"; do
  ep="${spec%%|*}"; body="${spec#*|}"
  apx=$(aq_post_r "/api/admin/$ep" "$body" -H 'X-Requested-With: XMLHttpRequest')
  [[ "$apx" == 401*'"auth"'* ]] \
    && ok "5aq POST /api/admin/$ep no session -> 401" || bad "5aq POST $ep no-sess: [$apx]"
  apx=$(aq_post_r "/api/admin/$ep" "$body" -H "X-Session: $AQ_TOK" \
    -H 'X-Requested-With: none' -H 'Connection: close')
  [[ "$apx" == 403* ]] \
    && ok "5aq POST /api/admin/$ep without X-Requested-With -> 403 (CSRF)" || bad "5aq POST $ep csrf: [$apx]"
done
# (C) session+pin+CSRF happy paths. rotate-sessions goes LAST (it rotates
# the session salt — every token minted before it dies by design).
apx=$(aq_post_r /api/admin/killswitch '{"pin":"1357","on":true}' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $AQ_TOK")
[[ "$apx" == 200*'"ok"'* && "$apx" == *'"on": true'* ]] \
  && ok "5aq POST killswitch session+pin+CSRF -> 200 (persist+render)" || bad "5aq killswitch happy: [$apx]"
apx=$(aq_post_r /api/admin/apconfig/preview '{"pin":"1357"}' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $AQ_TOK")
[[ "$apx" == 200*'"ssid"'*'"psk"'* ]] \
  && ok "5aq POST apconfig/preview session+pin+CSRF -> 200 {ssid,psk}" || bad "5aq preview happy: [$apx]"
prev_body="${apx#*|}"
prev_ssid=$(printf '%s' "$prev_body" | sed -n 's/.*"ssid": *"\([^"]*\)".*/\1/p')
prev_psk=$(printf '%s' "$prev_body" | sed -n 's/.*"psk": *"\([^"]*\)".*/\1/p')
printf '%s' "$prev_ssid" | grep -qE '^[A-HJ-NP-Z2-9]{8}$' \
  && ok "5aq preview ssid matches the no-lookalike alphabet" || bad "5aq preview ssid=[$prev_ssid]"
printf '%s' "$prev_psk" | grep -qE '^[A-Za-z0-9._-]{12}$' \
  && ok "5aq preview psk is 12 chars over [A-Za-z0-9._-]" || bad "5aq preview psk=[$prev_psk]"
# stealth degrade posture: the stub returns nothing -> 200 with the degraded
# default (stealth true, empty ports), never a 5xx
apx=$(aq_get /api/admin/stealth -H "X-Session: $AQ_TOK")
[[ "$apx" == 200*'"stealth"'* && "$apx" != *'50'*'5'* ]] \
  && ok "5aq stealth degrades to the safe posture (200, never 5xx)" || bad "5aq stealth degrade: [$apx]"
apx=$(aq_post_r /api/admin/rotate-sessions '{"pin":"1357"}' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $AQ_TOK")
[[ "$apx" == 200*'"ok"'* ]] \
  && ok "5aq POST rotate-sessions session+pin+CSRF -> 200" || bad "5aq rotate happy: [$apx]"
AQ_STOP
pkill -f status-server.py 2>/dev/null; sleep 0.3
grep -q '1357' "$B/srv-aq.log" && bad "5aq PIN leaked into server log (forbidden)" \
  || ok "5aq server log free of PIN"

# --- (5ar) security-feature battery (security plan todo 12) -------------------
sec "5ar. security-feature battery (block/killswitch/ssh/DNS/stealth/salt/audit/destruct)"
# Deeper per-feature asserts the standalone QAs (.omo/evidence/
# travel-router-security-features/qa-todo*.sh) cover, in suite form. §5aq owns
# the /api/admin/* GATE matrix (do not duplicate it here); this section owns
# the FEATURE semantics: nftables renders, travel-wan verbs, DNS drop-ins,
# session-salt rotation, audit rows, session self-destruct. Harness shapes are
# the suite's own: §5b run_wan stub-PATH idiom for renders, one §5aq-style
# server on 18610 (RESTARTED between phases — env seams are read at import)
# for the API-shaped salt/audit/destruct asserts.
AR="$B/5ar"; mkdir -p "$AR/bin" "$AR/sys/class/net/lo" "$AR/sys/class/net/wlan0/wireless" \
  "$AR/sys/class/net/eth0" "$AR/etc" "$AR/ip-addr" "$AR/nmcli-conn" "$AR/dnsmasq.d" \
  "$AR/sys/devices/platform/scb/usb/1-1/1-1.1" \
  "$AR/sys/devices/platform/soc/fe300000.mmcnr/mmc_host/mmc1"
ln -sf "$AR/sys/devices/platform/soc/fe300000.mmcnr/mmc_host/mmc1" "$AR/sys/class/net/wlan0/device"
ln -sf "$AR/sys/devices/platform/scb/usb/1-1/1-1.1" "$AR/sys/class/net/eth0/device"
printf '2: wlan0    inet 192.168.50.1/24 brd 192.168.50.255 scope global wlan0\n       valid_lft forever' > "$AR/ip-addr/wlan0"
printf '2: eth0    inet 10.0.0.2/24 brd 10.0.0.255 scope global dynamic eth0\n       valid_lft forever' > "$AR/ip-addr/eth0"
printf 'UpstreamNet' > "$AR/nmcli-conn/eth0"
for t in iw nft rfkill; do
  printf '#!/bin/bash\n{ printf "%%s " "$(basename "$0")"; printf "%%s\\n" "$*"; } >> %s/calls.log\nexit 0\n' "$AR" > "$AR/bin/$t"
done
printf '#!/bin/bash\n{ printf "%%s " "cp"; printf "%%s\\n" "$*"; } >> %s/calls.log\nexec /bin/cp "$@"\n' "$AR" > "$AR/bin/cp"
printf '#!/bin/bash\n{ printf "%%s " "systemctl"; printf "%%s\\n" "$*"; } >> %s/calls.log\nexit 0\n' "$AR" > "$AR/bin/systemctl"
printf '#!/bin/bash\n{ printf "%%s " "hostapd_cli"; printf "%%s\\n" "$*"; } >> %s/calls.log\nexit 0\n' "$AR" > "$AR/bin/hostapd_cli"
printf '#!/bin/bash\n{ printf "%%s " "sudo"; printf "%%s\\n" "$*"; } >> %s/calls.log\nexec /usr/bin/true\n' "$AR" > "$AR/bin/sudo"
printf '#!/bin/bash\n{ printf "%%s " "ip"; printf "%%s\\n" "$*"; } >> %s/calls.log\ndev=""; prev=""; for a in "$@"; do [ "$prev" = dev ] && dev="$a"; prev="$a"; done\nif [ -n "$dev" ] && [ -f %s/ip-addr/"$dev" ]; then cat %s/ip-addr/"$dev"; exit 0; fi\nif [ -n "$dev" ]; then exit 1; fi\nexit 0\n' "$AR" "$AR" "$AR" > "$AR/bin/ip"
printf '#!/bin/bash\n{ printf "%%s " "nmcli"; printf "%%s\\n" "$*"; } >> %s/calls.log\ndev="${@: -1}"; if [ -f %s/nmcli-conn/"$dev" ]; then printf "GENERAL.CONNECTION:%%s\\n" "$(cat %s/nmcli-conn/"$dev")"; exit 0; fi\nexit 1\n' "$AR" "$AR" "$AR" "$AR" > "$AR/bin/nmcli"
chmod +x "$AR"/bin/*
printf 'interface=wlan0\nctrl_interface=/var/run/hostapd\n' > "$AR/ap.conf"

ar_wan() { # WAN_PREFER -> run wan-select with §5ar seams; stdout+stderr merged
  rm -f "$AR/calls.log"; SYSFS_ROOT="$AR/sys" TRAVELROUTER_WAN_PREFER="$1" \
    TRAVELROUTER_STATE_FILE="$AR/state.json" \
    TRAVELROUTER_BLOCK_FILE="$AR/blocked-macs" \
    TRAVELROUTER_KILLSWITCH_FILE="$AR/killswitch" \
    TRAVELROUTER_SSHLOCKDOWN_FILE="$AR/ssh-lockdown" \
    TRAVELROUTER_BLOCKED_DOMAINS_FILE="$AR/blocked-domains" \
    TRAVELROUTER_DNS_LOCAL_FILE="$AR/dns-local" \
    NFTABLES_TARGET="$AR/etc/nftables.conf" DNSMASQ_CONF_DIR="$AR/dnsmasq.d" \
    PATH="$AR/bin:$PATH" ASSETS="$A" bash "$A/wan-select.sh" 2>&1
}
ar_calls() { cat "$AR/calls.log" 2>/dev/null || true; }
ar_dnsmasq_calls() { ar_calls | grep -c '^systemctl restart dnsmasq.service$' || true; }
ar_tw() { # travel-wan verb with §5ar seams
  PATH="$AR/bin:$PATH" NMCLI="$AR/bin/nmcli" HOSTAPD_CLI="$AR/bin/hostapd_cli" \
    TRAVELROUTER_AP_CONF="$AR/ap.conf" TRAVELROUTER_AP_SSID_FILE="$AR/ap-ssid" \
    TRAVELROUTER_STATE_FILE="$AR/state.json" TRAVELROUTER_BLOCK_FILE="$AR/blocked-macs" \
    NFTABLES_TARGET="$AR/etc/nftables.conf" \
    SUDO="$AR/bin/sudo" SYSTEMCTL="$AR/bin/systemctl" \
    bash "$A/travel-wan.sh" "$@" 2>&1
}

# ---- (a) nftables render battery: blocked_macs -------------------------------
printf 'aa:bb:cc:dd:ee:ff\n# comment\n\n  12:34:56:78:9A:BC  \nAA:bb:CC:dd:EE:ff\nnot-a-mac\n' > "$AR/blocked-macs"
: > "$AR/killswitch"; : > "$AR/ssh-lockdown"; : > "$AR/dns-local"
printf 'tracker.net\n' > "$AR/blocked-domains"
ar_out=$(ar_wan ethernet); rc=$?
ARC="$AR/etc/nftables.conf"
[[ $rc -eq 0 && "$(head -1 "$ARC")" == "flush ruleset" ]] \
  && ok "5ar render rc=0, flush-first (all features composed)" || bad "5ar render rc=$rc: $(echo "$ar_out" | tail -1)"
grep -qF 'aa:bb:cc:dd:ee:ff,12:34:56:78:9a:bc' "$ARC" \
  && ok "5ar blocked_macs populated: lowercased+deduped elements (2 rows from 5 lines)" \
  || bad "5ar blocked elements: $(grep -A1 'set blocked_macs' "$ARC" | tail -1)"
[[ "$(grep -c 'ether saddr @blocked_macs drop' "$ARC")" == "2" ]] \
  && ok "5ar blocked_macs: 2 drop rules (input + forward)" \
  || bad "5ar blocked drop count=$(grep -c 'ether saddr @blocked_macs drop' "$ARC")"
# drop BEFORE the established accepts in BOTH chains (chain-relative line math)
ar_in_drop=$(grep -n 'ether saddr @blocked_macs drop' "$ARC" | head -1 | cut -d: -f1)
ar_in_est=$(( $(grep -n 'chain input' "$ARC" | cut -d: -f1) - 1 + \
  $(awk '/chain input/,/^    }/' "$ARC" | grep -n 'ct state established,related accept' | head -1 | cut -d: -f1) ))
ar_fw_drop=$(grep -n 'ether saddr @blocked_macs drop' "$ARC" | tail -1 | cut -d: -f1)
ar_fw_est=$(( $(grep -n 'chain forward' "$ARC" | cut -d: -f1) - 1 + \
  $(awk '/chain forward/,/^    }/' "$ARC" | grep -n 'ct state established,related accept' | head -1 | cut -d: -f1) ))
[[ -n "$ar_in_drop" && -n "$ar_in_est" && "$ar_in_drop" -lt "$ar_in_est" ]] \
  && ok "5ar blocked input drop precedes established accept" \
  || bad "5ar input ordering drop=$ar_in_drop est=$ar_in_est"
[[ -n "$ar_fw_drop" && -n "$ar_fw_est" && "$ar_fw_drop" -lt "$ar_fw_est" ]] \
  && ok "5ar blocked forward drop precedes established accept" \
  || bad "5ar forward ordering drop=$ar_fw_drop est=$ar_fw_est"
# killswitch ON: LAN->WAN forward accept omitted (never inverted: present=ON)
! grep -q 'iifname "wlan0" oifname "eth0" accept' "$ARC" \
  && ok "5ar killswitch ON -> LAN->WAN forward accept omitted" \
  || bad "5ar killswitch accept still present"
# ssh lockdown ON: tcp-22 drop injected BEFORE the remaining {53,80} accept
grep -qF 'iifname "wlan0" tcp dport 22 drop' "$ARC" \
  && grep -qF 'iifname "wlan0" tcp dport { 53, 80 } accept' "$ARC" \
  && ok "5ar ssh-lockdown ON -> tcp-22 drop + 22 stripped from the accept" \
  || bad "5ar ssh-lockdown render: $(grep -n 'tcp dport' "$ARC" | tr '\n' ';')"
ar_22drop=$(grep -nF 'iifname "wlan0" tcp dport 22 drop' "$ARC" | head -1 | cut -d: -f1)
ar_22acc=$(grep -nF 'iifname "wlan0" tcp dport { 53, 80 } accept' "$ARC" | head -1 | cut -d: -f1)
[[ -n "$ar_22drop" && -n "$ar_22acc" && "$ar_22drop" -lt "$ar_22acc" ]] \
  && ok "5ar ssh-lockdown drop precedes the tcp accept (nft first-match)" \
  || bad "5ar lockdown ordering drop=$ar_22drop acc=$ar_22acc"
# default OFF: drop-ins (left by the composed render) removed -> zero restarts
# default OFF: seam files cleared -> drop-ins deleted, zero dnsmasq calls
rm -f "$AR/blocked-domains" "$AR/dns-local" "$AR/killswitch" "$AR/ssh-lockdown"
ar_out=$(ar_wan ethernet); rc=$?
[[ $rc -eq 0 && ! -e "$AR/dnsmasq.d/travel-router-dns-block.conf" && ! -e "$AR/dnsmasq.d/travel-router-dns-local.conf" && "$(ar_dnsmasq_calls)" == "1" ]] \
  && ok "5ar DNS seam files cleared -> drop-ins removed, zero dnsmasq calls before (default OFF)" \
  || bad "5ar DNS drop-ins exist unexpectedly"
# all three transforms composed simultaneously -> parse-shaped conf
ar_oc=$(grep -c '{' "$ARC"); ar_cc=$(grep -c '}' "$ARC")
[[ "$ar_oc" -gt 0 && "$ar_oc" == "$ar_cc" ]] \
  && ! grep -q '__[A-Z][A-Z_]*__' "$ARC" \
  && ok "5ar composed render is parse-shaped (brace-balanced, no placeholders)" \
  || bad "5ar composed braces open=$ar_oc close=$ar_cc placeholder=$(grep -c '__[A-Z]' "$ARC")"
# empty block file -> no elements line (the guaranteed-parse empty-set form)
: > "$AR/blocked-macs"
ar_out=$(ar_wan ethernet); rc=$?
sed -n '/set blocked_macs/,/^    }/p' "$ARC" > "$AR/setblock.txt"
[[ $rc -eq 0 ]] && ! grep -qE '^[[:space:]]*elements' "$AR/setblock.txt" \
  && grep -q 'ether saddr @blocked_macs drop' "$ARC" \
  && ok "5ar empty block file -> no elements line, drop rules persist" \
  || bad "5ar empty-set render rc=$rc elements=$(grep -cE 'elements' "$AR/setblock.txt" || true)"
# missing block file + flags cleared -> default posture (killswitch accept back)
rm -f "$AR/blocked-macs" "$AR/killswitch" "$AR/ssh-lockdown" "$AR/etc/nftables.conf"
ar_out=$(ar_wan ethernet); rc=$?
[[ $rc -eq 0 ]] && grep -q 'iifname "wlan0" oifname "eth0" accept' "$ARC" \
  && ! grep -qF 'iifname "wlan0" tcp dport 22 drop' "$ARC" \
  && grep -qF 'iifname "wlan0" tcp dport { 53, 80, 22 } accept' "$ARC" \
  && ok "5ar flags absent (default) -> forward accept present, no tcp-22 drop" \
  || bad "5ar default render rc=$rc: $(grep -c 'oifname "eth0" accept' "$ARC") drop=$(grep -c 'tcp dport 22 drop' "$ARC")"

# ---- (b) travel-wan verbs: block/unblock/blocked + stealth-check + ap-info ---
printf 'aa:bb:cc:dd:ee:ff\n' > "$AR/blocked-macs"
ar_out=$(ar_wan ethernet >/dev/null); rc=$?   # seed state.json for the verbs
out=$(ar_tw blocked); rc=$?
[[ $rc -eq 0 && "$out" == "aa:bb:cc:dd:ee:ff" ]] \
  && ok "5ar blocked lists the store" || bad "5ar blocked: rc=$rc out=[$out]"
out=$(ar_tw block 11:22:33:44:55:66); rc=$?
[[ $rc -eq 0 && "$(cat "$AR/blocked-macs")" == "aa:bb:cc:dd:ee:ff
11:22:33:44:55:66" ]] \
  && ok "5ar block valid MAC -> row added + reload" || bad "5ar block: rc=$rc file=$(cat "$AR/blocked-macs" 2>/dev/null)"
grep -qF 'systemctl start wan-select.service' "$AR/calls.log" \
  && ok "5ar block reload = systemctl start wan-select.service (immediate)" \
  || bad "5ar block reload missing: $(grep systemctl "$AR/calls.log" | head -1)"
grep -qF 'hostapd_cli -i wlan0 deauthenticate 11:22:33:44:55:66' "$AR/calls.log" \
  && ok "5ar block kick via hostapd_cli (AP iface from AP_CONF)" \
  || bad "5ar kick missing: $(grep hostapd_cli "$AR/calls.log" | head -1)"
out=$(ar_tw block 'zz:11:22:33:44:55'); rc=$?
[[ $rc -ne 0 && "$(grep -c . "$AR/blocked-macs")" == "2" ]] \
  && ok "5ar invalid MAC (zz group) rejected, store unchanged" \
  || bad "5ar invalid-mac rc=$rc rows=$(grep -c . "$AR/blocked-macs")"
out=$(ar_tw unblock aa:bb:cc:dd:ee:ff); rc=$?
[[ $rc -eq 0 && "$(cat "$AR/blocked-macs")" == "11:22:33:44:55:66" ]] \
  && ok "5ar unblock removes only the target row" \
  || bad "5ar unblock: rc=$rc file=$(cat "$AR/blocked-macs" 2>/dev/null)"
# stealth-check: LAN-only fixture -> stealth true; WAN accept -> false, [22]
# (comment-stripping trap: a #comment mentioning iifname+accept must never count)
printf 'flush ruleset\ntable inet travel_router {\n    chain input {\n        type filter hook input priority filter; policy drop;\n        iifname "lo" accept\n        iifname "wlan0" tcp dport { 53, 80, 22 } accept\n        # iifname "eth0" tcp dport 80 accept\n    }\n    chain forward {\n        type filter hook forward priority filter; policy drop;\n        iifname "wlan0" oifname "eth0" accept\n    }\n}' > "$ARC"
printf '{"mode":"routed","wan_if":"eth0","lan_ip":"192.168.50.1"}' > "$AR/state.json"
out=$(ar_tw stealth-check); rc=$?
printf '%s' "$out" | grep -q '"stealth":true' && printf '%s' "$out" | grep -q '"open_ports":\[\]' \
  && ok "5ar stealth-check: LAN-only accepts + comment trap -> stealth true, []" \
  || bad "5ar stealth LAN-only: rc=$rc out=[$out]"
sed -i '' 's|iifname "wlan0" oifname "eth0" accept|iifname "wlan0" oifname "eth0" accept\n        iifname "eth0" tcp dport 22 accept|' "$ARC"
out=$(ar_tw stealth-check); rc=$?
printf '%s' "$out" | grep -q '"stealth":false' && printf '%s' "$out" | grep -q '"open_ports":\[22\]' \
  && ok "5ar stealth-check: WAN tcp/22 accept -> stealth false, [22]" \
  || bad "5ar stealth WAN: rc=$rc out=[$out]"
# ap-info: hidden 2/1 -> true; 0/absent-conf -> false (LIVE ssid file + AP conf)
printf 'TravelNet\n' > "$AR/ap-ssid"
printf 'interface=wlan0\nignore_broadcast_ssid=2\n' > "$AR/ap.conf"
out=$(ar_tw ap-info)
printf '%s' "$out" | grep -q '"hidden":true' && printf '%s' "$out" | grep -q 'TravelNet' \
  && ok "5ar ap-info: ignore_broadcast_ssid=2 -> hidden true (live ssid)" \
  || bad "5ar ap-info 2: out=[$out]"
printf 'interface=wlan0\nignore_broadcast_ssid=1\n' > "$AR/ap.conf"
out=$(ar_tw ap-info)
printf '%s' "$out" | grep -q '"hidden":true' \
  && ok "5ar ap-info: ignore_broadcast_ssid=1 -> hidden true (both 1 and 2 hide)" \
  || bad "5ar ap-info 1: out=[$out]"
printf 'interface=wlan0\nignore_broadcast_ssid=0\n' > "$AR/ap.conf"
out=$(ar_tw ap-info)
printf '%s' "$out" | grep -q '"hidden":false' \
  && ok "5ar ap-info: ignore_broadcast_ssid=0 -> hidden false" \
  || bad "5ar ap-info 0: out=[$out]"
rm -f "$AR/ap.conf"
out=$(ar_tw ap-info)
printf '%s' "$out" | grep -q '"hidden":false' \
  && ok "5ar ap-info: missing conf degrades to hidden false" \
  || bad "5ar ap-info degraded: out=[$out]"

# ---- (c) DNS drop-ins (qa-todo6 idiom) ----------------------------------------
rm -f "$AR/blocked-macs" "$AR/dnsmasq.d/travel-router-dns-block.conf" \
  "$AR/dnsmasq.d/travel-router-dns-local.conf"
printf 'ads.example.com\n# comment\n\nTracker.NET\nnot_a_domain\n' > "$AR/blocked-domains"
: > "$AR/dns-local"
ar_out=$(ar_wan ethernet); rc=$?
[[ $rc -eq 0 ]] \
  && grep -q '^address=/ads.example.com/$' "$AR/dnsmasq.d/travel-router-dns-block.conf" \
  && grep -q '^address=/tracker.net/$' "$AR/dnsmasq.d/travel-router-dns-block.conf" \
  && ! grep -q 'not_a_domain' "$AR/dnsmasq.d/travel-router-dns-block.conf" \
  && ! grep -q 'address=/[^ ]*#' "$AR/dnsmasq.d/travel-router-dns-block.conf" \
  && ok "5ar DNS blocked-domains: NXDOMAIN rows (lowercased+deduped), invalid row skipped, no /# hijack form" \
  || bad "5ar DNS block render rc=$rc: $(cat "$AR/dnsmasq.d/travel-router-dns-block.conf" 2>/dev/null | tr '\n' ';')"
grep -q '^no-resolv$' "$AR/dnsmasq.d/travel-router-dns-local.conf" \
  && grep -q '^local=/#/$' "$AR/dnsmasq.d/travel-router-dns-local.conf" \
  && ! grep -q 'address=/#/' "$AR/dnsmasq.d/travel-router-dns-local.conf" \
  && ok "5ar DNS local-only: no-resolv + local=/#/ (NEVER address=/#/)" \
  || bad "5ar DNS local: $(cat "$AR/dnsmasq.d/travel-router-dns-local.conf" 2>/dev/null)"
[[ "$(ar_dnsmasq_calls)" == "1" ]] \
  && ok "5ar DNS: first apply -> exactly 1 coalesced restart (both drop-ins)" \
  || bad "5ar DNS restart count=$(ar_dnsmasq_calls)"
# content change (same presence) -> rewrite, NO restart (H03 rule)
printf 'tracker.net\nnewblock.example.org\n' > "$AR/blocked-domains"
ar_out=$(ar_wan ethernet); rc=$?
ar_dnsmasq_after_change=$(ar_dnsmasq_calls)
[[ $rc -eq 0 ]] \
  && grep -q '^address=/newblock.example.org/$' "$AR/dnsmasq.d/travel-router-dns-block.conf" \
  && [[ "$ar_dnsmasq_after_change" == "0" ]] \
  && ok "5ar DNS content-change -> drop-in rewritten, NO restart" \
  || bad "5ar DNS content-change rc=$rc restarts=$(ar_dnsmasq_after_change)"
# presence toggle off -> drop-in removed + exactly 1 restart
rm -f "$AR/dns-local"
ar_out=$(ar_wan ethernet); rc=$?
[[ $rc -eq 0 && ! -e "$AR/dnsmasq.d/travel-router-dns-local.conf" \
  && -f "$AR/dnsmasq.d/travel-router-dns-block.conf" && "$(ar_dnsmasq_calls)" == "1" ]] \
  && ok "5ar DNS local flag removed -> drop-in deleted, exactly 1 toggle-restart" \
  || bad "5ar DNS toggle rc=$rc restarts=$(ar_dnsmasq_calls)"

# ---- (d)+(e)+(f) API-shaped: one §5aq-style server on 18610 -------------------
# Salt seam: TRAVELROUTER_SALT_FILE into $AR (macOS /run is read-only; the
# suite-globally exported seam from admin todo 8 is inherited, but this
# section pins the file against $AR explicitly for salt-change asserts).
pkill -f status-server.py 2>/dev/null; sleep 0.3
ARLIVE="$AR/live"; printf 'HotelNet\nfalse\n' > "$ARLIVE"
STWAR="$AR/stub-travel-wan-ar"
cat > "$STWAR" <<'STUBEOF'
#!/bin/bash
if [[ "$1" == "ap-info" ]]; then
  ssid=""; hidden="false"
  [[ -f "$LIVE_FILE" ]] && { ssid="$(sed -n '1p' "$LIVE_FILE")"; hidden="$(sed -n '2p' "$LIVE_FILE")"; }
  printf '{"ssid": "%s", "hidden": %s}\n' "$ssid" "$hidden"
  exit 0
fi
if [[ "$1" == "ap-apply" ]]; then
  [[ "$APPLY_MODE" == "fail" ]] && { echo "ap-apply: probe failed" >&2; exit 1; }
  [[ -n "${2-}" ]] && sed -i '' "1s/.*/$2/" "$LIVE_FILE"
  [[ "${4-}" == "2" ]] && sed -i '' "2s/.*/true/" "$LIVE_FILE"
  [[ "${4-}" == "0" ]] && sed -i '' "2s/.*/false/" "$LIVE_FILE"
  exit 0
fi
exit 0
STUBEOF
chmod +x "$STWAR"
AR_START() { # -> fresh server (fresh in-memory throttle + audit ring) on 18610
  APPLY_MODE="${AR_APPLY:-ok}" LIVE_FILE="$ARLIVE" \
  TRAVELROUTER_SETUP_PIN="1357" TRAVELROUTER_ADMIN_PSK="${TESTADMIN_PSK:-AdminPass99}" \
  TRAVELWAN_BIN="$STWAR" TRAVELROUTER_STATE_FILE="$AR/state.json" \
  TRAVELROUTER_SALT_FILE="$AR/session-salt" \
  TRAVELROUTER_AUDIT_FILE="$AR/audit.jsonl" \
  TRAVELROUTER_STATUS_PORT=18610 TRAVELROUTER_BIND_HOST=127.0.0.1 \
    python3 "$A/status-server.py" >>"$B/srv-ar.log" 2>&1 &
  ARPID=$!
  wait_healthy 18610 || true
}
AR_STOP() { kill "$ARPID" 2>/dev/null; wait "$ARPID" 2>/dev/null; }

# (d) session-salt: rotate invalidates the pre-rotation token IN-PROCESS
rm -f "$AR/session-salt" "$AR/audit.jsonl"
AR_APPLY=ok AR_START
ARTOK=$(login_psk 18610 "${TESTADMIN_PSK:-AdminPass99}")
[[ -n "$ARTOK" ]] && ok "5ar(d) login mints pre-rotation token" || bad "5ar(d) login failed"
[[ -f "$AR/session-salt" && "$(stat -f%Lp "$AR/session-salt" 2>/dev/null || stat -c%a "$AR/session-salt" 2>/dev/null)" == "600" ]] \
  && ok "5ar(d) salt file auto-created 0600 in the fixture dir (salt seam)" \
  || bad "5ar(d) salt file mode=$(stat -f%Lp "$AR/session-salt" 2>/dev/null || stat -c%a "$AR/session-salt" 2>/dev/null) exists=$([[ -f "$AR/session-salt" ]] && echo y || echo n)"
[[ "$(wc -c <"$AR/session-salt" | tr -d ' ')" == "64" ]] \
  && ok "5ar(d) salt is 64 hex chars (32 bytes)" || bad "5ar(d) salt length=$(wc -c <"$AR/session-salt" | tr -d ' ')"
apx=$(aq_get_r /api/admin/audit -H "X-Session: $ARTOK")
[[ "$apx" == 200* ]] && ok "5ar(d) pre-rotation token passes a gated read -> 200" \
  || bad "5ar(d) pre-rotation gated read: [$apx]"
apx=$(aq_post_r /api/admin/rotate-sessions '{"pin":"1357"}' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $ARTOK")
[[ "$apx" == 200*'"ok"'* ]] && ok "5ar(d) POST rotate-sessions -> 200" || bad "5ar(d) rotate: [$apx]"
apx=$(aq_get_r /api/admin/audit -H "X-Session: $ARTOK")
[[ "$apx" == 401*'"auth"'* ]] \
  && ok "5ar(d) SAME pre-rotation token after rotate -> 401 (in-process, no cache)" \
  || bad "5ar(d) post-rotate token: [$apx]"
ARTOK2=$(login_psk 18610 "${TESTADMIN_PSK:-AdminPass99}")
apx=$(aq_get_r /api/admin/audit -H "X-Session: $ARTOK2")
[[ "$apx" == 200* ]] \
  && ok "5ar(d) fresh login after rotate -> 200 (ADMIN_PSK untouched)" \
  || bad "5ar(d) fresh login read: [$apx]"
# external salt overwrite with DIFFERENT content -> 401 WITHOUT calling rotate:
# _load_salt() is content-mixed and re-read on every verify, so a token minted
# before the overwrite must fail now; 401 proves the getter re-reads (a stale
# in-process cache would still 200). (mv with SAME content must stay 200 —
# the fingerprint is content, not inode — committed behavior, not asserted here.)
printf '%s\n' "$(openssl rand -hex 32)" > "$AR/session-salt"
apx=$(aq_get_r /api/admin/audit -H "X-Session: $ARTOK2")
[[ "$apx" == 401*'"auth"'* ]] \
  && ok "5ar(d) external salt overwrite -> pre-overwrite token 401 (getter re-reads every verify)" \
  || bad "5ar(d) external overwrite: [$apx]"
AR_STOP

# (e) audit ring: no-session GET + wrong-pin write + wrong login -> rows;
# NO PSK/PIN in any row. Fresh server (empty ring) on the same port.
# Mint order is assert-driven: the API returns the ring newest-first
# (reversed append order) and the assert wants
# [login/401, login/401, write/403, read/401], so chronologically the
# no-session read/401 is minted FIRST and the two login/401 rows LAST.
sleep 1
AR_APPLY=ok AR_START
ARTOK3=$(login_psk 18610 "${TESTADMIN_PSK:-AdminPass99}")
aq_get /api/admin/audit >/dev/null # no session -> 401, mints the read/401 row
aq_post /api/wan/apconfig '{"pin":"9999"}' -H 'X-Requested-With: XMLHttpRequest' \
  -H "X-Session: $ARTOK3" >/dev/null
for i in 1 2; do
  aq_post /api/auth/login '{"psk":"definitely-wrong-psk"}' \
    -H 'X-Requested-With: XMLHttpRequest' >/dev/null
done
apx=$(aq_get_r /api/admin/audit -H "X-Session: $ARTOK3")
[[ "$apx" == 200*'"attempts"'* ]] \
  && ok "5ar(e) GET /api/admin/audit with session -> 200 {attempts}" \
  || bad "5ar(e) audit read: [$apx]"
ar_audit_json="${apx#*|}"
# rows: shape ts/ip/kind/code; expected sequence newest-first; no secrets.
ARPSK="${TESTADMIN_PSK:-AdminPass99}"
printf '%s' "$ar_audit_json" | python3 -c '
import json, re, sys
data = json.loads(sys.stdin.read())
rows = data.get("attempts", [])
bad = []
want = [("login", 401), ("login", 401), ("write", 403), ("read", 401)]
got = [(r.get("kind"), r.get("code")) for r in rows]
if got != want: bad.append("sequence=%s" % got)
for r in rows:
    if set(r.keys()) != {"ts", "ip", "kind", "code"}: bad.append("keys=%s" % r)
    if r.get("ip") != "127.0.0.1": bad.append("ip=%s" % r)
    if not re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", r.get("ts", "")): bad.append("ts=%s" % r)
if not all(rows[i]["ts"] >= rows[i + 1]["ts"] for i in range(len(rows) - 1)): bad.append("ts-not-descending")
sys.exit(1 if bad else 0)
' && ok "5ar(e) rows: login/401 x2 + write/403 + read/401 newest-first, ts/ip shape exact" \
  || bad "5ar(e) row shape/sequence wrong: $(printf '%s' "$ar_audit_json" | od -c | head -3 | tr '\n' ' ')"
grep -qF "$ARPSK" "$AR/audit.jsonl" || printf '%s' "$ar_audit_json" | grep -qF "$ARPSK" \
  && bad "5ar(e) PSK leaked into audit (forbidden)" \
  || ok "5ar(e) no PSK value in audit file or response"
grep -qF '1357' "$AR/audit.jsonl" \
  && bad "5ar(e) PIN leaked into audit file (forbidden)" \
  || ok "5ar(e) no PIN value in audit file"
# ring cap: the deque construction is the enforcement (code-level, §5aq8 idiom)
grep -q 'AUDIT_CAP = 200' "$A/status-server.py" \
  && grep -q '_AUDIT_RING = deque(maxlen=AUDIT_CAP)' "$A/status-server.py" \
  && ok "5ar(e) ring cap: deque(maxlen=AUDIT_CAP) — 201st append auto-drops oldest" \
  || bad "5ar(e) ring cap construction missing"
AR_STOP

# (f) session-destruct on rename: salt-change matrix via /api/wan/apconfig
ar_salt() { cat "$AR/session-salt" 2>/dev/null || printf MISSING; }
# PSK-only change -> salt UNCHANGED, token survives
rm -f "$AR/session-salt"
AR_APPLY=ok AR_START
ARTOK4=$(login_psk 18610 "${TESTADMIN_PSK:-AdminPass99}")
ar_salt_before=$(ar_salt)
apx=$(aq_post_r /api/wan/apconfig '{"pin":"1357","psk":"newpsk123"}' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $ARTOK4")
[[ "$apx" == 200*'"ok"'*'"rc": 0'* ]] && ok "5ar(f) PSK-only apconfig -> 200 rc=0" || bad "5ar(f) PSK-only: [$apx]"
[[ "$(ar_salt)" == "$ar_salt_before" ]] \
  && ok "5ar(f) PSK-only -> salt UNCHANGED" || bad "5ar(f) PSK-only rotated the salt"
[[ "$(aq_get_r /api/admin/audit -H "X-Session: $ARTOK4")" == 200* ]] \
  && ok "5ar(f) PSK-only -> pre-change token still 200" || bad "5ar(f) PSK-only token died"
AR_STOP
# rename -> salt CHANGED + pre-rename token 401 + fresh login 200
rm -f "$AR/session-salt"; printf 'HotelNet\nfalse\n' > "$ARLIVE"
AR_APPLY=ok AR_START
ARTOK5=$(login_psk 18610 "${TESTADMIN_PSK:-AdminPass99}")
ar_salt_before=$(ar_salt)
apx=$(aq_post_r /api/wan/apconfig '{"pin":"1357","ssid":"NewName"}' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $ARTOK5")
[[ "$apx" == 200*'"ok"'*'"rc": 0'* ]] && ok "5ar(f) rename apconfig -> 200 rc=0" || bad "5ar(f) rename: [$apx]"
[[ "$(ar_salt)" != "$ar_salt_before" && "$(ar_salt)" != "MISSING" ]] \
  && ok "5ar(f) rename -> salt CHANGED" || bad "5ar(f) rename salt unchanged"
[[ "$(aq_get_r /api/admin/audit -H "X-Session: $ARTOK5")" == 401* ]] \
  && ok "5ar(f) rename -> pre-rename token 401 (self-destruct)" \
  || bad "5ar(f) pre-rename token survived"
ARTOK5B=$(login_psk 18610 "${TESTADMIN_PSK:-AdminPass99}")
[[ "$(aq_get_r /api/admin/audit -H "X-Session: $ARTOK5B")" == 200* ]] \
  && ok "5ar(f) fresh login after rename -> 200" || bad "5ar(f) post-rename login failed"
AR_STOP
# failed ap-apply -> NO rotate (the restore branch must not log everyone out)
rm -f "$AR/session-salt"; printf 'HotelNet\nfalse\n' > "$ARLIVE"
AR_APPLY=fail AR_START
ARTOK6=$(login_psk 18610 "${TESTADMIN_PSK:-AdminPass99}")
ar_salt_before=$(ar_salt)
apx=$(aq_post_r /api/wan/apconfig '{"pin":"1357","ssid":"NewName"}' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $ARTOK6")
[[ "$apx" == 200*'"ok": false'*'"rc": 1'* ]] \
  && ok "5ar(f) failed ap-apply -> 200 envelope {ok:false,rc:1}" || bad "5ar(f) failed-apply: [$apx]"
[[ "$(ar_salt)" == "$ar_salt_before" ]] \
  && ok "5ar(f) rc!=0 -> salt UNCHANGED (no rotate on restore)" \
  || bad "5ar(f) failed apply rotated the salt"
[[ "$(aq_get_r /api/admin/audit -H "X-Session: $ARTOK6")" == 200* ]] \
  && ok "5ar(f) rc!=0 -> pre-apply token still 200" || bad "5ar(f) token rotated on failed apply"
AR_STOP
# hidden-ONLY toggle -> salt CHANGED (hide is an identity change; clients must
# rejoin) + pre-toggle token 401; then a hidden NO-OP -> salt UNCHANGED.
# (V01's on-the-fly hide/show path; the stub writes LIVE_FILE line 2.)
rm -f "$AR/session-salt"; printf 'HotelNet\nfalse\n' > "$ARLIVE"
AR_APPLY=ok AR_START
ARTOK7=$(login_psk 18610 "${TESTADMIN_PSK:-AdminPass99}")
ar_salt_before=$(ar_salt)
apx=$(aq_post_r /api/wan/apconfig '{"pin":"1357","hidden":true}' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $ARTOK7")
[[ "$apx" == 200*'"ok"'*'"rc": 0'* ]] && ok "5ar(f) hidden-only apconfig -> 200 rc=0" || bad "5ar(f) hidden-only: [$apx]"
[[ "$(ar_salt)" != "$ar_salt_before" && "$(ar_salt)" != "MISSING" ]] \
  && ok "5ar(f) hidden-only toggle -> salt CHANGED" || bad "5ar(f) hidden-only salt unchanged"
[[ "$(aq_get_r /api/admin/audit -H "X-Session: $ARTOK7")" == 401* ]] \
  && ok "5ar(f) hidden-only -> pre-toggle token 401 (self-destruct)" \
  || bad "5ar(f) pre-toggle hidden token survived"
ARTOK7B=$(login_psk 18610 "${TESTADMIN_PSK:-AdminPass99}")
ar_salt_before=$(ar_salt)
apx=$(aq_post_r /api/wan/apconfig '{"pin":"1357","hidden":true}' \
  -H 'X-Requested-With: XMLHttpRequest' -H "X-Session: $ARTOK7B")
[[ "$apx" == 200*'"ok"'*'"rc": 0'* ]] && ok "5ar(f) hidden no-op apconfig -> 200 rc=0" || bad "5ar(f) hidden no-op: [$apx]"
[[ "$(ar_salt)" == "$ar_salt_before" ]] \
  && ok "5ar(f) hidden no-op -> salt UNCHANGED" || bad "5ar(f) hidden no-op rotated the salt"
AR_STOP
pkill -f status-server.py 2>/dev/null; sleep 0.3

# --- (5p) public /api/status endpoint (S01) ------------------------------------
sec "5p. public /api/status endpoint (S01)"
# The new unauthenticated endpoint returns only non-sensitive data:
# ap_ssid, wan_ssid, internet, and the router's own lan_ip (U01). No client
# list, no WAN IP, no known networks.
pkill -f status-server.py 2>/dev/null; sleep 0.3
printf '{"mode":"standalone","wan_if":"","wan_ssid":"HotelNet","wan_ip":"10.9.8.7","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/srv-state.json"
STW="$B/stub-travel-wan-warn"; printf '#!/bin/bash\nprintf %s "{\\"mode\\":\\"routed\\",\\"wan_if\\":\\"wlan1\\",\\"internet\\":\\"yes\\",\\"standalone\\":false}"\n' "$B" > "$STW"; chmod +x "$STW"
TRAVELWAN_BIN="$STW" TRAVELROUTER_STATE_FILE="$B/srv-state.json" TRAVELROUTER_STATUS_PORT=18103 TRAVELROUTER_BIND_HOST=127.0.0.1 \
  python3 "$A/status-server.py" >"$B/srv-5p.log" 2>&1 &
SPID_5P=$!
sleep 1.5
wait_healthy 18103 || true
# (1) GET /api/status without any auth -> 200 + JSON with the 3 public fields
r=$(curl -s -w '\n%{http_code}' http://127.0.0.1:18103/api/status 2>/dev/null)
code="${r##*$'\n'}"; body="${r%$'\n'*}"
[[ "$code" == "200" ]] && ok "5p(1) GET /api/status no auth -> 200" || bad "5p(1) code=$code"
echo "$body" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert "ap_ssid" in d and "wan_ssid" in d and "internet" in d and "lan_ip" in d' 2>/dev/null \
  && ok "5p(1) /api/status has ap_ssid, wan_ssid, internet, lan_ip" || bad "5p(1) missing fields: $body"
# (2) /api/status does NOT leak sensitive fields
leak=""
for w in clients wan_ip mode standalone ap_state clients_list; do
  echo "$body" | grep -qF "$w" && leak="$leak [$w]"
done
[[ -z "$leak" ]] && ok "5p(2) /api/status leaks no sensitive fields" || bad "5p(2) leak: $leak"
echo "$body" | grep -qF '"lan_ip"' \
  && ok "5p(2b) /api/status exposes lan_ip (router's own AP address)" \
  || bad "5p(2b) lan_ip MISSING"
# (3) GET / serves the minimal status page (no auth)
r=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18103/ 2>/dev/null)
[[ "$r" == "200" ]] && ok "5p(3) GET / no auth -> 200" || bad "5p(3) code=$r"
# (4) The minimal page uses textContent-only (no innerHTML/insertAdjacentHTML/document.write)
wh=$(curl -s http://127.0.0.1:18103/ 2>/dev/null)
if python3 - <<'PY' 2>/dev/null; then ok "5p(4) minimal page textContent-only"; else bad "5p(4) innerHTML/insertAdjacentHTML present"; fi
page = open("roles/travel-router/assets/status-server.py").read()
html = page.split('_STATUS_HTML = """')[1].split('"""')[0]
for forbidden in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write"):
    assert forbidden not in html
PY
# (5) Captive portal redirect still works (probe hosts -> 302)
printf '{"mode":"standalone","wan_if":"","wan_ssid":"","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/srv-state.json"
touch "$B/portal-active.conf"
TRAVELWAN_BIN="$STW" TRAVELROUTER_STATE_FILE="$B/srv-state.json" TRAVELROUTER_STATUS_PORT=18104 TRAVELROUTER_BIND_HOST=127.0.0.1 \
  TRAVELROUTER_PORTAL_CONF="$B/portal-active.conf" python3 "$A/status-server.py" >"$B/srv-5p-portal.log" 2>&1 &
SPID_5PP=$!
sleep 1.5
wait_healthy 18104 || true
r=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: captive.apple.com' http://127.0.0.1:18104/generate_204 2>/dev/null)
[[ "$r" == "302" ]] && ok "5p(5) captive portal redirect still 302" || bad "5p(5) code=$r"
kill $SPID_5P 2>/dev/null; wait $SPID_5P 2>/dev/null
kill $SPID_5P 2>/dev/null; wait $SPID_5P 2>/dev/null
pkill -f status-server.py 2>/dev/null; sleep 0.3

# --- (5z) Bookworm instance_id stamp (S07) -------------------------------------
# S07/T01: Bookworm flashes must carry a Trixie-format instance_id so
# `pi register` (pi:137/158-161) can bind pending_flashes to the device.
# Runs the provisioner against a REPO COPY in a tmpdir (never the real repo:
# it would write inventory.yaml there) with a plain scratch bootfs dir.
sec "5z. Bookworm instance_id stamp (S07)"
BW="$TMP/s07-repo"
rsync -a --exclude .git --exclude .omo "$ROOT/" "$BW/"
printf 'WIFI_SSID=T\nWIFI_PSK=abcdefgh\nWIFI_COUNTRY=US\nPI_USERNAME=pi\nPI_PASSWORD=pw123456\nTIMEZONE=America/Los_Angeles\nLOCALE=en_US.UTF-8\nKEYMAP=us\nROLE=base\n' > "$BW/.env"
mkdir -p "$BW/bootfs"
printf 'console=serial0,115200 console=tty1 root=PARTUUID=00000000-02 rootfstype=ext4\n' > "$BW/bootfs/cmdline.txt"
mkdir -p "$TMP/s07-stub"
printf '#!/bin/sh\nexit 1\n' > "$TMP/s07-stub/diskutil"; chmod +x "$TMP/s07-stub/diskutil"
(cd "$BW" && PATH="$TMP/s07-stub:$PATH" ./provision-bookworm.sh base "$PWD/bootfs" > "$TMP/s07-provision.log" 2>&1); bwrc=$?
grep -qE '^instance_id stamped: rpios-' "$TMP/s07-provision.log" \
  && ok "5z-0 provisioner ran in repo copy (rc=$bwrc, id stamped)" || bad "5z-0 provisioner failed in repo copy (rc=$bwrc): $(tail -2 "$TMP/s07-provision.log" | tr '\n' ' ')"
# 5z-1: stamp format + inert-file shape (dsmode second line, Trixie shape).
p=$(sed -n '1s/^instance_id: //p' "$BW/bootfs/meta-data")
if [[ "$p" =~ ^rpios-[0-9]{14}-[0-9]+$ ]]; then ok "5z-1 stamp instance_id format ($p)"; else bad "5z-1 stamp: '$p'"; fi
[[ "$(sed -n '2p' "$BW/bootfs/meta-data")" == "dsmode: local" ]] && ok "5z-1 dsmode: local second line" || bad "5z-1 dsmode line 2: $(sed -n '2p' "$BW/bootfs/meta-data")"
# 5z-2: pending entry binding — last pending_flashes instance_id == stamped id.
pend5z=$(yq -r '.pending_flashes[-1].instance_id' "$BW/inventory.yaml")
if [[ -n "$pend5z" && "$pend5z" != "null" && "$pend5z" == "$p" ]]; then ok "5z-2 pending entry instance_id == stamp"; else bad "5z-2 pending last='$(yq -r '.pending_flashes[-1].instance_id' "$BW/inventory.yaml" 2>/dev/null)' stamp='$p'"; fi
# 5z-3: rendered firstrun — persist lines present AND before cmdline cleanup.
if bash -n "$BW/bootfs/firstrun.sh" 2>"$TMP/s07-n.err"; then ok "5z-3 bash -n rendered firstrun.sh"; else bad "5z-3 firstrun syntax: $(cat "$TMP/s07-n.err")"; fi
grep -q 'mkdir -p /var/lib/rpi-project' "$BW/bootfs/firstrun.sh" && ok "5z-3 persist mkdir present" || bad "5z-3 persist mkdir missing"
grep -qF '/var/lib/rpi-project/instance_id' "$BW/bootfs/firstrun.sh" && ok "5z-3 persist cp target present" || bad "5z-3 persist cp missing"
pline5z=$(grep -n 'mkdir -p /var/lib/rpi-project' "$BW/bootfs/firstrun.sh" | head -1 | cut -d: -f1)
cline5z=$(grep -n 'cleaning cmdline.txt hook' "$BW/bootfs/firstrun.sh" | head -1 | cut -d: -f1)
if [[ -n "$pline5z" && -n "$cline5z" && "$pline5z" -lt "$cline5z" ]]; then ok "5z-3 persist line $pline5z < cmdline-cleanup line $cline5z"; else bad "5z-3 line order: persist=$pline5z cleanup=$cline5z"; fi
# 5z-4: real-repo source regression pins (no scratch run; grep the real files).
grep -qF 'printf '\''instance_id: %s\ndsmode: local\n'\'' "$INSTANCE_ID" > "$BOOT/meta-data"' "$ROOT/provision-bookworm.sh" \
  && ok "5z-4 real provisioner stamps instance_id" || bad "5z-4 real provisioner stamp line missing"
grep -qF 'mkdir -p /var/lib/rpi-project' "$ROOT/provision-bookworm.sh" && ok "5z-4 real firstrun persist mkdir" || bad "5z-4 persist mkdir missing in real provisioner"
grep -qF '/var/lib/rpi-project/instance_id' "$ROOT/provision-bookworm.sh" && ok "5z-4 persist cp target" || bad "5z-4 persist cp missing in real provisioner"
# 5z-5: offline bind assert — replica of pi:158-161 yq match expr (nothing
# extracted from `pi` at runtime) vs scratch inventory: entry[1] has the id.
yq -n '
  .pending_flashes = [{"image": "a"}, {"instance_id": "s07-bind-probe-1", "image": "b"}]
' > "$TMP/s07-bind-inv.yaml"
bind_expr='
      .pending_flashes // [] |
      to_entries | map(select(.value.instance_id == "'"INST"'")) | .[0].key // ""
    '
bind_hit=$(yq -r "${bind_expr/INST/s07-bind-probe-1}" "$TMP/s07-bind-inv.yaml")
bind_miss=$(yq -r "${bind_expr/INST/no-such-id}" "$TMP/s07-bind-inv.yaml")
[[ "$bind_hit" == "1" && ( -z "$bind_miss" || "$bind_miss" == "null" ) ]] \
  && ok "5z-5 offline bind: match resolves pending[1]; no-match empty/null" \
  || bad "5z-5 offline bind: hit='$bind_hit' (want 1) miss='$bind_miss' (want empty/null)"
rm -rf "$BW" "$TMP/s07-stub"

# --- (6) scope assert ---------------------------------------------------------
sec "6. scope assert (working tree vs HEAD)"
scope=$(git diff --name-only HEAD 2>/dev/null)
bad_scope=$(echo "$scope" | grep -vE '^(roles/travel-router/|roles/base/|role-setup\.service\.tmpl$|role-setup-dump\.sh$|user-data\.tmpl$|provision\.sh$|provision-bookworm\.sh$|\.env\.example$|README\.md$|INVENTORY\.md$|\.gitignore$|tasks/|RESUME\.md$)' || true)
[[ -z "$scope" ]] && ok "working tree clean" || { [[ -z "$bad_scope" ]] && ok "diff scoped to permitted paths" || bad "diff outside scope: $bad_scope"; }

echo
echo "=========================================="
if [[ $FAIL -eq 0 ]]; then
  echo "SUITE GREEN: $PASS passed, $FAIL failed"
  exit 0
else
  echo "SUITE RED: $PASS passed, $FAIL failed"
  exit 1
fi