#!/usr/bin/env bash
# block-busy-loop.sh — PreToolUse hook (matcher "Bash").
#
# Denies a Bash call that loads this machine's CPU or memory, the way a session
# recreates a slow CI host. The deny names the three routes that reproduce a
# load-dependent failure instead: a deadline or timing seam in the test, a CI
# run, a test VM. The shapes it refuses, and no others:
#
#   loop        a sleepless `while`/`until ...; do :; done` (or `do true;
#               done`) shell loop, also inside a quoted `bash -c '...'` or a
#               python or node string; the deny also names `sleep N` and a pid
#               wait.
#   lang-loop   a python `while True: pass` (or `while 1:`, or `...`), a node
#               `while (true) {}` or `for (;;) {}`.
#   load-tool   taskset, numactl, stress or stress-ng at command position (the
#               start, after ; & | ( ` { or a newline, behind sudo, env, nice,
#               nohup, exec, command, time, timeout N, a flag or VAR=x), or as
#               a quoted argv element followed by a closing quote or a flag.
#   null-sink   `yes` redirected to /dev/null; `dd` reading /dev/zero or
#               /dev/random into /dev/null.
#   script-file an unquoted token ending .sh .bash .py .js .mjs .cjs that names
#               a regular text file of at most 1 MiB that git does not track,
#               whose text holds one of the shapes above. A `cd <dir>` earlier
#               in the command moves the base a relative token resolves from.
#               At most 16 files are read. A symlink is read only when its one
#               target is a regular file inside the cwd. A missing, unreadable,
#               binary, oversized or tracked file is skipped.
#
# Delivered by the himmel-ops PLUGIN lane so it fires in every repo, not only
# a himmel checkout. It sources nothing and its message names no repo script,
# because an adopter repo has neither. This file is the only copy of the rule.
#
# A `;` inside a quoted span is blanked before the loop match, so a loop head
# such as `while [ "$x" != ";" ]` is still read as one head. The command
# position match runs on the text with every quoted span emptied, so a tool
# name inside a commit message or a grep pattern is not a command.
#
# Hook I/O: the tool-call JSON on stdin. Exit 0 allows; exit 2 denies, and
# stderr is shown to Claude. Each deny appends one JSONL row (ts, session_id,
# decision, shape, detail, loop, body) to BUSY_LOOP_LOG (default
# ~/.claude/busy-loop-guard/denials.jsonl), best-effort.
#
# Fail OPEN (exit 0) on anything it cannot evaluate (no jq, unparseable JSON,
# a non-Bash tool): a workflow nudge, not a security fence.
#
# Bypass: BUSY_LOOP_BYPASS=1 in the shell that launched the agent (session-
# sticky; a per-call prefix does not reach the hook). bash 3.2-safe.
set -uo pipefail

