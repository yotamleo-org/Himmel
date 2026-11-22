#!/usr/bin/env bash
# test-remote-setup.sh: hermetic suite for scripts/remote-setup/.
#
# The SUT runs from a FIXTURE checkout (copies of lib.sh and remote-setup.sh, a stub
# himmelctl, the real himmelctl lib dir by symlink), with a fixture HOME and PATH shims for
# curl, systemctl, launchctl, sudo, sleep, date, uname, id and bun (scripts/remote-setup/tests/).
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
WATCHDOG_SECS=${RS_WATCHDOG_SECS:-1100}
WATCHDOG=""
trap 'exit 1' TERM
trap '[ -n "$WATCHDOG" ] && kill "$WATCHDOG" 2> /dev/null; rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P) || exit 1

watchdog() {
    local me sp tree
    me=$(exec sh -c 'echo $PPID')
    trap 'kill "$sp" 2> /dev/null; exit 0' TERM
    /bin/sleep "$WATCHDOG_SECS" &
    sp=$!
    wait "$sp"
    tree=$(ps -A -o pid= -o ppid= -o stat= -o etime= -o command= | awk -v root="$SUITE_PID" -v me="$me" '
        { line[$1] = $0; kids[$2] = kids[$2] " " $1 }
        function walk(p, d,   n, a, i) {
            if (p == me) return
            printf "%" (2 * d) "s%s\n", "", line[p]
            n = split(kids[p], a, " ")
            for (i = 1; i <= n; i++) walk(a[i], d + 1)
        }
        END { walk(root, 0) }')
    printf 'FAIL: watchdog: the suite ran %ss, stopping it in case %s. Process tree:\n%s\n' "$WATCHDOG_SECS" "$(cat "$WORK/current-case" 2> /dev/null)" "$tree" >&2
    kill -TERM "$SUITE_PID" 2> /dev/null
    printf '%s\n' "$tree" | awk -v root="$SUITE_PID" '$1 != root { print $1 }' | while read -r p; do kill -KILL "$p" 2> /dev/null; done
    exit 0
}
SUITE_PID=$$
watchdog &
WATCHDOG=$!
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
ended() { ! kill -0 "$1" 2> /dev/null; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
lacks() { case "$1" in *"$2"*) return 1 ;; esac; return 0; }
starts() { case "$1" in "$2"*) return 0 ;; esac; return 1; }
file_mode() { stat -c %a "$1" 2> /dev/null || stat -f %Lp "$1"; } # gnu-ok: GNU stat -c first, the BSD stat -f spelling on the same line
file_has() { grep -qF -- "$2" "$1" 2>/dev/null; }
file_lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null; }

# ── fixture ─────────────────────────────────────────────────────────────

