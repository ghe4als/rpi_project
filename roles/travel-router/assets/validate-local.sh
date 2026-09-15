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
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  [PASS] $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
sec()  { echo; echo "### $*"; }

# wait_healthy PORT [tries]: poll /health until the live server responds
# (fixed sleeps race slow binds — §5t/§5w flaked at ~1/5 on code=000).
wait_healthy() {
  local port="$1" i=0
  for i in $(seq 1 20); do
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
[[ -f "$pfx/usr/local/lib/travel-router/setup.html" ]] \
  && ok "setup.html deployed (H02)" || bad "setup.html NOT deployed"
grep -q 'ssid=TestNet' "$pfx/etc/hostapd/hostapd-travel.conf" && ok "hostapd ssid rendered" || bad "hostapd ssid missing"
grep -q 'wpa_passphrase=TestPass123' "$pfx/etc/hostapd/hostapd-travel.conf" && ok "PSK rendered" || bad "PSK missing"
if grep -rn '__[A-Z][A-Z_]*__' "$pfx/etc" "$pfx/usr/local/lib/travel-router/status-server.py" "$pfx/usr/local/bin" >/dev/null 2>&1; then
  bad "unsubstituted placeholders remain: $(grep -rl '__[A-Z][A-Z_]*__' "$pfx/etc" "$pfx/usr/local" | tr '\n' ' ')"
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
sj=$(curl -s http://127.0.0.1:18080/status 2>/dev/null)
sp=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18080/status 2>/dev/null)
su=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/setup 2>/dev/null)
suc=$(curl -sD - -o /dev/null http://127.0.0.1:18080/setup 2>/dev/null | grep -i '^cache-control:' | head -1 | tr -d '\r' | awk '{print $2}')
[[ "$sc" == "200" ]] && ok "status /health 200" || bad "/health=$sc (srv.log: $(tail -1 "$B/srv.log" 2>/dev/null))"
echo "$sj" | grep -q '"mode"' && ok "/status contains mode" || bad "/status missing mode: $sj"
[[ "$sp" == "404" || "$sp" == "405" ]] && ok "POST -> 404/405" || bad "POST code=$sp"
[[ "$su" == "200" ]] && ok "GET /setup -> 200 (H02)" || bad "/setup code=$su"
[[ "$suc" == "no-store" ]] && ok "/setup served Cache-Control: no-store" || bad "/setup cache-control=$suc"
# XSS regression (H02): no HTML-injection path in either served page
if python3 - <<'PY' 2>/dev/null; then ok "textContent-only rendering (setup.html + status HTML)"; else bad "innerHTML/insertAdjacentHTML present in UI code"; fi
setup = open("roles/travel-router/assets/setup.html").read()
srv = open("roles/travel-router/assets/status-server.py").read()
code = setup.split("<script>")[1].split("</script>")[0]
for forbidden in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write"):
    assert forbidden not in code
# status page JS block: no assignment to .innerHTML either
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
sj=$(curl -s http://127.0.0.1:18081/status 2>/dev/null)
echo "$sj" | grep -q '"mode"' && echo "$sj" | grep -q '"lan_ip"' && ok "fallback payload carries mode/lan_ip" || bad "fallback: $sj"
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null

# --- (5d) POST API battery (H01: PIN gate + policy + argv contract) -----------
sec "5d. status-server POST API (H01)"
# argv-logging stub: every invocation appends its argv for connect-shape asserts
STW="$B/stub-travel-wan-args"
printf '#!/bin/bash\n{ printf "%%s\\n" "$*"; } >> %s/tw-args.log\nprintf "{\\"mode\\":\\"routed\\",\\"wan_if\\":\\"wlan1\\",\\"internet\\":\\"yes\\",\\"standalone\\":false}"\n' "$B" > "$STW"
chmod +x "$STW"
SRV_STATE="$B/srv-state.json"   # lan_ip=127.0.0.1 (runner-bindable)
srv_case() { # method path pin ssid psk -> emits "code body" on stdout
  local method="$1" url="$2" pin="$3" ssid="$4" psk="$5" body=""
  body=$(printf '{"pin":"%s","ssid":"%s","psk":"%s"}' "$pin" "$ssid" "$psk")
  curl -s -w '\n%{http_code}' -X "$method" \
    -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
    --data-binary "$body" "http://127.0.0.1:18090${url}" 2>/dev/null
}
start_srv() { # pin -> starts server on 18090 with TRAVELROUTER_SETUP_PIN=$1
  TRAVELROUTER_SETUP_PIN="$1" TRAVELWAN_BIN="$STW" TRAVELROUTER_STATE_FILE="$SRV_STATE" \
    TRAVELROUTER_STATUS_PORT=18090 TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >"$B/srv-h01.log" 2>&1 &
  SPID=$!; sleep 1.5
  wait_healthy 18090 || true
}
stop_srv() { kill $SPID 2>/dev/null; wait $SPID 2>/dev/null; : > "$B/tw-args.log" 2>/dev/null; }

# deny-by-default: NO pin in env -> write verbs 403 even with correct-looking pin
start_srv ""
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"1234","ssid":"A"}' http://127.0.0.1:18090/api/wan/connect)
[[ "$r" == "403" ]] && ok "deny-by-default: PIN unset -> 403" || bad "deny-by-default code=$r"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -d '{}' http://127.0.0.1:18090/api/wan/scan)
[[ "$r" == "200" ]] && ok "scan is read-only (no pin) -> 200" || bad "scan code=$r"
stop_srv

start_srv "1234"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"9","ssid":"A"}' http://127.0.0.1:18090/api/wan/connect)
[[ "$r" == "403" ]] && ok "wrong PIN -> 403" || bad "wrong pin code=$r"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -d '{"pin":"1234","ssid":"A"}' http://127.0.0.1:18090/api/wan/connect)
[[ "$r" == "403" || "$r" == "415" ]] && ok "missing X-Requested-With rejected (CSRF guard)" || bad "CSRF code=$r"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: text/plain' \
      -H 'X-Requested-With: XMLHttpRequest' -d '{}' http://127.0.0.1:18090/api/wan/connect)
