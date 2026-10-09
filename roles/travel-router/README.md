# travel-router — role manual

> The travel-router role's full documentation lives here
> (`roles/travel-router/README.md`). Quick start and the roles overview
> are in the repo [`README.md`](../../README.md).

This is the complete manual for the travel security router: buying guide,
provisioning, every admin-page security feature, the hotel procedure,
rogue-AP threat model, saved passwords, AP rename, WPA3 hardware ceiling,
first-boot notifications, and recovery paths. A **Feature parking lot** at
the bottom collects ideas for future waves.

---

### Provisioning the travel-router Pi

Turns a Pi (a Zero W v1.1 works) into a travel router: its onboard WiFi is
**always** your private travel network (`TRAVELROUTER_AP_SSID`), and whatever
USB network adapter you plug in auto-becomes the WAN (hotel WiFi dongle,
wired jack, or nothing — standalone AP mode). LAN is 192.168.50.0/24 with
DHCP/DNS, a status page and an **admin page** at `http://192.168.50.1/admin`
— no SSH needed to pick the hotel network (log in with
`TRAVELROUTER_ADMIN_PSK`; admin writes also need `TRAVELROUTER_SETUP_PIN`).

1. **What to buy** — a micro-USB **OTG adapter is REQUIRED** on the Zero W
   v1.1: its only data port is the micro-USB OTG port (the PWR port is
   power-only), so no USB device plugs in without it; a powered OTG hub is
   recommended for power-hungry adapters. A USB WiFi dongle must have a
   working Linux driver + CLIENT/station mode (ideally 5 GHz — the AP side
   is the onboard radio and never needs AP mode on the dongle); a USB
   Ethernet adapter just needs a working Linux driver. Some dongles lack
   usable Linux drivers or 5 GHz channel support — check before travel.

2. **Set `.env`**:
   ```
TRAVELROUTER_AP_SSID="TravelNet"
TRAVELROUTER_AP_PSK="at-least-8-chars"   # 8-63 chars, A-Za-z0-9._- only
TRAVELROUTER_SETUP_PIN="1234"            # required; second factor on every admin write (see Security features)
TRAVELROUTER_ADMIN_PSK="choose-a-passphrase"  # required; >=8 printable ASCII; logs into the admin page (/admin)
TRAVELROUTER_DEFAULT_PSKS="homepsk1,homepsk2"  # optional: default PSKs tried by "Try saved passwords"
ROLE="travel-router"
   ```

3. **Home test** — flash with the USB adapter plugged in (on the Zero W
   v1.1 use a **32-bit armhf Lite image** — Bookworm armhf Lite
   recommended; arm64 does not boot on this SoC). After first boot join the
   travel SSID from a laptop, open `http://192.168.50.1`, and confirm
   internet flows through the WAN. On the Zero W the first boot is slow
   (ARMv6 + full apt) — wait for the travel SSID before assuming failure.

**Threat model.** The router's management plane (admin page, SSH) is
only reachable from the private travel AP — nftables drops traffic arriving
from the WAN side to the router (the admin page's stealth self-check, below,
verifies exactly this against the rendered ruleset). The setup PIN is the
second factor on every admin write in addition to the admin-page session
(a leaked/observed session token alone cannot rename the AP or change the
DNS stores). Saved PSKs sit at rest as
0600 (root-owned) on the Pi, but during `connect`/`try-psks` they are
transiently visible in process arguments (`/proc/<pid>/cmdline`); the only
local accounts are `pi` and root, both already privileged, so no privilege
boundary is crossed today — PSK-in-argv accepted risk.

### Security features (admin page, default-off)

The admin page at `http://192.168.50.1/admin` is the management surface for
a set of opt-in security features. Log in with `TRAVELROUTER_ADMIN_PSK`;
writes additionally need the setup PIN (the session/CSRF header rules for
curl are in Troubleshooting). **Every feature flag defaults OFF** — a fresh
flash blocks nothing, cuts nothing, hides nothing; each toggle persists as
a flag file under `/etc/rpi-project/travel-router/` and survives reboots.
(S04 merged the old phone `/setup` page into this one — the admin page is
the only management surface.)

