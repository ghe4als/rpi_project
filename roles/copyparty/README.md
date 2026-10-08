# copyparty — role manual

> The copyparty role turns a Pi into a file server bound **only** to its
> Tailscale IP: no LAN/public exposure by construction. Auth-only (no
> anonymous access), optional at-rest encryption, optional true end-to-end
> sealing of individual files. Short start here; repo overview in the
> root [`README.md`](../../README.md).

---

## Threat model

What this role protects against, layer by layer:

- **Transit** — WireGuard tailnet encryption end-to-end; TLS termination at
  `https://<pi>.<tailnet>.ts.net/` via Tailscale Serve (one-time enable in
  the admin console). Traffic on hostile Wi-Fi reads as opaque encrypted UDP.
- **Network reach** — the server binds ONLY to the Tailscale IP + loopback
  (resolved at runtime, every boot). A LAN-side port scan finds nothing.
- **Casual read** — all access requires a real login (`--usernames`); no
  anonymous anything; anonymous file read → 403, wrong password → 403.
- **Card theft** — *with at-rest crypto on*: attacker gets ciphertext with
  gibberish filenames. *Same-card keyfile default* means a determined
  attacker with the whole card eventually gets in (obfuscation-grade —
  see Key custody). *With age-sealed files*: those are unreadable by ANYONE
  without your private key, including this server.

Not covered: a fully compromised running Pi reads plaintext of unsealed
files (kernel decrypted them at mount); RAM/page-cache exposure while
mounted is inherent to gocryptfs-class encryption.

## Key custody

The default (key staged from `.env` `COPYPARTY_CRYPT_KEY` to the bootfs as
`copyparty.crypt.key`, 0600 root) is zero-touch: the Pi boots, unlocks,
serves. The tradeoff: card + key live on the same device — thief-with-card
defeats it eventually. Stronger options (manual, described not automated):

1. **USB-stick keyfile** — keep `copyparty.crypt.key` on a stick that
   normally lives elsewhere; copy it in only when you need unattended
   boots. Card alone = useless ciphertext.
2. **Passphrase at boot** — remove the staged keyfile, run
   `gocryptfs -passwd`-style unlock over SSH manually after each boot
   (`tailscale ssh` still reaches the Pi; the file server stays down until
   you unlock). Strongest convenience-free option.

Regardless of custody: **back the key up somewhere safe. Lose the gocryptfs
key = lose ALL share data** (the volume is unrecoverable without it).

## age workflow

For files that must survive even a full server compromise — sealed by YOU,
before upload; the server stores a blob it can never open.

One-time on your Mac:

```bash
brew install age
age-keygen -o ~/age.key        # prints your public key; guard the private file
```

Seal before upload:

```bash
age -r <YOUR-PUBLIC-KEY> -o taxes.pdf.age taxes.pdf
# upload taxes.pdf.age through the copyparty UI like any file; delete the plaintext
```

Open after download (any device holding `~/age.key`):

```bash
age -d -i ~/age.key -o taxes.pdf taxes.pdf.age
```

Rules: the private key NEVER lives on the Pi; `.age` files are opaque to
thumbnails/preview (they're ciphertext — that's the point); **lost key =
lost files, there is no recovery**.

## USB drive variants

`COPYPARTY_DIR` may point at any prepared, persistent mount — the SD card
or an ext4/exFAT USB drive. Two supported shapes:

- **Files on USB, key on card** — `COPYPARTY_DIR=/mnt/share` (drive mounted
  via `/etc/fstab` entry you add once over SSH). Card theft yields zero
  files; thief now needs BOTH devices. Recommended if you add a drive.
- **Share stays on card** — nothing to do; the crypt volume backs the
  default `/var/lib/copyparty`.

Boundary by design: NEW drives never auto-appear in the web UI. Wiring a
drive = one SSH session (mount + fstab + set `COPYPARTY_DIR` + re-provision
or edit `/etc/copyparty/args` + restart). After that, all file operations
run through the UI. Pi 3B+ note: USB2 caps throughput ~35-40 MB/s.

## Recovery

Card read on another machine (any Linux box):

```bash
apt install gocryptfs
gocryptfs -extpass "cat /path/to/copyparty.crypt.key" \
  /path/to/card/var/lib/copyparty-crypt /mnt/recovered
```

The share appears plaintext under `/mnt/recovered`. The keyfile is the one
irreplaceable piece — treat it like a password vault master key.
(Parked alternatives, deliberately unsupported here: rclone crypt over
WebDAV; LUKS container files.)

---

