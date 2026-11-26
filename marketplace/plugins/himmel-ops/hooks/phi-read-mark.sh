#!/usr/bin/env bash
# phi-read-mark.sh — PostToolUse and PostToolUseFailure hook (matcher "*"): a tool
# call that touches a path under a salus-marked or PHI-listed root marks the
# session with ~/.himmel/phi-taint/<session_id>; scripts/peer-bridge/tell.ts
# refuses a marked session.
#
# Delivered by the himmel-ops PLUGIN lane; scripts/hooks/phi-read-mark.sh is a
# byte-identical copy for the Codex lane. It sources phi-egress-lib.sh beside it
# (the plugin's vendored copy), else ../guardrails/phi-egress-lib.sh.
#
# Paths checked, each made absolute against the payload cwd:
#   Read file_path, NotebookRead notebook_path, Grep path, Glob path and the part
#   of an absolute Glob pattern before its first wildcard (Grep and Glob with no
#   path: the cwd).
#   Bash and Monitor command: every word that starts with "/" in either of two
#   splits of the text: on unquoted, unescaped blanks and shell punctuation, quotes
#   and backslashes honoured as a shell reads them; and on every blank, quote and
#   shell punctuation character.
# A path is PHI when a .salus or .salus-profile marker sits at or above its raw or
# canonical form, or _guard_phi_decision returns 1 (listed) or 2 (unreadable).
#
# Fail direction: toward the mark. It never denies a call (PostToolUse). No lib
# beside it, or more than 256 path words, marks. A session_id outside
# ^[A-Za-z0-9-]{1,64}$, input jq cannot read, or a mark it cannot write exits 2.
# Bypass: none, it only marks; a human clears a mark by deleting the file.
#
# Bash 3.2-compatible.

input=$(cat && printf x) || { echo "phi-read-mark: unreadable hook input" >&2; exit 2; }
input=${input%x}
str() { jq -r "$1 | if type == \"string\" then . else \"\" end" <<<"$input" 2>/dev/null; }

tool=$(str '.tool_name // ""') || { echo "phi-read-mark: unreadable hook input" >&2; exit 2; }
case "$tool" in Read | NotebookRead | Grep | Glob | Bash | Monitor) ;; *) exit 0 ;; esac

sid=$(str '.session_id // ""') || { echo "phi-read-mark: unreadable hook input" >&2; exit 2; }
case "$sid" in "" | *[!A-Za-z0-9-]*) echo "phi-read-mark: invalid session_id" >&2; exit 2 ;; esac
[ "${#sid}" -le 64 ] || { echo "phi-read-mark: invalid session_id" >&2; exit 2; }

mark() {
    local d="${HOME:-}/.himmel/phi-taint"
    [ -n "${HOME:-}" ] || { echo "phi-read-mark: no HOME to mark $sid in" >&2; exit 2; }
    { mkdir -p "$d" && chmod 700 "$d" && : > "$d/$sid"; } 2>/dev/null || { echo "phi-read-mark: cannot write $d/$sid" >&2; exit 2; }
    exit 0
}

cwd=$(str '.cwd // ""')
case "$cwd" in /*) ;; *) cwd=$PWD ;; esac
paths=()
add() { case "$1" in "") ;; /*) paths+=("$1") ;; *) paths+=("$cwd/$1") ;; esac; }
case "$tool" in
    Read) add "$(str '.tool_input.file_path // ""')" ;;
    NotebookRead) add "$(str '.tool_input.notebook_path // ""')" ;;
    Grep | Glob)
        p=$(str '.tool_input.path // ""')
        add "${p:-$cwd}"
        if [ "$tool" = Glob ]; then
            p=$(str '.tool_input.pattern // ""')
            case "$p" in /*) add "${p%%[*?[{]*}" ;; esac
        fi
        ;;
    Bash | Monitor)
        cmd=$(str '.tool_input.command // ""')
        plain=$(printf '%s\n' "$cmd" | tr -s " \t\r;|&<>()'\"\`=:,{}" '\n')
        words=$(printf '%s\n' "$cmd" | awk 'BEGIN { sep = " \t\r;|&<>()`=:,{}" }
        {
            n = length($0)
            for (i = 1; i <= n; i++) {
                c = substr($0, i, 1)
                if (q == "\047") { if (c == q) q = ""; else w = w c; continue }
                if (c == "\\" && i < n) { i++; w = w substr($0, i, 1); continue }
                if (q == "\"") { if (c == q) q = ""; else w = w c; continue }
                if (c == "\047" || c == "\"") { q = c; continue }
                if (index(sep, c)) { if (w != "") print w; w = ""; continue }
                w = w c
            }
            if (q == "") { if (w != "") print w; w = "" } else w = w " "
        }
        END { if (w != "") print w }')
        words=$(printf '%s\n%s\n' "$plain" "$words" | LC_ALL=C sort -u)
        while IFS= read -r w; do
            case "$w" in /*) add "$w" ;; esac
        done <<<"$words"
        ;;
esac
[ "${#paths[@]}" -gt 0 ] || exit 0
[ "${#paths[@]}" -le 256 ] || mark

here=$(cd "$(dirname "$0")" && pwd -P)
lib="$here/phi-egress-lib.sh"
[ -r "$lib" ] || lib="$here/../guardrails/phi-egress-lib.sh"
# shellcheck source=/dev/null
if ! { [ -r "$lib" ] && . "$lib"; } 2>/dev/null; then mark; fi

salus_above() {
    local d="$1" prev=x
    while [ "$d" != "$prev" ]; do
        if [ -e "$d/.salus" ] || [ -e "$d/.salus-profile" ]; then return 0; fi
        prev=$d
        d=${d%/*}
    done
    return 1
}

for p in "${paths[@]}"; do
    salus_above "$p" && mark
    salus_above "$(_guard_phi_canon "$p")" && mark
    rc=0
    _guard_phi_decision "$p" || rc=$?
    case "$rc" in 1 | 2) mark ;; esac
done
exit 0
