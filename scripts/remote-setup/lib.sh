#!/usr/bin/env bash
# shellcheck disable=SC2034  # the RS_* variables are read by remote-setup.sh and the trap handlers
# lib.sh: shared pieces of scripts/remote-setup/remote-setup.sh. Sourced, never run.
# bash 3.2-safe: no associative arrays, no ${x,,}, no mapfile, no |&.
#
# Output contract: every run ends with exactly one
# `DONE: ...` (exit 0) or `FIX: ...` (exit 3) as its last line. A usage error is the one
# exception: a `usage:` line on stderr and exit 2.
# No token is ever put in argv, a log, stdout, stderr or a status item (I1): the only way
# a token reaches Telegram is rs_tg, which hands curl a config on stdin.

RS_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
RS_ROOT_GUESS=$(cd "$RS_LIB_DIR/../.." && pwd -P)

RS_ITEMS_SHIPPED="bridge-health bridge-persistence distinct-tokens"

RS_PART=""
RS_N=0
RS_FINISHED=0
RS_TOKEN=""
RS_CHILD_PID=""
RS_TMP_FILE=""
RS_UNITS_STOPPED=""
RS_JSON_MODE=0

# ── output ──────────────────────────────────────────────────────────────

# One line, no control bytes, no token.
rs_clean() {
    local s=$1
    s=${s//$'\r'/ }
    s=${s//$'\n'/ }
    s=${s//$'\t'/ }
    if [ -n "${RS_TOKEN:-}" ]; then s=${s//"$RS_TOKEN"/[redacted]}; fi
    printf '%s' "$s"
}

rs_say() {
    if [ "$RS_JSON_MODE" = 1 ]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi
}

rs_begin() {
    RS_PART=$1
    RS_N=0
    RS_FINISHED=0
    trap rs_on_exit EXIT
    trap 'rs_fix "interrupted. Run the same command again"' INT
    trap 'rs_fix "terminated. Run the same command again"' TERM
    rs_say "remote-setup $1: $2"
}

# rs_step <text> [skip]: a numbered progress line.
rs_step() {
    RS_N=$((RS_N + 1))
    if [ "${2:-}" = skip ]; then
        rs_say "  $RS_N. $1 ... skip (already done)"
    else
        rs_say "  $RS_N. $1 ... ok"
    fi
}

rs_done() {
    local msg
    msg=$(rs_clean "$1")
    rs_cleanup_children
    if ! rs_unit_restore; then
        rs_fix "$RS_RESTORE_FAILED did not start again: run systemctl --user start telegram-bridge.service, or launchctl bootstrap it, then check the bridge" # t13b-ok: remediation message text only, starts nothing
    fi
    RS_FINISHED=1
    if [ "$RS_JSON_MODE" = 1 ]; then printf 'DONE: %s\n' "$msg" >&2; else printf 'DONE: %s\n' "$msg"; fi
    exit 0
}

rs_fix() {
    local msg
    msg=$(rs_clean "$1")
    rs_cleanup_children
    rs_unit_restore >/dev/null 2>&1
    [ -n "${RS_RESTORE_FAILED:-}" ] && msg="$msg (and $RS_RESTORE_FAILED did not start again: start it by hand)"
    RS_FINISHED=1
    if [ "$RS_JSON_MODE" = 1 ]; then printf 'FIX: %s\n' "$msg" >&2; else printf 'FIX: %s\n' "$msg"; fi
    exit 3
}

# The safety net: any exit that is neither DONE nor FIX still ends the run with a FIX line.
rs_on_exit() {
    if [ "$RS_FINISHED" != 1 ]; then
        RS_FINISHED=1
        rs_cleanup_children
        rs_unit_restore >/dev/null 2>&1
        if [ "$RS_JSON_MODE" = 1 ]; then
            echo "FIX: something unexpected went wrong. Run the same command again" >&2
        else
            echo "FIX: something unexpected went wrong. Run the same command again; if it fails again, tell your chief"
        fi
        exit 3
    fi
}

rs_cleanup_children() {
    if [ -n "${RS_CHILD_PID:-}" ]; then
        kill "$RS_CHILD_PID" 2>/dev/null
        wait "$RS_CHILD_PID" 2>/dev/null
        RS_CHILD_PID=""
    fi
    if [ -n "$RS_TMP_FILE" ]; then rm -f "$RS_TMP_FILE"; fi
    RS_TMP_FILE=""
}

# ── guards (invariant I2) ───────────────────────────────────────────────

# A courtesy refusal, not a structural block: what makes the pairing safe is that a session
# cannot read a bot token (A7).
rs_guard() {
    if [ -n "${CLAUDECODE:-}" ] || [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
        rs_fix "this step handles secrets and must run in a separate plain Terminal, not inside Claude and not with !. Open a Terminal window, go to your himmel folder, then run the same command there"
    fi
    if [ ! -t 0 ]; then
        rs_fix "this step needs a plain Terminal where you can type (no pipe, no script). Open a Terminal window, go to your himmel folder, then run the same command there"
    fi
    if [ "$(id -u)" = 0 ]; then
        rs_fix "run this as your normal user, not as root and not with sudo. Open a Terminal as yourself, go to your himmel folder, then run the same command there"
    fi
}

# Prints this script's checkout. Returns 1 when the current folder is not that checkout:
# the commands the helper prints are relative to it.
rs_checkout_root() {
    printf '%s\n' "$RS_ROOT_GUESS"
    [ "$(pwd -P)" = "$RS_ROOT_GUESS" ] && [ -f ./scripts/remote-setup/remote-setup.sh ]
}

rs_tilde() {
    case "$1" in
        "$HOME") printf '~' ;;
        "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# rs_need_checkout: sets RS_ROOT or FIXes with the one command that fixes it.
rs_need_checkout() {
    local p
    RS_ROOT=$(rs_checkout_root) || {
        p=$(rs_tilde "$RS_ROOT")
        case "$p" in *[!A-Za-z0-9_./~-]*) p="'$p'" ;; esac
        rs_fix "run this from your himmel folder: cd $p"
    }
}

rs_install_hint() {
    local tool=$1 pkg cmd
    pkg=$tool
    [ "$tool" = node ] && pkg=nodejs
    if [ "$tool" = bun ]; then
        cmd="curl -fsSL https://bun.sh/install | bash"
    elif [ "$(uname)" = Darwin ]; then
        [ "$tool" = node ] && pkg=node
        cmd="brew install $pkg"
    else
        cmd="sudo apt install $pkg"
    fi
    printf '%s is missing. Install it with: %s, then run the same command again' "$tool" "$cmd"
}

# rs_preflight <tool...>: one FIX per missing tool, naming that OS's install command.
rs_preflight() {
    local t
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || rs_fix "$(rs_install_hint "$t")"
    done
}

# ── secrets ─────────────────────────────────────────────────────────────

# rs_secret <varname> <prompt>: reads a line without echo, trims surrounding whitespace
# (a phone clipboard adds a trailing newline or space), stores it in <varname>. The variable
# is never exported. Returns 1 when nothing could be read.
rs_secret() {
    local _line=""
    printf '%s ' "$2"
    IFS= read -rs _line || { printf '\n'; return 1; }
    printf '\n'
    _line=${_line//$'\r'/}
    _line=${_line#"${_line%%[![:space:]]*}"}
    _line=${_line%"${_line##*[![:space:]]}"}
    printf -v "$1" '%s' "$_line"
    _line=""
    return 0
}

# A Telegram bot token has the shape <digits>:<35 url-safe chars>.
rs_token_shape_ok() {
    [[ $1 =~ ^[0-9]+:[A-Za-z0-9_-]{35}$ ]]
}

# ── Telegram ────────────────────────────────────────────────────────────

# rs_tg <method> [json-body]: prints the response JSON on stdout, using $RS_TOKEN.
# The token and the body reach curl only through a config on stdin (curl -K -), built by the
# printf builtin, so neither appears in argv or in ps. Always prints one JSON object: a
# transport failure is {"ok":false,"error_code":0,...}. Returns 0 when ok is true.
# On HTTP 429 it waits retry_after (at most 30 s) once and asks again.
rs_tg() {
    local method=$1 body=${2:-} cfg esc out rc ec wait tries=0
    if [ -z "${RS_TOKEN:-}" ]; then
        printf '{"ok":false,"error_code":0,"description":"no token"}\n'
        return 1
    fi
    cfg=$(printf 'url = "https://api.telegram.org/bot%s/%s"' "$RS_TOKEN" "$method")
    if [ -n "$body" ]; then
        esc=${body//\\/\\\\}
        esc=${esc//\"/\\\"}
        cfg="$cfg"$'\n''header = "Content-Type: application/json"'$'\n'"data = \"$esc\""
    fi
    while :; do
        out=$(printf '%s\n' "$cfg" | curl -sS --max-time 15 -K - 2>/dev/null)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            printf '{"ok":false,"error_code":0,"description":"cannot reach Telegram","curl_exit":%s}\n' "$rc"
            return 1
        fi
        if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
            printf '{"ok":false,"error_code":-1,"description":"unreadable answer"}\n'
            return 1
        fi
        ec=$(printf '%s' "$out" | jq -r '.error_code // 0')
        if [ "$ec" = 429 ] && [ "$tries" -lt 1 ]; then
            tries=$((tries + 1))
            wait=$(printf '%s' "$out" | jq -r '.parameters.retry_after // 1')
            case "$wait" in '' | *[!0-9]*) wait=1 ;; esac
            [ "$wait" -gt 30 ] && wait=30
            [ "$wait" -lt 1 ] && wait=1
            sleep "$wait"
            continue
        fi
        printf '%s\n' "$out"
        [ "$(printf '%s' "$out" | jq -r '.ok == true')" = true ]
        return
    done
}

# rs_tg_fail <json> [what]: turns a failed answer into the one FIX that names the action.
rs_tg_fail() {
    local ec desc retry what=${2:-the request}
    ec=$(printf '%s' "$1" | jq -r '.error_code // 0' 2>/dev/null)
    desc=$(printf '%s' "$1" | jq -r '.description // "no description"' 2>/dev/null)
    case "$ec" in
        0 | -1)
            rs_fix "can't reach api.telegram.org: check your internet connection, then run the same command again"
            ;;
        401)
            rs_fix "the token was revoked: get a new one from @BotFather (send /mybots, pick the bot, API Token, Revoke current token), then run the same command again"
            ;;
        429)
            retry=$(printf '%s' "$1" | jq -r '.parameters.retry_after // 30' 2>/dev/null)
            rs_fix "Telegram asked to wait $retry s: wait that long, then run the same command again"
            ;;
        *)
            desc=$(rs_clean "$desc")
            rs_fix "Telegram refused $what ($ec: ${desc:0:80}): run the same command again, and if it repeats tell your chief"
            ;;
    esac
}

# rs_getme: getMe with $RS_TOKEN. Sets RS_BOT_ID and RS_BOT_USER, or FIXes.
rs_getme() {
    local out
    out=$(rs_tg getMe) || rs_tg_fail "$out" "the token check"
    RS_BOT_ID=$(printf '%s' "$out" | jq -r '.result.id // empty' 2>/dev/null)
    RS_BOT_USER=$(printf '%s' "$out" | jq -r '.result.username // empty' 2>/dev/null)
    [[ $RS_BOT_ID =~ ^[0-9]{1,15}$ ]] || rs_fix "Telegram's answer to the token check had no bot id: run the same command again"
    [[ $RS_BOT_USER =~ ^[A-Za-z0-9_]{3,64}$ ]] || rs_fix "Telegram's answer to the token check had no usable bot name: run the same command again"
}

# ── units (invariant I5, H7) ────────────────────────────────────────────

# rs_unit_stop <linux-unit> <mac-label> [<fallback-launcher>]
# Stops a running bridge or poller through its unit when one is active, and remembers it so
# an EXIT, INT or TERM puts it back. With no active unit, a launcher script that still
# reports a running process is stopped through that script. Returns 1 when a stop failed.
rs_unit_stop() {
    local unit=$1 label=$2 fallback=${3:-} uid running
    uid=$(id -u)
    if [ "$(uname)" = Darwin ]; then
        if command -v launchctl >/dev/null 2>&1 && launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
            launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || return 1
            RS_UNITS_STOPPED="${RS_UNITS_STOPPED}M|$label"$'\n'
            return 0
        fi
    else
        if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet "$unit" 2>/dev/null; then
            systemctl --user stop "$unit" >/dev/null 2>&1 || return 1
            RS_UNITS_STOPPED="${RS_UNITS_STOPPED}L|$unit"$'\n'
            return 0
        fi
    fi
    if [ -n "$fallback" ] && [ -f "$fallback" ]; then
        running=$(bash "$fallback" status 2>/dev/null)
        case "$running" in
            *'bridge process(es):'*)
                bash "$fallback" stop >/dev/null 2>&1 || return 1
                RS_UNITS_STOPPED="${RS_UNITS_STOPPED}R|$fallback"$'\n'
                ;;
        esac
    fi
    return 0
}

# rs_unit_restore: starts everything rs_unit_stop stopped. Sets RS_RESTORE_FAILED to the
# names that did not start. Returns 1 when any failed. Safe to call twice.
rs_unit_restore() {
    local rec kind what uid pending
    RS_RESTORE_FAILED=""
    pending=$RS_UNITS_STOPPED
    RS_UNITS_STOPPED=""
    uid=$(id -u)
    while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        kind=${rec%%|*}
        what=${rec#*|}
        case "$kind" in
            L) systemctl --user start "$what" >/dev/null 2>&1 || RS_RESTORE_FAILED="${RS_RESTORE_FAILED:+$RS_RESTORE_FAILED, }$what" ;;
            M) launchctl bootstrap "gui/$uid" "$HOME/Library/LaunchAgents/$what.plist" >/dev/null 2>&1 || RS_RESTORE_FAILED="${RS_RESTORE_FAILED:+$RS_RESTORE_FAILED, }$what" ;; # t13b-ok: puts back the bridge LaunchAgent this run stopped, installs nothing new
            R) bash "$what" start >/dev/null 2>&1 || RS_RESTORE_FAILED="${RS_RESTORE_FAILED:+$RS_RESTORE_FAILED, }the bridge" ;;
        esac
    done <<EOF
$pending
EOF
    [ -z "$RS_RESTORE_FAILED" ]
}

