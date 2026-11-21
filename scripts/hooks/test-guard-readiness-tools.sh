#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A && B || C is the ok/bad shape of the sibling suites; single quotes carry jq programs and stand-in source on purpose
# test-guard-readiness-tools.sh - direct suite for scripts/hooks/guard-readiness-tools.sh (C0s cycle 3).
#
# The guard is the readiness role's PreToolUse tool allow-list: in a readiness context (HIMMEL_READINESS exactly 1) only
# the tool names mcp__readiness__inspect and mcp__readiness__act pass, and only on a valid envelope. This suite runs the
# guard DIRECTLY with hand-built hook payloads in a fresh scratch HOME/TMPDIR/cwd; it proves the guard's own decision
# protocol and nothing else. It does NOT prove native tool dispatch, Claude Code delivering this hook, the supervisor's
# behaviour when this process is killed (SIGKILL), or the ActRequest semantics (the adapter's job).
#
# Order matters:
#   1. Harness controls. The row matrix is first run against stand-in guards that are WRONG on purpose, and the harness
#      must catch each one: a permissive stand-in must FAIL the forbidden rows, a blanket-denial stand-in must FAIL both
#      exact-name positives, a substring-match stand-in must FAIL the prefix/suffix/non-string-name rows, a stand-in that
#      fails open when jq is missing or crashes must FAIL the forced-failure rows. A harness that cannot see these is
#      vacuous, so a control that is not caught is a FAIL here.
#   2. Availability. A missing guard file is "UNAVAILABLE" (exit 3): that is availability, not causal security evidence.
#   3. The actual guard, row by row, then the zero-effect check and the plugin-copy byte parity.
#
# Row protocol observed exactly (the existing PreToolUse hook protocol, see guard-judge-writes.sh):
#   allow / generic context : exit 0, empty stdout, empty stderr
#   deny                    : exit 2, stdout one JSON {hookSpecificOutput:{hookEventName:"PreToolUse",
#                             permissionDecision:"deny",permissionDecisionReason:"readiness tool-deny: <code> (..."}},
#                             empty stderr; <code> is bad-envelope | oversize-input | not-allowed | guard-failure
#
# Usage: bash scripts/hooks/test-guard-readiness-tools.sh      Exit: 0 all ok, 1 a row/control failed, 3 guard/prerequisite unavailable.
# Platform: bash 3.2+ syntax, jq, coreutils; no network, no real HOME, nothing outside its mktemp directory is touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK="$HERE/guard-readiness-tools.sh"
PLUGIN_COPY="$HERE/../../marketplace/plugins/himmel-ops/scripts/guard-readiness-tools.sh"
BASH_ABS="$(command -v bash)"
JQ_ABS="$(command -v jq)"
[ -n "$BASH_ABS" ] && [ -n "$JQ_ABS" ] || { echo "FATAL: bash and jq must be on PATH" >&2; exit 1; }
REAL_PATH="$PATH"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/guard-readiness-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/home" HOOK_TMP="$TMP/hooktmp" CWD_DIR="$TMP/cwd" EMPTY_BIN="$TMP/emptybin"
PL="$TMP/pl" STUBS="$TMP/stubs" STANDINS="$TMP/standins" OUT="$TMP/stdout" ERR="$TMP/stderr"
mkdir -p "$FAKE_HOME" "$HOOK_TMP" "$CWD_DIR" "$EMPTY_BIN" "$PL" "$STUBS" "$STANDINS"
TO=() TERM_TO=()
if command -v timeout >/dev/null 2>&1; then TO=(timeout 15); TERM_TO=(timeout --preserve-status -s TERM 1); fi
BLOCK_FIFO="$TMP/blocked-stdin"
mkfifo "$BLOCK_FIFO" 2>/dev/null || TERM_TO=()
prereq_missing=0
if [ "${#TERM_TO[@]}" -eq 0 ]; then
    echo "SKIP: blocked-input signal control requires timeout and mkfifo"
    prereq_missing=1