new_case() {
    CASE=$1
    CASE_FAILS=0
    T=$WORK/$1
    mkdir -p "$T/home" "$T/tmp dir" "$T/bin" "$T/tg" "$T/units" "$T/root"
    cp "$HERE"/tests/shims/* "$T/bin/"
    echo Linux > "$T/uname"
    # a clock the sleep shim moves: a ten-minute wait ends in a few reads (see the date shim)
    date +%s > "$T/clock"
    echo 60 > "$T/clock.step"
    ROOT=$T/root
    HOME_FIX=$T/home
    mk_root
    set_getme 111 cand_bot
    : > "$T/in"
    RC=""
    LAST=""
}

mk_root() {
    mkdir -p "$ROOT/scripts/remote-setup/tests" "$ROOT/scripts/himmelctl" "$ROOT/scripts/telegram"
    cp "$HERE/lib.sh" "$HERE/remote-setup.sh" "$ROOT/scripts/remote-setup/"
    cp "$HERE/tests/drive.sh" "$ROOT/scripts/remote-setup/tests/"
    cp "$HERE/tests/himmelctl-stub.js" "$ROOT/scripts/himmelctl/bin.js"
    if [ -d "$REPO/scripts/himmelctl/lib" ]; then ln -s "$REPO/scripts/himmelctl/lib" "$ROOT/scripts/himmelctl/lib"; fi
    printf '// stub: the bun shim answers for onboard.ts\n' > "$ROOT/scripts/telegram/onboard.ts"
    cp "$HERE/tests/restart-bridge-stub.sh" "$ROOT/scripts/telegram/restart-bridge.sh"
    mkdir -p "$ROOT/scripts/lib"
    cp "$REPO/scripts/lib/prim.sh" "$ROOT/scripts/lib/prim.sh"
    mkdir -p "$ROOT/scripts/peer-bridge/units"
    cp "$REPO"/scripts/peer-bridge/units/* "$ROOT/scripts/peer-bridge/units/"
    printf '// stub: the bun shim answers for setup.ts\n' > "$ROOT/scripts/peer-bridge/setup.ts"
}

# A canary token: <id>:<35 url-safe chars>. Never a real credential.
mk_token() {
    printf '%s:CNRY%s' "$1" "$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9_-' | head -c 31)"
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
RUN_CAP=20
STALL_MAX=3
STALLS=0

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
    envs=(env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u TELEGRAM_ENV "HOME=$HOME_FIX" "PATH=$T/bin:$pbase" "RST=$T" "RST_REAL_BUN=$REAL_BUN" "TMPDIR=$T/tmp dir" TERM=dumb)
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
            rm -f "$T/noecho"
            (cd "$cwd" && { i=0; while [ ! -e "$T/noecho" ] && [ "$i" -lt $((RUN_CAP * 100)) ]; do /bin/sleep 0.01; i=$((i + 1)); done; cat "$stdin"; } \
                | perl -e 'alarm shift; exec @ARGV or exit 127' "$RUN_CAP" script -q /dev/null /bin/sh -c 'stty -echo && : > "$0" && exec "$@"' "$T/noecho" "${envs[@]}" > "$T/out.raw" 2> "$T/err") # read-sink-ok: the suite's own stdin file
        else
            (cd "$cwd" && perl -e 'alarm shift; exec @ARGV or exit 127' "$RUN_CAP" script -qec "$(printf '%q ' "${envs[@]}")" /dev/null -E never < "$stdin" > "$T/out.raw" 2> "$T/err") # read-sink-ok: the suite's own stdin file
        fi
    else
        (cd "$cwd" && "${envs[@]}" < "$stdin" > "$T/out.raw" 2> "$T/err") # read-sink-ok: the suite's own stdin file
    fi
    RC=$?
    rm -f "$T/id_root"
    tr -d '\r' < "$T/out.raw" > "$T/out"
    cat "$T/out" "$T/err" >> "$T/allout.log"
    LAST=$(last_line "$T/out")
    ERR=$(cat "$T/err")
    if [ "$tty" = 1 ] && [ "$RC" = 142 ]; then
        STALLS=$((STALLS + 1))
        check "the tty run ($*) ended within ${RUN_CAP}s" false
        if [ "$STALLS" -ge "$STALL_MAX" ]; then
            printf 'FAIL: %s tty runs did not end within %ss: stopping the suite\n' "$STALLS" "$RUN_CAP" >&2
            exit 1
        fi
    fi
    if [ "$contract" = 1 ]; then
        if [ "$json" = 1 ]; then expect_json_contract; else expect_contract; fi
    fi
}

run_drive() { # run_drive [run_sut options] <stdin-file> <lib function> [args]
    RUN_SCRIPT=tests/drive.sh
    RUN_ENV="RS_LIB=$ROOT/scripts/remote-setup/lib.sh"
    run_sut "$@"
    RUN_SCRIPT=remote-setup.sh
    RUN_ENV=""
}

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

case_mk_token_ends_when_tr_ignores_sigpipe() {
    local stub=$T/bsd-tr pid i
    mkdir -p "$stub"
    cat > "$stub/tr" << 'EOF'
#!/bin/sh
echo $$ > "$0.pid"
while IFS= read -r _l; do :; done
printf %s abcdefghijklmnopqrstuvwxyz0123456789
EOF
    chmod +x "$stub/tr"
    (
        trap '' PIPE
        PATH=$stub:$PATH
        mk_token 7 > "$T/tok"
    ) &
    pid=$!
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        kill -0 "$pid" 2> /dev/null || break
        /bin/sleep 0.5
    done
    check "mk_token ends within 10s when tr reads to EOF" ended "$pid"
    kill -KILL "$(cat "$stub/tr.pid" 2> /dev/null)" 2> /dev/null
    wait "$pid"
    check "mk_token keeps 31 chars of tr's output" eq "$(cat "$T/tok")" "7:CNRYabcdefghijklmnopqrstuvwxyz01234"
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

LIVE_SUBCOMMANDS="status bot peer"

case_contract_rows_every_subcommand() {
    local sub row
    for sub in bot away sudo peer status; do
        for row in success getme_failure network_failure preflight_miss; do
            case " $LIVE_SUBCOMMANDS " in
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
        bot:success)
            rm -rf "$HOME_FIX/.claude"
            seed_store "$(mk_token 111)"
            seed_access 777
            all_green
            set_getme 111 cand_bot
            feed ""
            run_sut "$T/in" bot
            check "bot success ends in DONE" starts "$LAST" "DONE:"
            ;;
        bot:getme_failure)
            printf '{"ok":false,"error_code":401,"description":"Unauthorized"}' > "$T/tg/getMe.json"
            feed "$(mk_token 111)"
            run_sut "$T/in" bot
            check "bot with a revoked token ends in FIX" starts "$LAST" "FIX:"
            set_getme 111 cand_bot
            ;;
        bot:network_failure)
            echo 6 > "$T/tg/getMe.curl_exit"
            feed "$(mk_token 111)"
            run_sut "$T/in" bot
            check "bot with no network ends in FIX" starts "$LAST" "FIX:"
            rm -f "$T/tg/getMe.curl_exit"
            ;;
        bot:preflight_miss)
            feed "$(mk_token 111)"
            run_sut --without jq "$T/in" bot
            check "bot without jq ends in FIX" starts "$LAST" "FIX:"
            check "bot without jq names jq" has "$LAST" "jq"
            ;;
        peer:success)
            seed_main
            set_getme "$OUR" bridge_bot
            set_group
            set_good_updates
            all_green
            feed "$(mk_token "$OUR")" 1
            run_sut "$T/in" peer
            check "peer success ends in DONE" starts "$LAST" "DONE:"
            ;;
        peer:getme_failure)
            seed_main
            printf '{"ok":false,"error_code":401,"description":"Unauthorized"}' > "$T/tg/getMe.json"
            feed "$(mk_token "$OUR")"
            run_sut "$T/in" peer
            check "peer with a revoked token ends in FIX" starts "$LAST" "FIX:"
            set_getme 111 cand_bot
            ;;
        peer:network_failure)
            seed_main
            echo 6 > "$T/tg/getMe.curl_exit"
            feed "$(mk_token "$OUR")"
            run_sut "$T/in" peer
            check "peer with no network ends in FIX" starts "$LAST" "FIX:"
            rm -f "$T/tg/getMe.curl_exit"
            ;;
        peer:preflight_miss)
            seed_main
            feed "$(mk_token "$OUR")"
            run_sut --without jq "$T/in" peer
            check "peer without jq ends in FIX" starts "$LAST" "FIX:"
            check "peer without jq names jq" has "$LAST" "jq"
            ;;
        *) SKIPN=$((SKIPN + 1)) ;;
    esac
}

all_green() {
    set_item bridge-health green "@main_bot reachable, 1 poller"
    set_item bridge-persistence green "unit installed and enabled"
    set_item distinct-tokens green "tokens distinct"
    set_item remote-peer green "example: set up, poller running"
}

case_curl_argv_is_exact() {
    local tok line n=0
    tok=$(mk_token 5000000002)
    run_drive --no-tty "$T/in" rs_getme
    : # run again with the token so a call really happens
    RUN_SCRIPT=tests/drive.sh
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
    RUN_SCRIPT=tests/drive.sh
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
    RUN_SCRIPT=tests/drive.sh
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
    check "part 4 is live since remote-peer ships" eq "$(part_field 3 state)" ok
    check "a skipped part does not fail status" eq "$(jq -r .ok "$T/out")" true
    check "himmelctl was asked only for the shipped parts' items" eq "$(grep '^status' "$T/himmelctl.calls")" "status --items bridge-health,bridge-persistence,distinct-tokens,remote-peer --json"
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
    set_item remote-peer red "poller stopped"
    # part 1 not ok: part 4 says to do part 1 first and offers no command
    run_sut --json "$T/in" status --json
    check "part 4 is live" eq "$(part_field 3 state)" partial
    check "part 4 detail" eq "$(part_field 3 detail)" "do part 1 first"
    check "part 4 has no command" eq "$(part_field 3 command)" null
    check "himmelctl was asked for the peer item too" has "$(grep '^status' "$T/himmelctl.calls" | tail -n 1)" "remote-peer"
    # part 1 ok: part 4 offers its own command
    all_green
    set_item remote-peer red "poller stopped"
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
    set_item remote-peer green "r"
    run_sut --json "$T/in" status --json
    chmod 700 "$d"
    check "status still answers" eq "$RC" 0
    check "and shows himmelctl's words" has "$(part_field 0 detail)" "ONLY-FROM-HIMMELCTL"
    # a different answer from himmelctl moves the output, so the output is himmelctl's
    set_item bridge-health red "A-DIFFERENT-ANSWER"
    run_sut --json "$T/in" status --json
    check "a changed himmelctl answer changes the output" has "$(part_field 0 detail)" "A-DIFFERENT-ANSWER"
}

CHANNEL_DIR() { printf '%s' "$HOME_FIX/.claude/channels/telegram"; }
STORE_FILE() { printf '%s' "$HOME_FIX/.claude/channels/telegram/.env"; }
ACCESS_FILE() { printf '%s' "$HOME_FIX/.claude/channels/telegram/access.json"; }
BOTS_FILE() { printf '%s' "$HOME_FIX/.himmel/remote-setup/bots.json"; }

seed_store() { # seed_store <token>: a main token already in the bridge store
    mkdir -p "$(CHANNEL_DIR)"
    printf 'TELEGRAM_BOT_TOKEN=%s\n' "$1" > "$(STORE_FILE)"
    chmod 600 "$(STORE_FILE)"
}
seed_access() { mkdir -p "$(CHANNEL_DIR)"; printf '{"allowFrom":["%s"]}\n' "$1" > "$(ACCESS_FILE)"; }
seed_bots() { mkdir -p "$HOME_FIX/.himmel/remote-setup"; printf '%s' "$1" > "$(BOTS_FILE)"; }

# What the bun shim answers for onboard.ts: the nonce line, then the offer for a private chat.
set_onboard() { # set_onboard <from-id> [label]
    {
        printf '[onboard] send this exact text to the bot (DM or an allowed group) to onboard: onboard-abcd1234\n'
        printf '[onboard] this only REPORTS chat/user ids; access.json is NOT written automatically.\n'
        printf '[onboard] chat.id=%s chat.type=private from.id=%s label=%s\n' "$1" "$1" "${2:-Ann Example}"
        printf '[onboard] done: copy the id(s) above into access.json yourself.\n'
    } > "$T/onboard.out"
}

onboard_calls() { [ -f "$T/onboard.calls" ] && wc -l < "$T/onboard.calls" | tr -d ' ' || echo 0; }
curl_methods() { sed -n 's#^url = ".*/bot[^/]*/\(.*\)"$#\1#p' "$T/curl.stdin" 2> /dev/null | sort | uniq -c | tr -s ' ' | tr '\n' ';'; }

# The line the FIX asks a chief to run, executed verbatim in the fixture HOME.
run_paste_line() {
    local line=${LAST#*run the same command again: }
    env HOME="$HOME_FIX" bash -c "$line"
}

# The secret half of a canary may appear only in the store, the stdin file the suite wrote, and
# the stdin config the curl shim recorded (in real use that config goes down a pipe).
assert_secret_only_in_store() { # assert_secret_only_in_store <token>
    local secret=${1#*:} leaks f
    leaks=""
    while IFS= read -r f; do
        case "$f" in
            "$T/in" | "$T/curl.stdin" | "$(STORE_FILE)") ;;
            *) leaks="$leaks $f" ;;
        esac
    done <<EOF
$(grep -rlF -- "$secret" "$T" 2> /dev/null)
EOF
    check "the token appears nowhere but the store (found in:$leaks)" eq "$leaks" ""
}

case_bot_red_bridge_id_as_main_refuses() {
    local tok
    tok=$(mk_token 111)
    seed_bots '{"bridge":{"id":"111","publishedAt":"2026-11-20T10:00:00Z"}}'
    set_getme 111 cand_bot
    feed "$tok"
    snapshot_stores
    run_sut "$T/in" bot
    check "exit 3" eq "$RC" 3
    check "says it is already the bridge bot" has "$LAST" "already your bridge bot"
    check "no pairing" eq "$(onboard_calls)" 0
    assert_stores_unchanged
}

case_bot_relay_id_as_main_refuses() {
    printf 'TELEGRAM_BOT_TOKEN=%s\n' "$(mk_token 444)" > "$ROOT/.env"
    set_getme 444 cand_bot
    feed "$(mk_token 444)"
    snapshot_stores
    run_sut "$T/in" bot
    check "exit 3" eq "$RC" 3
    check "says it is already the relay bot" has "$LAST" "already your relay bot"
    assert_stores_unchanged
}

case_bot_notice_id_as_main_refuses() {
    seed_bots '{"notice":{"id":"555","username":"notice_bot"}}'
    set_getme 555 cand_bot
    feed "$(mk_token 555)"
    snapshot_stores
    run_sut "$T/in" bot
    check "exit 3" eq "$RC" 3
    check "says it is already the notice bot" has "$LAST" "already your notice bot"
    assert_stores_unchanged
    # an id a half-finished setup step reserved counts as taken too
    seed_bots '{"notice":{"id":"555","username":"notice_bot","pending":true}}'
    snapshot_stores
    run_sut "$T/in" bot
    check "a pending id is refused" eq "$RC" 3
    assert_stores_unchanged
}

case_bot_different_id_without_replace_refuses() {
    local old new
    old=$(mk_token 111)
    new=$(mk_token 222)
    seed_store "$old"
    set_getme 222 other_bot
    feed "$new"
    snapshot_stores
    run_sut "$T/in" bot
    check "exit 3" eq "$RC" 3
    check "names --replace" has "$LAST" "--replace"
    assert_stores_unchanged
    # with --replace the different bot is accepted
    feed "$new"
    set_onboard 777
    run_sut "$T/in" bot --replace
    check "--replace stores the new bot" file_has "$(STORE_FILE)" "$new"
    check "--replace no longer holds the old one" file_lacks "$(STORE_FILE)" "$old"
}

case_bot_same_bot_new_token_is_stored() {
    local old new
    old=$(mk_token 111)
    new=$(mk_token 111)
    seed_store "$old"
    set_getme 111 cand_bot
    set_onboard 777
    feed "$new"
    run_sut "$T/in" bot
    check "a rotation does not need --replace" lacks "$LAST" "--replace"
    check "the new token is stored" file_has "$(STORE_FILE)" "$new"
    check "the old token is gone" file_lacks "$(STORE_FILE)" "$old"
    check "the store is private" eq "$(file_mode "$(STORE_FILE)")" 600
}

case_bot_same_token_skips_store() {
    local tok
    tok=$(mk_token 111)
    seed_store "$tok"
    touch -t 200001010000 "$(STORE_FILE)"
    touch "$T/ref"
    set_getme 111 cand_bot
    set_onboard 777
    feed "$tok"
    run_sut "$T/in" bot
    check "the same token string is not written again" test "$T/ref" -nt "$(STORE_FILE)"
    check "the token is still stored" file_has "$(STORE_FILE)" "$tok"
}

case_bot_post_write_check_that_cannot_run_is_a_fix() {
    local tok
    tok=$(mk_token 111)
    set_getme 111 cand_bot
    set_onboard 777
    echo 7 > "$T/himmelctl.fail"
    feed "$tok"
    run_sut "$T/in" bot
    check "a failing himmelctl is a FIX" eq "$RC" 3
    check "it says the check could not be made" has "$LAST" "could not be checked against your other bots"
    check "the saved token stays as a checkpoint" file_has "$(STORE_FILE)" "$tok"
    check "and nothing was paired" eq "$(onboard_calls)" 0
    rm -f "$T/himmelctl.fail"
    rm -rf "$HOME_FIX/.claude"
    echo "distinct-tokens" > "$T/items.omit"
    feed "$tok"
    run_sut "$T/in" bot
    check "an answer with no distinct-tokens row is a FIX too" has "$LAST" "could not be checked against your other bots"
    rm -f "$T/items.omit"
    rm -rf "$HOME_FIX/.claude"
    feed "$tok"
    run_sut "$T/in" bot
    check "and the same run goes on once himmelctl answers" eq "$(onboard_calls)" 1
}

case_bot_post_write_distinct_tokens_failure_restores_previous() {
    local old new
    old=$(mk_token 111)
    new=$(mk_token 111)
    seed_store "$old"
    set_item distinct-tokens degraded "the main bot and the bridge bot are the same bot"
    set_getme 111 cand_bot
    set_onboard 777
    feed "$new"
    snapshot_stores
    run_sut "$T/in" bot
    check "exit 3" eq "$RC" 3
    check "the FIX says the previous token was restored" has "$LAST" "restored"
    check "no pairing after the rollback" eq "$(onboard_calls)" 0
    assert_stores_unchanged
    rm -rf "$HOME_FIX/.claude"
    feed "$new"
    run_sut "$T/in" bot
    check "fresh: exit 3" eq "$RC" 3
    check "fresh: the token was removed again" file_lacks "$(STORE_FILE)" "${new#*:}"
}

# When the rollback write itself fails the FIX must say so, never "restored".
case_bot_post_write_restore_failure_is_not_reported_as_restored() {
    if [ "$(id -u)" = 0 ]; then SKIPN=$((SKIPN + 1)); return 0; fi # root ignores a read-only directory
    local old new
    old=$(mk_token 111)
    new=$(mk_token 111)
    seed_store "$old"
    set_item distinct-tokens degraded "the main bot and the bridge bot are the same bot"
    : > "$T/himmelctl.lockstore"
    set_getme 111 cand_bot
    set_onboard 777
    feed "$new"
    run_sut "$T/in" bot
    chmod 700 "$(CHANNEL_DIR)"
    check "exit 3" eq "$RC" 3
    check "it does not claim the previous token was restored" lacks "$LAST" "was restored"
    check "it says the previous token could not be put back" has "$LAST" "could NOT be put back"
    check "and the new token really is still saved" file_has "$(STORE_FILE)" "$new"
    # a fresh station: the same honesty when the new token cannot be removed
    rm -rf "$HOME_FIX/.claude"
    feed "$new"
    run_sut "$T/in" bot
    chmod 700 "$(CHANNEL_DIR)"
    check "fresh: it does not claim the token was removed" lacks "$LAST" "so it was removed"
    check "fresh: it says the token could not be removed" has "$LAST" "could NOT be removed again"
}

# A hand-edited store may quote the value; pressing Enter must reuse it without the quotes.
case_bot_enter_reuses_a_quoted_stored_token() {
    local tok
    tok=$(mk_token 111)
    mkdir -p "$(CHANNEL_DIR)"
    printf 'TELEGRAM_BOT_TOKEN="%s"\n' "$tok" > "$(STORE_FILE)"
    seed_access 777
    all_green
    feed ""
    run_sut "$T/in" bot
    check "the quoted token is reused" starts "$LAST" "DONE: bot"
    check "the quotes did not reach Telegram" file_has "$T/curl.stdin" "/bot$tok/getMe"
}

case_harness_ignores_a_telegram_env_from_the_launching_shell() {
    local tok decoy
    tok=$(mk_token 111)
    decoy=$T/decoy.env
    : > "$decoy"
    export TELEGRAM_ENV=$decoy
    set_onboard 777
    feed "$tok"
    run_sut "$T/in" bot
    unset TELEGRAM_ENV
    check "the canary went to the fixture store" file_has "$(STORE_FILE)" "$tok"
    check "and nothing reached the file the launching shell named" test ! -s "$decoy"
}

case_bot_run1_prints_paste_line_and_exits_3() {
    local tok
    tok=$(mk_token 111)
    set_onboard 777
    feed "$tok"
    run_sut "$T/in" bot
    check "exit 3" eq "$RC" 3
    check "the FIX asks the chief to create the allowlist" starts "$LAST" "FIX: have your chief create the allowlist with this line, then run the same command again: printf "
    check "the line holds the round-trip id" has "$LAST" '{"allowFrom":["777"]}'
    check "access.json stays absent" test ! -e "$(ACCESS_FILE)"
    check "the deep link was shown" file_has "$T/out" "https://t.me/cand_bot?start=onboard-abcd1234"
    check "one pairing" eq "$(onboard_calls)" 1
    check "the token is stored" file_has "$(STORE_FILE)" "$tok"
    check "the pairing label is shown" file_has "$T/out" "Ann Example"
    check "no onboarding temp file is left in a TMPDIR that has a space in it" eq "$(find "$T/tmp dir" -type f | wc -l | tr -d ' ')" 0
}

case_bot_run2_after_paste_reaches_done() {
    local tok
    tok=$(mk_token 111)
    set_onboard 777
    feed "$tok"
    run_sut "$T/in" bot
    check "run 1 is a FIX" eq "$RC" 3
    run_paste_line
    check "the printed line created access.json" file_has "$(ACCESS_FILE)" '"777"'
    all_green
    feed ""
    run_sut "$T/in" bot
    check "run 2 is DONE" eq "$RC" 0
    check "the DONE line" eq "$LAST" "DONE: bot — @cand_bot (id 111) reachable, bridge running, survives reboot"
    check "run 2 did not pair again" eq "$(onboard_calls)" 1
    check "run 2 enabled the bridge" file_has "$T/himmelctl.calls" "bridge enable"
}

case_bot_existing_access_json_other_id_fixes_unchanged() {
    seed_access 111
    local before
    before=$(cksum < "$(ACCESS_FILE)")
    set_getme 222 cand_bot
    set_onboard 777
    feed "$(mk_token 222)"
    run_sut "$T/in" bot
    check "exit 3" eq "$RC" 3
    check "says access.json lists another account" has "$LAST" "different Telegram account"
    check "access.json is unchanged" eq "$(cksum < "$(ACCESS_FILE)")" "$before"
    # the same id passes pairing: no paste line, straight on
    set_onboard 111
    all_green
    feed "$(mk_token 222)"
    run_sut "$T/in" bot
    check "the same id reaches DONE" starts "$LAST" "DONE: bot"
}

case_bot_existing_access_json_bad_shape_fixes_before_the_prompt() {
    mkdir -p "$(CHANNEL_DIR)"
    printf '{"allowFrom":["1","2"]}\n' > "$(ACCESS_FILE)"
    feed "$(mk_token 111)"
    snapshot_stores
    run_sut "$T/in" bot
    check "exit 3" eq "$RC" 3
    check "names access.json" has "$LAST" "access.json"
    check "no Telegram call" test ! -s "$T/curl.argv"
    assert_stores_unchanged
}

case_bot_rerun_without_token_never_pairs() {
    local tok
    tok=$(mk_token 111)
    seed_store "$tok"
    set_onboard 777
    feed ""
    run_sut "$T/in" bot
    check "no token and no access.json: a FIX" eq "$RC" 3
    check "it says to paste the token" has "$LAST" "paste"
    check "zero onboard calls" eq "$(onboard_calls)" 0
    check "no getUpdates in any recorded config" lacks "$(curl_methods)" "getUpdates"
    # with access.json in place the same Enter-only run finishes without pairing
    seed_access 777
    all_green
    feed ""
    run_sut "$T/in" bot
    check "access.json present: DONE" starts "$LAST" "DONE: bot"
    check "still zero onboard calls" eq "$(onboard_calls)" 0
    check "still no getUpdates" lacks "$(curl_methods)" "getUpdates"
    # positive control: pasting the token does pair, exactly once
    rm -f "$(ACCESS_FILE)"
    feed "$tok"
    run_sut "$T/in" bot
    check "with the token pasted: exactly one onboard call" eq "$(onboard_calls)" 1
}

case_bot_canary_token_absent_everywhere() {
    local tok
    tok=$(mk_token 111)
    printf '{"ok":false,"error_code":401,"description":"Unauthorized"}' > "$T/tg/getMe.json"
    feed "$tok"
    run_sut "$T/in" bot
    check "a revoked token is a FIX" eq "$RC" 3
    # then the two-run path
    set_getme 111 cand_bot
    set_onboard 777
    feed "$tok"
    run_sut "$T/in" bot
    check "run 1 is a FIX" eq "$RC" 3
    run_paste_line
    all_green
    feed ""
    run_sut "$T/in" bot
    check "run 2 is DONE" eq "$RC" 0
    check "the token is in the store" file_has "$(STORE_FILE)" "$tok"
    assert_secret_only_in_store "$tok"
    check "the canary is not in the curl argv" file_lacks "$T/curl.argv" "${tok#*:}"
    check "the canary is not in any output of any run" file_lacks "$T/allout.log" "${tok#*:}"
}

case_bot_done_rerun_changes_no_config_artifact() {
    local tok
    tok=$(mk_token 111)
    seed_store "$tok"
    seed_access 777
    all_green
    set_getme 111 cand_bot
    feed ""
    run_sut "$T/in" bot
    check "first run: DONE" eq "$RC" 0
    snapshot_stores
    feed ""
    run_sut "$T/in" bot
    check "second run: DONE" eq "$RC" 0
    assert_stores_unchanged
    snapshot_stores
    set_onboard 777
    feed "$tok"
    run_sut "$T/in" bot
    check "same token pasted: DONE" eq "$RC" 0
    assert_stores_unchanged
}

case_bot_inputs_are_only_the_g2_set() {
    local tok body
    tok=$(mk_token 111)
    set_onboard 777
    feed "$tok" "EXTRA-LINE-NOBODY-ASKED-FOR"
    run_sut "$T/in" bot
    check "exactly one prompt in the whole run" eq "$(grep -c 'Paste the bot token' "$T/out")" 1
    # structural: the token prompt is the only place the part reads the keyboard
    body=$(sed -n '/^cmd_bot()/,/^}/p' "$HERE/remote-setup.sh")
    check "cmd_bot has a body to read" test -n "$body"
    check "cmd_bot reads input only through rs_secret" eq "$(printf '%s\n' "$body" | grep -cE '(^|[[:space:];|&(])read -')" 0
    check "cmd_bot calls rs_secret once" eq "$(printf '%s\n' "$body" | grep -c 'rs_secret ')" 1
}

case_bot_sigint_during_onboard_restarts_unit() {
    : > "$T/units/telegram-bridge.service.active"
    : > "$T/onboard.hang"
    set_onboard 777
    feed "$(mk_token 111)"
    run_sut "$T/in" bot
    check "exit 3" eq "$RC" 3
    check "says it was interrupted" has "$LAST" "interrupted"
    check "the unit is active again" test -f "$T/units/telegram-bridge.service.active"
    local stop start
    stop=$(grep -n 'systemctl --user stop telegram-bridge.service' "$T/units.log" | head -n 1 | cut -d: -f1)
    start=$(grep -n 'systemctl --user start telegram-bridge.service' "$T/units.log" | tail -n 1 | cut -d: -f1)
    check "it was stopped" test -n "$stop"
    check "and started after the stop" test "${start:-0}" -gt "${stop:-0}"
    check "the onboard process was recorded" test -s "$T/onboard.pid"
    check "and it is gone" eq "$(kill -0 "$(cat "$T/onboard.pid")" 2> /dev/null && echo alive || echo gone)" gone
}

case_bot_mac_bootout_before_onboard() {
    echo Darwin > "$T/uname"
    : > "$T/units/com.himmel.telegram-bridge.loaded"
    set_onboard 777
    feed "$(mk_token 111)"
    run_sut "$T/in" bot
    local out boot ob
    out=$(grep -n 'launchctl bootout' "$T/units.log" | head -n 1 | cut -d: -f1)
    ob=$(grep -n '^onboard ' "$T/units.log" | head -n 1 | cut -d: -f1)
    boot=$(grep -n 'launchctl bootstrap' "$T/units.log" | tail -n 1 | cut -d: -f1)
    check "bootout was called" test -n "$out"
    check "bootout comes before onboard" test "${out:-99}" -lt "${ob:-0}"
    check "bootstrap comes after onboard" test "${boot:-0}" -gt "${ob:-99}"
    check "the agent is loaded again" test -f "$T/units/com.himmel.telegram-bridge.loaded"
    check "no systemctl on a Mac" lacks "$(cat "$T/units.log")" "systemctl"
}

# A bridge started by hand (no unit) is stopped through the launcher for pairing, and started again.
case_bot_pairing_stops_a_bridge_that_runs_without_a_unit() {
    : > "$T/restart-bridge.running"
    set_onboard 777
    feed "$(mk_token 111)"
    run_sut "$T/in" bot
    check "the launcher was asked for its status" file_has "$T/restart-bridge.log" "restart-bridge status"
    check "then told to stop" file_has "$T/restart-bridge.log" "restart-bridge stop"
    check "then told to start again" file_has "$T/restart-bridge.log" "restart-bridge start"
    local stop start
    stop=$(grep -n 'restart-bridge stop' "$T/restart-bridge.log" | head -n 1 | cut -d: -f1)
    start=$(grep -n 'restart-bridge start' "$T/restart-bridge.log" | tail -n 1 | cut -d: -f1)
    check "stop comes before start" test "${stop:-99}" -lt "${start:-0}"
    check "the bridge is running again" test -f "$T/restart-bridge.running"
    check "no unit command was needed" lacks "$(cat "$T/units.log" 2> /dev/null)" "systemctl --user stop"
}

case_token_with_trailing_space_is_trimmed() {
    local tok
    tok=$(mk_token 111)
    set_onboard 777
    feed "$(printf '  %s \r' "$tok")"
    run_sut "$T/in" bot
    check "it is not rejected as a bad token" lacks "$LAST" "not a bot token"
    check "it paired" eq "$(onboard_calls)" 1
    check "the trimmed token is what was stored" file_has "$(STORE_FILE)" "TELEGRAM_BOT_TOKEN=$tok"
    check "and nothing else was stored with it" eq "$(grep -c 'TELEGRAM_BOT_TOKEN=' "$(STORE_FILE)")" 1
    # a real mistake still gets a plain message, never an echo of what was typed
    feed "this is not a token"
    run_sut "$T/in" bot
    check "a non-token is a FIX" starts "$LAST" "FIX:"
    check "that says what to paste" has "$LAST" "not a bot token"
    check "and does not echo it" lacks "$(cat "$T/out")" "this is not a token"
}

case_curl_exit_6_restarts_unit_and_fixes() {
    local tok
    tok=$(mk_token 111)
    : > "$T/units/telegram-bridge.service.active"
    echo 6 > "$T/tg/getMe.curl_exit"
    feed "$tok"
    run_sut "$T/in" bot
    check "exit 3" eq "$RC" 3
    check "says it cannot reach Telegram" has "$LAST" "can't reach api.telegram.org"
    check "the unit is still active" test -f "$T/units/telegram-bridge.service.active"
    check "nothing was stored" test ! -e "$(STORE_FILE)"
    # onboarding that dies while the bridge is stopped: the bridge comes back
    rm -f "$T/tg/getMe.curl_exit"
    printf '[onboard] getUpdates failed: network down\n' > "$T/onboard.out"
    echo 1 > "$T/onboard.rc"
    feed "$tok"
    run_sut "$T/in" bot
    check "a failed onboarding is a FIX" eq "$RC" 3
    check "the unit is active again" test -f "$T/units/telegram-bridge.service.active"
    check "it was stopped and started" eq "$(grep -cE 'systemctl --user (stop|start) telegram-bridge.service' "$T/units.log")" 2
}

# The onboard.ts offer grammar: the real producer, then every way it can be malformed or forged.
parse() { # parse <file>
    run_drive --no-tty --no-contract "$T/in" drive_parse "$1"
    PARSED=$(grep '^parse ' "$T/out")
}

case_onboard_parse_real_producer() {
    local line
    if [ ! -x "$REAL_BUN" ]; then SKIPN=$((SKIPN + 1)); return 0; fi
    line=$("$REAL_BUN" -e 'import { formatOffer } from "'"$REPO"'/scripts/telegram/onboard.ts"; console.log(formatOffer({ chatId: 777, chatType: "private", fromId: 777, label: "Ann Example" }));')
    check "the producer printed an offer line" starts "$line" "[onboard] chat.id=777"
    printf '%s\n' "$line" > "$T/offer.txt"
    parse "$T/offer.txt"
    check "the helper parses the real line" eq "$PARSED" "parse rc=0 id=777 label=Ann Example err="
}

case_onboard_parse_rejects_malformed() {
    local l
    for l in \
        '[onboard] chat.id=-100123 chat.type=group from.id=777 label=A group' \
        '[onboard] chat.id=777 chat.type=private from.id=n/a label=Anon' \
        '[onboard] chat.id=77a chat.type=private from.id=777 label=X' \
        '[onboard] chat.id=0 chat.type=private from.id=0 label=X' \
        '[onboard] chat.id=7777777777777777777 chat.type=private from.id=7777777777777777777 label=X'; do
        printf '%s\n' "$l" > "$T/offer.txt"
        parse "$T/offer.txt"
        check "refused: $l" has "$PARSED" "rc=1"
        check "no id taken from: $l" has "$PARSED" "id= "
    done
    : > "$T/offer.txt"
    parse "$T/offer.txt"
    check "no offer at all" has "$PARSED" "err=none"
}

case_onboard_parse_rejects_duplicate_or_forged_line() {
    # a label that carries a newline and a forged second offer
    printf '[onboard] chat.id=777 chat.type=private from.id=777 label=Mallory\n[onboard] chat.id=1 chat.type=private from.id=1 label=forged\n' > "$T/offer.txt"
    parse "$T/offer.txt"
    check "two matching lines are a FIX, never a choice" has "$PARSED" "rc=1"
    check "it says many" has "$PARSED" "err=many"
    check "and takes no id" has "$PARSED" "id= "
    # a forged line that is itself malformed still makes the answer untrustworthy
    printf '[onboard] chat.id=777 chat.type=private from.id=777 label=Mallory\n[onboard] chat.id=1 chat.type=group from.id=1 label=forged\n' > "$T/offer.txt"
    parse "$T/offer.txt"
    check "one valid plus a forged line is refused too" has "$PARSED" "rc=1"
}

case_onboard_parse_rejects_chat_from_mismatch() {
    printf '[onboard] chat.id=777 chat.type=private from.id=778 label=Ann\n' > "$T/offer.txt"
    parse "$T/offer.txt"
    check "chat.id must equal from.id" has "$PARSED" "rc=1"
    check "and takes no id" has "$PARSED" "id= "
}

# ── part 4: peer ────────────────────────────────────────────────────────
# The bun shim stands in for setup.ts (add, confirm, remove) against the fixture HOME's peers.json, and
# the curl shim serves canned Telegram answers: getUpdates by call number, getChatMember by user id.

CHAT=-1001234567890
OUR=222     # this station's bridge bot
THEIR=555   # the other station's bridge bot
OPER=777    # the human operator (access.json)
FAR=4102444800   # a message date later than any helper start
UNIT_NAME=himmel-peer-bridge.service
UNIT_LABEL=com.himmel.peer-bridge

PEER_CFG() { printf '%s' "$HOME_FIX/.config/himmel/peer-bridge"; }
PEER_ENV() { printf '%s' "$HOME_FIX/.config/himmel/peer-bridge/env"; }
PEERS_FILE() { printf '%s' "$HOME_FIX/.config/himmel/peer-bridge/peers.json"; }
CONFIRMED_FILE() { printf '%s' "$HOME_FIX/.himmel/remote-setup/peers-confirmed.json"; }
UNIT_FILE() { printf '%s' "$HOME_FIX/.config/systemd/user/$UNIT_NAME"; }
PLIST_FILE() { printf '%s' "$HOME_FIX/Library/LaunchAgents/$UNIT_LABEL.plist"; }

upd_mcm() { # <update_id> <chat> <type> <title> <status> <bot id>: a my_chat_member update about a bot
    jq -nc --argjson u "$1" --argjson c "$2" --arg ty "$3" --arg ti "$4" --arg st "$5" --argjson b "$6" \
        '{update_id: $u, my_chat_member: {chat: {id: $c, type: $ty, title: $ti}, date: 1, new_chat_member: {status: $st, user: {id: $b, is_bot: true}}}}'
}
upd_hello() { # <update_id> <chat> <date> [type] [title]: the human sends the word hello
    jq -nc --argjson u "$1" --argjson c "$2" --argjson d "$3" --arg ty "${4:-supergroup}" --arg ti "${5:-bridge}" \
        '{update_id: $u, message: {message_id: $u, date: $d, chat: {id: $c, type: $ty, title: $ti}, from: {id: 777, is_bot: false}, text: "hello"}}'
}
upd_peer_hello() { # <update_id> <chat> <bot id> <username>: the other station's bot posts its hello
    jq -nc --argjson u "$1" --argjson c "$2" --argjson b "$3" --arg un "$4" \
        '{update_id: $u, message: {message_id: $u, date: 1, chat: {id: $c, type: "supergroup", title: "bridge"}, from: {id: $b, is_bot: true, username: $un}, text: "himmel peer hello"}}'
}
noise_updates() { # <from id> <to id>: unrelated chatter
    jq -nc --argjson a "$1" --argjson b "$2" \
        '[range($a; $b + 1)] | map({update_id: ., message: {message_id: ., date: 1, chat: {id: -5, type: "supergroup", title: "other"}, from: {id: 9, is_bot: false}, text: "hi"}})'
}
set_updates() { # <file under tg/> <update json>...
    local f=$1 sep="" out="[" x
    shift
    for x in "$@"; do
        out="$out$sep$x"
        sep=","
    done
    printf '{"ok":true,"result":%s]}' "$out" > "$T/tg/$f"
}
set_member() { # <bot id> <status> [extra json merged into the answer]
    local extra=${3:-}
    [ -n "$extra" ] || extra='{}'
    jq -nc --argjson id "$1" --arg st "$2" --argjson extra "$extra" \
        '{ok: true, result: ({status: $st, user: {id: $id, is_bot: true}, is_anonymous: false, can_be_edited: false, can_manage_chat: true,
          can_delete_messages: false, can_manage_video_chats: false, can_restrict_members: false, can_promote_members: false,
          can_change_info: false, can_invite_users: false, can_post_stories: false, can_edit_stories: false, can_delete_stories: false,
          can_pin_messages: false, can_manage_topics: false} + $extra)}' > "$T/tg/getChatMember.u$1.json"
}
set_group() { # a good group: a supergroup, members cannot change info or pin, both bridge bots admins with every right off, the operator is the owner
    printf '{"ok":true,"result":{"id":%s,"type":"supergroup","title":"bridge","permissions":{"can_send_messages":true,"can_invite_users":true,"can_change_info":false,"can_pin_messages":false}}}' "${1:-$CHAT}" > "$T/tg/getChat.json"
    set_member "$OUR" administrator
    set_member "$THEIR" administrator
    printf '{"ok":true,"result":{"status":"creator","user":{"id":%s,"is_bot":false}}}' "$OPER" > "$T/tg/getChatMember.u$OPER.json"
    printf '{"ok":true,"result":{"message_id":9}}' > "$T/tg/sendMessage.json"
}

