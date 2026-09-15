#!/bin/bash
# Renders cloud-init user-data + network-config from templates and stages a
# role directory onto an already-flashed Raspberry Pi OS Trixie SD card's
# bootfs partition.
#
# Usage: ./provision.sh [ROLE] [/Volumes/bootfs]
#   ROLE defaults to value in .env, else "base".
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"

ROLE_ARG=""
BOOT=""
for arg in "$@"; do
  if [[ "$arg" == /* ]]; then BOOT="$arg"; else ROLE_ARG="$arg"; fi
done
BOOT="${BOOT:-/Volumes/bootfs}"

if [[ ! -f "$REPO/.env" ]]; then
  echo "ERROR: $REPO/.env missing. Copy .env.example to .env and fill it in." >&2
  exit 1
fi

if [[ ! -d "$BOOT" ]]; then
  echo "ERROR: $BOOT not mounted. Re-insert the SD card or pass the right path." >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a; source "$REPO/.env"; set +a

: "${WIFI_SSID:?}" "${WIFI_PSK:?}" "${WIFI_COUNTRY:?}" \
  "${PI_USERNAME:?}" "${PI_PASSWORD:?}" \
  "${TIMEZONE:?}" "${LOCALE:?}" "${KEYMAP:?}"

ROLE="${ROLE_ARG:-${ROLE:-base}}"
# ROLES_PATHS: colon-separated list of dirs to search for <role>/install.sh.
# Defaults to $REPO/roles (backwards-compatible). External sibling repos can
# extend this, e.g. ROLES_PATHS=/path/to/piChick/roles:./roles ./provision.sh chicken-cam ...
ROLES_PATHS="${ROLES_PATHS:-$REPO/roles}"
ROLE_SRC=""
for _path in ${ROLES_PATHS//:/ }; do
  if [[ -x "$_path/$ROLE/install.sh" ]]; then
    ROLE_SRC="$_path/$ROLE"
    break
  fi
done
if [[ -z "$ROLE_SRC" ]]; then
  echo "ERROR: role '$ROLE' not found in ROLES_PATHS='$ROLES_PATHS' (looked for <path>/$ROLE/install.sh)" >&2
  exit 1
fi
echo "Selected role: $ROLE"

# macOS ships LibreSSL, whose `openssl passwd` doesn't support -6 (SHA-512
# crypt). Try the system openssl first, fall back to Homebrew's openssl@3,
# then python3's crypt module. All three produce a $6$... hash glibc accepts.
hash_password() {
  local pw="$1"
  if openssl passwd -6 "$pw" 2>/dev/null; then return 0; fi
  local brew_ssl="/opt/homebrew/opt/openssl@3/bin/openssl"
  [[ -x "$brew_ssl" ]] && "$brew_ssl" passwd -6 "$pw" 2>/dev/null && return 0
  python3 -c "import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))" "$pw"
}
PI_PASSWORD_HASH=$(hash_password "$PI_PASSWORD")
export PI_PASSWORD_HASH

SSH_KEYS_DIR="${SSH_KEYS_DIR:-$HOME/.ssh}"
SSH_AUTHORIZED_KEYS_INDENTED=""
key_count=0
for keyfile in "$SSH_KEYS_DIR"/id_ed25519.pub "$SSH_KEYS_DIR"/id_rsa.pub "$SSH_KEYS_DIR"/id_ecdsa.pub; do
  [[ -f "$keyfile" ]] || continue
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    SSH_AUTHORIZED_KEYS_INDENTED+="      - \"$line\""$'\n'
    key_count=$((key_count + 1))
  done < "$keyfile"
done
if [[ $key_count -eq 0 ]]; then
  echo "WARNING: no SSH public keys found in $SSH_KEYS_DIR (looked for id_ed25519/rsa/ecdsa.pub)" >&2
  SSH_AUTHORIZED_KEYS_INDENTED="      []"$'\n'
else
  echo "Embedding $key_count SSH public key(s) into user-data"
fi
SSH_AUTHORIZED_KEYS_INDENTED="${SSH_AUTHORIZED_KEYS_INDENTED%$'\n'}"
export SSH_AUTHORIZED_KEYS_INDENTED

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

VARS='${LOCALE} ${TIMEZONE} ${KEYMAP} ${PI_USERNAME} ${PI_PASSWORD_HASH} ${WIFI_SSID} ${WIFI_PSK} ${WIFI_COUNTRY} ${SSH_AUTHORIZED_KEYS_INDENTED}'
envsubst "$VARS" < "$REPO/user-data.tmpl"      > "$TMPDIR/user-data"
envsubst "$VARS" < "$REPO/network-config.tmpl" > "$TMPDIR/network-config"

echo "--- rendered user-data (password hash redacted) ---"
sed 's|passwd: \$.*|passwd: <hashed, redacted>|' "$TMPDIR/user-data"
echo "----------------------------------------------------"

# Overwrite cloud-init files on bootfs.
cp "$TMPDIR/user-data"      "$BOOT/user-data"
cp "$TMPDIR/network-config" "$BOOT/network-config"

# Bump instance_id so cloud-init treats this as a NEW instance and re-runs
# everything from scratch (incl. bootcmd / runcmd / the first-boot user
# creation). Without this bump, re-provisioning the SAME card causes
# cloud-init to say "already ran" and skip our updated user-data.
NEW_INSTANCE_ID="rpios-$(date +%Y%m%d%H%M%S)-$RANDOM"
if [[ -f "$BOOT/meta-data" ]]; then
  sed -i.bak "s/^instance_id:.*/instance_id: $NEW_INSTANCE_ID/" "$BOOT/meta-data"
  rm -f "$BOOT/meta-data.bak"
else
  printf 'instance_id: %s\ndsmode: local\n' "$NEW_INSTANCE_ID" > "$BOOT/meta-data"
fi
echo "instance_id bumped to: $NEW_INSTANCE_ID"

# Stage role tree at /boot/firmware/role/. Always include base/ for reuse.
# COPYFILE_DISABLE=1 prevents macOS from creating ._* AppleDouble metadata
# files on the FAT bootfs. Without it, /boot/firmware/role/._install.sh ends
# up alongside install.sh, both with execute bits, and bash on the Pi can
# pick up the AppleDouble binary - which silently fails the role-setup
# unit. Burned an hour of debugging on this one.
echo "Staging role '$ROLE' (+ base + declared deps) onto bootfs"
rm -rf "$BOOT/role"
mkdir -p "$BOOT/role"

# Resolve a role directory through ROLES_PATHS (same search as the selected role).
find_role_src() {
  local r="$1" p
  for p in ${ROLES_PATHS//:/ }; do
    if [[ -x "$p/$r/install.sh" ]]; then
      echo "$p/$r"
      return 0
    fi
  done
  return 1
}

# Recursively collect a role's dependencies from its optional role.deps file
# (one role name per line; blank lines and '#' comments ignored). Cycle-safe.
declare -a STAGE_ORDER=()
_seen_deps=""
collect_deps() {
  local r="$1" src deps_file dep
  case " $_seen_deps " in *" $r "*) return 0;; esac
  _seen_deps="$_seen_deps $r"
  src="$(find_role_src "$r")" || { echo "ERROR: dependency role '$r' not found in ROLES_PATHS='$ROLES_PATHS'" >&2; exit 1; }
  deps_file="$src/role.deps"
  if [[ -f "$deps_file" ]]; then
    while IFS= read -r dep; do
      dep="${dep%%#*}"; dep="${dep//[[:space:]]/}"
      [[ -n "$dep" ]] || continue
      collect_deps "$dep"
    done < "$deps_file"
  fi
  STAGE_ORDER+=("$r")
}

# base is always staged first; then the selected role's dep closure (deps before role).
COPYFILE_DISABLE=1 cp -R "$REPO/roles/base" "$BOOT/role/base"
if [[ "$ROLE" != "base" ]]; then
  collect_deps "$ROLE"
  for r in "${STAGE_ORDER[@]}"; do
    [[ "$r" == "base" ]] && continue
    rsrc="$(find_role_src "$r")"
    echo "  staging role: $r"
    COPYFILE_DISABLE=1 cp -R "$rsrc" "$BOOT/role/$r"
  done
fi

# Generic dispatcher: role-setup.service runs THIS top-level install.sh, which
# sources role.env and execs the selected role's REAL install.sh. This keeps
# $0 (and therefore $ROLE_DIR/assets) correct inside the role script.
cat > "$BOOT/role/install.sh" <<'DISPATCH'
#!/bin/bash
set -euo pipefail
ROLE_ENV=/boot/firmware/role/role.env
[[ -f "$ROLE_ENV" ]] || ROLE_ENV=/boot/role/role.env
# shellcheck disable=SC1090
[[ -f "$ROLE_ENV" ]] && source "$ROLE_ENV"
: "${ROLE:?ERROR: ROLE not set in role.env}"
ROLE_BASE="$(dirname "$0")"
TARGET="$ROLE_BASE/$ROLE/install.sh"
[[ -x "$TARGET" ]] || { echo "ERROR: role installer not found/executable: $TARGET" >&2; exit 1; }
exec /bin/bash "$TARGET"
DISPATCH
find "$BOOT/role" -name install.sh -exec chmod +x {} \;

ROLE_ENV_FILE="$BOOT/role/role.env"
{
  echo "ROLE=$ROLE"
  for var in $(env | awk -F= '/^(TOUCHSCREEN|NATS|OLLAMA|COOP|MOTION|TAILSCALE|NETDATA|TRAVELROUTER)_/ {print $1}'); do
    val="${!var}"
    printf '%s=%q\n' "$var" "$val"
  done
  # travel-router bootstraps its WAN from the provisioning WiFi: install.sh
  # seeds it as the first NM profile ("hotel simulation"). The PSK is already
  # plaintext on this partition (network-config), so no new exposure.
  if [[ "$ROLE" == "travel-router" ]]; then
    for var in WIFI_SSID WIFI_PSK WIFI_COUNTRY; do
      val="${!var}"
      printf '%s=%q\n' "$var" "$val"
    done
  fi
} > "$ROLE_ENV_FILE"
chmod 0644 "$ROLE_ENV_FILE"

# travel-router setup-v2: optional PSK seed file (.psksecret, gitignored) —
# staged next to role.env so install.sh can find it via the role-tree path.
if [[ "$ROLE" == "travel-router" && -f "$REPO/.psksecret" ]]; then
  cp "$REPO/.psksecret" "$BOOT/role/.psksecret"
fi

rm -f "$BOOT/custom.toml" "$BOOT/firstrun.sh" "$BOOT/firstrun.log" \
      "$BOOT/wpa_supplicant.conf"

# Touch $BOOT/ssh so the Raspberry Pi OS legacy "enable SSH on first boot"
# mechanism fires regardless of whether cloud-init's cc_ssh module runs.
# cloud-init should still configure SSH (user/pubkey/etc.), but on Lite
# images cc_ssh can fail silently; without this flag there's no fallback
# and the Pi is unreachable headless.
touch "$BOOT/ssh"

find "$BOOT" \( -name '._*' -o -name '.DS_Store' -o -name '.Spotlight-V100' -o -name '.Trashes' -o -name '.fseventsd' \) -print -exec rm -rf {} + 2>/dev/null || true

if command -v yq >/dev/null 2>&1; then
  PENDING_INV="$REPO/inventory.yaml"
  [[ -f "$PENDING_INV" ]] || printf '%s\n' '{}' > "$PENDING_INV"
  PENDING_TS="$(date +%Y-%m-%dT%H:%M:%S%z | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/')"
  PARENT_DISK_GUESS="$(df "$BOOT" 2>/dev/null | awk 'NR==2{print $1}' | sed 's/s[0-9]*$//')"
  yq -i "
    .pending_flashes += [{
      \"flashed_at\":                 \"$PENDING_TS\",
      \"instance_id\":                \"$NEW_INSTANCE_ID\",
      \"image\":                      \"$(basename "${IMAGE_HINT:-unknown}")\",
      \"disk\":                       \"${PARENT_DISK_GUESS:-unknown}\",
      \"role\":                       \"$ROLE\",
      \"pi_username\":                \"$PI_USERNAME\",
      \"wifi_ssid\":                  \"$WIFI_SSID\",
      \"touchscreen_overlay\":        \"${TOUCHSCREEN_OVERLAY:-}\",
      \"touchscreen_overlay_params\": \"${TOUCHSCREEN_OVERLAY_PARAMS:-}\"
    }]
  " "$PENDING_INV"
  echo "[inventory] recorded pending flash (instance_id=$NEW_INSTANCE_ID, role=$ROLE)"
  echo "[inventory] run 'pi discover' after the Pi boots to bind it to a serial"
fi

sync
echo
echo "Provisioning written to $BOOT. Ejecting..."
# Capture the parent disk BEFORE we eject - df won't work after unmount.
PARENT_DISK="$(df "$BOOT" 2>/dev/null | awk 'NR==2{print $1}' | sed 's/s[0-9]*$//')"
if diskutil eject "$BOOT" >/dev/null 2>&1; then
  echo "Ejected. Safe to remove."
elif [[ -n "$PARENT_DISK" ]] && diskutil eject "$PARENT_DISK" >/dev/null 2>&1; then
  echo "Ejected ($PARENT_DISK). Safe to remove."
else
  echo "Eject failed; run 'diskutil eject $PARENT_DISK' manually before pulling the card."
fi
