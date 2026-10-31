#!/usr/bin/env bash
# approval-grant-check.sh — PreToolUse Bash allow for one operator-granted call.
#
# When the permission classifier refuses a worker's Bash call, approval-grant-request.sh
# (PermissionDenied) files the exact command bytes with the root afk-sudo helper, root sends
# the operator the full command on Telegram, and the operator's `NONCE CODE` reply makes root
# write a one-use grant (root-only) plus an empty root-owned marker named by the command's
# sha256 in /var/lib/himmel/afk-grants. This member, LAST in the Bash chain, sees the
# worker's retry: when a marker for these exact bytes exists, it asks the root helper
#
#   sudo -n /usr/local/libexec/himmel/afk-sudo grant-spend --session=S --sha256=H --cwd=D
#
# and returns allow only when the helper prints `result=granted`. The helper, not this
# file, is the authority: it spends the grant (one use) and re-checks the session, cwd,
# expiry, every file the command names and the never-remote floor; grant.enabled false in
# the station config refuses every spend. A marker is only a hint that saves a sudo call
# per Bash command; a marker with no root grant behind it allows nothing.
#
# It takes the call away from the classifier for that one call and nothing else: every
# other member of the chain still runs, and a deny from any of them wins (the chain merges
# decisions after every member; deny beats allow). An ask from another member still asks.
#
# This file is pinned by the hook-integrity guard like every scripts/hooks/ file; the grant
# state it asks about is root-owned, never a user-writable file.
#
# FAILURE DIRECTION: FAIL OPEN to "no decision". No marker directory (helper not
# installed), no marker for these bytes, no jq or sha256sum, an unreadable payload, a sudo
# that cannot run without a password, or any helper answer but `result=granted` leaves the
# call to the permission layer, which refuses it again as before.
#
# Test seam: AFK_GRANT_DIR names the marker directory (the hint only; the helper keeps its
# own root paths).
#
# bash 3.2-compatible.
set -uo pipefail

HELPER=/usr/local/libexec/himmel/afk-sudo
MARKS="${AFK_GRANT_DIR:-/var/lib/himmel/afk-grants}"

[ -d "$MARKS" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v sha256sum >/dev/null 2>&1 || exit 0

input=''
IFS= read -r -d '' input 2>/dev/null || true  # swallow-ok: read -d '' ends at EOF with rc 1
[ -n "$input" ] || exit 0

tool=$(jq -r '.tool_name // ""' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open allow hook, no decision on error
[ "$tool" = Bash ] || exit 0
# The exact command bytes, hashed as the request hook hashed them (jq -j, no added newline).
has=$(jq -r '.tool_input.command | type == "string" and length > 0' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open allow hook
[ "$has" = true ] || exit 0
sha=$(jq -j '.tool_input.command' <<<"$input" 2>/dev/null | sha256sum 2>/dev/null) || exit 0  # swallow-ok: fail-open allow hook
sha=${sha%% *}
case "$sha" in
    *[!0-9a-f]* | '') exit 0 ;;
esac
[ "${#sha}" -eq 64 ] || exit 0

found=''
for m in "$MARKS/$sha".*; do
    if [ -f "$m" ] && [ ! -L "$m" ]; then found=1; fi
    break
done
[ -n "$found" ] || exit 0

session=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open allow hook
cwd=$(jq -r '.cwd // ""' <<<"$input" 2>/dev/null) || exit 0  # swallow-ok: fail-open allow hook
[ -n "$session" ] && [ -n "$cwd" ] || exit 0

out=$(sudo -n "$HELPER" grant-spend --session="$session" --sha256="$sha" --cwd="$cwd" </dev/null 2>/dev/null) || exit 0  # swallow-ok: no grant, no decision
case "$out" in
    "result=granted id="*) ;;
    *) exit 0 ;;
esac
case "$out" in *$'\n'*) exit 0 ;; esac

printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"approval-grant-check: the operator approved this exact command once (afk-sudo grant, TOTP); the grant is now spent"}}'
exit 0