# rs_unit_start <linux-unit> <mac-label>: starts one unit now, and forgets it as pending.
rs_unit_start() {
    local unit=$1 label=$2 uid kept rec
    uid=$(id -u)
    kept=""
    while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        [ "$rec" = "L|$unit" ] || [ "$rec" = "M|$label" ] || kept="${kept}${rec}"$'\n'
    done <<EOF
$RS_UNITS_STOPPED
EOF
    RS_UNITS_STOPPED=$kept
    if [ "$(uname)" = Darwin ]; then
        launchctl bootstrap "gui/$uid" "$HOME/Library/LaunchAgents/$label.plist" >/dev/null 2>&1 # t13b-ok: starts the bridge LaunchAgent the operator already installed, installs nothing new
    else
        systemctl --user start "$unit" >/dev/null 2>&1
    fi
}

# ── the main bot: token store, role check, access.json, pairing ─────────

# The token store is the bridge .env, written only through himmelctl's secret-store (a 0600 temp
# file plus rename). A token reaches these functions on stdin and leaves them on stdout, never argv.

# rs_stored_token: prints the stored main token, nothing when there is none.
rs_stored_token() {
    node -e '
const fs = require("fs");
const roles = require(process.argv[1]);
const file = roles.mainEnvFile({ home: process.env.HOME, env: process.env });
let raw = "";
try { raw = fs.readFileSync(file, "utf8"); } catch (_e) { process.exit(0); }
for (const line of raw.split(/\r?\n/)) {
  const m = /^\s*(?:export\s+)?TELEGRAM_BOT_TOKEN\s*=\s*(.*?)\s*$/.exec(line);
  if (m) { process.stdout.write(m[1].replace(/^(["\x27])(.*)\1$/, (_all, _quote, inner) => inner)); break; }
}
' "$RS_ROOT/scripts/himmelctl/lib/bot-roles.js"
}

# rs_store_token: the token on stdin goes into the store. Prints "store refused: <rule>" on stderr
# and returns 1 when the store says no. The rule never carries the value.
rs_store_token() {
    node -e '
const fs = require("fs");
const path = require("path");
const cp = require("child_process");
const root = process.argv[1];
const store = require(root + "/scripts/himmelctl/lib/secret-store.js");
const value = fs.readFileSync(0, "utf8").replace(/\r?\n$/, "");
const gitCheckIgnore = (f) => cp.spawnSync("git", ["check-ignore", "-q", f], { cwd: path.dirname(f) }).status === 0;
try {
  store.write("TELEGRAM_BOT_TOKEN", value, { home: process.env.HOME, himmelRoot: root, projectRoot: root, env: process.env, gitCheckIgnore });
} catch (e) {
  process.stderr.write("store refused: " + (e && e.message ? e.message : "unknown") + "\n");
  process.exit(1);
}
' "$RS_ROOT"
}

# rs_store_remove: drops the stored main token (the way back after a first token that must not stay).
rs_store_remove() {
    node -e '
const path = require("path");
const cp = require("child_process");
const root = process.argv[1];
const store = require(root + "/scripts/himmelctl/lib/secret-store.js");
const gitCheckIgnore = (f) => cp.spawnSync("git", ["check-ignore", "-q", f], { cwd: path.dirname(f) }).status === 0;
try {
  store.remove("TELEGRAM_BOT_TOKEN", { home: process.env.HOME, himmelRoot: root, projectRoot: root, env: process.env, gitCheckIgnore });
} catch (e) {
  process.stderr.write("store refused: " + (e && e.message ? e.message : "unknown") + "\n");
  process.exit(1);
}
' "$RS_ROOT"
}

# rs_role_check <candidate-bot-id> <role>: the one rule from bot-roles.js, given only the ids. Prints
# "<other role>|<reason>" and returns 1 when the candidate is another role's bot; returns 2 when the
# check itself could not run; returns 0 when the bot may take the role.
rs_role_check() {
    node -e '
const roles = require(process.argv[1]);
const ids = roles.readRoleIds({ home: process.env.HOME, repoRoot: process.argv[2], env: process.env });
const c = roles.roleConflict(process.argv[3], process.argv[4], ids);
if (c) { console.log(c.conflictsWith + "|" + c.reason); process.exit(1); }
' "$RS_ROOT/scripts/himmelctl/lib/bot-roles.js" "$RS_ROOT" "$1" "$2"
    local rc=$?
    [ "$rc" -le 1 ] || return 2
    return "$rc"
}

# rs_access_id <file>: prints the one allowed Telegram id; prints nothing when the file is absent.
# Returns 1 when the file is not an allowFrom list of exactly one digit string.
rs_access_id() {
    [ -e "$1" ] || return 0
    local id
    id=$(jq -r 'if ((.allowFrom | type) == "array") and ((.allowFrom | length) == 1) and ((.allowFrom[0] | type) == "string") and (.allowFrom[0] | test("^[0-9]{1,16}$")) then .allowFrom[0] else "BAD" end' "$1" 2> /dev/null) || return 1
    [ -n "$id" ] && [ "$id" != BAD ] || return 1
    printf '%s' "$id"
}

# rs_parse_onboard <file>: reads what onboard.ts printed. The producer is the fixed template
#   [onboard] chat.id=<int> chat.type=<word> from.id=<int|n/a> label=<free text>
# and only the label is free text, so a label can never move the two ids in front of it. Accepts
# exactly one offer line, a private chat (chat.id equals from.id), both ids plain digits. Sets
# RS_PAIR_ID and RS_PAIR_LABEL and returns 0; otherwise returns 1 with RS_PARSE_ERR = none (no
# offer), bad (an offer that is not a private chat with a real user) or many (more than one).
rs_parse_onboard() {
    local line n=0 seen=0 re
    RS_PAIR_ID=""
    RS_PAIR_LABEL=""
    RS_PARSE_ERR=""
    re='^\[onboard\] chat\.id=([1-9][0-9]{0,15}) chat\.type=private from\.id=([1-9][0-9]{0,15}) label=(.*)$'
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "[onboard] chat.id="*) seen=$((seen + 1)) ;; esac
        if [[ $line =~ $re ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]; then
            n=$((n + 1))
            if [ "$n" = 1 ]; then
                RS_PAIR_ID=${BASH_REMATCH[2]}
                RS_PAIR_LABEL=${BASH_REMATCH[3]}
            fi
        fi
    done < "$1" # read-sink-ok: the mktemp file rs_pair made, or a fixture the suite names
    if [ "$n" = 1 ] && [ "$seen" = 1 ]; then return 0; fi
    RS_PAIR_ID=""
    RS_PAIR_LABEL=""
    if [ "$seen" -eq 0 ]; then RS_PARSE_ERR=none; elif [ "$seen" -gt 1 ]; then RS_PARSE_ERR=many; else RS_PARSE_ERR=bad; fi
    return 1
}

# rs_pair: the deep-link round trip that learns which Telegram account is the operator. Stops the
# bridge (a second getUpdates consumer would fight it), runs onboard.ts, shows the link, waits for
# the Start press and puts the bridge back. Sets RS_PAIR_ID and RS_PAIR_LABEL, or FIXes.
rs_pair() {
    local out nonce i=0 orc alive
    out=$(mktemp "${TMPDIR:-/tmp}/remote-setup-onboard.XXXXXX") || rs_fix "could not make a temporary file: check that your temp folder is writable, then run the same command again"
    RS_TMP_FILE=$out
    rs_unit_stop telegram-bridge.service com.himmel.telegram-bridge "$RS_ROOT/scripts/telegram/restart-bridge.sh" \
        || rs_fix "the bridge could not be stopped for pairing: stop it with bash scripts/telegram/restart-bridge.sh stop, then run the same command again"
    bun scripts/telegram/onboard.ts > "$out" 2>&1 &
    RS_CHILD_PID=$!
    nonce=""
    while [ "$i" -lt 100 ]; do
        alive=0
        if kill -0 "$RS_CHILD_PID" 2> /dev/null; then alive=1; fi
        nonce=$(sed -n 's/^\[onboard\] send this exact text to the bot (DM or an allowed group) to onboard: \(onboard-[0-9a-f]\{8\}\)$/\1/p' "$out" | head -n 1)
        if [ -n "$nonce" ] || [ "$alive" = 0 ]; then break; fi
        sleep 0.2
        i=$((i + 1))
    done
    if [ -z "$nonce" ]; then
        if grep -q 'refusing to start' "$out" 2> /dev/null; then
            rs_fix "the bridge is still running, so pairing cannot start: stop it with bash scripts/telegram/restart-bridge.sh stop, then run the same command again"
        fi
        rs_fix "pairing did not start: check your internet connection, then run the same command again"
    fi
    rs_say "  Open this link on your phone and press Start in Telegram:"
    rs_say "    https://t.me/$RS_BOT_USER?start=$nonce"
    wait "$RS_CHILD_PID"
    orc=$?
    RS_CHILD_PID=""
    rs_unit_restore || rs_fix "the bridge did not start again ($RS_RESTORE_FAILED): start it by hand, then run the same command again"
    if ! rs_parse_onboard "$out"; then
        case "$RS_PARSE_ERR" in
            many) rs_fix "pairing saw more than one reply: run the same command again and press Start once" ;;
            bad) rs_fix "the reply did not come from a private chat with your bot: open the link on your phone, press Start in that private chat, then run the same command again" ;;
            *)
                [ "$orc" -eq 0 ] || rs_fix "pairing failed: check your internet connection, then run the same command again"
                rs_fix "no Start press arrived in time: run the same command again and press Start right after the link appears"
                ;;
        esac
    fi
}
