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
for v in AP_SSID AP_PSK AP_CHANNEL AP_COUNTRY LAN_CIDR DHCP_RANGE WAN_PREFER STATUS_PORT; do
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
TRAVELWAN_BIN="$STW" TRAVELROUTER_STATE_FILE="$B/srv-state.json" TRAVELROUTER_STATUS_PORT=18080 \
  python3 "$A/status-server.py" >"$B/srv.log" 2>&1 &
SPID=$!
sleep 1.5
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
for forbidden in ("innerHTML", "insertAdjacentHTML", "document.write"):
    assert forbidden not in code
# status page JS block: no assignment to .innerHTML either
page = srv.split('_STATUS_HTML = """')[1].split('"""')[0]
assert ".innerHTML" not in page and "insertAdjacentHTML" not in page
PY
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null
# fallback seeding: dead tool -> mode/lan_ip from state still present
TRAVELWAN_BIN="/nonexistent-travel-wan" TRAVELROUTER_STATE_FILE="$B/srv-state.json" TRAVELROUTER_STATUS_PORT=18081 \
  python3 "$A/status-server.py" >"$B/sfb.log" 2>&1 &
SPID=$!
sleep 1.5
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
    TRAVELROUTER_STATUS_PORT=18090 python3 "$A/status-server.py" >"$B/srv-h01.log" 2>&1 &
  SPID=$!; sleep 1.5
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
  TRAVELWAN_BIN="$STW" TRAVELROUTER_STATE_FILE="$B/srv-state.json" \
  TRAVELROUTER_STATUS_PORT=18091 TRAVELROUTER_PORTAL_CONF="$B/portal-active.conf" \
    python3 "$A/status-server.py" >"$B/srv-h04.log" 2>&1 &
  SPID=$!; sleep 1.5
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
  TRAVELROUTER_STATE_FILE="$B/srv-state.json" TRAVELROUTER_STATUS_PORT=18092 \
  python3 "$A/status-server.py" >"$B/srv-h04b.log" 2>&1 &
SPID2=$!; sleep 1.5
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

# --- (6) scope assert ---------------------------------------------------------
sec "6. scope assert (working tree vs HEAD)"
scope=$(git diff --name-only HEAD 2>/dev/null)
bad_scope=$(echo "$scope" | grep -vE '^(roles/travel-router/|provision\.sh$|provision-bookworm\.sh$|\.env\.example$|README\.md$|INVENTORY\.md$|tasks/|RESUME\.md$)' || true)
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