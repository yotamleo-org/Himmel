#!/usr/bin/env bash
# block-station-load-test.sh — PreToolUse Bash chain member: in a dispatched
# worker session (HIMMEL_WORKER=1) denies a command that would load the station,
# the way worker N31239 looped a suite in about 32 background copies and pushed
# load to 110 on 32 cores (decision 1309: a station is never load
# tested). The shapes it refuses, and no others:
#
#   xargs-fanout   xargs with -P / --max-procs above 2 (or 0, unlimited).
#   parallel       GNU parallel with no job flag (it defaults to every core), or
#                  -j / --jobs / -P above 2, 0, or a percentage.
#   loop-fanout    a for/while/until loop whose body starts background jobs (a
#                  standalone `&`) and whose passes times jobs the guard cannot
#                  show to be 2 or fewer: a literal word list or `seq N` / {1..N} / `-lt N`
#                  with N at most 2 passes; `$(nproc)`, a variable or no bound
#                  does not.
#   bg-fanout      more than 2 standalone background `&` launches in one command.
#   busy-loop      a sleepless `while :; do :; done` (or `true`) loop together
#                  with a background launch, the N31239 `( while :; do :; done ) &`
#                  repeated once per core.
#   load-tool      stress or stress-ng at command position; `yes` sent to
#                  /dev/null or put in the background.
#   script-file    a script the command runs (the command word, or the operand of
#                  bash, sh, python, node, source or .) that is a regular text
#                  file of at most 1 MiB which git does not track, whose text
#                  holds one of the shapes above. At most 8 files are read; a
#                  tracked suite is never read, so a committed test that
#                  legitimately backgrounds work still runs. This is the N31239
#                  shape: scratchpad/loaded-runs.sh held the loop, the command
#                  line only named it.
#
# A single foreground suite run, and a fan-out of at most 2 copies (xargs -P 2,
# parallel -j 2, `for i in 1 2; do ...& done`), pass.
#
# Worker-only: a headed or chief session sets no HIMMEL_WORKER marker and exits
# on the first line. There is no bypass; a worker proves "works under load" with
# a stubbed clock or a simulated slow tick (inject the deadline seam), or in CI,
# never by loading the station.
#
# A workflow guard, not a security fence: no jq or stdin that is not a JSON
# object allows the call. It reads the command text only; text built at run
# time (a script written then run in one call, an eval, a variable holding the
# flag) is the residual every command-text hook here carries.
#
# Hook I/O: the tool-call JSON on stdin. Exit 0 allows; exit 2 denies and the
# reason is shown to Claude. bash 3.2-safe.
set -uo pipefail

