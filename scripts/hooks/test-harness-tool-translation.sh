#!/usr/bin/env bash
# Suite for the harness tool translation: a Grok or Cursor tool call reaches
# himmel's guards in Claude's shape through each shared hook entry point.
#
# Usage: bash scripts/hooks/test-harness-tool-translation.sh
#
# Entry points:
#   project  scripts/hooks/run-hook-with-bash.js, the .claude/settings.json chains
#   plugin   marketplace/plugins/himmel-ops/hooks/run-hook-with-bash.js, its hooks.json
#   guard    marketplace/plugins/himmel-guard/hooks/hooks.json, its registration
#   user     scripts/hooks/guardrail-skip-in-himmel.js, the user-level forwarding
#
# Envelopes are real captures in fixtures/harness-tool-translation/: Grok 1.0.92
# (2026-11-25 write; 2026-11-26 shell, read, grep, search_replace and a t3-code
# tool through use_tool) and Cursor CLI 2026.11.22 (Shell, Read, Write). A row
# swaps only the tool input into the captured envelope; its Claude twin is the
# same envelope with Claude's tool name and input.
#
# Sections:
#   matcher      the registration a row runs through selects the native name:
#                its matcher carries the Claude term seen live to fire for it.
#                Grok tests Claude terms against its native names (Bash ->
#                run_terminal_command, Read -> read_file, Grep -> grep, Edit and
#                Write -> search_replace and write) and an mcp__ matcher against
#                mcp__<server>__<tool>; Cursor fires a Bash matcher on Shell.
#                Seen live: Grok 2026-11-26, Cursor 2026-11-25.
#   verdict      canary .env reads and docker --privileged are denied, the
#                edit-on-main rows stay denied (control), an ordinary shell
#                command and repo read pass (controls), the Grok use_tool call
#                reaches guard-t3-thread-tools.sh; the user wrapper runs in a
#                non-himmel project, and skips inside himmel (control)
#   parity       each member gives the native call the verdict it gives the
#                matching Claude call, allow and approval members included; a
#                member whose every trigger passes for Claude is printed as a
#                NOTE, since its parity proves nothing
#
# A verdict is deny (exit 2 or a deny decision), allow, ask, pass (exit 0 with
# no decision) or rc<N>. A group's verdict is the strictest of its
# registrations. Rows run in a feature-branch repo, edit-on-main rows in a repo
# on main; the user wrapper and himmel-guard rows run in a project with no
# .claude/settings.json, so neither skips; guard-t3-thread-tools.sh reads a T3
# settings file with no provider instances.
#   passthrough  a member sees an unknown or Claude tool call unchanged, and a
#                native call in Claude's shape
#   fail-closed  each entry point, copied with its table missing, unreadable or
#                unparseable, refuses a tool call; the same copy with the table
#                passes it (mutation control)
#
# Exit codes: 0 all rows passed, 1 at least one failed.
# shellcheck disable=SC2016  # rows carry command TEXT; nothing expands there
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
FIX="$HERE/fixtures/harness-tool-translation"
RUNNER="$HERE/run-hook-with-bash.js"
WRAPPER="$HERE/guardrail-skip-in-himmel.js"
TABLE_REL="lib/harness-tool-map.json"
PROJECT_SETTINGS="$ROOT/.claude/settings.json"
OPS="$ROOT/marketplace/plugins/himmel-ops"
GUARD="$ROOT/marketplace/plugins/himmel-guard"
WIRER="$ROOT/scripts/lib/wire-pretooluse-hooks.sh"

