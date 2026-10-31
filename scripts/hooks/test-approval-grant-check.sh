#!/usr/bin/env bash
# Smoke test for scripts/hooks/approval-grant-check.sh.
#
# A stub sudo on PATH records its argv and answers what the case sets, so these rows pin the
# hook's own contract: no marker means no sudo call at all, the helper is asked with the exact
# command hash, session and cwd, and only a one-line `result=granted id=...` with exit 0 becomes
# an allow. The helper's side (one use, expiry, root-only grant, grant.enabled) runs end to end
# in scripts/lib/test-afk-sudo.sh.
#
# Usage: bash scripts/hooks/test-approval-grant-check.sh
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/approval-grant-check.sh"
FAILED=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/approval-grant-check.XXXXXX")" || { echo "FAIL mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/marks"
cat > "$TMP/bin/sudo" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/argv"
cat "$TMP/answer" 2>/dev/null
exit \$(cat "$TMP/rc" 2>/dev/null || echo 0)
STUB
chmod 0755 "$TMP/bin/sudo"

CMD='npx --yes cowsay@1.6.0 N4198-probe'
SHA=$(printf '%s' "$CMD" | sha256sum | cut -d' ' -f1)

# run <tool> <command> [marks-dir]: OUT = hook stdout, CALLS = stub sudo argv lines.
run() {
    jq -n --arg t "$1" --arg c "$2" '{tool_name:$t,tool_input:{command:$c},session_id:"S1",cwd:"/w"}' > "$TMP/payload.json"
    : > "$TMP/argv"
    OUT=$(PATH="$TMP/bin:$PATH" AFK_GRANT_DIR="${3:-$TMP/marks}" bash "$HOOK" < "$TMP/payload.json" 2>&1)
    CALLS=$(cat "$TMP/argv")
}
answer() { printf '%b' "$1" > "$TMP/answer"; printf '%s' "${2:-0}" > "$TMP/rc"; }
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1"; echo "  want: $2"; echo "  got:  $3"; FAILED=1; fi; }
ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"approval-grant-check: the operator approved this exact command once (afk-sudo grant, TOTP); the grant is now spent"}}'

answer 'result=granted id=abcdefgh\n'
run Bash "$CMD" "$TMP/absent"
check "no marker directory: no decision" "" "$OUT"
check "no marker directory: sudo is never called" "" "$CALLS"

run Bash "$CMD"
check "no marker for these bytes: no decision" "" "$OUT"
check "no marker for these bytes: sudo is never called" "" "$CALLS"

ln -s /dev/null "$TMP/marks/$SHA.abcdefgh"
run Bash "$CMD"
check "a symlinked marker: no decision" "" "$OUT"
check "a symlinked marker: sudo is never called" "" "$CALLS"
rm "$TMP/marks/$SHA.abcdefgh"

: > "$TMP/marks/$SHA.abcdefgh"
run Bash "$CMD"
check "a marker and a granted spend: allow" "$ALLOW" "$OUT"
check "the helper is asked with the exact hash, session and cwd" "-n /usr/local/libexec/himmel/afk-sudo grant-spend --session=S1 --sha256=$SHA --cwd=/w" "$CALLS"

run Bash "$CMD "
check "other bytes (a trailing space): no decision" "" "$OUT"

run Read "$CMD"
check "a non-Bash tool: no decision" "" "$OUT"

answer 'result=no-grant\n' 5
run Bash "$CMD"
check "the helper finds no grant: no decision" "" "$OUT"

answer 'result=granted id=abcdefgh\n' 5
run Bash "$CMD"
check "granted text with a non-zero exit: no decision" "" "$OUT"

answer 'result=granted id=abcdefgh\nresult=granted id=zzzzzzzz\n'
run Bash "$CMD"
check "a two-line answer: no decision" "" "$OUT"

answer 'result=grant-disabled\n' 5
run Bash "$CMD"
check "grant.enabled false in the helper: no decision" "" "$OUT"

[ "$FAILED" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$FAILED"