fi
if [ "$(LC_ALL=C.UTF-8 "$BASH_ABS" -c 's="é"; printf "%s" "${#s}"' 2>/dev/null)" != 1 ]; then
    echo "SKIP: byte-versus-character controls require a working C.UTF-8 locale"
    prereq_missing=1
fi
if [ "$prereq_missing" -ne 0 ]; then
    echo "UNAVAILABLE: required guard-test controls cannot run; no reduced pass is claimed"
    exit 3
fi

pass=0 fail=0
ok() { echo "ok   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

NAME_INSPECT=mcp__readiness__inspect NAME_ACT=mcp__readiness__act
nm() { "$JQ_ABS" -nc --arg t "$2" '{tool_name:$t,tool_input:{}}' >"$PL/$1"; }   # nm <id> <tool_name string>
raw() { printf '%s' "$2" >"$PL/$1"; }                                           # raw <id> <exact text>
bytes() { printf '%b' "$2" >"$PL/$1"; }                                         # bytes <id> <printf %b escapes>
pad() { head -c "$1" /dev/zero | tr '\0' a; }                                   # pad <n> -> n ASCII bytes # read-sink-ok: reads /dev/zero, $1 is a byte count
# an envelope of exactly <total> bytes whose tool_name is <name>, padded inside tool_input
sized() {
    local id="$1" name="$2" total="$3" pre post n
    pre="{\"tool_name\":\"$name\",\"tool_input\":{\"pad\":\""
    post='"}}'
    n=$((total - ${#pre} - ${#post}))
    { printf '%s' "$pre"; pad "$n"; printf '%s' "$post"; } >"$PL/$id"
}
# the same, but the padding is 2-byte characters (an ASCII 'a' first when the byte count is odd): the byte count is
# <total> while the character count is about half, so a guard that counts characters instead of bytes is wrong
sized_mb() {
    local id="$1" name="$2" total="$3" pre post n
    pre="{\"tool_name\":\"$name\",\"tool_input\":{\"pad\":\""
    post='"}}'
    n=$((total - ${#pre} - ${#post}))
    { printf '%s' "$pre"; [ $((n % 2)) = 1 ] && printf a; yes $'\xc3\xa9' 2>/dev/null | head -n $((n / 2)) | tr -d '\n'; printf '%s' "$post"; } >"$PL/$id"
}

nm in-inspect "$NAME_INSPECT"
nm in-act "$NAME_ACT"
raw in-minimal "{\"tool_name\":\"$NAME_INSPECT\"}"
"$JQ_ABS" -nc '{session_id:"11111111-2222-3333-4444-555555555555",transcript_path:"/tmp/x.jsonl",cwd:"/tmp/w",permission_mode:"auto",hook_event_name:"PreToolUse",tool_name:"mcp__readiness__act",tool_input:{op:"label",tool_name:"Bash",nested:{tool_name:"Read"}},tool_use_id:"toolu_01"}' >"$PL/in-full"
printf ' \r\n\t{ "tool_input" : { "k" : [1, 2, {"a": null}] } ,\n  "tool_name" : "%s" }\r\n\n' "$NAME_ACT" >"$PL/in-ws-padded"
sized in-at-limit "$NAME_INSPECT" 262144
sized in-over-limit "$NAME_INSPECT" 262145
sized in-1mib "$NAME_ACT" 1048576
sized in-over-limit-forbidden Bash 262145
sized_mb in-at-limit-mb "$NAME_INSPECT" 262144
sized_mb in-over-limit-mb "$NAME_INSPECT" 262150
nm in-bash Bash
nm in-empty-name ""
raw in-empty ""
raw in-ws-only $' \n\t '
raw in-nonjson "$NAME_INSPECT"
raw in-truncated "{\"tool_name\":\"$NAME_INSPECT\""
raw in-trailing-comma "{\"tool_name\":\"$NAME_INSPECT\",}"
raw in-single-quotes "{'tool_name':'$NAME_INSPECT'}"
raw in-unquoted-key "{tool_name:\"$NAME_INSPECT\"}"
raw in-two-values-allowed-first "{\"tool_name\":\"$NAME_INSPECT\"}{\"tool_name\":\"Bash\"}"
raw in-two-values-allowed-last "{\"tool_name\":\"Bash\"}"$'\n'"{\"tool_name\":\"$NAME_INSPECT\"}"
raw in-trailing-garbage "{\"tool_name\":\"$NAME_INSPECT\"} x"
bytes in-nul-after "{\"tool_name\":\"$NAME_INSPECT\"}\\0"
bytes in-nul-before "\\0{\"tool_name\":\"$NAME_INSPECT\"}"
bytes in-nul-inside "{\"tool_name\":\"$NAME_INSPECT\",\"x\":\"a\\0b\"}"
raw in-null "null"
raw in-string "\"$NAME_INSPECT\""
raw in-number "42"
raw in-true "true"
raw in-array-wrapped "[{\"tool_name\":\"$NAME_INSPECT\"}]"
raw in-empty-object "{}"
raw in-no-tool-name '{"tool_input":{}}'
raw in-name-null '{"tool_name":null}'
raw in-name-array "{\"tool_name\":[\"$NAME_INSPECT\"]}"
raw in-name-object "{\"tool_name\":{\"name\":\"$NAME_INSPECT\"}}"
raw in-name-number '{"tool_name":42}'
raw in-name-true '{"tool_name":true}'
raw in-name-false '{"tool_name":false}'
raw in-key-upper "{\"TOOL_NAME\":\"$NAME_INSPECT\"}"
raw in-key-camel "{\"toolName\":\"$NAME_INSPECT\"}"
raw in-key-space "{\"tool_name \":\"$NAME_INSPECT\"}"
raw in-name-only-nested "{\"tool_input\":{\"tool_name\":\"$NAME_INSPECT\"}}"
bytes in-binary '\x01\x02\xff\xfe\x80garbage'

mkdir -p "$STUBS/crash" "$STUBS/silent" "$STUBS/rc1" "$STUBS/early"
printf '#!/bin/sh\nexit 134\n' >"$STUBS/crash/jq"
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' >"$STUBS/silent/jq"
printf '#!/bin/sh\ncat >/dev/null\nprintf allow\nexit 1\n' >"$STUBS/rc1/jq"
printf '#!/bin/sh\nexit 4\n' >"$STUBS/early/jq"
chmod +x "$STUBS/crash/jq" "$STUBS/silent/jq" "$STUBS/rc1/jq" "$STUBS/early/jq"
DENY_LINE='printf '"'"'{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"readiness tool-deny: not-allowed (stand-in) - x"}}\n'"'"
{ echo '#!/usr/bin/env bash'; echo 'cat >/dev/null 2>&1'; echo 'exit 0'; } >"$STANDINS/permissive.sh"
{ echo '#!/usr/bin/env bash'; echo 'cat >/dev/null 2>&1'; echo "$DENY_LINE"; echo 'exit 2'; } >"$STANDINS/blanket.sh"
{
    echo '#!/usr/bin/env bash'
    echo 'input=$(cat 2>/dev/null)'
    echo 'case "$input" in *mcp__readiness__inspect*|*mcp__readiness__act*) exit 0 ;; esac'
    echo "$DENY_LINE"; echo 'exit 2'
} >"$STANDINS/substring.sh"
{
    echo '#!/usr/bin/env bash'
    echo '[ "${HIMMEL_READINESS-}" = 1 ] || exit 0'
    echo 'command -v jq >/dev/null 2>&1 || exit 0'
    echo 'n=$(jq -r ".tool_name" 2>/dev/null) || exit 0'
    echo 'case "$n" in mcp__readiness__inspect|mcp__readiness__act) exit 0 ;; esac'
    echo "$DENY_LINE"; echo 'exit 2'
} >"$STANDINS/failopen.sh"

R_ID=() R_CLS=() R_EXP=() R_RSN=() R_LBL=() R_PL=() R_MK=() R_ENV=() R_IO=() R_RES=()
add() { # add <id> <class> <expect> <reason> <label> <payload id> <marker> <env mode> <io mode>
    [ -f "$PL/$6" ] || { echo "FATAL: row $1 names a payload that does not exist: $6" >&2; exit 1; }
    R_ID+=("$1"); R_CLS+=("$2"); R_EXP+=("$3"); R_RSN+=("$4"); R_LBL+=("$5"); R_PL+=("$PL/$6"); R_MK+=("$7"); R_ENV+=("$8"); R_IO+=("$9"); R_RES+=(0)
}
pos() { add "pos-$1" pos allow - "$2" "$3" 1 normal "${4:-normal}"; }                  # pos <id> <label> <payload> [io]
neg() { add "neg-$1" neg deny "$2" "$3" "$4" 1 normal normal; }                          # neg <id> <reason> <label> <payload>
gen() { add "gen-$1" gen generic - "$2" "$3" "${4:-UNSET}" normal normal; }              # gen <id> <label> <payload> [marker]
frc() { add "fail-$1" fail deny "$2" "$3" "$4" 1 "$5" "${6:-normal}"; }                  # frc <id> <reason> <label> <payload> <env> [io]

# the two exact names and the valid-envelope shapes that must pass in a readiness context
pos inspect "exact name mcp__readiness__inspect" in-inspect
pos act "exact name mcp__readiness__act" in-act
pos minimal-envelope "exact name, no tool_input (the guard does not judge ActRequest semantics)" in-minimal
pos full-envelope "realistic hook envelope; nested tool_name keys inside tool_input are data, not the tool" in-full
pos whitespace-padded "JSON with CR/LF/tab padding and reordered keys" in-ws-padded
pos at-limit "valid envelope of exactly 262144 bytes" in-at-limit
pos at-limit-pipe "valid envelope of exactly 262144 bytes delivered through a pipe" in-at-limit pipe

add pos-at-limit-multibyte pos allow - "exactly 262144 bytes of 2-byte characters (bytes are counted, not characters), UTF-8 locale" in-at-limit-mb 1 utf8 normal

# malformed input classes: every one denies
neg empty bad-envelope "empty stdin" in-empty
neg ws-only bad-envelope "whitespace-only stdin" in-ws-only
neg nonjson bad-envelope "a bare allowed name that is not JSON" in-nonjson
{ printf '?'; pad 262143; } >"$PL/in-large-invalid"
neg large-invalid bad-envelope "early JSON rejection with a full bounded input keeps stderr empty" in-large-invalid
neg truncated bad-envelope "truncated JSON" in-truncated
neg trailing-comma bad-envelope "trailing comma" in-trailing-comma
neg single-quotes bad-envelope "single-quoted pseudo JSON" in-single-quotes
neg unquoted-key bad-envelope "unquoted key" in-unquoted-key
neg two-values-allowed-first bad-envelope "two JSON values, the allowed one first" in-two-values-allowed-first
neg two-values-allowed-last bad-envelope "two JSON values, the allowed one last" in-two-values-allowed-last
neg trailing-garbage bad-envelope "valid object then trailing garbage" in-trailing-garbage
neg nul-after bad-envelope "valid object then a NUL byte" in-nul-after
neg nul-before bad-envelope "a NUL byte then a valid object" in-nul-before
neg nul-inside bad-envelope "a NUL byte inside the object" in-nul-inside
neg binary bad-envelope "binary garbage" in-binary
neg top-null bad-envelope "top-level null" in-null
neg top-string bad-envelope "top-level string equal to an allowed name" in-string
neg top-number bad-envelope "top-level number" in-number
neg top-true bad-envelope "top-level boolean" in-true
neg top-array bad-envelope "top-level array wrapping an allowed envelope" in-array-wrapped
neg empty-object bad-envelope "empty object (tool_name missing)" in-empty-object
neg no-tool-name bad-envelope "tool_name missing" in-no-tool-name
neg name-only-nested bad-envelope "an allowed name only nested inside tool_input" in-name-only-nested
neg name-null bad-envelope "tool_name null" in-name-null
neg name-array bad-envelope "tool_name an array holding an allowed name" in-name-array
neg name-object bad-envelope "tool_name an object" in-name-object
neg name-number bad-envelope "tool_name a number" in-name-number
neg name-true bad-envelope "tool_name true" in-name-true
neg name-false bad-envelope "tool_name false" in-name-false
neg key-upper bad-envelope "key TOOL_NAME" in-key-upper
neg key-camel bad-envelope "key toolName" in-key-camel
neg key-space bad-envelope "key with a trailing space" in-key-space

neg over-limit oversize-input "valid allowed envelope of 262145 bytes" in-over-limit
neg over-limit-pipe oversize-input "valid allowed envelope of 262145 bytes through a pipe" in-over-limit
add neg-over-limit-forbidden neg deny oversize-input "forbidden-name envelope of 262145 bytes" in-over-limit-forbidden 1 normal normal
neg 1mib oversize-input "valid allowed envelope of 1 MiB" in-1mib
add neg-over-limit-multibyte neg deny oversize-input "262150 bytes but only about 131000 characters (bytes, not characters), UTF-8 locale" in-over-limit-mb 1 utf8 normal
add neg-endless neg deny oversize-input "an endless non-NUL stdin stream is bounded, not drained" in-empty 1 normal endless

# names: each is a valid envelope with a string tool_name that is not exactly one of the two
i=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    i=$((i + 1)); key="${line%%|*}"; val="${line#*|}"
    nm "nm$i" "$val"
    neg "name-$key" not-allowed "tool_name $key" "nm$i"
done <<'EOF'
case-MCP|MCP__readiness__inspect
case-server|mcp__Readiness__inspect
case-tool|mcp__readiness__Inspect
case-act-upper|mcp__readiness__ACT
prefix-x|xmcp__readiness__inspect
prefix-underscore|_mcp__readiness__inspect
prefix-plugin|plugin_mcp__readiness__inspect
prefix-plugin-server|mcp__plugin_himmel-ops_readiness__inspect
suffix-digit|mcp__readiness__inspect2
suffix-x|mcp__readiness__inspect_x
suffix-s|mcp__readiness__acts
suffix-dunder|mcp__readiness__inspect__
suffix-comma-list|mcp__readiness__inspect,mcp__readiness__act
suffix-space-list|mcp__readiness__inspect mcp__readiness__act
suffix-star|mcp__readiness__inspect*
ws-inner-space|mcp__readiness__ inspect
foreign-server|mcp__other__inspect
foreign-readiness_x|mcp__readiness_x__inspect
foreign-readinessx|mcp__readinessx__act
foreign-no-tool|mcp__readiness__
foreign-no-tool-sep|mcp__readiness
foreign-finish|mcp__readiness__finish
foreign-label|mcp__readiness__label
foreign-qmd|mcp__plugin_qmd_qmd__query
foreign-slack|mcp__claude_ai_Slack__slack_send_message
foreign-glob|mcp__*
foreign-injection|ZZ-INJECT-MARKER-ZZ (the reason text must never echo the payload)
bare-inspect|inspect
bare-act|act
bare-readiness|readiness__inspect
native-Bash|Bash
native-bash-lower|bash
native-Read|Read
native-Write|Write
native-Edit|Edit
native-MultiEdit|MultiEdit
native-NotebookEdit|NotebookEdit
native-Glob|Glob
native-Grep|Grep
native-WebFetch|WebFetch
native-Task|Task
native-Agent|Agent
native-ToolSearch|ToolSearch
unknown-DeferredToolPlaceholder|DeferredToolPlaceholder
unknown-empty|
EOF
# names the line-oriented table cannot carry (whitespace is written with $'..' so no editor can strip it)
nm w-lead-sp $' mcp__readiness__inspect'; neg name-ws-leading-space not-allowed "tool_name with a leading space" w-lead-sp
nm w-trail-sp $'mcp__readiness__inspect '; neg name-ws-trailing-space not-allowed "tool_name with a trailing space" w-trail-sp
nm w-trail-tab $'mcp__readiness__act\t'; neg name-ws-trailing-tab not-allowed "tool_name with a trailing tab" w-trail-tab
nm w-only-sp " "; neg name-only-space not-allowed "tool_name is a single space" w-only-sp
nm w-nl "$NAME_INSPECT"$'\n'; neg name-ws-real-newline not-allowed "tool_name with a real trailing newline (not stripped by command substitution)" w-nl
nm w-cr "$NAME_INSPECT"$'\r'; neg name-ws-cr not-allowed "tool_name with a trailing CR" w-cr
nm w-nbsp "$NAME_INSPECT"$'\xc2\xa0'; neg name-ws-nbsp not-allowed "tool_name with a trailing NBSP" w-nbsp
nm w-cyr "mcp__readiness__inspe"$'\xd0\xb0'"t"; neg name-cyrillic not-allowed "tool_name with a Cyrillic look-alike letter" w-cyr
raw w-esc-nul "{\"tool_name\":\"$NAME_INSPECT\\u0000\"}"; neg name-esc-nul not-allowed "tool_name with an escaped NUL suffix" w-esc-nul
raw w-esc-name "{\"tool_name\":\"mcp__readiness__\\u0069nspect\"}"; pos escaped-name "an escaped letter that decodes to the exact name (JSON-equivalent)" w-esc-name

# forced guard failure inside a readiness context: all deny, and none lets an allowed-looking envelope through
frc nojq guard-failure "jq not on PATH, allowed envelope" in-inspect nojq
frc jq-crash guard-failure "jq crashes (rc 134), allowed envelope" in-inspect stub-crash
frc jq-silent guard-failure "jq exits 0 and prints nothing, allowed envelope" in-inspect stub-silent
frc jq-rc1-allow-text guard-failure "jq prints the allow verdict but exits 1, allowed envelope" in-inspect stub-rc1
frc jq-exits-before-read bad-envelope "jq exits before reading bounded input: producer stderr stays empty" in-at-limit stub-early
frc stdin-unreadable bad-envelope "stdin unreadable (a directory: read error, not EOF)" in-inspect normal noin
add fail-term-blocked fail deny guard-failure "SIGTERM while blocked reading stdin: still the deny JSON, exit 2" in-empty 1 normal blocked
add fail-stdout-closed fail deny rcOnly "deny still exits 2 with stdout closed" in-bash 1 normal noout
add fail-stdout-reader-gone fail deny rcOnly "deny still exits 2 after the stdout pipe reader exits" in-bash 1 normal noreader
add fail-stdout-closed-allow fail allow rcOnly "an allowed call with stdout closed still exits 0" in-inspect 1 normal noout

# generic context (marker not exactly 1): the existing protocol, silent exit 0 whatever the payload
gen inspect "marker unset, allowed name" in-inspect
gen bash "marker unset, native Bash" in-bash
gen empty "marker unset, empty stdin" in-empty
gen nonjson "marker unset, non-JSON" in-nonjson
gen binary "marker unset, binary garbage" in-binary
gen over-limit "marker unset, over 256 KiB" in-over-limit
gen marker-0 "marker 0" in-bash 0
gen marker-empty "marker set but empty" in-bash EMPTY
gen marker-yes "marker yes" in-bash yes
gen marker-true "marker true" in-bash true
gen marker-01 "marker 01 (not exactly 1)" in-bash 01
gen marker-1space "marker '1 ' (not exactly 1)" in-bash "1 "
gen marker-space1 "marker ' 1' (not exactly 1)" in-bash " 1"
gen marker-11 "marker 11" in-bash 11

GOT_RC=0 WHY=""
exec_row() { # exec_row <index> <hook> -> GOT_RC, $OUT, $ERR
    local i="$1" hook="$2" pathv="$REAL_PATH"
    local mk="${R_MK[$i]}" env_mode="${R_ENV[$i]}" io="${R_IO[$i]}" pl="${R_PL[$i]}"
    local -a ev
    case "$env_mode" in
        nojq) pathv="$EMPTY_BIN" ;;
        utf8) ;;
        stub-*) pathv="$STUBS/${env_mode#stub-}:$REAL_PATH" ;;
    esac
    ev=(PATH="$pathv" HOME="$FAKE_HOME" TMPDIR="$HOOK_TMP")
    [ "$env_mode" = utf8 ] && ev+=(LC_ALL=C.UTF-8)
    case "$mk" in
        UNSET) ;;
        EMPTY) ev+=(HIMMEL_READINESS=) ;;
        *) ev+=(HIMMEL_READINESS="$mk") ;;
    esac
    : >"$OUT"; : >"$ERR"
    case "$io" in
        normal) ( cd "$CWD_DIR" && "${TO[@]+"${TO[@]}"}" env -i "${ev[@]}" "$BASH_ABS" "$hook" <"$pl" >"$OUT" 2>"$ERR" ); GOT_RC=$? ;;
        pipe) cat "$pl" | ( cd "$CWD_DIR" && "${TO[@]+"${TO[@]}"}" env -i "${ev[@]}" "$BASH_ABS" "$hook" >"$OUT" 2>"$ERR" ); GOT_RC=${PIPESTATUS[1]} ;;
        endless)
            # The guard under test gets a truly endless stream (it must stop reading at its bound). A stand-in that
            # drains stdin would never return and would buffer without limit, so it only gets a finite 4 MiB stream.
            if [ "$hook" = "$HOOK" ]; then
                yes 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 2>/dev/null | ( cd "$CWD_DIR" && "${TO[@]+"${TO[@]}"}" env -i "${ev[@]}" "$BASH_ABS" "$hook" >"$OUT" 2>"$ERR" )
            else
                head -c 4194304 /dev/zero | tr '\0' a | ( cd "$CWD_DIR" && "${TO[@]+"${TO[@]}"}" env -i "${ev[@]}" "$BASH_ABS" "$hook" >"$OUT" 2>"$ERR" )
            fi
            GOT_RC=${PIPESTATUS[1]} ;;
        noin) ( cd "$CWD_DIR" && "${TO[@]+"${TO[@]}"}" env -i "${ev[@]}" "$BASH_ABS" "$hook" <"$CWD_DIR" >"$OUT" 2>"$ERR" ); GOT_RC=$? ;;  # stdin is a directory: a read ERROR, not EOF
        blocked)
            # stdin is a FIFO nobody writes: the guard blocks in its read until SIGTERM (the held read/write end keeps it open)
            exec 8<>"$BLOCK_FIFO"
            ( cd "$CWD_DIR" && "${TERM_TO[@]}" env -i "${ev[@]}" "$BASH_ABS" "$hook" <"$BLOCK_FIFO" >"$OUT" 2>"$ERR" ); GOT_RC=$?
            exec 8>&- ;;
        noout) ( cd "$CWD_DIR" && "${TO[@]+"${TO[@]}"}" env -i "${ev[@]}" "$BASH_ABS" "$hook" <"$pl" >&- 2>"$ERR" ); GOT_RC=$? ;;
        noreader)
            # Wait until the only reader has exited before invoking the guard.
            rm -f "$TMP/stdout-pipe"
            mkfifo "$TMP/stdout-pipe"
            ( exec 8<"$TMP/stdout-pipe" ) &
            reader_pid=$!
            exec 9>"$TMP/stdout-pipe"
            wait "$reader_pid"
            ( cd "$CWD_DIR" && "${TO[@]+"${TO[@]}"}" env -i "${ev[@]}" "$BASH_ABS" "$hook" <"$pl" >&9 2>"$ERR" ); GOT_RC=$?
            exec 9>&-
            rm -f "$TMP/stdout-pipe" ;;
    esac
}