- **Block list** (default OFF — empty list, nothing blocked). Block a
  device by MAC from the admin page's Connected-clients list (per-client
  Block button; blocked devices get a "blocked" badge, and the Blocked
  devices section offers Unblock) or over SSH: `travel-wan block <MAC>` /
  `travel-wan unblock <MAC>` / `travel-wan blocked`. A blocked MAC is
  dropped at the TOP of the nftables input AND forward chains — before the
  established-connection accepts, so its live sessions die too — and is
  deauthenticated from the AP immediately. The list persists across the
  30s re-render and reboots.
- **Internet kill switch** (default OFF — client internet flows). One
  toggle on the admin page cuts every client's LAN→WAN forwarding while
  the status/admin pages stay reachable. Mechanism: when the flag file
  exists, the nftables render omits the LAN→WAN forward accept; clearing
  the flag restores internet. Presence is the cut, absence is always the
  online state — never inverted.
- **DNS hardening** (default OFF — both halves). Two independent toggles
  on the admin page: a blocked-domains list (each listed domain is
  answered NXDOMAIN by dnsmasq) and a local-only mode (`no-resolv` +
  `local=/#/` — no upstream forwarding at all). Both render as dnsmasq
  drop-ins; clearing the list/flag removes the drop-in again, and dnsmasq
  restarts only when a drop-in appears or disappears, not on every edit.
- **Force-relogin** (default: no state — a one-shot action, not a flag).
  The admin page's "Force relogin" button (`POST
  /api/admin/rotate-sessions`) rotates the session-salt file that is mixed
  into every session token's fingerprint, so ALL sessions — including the
  admin's own — fail their next request and every device must log in
  again. `TRAVELROUTER_ADMIN_PSK` itself is unchanged.
- **Session self-destruct on AP rename/hide** (no default-off state — not
  a toggle; this is how the AP-settings flow always behaves). When an
  AP-settings change that
  CHANGES the SSID or the hidden flag applies successfully, the session
  salt rotates automatically: every session minted before the change dies,
  including the admin's own — the admin page handles the resulting 401 by
  dropping back to the login panel (log in again on the new SSID).
  PSK-only changes, no-op renames, and failed applies (the previous config
  is auto-restored) never rotate.
- **Auth-failure audit** (default: always-on logging, admin-only read —
  not a flag). Every 401/403/429 auth rejection (failed logins, wrong-PIN
  writes, session-gated reads without a session) lands in a bounded
  200-row ring, surfaced in the admin page's Audit table (`GET
  /api/admin/audit`, session-gated). Rows carry only timestamp, source IP,
  kind (login/write/read) and HTTP code — never a PSK or PIN value.
- **SSH lockdown** (default OFF — SSH reachable from the travel AP). When
  toggled ON from the admin page, the nftables render drops tcp/22 on the
  LAN (AP) interface ONLY: the drop is injected BEFORE the remaining
  `{53, 80}` accept (nftables is first-match, so the drop wins). The admin
  page (tcp/80) stays reachable, so recovery is simply toggling lockdown
  back off. WAN-side note: inbound SSH from the WAN/USB-Ethernet side is
  policy-dropped with or without this feature — see Recovery below.
- **WAN-stealth self-check** (default: read-only, always available — not a
  flag). The admin page's Stealth section (or `travel-wan stealth-check`
  over SSH) greps the rendered nftables ruleset for WAN-side accepts on
  management ports and reports `stealth: true/false` plus any open ports.
  It changes nothing; in the default posture it reports stealth.
- **AP-settings preview/change flow** (no default-off state — not a flag;
  the standard admin change path). The AP settings section can mint a
  random SSID (8 chars from a no-lookalike alphabet) and a random PSK via
  `POST
  /api/admin/apconfig/preview` (session + PIN; mints credentials, touches
  nothing), then apply via `POST /api/wan/apconfig`: the new hostapd
  config is parse-probed on a throwaway copy (the live radio is never
  touched by an invalid config) and the previous config is auto-restored
  if the AP fails to come up after the restart.

### First-boot simulation (provisioning WiFi becomes the first WAN)

The provisioning WiFi (`WIFI_SSID`/`WIFI_PSK` from `.env`) does double duty:
it bootstraps apt during first boot AND is seeded as the first WAN ("hotel")
NM profile (unbound, so it can only activate on a managed USB WiFi adapter,
never the AP radio).

- **USB adapter plugged in at first boot**: the Pi comes up ROUTED to
  `WIFI_SSID` with zero manual steps (wan-select auto-detects the WAN within
  30s). You can rehearse a full hotel setup at home before you travel.
- **No USB adapter**: the Pi boots standalone (AP only); the profile is
  seeded but inert and the install is green.
- Change or forget the seed later from the admin page (session-gated), or
  `ssh pi@192.168.50.1 travel-wan forget <SSID>` (it is SSID-named, so
  forget works like any hotel profile). Re-provisioning re-seeds it.

### Known networks and saved passwords

Successful connects are remembered: the NM profile (auto-reconnect on
boot/re-plug) plus a PSK-candidate store at
`/etc/rpi-project/travel-router/known-psks` (0600, root) — collected
candidates per SSID (max 4) and `d`-row defaults seeded from
`TRAVELROUTER_DEFAULT_PSKS`. The admin page's WiFi-networks section lists
known networks and offers "Try saved passwords" per network: it cycles that network's
saved candidates, then the defaults, via a throwaway probe profile and
connects with the winner — no re-typing. `travel-wan forget <SSID>`
removes the profile but KEEPS the saved PSKs, so forgetting a hotel
network never loses its password. "Try saved passwords" reports its
progress lines on the phone (which candidates failed, which connected)
instead of a bare failure code.

The scan list is a table of the **ten strongest** networks (scrollable),
with a Connect button that opens a dialog for the password plus
"Try saved passwords". Hidden networks and enterprise (802.1X) networks
are shown as notes — the page never joins those.

#### The connect dialog is the credential hub

Opening a network's dialog (from the scan list, a known network, or **Connect
manually**) gives one place to do everything for that network: an editable
network name (so hidden SSIDs can be typed), the password, **Connect**, and
**Try saved passwords**. "Try saved passwords" shows live progress while it
runs (a spinner row ticking "trying 1 of N… 2 of N…" based on the saved
candidate count), then lists each real server-side attempt ("candidate i/N
OK|failed") as soon as the result lands.

The dialog also carries a collapsible **Saved passwords** area: **For this
network** lists that network's saved candidates with a Remove button and an
"add a password for this network" field; **Defaults** lists the passwords tried
for *any* network (the `d`-rows seeded from `TRAVELROUTER_DEFAULT_PSKS` /
`.psksecret`) with Remove and an add field. Password values are never shown —
only which network/row they belong to.

### Pre-seeded passwords (.psksecret) and the saved-passwords manager

Starter passwords live in an optional, **gitignored** repo-root file
`.psksecret` (one PSK per line; `#` comments and blank lines are skipped):

