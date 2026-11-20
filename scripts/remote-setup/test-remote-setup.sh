#!/usr/bin/env bash
# test-remote-setup.sh: hermetic suite for scripts/remote-setup/.
#
# The SUT runs from a FIXTURE checkout (copies of lib.sh and remote-setup.sh, a stub
# himmelctl, the real himmelctl lib dir by symlink), with a fixture HOME and PATH shims for
# curl, systemctl, launchctl, sudo, sleep, uname, id and bun (scripts/remote-setup/testlib/).
# Nothing here touches the network, the real HOME, a real unit or a real token: tokens are
# random canaries. The seam is this harness, never a flag in the SUT.
#
# run_sut [--inject VAR=VAL]... [--no-tty] [--as-root] [--no-contract] [--json]
#         [--cwd DIR] [--without TOOL] <stdin-file> <args...>
#   By default the SUT runs under `script` (a real tty) with CLAUDECODE and
#   CLAUDE_CODE_SESSION_ID unset. --inject adds a guard variable back after the unset,
#   --no-tty skips `script`, --as-root makes `id -u` answer 0. Every run is checked against
#   the output contract (last line DONE+exit 0 or FIX+exit 3, exactly one such line) unless
#   --no-contract (usage rows only); --json checks the JSON contract instead.
#
# Run it under bash 3.2 too: ~/.local/opt/bash-3.2.57/bash scripts/remote-setup/test-remote-setup.sh

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/rs-test.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
PATH_BASE=$PATH
REAL_BUN=$(command -v bun || echo /nonexistent-bun)

PASS=0
FAILN=0
SKIPN=0
CASE_FAILS=0
CASE=""

# ── assertions ──────────────────────────────────────────────────────────

check() { # check <description> <command...>
    local d=$1
    shift
    if ! "$@"; then
        CASE_FAILS=$((CASE_FAILS + 1))
        printf 'FAIL: %s: %s\n' "$CASE" "$d" >&2
        [ -n "${LAST:-}" ] && printf '      last line: %s\n' "$LAST" >&2
    fi
}
eq() { [ "$1" = "$2" ]; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
lacks() { case "$1" in *"$2"*) return 1 ;; esac; return 0; }
starts() { case "$1" in "$2"*) return 0 ;; esac; return 1; }
file_has() { grep -qF -- "$2" "$1" 2>/dev/null; }
file_lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null; }

# ── fixture ─────────────────────────────────────────────────────────────

