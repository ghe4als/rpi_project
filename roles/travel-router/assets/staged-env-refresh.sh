#!/bin/bash
# staged-env-refresh.sh — re-derive the status unit's EnvironmentFile from
# bootfs role.env on EVERY start. /run is tmpfs (wiped by reboot) and
# role-setup disables itself after success, so install.sh's one-shot staging
# leaves the unit without SETUP_PIN/ADMIN_PSK after the first powercycle
# (observed 2026-09-21: every admin login 401'd). Running as ExecStartPre
# also makes hand-edit role.env + restart work as the recovery path.
# Exit 0 in every failure mode: staging must never block the service; a
# missing env file keeps the deny-by-default posture (login 401 / writes 403).
set -u

ENV_DIR="${TRAVELROUTER_ENV_DIR:-/run/travel-router/role-env}"
ENV_FILE="$ENV_DIR/travel-router-setup.env"

# Canonical runtime role.env lives on ext4 so credential rotation can rewrite
# it atomically. Fall back to the bootfs copy for first-boot / recovery.
role_env="${TRAVELROUTER_ROLE_ENV:-/etc/rpi-project/travel-router/role.env}"
[[ -f "$role_env" ]] || role_env="/run/travel-router/role.env"
[[ -f "$role_env" ]] || role_env="/boot/firmware/role/role.env"
[[ -f "$role_env" ]] || role_env="/boot/role/role.env"
if [[ ! -f "$role_env" ]]; then
    echo "[staged-env-refresh] no role.env found; nothing staged (deny-by-default)"
    exit 0
fi

set -a
# shellcheck disable=SC1090
. "$role_env" 2>/dev/null
src_rc=$?
set +a
if [[ $src_rc -ne 0 ]]; then
    echo "[staged-env-refresh] role.env failed to parse (rc=$src_rc); refusing to stage partial values"
    exit 0
fi

upin="${TRAVELROUTER_SETUP_PIN:-}"
apsk="${TRAVELROUTER_ADMIN_PSK:-}"
if [[ -z "$upin" && -z "$apsk" ]]; then
    echo "[staged-env-refresh] role.env has no SETUP_PIN/ADMIN_PSK; nothing staged"
    exit 0
fi

# Render-breaker chars would break the env file (or inject variables via $).
case "$upin$apsk" in
    *'|'*|*'\'*|*'$'*|*'&'*|*$'\n'*)
        echo "[staged-env-refresh] SETUP_PIN/ADMIN_PSK contains a render-breaker char (pipe, backslash, dollar, ampersand, or newline); refusing to stage"
        exit 0 ;;
esac

if ! mkdir -p "$ENV_DIR" 2>/dev/null; then
    echo "[staged-env-refresh] cannot create $ENV_DIR; nothing staged"
    exit 0
fi
tmp="$ENV_FILE.new.$$"
: > "$tmp"
[[ -n "$upin" ]] && printf 'TRAVELROUTER_SETUP_PIN="%s"\n' "$upin" >> "$tmp"
[[ -n "$apsk" ]] && printf 'TRAVELROUTER_ADMIN_PSK="%s"\n' "$apsk" >> "$tmp"
chmod 0600 "$tmp" 2>/dev/null || true
if mv -f "$tmp" "$ENV_FILE" 2>/dev/null; then
    what=""
    [[ -n "$upin" ]] && what="PIN"
    [[ -n "$apsk" ]] && what="${what:+$what+}PSK"
    echo "[staged-env-refresh] staged $what env file (0600) from $role_env"
else
    rm -f "$tmp" 2>/dev/null || true
    echo "[staged-env-refresh] staging failed (mv); leaving previous state"
fi
exit 0