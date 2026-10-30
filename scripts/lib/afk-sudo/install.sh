#!/usr/bin/env bash
# install.sh — install the AFK sudo helper on ONE station.
# Operator-run with sudo, on a test VM first; an agent never runs it.
#
#   sudo bash scripts/lib/afk-sudo/install.sh --user <login>
#   sudo bash scripts/lib/afk-sudo/install.sh --uninstall
#
# Installs root-owned copies of afk_sudo.py (as /usr/local/libexec/himmel/afk-sudo),
# approval_broker.py and never_remote.py (the run-kind floor, which a config cannot
# remove), one sudoers rule letting <login> run exactly that
# installed copy (checked with visudo -cf before it is moved into place), the
# ledger /var/log/himmel/afk-sudo.jsonl, the state dir, and on first install the
# TOTP seed, printed ONCE as an otpauth URI for the authenticator app.
# The station config /etc/himmel/afk-sudo.json ships disabled with an empty
# allowlist, mode allowlist and the run kind off (the run kind is also compiled
# off until a release flips it); enabling it is a separate `sudoedit` by the operator.
# A session talks to the installed helper through scripts/lib/afk-run (run kind) or
# scripts/lib/afk-sudo-request (sudo kind); neither is installed here.
# --uninstall removes the helper and the sudoers rule and keeps the config, the
# seed, the state and the ledger.
set -uo pipefail

LIBEXEC=/usr/local/libexec/himmel
SUDOERS=/etc/sudoers.d/himmel-afk-sudo
CONFIG=/etc/himmel/afk-sudo.json
SEED=/etc/himmel/afk-sudo/totp.seed
LEDGER=/var/log/himmel/afk-sudo.jsonl

# --- hints for the operator's next step ---
# Bash builtins plus uname only, so a test can source this file under a stubbed
# PATH and AFK_OS_RELEASE.
os_family() {
    local id="" like="" k v osr=${AFK_OS_RELEASE:-/etc/os-release}
    if [ "$(uname -s 2>/dev/null)" = Darwin ]; then echo mac; return; fi
    if [ -r "$osr" ]; then
        while IFS='=' read -r k v; do
            v=${v//\"/}
            case "$k" in ID) id=$v ;; ID_LIKE) like=$v ;; esac
        done < "$osr"
    fi
    case " $id $like " in
        *" arch "*) echo arch ;;
        *" debian "* | *" ubuntu "*) echo debian ;;
        *) echo unknown ;;
    esac
}
pkg_hint() {
    case "$(os_family)" in
        arch) echo "sudo pacman -S $*" ;;
        debian) echo "sudo apt install $*" ;;
        mac) echo "brew install $*" ;;
        *) echo "install with your package manager: $*" ;;
    esac
}
# The sudoedit command that works here: sudoedit needs an editor, and a minimal
# station has no vi.
enable_cmd() {
    local e
    if [ -n "${SUDO_EDITOR:-}${VISUAL:-}${EDITOR:-}" ] || command -v vi >/dev/null 2>&1; then
        echo "sudoedit $CONFIG"; return
    fi
    for e in nano vim micro; do
        if command -v "$e" >/dev/null 2>&1; then echo "SUDO_EDITOR=$e sudoedit $CONFIG"; return; fi
    done
    echo "SUDO_EDITOR=nano sudoedit $CONFIG   (no editor found; install one first: $(pkg_hint nano))"
}
qr_hint() {
    if ! command -v qrencode >/dev/null 2>&1; then echo "No QR code (qrencode is missing); to get one next time: $(pkg_hint qrencode)"; fi
}
# Sourced by the test: stop before the root check and the install.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

usage(){ echo "usage: sudo bash install.sh --user <login> | --uninstall" >&2; exit 2; }
die() { echo "install.sh: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "install.sh: run it with sudo" >&2; exit 2; }
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || die "cannot resolve the source dir"

case "${1:-}" in
    --uninstall)
        rm -f "$SUDOERS" "$LIBEXEC/afk-sudo" "$LIBEXEC/approval_broker.py" "$LIBEXEC/never_remote.py" || die "uninstall failed"
        echo "removed the helper and the sudoers rule; kept $CONFIG, $SEED, the state and $LEDGER"
        exit 0 ;;
    --user) [ $# -eq 2 ] || usage; user=$2 ;;
    *) usage ;;
esac
id -u "$user" >/dev/null 2>&1 || { echo "install.sh: no such user: $user" >&2; exit 2; }
case "$user" in *[!A-Za-z0-9._-]*) echo "install.sh: unexpected characters in user name" >&2; exit 2 ;; esac

install -d -o root -g root -m 0755 "$LIBEXEC" /etc/himmel /var/log/himmel /var/lib/himmel || die "cannot create the directories"
install -d -o root -g root -m 0700 /etc/himmel/afk-sudo /var/lib/himmel/afk-sudo || die "cannot create the private directories"
install -o root -g root -m 0644 "$src/approval_broker.py" "$LIBEXEC/approval_broker.py" || die "cannot install approval_broker.py"
install -o root -g root -m 0644 "$src/never_remote.py" "$LIBEXEC/never_remote.py" || die "cannot install never_remote.py"
install -o root -g root -m 0755 "$src/afk_sudo.py" "$LIBEXEC/afk-sudo" || die "cannot install the helper"
[ -e "$LEDGER" ] || install -o root -g root -m 0644 /dev/null "$LEDGER" || die "cannot create the ledger"

tmp=$(mktemp "${TMPDIR:-/tmp}/afk-sudo.XXXXXX") || die "mktemp failed"
trap 'rm -f "$tmp"' EXIT

if [ ! -e "$CONFIG" ]; then
    printf '{\n  "enabled": false,\n  "operator_id": 0,\n  "window_s": 120,\n  "mode": "allowlist",\n  "operator_user": "",\n  "max_per_hour": 6,\n  "run": {"enabled": false, "ttl_s": 900, "timeout_s": 300},\n  "never_remote_extra": [],\n  "classes": {}\n}\n' > "$tmp" || die "cannot write the config"
    install -o root -g root -m 0644 "$tmp" "$CONFIG" || die "cannot install the config"
fi

if [ ! -e "$SEED" ]; then
    (umask 077; python3 -I -c 'import base64, secrets; print(base64.b32encode(secrets.token_bytes(20)).decode())' > "$SEED.new") || die "cannot generate the seed"
    { chown root:root "$SEED.new" && chmod 0600 "$SEED.new" && mv "$SEED.new" "$SEED"; } || die "cannot install the seed"
    uri="otpauth://totp/himmel-afk-sudo:$(hostname)?secret=$(cat "$SEED")&issuer=himmel"
    echo "Add this to your authenticator app now; it is not shown again:"
    echo "$uri"
    if command -v qrencode >/dev/null 2>&1; then qrencode -t ansiutf8 "$uri"; else qr_hint; fi
fi

printf '%s ALL=(root) NOPASSWD: %s\n' "$user" "$LIBEXEC/afk-sudo" > "$tmp" || die "cannot write the sudoers rule"
visudo -cf "$tmp" >/dev/null || die "visudo rejected the sudoers rule"
install -o root -g root -m 0440 "$tmp" "$SUDOERS" || die "cannot install the sudoers rule"
echo "installed for $user; still disabled. Enable: $(enable_cmd) (enabled, operator_id, classes)"