command -v node >/dev/null 2>&1 || { echo "FAIL fixture: node not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL fixture: jq not found"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL fixture: git not found"; exit 1; }

FAILED=0
PASSED=0
pass() { PASSED=$((PASSED + 1)); echo "PASS $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL $1"; }

SB=$(mktemp -d "${TMPDIR:-/tmp}/harness-tool-translation.XXXXXX") || { echo "FAIL fixture: mktemp"; exit 1; }
trap 'chmod -R u+rwX "$SB" 2>/dev/null; rm -rf "$SB"' EXIT
mkdir -p "$SB/home" "$SB/tmp" "$SB/elsewhere" "$SB/t3/userdata"
printf '{"providerInstances":{}}\n' > "$SB/t3/userdata/settings.json"

mk_repo() {
    git init -q -b "$2" "$1" && printf 'hello\n' > "$1/readme.txt" \
        && git -C "$1" -c user.email=t@t -c user.name=t add readme.txt \
        && git -C "$1" -c user.email=t@t -c user.name=t commit -q -m init
}
mk_repo "$SB/work" feature/fixture || { echo "FAIL fixture: git repo"; exit 1; }
mk_repo "$SB/mainrepo" main || { echo "FAIL fixture: git repo on main"; exit 1; }
CANARY="$SB/elsewhere/.env"
printf 'HIMMEL_PROBE_CANARY=not-a-real-secret-1073\n' > "$CANARY"
WORK_FILE="$SB/work/readme.txt"
MAIN_FILE="$SB/mainrepo/readme.txt"
NONHIMMEL="$SB/work"

DOCKER_CMD='docker run --privileged --rm himmel-probe-does-not-exist:0 true'
ORDINARY_CMD='echo himmel-probe-1073'

SEQ=0
payload() {
    local h=$1 kind=$2 a=${3:-} b=${4:-} env name input
    SEQ=$((SEQ + 1))
    case "$h" in
        grok|claude-grok) env=grok ;;
        *) env=cursor ;;
    esac
    case "$env:$kind" in
        grok:shell)  name=run_terminal_command; input=$(jq -nc --arg c "$a" '{command:$c, description:"probe"}') ;;
        grok:read)   name=read_file; input=$(jq -nc --arg p "$a" '{target_file:$p}') ;;
        grok:grep)   name="grep"; input=$(jq -nc --arg p "$a" '{pattern:"HIMMEL", path:$p}') ;;
        grok:edit)   name=search_replace; input=$(jq -nc --arg p "$a" '{file_path:$p, old_string:"hello", new_string:"hi"}') ;;
        grok:write)  name="write"; input=$(jq -nc --arg p "$a" '{file_path:$p, content:"probe"}') ;;
        grok:t3)     name="t3-code__$a"; input=$(jq -nc --arg n "t3-code__$a" --argjson i "$b" '{tool_name:$n, tool_input:$i}') ;;
        cursor:shell) name=Shell; input=$(jq -nc --arg c "$a" '{command:$c, cwd:"", timeout:30000}') ;;
        cursor:read)  name=Read; input=$(jq -nc --arg p "$a" '{file_path:$p}') ;;
        cursor:write) name=Write; input=$(jq -nc --arg p "$a" '{file_path:$p, content:"probe"}') ;;
        *) echo "FAIL fixture: no $env shape for $kind"; exit 1 ;;
    esac
    case "$h" in
        claude-*)
            case "$kind" in
                shell) name=Bash; input=$(jq -nc --arg c "$a" '{command:$c, description:"probe"}') ;;
                read)  name=Read; input=$(jq -nc --arg p "$a" '{file_path:$p}') ;;
                grep)  name=Grep; input=$(jq -nc --arg p "$a" '{pattern:"HIMMEL", path:$p}') ;;
                edit)  name=Edit; input=$(jq -nc --arg p "$a" '{file_path:$p, old_string:"hello", new_string:"hi"}') ;;
                write) name=Write; input=$(jq -nc --arg p "$a" '{file_path:$p, content:"probe"}') ;;
                t3)    name="mcp__t3-code__$a"; input=$b ;;
            esac ;;
    esac
    local envelope
    case "$env:$kind" in
        grok:shell) envelope="$FIX/grok-run_terminal_command.json" ;;
        grok:read)  envelope="$FIX/grok-read_file.json" ;;
        grok:grep)  envelope="$FIX/grok-grep.json" ;;
        grok:edit)  envelope="$FIX/grok-search_replace.json" ;;
        grok:write) envelope="$FIX/grok-write.json" ;;
        grok:t3)    envelope="$FIX/grok-use_tool-t3.json" ;;
        cursor:shell) envelope="$FIX/cursor-Shell.json" ;;
        cursor:read)  envelope="$FIX/cursor-Read.json" ;;
        cursor:write) envelope="$FIX/cursor-Write.json" ;;
    esac
    jq -c --arg n "$name" --argjson i "$input" --arg sid "h1073-$h-$SEQ" --arg cwd "$SB/work" --arg claude "${h%%-*}" '
        .tool_name = $n | .tool_input = $i | .session_id = $sid
        | (if has("cwd") and .cwd != "" then .cwd = $cwd else . end)
        | (if has("workspaceRoot") then .workspaceRoot = $cwd else . end)
        | (if has("sessionId") then .sessionId = $sid else . end)
        | (if $claude == "claude" then del(.toolName, .toolInput)
           elif has("toolName") then .toolName = $n | .toolInput = $i else . end)' \
        "$envelope" > "$SB/p.json" || { echo "FAIL fixture: jq payload $h $kind"; exit 1; }
}

