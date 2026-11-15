#!/usr/bin/env bash
# PreToolUse Bash guard: merge-on-green.sh runs only as one bare command.
#
# The merge allow rules match only command text that starts with
# `bash <anchor>/scripts/handover/merge-on-green.sh` or
# `bash scripts/handover/merge-on-green.sh`; any other spelling that runs the script
# reaches the auto-mode classifier, which can deny a GO-backed merge. This hook
# denies (exit 2) such a spelling and prints the allowed line. It never allows, and
# fails OPEN (exit 0, a stderr note) when it cannot evaluate.
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
export LC_ALL=C

RUN=0
RUN_ARGS=""
ARGS_SAFE=1

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
            if | then | elif | else | do | while | until | '!' | '{') i=$((i + 1)) ;;
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
                case "${W[i]}" in
                    --*) i=$((i + 1)) ;;
                    -*n*) return 0 ;;
                    -*) i=$((i + 1)) ;;
                    *) break ;;
                esac
            done
            [ "$i" -lt "$WN" ] || return 0
            base=${W[i]##*/} ;;
    esac
    [ "$base" = merge-on-green.sh ] || return 0
    if [ "$RUN" = 0 ]; then
        i=$((i + 1))
        while [ "$i" -lt "$WN" ]; do
            case "${W[i]}" in *[!A-Za-z0-9._/+=:@%,-]* | '') ARGS_SAFE=0 ;; esac
            RUN_ARGS="$RUN_ARGS ${W[i]}"; i=$((i + 1))
        done
    fi
    RUN=1
}

W=(); WN=0; cur=""; inword=0
end_word() { if [ "$inword" = 1 ]; then W[WN]=$cur; WN=$((WN + 1)); fi; cur=""; inword=0; }
end_segment() { end_word; eval_segment; W=(); WN=0; }

# scan_line: tokenize one line L (no newline) into W, carrying quote state q and a
# pending heredoc delimiter hd across lines. Sets cont=1 on a trailing backslash.
scan_line() {
    local n=${#L} j=0 c
    cont=0
    while [ "$j" -lt "$n" ]; do
        c=${L:j:1}
        if [ "$q" = "'" ]; then
            if [ "$c" = "'" ]; then q=""; else cur="$cur$c"; fi
            j=$((j + 1)); continue
        fi
        if [ "$q" = '"' ]; then
            case "$c" in
                '"') q="" ;;
                "\\")
                    j=$((j + 1))
                    if [ "$j" -ge "$n" ]; then cont=1; else cur="$cur${L:j:1}"; fi ;;
                *) cur="$cur$c" ;;
            esac
            j=$((j + 1)); continue
        fi
        case "$c" in
            "'" | '"') q=$c; inword=1 ;;
            "\\")
                j=$((j + 1))
                if [ "$j" -ge "$n" ]; then cont=1; else cur="$cur${L:j:1}"; inword=1; fi ;;
            ' ' | $'\t' | $'\r') end_word ;;
            '#')
                if [ "$inword" = 1 ]; then cur="$cur$c"; else return 0; fi ;;
            ';' | '&' | '|' | '(' | ')' | '`') end_segment ;;
            '<')
                end_word
                if [ "${L:j+1:1}" = '<' ] && [ "${L:j+2:1}" = '<' ]; then
                    j=$((j + 3)); continue
                elif [ "${L:j+1:1}" = '<' ]; then
                    j=$((j + 2))
                    if [ "${L:j:1}" = '-' ]; then hd_strip=1; j=$((j + 1)); fi
                    while [ "${L:j:1}" = ' ' ] || [ "${L:j:1}" = $'\t' ]; do j=$((j + 1)); done
                    hd=""
                    while [ "$j" -lt "$n" ]; do
                        c=${L:j:1}
                        case "$c" in
                            ' ' | $'\t' | $'\r' | ';' | '&' | '|' | '<' | '>' | ')') break ;;
                            "'" | '"' | "\\") ;;
                            *) hd="$hd$c" ;;
                        esac
                        j=$((j + 1))
                    done
                    [ -n "$hd" ] || hd_strip=0
                    continue
                fi ;;
            '>') end_word ;;
            *) cur="$cur$c"; inword=1 ;;
        esac
        j=$((j + 1))
    done
}

line_cannot_hold_run() {
    if [ -n "$q" ] || [ "$cont" != 0 ] || [ "$WN" != 0 ] || [ "$inword" != 0 ]; then return 1; fi
    case "$L" in
        *merge-on-green* | *'<<'* | *"'"* | *'"'* | *"\\") return 1 ;;
    esac
    return 0
}

q=""; hd=""; hd_strip=0; in_body=0; cont=0
while IFS= read -r L || [ -n "$L" ]; do
    if [ "$in_body" = 1 ]; then
        B=${L%$'\r'}
        if [ "$hd_strip" = 1 ]; then
            while [ "${B#$'\t'}" != "$B" ]; do B=${B#$'\t'}; done
        fi
        if [ "$B" = "$hd" ]; then in_body=0; hd=""; hd_strip=0; fi
        continue
    fi
    line_cannot_hold_run && continue
    scan_line
    if [ -n "$q" ]; then
        cur="$cur"$'\n'
    elif [ "$cont" = 0 ]; then
        end_segment
        [ -z "$hd" ] || in_body=1
    fi
done <<< "$cmd"
end_segment

[ "$RUN" = 1 ] || exit 0

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
if [ "$ARGS_SAFE" = 1 ] && [ -n "$RUN_ARGS" ]; then line="bash $anchor/$MOG$RUN_ARGS"; fi
{
    echo "guard-merge-compound: DENIED - \`${cmd:0:200}\`: merge-on-green.sh runs only as one bare command. A cd/;/|/&& compound, an env prefix, the \$HIMMEL_REPO spelling or a worktree's copy matches no allow rule, so the auto-mode classifier judges the merge and can deny it. merge-on-green.sh --go finds the PR worktree from the GO file, so run it from any directory, alone, as exactly:"
    echo
    echo "$line"
    echo
    echo "(--jira-transition only when the brief says completes-ticket: yes; the relative bash $MOG <args> is the other allowed spelling)"
} >&2
exit 2