judge_row() { # judge_row <index> -> 0 matches the protocol, else 1 with WHY set
    local i="$1"
    local exp="${R_EXP[$i]}" rsn="${R_RSN[$i]}" io="${R_IO[$i]}"
    WHY=""
    case "$exp" in
        allow | generic)
            [ "$GOT_RC" = 0 ] || { WHY="rc=$GOT_RC, want 0"; return 1; }
            [ "$io" = noout ] || [ ! -s "$OUT" ] || { WHY="stdout not empty"; return 1; }
            ;;
        deny)
            [ "$GOT_RC" = 2 ] || { WHY="rc=$GOT_RC, want 2"; return 1; }
            if [ "$io" != noout ] && [ "$io" != noreader ]; then
                "$JQ_ABS" -se --arg c "$rsn" 'length == 1 and (.[0] | keys == ["hookSpecificOutput"]) and (.[0].hookSpecificOutput
                    | (keys == ["hookEventName","permissionDecision","permissionDecisionReason"]) and .hookEventName == "PreToolUse"
                    and .permissionDecision == "deny" and (.permissionDecisionReason | type == "string"
                    and test("^readiness tool-deny: " + $c + " \\([^()]*\\) - the readiness role may call only mcp__readiness__inspect and mcp__readiness__act$")
                    and (contains("ZZ-INJECT") | not)))' "$OUT" >/dev/null 2>&1 \
                    || { WHY="stdout is not the exact deny JSON with code $rsn: $(head -c 200 "$OUT")"; return 1; }
            fi
            ;;
    esac
    [ ! -s "$ERR" ] || { WHY="stderr not empty: $(head -c 120 "$ERR")"; return 1; }
    return 0
}

