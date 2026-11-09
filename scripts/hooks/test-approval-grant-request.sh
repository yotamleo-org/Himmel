#!/usr/bin/env bash
# Smoke test for scripts/hooks/approval-grant-request.sh.
#
# A stub sudo on PATH records its argv and stdin. The hook must hand root the refused
# command's exact bytes on stdin (never on argv), print nothing and exit 0 on every path,
# and make no sudo call when the helper is not installed or the tool is not Bash. The
# helper's side runs end to end in scripts/lib/test-afk-sudo.sh.
#
# Usage: bash scripts/hooks/test-approval-grant-request.sh
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/approval-grant-request.sh"
FAILED=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/approval-grant-request.XXXXXX")" || { echo "FAIL mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/marks"
cat > "$TMP/bin/sudo" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/argv"
cat > "$TMP/stdin"
echo result=pending id=abcdefgh
exit \$(cat "$TMP/rc" 2>/dev/null || echo 0)
STUB
chmod 0755 "$TMP/bin/sudo"

CMD='npx --yes cowsay@1.6.0 N4198-probe'

# run <tool> <command> [marks-dir] [reason]: OUT = hook stdout+stderr, RC, CALLS = stub argv lines.
run() {
    jq -n --arg t "$1" --arg c "$2" --arg r "${4:-[Code from External] fetches a package}" '{tool_name:$t,tool_input:{command:$c},session_id:"S1",cwd:"/w",reason:$r}' > "$TMP/payload.json"
    : > "$TMP/argv"; rm -f "$TMP/stdin"
    OUT=$(PATH="$TMP/bin:$PATH" AFK_GRANT_DIR="${3:-$TMP/marks}" bash "$HOOK" < "$TMP/payload.json" 2>&1)
    RC=$?
    CALLS=$(cat "$TMP/argv")
}
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1"; echo "  want: $2"; echo "  got:  $3"; FAILED=1; fi; }

run Bash "$CMD" "$TMP/absent"
check "helper not installed: no sudo call" "" "$CALLS"
check "helper not installed: exit 0" "0" "$RC"

run Read "$CMD"
check "a non-Bash denial: no sudo call" "" "$CALLS"

run Bash "$CMD"
check "a Bash denial files one grant request" "-n /usr/local/libexec/himmel/afk-sudo grant-request --session=S1 --cwd=/w --why=[Code from External] fetches a package" "$CALLS"
check "root gets the exact command bytes on stdin" "$(printf '%s' "$CMD" | sha256sum)" "$(sha256sum < "$TMP/stdin")"
check "the hook prints nothing" "" "$OUT"
check "the hook exits 0" "0" "$RC"

# Only a real classifier refusal files: its reason carries a bracketed category.
NO_VERDICT="The server-side auto mode classifier gave no verdict for Bash: another call in this response was changed by a hook after auto mode reviewed it, or could not be confirmed unchanged, so this call's review no longer applies. This is not a judgment that the action is unsafe."
run Bash "$CMD" "$TMP/marks" "$NO_VERDICT"
check "a no-verdict denial: no sudo call" "" "$CALLS"
check "a no-verdict denial: exit 0" "0" "$RC"
check "a no-verdict denial prints nothing" "" "$OUT"

run Bash "$CMD" "$TMP/marks" "Classifier unavailable"
check "Classifier unavailable: no sudo call" "" "$CALLS"

run Bash "$CMD" "$TMP/marks" "denied with no category"
check "a reason with no bracketed category: no sudo call" "" "$CALLS"

run Bash "$CMD" "$TMP/marks" "[Credential Exploration] reads a token file"
check "a credential category: no sudo call" "" "$CALLS"

run Bash "$CMD" "$TMP/marks" "[Unauthorized Persistence] adds a cron job"
check "a real refusal files exactly one request, argv unchanged" "-n /usr/local/libexec/himmel/afk-sudo grant-request --session=S1 --cwd=/w --why=[Unauthorized Persistence] adds a cron job" "$CALLS"

printf '5' > "$TMP/rc"
run Bash "$CMD"
check "a refused request still exits 0" "0" "$RC"
check "a refused request prints nothing" "" "$OUT"

[ "$FAILED" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$FAILED"
