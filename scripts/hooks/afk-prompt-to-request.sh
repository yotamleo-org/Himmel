#!/usr/bin/env bash
# afk-prompt-to-request.sh — PermissionRequest hook: while the operator is
# away, a Bash permission prompt is denied with the exact `afk-run --blocked-by prompt` line to
# run instead, so an unattended session files a remote-approval request rather than parking on a
# dialog nobody answers.
#
# The on/off source is the root helper alone: `sudo -n /usr/local/libexec/himmel/afk-sudo mode`
# must answer `enabled=true` and `run_enabled=true` (root config `"enabled": true` and
# `"run": {"enabled": true}`). No user-writable marker turns it on. Anything else (helper absent,
# sudo refused, the station off or locked down, the run kind off): no output, exit 0, and the
# dialog opens as before.
#
# Only Bash calls: another tool has no argv the helper could run. A command the gate-shapes hook
# (permission-allow-gate-shapes.sh, the other PermissionRequest member) allows is left to it.
# A plain command (words of [A-Za-z0-9_./:=@%+,-] only, the first an executable on PATH, not an
# assignment, builtin, keyword, alias or function) is named as its own argv; anything else
# runs as `bash -c <the command>`, quoted, so the request is exactly the call that prompted.
#
# A workflow redirect, not a fence: fails open (no output) on every error.
# Bypass: AFK_PROMPT_TO_REQUEST_OFF=1 in the launching shell lets the dialog open as before.
#
# Input: PermissionRequest JSON on stdin. Output on deny:
#   {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"..."}}}
# Bash 3.2-compatible.
set -uo pipefail
trap 'exit 0' EXIT

[ "${AFK_PROMPT_TO_REQUEST_OFF:-}" = 1 ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
{ [ -r "$here/../lib/git-clean.sh" ] && . "$here/../lib/git-clean.sh"; } 2>/dev/null || exit 0  # swallow-ok: fail-open hook, no decision on error
input=""
IFS= read -r -d '' input 2>/dev/null || true  # swallow-ok: read -d '' ends at EOF with rc 1
[ -n "$input" ] || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0  # swallow-ok: fail-open hook, no decision on error
[ "$tool" = "Bash" ] || exit 0
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0  # swallow-ok: fail-open hook, no decision on error
[ -n "$cmd" ] || exit 0

mode="$(sudo -n /usr/local/libexec/himmel/afk-sudo mode 2>/dev/null | sed -n 1p)" || exit 0  # swallow-ok: no helper or sudo refused = off, the dialog opens
case " $mode " in *" enabled=true "*) ;; *) exit 0 ;; esac
case " $mode " in *" run_enabled=true "*) ;; *) exit 0 ;; esac

if [ -r "$here/permission-allow-gate-shapes.sh" ]; then
    case "$(printf '%s' "$input" | bash "$here/permission-allow-gate-shapes.sh" 2>/dev/null)" in  # swallow-ok: a failed gate-shapes run allows nothing, so the deny stands
        *'"behavior":"allow"'*) exit 0 ;;
    esac
fi

session="$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)" || exit 0  # swallow-ok: fail-open hook, no decision on error
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)" || exit 0  # swallow-ok: fail-open hook, no decision on error
[ -n "$session" ] || session=unknown
[ -n "$cwd" ] || cwd=$PWD
ticket="$(git_clean -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null | grep -o '[A-Za-z][A-Za-z0-9]*-[0-9][0-9]*' | sed -n 1p | tr '[:lower:]' '[:upper:]')"  # swallow-ok: no branch or no ticket in it names ticket none
[ -n "$ticket" ] || ticket=none

lib="$(cd "$here/../lib" 2>/dev/null && pwd)" || exit 0  # swallow-ok: fail-open hook, no decision on error
line="$(printf '%q ' "$lib/afk-run" --session "$session" --ticket "$ticket" --blocked-by prompt --cwd "$cwd" --)"
first=${cmd%% *}
if [[ $cmd =~ ^[A-Za-z0-9_./:=@%+,-]+(\ [A-Za-z0-9_./:=@%+,-]+)*$ ]] && [[ $first != *=* ]] \
    && [ "$(type -t -- "$first" 2>/dev/null)" = file ]; then  # swallow-ok: an unknown name is not a file, so it runs as bash -c
    line="$line$cmd"
else
    line="${line}bash -c $(printf '%q' "$cmd")"
fi

msg="operator is AFK: file \`$line\`
That asks the operator on Telegram, waits up to 9 minutes and, if approved, runs the command once as the operator's user and prints its output and exit status; do not retry the command itself. Exit 75: still pending, re-attach with the afk-run wait line it prints. Exit 76: this session already has a request pending or three sessions are waiting; run the same line again later. Bypass: AFK_PROMPT_TO_REQUEST_OFF=1 in the launching shell opens the dialog as before."
jq -cn --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:$m}}}'
exit 0