run_rows() { # run_rows <hook> <report 1|0>
    local hook="$1" report="$2" i n="${#R_ID[@]}"
    for ((i = 0; i < n; i++)); do
        exec_row "$i" "$hook"
        if judge_row "$i"; then
            R_RES[i]=0
            [ "$report" = 1 ] && ok "${R_CLS[$i]}: ${R_LBL[$i]}"
        else
            R_RES[i]=1
            [ "$report" = 1 ] && bad "${R_CLS[$i]}: ${R_LBL[$i]} - $WHY"
        fi
    done
}
count() { # count <class|-> <bad|all> : rows of a class (or every row) that failed / exist
    local c="$1" what="$2" i n="${#R_ID[@]}" t=0
    for ((i = 0; i < n; i++)); do
        { [ "$c" = - ] || [ "${R_CLS[$i]}" = "$c" ]; } || continue
        if [ "$what" = all ] || [ "${R_RES[$i]}" = 1 ]; then t=$((t + 1)); fi
    done
    echo "$t"
}
res() { local i n="${#R_ID[@]}"; for ((i = 0; i < n; i++)); do [ "${R_ID[$i]}" = "$1" ] && { echo "${R_RES[$i]}"; return; }; done; echo missing; }

sz() { wc -c <"$PL/$1" | tr -d ' '; }
[ "$(sz in-at-limit)" = 262144 ] && ok "fixture: at-limit envelope is exactly 262144 bytes" || bad "fixture: at-limit envelope is $(sz in-at-limit) bytes"
[ "$(sz in-over-limit)" = 262145 ] && ok "fixture: over-limit envelope is exactly 262145 bytes" || bad "fixture: over-limit envelope is $(sz in-over-limit) bytes"
[ "$(sz in-1mib)" = 1048576 ] && ok "fixture: 1 MiB envelope is exactly 1048576 bytes" || bad "fixture: 1 MiB envelope is $(sz in-1mib) bytes"
[ "$(sz w-nl)" -gt "$(sz in-inspect)" ] && ok "fixture: the trailing-newline name payload carries the newline" || bad "fixture: the trailing-newline name payload lost its newline"