new_case() {
    CASE=$1
    CASE_FAILS=0
    T=$WORK/$1
    mkdir -p "$T/home" "$T/tmp" "$T/bin" "$T/tg" "$T/units" "$T/root"
    cp "$HERE"/testlib/shims/* "$T/bin/"
    ROOT=$T/root
    HOME_FIX=$T/home
    mk_root
    set_getme 111 cand_bot
    : > "$T/in"
    RC=""
    LAST=""
}

mk_root() {
    mkdir -p "$ROOT/scripts/remote-setup/testlib" "$ROOT/scripts/himmelctl" "$ROOT/scripts/telegram"
    cp "$HERE/lib.sh" "$HERE/remote-setup.sh" "$ROOT/scripts/remote-setup/"
    cp "$HERE/testlib/drive.sh" "$ROOT/scripts/remote-setup/testlib/"
    cp "$HERE/testlib/himmelctl-stub.js" "$ROOT/scripts/himmelctl/bin.js"
    if [ -d "$REPO/scripts/himmelctl/lib" ]; then ln -s "$REPO/scripts/himmelctl/lib" "$ROOT/scripts/himmelctl/lib"; fi
    printf '// stub: the bun shim answers for onboard.ts\n' > "$ROOT/scripts/telegram/onboard.ts"
    cp "$HERE/testlib/restart-bridge-stub.sh" "$ROOT/scripts/telegram/restart-bridge.sh"
}

# A canary token: <id>:<35 url-safe chars>. Never a real credential.
mk_token() {
    printf '%s:CNRY%s' "$1" "$(LC_ALL=C tr -dc 'A-Za-z0-9_-' < /dev/urandom | head -c 31)"
}

set_getme() { # set_getme <id> <username>
    printf '{"ok":true,"result":{"id":%s,"is_bot":true,"username":"%s"}}' "$1" "$2" > "$T/tg/getMe.json"
}

set_item() { # set_item <id> <severity> [detail]
    local f=$T/items.json
    [ -f "$f" ] || echo '{}' > "$f"
    jq --arg id "$1" --arg s "$2" --arg d "${3:-}" '.[$id] = {severity: $s, detail: $d}' "$f" > "$f.new" && mv "$f.new" "$f"
}

feed() { # feed <line>...: the lines the human types, one per prompt
    : > "$T/in"
    local l
    for l in "$@"; do printf '%s\n' "$l" >> "$T/in"; done
}

# Hash every file and list every path under the fixture HOME: the I4 artifact set and more.
snapshot_stores() {
    SNAP=$(cd "$HOME_FIX" && { find . | sort; find . -type f -exec cksum {} + 2>/dev/null | sort; })
}
assert_stores_unchanged() {
    local after
    after=$(cd "$HOME_FIX" && { find . | sort; find . -type f -exec cksum {} + 2>/dev/null | sort; })
    check "no file under HOME changed" eq "$SNAP" "$after"
}

# ── the runner ──────────────────────────────────────────────────────────

# last_line <file>: the last non-blank line.
last_line() { grep -v '^[[:space:]]*$' "$1" | tail -n 1; }

expect_contract() {
    local n
    n=$(grep -cE '^(DONE|FIX):' "$T/out")
    check "contract: exactly one DONE or FIX line" eq "$n" 1
    case "$LAST" in
        DONE:*) check "contract: DONE exits 0" eq "$RC" 0 ;;
        FIX:*) check "contract: FIX exits 3" eq "$RC" 3 ;;
        *) check "contract: the last line is DONE or FIX" false ;;
    esac
}

expect_json_contract() {
    check "json contract: stdout is one JSON value" jq -e . "$T/out" > /dev/null 2>&1
    check "json contract: exit is 0 or 3" test "$RC" = 0 -o "$RC" = 3
    check "json contract: has parts and ok" jq -e 'has("parts") and has("ok")' "$T/out" > /dev/null 2>&1
    check "json contract: no DONE or FIX line on stdout" eq "$(grep -cE '^(DONE|FIX):' "$T/out")" 0
    check "json contract: a single object" eq "$(jq -s 'length' "$T/out" 2>/dev/null)" 1
}

RUN_SCRIPT=remote-setup.sh
RUN_ENV=""

run_sut() {
    local inj="" tty=1 root=0 contract=1 json=0 cwd=$ROOT without="" pbase=$PATH_BASE
    while [ $# -gt 0 ]; do
        case "$1" in
            --inject) inj="$inj $2"; shift 2 ;;
            --no-tty) tty=0; shift ;;
            --as-root) root=1; shift ;;
            --no-contract) contract=0; shift ;;
            --json) json=1; tty=0; shift ;;
            --cwd) cwd=$2; shift 2 ;;
            --without) without=$2; shift 2 ;;
            *) break ;;
        esac
    done
    local stdin=$1
    shift
    [ "$root" = 1 ] && : > "$T/id_root"
    if [ -n "$without" ]; then
        local d f n
        rm -rf "$T/pbin"
        mkdir -p "$T/pbin"
        for d in $(printf '%s' "$PATH_BASE" | tr ':' ' '); do
            for f in "$d"/*; do
                [ -x "$f" ] || continue
                n=${f##*/}
                [ "$n" = "$without" ] && continue
                [ -e "$T/pbin/$n" ] || ln -s "$f" "$T/pbin/$n"
            done
        done
        pbase=$T/pbin
    fi
    local envs
    envs=(env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID "HOME=$HOME_FIX" "PATH=$T/bin:$pbase" "RST=$T" "RST_REAL_BUN=$REAL_BUN" "TMPDIR=$T/tmp" TERM=dumb)
    local i
    for i in $inj $RUN_ENV; do envs[${#envs[@]}]=$i; done
    # the SUT runs under the same bash as this suite, so a 3.2 run of the suite is a 3.2 run of the SUT
    envs[${#envs[@]}]=$BASH
    envs[${#envs[@]}]=$ROOT/scripts/remote-setup/$RUN_SCRIPT
    for i in "$@"; do envs[${#envs[@]}]=$i; done
    : > "$T/out.raw"
    : > "$T/err"
    if [ "$tty" = 1 ]; then
        if [ "$(uname)" = Darwin ]; then
            (cd "$cwd" && script -q /dev/null "${envs[@]}" < "$stdin" > "$T/out.raw" 2> "$T/err")
        else
            (cd "$cwd" && script -qec "$(printf '%q ' "${envs[@]}")" /dev/null -E never < "$stdin" > "$T/out.raw" 2> "$T/err")
        fi
    else
        (cd "$cwd" && "${envs[@]}" < "$stdin" > "$T/out.raw" 2> "$T/err")
    fi
    RC=$?
    rm -f "$T/id_root"
    tr -d '\r' < "$T/out.raw" > "$T/out"
    LAST=$(last_line "$T/out")
    ERR=$(cat "$T/err")
    if [ "$contract" = 1 ]; then
        if [ "$json" = 1 ]; then expect_json_contract; else expect_contract; fi
    fi
}

run_drive() { # run_drive [run_sut options] <stdin-file> <lib function> [args]
    RUN_SCRIPT=testlib/drive.sh
    RUN_ENV="RS_LIB=$ROOT/scripts/remote-setup/lib.sh"
    run_sut "$@"
    RUN_SCRIPT=remote-setup.sh
    RUN_ENV=""
}

# ── cases: Task 1, the shared lib, the output contract and the harness ──

# Every writing subcommand refuses, exit 3 with a FIX, and writes nothing, whatever way the
# guard is tripped (I2). 4 subcommands x 4 ways = 16 cases, plus a positive control.
case_guard_matrix_every_writer() {
    local sub mode
    feed "$(mk_token 5000000001)"
    snapshot_stores
    for sub in bot away sudo peer; do
        for mode in claudecode session notty root; do
            case "$mode" in
                claudecode) run_sut --inject CLAUDECODE=1 "$T/in" "$sub" ;;
                session) run_sut --inject CLAUDE_CODE_SESSION_ID=x "$T/in" "$sub" ;;
                notty) run_sut --no-tty "$T/in" "$sub" ;;
                root) run_sut --as-root "$T/in" "$sub" ;;
            esac
            check "$sub/$mode: exit 3" eq "$RC" 3
            check "$sub/$mode: FIX line" starts "$LAST" "FIX:"
            check "$sub/$mode: names the guard, not a later step" lacks "$LAST" "later update"
            assert_stores_unchanged
        done
    done
    # positive control: with nothing tripped the guard stays quiet and the run goes on
    run_sut "$T/in" away
    check "control: the guard lets a clean terminal through" has "$LAST" "later update"
}

case_usage_exits_2() {
    run_sut --no-tty --no-contract "$T/in"
    check "no subcommand: exit 2" eq "$RC" 2
    check "no subcommand: usage line on stderr" has "$ERR" "usage:"
    run_sut --no-tty --no-contract "$T/in" frobnicate
    check "unknown subcommand: exit 2" eq "$RC" 2
    check "unknown subcommand: usage line on stderr" has "$ERR" "usage:"
    check "unknown subcommand: no DONE or FIX on stdout" eq "$(grep -cE '^(DONE|FIX):' "$T/out")" 0
}

case_usage_rows_every_subcommand() {
    local sub
    for sub in bot away sudo peer status; do
        run_sut --no-tty --no-contract "$T/in" "$sub" --bogus
        check "$sub --bogus: exit 2" eq "$RC" 2
        check "$sub --bogus: usage line on stderr" has "$ERR" "usage:"
        run_sut --no-tty --no-contract "$T/in" "$sub" stray
        check "$sub stray: exit 2" eq "$RC" 2
        check "$sub stray: usage line on stderr" has "$ERR" "usage:"
    done
}

# Subcommands whose rows are live. A later task adds its subcommand here when it builds it.
BUILT_SUBS="status"

case_contract_rows_every_subcommand() {
    local sub row
    for sub in bot away sudo peer status; do
        for row in success getme_failure network_failure preflight_miss; do
            case " $BUILT_SUBS " in
                *" $sub "*) contract_row "$sub" "$row" ;;
                *) SKIPN=$((SKIPN + 1)) ;;
            esac
        done
    done
}
# One contract row: a subcommand under one situation. run_sut itself checks the contract; a
# situation that cannot happen for a subcommand (status never calls Telegram) is a skip.
contract_row() {
    local sub=$1 row=$2
    rm -f "$T/himmelctl.fail" "$T/items.json" "$T/items.omit"
    case "$sub:$row" in
        status:success)
            all_green
            run_sut --no-tty "$T/in" status
            check "status success ends in DONE" starts "$LAST" "DONE:"
            ;;
        status:network_failure)
            echo 7 > "$T/himmelctl.fail"
            run_sut --no-tty "$T/in" status
            check "status with an unreadable himmelctl ends in FIX" starts "$LAST" "FIX:"
            ;;
        status:preflight_miss)
            run_sut --no-tty --without jq "$T/in" status
            check "status without jq ends in FIX" starts "$LAST" "FIX:"
            check "status without jq names jq" has "$LAST" "jq"
            ;;
        *) SKIPN=$((SKIPN + 1)) ;;
    esac
}