[ "${HIMMEL_WORKER:-0}" = "1" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null) || exit 0  # swallow-ok: a workflow guard allows a call it cannot read
fields=$(jq -r '(.tool_name // "") + "\n" + (.cwd // "") + "\n" + (.tool_input.command // "")' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: a workflow guard allows a call it cannot parse
tool=${fields%%$'\n'*}
rest=${fields#*$'\n'}
call_cwd=${rest%%$'\n'*}
cmd=${rest#*$'\n'}

[ "$tool" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0
[ -n "$call_cwd" ] && [ -d "$call_cwd" ] || call_cwd=$PWD

CAP=2
NL=$'\n'
CMD_POS="(^|[;&|(\`{${NL}])[[:space:]]*((sudo|env|nice|nohup|exec|command|time|timeout|do|then|else|elif|if|while|until|!|-[^[:space:]]+|[0-9]+[smhd]?|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)[[:space:]]+)*([^[:space:];&|]*/)?"
XARGS_RE="${CMD_POS}xargs[[:space:]]([^;&|]*[[:space:]])?(-[[:alnum:]]*P[[:space:]]*|--max-procs(=|[[:space:]]+))([0-9]+)"
PARALLEL_RE="${CMD_POS}parallel([[:space:]]+[^;&|]*)?"
JOBS_RE='(^|[[:space:]])(-j|-P|--jobs|--max-procs)(=|[[:space:]]+)?\+?([0-9]+)(%?)'
STRESS_RE="${CMD_POS}(stress-ng|stress)([[:space:]]+-|[[:space:];&|)'\"]|\$)"
YES_NULL_RE="${CMD_POS}yes([[:space:]][^;&|]*)?>[[:space:]]*/dev/null"
YES_BG_RE="${CMD_POS}yes([[:space:]][^;&|]*)?[[:space:]]&([^&>]|\$)"
BUSY_LOOP_RE='(^|[^[:alnum:]_-])(while|until)[[:space:]][^;]*[;[:space:]]+do[[:space:]]+(:|true)[[:space:];]*done([^[:alnum:]_]|$)'
BG_RE='(^|[^&>|])&([[:space:];)]|$)'
LOOP_KW_RE='(^|[^[:alnum:]_-])(for|while|until)[[:space:]]'

QUOTED_RE="^([^'\"]*)('[^']*'|\"([^\"\\\\]|\\\\.)*\")(.*)\$"
CFLAG_RE='-[[:alnum:]]*[ce][[:space:]]*$'

norm_text() {
    local rest=$1 pre span inner
    normed=""
    if [ "${#rest}" -gt 65536 ]; then
        normed=$rest
        return
    fi
    while [[ $rest =~ $QUOTED_RE ]]; do
        pre=${BASH_REMATCH[1]}
        span=${BASH_REMATCH[2]}
        rest=${BASH_REMATCH[4]}
        inner=${span:1:${#span}-2}
        if [[ $normed$pre =~ $CFLAG_RE ]]; then
            normed+="$pre;$inner;"
        else
            normed+="$pre${span//&/_}"
        fi
    done
    normed+=$rest
}

last_group() { printf '%s' "${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"; }

count_bg() {
    local rest=$1 n=0
    while [[ $rest =~ $BG_RE ]]; do
        n=$((n + 1))
        rest=${rest#*"${BASH_REMATCH[0]}"}
    done
    printf '%s' "$n"
}

loop_copies() {
    local kind=$1 head=$2 list a b n
    if [ "$kind" = for ]; then
        if [[ $head =~ ^[[:space:]]*\(\([^\;]*\;[^\<]*\<(=?)[[:space:]]*([0-9]+) ]]; then
            n=$((10#${BASH_REMATCH[2]}))
            [ -n "${BASH_REMATCH[1]}" ] && n=$((n + 1))
            printf '%s' "$n"
            return
        fi
        [[ $head =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]+(.*)$ ]] || { printf unknown; return; }
        list=${BASH_REMATCH[1]}
        list=${list%"${list##*[![:space:];]}"}
        if [[ $list =~ ^\{([0-9]+)\.\.([0-9]+)\}$ ]]; then
            a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]}))
            if [ "$b" -ge "$a" ]; then printf '%s' $((b - a + 1)); else printf '%s' $((a - b + 1)); fi
            return
        fi
        if [[ $list =~ ^(\$\(|\`)[[:space:]]*seq[[:space:]]+([0-9]+[[:space:]]+)*([0-9]+)[[:space:]]*(\)|\`)$ ]]; then
            printf '%s' $((10#${BASH_REMATCH[3]}))
            return
        fi
        case $list in *\$* | *\`* | *\** | *\?* | *\[* | *\{* | *\(*) printf unknown; return ;; esac
        # shellcheck disable=SC2086 # counts words of a list the case above proved free of glob characters
        set -- $list
        printf '%s' "$#"
        return
    fi
    if [[ $head =~ -(lt|le)[[:space:]]+\"?([0-9]+)\"? ]]; then
        n=$((10#${BASH_REMATCH[2]}))
        [ "${BASH_REMATCH[1]}" = le ] && n=$((n + 1))
        printf '%s' "$n"
        return
    fi
    if [[ $head =~ \<(=?)[[:space:]]*([0-9]+) ]]; then
        n=$((10#${BASH_REMATCH[2]}))
        [ -n "${BASH_REMATCH[1]}" ] && n=$((n + 1))
        printf '%s' "$n"
        return
    fi
    printf unknown
}

shape=""
detail=""

scan_shapes() {
    local text=$1 rest n m after head body kind copies bg segment per
    norm_text "$1"
    text=$normed

    rest=$text
    while [[ $rest =~ $XARGS_RE ]]; do
        m=${BASH_REMATCH[0]}
        n=$(last_group)
        if [ "$((10#$n))" -gt "$CAP" ] || [ "$((10#$n))" -eq 0 ]; then
            shape=xargs-fanout detail="xargs runs $((10#$n)) copies at once (cap $CAP)"
            return 0
        fi
        rest=${rest#*"$m"}
    done

    rest=$text
    while [[ $rest =~ $PARALLEL_RE ]]; do
        m=${BASH_REMATCH[0]}
        segment=${BASH_REMATCH[$((${#BASH_REMATCH[@]} - 1))]}
        if [[ $segment =~ $JOBS_RE ]]; then
            n=${BASH_REMATCH[4]}
            if [ -n "${BASH_REMATCH[5]}" ] || [ "$((10#$n))" -gt "$CAP" ] || [ "$((10#$n))" -eq 0 ]; then
                shape=parallel detail="parallel runs ${n}${BASH_REMATCH[5]} jobs at once (cap $CAP)"
                return 0
            fi
        else
            shape=parallel detail="parallel with no -j runs one job per core (cap $CAP)"
            return 0
        fi
        rest=${rest#*"$m"}
    done

    if [[ $text =~ $STRESS_RE ]]; then
        shape=load-tool detail=$(printf '%s' "${BASH_REMATCH[5]}" | tr -d '[:space:]')
        return 0
    fi
    if [[ $text =~ $YES_NULL_RE ]]; then
        shape=load-tool detail="yes to /dev/null"
        return 0
    fi
    if [[ $text =~ $YES_BG_RE ]]; then
        shape=load-tool detail="yes in the background"
        return 0
    fi

    bg=$(count_bg "$text")

    if [ "$bg" -gt 0 ] && [[ $text =~ $BUSY_LOOP_RE ]]; then
        shape=busy-loop detail="a sleepless ${BASH_REMATCH[2]} loop next to a background launch"
        return 0
    fi

    rest=$text
    while [[ $rest =~ $LOOP_KW_RE ]]; do
        kind=${BASH_REMATCH[2]}
        after=${rest#*"${BASH_REMATCH[0]}"}
        rest=$after
        [ "$kind" = until ] && kind=while
        shopt -s extglob
        head=${after%%@(\;|"$NL"| )do@(\;|"$NL"| )*}
        shopt -u extglob
        [ "$head" != "$after" ] || continue
        body=${after#"$head"}
        body=${body#*do}
        case $body in *done*) body=${body%done*} ;; esac
        per=$(count_bg "$body")
        [ "$per" -gt 0 ] || continue
        copies=$(loop_copies "$kind" "$head")
        if [ "$copies" = unknown ] || [ "$((copies * per))" -gt "$CAP" ]; then
            shape=loop-fanout detail="a $kind loop starts $per background job(s) per pass and does not stay at $CAP or fewer in all (passes: $copies)"
            return 0
        fi
    done

    if [ "$bg" -gt "$CAP" ]; then
        shape=bg-fanout detail="$bg background launches in one command (cap $CAP)"
        return 0
    fi
    return 1
}

readable_script() {
    local p=$1
    [ -f "$p" ] && [ -r "$p" ] || return 1
    [ "$(wc -c <"$p" 2>/dev/null | tr -d ' ')" -le 1048576 ] 2>/dev/null || return 1  # read-sink-ok: a script the command itself runs, only sized and matched for load shapes, never sent anywhere  # swallow-ok: an unsizable script is skipped, not read
    grep -Iq . "$p" 2>/dev/null || return 1
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
    if command -v git >/dev/null 2>&1 &&
        git -C "$(dirname "$p")" ls-files --error-unmatch -- "$(basename "$p")" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

if ! scan_shapes "$cmd"; then
    prev=""
    at_start=1
    interp=0
    read_count=0
    base=$call_cwd
    set -f
    words=${cmd//[;&|()\{\}\`]/ ; }
    words=${words//$NL/ ; }
    for tok in $words; do
        if [ "$prev" = "cd" ]; then
            case $tok in /*) next=$tok ;; *) next=$base/$tok ;; esac
            [ -d "$next" ] && base=$next
        fi
        prev=$tok
        case $tok in
            ";") at_start=1 interp=0
                continue ;;
            sudo|env|nice|nohup|exec|command|time|timeout|do|then|else|elif|if|while|until|"!"|[0-9]*|[A-Za-z_]*=*)
                if [ "$at_start" = 1 ]; then continue; fi ;;
            -*) if [ "$interp" = 1 ]; then continue; fi ;;
            sh|bash|zsh|dash|ksh|python|python[0-9]*|node|bun|deno|source|.|*/sh|*/bash|*/zsh|*/python*|*/node)
                if [ "$at_start" = 1 ]; then
                    at_start=0 interp=1
                    continue
                fi ;;
        esac
        run_pos=$((at_start + interp))
        at_start=0 interp=0
        [ "$run_pos" -gt 0 ] || continue
        tok=${tok#[\'\"]}
        tok=${tok%[\'\"]}
        case $tok in *.sh|*.bash|*.py|*.js|*.mjs|*.cjs) ;; *) continue ;; esac
        [ "$read_count" -lt 8 ] || break
        read_count=$((read_count + 1))
        case $tok in /*) p=$tok ;; *) p=$base/$tok ;; esac
        readable_script "$p" || continue
        ftext=$(cat "$p" 2>/dev/null) || continue  # swallow-ok: an unreadable script is skipped, not scanned
        if scan_shapes "$ftext"; then
            detail="$(basename "$p"): $detail"
            shape=script-file
            break
        fi
    done
    set +f
    [ -n "$shape" ] || exit 0
fi

reason="block-station-load-test: a worker may not load the station ($shape: $detail). A station is never load tested (decision 1309): a fan-out past $CAP copies, a busy loop or a stress tool slows every worker, judge and hook on it until they time out. Prove \"works under load\" without loading the machine: stub the clock or inject a simulated slow tick (the deadline seam) in the test, or let CI run it. A single foreground suite run, or a fan-out of at most $CAP copies (xargs -P $CAP, parallel -j $CAP), is allowed."

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(jq -Rn --arg r "$reason" '$r')"
printf '%s\n' "$reason" >&2
exit 2
