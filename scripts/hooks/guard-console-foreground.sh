#!/usr/bin/env bash
# guard-console-foreground.sh — PreToolUse hook (matcher "Bash"):
# a CONSOLE session must run a long console-kit script with the Bash tool's
# run_in_background: true, never in the foreground. A foreground run blocks the
# console turn for minutes and every leg's SendMessage (READY, MERGED, BLOCKED,
# quote-backs) queues behind it. Prose ("run it in the background") drifted
# twice, so per root CLAUDE.md's "Adding a rule" it is a hook.
#
# TRIP CONDITION: HIMMEL_CONSOLE_DOC is set (a cheap first gate, before stdin is
# read) AND the session's own `-n` name ends in `-console` (a leg launched from
# a console inherits the env var, so the name is the real identity) AND the Bash command runs a script named in
# scripts/handover/console-kit/long-running.txt AND tool_input.run_in_background
# is not true. "Runs" means the name follows an interpreter (bash, sh, node,
# bun, python) in command position or sits in command position behind a path; a grep or cat that
# merely names the script is not a run.
# ponytail: a textual match, not a shell parser — a script run through eval, a
# wrapper script or a quoted path slips past, and a listed name fed to an
# interpreter as a later argument is not seen; revisit if a console is
# observed doing it.
#
# DENY: structured permissionDecision "deny" on stdout plus exit 2 + stderr (the
# guard-console-dispatch.sh idiom); the message gives the exact re-issue shape.
# A WORKFLOW nudge, not a security fence: fails OPEN on missing jq, an
# unparseable payload or an unreadable list (scripts/hooks/CLAUDE.md).
#
# Single-run bypass (set in the shell that LAUNCHED Claude Code; a per-call
# prefix does not reach this hook): CONSOLE_FG_OK=1.
#
# Test seam: CONSOLE_FG_LIST points at an alternate list file. Bash
# 3.2-compatible. Exit codes: 0 allow; 2 refuse.
set -uo pipefail

[ -n "${HIMMEL_CONSOLE_DOC:-}" ] || exit 0
[ "${CONSOLE_FG_OK:-}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$tool" = "Bash" ] || exit 0

bg=$(printf '%s' "$input" | jq -r '.tool_input.run_in_background // false' 2>/dev/null) || exit 0
[ "$bg" = "true" ] && exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A leg launched from a console's Bash inherits HIMMEL_CONSOLE_DOC as ambient env,
# so the env var alone cannot tell them apart: only a session named `*-console`
# is a console (the console-compact-reinject.sh rule). Unresolvable name: allow.
lib="$HERE/../lib/session-name.sh"
# shellcheck source=scripts/lib/session-name.sh
{ [ -r "$lib" ] && . "$lib"; } 2>/dev/null || exit 0
sname=$(current_session_name 2>/dev/null) || exit 0
case "$sname" in *-console) ;; *) exit 0 ;; esac

list="${CONSOLE_FG_LIST:-$HERE/../handover/console-kit/long-running.txt}"
[ -r "$list" ] || exit 0

hit=""
while IFS= read -r name; do
    case "$name" in ''|'#'*) continue ;; esac
    esc=$(printf '%s' "$name" | sed 's/[.[\*^$]/\\&/g')
    tail='($|[[:space:];&|)])'
    tok='[^[:space:];&|()]+'
    wrap="(((timeout|nohup)([[:space:]]+${tok})*)[[:space:]]+)?"
    via_interp="(^|[;&|(])[[:space:]]*${wrap}(bash|sh|node|bun|python3?)[[:space:]]+([^[:space:]]*/)?${esc}${tail}"
    via_path="(^|[;&|(])[[:space:]]*${wrap}[^[:space:]]*/${esc}${tail}"
    if printf '%s' "$cmd" | grep -Eq -e "$via_interp" -e "$via_path"; then
        hit="$name"
        break
    fi
done < "$list"
[ -n "$hit" ] || exit 0

# A bounded run is allowed in the foreground: `timeout N` (a whole 1..90 seconds, an `s`
# suffix, or 1m / 1.5m) as the OUTERMOST command, wrapping the interpreter or script path
# directly, with no chain, pipe, substitution or newline anywhere. Anything else (-k, nohup,
# a chain before or after, N > 90 or 0) stays denied.
# ponytail: a textual check; an argument holding one of ;&|`$( denies a bounded run and the
# console re-issues it in the background — revisit if that is observed.
case "$hit:$cmd" in
    console-wait.sh:*|run-suite.sh:*) ;;
    *[\;\&\|\`\$\(]*|*"
"*) ;;
    *)
        dur=$(printf '%s' "$cmd" | sed -nE 's/^[[:space:]]*timeout[[:space:]]+([0-9.]+[sm]?)[[:space:]]+((bash|sh|node|bun|python3?)[[:space:]]+|[^[:space:]]*\/).*/\1/p')
        case "$dur" in
            1m|1.5m) exit 0 ;;
            [1-9]|[1-9][0-9]|[1-9]s|[1-9][0-9]s) [ "${dur%s}" -le 90 ] && exit 0 ;;
        esac ;;
esac

deny_msg="You are a CONSOLE session running a long console-kit script (${hit}) in the foreground — DENIED (HIMMEL-5821).

A foreground run blocks this console turn for minutes, and every leg's SendMessage (READY, MERGED,
BLOCKED, quote-backs) queues behind it.

Re-issue the SAME command with the Bash tool's run_in_background set to true:
  Bash(command: <the command you just tried>, run_in_background: true)
The completion arrives as a task notification; do not poll its output file or sleep on it. Keep
handling leg messages meanwhile and read the result when the notification lands.

A bounded run is allowed in the foreground: make \`timeout 90\` (1 to 90 s) the outermost command, e.g.
  timeout 90 bash scripts/handover/console-kit/ready-check.sh <args>
console-wait.sh and suites stay background. Short scripts (append-results.sh, go.sh, write-verdict.sh,
fleet-manifest.sh, leg-event.sh) are not on the list and stay foreground. The list is scripts/handover/console-kit/long-running.txt.

Bypass for one session: relaunch with CONSOLE_FG_OK=1 in the launching shell (a per-call prefix
does not reach this hook)."

reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
    || reason='"guard-console-foreground: console session denied a foreground long console-kit script"'
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
printf '%s\n' "$deny_msg" >&2
exit 2