all_green() {
    set_item bridge-health green "@main_bot reachable, 1 poller"
    set_item bridge-persistence green "unit installed and enabled"
    set_item distinct-tokens green "tokens distinct"
}

case_curl_argv_is_exact() {
    local tok line n=0
    tok=$(mk_token 5000000002)
    run_drive --no-tty "$T/in" rs_getme
    : # run again with the token so a call really happens
    RUN_SCRIPT=testlib/drive.sh
    RUN_ENV="RS_LIB=$ROOT/scripts/remote-setup/lib.sh DRIVE_TOKEN=$tok"
    run_sut --no-tty "$T/in" rs_getme
    RUN_SCRIPT=remote-setup.sh
    RUN_ENV=""
    check "the call reached the curl shim" test -s "$T/curl.argv"
    while IFS= read -r line; do
        n=$((n + 1))
        check "curl argv line $n is exact" eq "$line" "-sS --max-time 15 -K -"
    done < "$T/curl.argv"
    check "the token is not in any argv" file_lacks "$T/curl.argv" "${tok#*:}"
    check "the token reached curl on stdin" file_has "$T/curl.stdin" "$tok"
}

case_getme_401_gives_revoked_fix() {
    printf '{"ok":false,"error_code":401,"description":"Unauthorized"}' > "$T/tg/getMe.json"
    local tok
    tok=$(mk_token 5000000003)
    RUN_SCRIPT=testlib/drive.sh
    RUN_ENV="RS_LIB=$ROOT/scripts/remote-setup/lib.sh DRIVE_TOKEN=$tok"
    run_sut --no-tty "$T/in" rs_getme
    RUN_SCRIPT=remote-setup.sh
    RUN_ENV=""
    check "exit 3" eq "$RC" 3
    check "says the token was revoked" has "$LAST" "the token was revoked"
    check "names @BotFather" has "$LAST" "@BotFather"
    check "no parse error leaks" lacks "$(cat "$T/out")" "parse error"
    check "the token is not in the output" lacks "$(cat "$T/out")" "${tok#*:}"
}