## `.env` reference

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `TAILSCALE_AUTH_KEY` | yes | — | One-time key; the tailscale dep joins the tailnet. |
| `COPYPARTY_ACCOUNTS` | **yes** | — | `user:pass` pairs, comma-sep; first = r/w owner. |
| `COPYPARTY_PORT` | no | `3923` | TCP port on the Tailscale IP. |
| `COPYPARTY_DIR` | no | `/var/lib/copyparty` | Share root; may be a persistent USB mount. |
| `COPYPARTY_CRYPT` | no | `0` | `1` = gocryptfs under the share (at-rest). |
| `COPYPARTY_CRYPT_KEY` | when crypt | — | Volume key; staged 0600 to bootfs. |
| `COPYPARTY_SFX_URL` | no | latest release | Alternate sfx source URL. |
| `COPYPARTY_WAIT_SEC` | no | `180` | Seconds to wait for tailscale0 at boot. |

## Troubleshooting

- **copyparty won't start, journal shows "FATAL: crypt mount missing"** —
  the fail-closed guard tripped: gocryptfs volume wasn't mounted (key
  changed? backing dir gone?). `journalctl -u crypt-unlock.service` has the
  mount error; fix the cause and restart both units.
- **Service fails with "could not resolve Tailscale IPv4"** — tailnet not
  up; check `journalctl -u tailscale-up.service`, approve the node in the
  admin console, then `systemctl restart copyparty`.
- **Wrong password rejected with 403 even though UI shows list** — correct:
  auth-only. Log in with one of the `COPYPARTY_ACCOUNTS` pairs.
- **Logs:** `journalctl -u copyparty.service`, or `/var/log/role-setup.log`
  for first-boot provisioning output.
---

## Credential rotation

Two independent credentials exist. Rotate them separately.

### 1. Web-UI account (routine, instant)

**Or just run the rotation pusher** — generates fresh passwords for the
accounts you name (default: all), applies them on the Pi, restarts,
verifies every new login over HTTP before touching anything local, mirrors
`.env` to match, and prints the new pairs once:

```bash
cd ~/code/rpi_project
roles/copyparty/rotate-accounts.sh              # rotate ALL accounts
roles/copyparty/rotate-accounts.sh al           # rotate one
roles/copyparty/rotate-accounts.sh --check      # peek, no change
```

Fail-safe behavior: if any new login fails verification it stops with the
`.env` unmodified and prints the SSH one-liner to restore the on-Pi args
backup (`args.bak-*-rotation`).

The service reads `/etc/copyparty/args` at start. To rotate UI creds

```bash
ssh pi@<pi>
sudo nano /etc/copyparty/args
# edit the trailing -a user:pass line(s)
sudo systemctl restart copyparty
```

Then MIRROR the new pairs in `.env` (`COPYPARTY_ACCOUNTS=...`) on the
provisioning host — the next provision re-renders args from `.env` and
would otherwise silently revert the rotation. Optionally replace plaintext
with the argon2-hashed form copyparty echoes in the journal at startup
(`grep -oE '^  -a [^ ]+' journalctl -u copyparty` output) to keep creds
hashed at rest.

Extra accounts: add `-a user2:pass2` lines; they get read-only access
until granted write by appending their name after a `:rwmd,` segment in the
`-v` line (first user is the r/w/m/d owner; that is also where you can
hand out move-only or delete-only rights, e.g. `:m,user2,` or `:d,user3,`).

### 2. gocryptfs volume key (only if the key itself was exposed)

Rotation requires the current key intact (or the master key from
`gocryptfs.conf`), remount, and BOTH copies updated (Pi bootfs + Mac
`.env`) before the next boot, or the fail-closed guard leaves copyparty
down:

```bash
ssh pi@<pi>
sudo systemctl stop copyparty.service crypt-unlock.service
sudo umount /var/lib/copyparty 2>/dev/null || true
# generate + stage the NEW key first (keep a copy for .env):
NEWKEY=$(openssl rand -hex 32); echo "$NEWKEY" | tee ~/new-crypt-key   # copy to .env!
sudo install -m 0755 /dev/null /boot/firmware/role/copyparty.crypt.key.new 2>/dev/null
printf '%s' "$NEWKEY" | sudo tee /boot/firmware/role/copyparty.crypt.key.new >/dev/null
# rotate the volume to the new key:
sudo gocryptfs -passwd \
  -extpass "cat /boot/firmware/role/copyparty.crypt.key" \
  /var/lib/copyparty-crypt
sudo rm -f /boot/firmware/role/copyparty.crypt.key
sudo mv /boot/firmware/role/copyparty.crypt.key.new /boot/firmware/role/copyparty.crypt.key
sudo systemctl start crypt-unlock.service && sudo systemctl start copyparty.service
# verify mount + 200, then delete ~/new-crypt-key and update .env COPYPARTY_CRYPT_KEY
```

Sanity anchors: volume key files live in `/var/lib/copyparty-crypt/`
(`gocryptfs.conf` etc.); the keyfile is on the VFAT bootfs so its perms
are governed by fmask/dmask, not chmod (world-readable 0755 — accepted
documented tradeoff). Fail-closed: copyparty NEVER starts over plaintext
if the keyfile/new key mismatches the volume — check
`journalctl -u crypt-unlock` first whenever the server is down.