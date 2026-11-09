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
# TOTP seed, printed ONCE as an otpauth URI for the authenticator app, and a root-only
# notice-bot.env for the notice bot's token (the bot root sends each request's
# facts and nonce through; no request is filed while it holds no token), written from
# notice-bot.env.template with a TELEGRAM_BOT_TOKEN= placeholder and never rewritten.
# The station config /etc/himmel/afk-sudo.json is written from afk-sudo.json.template when absent;
# over an existing config the keys it lacks are added (nested ones too), no existing value is
# changed, and only key names are printed. It ships disabled with an empty
# allowlist, mode allowlist and the run kind off (run.enabled false; the compiled
# switch RUN_KIND_SHIPPED is on since slice 1b), the grant kind off (grant.enabled false) and the
# station ops off (ops.enabled false); enabling any is a separate `sudoedit` by the operator.
# The ops (scripts/station-ops) are copied root-owned to /usr/local/libexec/himmel/ops with a manifest.
# A session talks to the installed helper through scripts/lib/afk-run (run kind) or
# scripts/lib/afk-sudo-request (sudo kind); neither is installed here.
# --uninstall removes the helper and the sudoers rule and keeps the config, the
# seed, notice-bot.env, the state and the ledger.
set -uo pipefail

LIBEXEC=/usr/local/libexec/himmel
SUDOERS=/etc/sudoers.d/himmel-afk-sudo
CONFIG=/etc/himmel/afk-sudo.json
SEED=/etc/himmel/afk-sudo/totp.seed
LEDGER=/var/log/himmel/afk-sudo.jsonl
NOTICE_ENV=/etc/himmel/afk-sudo/notice-bot.env
ROOT_GROUP=root

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
    local e f=${1:-$CONFIG}
    if [ -n "${SUDO_EDITOR:-}${VISUAL:-}${EDITOR:-}" ] || command -v vi >/dev/null 2>&1; then
        echo "sudoedit $f"; return
    fi
    for e in nano vim micro; do
        if command -v "$e" >/dev/null 2>&1; then echo "SUDO_EDITOR=$e sudoedit $f"; return; fi
    done
    echo "SUDO_EDITOR=nano sudoedit $f   (no editor found; install one first: $(pkg_hint nano))"
}
# The config and the notice bot's env file come from the templates beside this script, only when
# absent; a station's own files are never rewritten wholesale.
# install_config <srcdir> <config>: write the config from afk-sudo.json.template, or, when it exists,
# add the template's keys it lacks (nested ones too) and change no existing value. The file keeps its
# mode and owner; only key names are printed, never a value.
install_config() {
    local src=$1 cfg=$2 added
    if [ ! -e "$cfg" ] && [ ! -L "$cfg" ]; then
        install -o root -g root -m 0644 "$src/afk-sudo.json.template" "$cfg" || return 1
        return 0
    fi
    # shellcheck disable=SC2016 # python source, not shell
    added=$(python3 -I -c '
import json, os, stat, sys, tempfile
tpl_path, cfg_path = sys.argv[1:3]
# The owner the helper requires is root; a test seam names another uid, honoured only when this is not root.
owner = int(os.environ.get("AFK_OWNER_UID", "0")) if os.geteuid() != 0 else 0
def refuse(why):
    sys.exit("install.sh: refusing " + cfg_path + ": " + why + " (the helper refuses it too); fix it first")
with open(tpl_path, encoding="utf-8") as f:
    tpl = json.load(f)
# The checks the helper makes before it reads the config (approval_broker.check_safe): lstat, so a link is refused.
st = os.lstat(cfg_path)
if not stat.S_ISREG(st.st_mode):
    refuse("not a regular file (a link or a directory)")
if st.st_uid != owner:
    refuse("not owned by root")
if st.st_mode & 0o022:
    refuse("group- or world-writable")
with open(cfg_path, "rb") as f:
    raw = f.read()
try:
    cur = json.loads(raw.decode("utf-8"))
except ValueError:
    sys.exit("install.sh: " + cfg_path + " is not valid JSON in UTF-8 (the helper refuses it too); it is left as it was")
if not isinstance(cur, dict):
    sys.exit("the config is not a JSON object")
added = []
def fill(dst, src, prefix):
    for k, v in src.items():
        if k not in dst:
            dst[k] = v
            added.append(prefix + k)
        elif isinstance(dst[k], dict) and isinstance(v, dict):
            fill(dst[k], v, prefix + k + ".")
fill(cur, tpl, "")
if added:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(cfg_path), prefix=".afk-sudo.")
    try:
        os.fchmod(fd, st.st_mode & 0o7777)
        os.fchown(fd, st.st_uid, st.st_gid)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(cur, f, indent=2, ensure_ascii=False)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        # Replace only a config that is still the one we read (a lockdown or an edit in between is not overwritten).
        st2 = os.lstat(cfg_path)
        with open(cfg_path, "rb") as f:
            again = f.read()
        if (st2.st_ino, st2.st_mtime_ns, st2.st_size) != (st.st_ino, st.st_mtime_ns, st.st_size) or again != raw:
            sys.exit("install.sh: " + cfg_path + " changed while it was being merged; it is left as it is, run the install again")
        os.replace(tmp, cfg_path)
    except BaseException:
        if os.path.lexists(tmp):
            os.unlink(tmp)
        raise
    dfd = os.open(os.path.dirname(cfg_path), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
print(" ".join(added))
' "$src/afk-sudo.json.template" "$cfg") || { echo "install.sh: the new keys were not added to $cfg; it is left as it was" >&2; return 1; }
    if [ -n "$added" ]; then
        echo "Added the new keys to $cfg (existing values untouched): $added"
    fi
}
# install_notice_env <srcdir> <file>: write the TELEGRAM_BOT_TOKEN= placeholder (no token, root only) when absent.
install_notice_env() {
    local src=$1 f=$2
    [ -e "$f" ] && return 0
    install -o root -g "$ROOT_GROUP" -m 0600 "$src/notice-bot.env.template" "$f" || return 1
    notice_env_steps
}
notice_env_steps() {
    echo "Created $NOTICE_ENV with no token: sudo and run requests are refused until it holds one."
    echo "The notice bot is a SECOND bot, not the Telegram bridge's: root alone sends each request's facts and nonce through it."
    echo "  1. In Telegram, ask @BotFather for /newbot and copy the token."
    echo "  2. Open the new bot's chat and send it /start, so it may message you."
    echo "  3. $(enable_cmd "$NOTICE_ENV") and put the token after TELEGRAM_BOT_TOKEN= on its last line."
}
qr_hint() {
    if ! command -v qrencode >/dev/null 2>&1; then echo "No QR code (qrencode is missing); to get one next time: $(pkg_hint qrencode)"; fi
}
stale_files() {
    local src=$1 lx=$2 opsrc f
    [ -e "$lx/afk-sudo" ] || return 0
    opsrc="$src/../../station-ops"
    cmp -s "$src/afk_sudo.py" "$lx/afk-sudo" || echo "$lx/afk-sudo"
    for f in approval_broker.py never_remote.py; do
        cmp -s "$src/$f" "$lx/$f" || echo "$lx/$f"
    done
    for f in "$opsrc"/*.json; do
        f=$(basename "$f" .json)
        cmp -s "$opsrc/$f.json" "$lx/ops/$f.json" || echo "$lx/ops/$f.json"
        cmp -s "$opsrc/$f.sh" "$lx/ops/$f.sh" || echo "$lx/ops/$f.sh"
    done
    for f in "$lx/ops"/*.json; do
        [ -e "$f" ] && [ "${f##*/}" != manifest.json ] || continue
        [ -e "$opsrc/$(basename "$f")" ] || echo "$f"
    done
}
# Sourced by the test: stop before the root check and the install.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

