#!/usr/bin/env bash
# untaint.sh — a human at a terminal clears one session's peer taint.
#
# Usage: bash scripts/peer-bridge/untaint.sh <session_id>
#
# Removes ~/.himmel/peer-bridge/taint/<session_id> and every
# taint/<session_id>.pending.* left by a mark hook, then appends
# {"sid","by","at"} to taint/cleared.log. Exit 0 when cleared, 3 when refused.
#
# Refuses when CLAUDECODE or CLAUDE_CODE_SESSION_ID is set (a Claude session's
# Bash), when the id fails ^[A-Za-z0-9-]{1,64}$, when /dev/tty cannot be opened,
# or when the answer typed there is not `yes`.
#
# ponytail: env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID plus a pty (script -qc, python pty) still lets any untainted Claude Bash clear a taint; the env and TTY checks stop accidents, not a determined session, upgrade path the bridge runs as its own sandboxed user that owns the taint files.
#
# Bash 3.2-compatible.
set -u

refuse() {
    printf 'untaint: %s\n' "$1" >&2
    exit 3
}

sid="${1:-}"
S="${HOME:-}/.himmel/peer-bridge"

if [ -n "${CLAUDECODE:-}" ] || [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    refuse "run this yourself in a terminal, not from a Claude session"
fi
if [ -z "$sid" ] || [ "${#sid}" -gt 64 ]; then refuse "usage: untaint.sh <session_id>"; fi
case "$sid" in *[!A-Za-z0-9-]*) refuse "invalid session_id" ;; esac
[ -d "$S/taint" ] || refuse "no taint dir under $S"

exec 3</dev/tty 2>/dev/null || refuse "needs a human at a terminal (/dev/tty)"
printf 'Clear the peer taint of session %s? Type yes: ' "$sid" >&2
ans=""
read -r ans <&3 || refuse "no answer"
[ "$ans" = yes ] || refuse "not cleared"

rm -f "$S/taint/$sid" "$S/taint/$sid".pending.*
by=$(printf '%s' "${USER:-unknown}" | tr -c 'A-Za-z0-9._-' '_')
printf '{"sid":"%s","by":"%s","at":"%s"}\n' "$sid" "$by" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$S/taint/cleared.log"
echo "untaint: cleared $sid"