hook_env() {
    env -i PATH="$PATH" HOME="$SB/home" TMPDIR="$SB/tmp" T3CODE_HOME="$SB/t3" \
        CLAUDE_PROJECT_DIR="${PROJECT_DIR:-$ROOT}" CLAUDE_PLUGIN_ROOT="${PLUGIN_ROOT:-$OPS}" \
        GUARDRAIL_BASH="$(command -v bash)" "$@"
}
decide() {
    local d
    d=$(printf '%s' "$2" | jq -r 'select(type == "object") | .hookSpecificOutput.permissionDecision // empty' 2>/dev/null | tail -n 1)
    if [ "$1" = 2 ] || [ "$d" = deny ]; then V=deny
    elif [ "$1" != 0 ]; then V="rc$1"
    elif [ -n "$d" ]; then V=$d
    else V=pass
    fi
}
run_cmd() {
    local out rc
    out=$(cd "$SB/work" && hook_env sh -c "$1" < "$SB/p.json" 2>"$SB/err")
    rc=$?
    decide "$rc" "$out"
}
run_member() {
    local out rc
    out=$(cd "$SB/work" && hook_env node "$RUNNER" --chain "$1" < "$SB/p.json" 2>"$SB/err")
    rc=$?
    decide "$rc" "$out"
}
run_user() {
    local out rc
    out=$(cd "$SB/work" && PROJECT_DIR="${PROJECT_DIR:-$NONHIMMEL}" hook_env node "$WRAPPER" "$1" < "$SB/p.json" 2>"$SB/err")
    rc=$?
    decide "$rc" "$out"
}

reg_cmds() { jq -r --arg m "$2" '.hooks.PreToolUse[] | select(.matcher == $m) | .hooks[].command' "$1"; }
chain_members() {
    reg_cmds "$PROJECT_SETTINGS" "$1" | grep -o -E 'scripts/hooks/[A-Za-z0-9_.-]+\.sh' | awk '!seen[$0]++' \
        | while IFS= read -r m; do printf '%s\n' "$ROOT/$m"; done
}
run_group() {
    local cmds c best=pass
    cmds=$(reg_cmds "$1" "$2")
    [ -n "$cmds" ] || { V="no-registration"; return; }
    while IFS= read -r c; do
        run_cmd "$c"
        case "$V:$best" in
            deny:*) best=deny ;;
            ask:pass|ask:allow) best=ask ;;
            allow:pass) best=allow ;;
            rc*:pass|rc*:allow) best=$V ;;
        esac
    done <<EOF
$cmds
EOF
    V=$best
}

expect() {
    if [ "$V" = "$2" ]; then pass "$1"; else fail "$1 - want $2 got $V ($(head -c 300 "$SB/err" | tr '\n' ' '))"; fi
}
expect_not() {
    if [ "$V" != "$2" ] && [ "${V#rc}" = "$V" ]; then pass "$1"; else fail "$1 - got $V ($(head -c 300 "$SB/err" | tr '\n' ' '))"; fi
}