[[ "$r" == "415" ]] && ok "wrong Content-Type -> 415" || bad "ctype code=$r"
r=$(python3 -c "print('{\"pad\":\"' + 'x'*9000 + '\"}')" | curl -s -o /dev/null -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' --data-binary @- http://127.0.0.1:18090/api/wan/connect)
[[ "$r" == "413" ]] && ok "oversized body -> 413" || bad "size code=$r"
# happy path: exact argv in list form, PSK never echoed back
resp=$(curl -s -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
  -d '{"pin":"1234","ssid":"HotelNet","psk":"secret1"}' http://127.0.0.1:18090/api/wan/connect)
code="${resp##*$'\n'}"
body="${resp%$'\n'*}"
[[ "$code" == "200" ]] && ok "connect happy path -> 200" || bad "connect code=$code resp=$resp"
grep -qF 'connect HotelNet secret1' "$B/tw-args.log" && ok "stub received list-form argv (connect ssid psk)" || bad "argv: $(cat "$B/tw-args.log" 2>/dev/null | head -1)"
grep -qF 'secret1' "$body" && bad "PSK echoed in connect response (forbidden)" || ok "no PSK in connect response"
# SSID policy: leading dash rejected before any subprocess call
: > "$B/tw-args.log"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"1234","ssid":"-evil"}' http://127.0.0.1:18090/api/wan/connect)
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
# R1: probe Host + active drop-in -> 302 to /setup on the same bound port
r=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: captive.apple.com' http://127.0.0.1:18091/generate_204 2>/dev/null)
loc=$(curl -s -o /dev/null -w '%{redirect_url}' -H 'Host: captive.apple.com' http://127.0.0.1:18091/generate_204 2>/dev/null)
[[ "$r" == "302" ]] && ok "R1 probe-Host GET -> 302" || bad "R1 code=$r (srv.log: $(tail -1 "$B/srv-h04.log" 2>/dev/null))"
[[ "$loc" == "http://127.0.0.1:18091/setup" ]] && ok "R1 Location -> /setup on bound host+port" || bad "R1 location=$loc"
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
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\n' > "$TMP/pinok.env"
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
  TRAVELROUTER_SETUP_PIN="2468" TRAVELWAN_BIN="$STW" TRAVELROUTER_STATE_FILE="$SRV_PIN_STATE" \
  TRAVELROUTER_STATUS_PORT=18094 TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >"$B/srv-h05.log" 2>&1 &
  SPID=$!; sleep 1.5
  wait_healthy 18094 || true
}
PORTAL_STOP() { kill $SPID 2>/dev/null; wait $SPID 2>/dev/null; }
PORTAL_START
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"wrong","ssid":"A"}' http://127.0.0.1:18094/api/wan/connect)
[[ "$r" == "403" ]] && ok "5g wrong PIN -> 403" || bad "5g wrong-pin code=$r"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"2468","ssid":"Net5g"}' http://127.0.0.1:18094/api/wan/connect)
[[ "$r" == "200" ]] && ok "5g correct PIN -> 200" || bad "5g happy code=$r"
PORTAL_STOP

