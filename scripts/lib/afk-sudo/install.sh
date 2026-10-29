#!/usr/bin/env bash
# install.sh — install the AFK sudo helper on ONE station.
# Operator-run with sudo, on a test VM first; an agent never runs it.
#
#   sudo bash scripts/lib/afk-sudo/install.sh --user <login>
#   sudo bash scripts/lib/afk-sudo/install.sh --uninstall
#
# Installs root-owned copies of afk_sudo.py (as /usr/local/libexec/himmel/afk-sudo)
# and approval_broker.py, one sudoers rule letting <login> run exactly that
# installed copy (checked with visudo -cf before it is moved into place), the
# ledger /var/log/himmel/afk-sudo.jsonl, the state dir, and on first install the
# TOTP seed, printed ONCE as an otpauth URI for the authenticator app.
# The station config /etc/himmel/afk-sudo.json ships disabled with an empty
# allowlist; enabling it is a separate `sudoedit` by the operator.
# --uninstall removes the helper and the sudoers rule and keeps the config, the
# seed, the state and the ledger.
set -uo pipefail

LIBEXEC=/usr/local/libexec/himmel
SUDOERS=/etc/sudoers.d/himmel-afk-sudo
CONFIG=/etc/himmel/afk-sudo.json
SEED=/etc/himmel/afk-sudo/totp.seed
LEDGER=/var/log/himmel/afk-sudo.jsonl

usage() { echo "usage: sudo bash install.sh --user <login> | --uninstall" >&2; exit 2; }
die() { echo "install.sh: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "install.sh: run it with sudo" >&2; exit 2; }
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || die "cannot resolve the source dir"

case "${1:-}" in
    --uninstall)
        rm -f "$SUDOERS" "$LIBEXEC/afk-sudo" "$LIBEXEC/approval_broker.py" || die "uninstall failed"
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
install -o root -g root -m 0755 "$src/afk_sudo.py" "$LIBEXEC/afk-sudo" || die "cannot install the helper"
[ -e "$LEDGER" ] || install -o root -g root -m 0644 /dev/null "$LEDGER" || die "cannot create the ledger"

tmp=$(mktemp "${TMPDIR:-/tmp}/afk-sudo.XXXXXX") || die "mktemp failed"
trap 'rm -f "$tmp"' EXIT

if [ ! -e "$CONFIG" ]; then
    printf '{\n  "enabled": false,\n  "operator_id": 0,\n  "window_s": 120,\n  "classes": {}\n}\n' > "$tmp" || die "cannot write the config"
    install -o root -g root -m 0644 "$tmp" "$CONFIG" || die "cannot install the config"
fi

if [ ! -e "$SEED" ]; then
    (umask 077; python3 -I -c 'import base64, secrets; print(base64.b32encode(secrets.token_bytes(20)).decode())' > "$SEED.new") || die "cannot generate the seed"
    { chown root:root "$SEED.new" && chmod 0600 "$SEED.new" && mv "$SEED.new" "$SEED"; } || die "cannot install the seed"
    uri="otpauth://totp/himmel-afk-sudo:$(hostname)?secret=$(cat "$SEED")&issuer=himmel"
    echo "Add this to your authenticator app now; it is not shown again:"
    echo "$uri"
    if command -v qrencode >/dev/null 2>&1; then qrencode -t ansiutf8 "$uri"; fi
fi

printf '%s ALL=(root) NOPASSWD: %s\n' "$user" "$LIBEXEC/afk-sudo" > "$tmp" || die "cannot write the sudoers rule"
visudo -cf "$tmp" >/dev/null || die "visudo rejected the sudoers rule"
install -o root -g root -m 0440 "$tmp" "$SUDOERS" || die "cannot install the sudoers rule"
echo "installed for $user; still disabled. Enable: sudoedit $CONFIG (enabled, operator_id, classes)"