echo "== matcher: each registration selects the native name =="
term_selected() {
    local m=$1 t=$2
    case "|$m|" in *"|$t|"*) return 0 ;; esac
    case "$m" in *[!A-Za-z0-9_\|,\ -]*) printf '%s' "$t" | grep -q -E "$m" ;; *) return 1 ;; esac
}
matcher_row() {
    if [ -z "$(reg_cmds "$2" "$3")" ]; then fail "matcher: $1 has no '$3' registration"; return; fi
    if term_selected "$3" "$5"; then pass "matcher: $1 '$3' selects $4 (term $5)"
    else fail "matcher: $1 '$3' does not select $4 (term $5)"; fi
}
for row in \
    "run_terminal_command Bash" "Shell Bash"; do
    native=${row%% *}; term=${row#* }
    matcher_row project "$PROJECT_SETTINGS" Bash "$native" "$term"
    matcher_row plugin "$OPS/hooks/hooks.json" 'Bash|PowerShell' "$native" "$term"
    matcher_row guard "$GUARD/hooks/hooks.json" 'Bash|PowerShell' "$native" "$term"
done
matcher_row project "$PROJECT_SETTINGS" 'Read|Grep' read_file Read
matcher_row project "$PROJECT_SETTINGS" 'Read|Grep' grep Grep
matcher_row project "$PROJECT_SETTINGS" 'Edit|Write|MultiEdit|NotebookEdit' search_replace Edit
matcher_row project "$PROJECT_SETTINGS" 'Edit|Write|MultiEdit|NotebookEdit' write Write
matcher_row project "$PROJECT_SETTINGS" 'mcp__t3-code__.*' t3-code__t3_thread_list mcp__t3-code__t3_thread_list
for name in auto-approve-safe-bash block-edit-on-main block-read-secrets; do
    um=$(grep -o -E "\{\"name\":\"$name\",\"matcher\":\"[^\"]*\"" "$WIRER" | head -n 1 | sed -E 's/.*"matcher":"([^"]*)"$/\1/')
    [ -n "$um" ] || { fail "matcher: user wrapper spec for $name not found in $WIRER"; continue; }
    case "$name" in
        block-edit-on-main) terms="search_replace:Edit write:Write" ;;
        block-read-secrets) terms="run_terminal_command:Bash Shell:Bash read_file:Read grep:Grep" ;;
        *) terms="run_terminal_command:Bash Shell:Bash" ;;
    esac
    for t in $terms; do
        if term_selected "$um" "${t#*:}"; then pass "matcher: user $name '$um' selects ${t%%:*}"
        else fail "matcher: user $name '$um' does not select ${t%%:*}"; fi
    done
done

echo "== verdict: the DoD rows through each entry point =="
for h in claude-grok grok claude-cursor cursor; do
    payload "$h" shell "cat $CANARY"
    run_group "$PROJECT_SETTINGS" Bash;            expect "project Bash: $h cat <canary .env> is denied" deny
    payload "$h" shell "$DOCKER_CMD"
    run_group "$OPS/hooks/hooks.json" 'Bash|PowerShell'; expect "plugin Bash|PowerShell: $h docker run --privileged is denied" deny
    payload "$h" shell 'rm -rf /'
    PROJECT_DIR=$NONHIMMEL PLUGIN_ROOT=$GUARD run_group "$GUARD/hooks/hooks.json" 'Bash|PowerShell'
    expect "guard Bash|PowerShell: $h rm -rf / is denied" deny
    payload "$h" shell "cat $CANARY"
    run_user "$ROOT/scripts/hooks/block-read-secrets.sh"; expect "user block-read-secrets: $h cat <canary .env> is denied" deny

    payload "$h" shell "$ORDINARY_CMD"
    run_group "$PROJECT_SETTINGS" Bash;            expect_not "project Bash: $h ordinary shell passes" deny
    run_group "$OPS/hooks/hooks.json" 'Bash|PowerShell'; expect_not "plugin Bash|PowerShell: $h ordinary shell passes" deny
    PROJECT_DIR=$NONHIMMEL PLUGIN_ROOT=$GUARD run_group "$GUARD/hooks/hooks.json" 'Bash|PowerShell'
    expect_not "guard Bash|PowerShell: $h ordinary shell passes" deny
    run_user "$ROOT/scripts/hooks/block-read-secrets.sh"; expect "user block-read-secrets: $h ordinary shell passes" pass

    payload "$h" read "$CANARY"
    run_group "$PROJECT_SETTINGS" 'Read|Grep';     expect "project Read|Grep: $h read <canary .env> is denied" deny
    run_user "$ROOT/scripts/hooks/block-read-secrets.sh"; expect "user block-read-secrets: $h read <canary .env> is denied" deny
    payload "$h" read "$WORK_FILE"
    run_group "$PROJECT_SETTINGS" 'Read|Grep';     expect_not "project Read|Grep: $h ordinary repo read passes" deny
    run_user "$ROOT/scripts/hooks/block-read-secrets.sh"; expect "user block-read-secrets: $h ordinary repo read passes" pass

    payload "$h" write "$MAIN_FILE"
    run_group "$PROJECT_SETTINGS" 'Edit|Write|MultiEdit|NotebookEdit'; expect "project Edit|Write: $h write on main is denied (control)" deny
    run_user "$ROOT/scripts/hooks/block-edit-on-main.sh"; expect "user block-edit-on-main: $h write on main is denied (control)" deny