echo "--- harness controls: wrong stand-in guards must be caught by this harness"
total_rows="$(count - all)"
run_rows "$STANDINS/permissive.sh" 0
neg_n="$(count neg all)"; fail_n="$(count fail all)"
if [ "$(count pos bad)" = 0 ] && [ "$(count gen bad)" = 0 ] && [ "$(count neg bad)" = "$neg_n" ] && [ "$(res fail-nojq)" = 1 ] && [ "$(res fail-jq-crash)" = 1 ] && [ "$(res neg-over-limit)" = 1 ]; then
    ok "control: permissive stand-in (always exit 0) is caught - all $neg_n forbidden rows fail, no positive fails, $total_rows rows run"
else
    bad "control: permissive stand-in NOT caught (pos bad=$(count pos bad) gen bad=$(count gen bad) neg bad=$(count neg bad)/$neg_n fail bad=$(count fail bad)/$fail_n)"
fi
run_rows "$STANDINS/blanket.sh" 0
if [ "$(res pos-inspect)" = 1 ] && [ "$(res pos-act)" = 1 ] && [ "$(count pos bad)" = "$(count pos all)" ] && [ "$(res gen-inspect)" = 1 ]; then
    ok "control: blanket-denial stand-in is caught - both exact-name positives fail ($(count pos bad)/$(count pos all) positives, generic context too)"
