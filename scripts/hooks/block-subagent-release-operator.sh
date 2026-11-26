#!/usr/bin/env bash
# block-subagent-release-operator.sh — PreToolUse Bash chain member: denies an
# in-process subagent any Bash command that runs `jira release operator ...`,
# so a subagent never writes an operator-chain row (spec-review included: a
# critic subagent must not record its own verdict). operatorFence in the jira
# CLI reads only the environment, and a subagent inherits the chief's.
#
# A security fence, so it fails CLOSED: no jq denies every call, and stdin that
# is not exactly one JSON object is denied. `agent_id` absent or null is the main
# session (the chief) and is allowed without reading the command; any other value
# is a subagent. A command that does not hold both words `release` and `operator`
# is allowed at once. One that does is allowed only when every simple command in
# it is on a short read-only allowlist and it holds no substitution, no live `$`
# or glob word and no run-a-string option; anything else is denied.
# The allowlist and the fence residual (what it cannot see) are in
# docs/internals/enforcement.md.
# git-env-ok: git is matched as a command word in a case pattern and never run here
#
# Bypass (set in the shell that launched Claude Code; session-sticky, a per-call
# prefix does not reach the hook): SUBAGENT_RELEASE_OPERATOR_GUARD_DISABLE=1
set -o pipefail
# shellcheck disable=SC2154 # rc is assigned inside the trap string.
trap 'rc=$?;if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

deny() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
    printf '%s\n' "$1" >&2
    exit 2
}

BYPASS='Bypass: SUBAGENT_RELEASE_OPERATOR_GUARD_DISABLE=1 in the shell that launched Claude Code.'
RULE="block-subagent-release-operator: a subagent may not run a Bash command that names both release and operator unless it is only a read-only search or file write (grep, egrep, fgrep, rg, git grep, git log, git diff, sed -n, cat or tee to a file); jira release operator writes an operator-chain row, and only the main session (the chief) records one. To search for the phrase, quote it as one argument to grep or git grep through Bash, for example grep -n 'release operator' <file>. To write a file that names it, use the Write tool or a heredoc. $BYPASS"

[ "${SUBAGENT_RELEASE_OPERATOR_GUARD_DISABLE:-0}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 \
    || deny "block-subagent-release-operator: cannot read the hook input without jq; every Bash call is denied until jq is on PATH. $BYPASS"

# stdin is read once by the builtin, so a closed fd 0 ends at once with empty input (a $(jq) reading
# fd 0 itself would read its own output pipe, which takes the free fd 0, and hang).
input=""
IFS= read -r -d '' input 2>/dev/null || true # swallow-ok: read -d '' returns 1 at EOF on every input; empty input is the parse deny below
parsed=$(jq -rs '
  if length != 1 or (.[0] | type) != "object" then error("not one object")
  else
    .[0] | (if .agent_id == null then "chief" else "sub" end),
    ((.tool_input.command // "") | if type == "string" then . else tostring end)
  end' <<<"$input" 2>/dev/null) || parsed=parse

verdict=${parsed%%$'\n'*}
cmd=''
case "$parsed" in *$'\n'*) cmd=${parsed#*$'\n'} ;; esac

unwrap_child=0
[ -z "${GUARD_UNWRAP_DEPTH:-}" ] || unwrap_child=1

case "$verdict" in
    chief) [ "$unwrap_child" = 1 ] || exit 0 ;;
    sub) ;;
    *) deny "block-subagent-release-operator: cannot parse the hook input as a JSON object; the call is denied. $BYPASS" ;;
esac

both_words() {
    local t=$1 bsnl=$'\\\n' dsq="\$'" ddq='$"' sq="'" dq='"' bs=$'\\' sep=$';&|(){}<>`\t\r\n'
    t=${t//"$bsnl"/}
    t=${t//"$dsq"/$sq}
    t=${t//"$ddq"/$dq}
    t=${t//"$sq"/}
    t=${t//"$dq"/}
    t=${t//"$bs"/}
    t=${t//[$sep]/ }
    case " $t " in *" release "*) ;; *) return 1 ;; esac
    case " $t " in *" operator "*) return 0 ;; esac
    return 1
}

both_words "$cmd" || exit 0

cmd=${cmd//$'\r'/ }

case "${BASH_SOURCE[0]}" in
    */*) _gu_lib=${BASH_SOURCE[0]%/*}/lib/guard-unwrap.sh ;;
    *) _gu_lib=lib/guard-unwrap.sh ;;
esac
# shellcheck source=lib/guard-unwrap.sh
if ! { [ -r "$_gu_lib" ] && . "$_gu_lib"; } 2>/dev/null; then
    deny "block-subagent-release-operator: cannot load $_gu_lib; the call is denied. $BYPASS"
fi

guard_unwrap "${BASH_SOURCE[0]}" "$cmd" 2>/dev/null || deny "$RULE"

[ "$GU_TOKENIZED" = 1 ] || deny "$RULE"

readonly_sed() {
    local a script='' re='^(([0-9]+|\$|/[^/]*/)(,([0-9]+|\$|/[^/]*/))?)?p$'
    for a in "$@"; do
        case "$a" in
            -n|-E|-r|-s|--quiet|--silent|-nE|-En|-nr|-rn) ;;
            -*) return 1 ;;
            *) [ -n "$script" ] || script=$a ;;
        esac
    done
    [[ $script =~ $re ]]
}

readonly_git() {
    local a sub='' skip=0
    for a in "$@"; do
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        if [ -z "$sub" ]; then
            case "$a" in
                -C) skip=1 ;;
                --no-pager|-P) ;;
                -*) return 1 ;;
                grep|log|diff) sub=$a ;;
                *) return 1 ;;
            esac
        else
            case "$a" in -O*|--open-files-in-pager*|--ext-diff|--textconv) return 1 ;; esac
        fi
    done
    [ -n "$sub" ]
}

readonly_rg() {
    local a
    for a in "$@"; do
        case "$a" in --pre|--pre=*|--hostname-bin|--hostname-bin=*) return 1 ;; esac
    done
    return 0
}

readonly_command() {
    local s=0 k=0 n core cw j
    local -a idx args
    [ "$ST_SUBST" = 1 ] && return 1
    while [ "$k" -lt "$ST_N" ]; do
        if [ "${ST_X[k]}" = 1 ] || [ "${ST_G[k]}" = 1 ]; then return 1; fi
        k=$((k + 1))
    done
    while [ "$s" -lt "$ST_NSEG" ]; do
        idx=()
        args=()
        read -r -a idx <<<"${GU_SW[s]:-}"
        n=${#idx[@]}
        core=${GU_CORE[s]:-0}
        if [ -n "${GU_XA[s]:-}" ]; then return 1; fi
        if [ "$core" -lt "$n" ]; then
            cw=${ST_W[idx[core]]}
            j=$((core + 1))
            while [ "$j" -lt "$n" ]; do
                args[${#args[@]}]=${ST_W[idx[j]]}
                j=$((j + 1))
            done
            case "$cw" in
                grep|egrep|fgrep|cat|tee|cd) ;;
                rg|ripgrep) readonly_rg "${args[@]+"${args[@]}"}" || return 1 ;;
                sed|gsed) readonly_sed "${args[@]+"${args[@]}"}" || return 1 ;;
                git) readonly_git "${args[@]+"${args[@]}"}" || return 1 ;;
                *) return 1 ;;
            esac
        fi
        s=$((s + 1))
    done
    return 0
}

readonly_command || deny "$RULE"
exit 0