seed_main() { seed_store "$(mk_token 111)"; seed_access "$OPER"; }
seed_peer_env() { # the bridge token a station stored earlier
    BTOK=$(mk_token "$OUR")
    mkdir -p "$(PEER_CFG)"
    chmod 700 "$(PEER_CFG)"
    printf 'PEER_BOT_TOKEN=%s\n' "$BTOK" > "$(PEER_ENV)"
    chmod 600 "$(PEER_ENV)"
}
seed_peers_json() { # <name> <peer bot id> <chat id or null>: what setup.ts add / confirm left behind
    mkdir -p "$(PEER_CFG)"
    jq -nc --arg n "$1" --arg b "$2" --argjson c "$3" \
        '{operatorBotId: "111", operatorChatId: 777, bridgeRoot: "/x", himmelRoot: "/y", peers: {($n): {peerBotId: $b, chatId: $c, allowFrom: [$b], theirs: {username: "old_bot"}}}, maxTextChars: 4000, addressing: "command"}' > "$(PEERS_FILE)"
    chmod 600 "$(PEERS_FILE)"
}
seed_checkpoint() { # <name> <peer bot id> <chat id>
    mkdir -p "$HOME_FIX/.himmel/remote-setup"
    jq -nc --arg n "$1" --arg b "$2" --argjson c "$3" '{peers: [{name: $n, peerBotId: $b, chatId: $c, confirmedAt: "2026-11-20T10:00:00Z"}]}' > "$(CONFIRMED_FILE)"
    chmod 600 "$(CONFIRMED_FILE)"
}
render_unit_into() { # <dest> [linux|mac]: the unit as the helper renders it
    local c
    mkdir -p "$(dirname "$1")"
    if [ "${2:-linux}" = mac ]; then c=$(cat "$ROOT/scripts/peer-bridge/units/$UNIT_LABEL.plist"); else c=$(cat "$ROOT/scripts/peer-bridge/units/$UNIT_NAME"); fi
    c=${c//@HIMMEL_ROOT@/$ROOT}
    c=${c//@HOME@/$HOME_FIX}
    printf '%s\n' "$c" > "$1"
}
seed_unit() { # [linux|mac]: the poller unit installed and running
    if [ "${1:-linux}" = mac ]; then
        render_unit_into "$(PLIST_FILE)" mac
        : > "$T/units/$UNIT_LABEL.loaded"
    else
        render_unit_into "$(UNIT_FILE)"
        : > "$T/units/$UNIT_NAME.active"
        : > "$T/units/$UNIT_NAME.enabled"
    fi
}
seed_confirmed_station() { # [linux|mac]
    seed_main
    seed_peer_env
    seed_bots "{\"bridge\":{\"id\":\"$OUR\",\"publishedAt\":\"2026-11-20T10:00:00Z\"}}"
    seed_peers_json example "$THEIR" "$CHAT"
    seed_checkpoint example "$THEIR" "$CHAT"
    seed_unit "${1:-linux}"
    set_getme "$OUR" bridge_bot
    set_group
    all_green
}
# A discovery that ends well: the operator's hello and the other bot's hello are waiting.
set_good_updates() { set_updates getUpdates.json "$(upd_hello 101 "$CHAT" "$FAR")" "$(upd_peer_hello 102 "$CHAT" "$THEIR" example_bot)"; }

# a fresh fixture for a second scenario inside one case, keeping the failures counted so far
sub_case() { local keep=$CASE_FAILS; new_case "$1"; CASE_FAILS=$keep; }
sent_count() { local n; n=$(grep -c '/sendMessage"$' "$T/curl.stdin" 2> /dev/null); echo "${n:-0}"; }
method_count() { local n; n=$(grep -c "/$1\"\$" "$T/curl.stdin" 2> /dev/null); echo "${n:-0}"; }
setup_calls() { if [ -f "$T/setup.calls" ]; then cat "$T/setup.calls"; fi; }
line_of() { grep -n -- "$1" "$T/units.log" | head -n 1 | cut -d: -f1; }
last_line_of() { grep -n -- "$1" "$T/units.log" | tail -n 1 | cut -d: -f1; }
sent_chat() { awk '/\/sendMessage"$/ {f = 1; next} f && /^data =/ {print; f = 0}' "$T/curl.stdin" | sed -n 's/.*chat_id\\":\(-[0-9]*\),.*/\1/p' | tail -n 1; }

case_peer_fresh_fresh_discovers_via_hello() {
    local tok
    tok=$(mk_token "$OUR")
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_good_updates
    all_green
    feed "$tok" 1
    run_sut "$T/in" peer
    check "exit 0" eq "$RC" 0
    check "the DONE line names the peer" eq "$LAST" "DONE: peer example — group confirmed, poller running"
    check "setup.ts add got every id from discovery" has "$(setup_calls)" "add example --peer-bot-id $THEIR --peer-username example_bot --operator-bot-id 111"
    check "setup.ts confirm got the group" has "$(setup_calls)" "confirm example $CHAT"
    check "the bridge token is stored as one line" eq "$(cat "$(PEER_ENV)")" "PEER_BOT_TOKEN=$tok"
    check "owner-only token file" eq "$(file_mode "$(PEER_ENV)")" 600
    check "the bridge bot id is published" eq "$(jq -r '.bridge.id' "$(BOTS_FILE)")" "$OUR"
    check "and is no longer pending" eq "$(jq -r '.bridge.pending // false' "$(BOTS_FILE)")" false
    check "the checkpoint holds the peer" eq "$(jq -r '.peers[0] | "\(.name) \(.peerBotId) \(.chatId)"' "$(CONFIRMED_FILE)")" "example $THEIR $CHAT"
    check "exactly one hello was posted" eq "$(sent_count)" 1
    check "the hello is the fixed plain line" file_has "$T/curl.stdin" 'himmel peer hello'
    check "it went to the discovered group" eq "$(sent_chat)" "$CHAT"
    check "the unit file is installed" test -f "$(UNIT_FILE)"
    check "the unit is started" test -f "$T/units/$UNIT_NAME.active"
    check "and enabled, so it survives a reboot" test -f "$T/units/$UNIT_NAME.enabled"
}

case_peer_confirmed_side_posts_hello_without_waiting() {
    seed_confirmed_station
    feed ""
    run_sut "$T/in" peer
    check "exit 0" eq "$RC" 0
    check "DONE names the peer" eq "$LAST" "DONE: peer example — group confirmed, poller running"
    check "one hello" eq "$(sent_count)" 1
    check "to the recorded group" eq "$(sent_chat)" "$CHAT"
    check "no getUpdates at all" eq "$(method_count getUpdates)" 0
    check "the poller was never stopped" lacks "$(cat "$T/units.log")" "systemctl --user stop"
    check "and nothing was added or confirmed again" eq "$(setup_calls)" ""
}

case_peer_unconfirmed_pages_101_backlog() {
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    all_green
    printf '{"ok":true,"result":%s}' "$(noise_updates 1 100)" > "$T/tg/getUpdates.1.json"
    set_updates getUpdates.2.json "$(upd_hello 101 "$CHAT" "$FAR")" "$(upd_peer_hello 102 "$CHAT" "$THEIR" example_bot)"
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "the hello behind 100 other messages is found" eq "$RC" 0
    check "the second read acknowledged the first 100" file_has "$T/curl.stdin" '\"offset\":101'
    check "the peer was added" has "$(setup_calls)" "add example"
}

case_peer_confirmed_repoint_backlog_full_gives_fix_and_restarts_poller() {
    seed_confirmed_station
    printf '{"ok":true,"result":%s}' "$(noise_updates 1 100)" > "$T/tg/getUpdates.json"
    feed "" ""
    run_sut "$T/in" peer --replace
    check "exit 3" eq "$RC" 3
    check "says too many messages are queued" has "$LAST" "too many queued messages"
    check "asks the other operator to run it once" has "$LAST" "ask the other operator to run the same command once more"
    check "the poller is running again" test -f "$T/units/$UNIT_NAME.active"
    check "it was stopped first" test -n "$(line_of 'systemctl --user stop himmel-peer-bridge.service')"
    check "and started after" test "$(last_line_of 'systemctl --user start himmel-peer-bridge.service')" -gt "$(line_of 'systemctl --user stop himmel-peer-bridge.service')"
    check "nothing was acknowledged" file_lacks "$T/curl.stdin" 'offset'
    check "no hello was posted" eq "$(sent_count)" 0
}

case_peer_no_offset_ack_on_confirmed_side() {
    seed_confirmed_station
    # a full batch of exactly 100 whose last two updates are the hellos: a side that paged would ask again
    # with an offset; the confirmed side reads once and acknowledges nothing
    printf '{"ok":true,"result":%s}' "$(jq -nc --argjson n "$(noise_updates 1 98)" --argjson a "$(upd_hello 99 "$CHAT" "$FAR")" --argjson b "$(upd_peer_hello 100 "$CHAT" "$THEIR" example_bot)" '$n + [$a, $b]')" > "$T/tg/getUpdates.json"
    feed "" "" 1
    run_sut "$T/in" peer --replace
    check "exit 0" eq "$RC" 0
    check "it read the updates" test "$(method_count getUpdates)" -ge 1
    check "and acknowledged none of them" file_lacks "$T/curl.stdin" 'offset'
    check "the poller ran again" test -f "$T/units/$UNIT_NAME.active"
    sub_case peer_no_offset_ack_control
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    all_green
    printf '{"ok":true,"result":%s}' "$(noise_updates 1 100)" > "$T/tg/getUpdates.1.json"
    set_updates getUpdates.2.json "$(upd_hello 101 "$CHAT" "$FAR")" "$(upd_peer_hello 102 "$CHAT" "$THEIR" example_bot)"
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "control: the unconfirmed side pages with an offset" file_has "$T/curl.stdin" 'offset'
}

# The real gate (not a copy) drops the plain hello line at rule 6, counts nothing against the rate window,
# and its drop log never carries the text.
case_peer_gate_drops_plain_hello_real_gate() {
    if [ ! -x "$REAL_BUN" ]; then SKIPN=$((SKIPN + 1)); return 0; fi
    cat > "$T/gate-probe.ts" <<EOF
import { admit, createGateState } from "$REPO/scripts/peer-bridge/gate";
const PEER_ID = "555000111", CHAT = -1001234567890;
const caps = { opens: ["question", "status", "info"], maxOpenThreads: 5, maxPerMinute: 10, maxReaderRunsPerDay: 50, maxReaderRunsPerKindPerDay: { question: 30, status: 10, info: 10 }, maxWakesPerDay: 30 };
const cfg: any = { maxTextChars: 4000, peers: { example: { peerBotId: PEER_ID, chatId: CHAT, allowFrom: [PEER_ID], ...caps, theirs: { username: "example_bot", ...caps, copiedAt: "2026-11-20" } } } };
const msg = (text: string, id: number) => ({ update_id: id, message: { message_id: id, from: { id: Number(PEER_ID), is_bot: true, username: "example_bot" }, chat: { id: CHAT, type: "supergroup", title: "bridge" }, date: 1731000000, text } });
const state = createGateState({ ourBotId: "111000111", ourUsername: "ours_bot", committed: 0, now: 1731000000000 });
const hello: any = admit(msg("himmel peer hello", 5), cfg, state);
const control: any = admit(msg("/peer@ours_bot\n#ask:question id=a1b2c3d4\nhow do I x?", 6), cfg, createGateState({ ourBotId: "111000111", ourUsername: "ours_bot", committed: 0, now: 1731000000000 }));
console.log(JSON.stringify({ helloOk: hello.ok, rule: hello.rule, log: hello.log, rateSize: state.rate.size, controlOk: control.ok }));
EOF
    local out
    out=$("$REAL_BUN" "$T/gate-probe.ts" 2> "$T/gate.err")
    check "the real gate ran" eq "$(printf '%s' "$out" | jq -r '.controlOk' 2> /dev/null)" true
    check "the plain hello is dropped" eq "$(printf '%s' "$out" | jq -r '.helloOk')" false
    check "at rule 6" eq "$(printf '%s' "$out" | jq -r '.rule')" 6
    check "the rate window is unchanged" eq "$(printf '%s' "$out" | jq -r '.rateSize')" 0
    check "the drop log does not carry the text" lacks "$(printf '%s' "$out" | jq -r '.log')" "himmel peer hello"
}

case_peer_check_group_unknown_right_names_raw_field() {
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_member "$THEIR" administrator '{"can_manage_tags":true}'
    set_good_updates
    all_green
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "exit 3" eq "$RC" 3
    check "the FIX names the raw field" has "$LAST" "can_manage_tags"
    check "and where to switch it off" has "$LAST" "Edit → Administrators"
    check "nothing was added" eq "$(setup_calls)" ""
    set_member "$THEIR" administrator '{"can_pin_messages":true}'
    feed "" 1
    run_sut "$T/in" peer
    check "a known right is named by its button" has "$LAST" "Pin messages"
}

case_peer_chatid_two_groups_newest_hello_after_start_or_pick() {
    local other=-1009999999999
    seed_main
    set_getme "$OUR" bridge_bot
    set_group "$other"
    all_green
    # a hello from before the helper started is a stale group; the one after the start wins
    set_updates getUpdates.json "$(upd_hello 101 "$CHAT" 100 supergroup 'old group')" "$(upd_hello 102 "$other" "$FAR" supergroup 'new group')" "$(upd_peer_hello 103 "$other" "$THEIR" example_bot)"
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "exit 0" eq "$RC" 0
    check "the hello went to the newer group" eq "$(sent_chat)" "$other"
    sub_case peer_chatid_two_groups_pick
    seed_main
    set_getme "$OUR" bridge_bot
    set_group "$other"
    all_green
    set_updates getUpdates.json "$(upd_hello 101 "$CHAT" "$FAR" supergroup 'group A')" "$(upd_hello 102 "$other" "$FAR" supergroup 'group B')" "$(upd_peer_hello 103 "$other" "$THEIR" example_bot)"
    feed "$(mk_token "$OUR")" 2 1
    run_sut "$T/in" peer
    check "exit 0" eq "$RC" 0
    check "the list is numbered and shows titles" has "$(cat "$T/out")" "1) group A"
    check "second entry listed" has "$(cat "$T/out")" "2) group B"
    check "the pick chose group B" eq "$(sent_chat)" "$other"
    check "two pick prompts: the group, then the sole bot" eq "$(grep -c 'Type the number' "$T/out")" 2
}

case_peer_group_titles_with_a_pipe_stay_whole_in_the_pick() {
    local other=-1009999999999
    seed_main
    set_getme "$OUR" bridge_bot
    set_group "$other"
    all_green
    set_updates getUpdates.json "$(upd_hello 101 "$CHAT" "$FAR" supergroup 'Ops|East')" "$(upd_hello 102 "$other" "$FAR" supergroup 'Ops|West')" "$(upd_peer_hello 103 "$other" "$THEIR" example_bot)"
    feed "$(mk_token "$OUR")" 2 1
    run_sut "$T/in" peer
    check "exit 0" eq "$RC" 0
    check "the first title is whole" has "$(cat "$T/out")" "1) Ops|East (supergroup)"
    check "the second title is whole" has "$(cat "$T/out")" "2) Ops|West (supergroup)"
    check "the pick chose the second group" eq "$(sent_chat)" "$other"
}

case_peer_check_group_basic_group_fix() {
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    printf '{"ok":true,"result":{"id":%s,"type":"group","title":"bridge"}}' "$CHAT" > "$T/tg/getChat.json"
    set_good_updates
    all_green
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "exit 3" eq "$RC" 3
    check "says it must be a supergroup" has "$LAST" "supergroup"
    check "gives the public-then-private path" has "$LAST" "Group type → Public"
    check "then private" has "$LAST" "Private"
    check "the owner is not told to ask the owner" lacks "$LAST" "ask the group owner"
    check "nothing was added" eq "$(setup_calls)" ""
    # a migrated basic group is followed to the new id (control for the same fixture shape)
    sub_case peer_check_group_migrated
    seed_main
    set_getme "$OUR" bridge_bot
    set_group -1008888888888
    printf '{"ok":false,"error_code":400,"description":"Bad Request: group chat was upgraded to a supergroup chat","parameters":{"migrate_to_chat_id":-1008888888888}}' > "$T/tg/getChat.1.json"
    printf '{"ok":true,"result":{"id":-1008888888888,"type":"supergroup","title":"bridge","permissions":{"can_change_info":false,"can_pin_messages":false}}}' > "$T/tg/getChat.2.json"
    set_updates getUpdates.json "$(upd_hello 101 "$CHAT" "$FAR" group)" "$(upd_peer_hello 102 "$CHAT" "$THEIR" example_bot)"
    all_green
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "exit 0" eq "$RC" 0
    check "confirm used the new id" has "$(setup_calls)" "confirm example -1008888888888"
}

case_peer_hello_post_follows_a_migrated_group() {
    local new=-1008888888888
    seed_main
    set_getme "$OUR" bridge_bot
    set_group "$new"
    printf '{"ok":false,"error_code":400,"description":"Bad Request: group chat was upgraded to a supergroup chat","parameters":{"migrate_to_chat_id":%s}}' "$new" > "$T/tg/sendMessage.1.json"
    printf '{"ok":true,"result":{"message_id":9}}' > "$T/tg/sendMessage.2.json"
    set_updates getUpdates.json "$(upd_hello 101 "$CHAT" "$FAR" group)" "$(upd_peer_hello 102 "$new" "$THEIR" example_bot)"
    all_green
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "a hello post that gets the migration error: exit 0" eq "$RC" 0
    check "the hello was posted again to the new id" eq "$(sent_chat)" "$new"
    check "two posts in all" eq "$(sent_count)" 2
    check "confirm used the new id" has "$(setup_calls)" "confirm example $new"
    check "the checkpoint keeps the new id" eq "$(jq -r '.peers[0].chatId' "$(CONFIRMED_FILE)")" "$new"
    sub_case peer_hello_post_follows_a_migrated_group_confirmed_side
    seed_confirmed_station
    set_group "$new"
    printf '{"ok":false,"error_code":400,"description":"Bad Request: group chat was upgraded to a supergroup chat","parameters":{"migrate_to_chat_id":%s}}' "$new" > "$T/tg/sendMessage.1.json"
    printf '{"ok":true,"result":{"message_id":9}}' > "$T/tg/sendMessage.2.json"
    feed ""
    run_sut "$T/in" peer
    check "confirmed side, group migrated: exit 0" eq "$RC" 0
    check "the hello went to the new id" eq "$(sent_chat)" "$new"
    check "setup.ts confirmed the peer in the new group" has "$(setup_calls)" "confirm example $new"
    check "the peer list holds the new id" eq "$(jq -r '.peers.example.chatId' "$(PEERS_FILE)")" "$new"
    check "the checkpoint holds the new id" eq "$(jq -r '.peers[0].chatId' "$(CONFIRMED_FILE)")" "$new"
    sub_case peer_hello_post_other_error_stays_a_fix
    seed_confirmed_station
    printf '{"ok":false,"error_code":403,"description":"Forbidden: bot was kicked from the supergroup chat"}' > "$T/tg/sendMessage.json"
    feed ""
    run_sut "$T/in" peer
    check "any other refusal is still one FIX" eq "$RC" 3
    check "and names the refused action" has "$LAST" "posting the hello in the group"
    check "no confirm ran" eq "$(setup_calls)" ""
}

case_peer_check_group_member_change_info_fix() {
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    printf '{"ok":true,"result":{"id":%s,"type":"supergroup","title":"bridge","permissions":{"can_change_info":true,"can_pin_messages":true}}}' "$CHAT" > "$T/tg/getChat.json"
    set_good_updates
    all_green
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "exit 3" eq "$RC" 3
    check "names Change group info" has "$LAST" "Change group info"
    check "names Pin messages" has "$LAST" "Pin messages"
    check "points at Permissions" has "$LAST" "Edit → Permissions"
    check "nothing was added" eq "$(setup_calls)" ""
}

case_peer_non_owner_fix_says_ask_owner() {
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    printf '{"ok":true,"result":{"status":"member","user":{"id":%s,"is_bot":false}}}' "$OPER" > "$T/tg/getChatMember.u$OPER.json"
    printf '{"ok":true,"result":{"id":%s,"type":"group","title":"bridge"}}' "$CHAT" > "$T/tg/getChat.json"
    set_good_updates
    all_green
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "exit 3" eq "$RC" 3
    check "tells the human to ask the owner" has "$LAST" "ask the group owner to"
    check "and still says what to do" has "$LAST" "Group type"
}

case_peer_checkpoint_written_after_confirm_before_status() {
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_good_updates
    all_green
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "exit 0" eq "$RC" 0
    check "the final status read found the checkpoint already written" eq "$(tail -n 1 "$T/himmelctl.checkpoint")" present
    check "confirm ran before the unit started" test "$(line_of 'setup confirm')" -lt "$(line_of 'systemctl --user start')"
    sub_case peer_checkpoint_confirm_refused
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_good_updates
    all_green
    echo 3 > "$T/setup.confirm.rc"
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "exit 3" eq "$RC" 3
    check "the FIX carries setup.ts's reason" has "$LAST" "every right off"
    check "no checkpoint" test ! -e "$(CONFIRMED_FILE)"
    check "no unit" test ! -e "$(UNIT_FILE)"
    check "no status read" test ! -e "$T/himmelctl.checkpoint"
}

case_peer_unit_start_failure_keeps_checkpoint() {
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_good_updates
    all_green
    : > "$T/units/$UNIT_NAME.startfail"
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "exit 3" eq "$RC" 3
    check "the FIX names the poller log" has "$LAST" "journalctl --user -u himmel-peer-bridge.service"
    check "the checkpoint is kept" eq "$(jq -r '.peers[0].name' "$(CONFIRMED_FILE)")" example
    # the re-run resumes at the unit step: nothing is added or confirmed twice
    rm -f "$T/units/$UNIT_NAME.startfail"
    feed ""
    run_sut "$T/in" peer
    check "the re-run reaches DONE" eq "$RC" 0
    check "setup.ts add ran exactly once in all" eq "$(setup_calls | grep -c '^add ')" 1
    check "and confirm exactly once" eq "$(setup_calls | grep -c '^confirm ')" 1
}

case_peer_adoption_from_example_end_state_reaches_done() {
    local before after added f bcks acks
    seed_main
    seed_peer_env
    seed_peers_json example "$THEIR" "$CHAT"
    set_getme "$OUR" bridge_bot
    set_group
    all_green
    snapshot_stores
    before=$SNAP
    feed ""
    run_sut "$T/in" peer
    check "exit 0" eq "$RC" 0
    check "DONE names example" eq "$LAST" "DONE: peer example — group confirmed, poller running"
    after=$(cd "$HOME_FIX" && find . -type f | sort)
    added=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$before" in *"$f"*) ;; *) added="$added $f" ;; esac
    done <<EOF
$after
EOF
    check "only the unit and the helper's own records appeared ($added)" eq "$added" " ./.config/systemd/user/$UNIT_NAME ./.himmel/remote-setup/bots.json ./.himmel/remote-setup/peers-confirmed.json"
    bcks=$(printf '%s\n' "$before" | grep -E '^[0-9]+ [0-9]+ \./' | sort)
    acks=$(cd "$HOME_FIX" && printf '%s\n' "$bcks" | sed 's/^[0-9]* [0-9]* //' | while IFS= read -r f; do cksum "$f"; done | sort)
    check "every earlier file is byte-identical" eq "$acks" "$bcks"
    check "setup.ts was not run: the peer was already confirmed" eq "$(setup_calls)" ""
    check "the checkpoint was adopted from peers.json" eq "$(jq -r '.peers[0] | "\(.name) \(.peerBotId) \(.chatId)"' "$(CONFIRMED_FILE)")" "example $THEIR $CHAT"
}

case_peer_rerun_posts_exactly_one_hello() {
    seed_confirmed_station
    feed ""
    run_sut "$T/in" peer
    check "first run: DONE" eq "$RC" 0
    rm -f "$T/curl.stdin"
    feed ""
    run_sut "$T/in" peer
    check "second run: DONE" eq "$RC" 0
    check "the second run posts exactly one hello" eq "$(sent_count)" 1
}

case_peer_repoint_runs_remove_then_add_confirm() {
    seed_confirmed_station
    set_updates getUpdates.json "$(upd_hello 101 "$CHAT" "$FAR")" "$(upd_peer_hello 102 "$CHAT" 666 new_bot)"
    set_member 666 administrator
    feed "" "" 1 yes
    run_sut "$T/in" peer --replace
    check "exit 0" eq "$RC" 0
    check "says the other bot changed" has "$(cat "$T/out")" "a different bot"
    check "the old entry was removed" has "$(setup_calls)" "remove example"
    check "the new bot was added under the same name" has "$(setup_calls)" "add example --peer-bot-id 666 --peer-username new_bot --operator-bot-id 111"
    check "and confirmed" has "$(setup_calls)" "confirm example $CHAT"
    check "in that order" eq "$(setup_calls | sed 's/ .*//' | tr '\n' ' ')" "remove add confirm "
    check "the checkpoint holds the new bot" eq "$(jq -r '.peers[0].peerBotId' "$(CONFIRMED_FILE)")" 666
}

case_peer_pending_publication_survives_interruption() {
    local tok conflict
    if [ "$(id -u)" = 0 ]; then SKIPN=$((SKIPN + 1)); return 0; fi
    tok=$(mk_token "$OUR")
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_good_updates
    all_green
    mkdir -p "$(PEER_CFG)"
    chmod 500 "$(PEER_CFG)"
    feed "$tok"
    run_sut "$T/in" peer
    check "the token store failed, so a FIX" eq "$RC" 3
    check "the id was published before the store, as pending" eq "$(jq -c '.bridge | [.id, .pending]' "$(BOTS_FILE)")" "[\"$OUR\",true]"
    check "no token was stored" test ! -s "$(PEER_ENV)"
    conflict=$(env HOME="$HOME_FIX" node -e '
const roles = require(process.argv[1]);
const ids = roles.readRoleIds({ home: process.env.HOME, repoRoot: process.argv[2], env: process.env });
const c = roles.roleConflict(process.argv[3], "notice", ids);
console.log(c ? c.conflictsWith : "none");
' "$REPO/scripts/himmelctl/lib/bot-roles.js" "$ROOT" "$OUR")
    check "a pending bridge id counts as taken for another role" eq "$conflict" bridge
    chmod 700 "$(PEER_CFG)"
    feed "$tok" 1
    run_sut "$T/in" peer
    check "the next run resolves it and reaches DONE" eq "$RC" 0
    check "pending is cleared" eq "$(jq -r '.bridge.pending // false' "$(BOTS_FILE)")" false
}

case_peer_allowfrom_written_by_setup_ts_only_digit_strings() {
    if [ ! -x "$REAL_BUN" ]; then SKIPN=$((SKIPN + 1)); return 0; fi
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_good_updates
    all_green
    : > "$T/setup.real"
    RUN_ENV="RST_REAL_SETUP=$REPO/scripts/peer-bridge/setup.ts"
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    RUN_ENV=""
    check "the real setup.ts add ran and the helper reached DONE (last: $LAST)" eq "$RC" 0
    check "allowFrom is exactly the peer bot, as a digit string" eq "$(jq -c '.peers.example.allowFrom' "$(PEERS_FILE)")" "[\"$THEIR\"]"
    check "every allowFrom entry is a digit string" eq "$(jq -r '[.peers[].allowFrom[] | type == "string" and test("^[0-9]+$")] | all' "$(PEERS_FILE)")" true
    check "no human id was added" lacks "$(cat "$(PEERS_FILE)")" "$OPER\""
    check "setup.ts stays the only writer: no code line writes peers.json" eq "$(grep -E 'peers\.json' "$HERE/remote-setup.sh" | grep -vE '^[[:space:]]*#' | grep -cE '[^2&<-]>[^&]|rs_json_edit|[[:space:]]mv[[:space:]]|tee ')" 0
}

case_peer_canary_token_absent_everywhere() {
    local tok secret leaks f
    tok=$(mk_token "$OUR")
    secret=${tok#*:}
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_good_updates
    all_green
    printf '{"ok":false,"error_code":401,"description":"Unauthorized"}' > "$T/tg/getMe.json"
    feed "$tok"
    run_sut "$T/in" peer
    check "a revoked token is a FIX" eq "$RC" 3
    set_getme "$OUR" bridge_bot
    feed "$tok" 1
    run_sut "$T/in" peer
    check "the full path is DONE" eq "$RC" 0
    feed ""
    run_sut "$T/in" peer
    check "the re-run is DONE" eq "$RC" 0
    leaks=""
    while IFS= read -r f; do
        case "$f" in
            "$T/in" | "$T/curl.stdin" | "$(PEER_ENV)") ;;
            *) leaks="$leaks $f" ;;
        esac
    done <<EOF
$(grep -rlF -- "$secret" "$T" 2> /dev/null)
EOF
    check "the token appears nowhere but the store (found in:$leaks)" eq "$leaks" ""
    check "not in the curl argv" file_lacks "$T/curl.argv" "$secret"
    check "not in any output of any run" file_lacks "$T/allout.log" "$secret"
    check "setup.ts calls carry no token" file_lacks "$T/setup.calls" "$secret"
}

case_peer_sigint_during_discovery_restarts_poller() {
    seed_confirmed_station
    set_updates getUpdates.json "$(upd_hello 101 "$CHAT" "$FAR")"
    : > "$T/sleep.int"
    feed "" ""
    run_sut "$T/in" peer --replace
    check "exit 3" eq "$RC" 3
    check "says it was interrupted" has "$LAST" "interrupted"
    check "the poller is running again" test -f "$T/units/$UNIT_NAME.active"
    check "it was stopped for the read" test -n "$(line_of 'systemctl --user stop himmel-peer-bridge.service')"
    check "and started again after" test "$(last_line_of 'systemctl --user start himmel-peer-bridge.service')" -gt "$(line_of 'systemctl --user stop himmel-peer-bridge.service')"
}

case_renamed_peer_bot_keeps_name() {
    # the other bot changed its username: the same bot id keeps the same name, and nothing is added
    seed_confirmed_station
    set_updates getUpdates.json "$(upd_hello 101 "$CHAT" "$FAR")" "$(upd_peer_hello 102 "$CHAT" "$THEIR" renamed_bot)"
    feed "" "" 1
    run_sut "$T/in" peer --replace
    check "exit 0" eq "$RC" 0
    check "the name is kept" eq "$LAST" "DONE: peer example — group confirmed, poller running"
    check "setup.ts was not run again" eq "$(setup_calls)" ""
    # added earlier but never confirmed: the same id keeps the name, and only confirm runs
    sub_case renamed_peer_bot_unconfirmed
    seed_main
    seed_peer_env
    seed_bots "{\"bridge\":{\"id\":\"$OUR\",\"publishedAt\":\"2026-11-20T10:00:00Z\"}}"
    seed_peers_json example "$THEIR" null
    set_getme "$OUR" bridge_bot
    set_group
    all_green
    set_updates getUpdates.json "$(upd_hello 101 "$CHAT" "$FAR")" "$(upd_peer_hello 102 "$CHAT" "$THEIR" renamed_bot)"
    feed "" 1
    run_sut "$T/in" peer
    check "exit 0" eq "$RC" 0
    check "the old name stays" has "$LAST" "peer example"
    check "no new add" eq "$(setup_calls | grep -c '^add ')" 0
    check "confirm ran for the kept name" has "$(setup_calls)" "confirm example $CHAT"
}

case_peer_done_rerun_changes_no_config_artifact() {
    set_getme "$OUR" bridge_bot
    seed_main
    set_group
    set_good_updates
    all_green
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "first run: DONE" eq "$RC" 0
    snapshot_stores
    feed ""
    run_sut "$T/in" peer
    check "second run: DONE" eq "$RC" 0
    assert_stores_unchanged
    snapshot_stores
    feed "$(sed -n 's/^PEER_BOT_TOKEN=//p' "$(PEER_ENV)")"
    run_sut "$T/in" peer
    check "same token pasted: DONE" eq "$RC" 0
    assert_stores_unchanged
}

case_peer_inputs_are_only_the_g2_set() {
    local sec
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_good_updates
    all_green
    feed "$(mk_token "$OUR")" 1 "EXTRA-LINE-NOBODY-ASKED-FOR"
    run_sut "$T/in" peer
    check "exit 0" eq "$RC" 0
    check "exactly one prompt in the whole run" eq "$(grep -c 'Paste the bridge bot token' "$T/out")" 1
    check "no enter prompt on the simple path" eq "$(grep -c 'Press Enter' "$T/out")" 0
    check "one digit prompt: the confirmation of the sole bot" eq "$(grep -c 'Type the number' "$T/out")" 1
    sec=$(sed -n '/^# ── part 4:/,/^# ── status:/p' "$HERE/remote-setup.sh")
    check "part 4 has a body to read" test -n "$sec"
    check "part 4 reads input only through the lib's rs_secret, rs_enter and rs_pick" eq "$(printf '%s\n' "$sec" | grep -cE '(^|[[:space:];|&(])read -')" 0
    check "the token prompt is one call" eq "$(printf '%s\n' "$sec" | grep -c 'rs_secret ')" 1
}

case_peer_remove_deletes_checkpoint_and_status_na() {
    seed_confirmed_station
    feed yes
    run_sut "$T/in" peer --remove
    check "exit 0" eq "$RC" 0
    check "DONE names what was removed" has "$LAST" "removed example"
    check "setup.ts remove ran" has "$(setup_calls)" "remove example"
    check "the checkpoint is gone" test ! -e "$(CONFIRMED_FILE)"
    check "the poller unit is gone" test ! -e "$(UNIT_FILE)"
    check "and not running" test ! -e "$T/units/$UNIT_NAME.active"
    set_item remote-peer n/a "no peer bridge has been set up with remote-setup"
    run_sut --json "$T/in" status --json
    check "part 4 reads not set" eq "$(part_field 3 state)" "not set"
    check "and offers its command" eq "$(part_field 3 command)" "bash scripts/remote-setup/remote-setup.sh peer"
}

case_peer_remove_interrupted_resumes() {
    seed_confirmed_station
    : > "$T/setup.remove.sigint"
    feed yes
    run_sut "$T/in" peer --remove
    check "interrupted: exit 3" eq "$RC" 3
    check "says so" has "$LAST" "interrupted"
    check "setup.ts had removed the peer" eq "$(jq -r '.peers | has("example")' "$(PEERS_FILE)")" false
    check "the checkpoint is still there" test -f "$(CONFIRMED_FILE)"
    rm -f "$T/setup.remove.sigint"
    feed ""
    run_sut "$T/in" peer --remove
    check "the next run finishes the delete" eq "$RC" 0
    check "the checkpoint is gone" test ! -e "$(CONFIRMED_FILE)"
    check "setup.ts remove ran only once" eq "$(setup_calls | grep -c '^remove ')" 1
    check "the poller unit is gone" test ! -e "$(UNIT_FILE)"
}

case_peer_remove_with_nothing_set_up_is_done() {
    seed_main
    feed ""
    run_sut "$T/in" peer --remove
    check "exit 0" eq "$RC" 0
    check "DONE says there was nothing to remove" has "$LAST" "nothing to remove"
    check "setup.ts was not run" eq "$(setup_calls)" ""
}

case_peer_wait_pages_when_the_group_is_busy() {
    # a fresh side that waits for the other hello keeps acknowledging: 100 messages of chatter arrive
    # while it waits, and the hello behind them is still found
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    all_green
    set_updates getUpdates.1.json "$(upd_hello 1 "$CHAT" "$FAR")"
    printf '{"ok":true,"result":%s}' "$(noise_updates 2 101)" > "$T/tg/getUpdates.2.json"
    set_updates getUpdates.3.json "$(upd_peer_hello 102 "$CHAT" "$THEIR" example_bot)"
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "the hello behind the chatter is found" eq "$RC" 0
    check "the wait acknowledged the full batch before asking again" file_has "$T/curl.stdin" '\"offset\":102'
}

case_peer_remove_unreadable_peer_list_stops_before_any_change() {
    seed_confirmed_station
    printf 'this is not json\n' > "$(PEERS_FILE)"
    feed yes
    run_sut "$T/in" peer --remove
    check "an unreadable peers.json is a FIX" eq "$RC" 3
    check "the FIX names the peer list" has "$LAST" "peer list"
    check "the working poller is still running" test -f "$T/units/$UNIT_NAME.active"
    check "its unit file is kept" test -f "$(UNIT_FILE)"
    check "the checkpoint is kept" test -f "$(CONFIRMED_FILE)"
    check "nothing was stopped" lacks "$(cat "$T/units.log")" "systemctl --user disable"
    check "setup.ts was not run" eq "$(setup_calls)" ""
    sub_case peer_remove_missing_peer_list_is_not_a_failure
    seed_main
    feed ""
    run_sut "$T/in" peer --remove
    check "control, no peers.json at all: nothing to remove" has "$LAST" "nothing to remove"
}

case_peer_remove_teardown_failure_is_a_fix() {
    seed_confirmed_station
    : > "$T/units/$UNIT_NAME.stopfail"
    feed yes
    run_sut "$T/in" peer --remove
    check "a poller that will not stop is a FIX, never DONE" eq "$RC" 3
    check "the FIX says the poller could not be stopped" has "$LAST" "could not be stopped"
    check "the unit file is kept while the poller still runs" test -f "$(UNIT_FILE)"
    check "the peer itself is already removed" eq "$(jq -r '.peers | has("example")' "$(PEERS_FILE)")" false
    rm -f "$T/units/$UNIT_NAME.stopfail"
    feed ""
    run_sut "$T/in" peer --remove
    check "the re-run reaches DONE" eq "$RC" 0
    check "and cleans up the leftover poller" has "$LAST" "leftover poller"
    check "the unit file is gone" test ! -e "$(UNIT_FILE)"
    check "and the poller stopped" test ! -e "$T/units/$UNIT_NAME.active"
}

case_peer_remove_unit_delete_failure_is_a_fix() {
    if [ "$(id -u)" = 0 ]; then SKIPN=$((SKIPN + 1)); return 0; fi
    seed_confirmed_station
    chmod 500 "$(dirname "$(UNIT_FILE)")"
    feed yes
    run_sut "$T/in" peer --remove
    chmod 700 "$(dirname "$(UNIT_FILE)")"
    check "a unit file that cannot be deleted is a FIX, never DONE" eq "$RC" 3
    check "the FIX says the unit file could not be deleted" has "$LAST" "unit file could not be deleted"
    check "the poller itself was stopped" test ! -e "$T/units/$UNIT_NAME.active"
    check "the unit file is still there" test -f "$(UNIT_FILE)"
    feed ""
    run_sut "$T/in" peer --remove
    check "the re-run reaches DONE" eq "$RC" 0
    check "the unit file is gone" test ! -e "$(UNIT_FILE)"
}

case_peer_remove_reload_failure_is_a_fix() {
    seed_confirmed_station
    : > "$T/units/daemon-reload.fail"
    feed yes
    run_sut "$T/in" peer --remove
    check "a systemd reload that fails is a FIX, never DONE" eq "$RC" 3
    check "the FIX names the reload command" has "$LAST" "systemctl --user daemon-reload"
    check "the unit file was deleted" test ! -e "$(UNIT_FILE)"
}

seed_second_peer() { # yotam, a second confirmed peer in another group
    jq '.peers.yotam = {peerBotId: "666", chatId: -1002, allowFrom: ["666"], theirs: {username: "y_bot"}}' "$(PEERS_FILE)" > "$(PEERS_FILE).new" && mv "$(PEERS_FILE).new" "$(PEERS_FILE)"
    jq '.peers += [{name: "yotam", peerBotId: "666", chatId: -1002, confirmedAt: "2026-11-20T10:00:00Z"}]' "$(CONFIRMED_FILE)" > "$(CONFIRMED_FILE).new" && mv "$(CONFIRMED_FILE).new" "$(CONFIRMED_FILE)"
}

case_peer_remove_one_of_two_restarts_poller() {
    seed_confirmed_station
    seed_second_peer
    feed 1 yes
    run_sut "$T/in" peer --remove
    check "exit 0" eq "$RC" 0
    check "the numbered pick offered both peers" has "$(cat "$T/out")" "2) yotam"
    check "DONE names the removed peer and the restart" has "$LAST" "removed example; the poller was restarted"
    check "setup.ts removed only example" eq "$(setup_calls)" "remove example"
    check "yotam stays on the record" eq "$(jq -r '.peers | map(.name) | join(",")' "$(CONFIRMED_FILE)")" yotam
    check "the poller was restarted" test -n "$(line_of 'systemctl --user restart himmel-peer-bridge.service')"
    check "and its unit file stays" test -f "$(UNIT_FILE)"
    # a restart that fails is a FIX: the removed peer stays removed
    sub_case peer_remove_one_of_two_restart_fails
    seed_confirmed_station
    seed_second_peer
    : > "$T/units/$UNIT_NAME.startfail"
    feed 1 yes
    run_sut "$T/in" peer --remove
    check "a poller that does not restart is a FIX" eq "$RC" 3
    check "the FIX says it did not restart" has "$LAST" "did not restart"
    check "the removed peer stays removed" eq "$(jq -r '.peers | has("example")' "$(PEERS_FILE)")" false
    # nothing was running, so nothing was restarted, and DONE does not say it was
    sub_case peer_remove_one_of_two_poller_not_running
    seed_confirmed_station
    seed_second_peer
    rm -f "$T/units/$UNIT_NAME.active"
    feed 1 yes
    run_sut "$T/in" peer --remove
    check "exit 0" eq "$RC" 0
    check "DONE does not claim a restart" lacks "$LAST" "restarted"
    check "DONE says the poller was not running" has "$LAST" "was not running"
}

case_peer_remove_one_of_two_interrupted_before_restart_finishes_that_removal() {
    seed_confirmed_station
    seed_second_peer
    : > "$T/units/$UNIT_NAME.startfail"
    feed 1 yes
    run_sut "$T/in" peer --remove
    check "the first run stops at the restart: FIX" eq "$RC" 3
    check "the FIX says to run it again with --remove" has "$LAST" "peer --remove"
    check "example is already removed" eq "$(jq -r '.peers | has("example")' "$(PEERS_FILE)")" false
    rm -f "$T/units/$UNIT_NAME.startfail"
    feed ""
    run_sut "$T/in" peer --remove
    check "the re-run reaches DONE" eq "$RC" 0
    check "it finishes the restart for example" has "$LAST" "removed example; the poller was restarted"
    check "the remaining peer is never offered for removal" lacks "$(setup_calls)" "remove yotam"
    check "and stays set up" eq "$(jq -r '.peers | has("yotam")' "$(PEERS_FILE)")" true
    check "setup.ts removed only example, once" eq "$(setup_calls)" "remove example"
    check "no pick prompt on the re-run" eq "$(grep -c 'Type the number' "$T/out")" 0
    check "the pending removal record is cleared" test ! -e "$HOME_FIX/.himmel/remote-setup/peer-removing.json"
}

case_peer_remove_declined_clears_its_note() {
    seed_confirmed_station
    seed_second_peer
    feed 1 no
    run_sut "$T/in" peer --remove
    check "a declined removal is a FIX" eq "$RC" 3
    check "the FIX says nothing was removed" has "$LAST" "nothing was removed"
    check "example is still set up" eq "$(jq -r '.peers | has("example")' "$(PEERS_FILE)")" true
    check "the in-progress note is gone" test ! -e "$HOME_FIX/.himmel/remote-setup/peer-removing.json"
    feed 2 yes
    run_sut "$T/in" peer --remove
    check "the next run offers the normal pick" has "$(cat "$T/out")" "2) yotam"
    check "and removes the machine picked" has "$LAST" "removed yotam"
    check "example stays" eq "$(jq -r '.peers | has("example")' "$(PEERS_FILE)")" true
    sub_case peer_remove_stale_note_pick_finish
    seed_confirmed_station
    seed_second_peer
    mkdir -p "$HOME_FIX/.himmel/remote-setup"
    printf '{"name":"example"}' > "$HOME_FIX/.himmel/remote-setup/peer-removing.json"
    feed 1 yes
    run_sut "$T/in" peer --remove
    check "finish: exit 0" eq "$RC" 0
    check "the pick offers finishing or cancelling" has "$(cat "$T/out")" "2) Cancel"
    check "finish removes example" has "$LAST" "removed example"
    sub_case peer_remove_stale_note_pick_cancel
    seed_confirmed_station
    seed_second_peer
    mkdir -p "$HOME_FIX/.himmel/remote-setup"
    printf '{"name":"example"}' > "$HOME_FIX/.himmel/remote-setup/peer-removing.json"
    feed 2 2 yes
    run_sut "$T/in" peer --remove
    check "cancel: exit 0" eq "$RC" 0
    check "cancel then pick removes yotam" has "$LAST" "removed yotam"
    check "example stays" eq "$(jq -r '.peers | has("example")' "$(PEERS_FILE)")" true
}

case_peer_mac_bootout_then_bootstrap_order() {
    echo Darwin > "$T/uname"
    seed_confirmed_station mac
    set_good_updates
    feed "" "" 1
    run_sut "$T/in" peer --replace
    local out boot
    out=$(line_of 'launchctl bootout')
    boot=$(last_line_of 'launchctl bootstrap')
    check "exit 0" eq "$RC" 0
    check "bootout was called" test -n "$out"
    check "bootstrap was called" test -n "$boot"
    check "bootstrap comes after bootout" test "${boot:-0}" -gt "${out:-99}"
    check "the agent is loaded again" test -f "$T/units/$UNIT_LABEL.loaded"
    check "no systemctl on a Mac" lacks "$(cat "$T/units.log")" "systemctl"
    check "the plist is the rendered template" file_has "$(PLIST_FILE)" "$ROOT/scripts/peer-bridge/run.sh"
}

case_peer_mac_old_agent_is_not_accepted_as_the_updated_poller() {
    local uid
    uid=$(id -u)
    echo Darwin > "$T/uname"
    seed_confirmed_station mac
    printf 'an older render of the plist\n' > "$(PLIST_FILE)"
    : > "$T/units/$UNIT_LABEL.bootoutfail"
    feed ""
    run_sut "$T/in" peer
    check "a job that will not stop is a FIX, never DONE" eq "$RC" 3
    check "the FIX says the old poller could not be stopped" has "$LAST" "old poller could not be stopped"
    check "and names the stop command" has "$LAST" "launchctl bootout gui/$uid/$UNIT_LABEL"
    check "the plist on disk is still the old one, so a re-run sees the change" eq "$(cat "$(PLIST_FILE)")" "an older render of the plist"
    rm -f "$T/units/$UNIT_LABEL.bootoutfail"
    feed ""
    run_sut "$T/in" peer
    check "the re-run reaches DONE" eq "$RC" 0
    check "the plist is the rendered template now" file_has "$(PLIST_FILE)" "$ROOT/scripts/peer-bridge/run.sh"
    check "the old job was stopped and the new one started" test "$(last_line_of 'launchctl bootstrap')" -gt "$(last_line_of 'launchctl bootout')"
    check "the agent is loaded" test -f "$T/units/$UNIT_LABEL.loaded"
}

case_peer_mac_start_failure_names_the_poller_log() {
    echo Darwin > "$T/uname"
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_good_updates
    all_green
    : > "$T/units/$UNIT_LABEL.startfail"
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "an agent that will not start is a FIX" eq "$RC" 3
    check "the FIX points at the poller log in peer-bridge.md" has "$LAST" "poller log named in docs/internals/peer-bridge.md (Audit trail)"
}

case_peer_changed_token_restarts_the_running_poller() {
    local tok
    seed_confirmed_station
    tok=$(mk_token "$OUR")
    feed "$tok"
    run_sut "$T/in" peer
    check "a rotated token for the same bot: exit 0" eq "$RC" 0
    check "the new token is stored" eq "$(cat "$(PEER_ENV)")" "PEER_BOT_TOKEN=$tok"
    check "the running poller was restarted to load it" test -n "$(line_of 'systemctl --user restart himmel-peer-bridge.service')"
    check "and is running" test -f "$T/units/$UNIT_NAME.active"
    sub_case peer_same_token_no_restart
    seed_confirmed_station
    feed "$BTOK"
    run_sut "$T/in" peer
    check "control, the same token pasted: exit 0" eq "$RC" 0
    check "control: the poller is not bounced" lacks "$(cat "$T/units.log")" "restart"
    sub_case peer_changed_token_mac
    echo Darwin > "$T/uname"
    seed_confirmed_station mac
    feed "$(mk_token "$OUR")"
    run_sut "$T/in" peer
    check "mac, a rotated token: exit 0" eq "$RC" 0
    check "mac: the agent was booted out" test -n "$(line_of 'launchctl bootout')"
    check "mac: and bootstrapped again after" test "$(last_line_of 'launchctl bootstrap')" -gt "$(line_of 'launchctl bootout')"
}

case_peer_without_part1_fixes() {
    feed "$(mk_token "$OUR")"
    snapshot_stores
    run_sut "$T/in" peer
    check "exit 3" eq "$RC" 3
    check "says to do part 1 first" has "$LAST" "do part 1 first: bash scripts/remote-setup/remote-setup.sh bot"
    assert_stores_unchanged
}

case_peer_bridge_equals_main_refuses() {
    seed_main
    set_getme 111 bridge_bot
    set_group
    set_good_updates
    all_green
    feed "$(mk_token 111)"
    snapshot_stores
    run_sut "$T/in" peer
    check "exit 3" eq "$RC" 3
    check "says it is already the main bot" has "$LAST" "already your main bot"
    assert_stores_unchanged
}

case_peer_different_bridge_id_without_replace_refuses() {
    seed_confirmed_station
    set_getme 333 other_bot
    feed "$(mk_token 333)"
    snapshot_stores
    run_sut "$T/in" peer
    check "exit 3" eq "$RC" 3
    check "says a different bridge bot is set up" has "$LAST" "a different bridge bot is already set up"
    check "names the flag" has "$LAST" "peer --replace"
    assert_stores_unchanged
}

case_peer_hello_timeout_fixes() {
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_updates getUpdates.json "$(upd_hello 101 "$CHAT" "$FAR")"
    all_green
    feed "$(mk_token "$OUR")"
    run_sut "$T/in" peer
    check "exit 3" eq "$RC" 3
    check "asks the other operator to run it once" has "$LAST" "ask the other operator to run the same command once"
    check "our hello was posted" eq "$(sent_count)" 1
    check "nothing was added" eq "$(setup_calls)" ""
    check "the token is kept for the re-run" test -s "$(PEER_ENV)"
}

case_peer_sole_candidate_needs_a_yes() {
    local before
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_good_updates
    all_green
    feed "$(mk_token "$OUR")" 2
    run_sut "$T/in" peer
    check "no: exit 3" eq "$RC" 3
    check "no: one FIX says what to do next" has "$LAST" "ask the other operator for the name of their bridge bot"
    check "the prompt shows the name and masks the id" has "$(cat "$T/out")" "@example_bot (id masked)"
    check "the bot id is not printed" lacks "$(cat "$T/out")" "bot id $THEIR"
    check "no: setup.ts was not run" eq "$(setup_calls)" ""
    check "no: no peers.json, so nothing in allowFrom" test ! -e "$(PEERS_FILE)"
    check "no: no checkpoint" test ! -e "$(CONFIRMED_FILE)"
    check "no: no unit" test ! -e "$(UNIT_FILE)"
    sub_case peer_sole_candidate_no_answer
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_good_updates
    all_green
    feed "$(mk_token "$OUR")"
    run_sut "$T/in" peer
    check "no answer: exit 3" eq "$RC" 3
    check "no answer: the FIX says no answer was given" has "$LAST" "no answer was given about @example_bot"
    check "no answer: setup.ts was not run" eq "$(setup_calls)" ""
    check "no answer: no peers.json" test ! -e "$(PEERS_FILE)"
    sub_case peer_sole_candidate_not_a_terminal
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_good_updates
    all_green
    feed "$(mk_token "$OUR")" 1
    snapshot_stores
    run_sut --no-tty "$T/in" peer
    check "no terminal: exit 3" eq "$RC" 3
    check "no terminal: the FIX asks for a plain Terminal" has "$LAST" "plain Terminal"
    check "no terminal: setup.ts was not run" eq "$(setup_calls)" ""
    assert_stores_unchanged
    sub_case peer_sole_candidate_yes
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_good_updates
    all_green
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "control, yes: exit 0" eq "$RC" 0
    check "control, yes: the peer was added" has "$(setup_calls)" "add example --peer-bot-id $THEIR"
    check "control, yes: allowFrom is the bot only" eq "$(jq -c '.peers.example.allowFrom' "$(PEERS_FILE)")" "[\"$THEIR\"]"
}

case_peer_wait_is_bounded_by_the_clock_not_by_the_loop_count() {
    local n
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    # the answer is never empty, so a read returns at once and a loop count alone would end the wait in about a minute
    set_updates getUpdates.json "$(upd_hello 101 "$CHAT" "$FAR")"
    all_green
    feed "$(mk_token "$OUR")"
    run_sut "$T/in" peer
    n=$(method_count getUpdates)
    check "no hello from the other station: exit 3" eq "$RC" 3
    check "the FIX says no hello came" has "$LAST" "no hello came from the other station"
    check "the wait ended when the ten minutes were up ($n reads), not after a fixed number of reads" test "$n" -ge 8 -a "$n" -le 16
}

case_peer_a_failed_merge_of_updates_leaves_no_temp_file() {
    local real_jq
    real_jq=$(command -v jq)
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_good_updates
    all_green
    # jq fails only for the merge of the new updates into the kept ones; the shell has opened the .new file by then
    printf '#!/usr/bin/env bash\ncase "$*" in *"unique_by([.u, .k])"*) exit 5 ;; esac\nexec %s "$@"\n' "$real_jq" > "$T/bin/jq"
    chmod +x "$T/bin/jq"
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "the merge failed: exit 3" eq "$RC" 3
    check "the FIX says the messages could not be kept" has "$LAST" "could not be kept"
    check "no updates file is left in the temp folder" eq "$(find "$T/tmp dir" -name 'remote-setup-updates*' | wc -l | tr -d ' ')" 0
}

case_peer_409_names_a_webhook_or_a_competing_poller() {
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    all_green
    printf '{"ok":false,"error_code":409,"description":"Conflict: can'"'"'t use getUpdates method while webhook is active; use deleteWebhook to delete the webhook first"}' > "$T/tg/getUpdates.json"
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "a webhook conflict: exit 3" eq "$RC" 3
    check "the FIX says the bot has a webhook" has "$LAST" "has a webhook set"
    check "it keeps Telegram's description" has "$LAST" "webhook is active"
    check "and does not send the operator to a poller" lacks "$LAST" "stop that program"
    sub_case peer_409_poller
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    all_green
    printf '{"ok":false,"error_code":409,"description":"Conflict: terminated by other getUpdates request; make sure that only one bot instance is running"}' > "$T/tg/getUpdates.json"
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "a competing poller: exit 3" eq "$RC" 3
    check "the FIX says another program is reading" has "$LAST" "another program is already reading this bot's messages"
    check "it keeps Telegram's description" has "$LAST" "terminated by other getUpdates request"
    check "and does not talk about a webhook" lacks "$LAST" "webhook set"
}

case_peer_no_group_hello_fix_puts_the_rerun_before_the_hello() {
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_updates getUpdates.json
    all_green
    feed "$(mk_token "$OUR")" 1
    run_sut "$T/in" peer
    check "no hello in the group: exit 3" eq "$RC" 3
    check "the FIX starts with the re-run" has "$LAST" "no hello arrived from the group: run the same command again"
    check "then says to wait for the prompt" has "$LAST" "wait until it asks"
    check "and not to send hello first" lacks "$LAST" "send the word hello in the group, then run"
    check "nothing was added" eq "$(setup_calls)" ""
}

case_peer_retry_after_a_timed_out_discovery_asks_for_a_fresh_hello() {
    local base
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    all_green
    set_updates getUpdates.json "$(upd_hello 101 "$CHAT" "$FAR")"
    feed "$(mk_token "$OUR")"
    run_sut "$T/in" peer
    check "run 1, the other station never answers: exit 3" eq "$RC" 3
    # Telegram no longer holds the hello that named the group (it was acknowledged); only the other bot's hello is left
    base=$(cat "$T/tg/getUpdates.n")
    rm -f "$T/tg/getUpdates.json"
    set_updates "getUpdates.$((base + 1)).json" "$(upd_peer_hello 102 "$CHAT" "$THEIR" example_bot)"
    set_updates "getUpdates.$((base + 2)).json" "$(upd_hello 103 "$CHAT" "$FAR")" "$(upd_peer_hello 102 "$CHAT" "$THEIR" example_bot)"
    feed "" 1
    run_sut "$T/in" peer
    check "run 2 reaches DONE" eq "$RC" 0
    check "run 2 asked for a fresh hello in the group" has "$(cat "$T/out")" "send the word hello in it"
    check "the peer was added once" eq "$(setup_calls | grep -c '^add ')" 1
    check "and confirmed in the group" has "$(setup_calls)" "confirm example $CHAT"
}

case_peer_hostile_username_refused() {
    seed_main
    set_getme "$OUR" bridge_bot
    set_group
    set_updates getUpdates.json "$(upd_hello 101 "$CHAT" "$FAR")" "$(upd_peer_hello 102 "$CHAT" "$THEIR" "evil;name")"
    all_green
    feed "$(mk_token "$OUR")"
    run_sut "$T/in" peer
    check "exit 3" eq "$RC" 3
    check "says the name is not usable" has "$LAST" "not a usable Telegram username"
    check "the hostile bytes are not echoed" lacks "$(cat "$T/out")" "evil;name"
    check "nothing was added" eq "$(setup_calls)" ""
}

# The bun shim stands in for setup.ts, so it must not report a write it did not make.
case_bun_shim_fails_when_it_cannot_write_peers_json() {
    local before verb rc
    if [ "$(id -u)" = 0 ]; then SKIPN=$((SKIPN + 1)); return 0; fi
    seed_peers_json example "$THEIR" "$CHAT"
    before=$(cksum < "$(PEERS_FILE)")
    chmod 500 "$(PEER_CFG)"
    for verb in "add other --peer-bot-id 666 --peer-username other_bot --operator-bot-id 111" "confirm example -1002" "remove example"; do
        # shellcheck disable=SC2086
        printf 'yes\n' | env RST="$T" HOME="$HOME_FIX" RST_REAL_BUN="$REAL_BUN" PATH="$T/bin:$PATH_BASE" "$T/bin/bun" "$ROOT/scripts/peer-bridge/setup.ts" $verb > "$T/shim.out" 2> "$T/shim.err"
        rc=$?
        check "${verb%% *}: a read-only folder is a non-zero exit" test "$rc" -ne 0
        check "${verb%% *}: it does not say the write happened" eq "$(grep -cE '^(added|confirmed|removed) ' "$T/shim.out")" 0
        check "${verb%% *}: peers.json is unchanged" eq "$(cksum < "$(PEERS_FILE)")" "$before"
    done
    chmod 700 "$(PEER_CFG)"
}

# The systemctl shim stands in for the real one: disable and enable change the running state only with --now.
case_systemctl_shim_changes_the_running_state_only_with_now() {
    local u=x.service
    : > "$T/units/$u.active"
    : > "$T/units/$u.enabled"
    env RST="$T" "$T/bin/systemctl" --user disable "$u"
    check "disable without --now leaves the unit running" test -f "$T/units/$u.active"
    check "and takes the enabled mark away" test ! -e "$T/units/$u.enabled"
    env RST="$T" "$T/bin/systemctl" --user disable --now "$u"
    check "disable --now stops it" test ! -e "$T/units/$u.active"
    env RST="$T" "$T/bin/systemctl" --user enable "$u"
    check "enable without --now does not start it" test ! -e "$T/units/$u.active"
    check "and marks it enabled" test -f "$T/units/$u.enabled"
    env RST="$T" "$T/bin/systemctl" --user enable --now "$u"
    check "enable --now starts it" test -f "$T/units/$u.active"
}

case_peer_name_second_collision_gets_3() {
    run_drive --no-tty --no-contract "$T/in" rs_peer_name_for Example_bot example example-2
    check "the third name is -3" eq "$(sed -n 2p "$T/out")" example-3
    run_drive --no-tty --no-contract "$T/in" rs_peer_name_for Fresh_Sky_Bot example
    check "a trailing _bot is stripped and the rest mapped to dashes" eq "$(sed -n 2p "$T/out")" fresh-sky
    run_drive --no-tty --no-contract "$T/in" rs_peer_name_for HimmelBot
    check "a trailing bot is stripped" eq "$(sed -n 2p "$T/out")" himmel
}

case_peer_name_32_char_base_with_suffix_fits() {
    local long=abcdefghijklmnopqrstuvwxyzabcdef
    run_drive --no-tty --no-contract "$T/in" rs_peer_name_for "$long" "$long"
    check "a 32-character base plus a suffix still fits" eq "$(sed -n 2p "$T/out")" "abcdefghijklmnopqrstuvwxyzabcd-2"
    check "and passes the name pattern" eq "$(sed -n 2p "$T/out" | grep -cE '^[a-z0-9][a-z0-9-]{0,31}$')" 1
    run_drive --no-tty --no-contract "$T/in" rs_peer_name_for "$long" "$long" "abcdefghijklmnopqrstuvwxyzabcd-2"
    check "the next free suffix" eq "$(sed -n 2p "$T/out")" "abcdefghijklmnopqrstuvwxyzabcd-3"
}

CASES="mk_token_ends_when_tr_ignores_sigpipe guard_matrix_every_writer usage_exits_2 usage_rows_every_subcommand contract_rows_every_subcommand
curl_argv_is_exact getme_401_gives_revoked_fix tg_429_waits_retry_after_once outside_checkout_gives_cd_fix
status_skips_unshipped_parts status_na_counts_not_ok status_part_prereq_message status_runs_under_claudecode
status_json_is_single_object_on_success status_json_on_item_failure status_json_never_appends_done_line
status_reads_no_daemon_log_peers_json_or_mode
bot_red_bridge_id_as_main_refuses bot_relay_id_as_main_refuses bot_notice_id_as_main_refuses
bot_different_id_without_replace_refuses bot_same_bot_new_token_is_stored bot_same_token_skips_store
bot_post_write_check_that_cannot_run_is_a_fix bot_post_write_distinct_tokens_failure_restores_previous
bot_post_write_restore_failure_is_not_reported_as_restored
bot_enter_reuses_a_quoted_stored_token harness_ignores_a_telegram_env_from_the_launching_shell
bot_run1_prints_paste_line_and_exits_3
bot_run2_after_paste_reaches_done bot_existing_access_json_other_id_fixes_unchanged
bot_existing_access_json_bad_shape_fixes_before_the_prompt bot_rerun_without_token_never_pairs
bot_canary_token_absent_everywhere bot_done_rerun_changes_no_config_artifact bot_inputs_are_only_the_g2_set
bot_sigint_during_onboard_restarts_unit bot_mac_bootout_before_onboard
bot_pairing_stops_a_bridge_that_runs_without_a_unit token_with_trailing_space_is_trimmed
curl_exit_6_restarts_unit_and_fixes onboard_parse_real_producer onboard_parse_rejects_malformed
onboard_parse_rejects_duplicate_or_forged_line onboard_parse_rejects_chat_from_mismatch
peer_fresh_fresh_discovers_via_hello peer_confirmed_side_posts_hello_without_waiting peer_unconfirmed_pages_101_backlog
peer_confirmed_repoint_backlog_full_gives_fix_and_restarts_poller peer_no_offset_ack_on_confirmed_side
peer_gate_drops_plain_hello_real_gate peer_check_group_unknown_right_names_raw_field
peer_chatid_two_groups_newest_hello_after_start_or_pick peer_group_titles_with_a_pipe_stay_whole_in_the_pick peer_hello_post_follows_a_migrated_group peer_check_group_basic_group_fix
peer_check_group_member_change_info_fix peer_non_owner_fix_says_ask_owner
peer_checkpoint_written_after_confirm_before_status peer_unit_start_failure_keeps_checkpoint
peer_adoption_from_example_end_state_reaches_done peer_rerun_posts_exactly_one_hello
peer_repoint_runs_remove_then_add_confirm peer_pending_publication_survives_interruption
peer_allowfrom_written_by_setup_ts_only_digit_strings peer_canary_token_absent_everywhere
peer_sigint_during_discovery_restarts_poller renamed_peer_bot_keeps_name
peer_done_rerun_changes_no_config_artifact peer_inputs_are_only_the_g2_set
peer_remove_deletes_checkpoint_and_status_na peer_remove_interrupted_resumes peer_remove_with_nothing_set_up_is_done peer_remove_unreadable_peer_list_stops_before_any_change peer_remove_teardown_failure_is_a_fix peer_wait_pages_when_the_group_is_busy peer_remove_unit_delete_failure_is_a_fix peer_remove_reload_failure_is_a_fix peer_remove_one_of_two_restarts_poller peer_remove_one_of_two_interrupted_before_restart_finishes_that_removal peer_remove_declined_clears_its_note
peer_mac_bootout_then_bootstrap_order peer_mac_old_agent_is_not_accepted_as_the_updated_poller peer_changed_token_restarts_the_running_poller peer_mac_start_failure_names_the_poller_log peer_without_part1_fixes peer_bridge_equals_main_refuses
peer_different_bridge_id_without_replace_refuses peer_hello_timeout_fixes peer_wait_is_bounded_by_the_clock_not_by_the_loop_count peer_a_failed_merge_of_updates_leaves_no_temp_file peer_retry_after_a_timed_out_discovery_asks_for_a_fresh_hello peer_no_group_hello_fix_puts_the_rerun_before_the_hello peer_409_names_a_webhook_or_a_competing_poller peer_sole_candidate_needs_a_yes peer_hostile_username_refused
bun_shim_fails_when_it_cannot_write_peers_json systemctl_shim_changes_the_running_state_only_with_now
peer_name_second_collision_gets_3 peer_name_32_char_base_with_suffix_fits"

# ── run ─────────────────────────────────────────────────────────────────

main() {
    local c wanted=${1:-}
    for c in $CASES; do
        if [ -n "$wanted" ] && [ "$wanted" != "$c" ]; then continue; fi
        printf '%s\n' "$c" > "$WORK/current-case"
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