```
0123456789
welcome
guestwifi
```

At provisioning the file is staged next to `role.env` and install.sh seeds
its values into the store as default (`d`) rows alongside
`TRAVELROUTER_DEFAULT_PSKS` (env first, file appended, no duplicates). The
file is read **once at install** — the router and phone never modify it.
Afterwards the store itself is managed at runtime:

- **Phone**: the admin page's "Saved passwords" section lists the store
  rows (type/index/SSID only — passwords never leave the device) and can
  add default passwords or remove rows (PIN-gated).
- **SSH**: `travel-wan psks-add <SSID> <PSK>`,
  `travel-wan psks-add-default <PSK>`, `travel-wan psks-list`
  (TYPE⟨TAB⟩SSID⟨TAB⟩PSK, root only — the store is 0600),
  `travel-wan psks-del <index>`.

### Common SSID names (.ssid_common)

An optional, **gitignored** repo-root file `.ssid_common` feeds the travel
AP a pool of network names you rotate through (one SSID per line; `#`
comments and blank lines are skipped):

```
HomeNet
CafeNet
LabNet
```

Same pipeline as `.psksecret`: staged next to `role.env` at provisioning,
ingested **once at install** into `/etc/rpi-project/travel-router/ssid-common`
(0600; entries validated — printable ASCII, ≤32 chars — a bad entry fails
install with a remediation, duplicates keep the first occurrence). Re-run
behavior mirrors AP re-provisioning: a re-run WITHOUT the file clears the
pool; a re-run WITH it rebuilds from scratch. There is no runtime editor —
edit the file and re-run install (dry-run safe).