# --- (5h) install.sh seed battery (W01/W03) ----------------------------------
sec "5h. install.sh WAN bootstrap seed (W03) + no-seed skip"
# second dry-run WITH WIFI_* present (different fixture than run1/§2)
cat > "$TMP/seed.env" <<'EOF'
TRAVELROUTER_AP_SSID=TestNet
TRAVELROUTER_AP_PSK=TestPass123
TRAVELROUTER_SETUP_PIN=9876
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
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\nWIFI_COUNTRY=DE\n' > "$TMP/country.env"
TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$TMP/cc1" TRAVELROUTER_ROLE_ENV="$TMP/country.env" \
  bash "$ROOT/roles/travel-router/install.sh" >/dev/null 2>&1
c=$(grep -c '^country_code=DE$' "$TMP/cc1/etc/hostapd/hostapd-travel.conf")
[[ "$c" == "1" ]] && ok "unset AP_COUNTRY + WIFI_COUNTRY=DE -> country_code=DE" || bad "country_code=DE count=$c"
# explicit AP_COUNTRY wins over WIFI_COUNTRY
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\nTRAVELROUTER_AP_COUNTRY=AU\nWIFI_COUNTRY=DE\n' > "$TMP/country2.env"
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
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\nTRAVELROUTER_DEFAULT_PSKS=alpha,beta\n' > "$TMP/pskseed.env"
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
# (1) structural: setup.html must declare the escape-aware SSID splitter.
grep -q 'escape-aware SSID splitter' "$A/setup.html" \
  && ok "5r setup.html escape-aware SSID splitter marker" \
  || bad "5r setup.html splitter marker MISSING (T7 adds it)"
# (2) behavioral: python replica pins the splitter contract.
# DRIFT RISK: this replica must be updated in lockstep with the JS splitter
# in setup.html (and the travel-wan scan row format) — if one changes, both
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
start_known_srv() { # pin -> server on 18095 with TRAVELWAN_PSK_STORE fixture
  TRAVELROUTER_SETUP_PIN="$1" TRAVELWAN_BIN="$STWT" TRAVELROUTER_STATE_FILE="$KNOWN_STATE" \
  TRAVELWAN_PSK_STORE="$TRAVELWAN_PSK_STORE" \
  TRAVELROUTER_STATUS_PORT=18095 TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >"$B/srv-m8g.log" 2>&1 &
  SPID=$!; sleep 1.5
  wait_healthy 18095 || true
}
stop_known_srv() { kill $SPID 2>/dev/null; wait $SPID 2>/dev/null; sleep 0.3; }
# gate matrix on POST /api/wan/psks with NO pin in env -> 403
start_known_srv ""
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"1234","ssid":"X"}' http://127.0.0.1:18095/api/wan/psks)
[[ "$r" == "403" ]] && ok "5t POST psks pin-unset -> 403" || bad "5t pin-unset code=$r (want 403)"
stop_known_srv
# wrong pin -> 403; missing X-Requested-With -> 403
start_known_srv "1234"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"9","ssid":"X"}' http://127.0.0.1:18095/api/wan/psks)
[[ "$r" == "403" ]] && ok "5t POST psks wrong pin -> 403" || bad "5t wrong-pin code=$r (want 403)"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -d '{"pin":"1234","ssid":"X"}' http://127.0.0.1:18095/api/wan/psks)
[[ "$r" == "403" ]] && ok "5t POST psks missing X-Requested-With -> 403" || bad "5t csrf code=$r (want 403)"
# GET /api/wan/known: 200 + fixture SSID present, fixture PSK absent.
resp=$(curl -s -w '\n%{http_code}' http://127.0.0.1:18095/api/wan/known 2>/dev/null)
code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
[[ "$code" == "200" ]] && ok "5t GET /api/wan/known -> 200" || bad "5t known code=$code (want 200)"
echo "$body" | grep -q 'FixtureNet' && ok "5t known body carries SSID" || bad "5t known body missing SSID: $(echo "$body" | head -c 120)"
echo "$body" | grep -q 'sup3rsecret' && bad "5t known body LEAKS psk (forbidden)" || ok "5t known body free of psk"
# POST /api/wan/psks happy path: PIN + header -> 200 (endpoint RED now: 404)
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
      -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"1234","ssid":"X"}' http://127.0.0.1:18095/api/wan/psks)
