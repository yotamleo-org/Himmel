#!/usr/bin/env bash
# PreToolUse Bash guard: merge-on-green.sh runs only as one bare command.
#
# The merge allow rules match command TEXT that starts with
#     bash <anchor>/scripts/handover/merge-on-green.sh
#     bash scripts/handover/merge-on-green.sh
# where <anchor> is the primary checkout. Any other spelling that runs the script
# (`cd <worktree> && bash ...`, a `;` or `|` compound, an env prefix, the
# "$HIMMEL_REPO/..." spelling, a worktree's copy) matches no rule, so the auto-mode
# classifier judges the merge itself and can deny a GO-backed merge (a cd compound
# on 2026-11-12 11:07Z; the "$HIMMEL_REPO" rows of 2026-11-07). merge-on-green.sh --go
# resolves the PR worktree from the GO file, so the bare command works from any cwd.
#
# This hook denies (exit 2, message on stderr) a command that runs merge-on-green.sh
# in any spelling but those two, alone, and prints the allowed line. It never emits
# an allow decision, so it can only narrow what the permission layer does. A command
# that only names the script (cat, grep, sed, a commit message, a heredoc body) is
# not a run and passes. It is a workflow nudge, so it fails OPEN (exit 0, a stderr
# note) when it cannot evaluate: no jq, unparseable input, no resolvable anchor.
#
# Known misses, left on purpose: a run hidden inside a quoted string (`bash -c "..."`,
# `"$(...)"`) or behind a shell function or alias. The scan is flat.
#
# bash 3.2-safe.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" # swallow-ok: an empty SCRIPT_DIR only matters with HIMMEL_REPO unset, and then the anchor lookup fails open with a note
MOG=scripts/handover/merge-on-green.sh

note() { echo "guard-merge-compound: $1 - not checked (fail open)" >&2; exit 0; }

payload=$(cat) || exit 0
case "$payload" in *merge-on-green*) ;; *) exit 0 ;; esac
command -v jq >/dev/null 2>&1 || note "jq not on PATH"
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || note "unparseable hook input" # swallow-ok: a jq failure fails open with a note
case "$cmd" in *merge-on-green.sh*) ;; *) exit 0 ;; esac

# --- detection: does any simple command in $cmd run merge-on-green.sh? ---------
RUN=0
RUN_ARGS=""

# eval_segment: inspect the words W[0..WN-1] of one simple command.
eval_segment() {
    local i=0 w base
    [ "$WN" -gt 0 ] || return 0
    while [ "$i" -lt "$WN" ]; do
        w=${W[i]}
        case "$w" in
            [A-Za-z_]*=*)
                case "${w%%=*}" in *[!A-Za-z0-9_]*) break ;; esac
                i=$((i + 1)) ;;
            env | command | exec | builtin | nohup | time | nice | sudo) i=$((i + 1)) ;;
            -*) if [ "$i" -gt 0 ]; then i=$((i + 1)); else break; fi ;;
            *) break ;;
        esac
    done
    [ "$i" -lt "$WN" ] || return 0
    base=${W[i]##*/}
    case "$base" in
        bash | sh | zsh | dash | ksh | source | .)
            i=$((i + 1))
            while [ "$i" -lt "$WN" ]; do
                case "${W[i]}" in -*) i=$((i + 1)) ;; *) break ;; esac
            done
            [ "$i" -lt "$WN" ] || return 0
            base=${W[i]##*/} ;;
    esac
    [ "$base" = merge-on-green.sh ] || return 0
    if [ "$RUN" = 0 ]; then
        i=$((i + 1))
        while [ "$i" -lt "$WN" ]; do RUN_ARGS="$RUN_ARGS ${W[i]}"; i=$((i + 1)); done
    fi
    RUN=1
}

W=(); WN=0; cur=""; inword=0
end_word() { if [ "$inword" = 1 ]; then W[WN]=$cur; WN=$((WN + 1)); fi; cur=""; inword=0; }
end_segment() { end_word; eval_segment; W=(); WN=0; }