[ "${BUSY_LOOP_BYPASS:-0}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null) || exit 0
fields=$(jq -r '(.tool_name // "") + "\n" + (.session_id // "") + "\n" + (.cwd // "") + "\n" + (.tool_input.command // "")' <<<"$input" 2>/dev/null) || exit 0
tool=${fields%%$'\n'*}
rest=${fields#*$'\n'}
session=${rest%%$'\n'*}
rest=${rest#*$'\n'}
call_cwd=${rest%%$'\n'*}
cmd=${rest#*$'\n'}

[ "$tool" = "Bash" ] || exit 0
[ -n "$call_cwd" ] && [ -d "$call_cwd" ] || call_cwd=$PWD

QUOTED_RE="^([^'\"]*)('[^']*'|\"([^\"\\\\]|\\\\.)*\")(.*)$"
NL=$'\n'
BUSY_LOOP_RE='(^|[^[:alnum:]_-])(while|until)[[:space:]][^;]*[;[:space:]]+do[[:space:]]+(:|true)[[:space:];]*done([^[:alnum:]_]|$)'
PY_LOOP_RE='(^|[^[:alnum:]_])while[[:space:]]+(True|1)[[:space:]]*:[[:space:]]*(pass|\.\.\.)([^[:alnum:]_]|$)'
JS_WHILE_RE='(^|[^[:alnum:]_])while[[:space:]]*\([[:space:]]*(true|1)[[:space:]]*\)[[:space:]]*(\{[[:space:]]*\}|;)'
JS_FOR_RE='(^|[^[:alnum:]_])for[[:space:]]*\([[:space:]]*;[[:space:]]*;[[:space:]]*\)[[:space:]]*(\{[[:space:]]*\}|;)'
CMD_POS="(^|[;&|(\`{${NL}])[[:space:]]*((sudo|env|nice|nohup|exec|command|time|timeout|-[^[:space:]]+|[0-9]+[smhd]?|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)[[:space:]]+)*([^[:space:];&|]*/)?"
TOOL_RE="${CMD_POS}(taskset|numactl|stress-ng|stress)([[:space:];&|)]|\$)"
ARGV_RE="['\"](taskset|numactl|stress-ng|stress)(['\"]|[[:space:]]+-)"
YES_RE="${CMD_POS}yes([[:space:]][^;&|]*)?>[[:space:]]*/dev/null"
DD_RE="${CMD_POS}dd[[:space:]][^;&|]*(if=/dev/(zero|u?random)[^;&|]*of=/dev/null|of=/dev/null[^;&|]*if=/dev/(zero|u?random))"

semi_blanked=""
emptied=""
rest=$cmd
while [[ $rest =~ $QUOTED_RE ]]; do
    span=${BASH_REMATCH[2]}
    semi_blanked+=${BASH_REMATCH[1]}${span//;/ }
    emptied+="${BASH_REMATCH[1]}''"
    rest=${BASH_REMATCH[4]}
done
semi_blanked+=$rest
emptied+=$rest

shape=""
detail=""
loop=""
body=""

match_shapes() {
    if [[ $2 =~ $BUSY_LOOP_RE ]]; then
        shape=loop loop=${BASH_REMATCH[2]} body=${BASH_REMATCH[3]} detail="$loop ... do ${BASH_REMATCH[3]}; done"
    elif [[ $1 =~ $PY_LOOP_RE ]] || [[ $1 =~ $JS_WHILE_RE ]] || [[ $1 =~ $JS_FOR_RE ]]; then
        shape=lang-loop detail=$(printf '%s' "${BASH_REMATCH[0]}" | tr -s '[:space:]' ' ')
    elif [[ $3 =~ $TOOL_RE ]]; then
        shape=load-tool detail=${BASH_REMATCH[5]}
    elif [[ $1 =~ $ARGV_RE ]]; then
        shape=load-tool detail=${BASH_REMATCH[1]}
    elif [[ $3 =~ $YES_RE ]]; then
        shape=null-sink detail="yes to /dev/null"
    elif [[ $3 =~ $DD_RE ]]; then
        shape=null-sink detail="dd to /dev/null"
    else
        return 1
    fi
}

readable_script() {
    local p=$1 target dir
    if [ -L "$p" ]; then
        target=$(readlink "$p" 2>/dev/null) || return 1
        case $target in /*) ;; *) target=$(dirname "$p")/$target ;; esac
        [ -L "$target" ] && return 1
        dir=$(cd "$(dirname "$target")" 2>/dev/null && pwd -P) || return 1
        case "$dir/" in "$(cd "$call_cwd" && pwd -P)/"*) ;; *) return 1 ;; esac
        p=$target
    fi
    [ -f "$p" ] && [ -r "$p" ] || return 1
    [ "$(wc -c <"$p" 2>/dev/null | tr -d ' ')" -le 1048576 ] 2>/dev/null || return 1
    grep -Iq . "$p" 2>/dev/null || return 1
    if command -v git >/dev/null 2>&1 &&
        git -C "$(dirname "$p")" ls-files --error-unmatch -- "$(basename "$p")" >/dev/null 2>&1; then
        return 1
    fi
    script_path=$p
}

if ! match_shapes "$cmd" "$semi_blanked" "$emptied"; then
    base=$call_cwd
    prev=""
    read_count=0
    set -f
    for tok in ${emptied//[;&|()<>]/ }; do
        if [ "$prev" = "cd" ]; then
            case $tok in /*) next=$tok ;; *) next=$base/$tok ;; esac
            [ -d "$next" ] && base=$next
        fi
        prev=$tok
        case $tok in *.sh|*.bash|*.py|*.js|*.mjs|*.cjs) ;; *) continue ;; esac
        [ "$read_count" -lt 16 ] || break
        read_count=$((read_count + 1))
        case $tok in /*) p=$tok ;; *) p=$base/$tok ;; esac
        script_path=""
        readable_script "$p" || continue
        ftext=$(cat "$script_path" 2>/dev/null) || continue
        if match_shapes "$ftext" "$ftext" "$ftext"; then
            detail="$(basename "$script_path"): $detail"
            shape=script-file
            break
        fi
    done
    set +f
    [ -n "$shape" ] || exit 0
fi

log=${BUSY_LOOP_LOG:-${HOME:-}/.claude/busy-loop-guard/denials.jsonl}
if mkdir -p "$(dirname "$log")" 2>/dev/null; then
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg session_id "$session" \
        --arg shape "$shape" --arg detail "$detail" --arg loop "$loop" --arg body "$body" \
        '{ts: $ts, session_id: $session_id, decision: "deny", shape: $shape, detail: $detail, loop: $loop, body: $body}' \
        >>"$log" 2>/dev/null || true
fi

{
    if [ "$shape" = "loop" ]; then
        printf 'busy-loop guard: sleepless busy loop refused.\n\n'
        printf 'A %s loop whose body is only "%s" spins a core at 100%% CPU. Put a\n' "$loop" "$body"
        printf '"sleep N" in the body, or wait on a pid: while kill -0 <pid>; do sleep 1; done\n\n'
    else
        printf 'busy-loop guard: station load refused (%s: %s).\n\n' "$shape" "$detail"
    fi
    printf 'Loading this machine'"'"'s CPU or memory to recreate a slow or busy CI host can\n'
    printf 'stall every session on it. Reproduce a load-dependent failure with:\n'
    printf '  1. a deadline or timing seam in the test (inject the clock or the budget),\n'
    printf '  2. a CI run,\n'
    printf '  3. a test VM.\n\n'
    printf 'Bypass: BUSY_LOOP_BYPASS=1 <launching shell>; a per-call prefix does not work.\n'
} >&2
exit 2