case_tg_429_waits_retry_after_once() {
    local tok
    tok=$(mk_token 5000000004)
    printf '{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":3}}' > "$T/tg/getMe.1.json"
    printf '{"ok":true,"result":{"id":5000000004,"username":"waited_bot"}}' > "$T/tg/getMe.2.json"
    RUN_SCRIPT=testlib/drive.sh
    RUN_ENV="RS_LIB=$ROOT/scripts/remote-setup/lib.sh DRIVE_TOKEN=$tok"
    run_sut --no-tty "$T/in" rs_getme
    check "a 429 then an ok answer succeeds" eq "$RC" 0
    check "it waited retry_after once" eq "$(grep -c '^sleep 3$' "$T/sleep.log")" 1
    check "it asked twice" eq "$(wc -l < "$T/curl.argv" | tr -d ' ')" 2
    # a second 429 is a FIX naming the wait, never a loop
    rm -f "$T/tg/getMe.n" "$T/tg/getMe.2.json" "$T/sleep.log" "$T/curl.argv"
    printf '{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":3}}' > "$T/tg/getMe.json"
    rm -f "$T/tg/getMe.1.json"
    run_sut --no-tty "$T/in" rs_getme
    RUN_SCRIPT=remote-setup.sh
    RUN_ENV=""
    check "two 429s end in a FIX" eq "$RC" 3
    check "the FIX names the wait" has "$LAST" "Telegram asked to wait 3 s"
    check "it waited once, not in a loop" eq "$(grep -c '^sleep ' "$T/sleep.log")" 1
}

case_outside_checkout_gives_cd_fix() {
    run_sut --cwd "$T" "$T/in" bot
    check "exit 3" eq "$RC" 3
    check "says to run it from the himmel folder" has "$LAST" "run this from your himmel folder: cd "
    check "names the folder" has "$LAST" "$ROOT"
    run_sut --cwd "$T" "$T/in" status
    check "status too" has "$LAST" "run this from your himmel folder: cd "
}

