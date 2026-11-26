#!/usr/bin/env bash
# suggest-missing-path.sh — PostToolUseFailure hook (matcher "Bash"): when a Bash call
# fails with `No such file or directory` on a path inside the repo or the handover
# root, name up to three existing files with the same basename so the next call
# uses the right path.
#
# Delivered by the himmel-ops PLUGIN lane only. Self-contained: sources nothing.
#
# Decision order:
#   1. Not a Bash failure, or no `No such file or directory` line in the error: print nothing.
#   2. For each such line (first three), take the failed path. A relative path is
#      resolved against the payload's cwd; a path outside the repo top-level and
#      outside $HANDOVER_DIR gets no hint; a path that exists gets no hint.
#   3. Repo: `git ls-files` entries whose last component equals the basename.
#      Handover root: `find` bounded to depth 6, skipping .git. First three each.
#   4. No match: print nothing.
#
# Fail direction: open. It is advisory (PostToolUseFailure cannot deny): any error
# it cannot read prints nothing and exits 0. Bypass: none needed.
#
# Bash 3.2-compatible.

main() {
    command -v jq >/dev/null 2>&1 || return 0
    local input tool err cwd
    input=$(cat) || return 0
    tool=$(printf '%s' "$input" | jq -r '.tool_name // "" | if type == "string" then . else "" end' 2>/dev/null) || return 0
    [ "$tool" = "Bash" ] || return 0
    err=$(printf '%s' "$input" | jq -r '.error // "" | if type == "string" then . else "" end' 2>/dev/null) || return 0
    case "$err" in *"No such file or directory"*) ;; *) return 0 ;; esac
    cwd=$(printf '%s' "$input" | jq -r '.cwd // "" | if type == "string" then . else "" end' 2>/dev/null) || return 0
    [ -n "$cwd" ] || cwd=$PWD
    [ -d "$cwd" ] || return 0

    local root handover
    root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || root=""
    handover=""
    if [ -n "${HANDOVER_DIR:-}" ] && [ -d "$HANDOVER_DIR" ]; then
        handover=$(cd "$HANDOVER_DIR" 2>/dev/null && pwd -P) || handover=""
    fi
    [ -n "$root" ] || [ -n "$handover" ] || return 0
    [ -z "$root" ] || root=$(cd "$root" && pwd -P) || return 0

    local hint="" seen=0 line path base dir abs matches
    while IFS= read -r line; do
        case "$line" in *"No such file or directory"*) ;; *) continue ;; esac
        seen=$((seen + 1))
        [ "$seen" -le 3 ] || break
        path=${line%%: No such file or directory*}
        path=${path%%: \[Errno 2\]*}
        case "$path" in
            *\') path=${path%\'}; path=${path##*\'} ;;
            *\") path=${path%\"}; path=${path##*\"} ;;
            *) path=${path##*: } ;;
        esac
        [ -n "$path" ] || continue
        base=${path##*/}
        case "$base" in ""|*[\*\?\[\]\\]*) continue ;; esac

        case "$path" in
            /*) abs=$path ;;
            *) abs="$cwd/$path" ;;
        esac
        [ ! -e "$abs" ] || continue
        dir=${abs%/*}
        while [ -n "$dir" ] && [ ! -d "$dir" ]; do dir=${dir%/*}; done
        [ -n "$dir" ] || dir=/
        dir=$(cd "$dir" 2>/dev/null && pwd -P) || continue

        matches=""
        if [ -n "$root" ]; then
            case "$dir/" in "$root"/*) matches=$(git -C "$root" ls-files 2>/dev/null | awk -v b="$base" '{ n = split($0, a, "/"); if (a[n] == b) { print; if (++c == 3) exit } }') ;; esac
        fi
        if [ -z "$matches" ] && [ -n "$handover" ]; then
            case "$dir/" in "$handover"/*) matches=$(find "$handover" -maxdepth 6 -name .git -prune -o -type f -name "$base" -print 2>/dev/null | head -3) ;; esac
        fi
        [ -n "$matches" ] || continue
        hint="${hint}${hint:+
}Missing path hint: ${path} does not exist; a file named ${base} exists at: $(printf '%s' "$matches" | head -3 | paste -sd ' ' - | sed 's/ /, /g')"
    done <<EOF
$err
EOF

    [ -n "$hint" ] || return 0
    jq -nc --arg c "$hint" '{hookSpecificOutput:{hookEventName:"PostToolUseFailure",additionalContext:$c}}'
}

main || true
exit 0