done
for h in claude-grok grok; do
    payload "$h" edit "$MAIN_FILE"
    run_group "$PROJECT_SETTINGS" 'Edit|Write|MultiEdit|NotebookEdit'; expect "project Edit|Write: $h edit on main is denied (control)" deny
    run_user "$ROOT/scripts/hooks/block-edit-on-main.sh"; expect "user block-edit-on-main: $h edit on main is denied (control)" deny
    payload "$h" t3 t3_thread_launch '{"title":"fixture-chief","prompt":"noop"}'
    run_group "$PROJECT_SETTINGS" 'mcp__t3-code__.*'; expect "project mcp__t3-code__.*: $h use_tool call with a chief title reaches guard-t3-thread-tools.sh" deny
    payload "$h" t3 t3_thread_list '{"limit":1}'
    run_group "$PROJECT_SETTINGS" 'mcp__t3-code__.*'; expect_not "project mcp__t3-code__.*: $h harmless T3 read passes" deny
done
payload grok shell "cat $CANARY"
PROJECT_DIR=$ROOT run_user "$ROOT/scripts/hooks/block-read-secrets.sh"
expect "user block-read-secrets: inside himmel the wrapper skips (control)" pass

echo "== parity: each member, native call vs its Claude twin =="
OWED=""
parity() {
    local label=$1 fn=$2 target=$3 kind=$4 hs=$5 h cv nv nonpass=0
    shift 5
    for h in $hs; do
        payload "claude-$h" "$kind" "$@"; "$fn" "$target"; cv=$V
        payload "$h" "$kind" "$@"; "$fn" "$target"; nv=$V
        if [ "$cv" = "$nv" ]; then pass "parity $label: $h $kind '$1' -> $cv"
        else fail "parity $label: $h $kind '$1' native $nv, Claude $cv"; fi
        [ "$cv" = pass ] || nonpass=1
    done
    [ "$nonpass" = 1 ] && PROVED="$PROVED $label"
}
SHELL_TRIGGERS="$ORDINARY_CMD|cat $CANARY|$DOCKER_CMD|rm -rf /|git stash|git status|qmd query fixture|crontab -r"
each_shell_trigger() {
    local t rest=$SHELL_TRIGGERS
    while [ -n "$rest" ]; do
        t=${rest%%|*}
        if [ "$t" = "$rest" ]; then rest=""; else rest=${rest#*|}; fi
        parity "$1" "$2" "$3" shell "grok cursor" "$t"
    done
}
note_owed() { case " $PROVED " in *" $1 "*) ;; *) OWED="$OWED $1" ;; esac; }
PROVED=""

while IFS= read -r m; do
    each_shell_trigger "project:Bash:$(basename "$m")" run_member "$m"; note_owed "project:Bash:$(basename "$m")"
done <<EOF
$(chain_members Bash)
EOF
while IFS= read -r m; do
    l="project:Read|Grep:$(basename "$m")"
    parity "$l" run_member "$m" read "grok cursor" "$CANARY"
    parity "$l" run_member "$m" read "grok cursor" "$WORK_FILE"
    parity "$l" run_member "$m" grep "grok" "$CANARY"
    note_owed "$l"