When the pool is non-empty, the admin page's **Random name** button draws
from it (the preview response says `source: "pool"`, otherwise
`"generated"`), and the AP-settings card lists the pool under "Common
names" — tap one to fill the name field, then save with the PIN as usual
(a pool pick is not a second write path; identity-change session rotation
and auto-restore apply unchanged). Empty/absent pool = today's random mint
from the no-lookalike alphabet; nothing changes on a fresh flash.

### Changing the router's own network (AP rename)

The admin page's "AP settings" flow (and `POST /api/wan/apconfig`) changes
the travel SSID and/or AP password at runtime. The new config is validated
by a parse-probe on a throwaway copy (the live radio is never touched), then
rendered from the template, and the AP service restarts (connected devices
drop and must rejoin). After the restart the AP's control socket is polled
for a few seconds; if it never appears, the previous config is restored and
the AP is restarted automatically. If you changed the SSID, join the new
SSID manually — the phone re-checks the router over the new connection.
**Re-provisioning resets the AP name/password to your `.env` values by
design.**

#### Hide/show the SSID without renaming

The AP-settings card's **Apply hide/show now** button toggles SSID broadcast
without changing the network name or password: uncheck "Broadcast this SSID"
and apply to hide, recheck and apply to show again. The button only enables
when the checkbox differs from the live state, and a confirmation dialog warns
that all connected devices drop and must re-add the network (hidden networks
never appear in scans). Hiding is an identity change, so your admin session
also ends — log in again on the same SSID. The rename Save path is unchanged;
this is a separate, single-purpose control.

#### WiFi security mode: WPA2 vs WPA3 (per-hardware capability check)