else
    bad "control: blanket-denial stand-in NOT caught (pos-inspect=$(res pos-inspect) pos-act=$(res pos-act) gen-inspect=$(res gen-inspect))"
fi
run_rows "$STANDINS/substring.sh" 0
if [ "$(res pos-inspect)" = 0 ] && [ "$(res pos-act)" = 0 ] && [ "$(res neg-name-suffix-x)" = 1 ] && [ "$(res neg-name-prefix-x)" = 1 ] && [ "$(res neg-name-array)" = 1 ] && [ "$(res neg-name-only-nested)" = 1 ]; then
    ok "control: substring-match stand-in is caught - suffix, prefix, non-string and nested-name rows fail, exact names still pass"
else
    bad "control: substring-match stand-in NOT caught (suffix=$(res neg-name-suffix-x) prefix=$(res neg-name-prefix-x) array=$(res neg-name-array) nested=$(res neg-name-only-nested))"
fi
run_rows "$STANDINS/failopen.sh" 0
if [ "$(res pos-inspect)" = 0 ] && [ "$(res fail-nojq)" = 1 ] && [ "$(res fail-jq-crash)" = 1 ] && [ "$(res neg-nonjson)" = 1 ] && [ "$(res neg-empty)" = 1 ]; then
    ok "control: fail-open stand-in is caught - missing/crashing jq and unparseable input rows fail, the exact name still passes"