done <<EOF
$(chain_members 'Read|Grep')
EOF
while IFS= read -r m; do
    l="project:Edit|Write:$(basename "$m")"
    parity "$l" run_member "$m" edit "grok" "$MAIN_FILE"
    parity "$l" run_member "$m" edit "grok" "$WORK_FILE"
    parity "$l" run_member "$m" write "grok cursor" "$MAIN_FILE"
    parity "$l" run_member "$m" write "grok cursor" "$WORK_FILE"
    parity "$l" run_member "$m" write "grok cursor" "$SB/home/.claude/settings.json"
    note_owed "$l"
done <<EOF
$(chain_members 'Edit|Write|MultiEdit|NotebookEdit')
EOF
matcher='Edit|Write|NotebookEdit'
while IFS= read -r c; do
    l="project:$matcher:$(printf '%s' "$c" | grep -o -E '[A-Za-z0-9_.-]+\.sh' | grep -v run-node | head -n 1)"
    parity "$l" run_cmd "$c" edit "grok" "$WORK_FILE"
    parity "$l" run_cmd "$c" write "grok cursor" "$WORK_FILE"
    note_owed "$l"
done <<EOF
$(reg_cmds "$PROJECT_SETTINGS" "$matcher")
EOF
for matcher in 'mcp__t3-code__.*' 'mcp__.*'; do
    while IFS= read -r c; do
        l="project:$matcher:$(printf '%s' "$c" | grep -o -E '[A-Za-z0-9_.-]+\.sh' | grep -v run-node | head -n 1)"
        parity "$l" run_cmd "$c" t3 "grok" t3_thread_launch '{"title":"fixture-chief","prompt":"noop"}'
        parity "$l" run_cmd "$c" t3 "grok" t3_thread_list '{"limit":1}'
        note_owed "$l"
    done <<EOF
$(reg_cmds "$PROJECT_SETTINGS" "$matcher")
EOF
done
PLUGIN_SHELL_MATCHERS='Bash|PowerShell
Bash|PowerShell|mcp__.*
Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell
Bash
Bash|mcp__.*[Aa][Gg][Ee][Nn][Tt][-_][Nn][Aa][Tt][Ii][Vv][Ee].*
Bash|Edit|Write|MultiEdit|NotebookEdit|mcp__.*
Bash|Grep|mcp__.*qmd.*
*'
while IFS= read -r matcher; do
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        l="plugin:$matcher:$(printf '%s' "$c" | grep -o -E '[A-Za-z0-9_.-]+\.sh' | grep -v -E '^run-node\.sh$' | tail -n 1)"
        each_shell_trigger "$l" run_cmd "$c"
        case "$matcher" in
            *Edit*|'*')
                parity "$l" run_cmd "$c" write "grok cursor" "$MAIN_FILE"
                parity "$l" run_cmd "$c" edit "grok" "$WORK_FILE" ;;
        esac
        case "$matcher" in
            *mcp__*|'*') parity "$l" run_cmd "$c" t3 "grok" t3_thread_list '{"limit":1}' ;;
        esac
        note_owed "$l"
    done <<EOF
$(reg_cmds "$OPS/hooks/hooks.json" "$matcher")
EOF
done <<EOF
$PLUGIN_SHELL_MATCHERS
EOF
for g in auto-approve-safe-bash block-read-secrets; do
    each_shell_trigger "user:$g" run_user "$ROOT/scripts/hooks/$g.sh"; note_owed "user:$g"
done
parity "user:block-edit-on-main" run_user "$ROOT/scripts/hooks/block-edit-on-main.sh" write "grok cursor" "$MAIN_FILE"
parity "user:block-edit-on-main" run_user "$ROOT/scripts/hooks/block-edit-on-main.sh" edit "grok" "$WORK_FILE"
for o in $OWED; do echo "NOTE parity vacuous (every trigger passes for Claude): $o"; done

echo "== passthrough: what a member sees =="
printf '#!/usr/bin/env bash\ncat > "%s/seen.json"\nexit 0\n' "$SB" > "$SB/dump.sh"
mkdir -p "$SB/guard-dump"
cp -R "$GUARD/." "$SB/guard-dump/"
cp "$SB/dump.sh" "$SB/guard-dump/hooks/block-destructive-commands.sh"
GUARD_CMD=$(reg_cmds "$GUARD/hooks/hooks.json" 'Bash|PowerShell' | head -n 1)
OPS_CMD=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash|PowerShell") | .hooks[].command' "$OPS/hooks/hooks.json" | head -n 1 \
    | sed -E 's#"\$CLAUDE_PROJECT_DIR/scripts/hooks/[A-Za-z0-9_.-]+\.sh"#"$DUMP"#')
