#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$REPO/scripts/antigravity/install-antigravity-backstop.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

# shellcheck source=../lib/override-env.sh
# shellcheck disable=SC1091
. "$REPO/scripts/lib/override-env.sh"
scrub_override_env

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-agy-backstop.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export T3CODE_HOME="$TMP/t3home"
HASH_DIR="$T3CODE_HOME/userdata/providers/antigravity/abc123def"
NON_HIMMEL="$TMP/other-repo"
mkdir -p "$HOME/.himmel" "$HASH_DIR/config" "$NON_HIMMEL"

git -C "$NON_HIMMEL" init -q -b main
git -C "$NON_HIMMEL" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

printf '{"custom-user-hook":{"Stop":[{"type":"command","command":"true","timeout":5}]}}\n' > "$HASH_DIR/config/hooks.json"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

echo "== 1. --check does not mutate =="
if [ ! -f "$INSTALLER" ]; then
    bad "installer missing: $INSTALLER"
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi
out="$(bash "$INSTALLER" --check 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$HOME/.gemini/config/hooks.json" ]; then
    ok "--check exits 0 without writing ~/.gemini/config/hooks.json"
else
    bad "--check mutated or failed (rc=$rc out=$out)"
fi

echo "== 2. Apply installs T3 Antigravity backstop + ~/.gemini mirror =="
out="$(bash "$INSTALLER" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "installer apply exits 0"; else bad "installer apply failed (rc=$rc out=$out)"; fi

PRIMARY="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
PRIMARY="$(dirname "$PRIMARY")"
ADAPTER_ABS="$PRIMARY/scripts/hooks/antigravity-hook-adapter.sh"

for target in "$HASH_DIR/config/hooks.json" "$HOME/.gemini/config/hooks.json"; do
    if [ -f "$target" ] && jq -e --arg a "$ADAPTER_ABS" '
        .["himmel-antigravity-backstop"].PreToolUse[0].hooks[0].command | contains($a)
    ' "$target" >/dev/null 2>&1; then
        ok "installed absolute primary adapter in $target"
    else
        bad "missing or wrong adapter command in $target"
    fi
done

if jq -e '.["custom-user-hook"].Stop[0].command == "true"' "$HASH_DIR/config/hooks.json" >/dev/null 2>&1; then
    ok "preserves unrelated user hook specs in T3 config/hooks.json"
else
    bad "clobbered unrelated user hook specs in T3 config/hooks.json"
fi

echo "== 3. Idempotent re-run =="
out2="$(bash "$INSTALLER" 2>&1)"; rc2=$?
if [ "$rc2" -eq 0 ] && grep -q "UNCHANGED" <<<"$out2"; then
    ok "second run is idempotent (UNCHANGED)"
else
    bad "second run not idempotent (rc=$rc2 out=$out2)"
fi

echo "== 4. Installed backstop command fences a hookless non-himmel repo =="
WT_T3="$TMP/wt-t3home"
WT_HASH="$WT_T3/userdata/providers/antigravity/wt123"
mkdir -p "$WT_HASH/config"
T3CODE_HOME="$WT_T3" HIMMEL_PRIMARY_ROOT="$REPO" bash "$INSTALLER" >/dev/null
CMD="$(jq -r '.["himmel-antigravity-backstop"].PreToolUse[0].hooks[0].command' "$WT_HASH/config/hooks.json")"
PAYLOAD_ENV="$(jq -cn --arg c "$NON_HIMMEL" --arg p "$NON_HIMMEL/.env" '{
    hookEventName:"PreToolUse",conversationId:"bs-1",cwd:$c,
    toolCall:{id:"c1",name:"read_file",args:{Path:$p}}
}')"
PAYLOAD_MCP="$(jq -cn --arg c "$NON_HIMMEL" '{
    hookEventName:"PreToolUse",conversationId:"bs-1",cwd:$c,
    toolCall:{id:"c2",name:"mcp_t3-code_preview_open",args:{url:"https://example.com"}}
}')"
dec_env="$(printf '%s' "$PAYLOAD_ENV" | HIMMEL_ANTIGRAVITY_PROJECT_DIR="$REPO" sh -c "$CMD" 2>/dev/null | jq -r '.decision // empty' 2>/dev/null || true)"
if [ "$dec_env" = "deny" ]; then
    ok "backstop denies .env read in hookless non-himmel repo"
else
    bad "backstop allowed .env read in non-himmel repo (dec=$dec_env)"
fi
dec_mcp="$(printf '%s' "$PAYLOAD_MCP" | HIMMEL_ANTIGRAVITY_PROJECT_DIR="$REPO" sh -c "$CMD" 2>/dev/null | jq -r '.decision // empty' 2>/dev/null || true)"
if [ -z "$dec_mcp" ]; then
    ok "backstop gives preview_open the Claude-lane verdict (allow) in hookless non-himmel repo"
else
    bad "backstop did not give preview_open the Claude-lane verdict in non-himmel repo (dec=$dec_mcp)"
fi

echo "== 5. Symlinked target refused fail-closed =="
ln -sf "$TMP/evil.json" "$HOME/.gemini/config/hooks.json"
out_sym="$(bash "$INSTALLER" 2>&1)"; rc_sym=$?
if [ "$rc_sym" -ne 0 ] && [ ! -e "$TMP/evil.json" ]; then
    ok "refuses symlinked hooks.json without writing target"
else
    bad "followed symlinked hooks.json (rc=$rc_sym out=$out_sym)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