[[ "$r" == "200" ]] && ok "5t POST psks happy path (pin+hdr) -> 200" || bad "5t POST psks happy code=$r (want 200)"
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
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\nTRAVELROUTER_DEFAULT_PSKS=gamma\n' > "$TMP/pskv-b.env"
pfxvb="$TMP/pskv-run-b"
TRAVELROUTER_DRY_RUN=1 DRY_RUN_PREFIX="$pfxvb" TRAVELROUTER_ROLE_ENV="$TMP/pskv-b.env" \
  TRAVELROUTER_DEFAULT_PSKS="gamma" TRAVELROUTER_PSKSECRET_FILE="$TMP/psksecret-b" \
  bash "$ROOT/roles/travel-router/install.sh" >"$TMP/pskv-b.log" 2>&1
STORE5VB="$pfxvb/etc/rpi-project/travel-router/known-psks"
c=$(grep -c $'^d\t\tgamma$' "$STORE5VB" 2>/dev/null || true)
[[ "$c" == "1" ]] && ok "5v no-dupe merge: exactly one gamma d-row" || bad "5v gamma d-row count=$c (want 1)"
# (c) second install preserves s-row, refreshes d-rows env-first + file-appended
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_SETUP_PIN=9876\nTRAVELROUTER_DEFAULT_PSKS=gamma\n' > "$TMP/pskv-c.env"
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
# endpoint part: live server on 18096 (§5t pattern, PIN 1234, stub ap-apply exit 0)
pkill -f status-server.py 2>/dev/null; sleep 0.3
STWV2="$B/stub-travel-wan-v2"
printf '#!/bin/bash\ncase "$1" in try-psks) exit 0;; ap-apply) exit 0;; psks-list) printf "s\\tX\\tpk1\\nd\\t\\tdk\\n"; exit 0;; known) printf "X\\t1\\tyes\\n"; exit 0;; esac\nexit 1\n' > "$STWV2"; chmod +x "$STWV2"
KNOWN_STATE2="$B/known-state2.json"
printf '{"mode":"standalone","wan_if":"","wan_ssid":"","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$KNOWN_STATE2"
TRAVELROUTER_SETUP_PIN="1234" TRAVELWAN_BIN="$STWV2" TRAVELROUTER_STATE_FILE="$KNOWN_STATE2" \
  TRAVELROUTER_STATUS_PORT=18096 TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >"$B/srv-v2.log" 2>&1 &