seen_by() {
    rm -f "$SB/seen.json"
    case "$1" in
        project) (cd "$SB/work" && hook_env node "$RUNNER" --chain "$SB/dump.sh" < "$SB/p.json" >/dev/null 2>&1) ;;
        plugin)  (cd "$SB/work" && hook_env DUMP="$SB/dump.sh" sh -c "$OPS_CMD" < "$SB/p.json" >/dev/null 2>&1) ;;
        guard)   (cd "$SB/work" && PROJECT_DIR=$NONHIMMEL PLUGIN_ROOT="$SB/guard-dump" hook_env sh -c "$GUARD_CMD" < "$SB/p.json" >/dev/null 2>&1) ;;
        user)    (cd "$SB/work" && PROJECT_DIR=$NONHIMMEL hook_env node "$WRAPPER" "$SB/dump.sh" < "$SB/p.json" >/dev/null 2>&1) ;;
    esac
}
same_call() {
    local got
    got=$(jq -c '[.tool_name, .tool_input]' "$SB/seen.json" 2>/dev/null)
    if [ "$got" = "$(jq -nc --arg n "$2" --argjson i "$3" '[$n, $i]')" ]; then pass "$1"
    else fail "$1 - saw ${got:-nothing}"; fi
}
for ep in project plugin guard user; do
    payload grok shell "$ORDINARY_CMD"; seen_by "$ep"
    same_call "$ep: grok run_terminal_command arrives as Bash" Bash "{\"command\":\"$ORDINARY_CMD\",\"description\":\"probe\"}"
    payload cursor shell "$ORDINARY_CMD"; seen_by "$ep"
    same_call "$ep: cursor Shell arrives as Bash" Bash "{\"command\":\"$ORDINARY_CMD\",\"cwd\":\"\",\"timeout\":30000}"
    payload grok read "$WORK_FILE"; seen_by "$ep"
    same_call "$ep: grok read_file arrives as Read with file_path" Read "{\"file_path\":\"$WORK_FILE\"}"
    payload grok grep "$WORK_FILE"; seen_by "$ep"
    same_call "$ep: grok grep arrives as Grep" Grep "{\"pattern\":\"HIMMEL\",\"path\":\"$WORK_FILE\"}"
    payload grok edit "$WORK_FILE"; seen_by "$ep"
    same_call "$ep: grok search_replace arrives as Edit" Edit "{\"file_path\":\"$WORK_FILE\",\"old_string\":\"hello\",\"new_string\":\"hi\"}"
    payload grok write "$WORK_FILE"; seen_by "$ep"
    same_call "$ep: grok write arrives as Write" Write "{\"file_path\":\"$WORK_FILE\",\"content\":\"probe\"}"
    payload grok t3 t3_thread_list '{"limit":1}'; seen_by "$ep"
    same_call "$ep: grok use_tool t3-code__t3_thread_list arrives as mcp__t3-code__t3_thread_list" mcp__t3-code__t3_thread_list '{"limit":1}'
    for sent in \
        '{"hook_event_name":"PreToolUse","session_id":"h1073-u","tool_name":"FutureTool","tool_input":{"target_file":"x","command":"y"}}' \
        '{"hook_event_name":"PreToolUse","session_id":"h1073-c","tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
        '{"hook_event_name":"PreToolUse","session_id":"h1073-r","tool_name":"Read","tool_input":{"file_path":"/x","target_file":"/y"}}' \
        '{"hook_event_name":"PreToolUse","session_id":"h1073-m","tool_name":"mcp__t3-code__t3_thread_list","tool_input":{"tool_name":"t3-code__x","tool_input":{}}}' \
        '{"hook_event_name":"PreToolUse","session_id":"h1073-n","tool_name":"t3code__nope","tool_input":{"limit":1}}'; do
        printf '%s' "$sent" > "$SB/p.json"; seen_by "$ep"
        if [ "$(jq -cS . "$SB/seen.json" 2>/dev/null)" = "$(printf '%s' "$sent" | jq -cS .)" ]; then
            pass "$ep: $(printf '%s' "$sent" | jq -r .tool_name) passes through unchanged"
        else fail "$ep: $(printf '%s' "$sent" | jq -r .tool_name) changed: $(cat "$SB/seen.json" 2>/dev/null || echo nothing)"; fi
    done