usage(){ echo "usage: sudo bash install.sh --user <login> | --uninstall" >&2; exit 2; }
die() { echo "install.sh: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "install.sh: run it with sudo" >&2; exit 2; }
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || die "cannot resolve the source dir"

case "${1:-}" in
    --uninstall)
        rm -rf "$LIBEXEC/ops" || die "uninstall failed"
        rm -f "$SUDOERS" "$LIBEXEC/afk-sudo" "$LIBEXEC/approval_broker.py" "$LIBEXEC/never_remote.py" || die "uninstall failed"
        echo "removed the helper and the sudoers rule; kept $CONFIG, $SEED, $NOTICE_ENV, the state and $LEDGER"
        exit 0 ;;
    --user) [ $# -eq 2 ] || usage; user=$2 ;;
    *) usage ;;
esac
id -u "$user" >/dev/null 2>&1 || { echo "install.sh: no such user: $user" >&2; exit 2; }
case "$user" in *[!A-Za-z0-9._-]*) echo "install.sh: unexpected characters in user name" >&2; exit 2 ;; esac

install -d -o root -g root -m 0755 "$LIBEXEC" /etc/himmel /var/log/himmel /var/lib/himmel || die "cannot create the directories"
install -d -o root -g root -m 0700 /etc/himmel/afk-sudo /var/lib/himmel/afk-sudo || die "cannot create the private directories"
# The grant kind's hash-only markers: readable by the PreToolUse check, written by root alone.
install -d -o root -g root -m 0755 /var/lib/himmel/afk-grants || die "cannot create the grant marker directory"
install -o root -g root -m 0644 "$src/approval_broker.py" "$LIBEXEC/approval_broker.py" || die "cannot install approval_broker.py"
install -o root -g root -m 0644 "$src/never_remote.py" "$LIBEXEC/never_remote.py" || die "cannot install never_remote.py"
install -o root -g root -m 0755 "$src/afk_sudo.py" "$LIBEXEC/afk-sudo" || die "cannot install the helper"
# The station ops: root-owned copies of scripts/station-ops/<op>.sh + <op>.json and a manifest of their
# version and sha256. The helper runs only an installed copy that still hashes to the manifest, never the repo file.
opsrc=$(cd "$src/../../station-ops" 2>/dev/null && pwd) || die "cannot find scripts/station-ops"
rm -rf "$LIBEXEC/ops" || die "cannot clear $LIBEXEC/ops"
install -d -o root -g root -m 0755 "$LIBEXEC/ops" || die "cannot create $LIBEXEC/ops"
for f in "$opsrc"/*.json; do
    op=$(basename "$f" .json)
    install -o root -g root -m 0644 "$f" "$LIBEXEC/ops/$op.json" || die "cannot install $op.json"
    install -o root -g root -m 0755 "$opsrc/$op.sh" "$LIBEXEC/ops/$op.sh" || die "cannot install $op.sh"
done
python3 -I "$opsrc/build-manifest.py" "$LIBEXEC/ops" >/dev/null || die "cannot write the ops manifest"
[ -e "$LEDGER" ] || install -o root -g root -m 0644 /dev/null "$LEDGER" || die "cannot create the ledger"

tmp=$(mktemp "${TMPDIR:-/tmp}/afk-sudo.XXXXXX") || die "mktemp failed"
trap 'rm -f "$tmp"' EXIT

install_config "$src" "$CONFIG" || die "cannot install the config"

if [ ! -e "$SEED" ]; then
    (umask 077; python3 -I -c 'import base64, secrets; print(base64.b32encode(secrets.token_bytes(20)).decode())' > "$SEED.new") || die "cannot generate the seed"
    { chown root:root "$SEED.new" && chmod 0600 "$SEED.new" && mv "$SEED.new" "$SEED"; } || die "cannot install the seed"
    uri="otpauth://totp/himmel-afk-sudo:$(hostname)?secret=$(cat "$SEED")&issuer=himmel"
    echo "Add this to your authenticator app now; it is not shown again:"
    echo "$uri"
    if command -v qrencode >/dev/null 2>&1; then qrencode -t ansiutf8 "$uri"; else qr_hint; fi
fi

install_notice_env "$src" "$NOTICE_ENV" || die "cannot create $NOTICE_ENV"

printf '%s ALL=(root) NOPASSWD: %s\n' "$user" "$LIBEXEC/afk-sudo" > "$tmp" || die "cannot write the sudoers rule"
visudo -cf "$tmp" >/dev/null || die "visudo rejected the sudoers rule"
install -o root -g root -m 0440 "$tmp" "$SUDOERS" || die "cannot install the sudoers rule"
echo "installed for $user; still disabled. Enable: $(enable_cmd) (enabled, operator_id, classes)"
