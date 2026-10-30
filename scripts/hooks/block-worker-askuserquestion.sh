#!/usr/bin/env bash
# block-worker-askuserquestion.sh — PreToolUse hook (matcher "AskUserQuestion"):
# denies AskUserQuestion for a chief-spawned worker. A worker
# launched headed by a chief (scripts/handover/chief-kit/headed-arm-worker.sh,
# exports HIMMEL_CONSOLE_LEG=1 in the launching shell) runs in a
# window nobody answers: two workers parked on an AskUserQuestion call on
# 2026-09-10 — one 77 minutes with its diff already complete, the other
# despite an explicit NEVER in its brief. Second drift on prose -> structural
# (root CLAUDE.md "Adding a rule").
#
# Scope: inert until the launcher export lands. Until then
# HIMMEL_CONSOLE_LEG is never set and this hook always falls through to
# allow — that is expected, not a bug.
#
# Workflow nudge, not a security fence (scripts/hooks/CLAUDE.md "Fail-open vs
# fail-closed"): fails OPEN on anything it cannot parse (missing jq, malformed
# or empty stdin), so a hook bug never locks an operator's own session out of
# AskUserQuestion.
#
# Bypass: unset HIMMEL_CONSOLE_LEG in the launching shell (session-sticky; a
# per-call prefix does not reach this hook process).
#
# Platform guard: plain env var + jq, no git/path work; any POSIX bash 3.2+.
#
# Hook I/O: JSON on stdin. exit 0 = allow, exit 2 = deny (stderr plus a
# structured hookSpecificOutput.permissionDecision on stdout — same
# belt-and-braces idiom as guard-chief-dispatch.sh).
set -uo pipefail

[ "${HIMMEL_CONSOLE_LEG:-0}" = "1" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$tool" = "AskUserQuestion" ] || exit 0

deny_msg="You are a chief-spawned worker; nobody answers in this window. Ask the chief by SendMessage (your brief names it), or wait with ONE foreground blocking command / a foreground until-loop."

reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
    || reason='"block-worker-askuserquestion: chief-spawned worker denied AskUserQuestion"'
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
printf '%s\n' "$deny_msg" >&2
exit 2