# ── cases: Task 4, the status aggregator ────────────────────────────────

part_field() { jq -r ".parts[$1].$2" "$T/out"; } # part_field <index 0-3> <field>

# A fixture whose lib ships one more item, so a part beyond part 1 is live.
ship_item() {
    sed "s/^RS_ITEMS_SHIPPED=\"\(.*\)\"/RS_ITEMS_SHIPPED=\"\1 $1\"/" "$HERE/lib.sh" > "$ROOT/scripts/remote-setup/lib.sh"
}

case_status_skips_unshipped_parts() {
    all_green
    run_sut --json "$T/in" status --json
    check "exit 0" eq "$RC" 0
    check "four parts" eq "$(jq '.parts | length' "$T/out")" 4
    check "part 1 ok" eq "$(part_field 0 state)" ok
    check "part 2 skipped" eq "$(part_field 1 state)" skipped
    check "part 3 skipped" eq "$(part_field 2 state)" skipped
    check "part 4 skipped" eq "$(part_field 3 state)" skipped
    check "a skipped part does not fail status" eq "$(jq -r .ok "$T/out")" true
    check "himmelctl was asked only for part 1's items" eq "$(grep '^status' "$T/himmelctl.calls")" "status --items bridge-health,bridge-persistence,distinct-tokens --json"
    # the shape of one part
    check "a part has name, detail, command, guide" eq "$(jq -r '.parts[0] | [has("name"), has("detail"), has("command"), has("guide")] | all' "$T/out")" true
    check "an ok part has no next command" eq "$(part_field 0 command)" null
}

case_status_na_counts_not_ok() {
    # nothing set up: every item n/a. n/a is not ok; skipped parts are not counted.
    run_sut --json "$T/in" status --json
    check "exit 3" eq "$RC" 3
    check "part 1 is not set" eq "$(part_field 0 state)" "not set"
    check "overall not ok" eq "$(jq -r .ok "$T/out")" false
    check "the next command is the bot helper" eq "$(part_field 0 command)" "bash scripts/remote-setup/remote-setup.sh bot"
    check "the guide link points at part 1" eq "$(part_field 0 guide)" "docs/setup/remote-setup.md#part-1"
    run_sut --no-tty "$T/in" status
    check "text mode: exit 3" eq "$RC" 3
    check "text mode: names the part and the command" has "$LAST" "part 1 (Main bot) is not set up. Run: bash scripts/remote-setup/remote-setup.sh bot"
    # one item red, the rest green: partial, and the FIX names the item
    all_green
    set_item bridge-health red "getMe refused"
    run_sut --json "$T/in" status --json
    check "partial" eq "$(part_field 0 state)" partial
    check "partial detail names the failing item" has "$(part_field 0 detail)" "bridge-health"
    check "partial still names the helper" eq "$(part_field 0 command)" "bash scripts/remote-setup/remote-setup.sh bot"
}

case_status_part_prereq_message() {
    ship_item remote-peer
    set_item remote-peer red "poller stopped"
    # part 1 not ok: part 4 says to do part 1 first and offers no command
    run_sut --json "$T/in" status --json
    check "part 4 is live" eq "$(part_field 3 state)" partial
    check "part 4 detail" eq "$(part_field 3 detail)" "do part 1 first"
    check "part 4 has no command" eq "$(part_field 3 command)" null
    check "himmelctl was asked for the peer item too" has "$(grep '^status' "$T/himmelctl.calls" | tail -n 1)" "remote-peer"
    # part 1 ok: part 4 offers its own command
    all_green
    run_sut --json "$T/in" status --json
    check "part 4 keeps its detail" has "$(part_field 3 detail)" "remote-peer"
    check "part 4 offers its command" eq "$(part_field 3 command)" "bash scripts/remote-setup/remote-setup.sh peer"
    check "a not-ok part fails the whole" eq "$(jq -r .ok "$T/out")" false
}

case_status_runs_under_claudecode() {
    all_green
    run_sut --no-tty --inject CLAUDECODE=1 "$T/in" status
    check "status is read-only and runs under CLAUDECODE" starts "$LAST" "DONE: status"
    check "no guard refusal" lacks "$(cat "$T/out")" "plain Terminal"
    run_sut --no-tty --inject CLAUDE_CODE_SESSION_ID=x "$T/in" status
    check "nor under a session id" starts "$LAST" "DONE: status"
}

