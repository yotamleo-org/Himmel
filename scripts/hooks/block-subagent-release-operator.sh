#!/usr/bin/env bash
# block-subagent-release-operator.sh — PreToolUse Bash chain member: denies an
# in-process subagent any Bash command that runs `jira release operator ...`,
# so a subagent never writes an operator-chain row (spec-review included: a
# critic subagent must not record its own verdict). operatorFence in the jira
# CLI reads only the environment, and a subagent inherits the chief's.
#
# A security fence, so it fails CLOSED: no jq denies every call, and stdin that
# is not a JSON object is denied. `agent_id` absent or null is the main session
# (the chief) and is allowed without reading the command; any other value is a
# subagent. A guard-unwrap child call carries no agent_id; it runs with
# GUARD_UNWRAP_DEPTH set and is always a subagent's, so the hook treats it as one.
#
# The match, for a subagent:
#   1. Pre-filter. The command is normalised (backslash-newline pairs deleted,
#      `$'` and `$"` turned into `'` and `"`, then every `'`, `"` and `\`
#      deleted) and split into words at every space, TAB, CR, newline and shell
#      metacharacter. A command that does not hold both words `release` and
#      `operator` is allowed at once: no visible spelling of the writer lacks
#      them.
#   2. Otherwise guard-unwrap derives the text the shell runs (quotes removed,
#      wrappers stripped, `bash -c`, `eval` and `env -S` bodies read) and feeds
#      each derived form back through this hook.
#   3. The tokenizer then splits the command into simple commands, and a simple
#      command is denied when `release` is directly followed by `operator` in
#      its words (redirects aside): the command-word sequence the jira CLI
#      runs. `git diff -G 'release|operator'`, `grep -n 'release operator' f`
#      and a heredoc body that writes a file naming both words are allowed.
#   4. Where a command's words can reach the CLI as DATA rather than as its own
#      words, both words anywhere in it still deny: an `xargs` segment (any
#      word of the whole command), a shell, `eval`, `source`, node, python,
#      perl, ruby, php or lua segment (any word of the segment, or of the whole
#      command when it has a heredoc).
#   5. A command whose quoting the tokenizer cannot read, and that holds both
#      words, is denied.
#
# What it cannot see (text built at run time, a nested claude session, a chief
# in another repo, the Monitor tool; and a command that runs its argument as
# code from another tool: sed `e`, rg --pre, git grep -O, a git alias) is the
# fence residual named in docs/internals/enforcement.md.
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
RULE="block-subagent-release-operator: a subagent may not run a Bash command that runs jira release operator (or one this fence cannot read); it writes an operator-chain row, and only the main session (the chief) records one. To search for the phrase, quote it as one argument to grep or git grep through Bash, for example grep -n 'release operator' <file>. To write a file that names it, use the Write tool or a heredoc. $BYPASS"

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

case "$verdict" in
    chief) [ -n "${GUARD_UNWRAP_DEPTH:-}" ] || exit 0 ;;
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

scan_segments() {
    local s=0 n j w prev segtext core cb
    local -a idx
    while [ "$s" -lt "$ST_NSEG" ]; do
        idx=()
        read -r -a idx <<<"${GU_SW[s]:-}"
        n=${#idx[@]}
        prev=''
        segtext=''
        j=0
        while [ "$j" -lt "$n" ]; do
            w=${ST_W[idx[j]]}
            [ "$prev" = release ] && [ "$w" = operator ] && return 0
            prev=$w
            segtext=$segtext${segtext:+ }$w
            j=$((j + 1))
        done
        if [ -n "${GU_XA[s]:-}" ]; then
            both_words "$cmd" && return 0
        fi
        core=${GU_CORE[s]:-0}
        if [ "$core" -lt "$n" ]; then
            cb=${ST_W[idx[core]]##*/}
            cb=${cb%.exe}
            case "$cb" in
                bash|sh|zsh|dash|ksh|mksh|ash|yash|posh|eval|source|.|node*|bun|deno|tsx|npx|python*|perl*|ruby*|php*|lua*)
                    if [ "$ST_HEREDOC" = 1 ]; then
                        both_words "$cmd" && return 0
                    else
                        both_words "$segtext" && return 0
                    fi ;;
            esac
        fi
        s=$((s + 1))
    done
    return 1
}

if scan_segments; then
    deny "$RULE"
fi
exit 0