The travel AP runs **WPA2-PSK (RSN/CCMP-128)** by default — the strongest mode
the Zero W's radio supports. Upgrading to WPA3 is a hardware question, not just
a config preference: SAE (WPA3's handshake) needs support in BOTH the radio
firmware and hostapd. The mode is an **env var** (no template editing):

```
TRAVELROUTER_AP_SECURITY="wpa2"             # default: WPA-PSK, no PMF
# "wpa3-transition" -> wpa_key_mgmt=WPA-PSK SAE + ieee80211w=1 (optional PMF)
# "wpa3"            -> wpa_key_mgmt=SAE + ieee80211w=2 (PMF required; WPA2-only clients locked out)
```

At install the requested mode is validated against the AP radio; unsupported
hardware **fails loud with a remediation** — never a silent downgrade to WPA2.
The wpa2 render is byte-identical to the pre-WS behavior.

The router ships `travel-wan wifi-capabilities` to check the radio (see below);
the underlying `iw phy` recipe is how that verb decides:

```bash
hostapd -v                        # need hostapd >= 2.9; 2.10 is fine (2.11 too)
iw phy0 info > /tmp/phy0.txt      # phy0 = onboard radio (AP side); phy1 = USB WAN

# THE test: SAE support + the CMAC (management-frame/BIP) cipher
grep -c SAE /tmp/phy0.txt
#   0  -> no WPA3 (this radio's ceiling is WPA2-CCMP)
#  >0  -> SAE possible; also confirm the AP mode + CMAC cipher are listed
```

Interpreting the dump:
- **Supported Ciphers**: WEP40/WEP104/TKIP are legacy — you want CCMP-128
  (or CCMP-256/GCMP on better radios). **CMAC** = the BIP cipher that PMF
  needs. CCMP-128 = WPA2's AES; GCMP-256 hints at WPA3-class hardware.
- **Supported interface modes**: `AP` must be present (SAE without AP mode
  still can't run our AP).
- **AKM suites** (shown on newer iw versions): look for
  `00-0f-ac:8` (SAE) alongside `00-0f-ac:2` (PSK). SAE + PSK = transition
  mode possible; SAE only = WPA3-only mode.
- **Extended features**: `EXT_KEY_ID` is a WPA3/PMF hint, but its absence is
  not disqualifying — the CMAC cipher + the "supports SAE" line are stronger.

Note: transition mode is still downgrade-attackable by design — pure SAE
is where the real gain is.

##### SAE-capable hardware (what to buy for WPA3/PMF)

| Hardware | AP radio | WPA2 | WPA3/PMF | Notes |
|---|---|---|---|---|
| Pi Zero W v1.1 | BCM43430A1 | yes | **no** | chip ceiling; detection-only |
| Pi 3B+ | BCM43455 (2.4 GHz only) | yes | **no** | no SAE advertised |
| **Pi 4** | BCM43455 (2.4 + 5 GHz) | yes | **yes** | SAE + CMAC; the WQ target |
| Pi 5 | (verify) | yes | probe first | run `wifi-capabilities` |

**Rule: probe before buying.** Run `travel-wan wifi-capabilities` on the
candidate; `"wpa3":true` (SAE + AP mode) is the only signal that matters. A USB
adapter is not required for WPA3 on the Pi 4 — its **onboard** radio is the AP
and already exposes SAE, so there is no topology change.

`travel-wan wifi-capabilities` automates the check above and prints the AP
radio's capability as one JSON line:

```bash
ssh pi@192.168.50.1 travel-wan wifi-capabilities
# {"iface":"wlan0","phy":"phy0","ap_mode":true,"sae":true,"pmf":true,
#  "wpa3":true,"bands":["2.4","5"],"iw":true}
```

`"wpa3":true` means the AP radio exposes SAE + AP mode (a WPA3 candidate);
`"wpa3":false` means the radio's ceiling is WPA2. `"pmf"` reflects the CMAC
(BIP) cipher — the management-frame-protection indicator. A missing `iw`
yields `"iw":false` and exit 3, never an abort.

#### SSID rotation is NOT a defense

Do not expect the router to "hide" or rotate the SSID on an attack. **It never
does so automatically, and rotation would not help:** a deauth attacker does
not need your SSID, while rotating it drops every client and your admin session
— a self-inflicted DoS. If you want to rename the network, do it deliberately
via the AP-settings flow; it is never wired to detection.

### Forged-deauth detection (Tier 1, heuristic)

WPA2 management frames are unauthenticated, so anyone in RF range can forge a
deauth/disassoc and drop your clients. WPA2-only hardware (the Zero W) cannot
cryptographically prevent this — the real fix is PMF/WPA3 on capable hardware
(above). As a mitigation the router **detects and alerts**, so you can leave or
switch networks:

- `deauth-watch.service` watches the AP radio for station disconnects and
  raises an alert when **5 or more** land within **10 seconds** (both tunable
  via `TRAVELROUTER_DEAUTH_THRESHOLD` / `TRAVELROUTER_DEAUTH_WINDOW_SEC`).
- On a burst it writes `/run/travel-router/deauth-alert.json` and publishes
  `rpi.nodes.<hostname>.deauth-alert` to `NATS_URL`. The public status page
  and the admin page both surface a warning banner while the alert is fresh
  (15 min TTL); the admin page can **Dismiss** it (session + PIN).
- A cooldown (default 60 s) prevents alert storms; the router's **own** AP
  restarts and MAC-block kicks are self-suppressed and never counted.
- This is a **heuristic, not proof** — it does not distinguish a forged frame
  from a genuine disconnect. And it deliberately **never auto-rotates the
  SSID**: rotation is not a defense (the attacker does not need the SSID) and
  it drops every client and the admin session — a self-inflicted DoS.
- The **only real prevention is PMF/WPA3** (above), and even that cannot stop
  RF jamming or link-layer DoS. Detection → decide is the honest posture.

### First-boot notifications (NATS)

Both events need a route to `NATS_URL`; with no USB adapter plugged in
(standalone AP boot) neither is published. Subscribe on the monitor Pi with
`nats sub 'rpi.nodes.>'`.

- `rpi.nodes.<hostname>.online` — the base role's node announcer publishes
  this during role-setup; it retries 20x3s, then keeps retrying every 30s
  (systemd `Restart=on-failure`) until the broker is reachable.
- `rpi.nodes.<hostname>.setup-complete` — published when role-setup finishes
  successfully (best-effort ExecStartPost).

4. **Hotel procedure (phone, no SSH)** — plug in the dongle → join the
   travel SSID from your phone → the **public status page** opens
   automatically (the OS captive-portal popup; if it doesn't, open
   `http://192.168.50.1/`) → for management (scan/connect to the hotel
   network), open `http://192.168.50.1/admin`, log in with
   **`TRAVELROUTER_ADMIN_PSK`** (the setup PIN is only needed for admin
   changes) → tap **Scan** → pick the hotel
   network → **Connect** (add the PSK if the hotel uses WPA2). Then:
   - **Hotel with a captive portal** (login page): the Pi is now associated
     but not yet online — finish the **hotel's own login page from the same
     device**: open any `http://` site and the portal pops up (the Pi stays
     out of the way during this phase by design). Once you log in, the
     status page flips to internet=yes.
   - **Hotel with WPA2** (just a password): you already entered the PSK —
     done.
   - The "no internet" badge on your phone can linger a couple of minutes
     after connecting (OS re-probe cadence); `http://192.168.50.1` is the
     source of truth. WAN is re-detected every 30s; unplugging the adapter
     drops back to standalone automatically.

5. **Standalone note** — with no adapter plugged in the Pi is still a fully
   usable private AP (LAN + DHCP/DNS + status page, no NAT). While
   standalone, phones joining the travel SSID get the public status page
   pushed at them automatically (probe hijack, S05); a WAN existing
   switches the redirect off.

6. **Recovery / fallback (SSH)** — after role-setup the Pi is reachable ONLY
   via the travel SSID (SSH to 192.168.50.1, creds from `.env`; the
   `travel-wan` CLI still works: `ssh pi@192.168.50.1 travel-wan
   connect <SSID> <PSK>`) or by plugging a USB Ethernet adapter:
   NetworkManager keeps managing it, so the Pi regains wired connectivity
   (a DHCP address plus outbound internet — first-boot apt and WAN duty
   work). Wired connectivity is NOT wired SSH, though: the nftables input
   chain is policy-drop with accepts only on the travel-AP interface, so
   inbound connections arriving from the wired/WAN side — SSH included —
   are dropped by default. SSH is reachable only from the travel AP side,
   and only while SSH lockdown (above) is off; locked out of the AP side
   entirely, re-provision. Forgot the PIN? Re-provision, or edit
   `/boot/firmware/role/role.env` on the bootfs partition and restart
   `travel-router-status.service`. A FAILED role-setup stays enabled and
   retries on the next boot. If first-boot home WiFi was unreachable, apt
   fails BEFORE the AP interface is unmanaged, so the home-WiFi client
   config survives — fix `.env` and re-provision, or plug USB Ethernet.

7. **Upgrading a previously provisioned Pi** — Pis flashed before this
   feature have no setup PIN, so every admin WRITE stays deny-by-default
   there (reads still work with just the admin login): re-provision, or
   hand-add `TRAVELROUTER_SETUP_PIN` to `role.env`
   and restart `travel-router-status.service`. The same applies to
   `TRAVELROUTER_ADMIN_PSK` (the admin-page login): with no ADMIN_PSK set,
   login is deny-by-default and no session is ever issued — hand-add it to
   `role.env` and restart `travel-router-status.service`.

---

## Feature parking lot (ideas for future waves, not commitments)

Owned by the role; promote items from here into planned waves per the repo
planning protocol (explore -> draft -> review -> $start-work). Security-first
ordering — rogue-AP defense is the theme these serve:

1. **Rogue-AP detection** — when the WAN joins a hotel SSID, watch for a
   second AP beaconing the SAME SSID on a different BSSID/channel, and warn
   on the public status page (evil-twin indicator).
2. **Known-BSSID pinning** — record the BSSID a network was first joined
   with; warn when the same SSID shows up from an unknown BSSID.
3. **VPN-on-WAN option** — optional wireguard/tailscale tunnel over the
   hotel WAN so all client traffic exits a trusted endpoint, not the hotel.
4. **DHCP-lease ARP-watch** — surface duplicate-IP/spoofing anomalies from
   the LAN lease table on the admin page.
5. **HTTPS-only DNS (DoT) toggle** — route dnsmasq upstreams through DNS
   over TLS so hotel DNS cannot rewrite answers.
6. **Client quarantine VLAN/guest mode** — one-tap second SSID with
   LAN-isolation for devices you do not fully trust.
7. **Battery/UPS awareness** — surface supported UPS/battery-charge state
   on the status page (travel power stability).
8. **Auto-roam policy** — prefer known BSSIDs; rate-limit probe bursts to
   reduce fingerprinting on the travel AP.
