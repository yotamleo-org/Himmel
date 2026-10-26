#!/usr/bin/env bash
# The frozen VM trial for scripts/lib/himmel-secrets on ubuntu_new.
# Fake keys only (HIMMEL_TRIAL_7147_*). Prints PASS/FAIL lines, never a value.
# Run inside the guest: bash /tmp/7147-trial.sh [<himmel checkout>]
# shellcheck disable=SC2015,SC2329 # frozen copy of the historic trial: annotations only, behaviour unchanged
set -u
H="${1:-$HOME/himmel}"
HS="$H/scripts/lib/himmel-secrets"
W=$(mktemp -d /tmp/7147-trial.XXXXXX) || exit 2 # prim-ok: runs inside the guest, never on the host
fails=0
ok() { printf 'PASS %s\n' "$1"; }
no() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }

printf 'guest: %s uid=%s head=%s\n' "$(uname -sr)" "$(id -u)" "$(git -C "$H" rev-parse HEAD 2>/dev/null)"
[ -x "$HS" ] || { no "resolver present at $HS"; exit 1; }
for t in secret-tool busctl timeout gnome-keyring-daemon dbus-daemon; do
    command -v "$t" >/dev/null 2>&1 && printf 'tool %s: yes\n' "$t" || printf 'tool %s: NO\n' "$t"
done

# The guest has no desktop session over ssh, so the trial runs a private
# session bus listening at $W/rt/bus (the cron-shaped step finds it there)
# with gnome-keyring unlocked by a throwaway password.
inner() {
    set -u
    rt="$W/rt"
    printf 'trial-pw-7147' | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1
    sleep 1

    out=$("$HS" status 2>&1 | head -1)
    chk "1 status reports an unlocked keyring" "$out" "keyring: unlocked"

    printf 'fake-7147-user' | "$HS" put --stdin HIMMEL_TRIAL_7147_A >/dev/null 2>&1
    v=$("$HS" get --no-dotenv HIMMEL_TRIAL_7147_A 2>/dev/null)
    chk "2 lookup serves the stored user-default key" "$v" "HIMMEL_TRIAL_7147_A=fake-7147-user"

    (cd "$H" && printf 'fake-7147-project' | "$HS" put --project --stdin HIMMEL_TRIAL_7147_A >/dev/null 2>&1)
    v=$(cd "$H" && "$HS" get --no-dotenv HIMMEL_TRIAL_7147_A 2>/dev/null)
    chk "3 project-scoped entry beats the user default" "$v" "HIMMEL_TRIAL_7147_A=fake-7147-project"
    v=$(cd "$W" && "$HS" get --no-dotenv HIMMEL_TRIAL_7147_A 2>/dev/null)
    chk "3b outside the project the user default serves" "$v" "HIMMEL_TRIAL_7147_A=fake-7147-user"

    v=$(cd "$W" && env -i HOME="$HOME" PATH="$PATH" HIMMEL_SECRETS_RUNTIME_DIR="$rt" \
        "$HS" get --no-dotenv HIMMEL_TRIAL_7147_A 2>/dev/null)
    chk "4 cron-shaped env (no DBUS_SESSION_BUS_ADDRESS) finds <rt>/bus" "$v" "HIMMEL_TRIAL_7147_A=fake-7147-user"

    printf 'ZAI_API_KEY=fake-7147-b\nJIRA_EMAIL=fake@example.invalid\n' >"$W/in.env"
    out=$("$HS" import-env "$W/in.env" 2>&1)
    case "$out" in *"stored ZAI_API_KEY"*"skipped JIRA_EMAIL (config key"*) ok "5 import-env stores the secret, skips the config key" ;;
        *) no "5 import-env output: $out" ;; esac
    "$HS" export-env "$W/out.env" >/dev/null 2>&1
    chk "6 export-env writes a 0600 file" "$(stat -c %a "$W/out.env" 2>/dev/null)" "600" # gnu-ok: the guest is Ubuntu
    grep -qx 'HIMMEL_TRIAL_7147_A=fake-7147-user' "$W/out.env" && grep -qx 'ZAI_API_KEY=fake-7147-b' "$W/out.env" \
        && ok "6b export-env restores both keys" || no "6b export-env content (key names: $(cut -d= -f1 "$W/out.env" | tr '\n' ' '))"
    mkdir -p "$W/repo" && git -C "$W/repo" init -q && cp "$W/out.env" "$W/repo/.env"
    v=$(cd "$W/repo" && HIMMEL_SECRETS_KEYRING=off bash -c '. "$1"; load_dotenv ZAI_API_KEY; printf "%s" "${ZAI_API_KEY-}"' _ "$H/scripts/lib/load-dotenv.sh" 2>/dev/null)
    chk "6c the exported .env works as a legacy .env" "$v" "fake-7147-b"

    busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service \
        Lock ao 1 /org/freedesktop/secrets/aliases/default >/dev/null 2>&1
    s=$(date +%s)
    err=$(cd "$W" && "$HS" get --no-dotenv HIMMEL_TRIAL_7147_A 2>&1 >/dev/null)
    rc=$?; d=$(( $(date +%s) - s ))
    [ "$d" -le 3 ] && ok "7 locked keyring returns in ${d}s (rc=$rc)" || no "7 locked keyring took ${d}s"
    chk "7b exactly one 'keyring locked' line" "$(printf '%s\n' "$err" | grep -c 'keyring locked')" "1"
}
export -f inner ok no chk
export H HS W fails
# Keep the throwaway keyring and its control socket under $W, away from any
# real login keyring.
mkdir -p "$W/data" "$W/xrt" "$W/rt" && chmod 700 "$W/xrt" "$W/rt"
export XDG_DATA_HOME="$W/data" XDG_RUNTIME_DIR="$W/xrt"
bus_pid=$(dbus-daemon --session --fork --print-pid --address="unix:path=$W/rt/bus") || { no "private session bus starts"; exit 1; }
[ -S "$W/rt/bus" ] && ok "0 private session bus listens at <rt>/bus" || no "0 bus socket at <rt>/bus"
DBUS_SESSION_BUS_ADDRESS="unix:path=$W/rt/bus" bash -c 'inner; exit $fails'
rc=$(( $? + fails ))
kill "$bus_pid" 2>/dev/null
rm -rf "$W"
printf 'trial done: %s\n' "$([ "$rc" = 0 ] && echo ALL PASS || echo "$rc FAIL(s)")"
exit "$rc"