SPID=$!; sleep 1.5
wait_healthy 18096 || true
r=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18096/api/wan/psks-manage)
[[ "$r" == "403" ]] && ok "5w GET psks-manage no X-Pin -> 403" || bad "5w no-pin code=$r (want 403)"
r=$(curl -s -w '\n%{http_code}' -H 'X-Pin: 1234' http://127.0.0.1:18096/api/wan/psks-manage 2>/dev/null)
code="${r##*$'\n'}"; body="${r%$'\n'*}"
[[ "$code" == "200" ]] && ok "5w GET psks-manage X-Pin -> 200" || bad "5w GET code=$code (want 200)"
echo "$body" | grep -q 'psks-secret-fixture' && bad "5w GET body leaks fixture psk" || ok "5w GET body clean of fixture psk"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert 'rows' in d and isinstance(d['rows'], list); assert all('psk' not in row for row in d['rows'])" "$body" 2>/dev/null \
  && ok "5w GET rows carry no psk key" || bad "5w GET rows contain psk key or bad JSON"
r=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Pin: 9' http://127.0.0.1:18096/api/wan/psks-manage)
[[ "$r" == "403" ]] && ok "5w GET wrong X-Pin -> 403" || bad "5w wrong-pin code=$r (want 403)"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"1234","action":"add","ssid":"S","psk":"p"}' http://127.0.0.1:18096/api/wan/psks-manage)
[[ "$r" == "200" ]] && ok "5w POST psks-manage add -> 200" || bad "5w POST add code=$r (want 200)"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"1234","ssid":"NewName","psk":"newpsk9x"}' http://127.0.0.1:18096/api/wan/apconfig)
[[ "$r" == "200" ]] && ok "5w POST apconfig happy -> 200" || bad "5w apconfig code=$r (want 200)"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"1234","ssid":"a|b","psk":"newpsk9"}' http://127.0.0.1:18096/api/wan/apconfig)
[[ "$r" == "400" ]] && ok "5w apconfig render-breaker ssid -> 400" || bad "5w render-breaker code=$r (want 400)"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"1234","ssid":"NewName","psk":"short"}' http://127.0.0.1:18096/api/wan/apconfig)
[[ "$r" == "400" ]] && ok "5w apconfig short psk -> 400" || bad "5w short-psk code=$r (want 400)"
r=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18096/api/wan/apconfig 2>/dev/null)
[[ "$r" == "404" ]] && ok "5w GET apconfig -> 404" || bad "5w GET apconfig code=$r"
for verb in PUT PATCH DELETE; do
  r=$(curl -s -o /dev/null -w '%{http_code}' -X "$verb" http://127.0.0.1:18096/api/wan/psks-manage 2>/dev/null)
  [[ "$r" == "404" ]] && ok "5w $verb psks-manage -> 404" || bad "5w $verb psks-manage code=$r"
done
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null
pkill -f status-server.py 2>/dev/null; sleep 0.3

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
# (c) setup.html UI contracts
grep -q '<dialog' "$A/setup.html" && ok "5x native dialog present" || bad "5x <dialog MISSING (setup-v2 M7)"
grep -q 'escape-aware SSID splitter' "$A/setup.html" \
  && ok "5x escape-aware splitter marker stays" || bad "5x splitter marker LOST"
if python3 - <<'PY'
code = open("roles/travel-router/assets/setup.html").read().split("<script>")[1].split("</script>")[0]
for forbidden in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write"):
    assert forbidden not in code, forbidden
PY
then ok "5x XSS forbidden list stays clean"; else bad "5x XSS forbidden list violated"; fi
anchor=$(grep -n -F 'api("/api/wan/psks"' "$A/setup.html" | head -1 | cut -d: -f1)
found=0
if [[ -n "$anchor" ]]; then
  seg=$(sed -n "$((anchor)),$((anchor+15))p" "$A/setup.html")
  echo "$seg" | grep -q 'd.log' && found=1
fi
[[ "$found" == "1" ]] && ok "5x psks handler renders d.log fallback (scoped)" \
  || bad "5x psks handler d.log fallback MISSING (rc=1 diagnostics opaque)"
grep -q 'psks-manage' "$A/setup.html" && ok "5x psks-manage referenced" || bad "5x psks-manage MISSING from setup.html"

# --- (5y) setup-v2 psk leak sweep (M8-h extension) -----------------------------
sec "5y. setup-v2 psk leak sweep"
# Extends the §5u family to the setup-v2 fixture psks; runs AFTER §5v-§5x so
# the new fixture files exist. Excludes: psk stores, staged psksecret copies,
# fixture psksecret sources, argv logs, .env fixtures.
leak_hits2=""
for p in capkA dfltA psks-secret-fixture 0123456789 welcome guestwifi gamma guestwifi2 oldpsk; do
  h=$(grep -rl "$p" "$TMP" 2>/dev/null \
      | grep -v '/v2-store$' | grep -v '/psksecret-a$' | grep -v '/psksecret-b$' \
      | grep -v '/psksecret-c$' | grep -v '/psksecret-c2$' | grep -v '/psksecret-e$' \
      | grep -v '/travel-router/psksecret$' | grep -v '/known-psks$' \
      | grep -v '/order-argv.log$' | grep -v '/v2-argv' | grep -v '\.env$' \
      | grep -v '/cap-caps' | grep -v '/cap-caps.err' || true)
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

# (2) cmd_ap_apply success path. HOSTAPD_BIN is a stub that stats the candidate
# conf (and its sibling .bak) DURING hostapd -t — capturing their modes while
# they exist, before the mv/rm removes them (stale-state guard).
c3stat="$c3/stat-stub.sh"
cat > "$c3stat" <<'EOF'
#!/bin/bash
# hostapd -t stub: record candidate (and sibling .bak) modes while they exist.
f="${2:-}"
[[ -f "$f" ]] && printf 'tmp %s\n' "$(stat -f%Lp "$f" 2>/dev/null || stat -c%a "$f" 2>/dev/null)" >>"$MODELOG"
ap="${f%.new.*}"
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
    printf 'ap="${TRAVELROUTER_AP_CONF:?}"\n'
    printf '[[ -f "$ap.bak" ]] && printf '"'"'bak %%s\\n'"'"' "$(stat -f%%Lp "$ap.bak" 2>/dev/null || stat -c%%a "$ap.bak" 2>/dev/null)" >>"$MODELOG"\n'
    printf 'exit %s\n' "$2"
  } > "$1"; chmod +x "$1"
}
mk_restart_stub "$c3/restart-ok.sh" 0
mk_restart_stub "$c3/restart-fail.sh" 1
mkdir -p "$c3/ap-etc"
# Fixture live conf is deliberately 0644 so the 600 asserts below prove the
# chmods ran (a 0644->0644 no-op would pass vacuously).
printf 'interface=uap0\nssid=OldNet\n' > "$c3/ap-etc/hostapd-travel.conf"
chmod 0644 "$c3/ap-etc/hostapd-travel.conf"
printf 'OldNet\n' > "$c3/ap-ssid"
printf 'TRAVELROUTER_AP_SSID=TestNet\nTRAVELROUTER_AP_PSK=TestPass123\nTRAVELROUTER_AP_COUNTRY=US\nTRAVELROUTER_AP_CHANNEL=6\nTRAVELROUTER_AP_INTERFACE=uap0\n' > "$c3/role.env"
c3aprun() {  # $1 = MODELOG target, $2 = SYSTEMCTL stub
  ( umask 022
    export TRAVELROUTER_AP_CONF="$c3/ap-etc/hostapd-travel.conf"
    export TRAVELROUTER_AP_TEMPLATE="$A/hostapd.conf.tmpl"
    export TRAVELROUTER_HOSTAPD_BIN="$c3stat"
    export TRAVELROUTER_AP_SSID_FILE="$c3/ap-ssid"
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
  && ok "5z rendered tmp conf was 0600 while alive (hostapd -t stat)" \
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

# --- (5aa) scan/status POST desync: connection closed, no smuggled request ----
sec "5aa. scan/status POST closes connection (smuggled keep-alive body not served)"
# POST /api/wan/scan and /api/wan/status never read their request body; under
# HTTP/1.1 keep-alive the unsent body would be parsed as the next request on
# the same socket. The response must carry Connection: close (after the status
# line) and the server must close the socket so the smuggled request never
# executes. One socket, one smuggled GET /api/wan/known inside the body.
pkill -f status-server.py 2>/dev/null; sleep 0.3
printf '{"mode":"standalone","wan_if":"","wan_ssid":"FixtureNet","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/srv-state.json"
STWT="$B/stub-travel-wan-c4"
# known) -> the smuggled request, if served, returns this distinctive token.
# (3 tab-separated fields so the known parser would echo it back.)
printf '#!/bin/bash\nif [[ "$1" == known ]]; then printf "KNOWN\\tSMUGGLED-KNOWN-TOKEN\\tyes\\n"; exit 0; fi\nprintf "{\\"mode\\":\\"routed\\",\\"internet\\":\\"yes\\"}"\n' > "$STWT"; chmod +x "$STWT"
TRAVELWAN_BIN="$STWT" TRAVELROUTER_STATE_FILE="$B/srv-state.json" \
TRAVELROUTER_STATUS_PORT=18097 TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >"$B/srv-c4.log" 2>&1 &
C4PID=$!
wait_healthy 18097 || true

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
ok_hdr = line1.startswith(b"HTTP/1.") and b" 200 " in line1
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
[[ $rc -eq 0 ]] && ok "5aa scan POST: 200 status line first + Connection: close, socket EOF (smuggled GET not served)" \
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
# One client IP (127.0.0.1) hammers POST /api/wan/connect with a wrong PIN.
# Tiers: 5th fail -> 5s block, 25th -> 30s, 51st -> 120s. A blocked (429)
# attempt still advances the counter. Success resets the IP's entry.
# NOTE: 127.0.0.2 source binds fail on macOS (errno 49) — single client IP.
pkill -f status-server.py 2>/dev/null; sleep 0.3
printf '{"mode":"standalone","wan_if":"","wan_ssid":"FixtureNet","wan_ip":"","lan_ip":"127.0.0.1","ap_interface":"wlan0"}' > "$B/srv-state.json"
STWC1="$B/stub-travel-wan-c1"
printf '#!/bin/bash\ncase "$1" in connect|scan|status) printf "{\\"mode\\":\\"routed\\",\\"wan_if\\":\\"wlan1\\",\\"internet\\":\\"yes\\",\\"standalone\\":false}"; exit 0;; esac\nexit 0\n' > "$STWC1"; chmod +x "$STWC1"
C1LOG="$B/c1-throttle.txt"
: > "$C1LOG"
echo "=== C1 PIN throttle transcript ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ===" >> "$C1LOG"
c1_start() { # -> fresh server on 18098 (fresh in-memory throttle state)
  TRAVELROUTER_SETUP_PIN="2468" TRAVELWAN_BIN="$STWC1" TRAVELROUTER_STATE_FILE="$B/srv-state.json" \
  TRAVELROUTER_STATUS_PORT=18098 TRAVELROUTER_BIND_HOST=127.0.0.1 python3 "$A/status-server.py" >>"$B/srv-c1.log" 2>&1 &
  C1PID=$!
  wait_healthy 18098 || true
}
c1_stop() { kill $C1PID 2>/dev/null; wait $C1PID 2>/dev/null; }
c1_post() { # pin -> one POST attempt; echoes the HTTP code, logs to transcript
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
    -d "{\"pin\":\"$1\",\"ssid\":\"HotelNet\"}" http://127.0.0.1:18098/api/wan/connect 2>/dev/null)
  echo "POST /api/wan/connect pin=<redacted:len=${#1}> -> $code" >> "$C1LOG"
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
  -H 'X-Requested-With: XMLHttpRequest' -d '{"pin":"wrongbody","ssid":"HotelNet"}' \
  http://127.0.0.1:18098/api/wan/connect 2>/dev/null)
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

# --- (6) scope assert ---------------------------------------------------------
sec "6. scope assert (working tree vs HEAD)"
scope=$(git diff --name-only HEAD 2>/dev/null)
bad_scope=$(echo "$scope" | grep -vE '^(roles/travel-router/|roles/base/|role-setup\.service\.tmpl$|provision\.sh$|provision-bookworm\.sh$|\.env\.example$|README\.md$|INVENTORY\.md$|\.gitignore$|tasks/|RESUME\.md$)' || true)
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