case_status_json_is_single_object_on_success() {
    all_green
    run_sut --json "$T/in" status --json
    check "exit 0" eq "$RC" 0
    check "stdout is exactly one object" eq "$(jq -s 'length' "$T/out")" 1
    check "ok is true" eq "$(jq -r .ok "$T/out")" true
    check "the human header went to stderr" has "$ERR" "remote-setup status:"
    check "and not to stdout" lacks "$(cat "$T/out")" "remote-setup status:"
}

case_status_json_on_item_failure() {
    echo 7 > "$T/himmelctl.fail"
    run_sut --json "$T/in" status --json
    check "exit 3" eq "$RC" 3
    check "part 1 state is error" eq "$(part_field 0 state)" error
    check "part 1 carries the error" has "$(part_field 0 error)" "himmelctl"
    check "part 1 offers no command" eq "$(part_field 0 command)" null
    check "overall not ok" eq "$(jq -r .ok "$T/out")" false
    # an item missing from the answer is an error too
    rm -f "$T/himmelctl.fail"
    all_green
    echo "distinct-tokens" > "$T/items.omit"
    run_sut --json "$T/in" status --json
    check "a missing item: error" eq "$(part_field 0 state)" error
    check "a missing item: names it" has "$(part_field 0 error)" "distinct-tokens"
}

case_status_json_never_appends_done_line() {
    all_green
    run_sut --json "$T/in" status --json
    check "no DONE on stdout" eq "$(grep -c '^DONE:' "$T/out")" 0
    check "the DONE line is on stderr" has "$ERR" "DONE: status"
    rm -f "$T/items.json"
    run_sut --json "$T/in" status --json
    check "no FIX on stdout" eq "$(grep -c '^FIX:' "$T/out")" 0
    check "the FIX line is on stderr" has "$ERR" "FIX: part 1"
}

# Status computes nothing itself: with every source a direct reader could use made unreadable
# or absent, it still shows exactly what himmelctl says (I8).
case_status_reads_no_daemon_log_peers_json_or_mode() {
    local q=$HOME_FIX/handovers/bypass-queue d=$HOME_FIX/.config/himmel/peer-bridge
    mkdir -p "$q" "$d"
    : > "$q/daemon.log"
    : > "$q/mode"
    : > "$d/peers.json"
    chmod 000 "$q/daemon.log" "$q/mode" "$d/peers.json" "$d"
    set_item bridge-health green "ONLY-FROM-HIMMELCTL"
    set_item bridge-persistence green "p"
    set_item distinct-tokens green "t"
    run_sut --json "$T/in" status --json
    chmod 700 "$d"
    check "status still answers" eq "$RC" 0
    check "and shows himmelctl's words" has "$(part_field 0 detail)" "ONLY-FROM-HIMMELCTL"
    # a different answer from himmelctl moves the output, so the output is himmelctl's
    set_item bridge-health red "A-DIFFERENT-ANSWER"
    run_sut --json "$T/in" status --json
    check "a changed himmelctl answer changes the output" has "$(part_field 0 detail)" "A-DIFFERENT-ANSWER"
}

CASES="guard_matrix_every_writer usage_exits_2 usage_rows_every_subcommand contract_rows_every_subcommand
curl_argv_is_exact getme_401_gives_revoked_fix tg_429_waits_retry_after_once outside_checkout_gives_cd_fix
status_skips_unshipped_parts status_na_counts_not_ok status_part_prereq_message status_runs_under_claudecode
status_json_is_single_object_on_success status_json_on_item_failure status_json_never_appends_done_line
status_reads_no_daemon_log_peers_json_or_mode"

# ── run ─────────────────────────────────────────────────────────────────

main() {
    local c wanted=${1:-}
    for c in $CASES; do
        if [ -n "$wanted" ] && [ "$wanted" != "$c" ]; then continue; fi
        new_case "$c"
        "case_$c"
        if [ "$CASE_FAILS" = 0 ]; then
            PASS=$((PASS + 1))
            printf 'ok: %s\n' "$c"
        else
            FAILN=$((FAILN + 1))
            printf 'FAIL: %s (%s checks failed)\n' "$c" "$CASE_FAILS" >&2
        fi
    done
    printf '%s passed, %s failed, %s skipped\n' "$PASS" "$FAILN" "$SKIPN"
    [ "$FAILN" = 0 ]
}

main "$@"