done

echo "== fail-closed: no readable table, every entry point refuses =="
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$SB/allow.sh"
for f in "$OPS/hooks/$TABLE_REL" "$GUARD/hooks/$TABLE_REL"; do
    if cmp -s "$HERE/$TABLE_REL" "$f"; then pass "the table at ${f#"$ROOT"/} is byte-identical to scripts/hooks/$TABLE_REL"
    else fail "the table at ${f#"$ROOT"/} is missing or differs from scripts/hooks/$TABLE_REL"; fi
done
stage() {
    local d=$1 state=$2 t
    rm -rf "$d"; mkdir -p "$d/project/scripts/hooks" "$d/ops/hooks" "$d/guard"
    cp "$RUNNER" "$HERE/hook-integrity.js" "$WRAPPER" "$d/project/scripts/hooks/"
    [ -d "$HERE/lib" ] && cp -R "$HERE/lib" "$d/project/scripts/hooks/lib"
    cp "$OPS/hooks/run-hook-with-bash.js" "$OPS/hooks/hook-integrity.js" "$d/ops/hooks/"
    [ -d "$OPS/hooks/lib" ] && cp -R "$OPS/hooks/lib" "$d/ops/hooks/lib"
    cp -R "$GUARD/." "$d/guard/"
    cp "$SB/allow.sh" "$d/guard/hooks/block-destructive-commands.sh"
    for t in "$d/project/scripts/hooks/$TABLE_REL" "$d/ops/hooks/$TABLE_REL" "$d/guard/hooks/$TABLE_REL"; do
        case "$state" in
            missing) rm -f "$t" ;;
            unreadable) [ -f "$t" ] && chmod 000 "$t" ;;
            unparseable) mkdir -p "$(dirname "$t")"; printf '{ not json\n' > "$t" ;;
        esac
    done
}
fc_run() {
    local d=$1 out rc
    jq -nc '{hook_event_name:"PreToolUse", session_id:"h1073-fc", tool_name:"Bash", tool_input:{command:"echo hi"}}' > "$SB/p.json"
    case "$2" in
        project) out=$(cd "$SB/work" && hook_env node "$d/project/scripts/hooks/run-hook-with-bash.js" --chain "$SB/allow.sh" < "$SB/p.json" 2>"$SB/err") ;;
        plugin)  out=$(cd "$SB/work" && hook_env node "$d/ops/hooks/run-hook-with-bash.js" "$SB/allow.sh" < "$SB/p.json" 2>"$SB/err") ;;
        guard)   out=$(cd "$SB/work" && PROJECT_DIR=$NONHIMMEL PLUGIN_ROOT="$d/guard" hook_env sh -c "$GUARD_CMD" < "$SB/p.json" 2>"$SB/err") ;;
        user)    out=$(cd "$SB/work" && PROJECT_DIR=$NONHIMMEL hook_env node "$d/project/scripts/hooks/guardrail-skip-in-himmel.js" "$SB/allow.sh" < "$SB/p.json" 2>"$SB/err") ;;
    esac
    rc=$?
    decide "$rc" "$out"
}
for ep in project plugin guard user; do
    stage "$SB/fc" present; fc_run "$SB/fc" "$ep"
    expect "fail-closed $ep: with the table an ordinary call passes (mutation control)" pass
    states="missing unparseable"
    [ "$(id -u)" = 0 ] || states="$states unreadable"
    for s in $states; do
        stage "$SB/fc" "$s"; fc_run "$SB/fc" "$ep"
        expect "fail-closed $ep: a $s table refuses the call" deny
    done
done

echo
echo "harness-tool-translation: $PASSED passed, $FAILED failed"
[ "$FAILED" = 0 ]
