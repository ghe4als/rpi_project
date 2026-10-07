# tailscale — role manual

> The tailscale role turns a Pi into a Tailscale **subnet router** with
> **Tailscale SSH** enabled, reachable from anywhere on your tailnet. Short
> start here and a fuller overview in the repo [`README.md`](../../README.md).

---

## What this role does

- Installs Tailscale from the official installer.
- Enables IP forwarding (subnet routing needs it) via a sysctl drop-in.
- On first boot, runs `tailscale up --ssh --advertise-routes=<subnet>
  --hostname=<host>` with a one-time auth key, then **scrubs that key**
  from `role.env` on the bootfs so it can't leak if the card is re-read.

---

## Setup steps (generate the auth key)

While you're in front of the browser minting a key, follow this:

1. **Open the auth-keys page** — https://login.tailscale.com/admin/settings/keys

2. **Generate a one-time auth key:**
   - **Reusable key:** OFF (leave the default one-shot unless you'll
     re-provision the same card)
   - **Ephemeral:** OFF (permanent node entry)
   - **Tags:** optional — e.g. `tag:router` if your tailnet uses ACLs that
     require tags to advertise a subnet. For a simple single-admin tailnet,
     leave this blank.
   - Copy the `tskey-auth-…` value.

3. **Drop it into `.env`** (or `.env` on the provisioning host):
   ```dotenv
   # tailscale role only:
   TAILSCALE_AUTH_KEY="tskey-auth-xxxxxxxxxxxxxxxx"
   TAILSCALE_SUBNET="192.168.0.0/24"   # the LAN this Pi will route for
   ROLE="tailscale"
   ```
   `TAILSCALE_HOSTNAME` and `TAILSCALE_UP_TIMEOUT_SEC` are optional and have
   defaults (`hostname` and `120` respectively) — leave them out.

4. **Flash + boot.** After first boot the Pi joins the tailnet and advertises
   `TAILSCALE_SUBNET` as a subnet route.

5. **Approve in the console** — the node and its subnet route must both be
   approved at https://login.tailscale.com/admin/machines
   (Machines → this node → Approve → Edit route settings → enable the subnet).

---

## `.env` reference

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `TAILSCALE_AUTH_KEY` | **yes** | — | One-time auth key. Scrubbed from `role.env` after first up. |
| `TAILSCALE_SUBNET` | no | `192.168...0.0/24` | LAN subnet advertised as a subnet route. |
| `TAILSCALE_HOSTNAME` | no | Pi hostname | Node name on the tailnet. |
| `TAILSCALE_UP_TIMEOUT_SEC` | no | `120` | Seconds the bring-up wait accepts before failing. |
| `TRAVELROUTER_*` | — | — | Not used by this role. |

---

## Troubleshooting

- **"TAILSCALE_AUTH_KEY not set"** on boot — the key isn't in `role.env`; set
  it in `.env`, re-provision. The Pi still boots and stays reachable on LAN.
- **`tailscale up` fails** — expired/used key, tailnet ACL blocks the key, or
  no internet. Regenerate a one-time key (`tskey-auth-…`) and re-provision.
- **No routing to the subnet** — forgot to approve the subnet route in the
  console (the node AND the route both need approval).
- **Logs:** `journalctl -u tailscale-up.service` or `/var/log/role-setup.log`.

---

## How the pieces fit

- `install.sh` runs during `role-setup.service`: installs Tailscale, sets
  forwarding, stages the bring-up wrapper + systemd service.
- `tailscale-up.service` (a oneshot with `ConditionPathExists` on a done
  marker) runs `tailscale up` once, at multi-user, after network-online —
  see `assets/tailscale-up.sh` for the exact argv. Key scrub after success.