n=${#cmd}; i=0; q=""; hd=""; hd_strip=0
while [ "$i" -lt "$n" ]; do
    c=${cmd:i:1}
    if [ "$q" = "'" ]; then
        if [ "$c" = "'" ]; then q=""; else cur="$cur$c"; fi
        i=$((i + 1)); continue
    fi
    if [ "$q" = '"' ]; then
        case "$c" in
            '"') q="" ;;
            "\\") i=$((i + 1)); cur="$cur${cmd:i:1}" ;;
            *) cur="$cur$c" ;;
        esac
        i=$((i + 1)); continue
    fi
    case "$c" in
        "'" | '"') q=$c; inword=1 ;;
        "\\")
            i=$((i + 1))
            if [ "${cmd:i:1}" != $'\n' ]; then cur="$cur${cmd:i:1}"; inword=1; fi ;;
        ' ' | $'\t' | $'\r') end_word ;;
        '#')
            if [ "$inword" = 1 ]; then cur="$cur$c"; else
                while [ "$i" -lt "$n" ] && [ "${cmd:i:1}" != $'\n' ]; do i=$((i + 1)); done
                continue
            fi ;;
        $'\n')
            end_segment
            if [ -n "$hd" ]; then
                i=$((i + 1))
                while [ "$i" -lt "$n" ]; do
                    line=""
                    while [ "$i" -lt "$n" ] && [ "${cmd:i:1}" != $'\n' ]; do
                        line="$line${cmd:i:1}"; i=$((i + 1))
                    done
                    i=$((i + 1))
                    if [ "$hd_strip" = 1 ]; then
                        while [ "${line#$'\t'}" != "$line" ]; do line=${line#$'\t'}; done
                    fi
                    [ "${line%$'\r'}" = "$hd" ] && break
                done
                hd=""; hd_strip=0
                continue
            fi ;;
        ';' | '&' | '|' | '(' | ')' | '`') end_segment ;;
        '<')
            end_word
            if [ "${cmd:i+1:1}" = '<' ] && [ "${cmd:i+2:1}" = '<' ]; then
                i=$((i + 3)); continue
            elif [ "${cmd:i+1:1}" = '<' ]; then
                i=$((i + 2))
                if [ "${cmd:i:1}" = '-' ]; then hd_strip=1; i=$((i + 1)); fi
                while [ "${cmd:i:1}" = ' ' ] || [ "${cmd:i:1}" = $'\t' ]; do i=$((i + 1)); done
                hd=""
                while [ "$i" -lt "$n" ]; do
                    c=${cmd:i:1}
                    case "$c" in
                        ' ' | $'\t' | $'\n' | $'\r' | ';' | '&' | '|' | '<' | '>' | ')') break ;;
                        "'" | '"' | "\\") ;;
                        *) hd="$hd$c" ;;
                    esac
                    i=$((i + 1))
                done
                [ -n "$hd" ] || hd_strip=0
                continue
            fi ;;
        '>') end_word ;;
        *) cur="$cur$c"; inword=1 ;;
    esac
    i=$((i + 1))
done
end_segment

[ "$RUN" = 1 ] || exit 0

# --- is $cmd exactly one of the two allowed spellings? -----------------------
c=$cmd
while :; do case "$c" in [' '$'\t'$'\n'$'\r']*) c=${c#?} ;; *) break ;; esac; done
while :; do case "$c" in *[' '$'\t'$'\n'$'\r']) c=${c%?} ;; *) break ;; esac; done
clean=1
case "$c" in *[';&|<>$`(){}']* | *"\\"* | *$'\n'* | *$'\r'* | *$'\t'*) clean=0 ;; esac

allowed_as() {
    case "$c" in "bash $1" | "bash $1 "*) return 0 ;; esac
    return 1
}
if [ "$clean" = 1 ] && allowed_as "$MOG"; then exit 0; fi

# shellcheck source=../lib/git-clean.sh
{ [ -r "$SCRIPT_DIR/../lib/git-clean.sh" ] && . "$SCRIPT_DIR/../lib/git-clean.sh"; } 2>/dev/null || note "cannot load scripts/lib/git-clean.sh" # swallow-ok: fail-open nudge, the note names the cause
base="${HIMMEL_REPO:-$SCRIPT_DIR}"
common=$(git_clean -C "$base" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || note "cannot resolve the primary checkout from '$base'" # swallow-ok: fail-open nudge, the note names the cause
anchor=${common%/.git}
[ "$anchor" != "$common" ] || note "'$common' is not a checkout's .git directory"
anchor=$(cd -P "$anchor" 2>/dev/null && pwd -P) || note "cannot enter '$anchor'" # swallow-ok: fail-open nudge, the note names the cause
case "$anchor" in
    /*) ;;
    *) note "the primary checkout '$anchor' is not an absolute path" ;;
esac
case "$anchor" in
    *[!A-Za-z0-9._/+-]* | */.claude/worktrees/*)
        note "the primary checkout '$anchor' has no allow-rule spelling" ;;
esac

if [ "$clean" = 1 ] && allowed_as "$anchor/$MOG"; then exit 0; fi

line="bash $anchor/$MOG --jira-transition --go <GO file>"
case "$RUN_ARGS" in
    *[!A-Za-z0-9._/+=:@%,\ -]*) ;;
    ?*) line="bash $anchor/$MOG$RUN_ARGS" ;;
esac
{
    echo "guard-merge-compound: DENIED - \`${cmd:0:200}\`: merge-on-green.sh runs only as one bare command. A cd/;/|/&& compound, an env prefix, the \$HIMMEL_REPO spelling or a worktree's copy matches no allow rule, so the auto-mode classifier judges the merge and can deny it. merge-on-green.sh --go finds the PR worktree from the GO file, so run it from any directory, alone, as exactly:"
    echo
    echo "$line"
    echo
    echo "(--jira-transition only when the brief says completes-ticket: yes; the relative bash $MOG <args> is the other allowed spelling)"
} >&2
exit 2