else
    bad "control: fail-open stand-in NOT caught (nojq=$(res fail-nojq) crash=$(res fail-jq-crash) nonjson=$(res neg-nonjson) empty=$(res neg-empty))"
fi

if [ ! -f "$HOOK" ]; then
    echo "UNAVAILABLE: $HOOK does not exist - availability, not causal security evidence (controls above ran)"
    echo
    echo "RESULTS: $pass passed, $fail failed, guard missing"
    exit 3
fi

echo "--- the actual guard ($(wc -c <"$HOOK" | tr -d ' ') bytes), $total_rows rows"
run_rows "$HOOK" 1
for c in pos neg gen fail; do echo "rows $c: $(count "$c" all) run, $(count "$c" bad) failed"; done

left="$(find "$FAKE_HOME" "$HOOK_TMP" "$CWD_DIR" -mindepth 1 2>/dev/null | head -5)"
[ -z "$left" ] && ok "zero effects: the scratch HOME, TMPDIR and cwd are still empty after every row" || bad "zero effects: the guard left files behind: $left"

if [ -f "$PLUGIN_COPY" ] && cmp -s "$HOOK" "$PLUGIN_COPY"; then
    ok "plugin copy is byte-identical"
else
    bad "plugin copy is missing or differs: $PLUGIN_COPY"
fi

echo
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
