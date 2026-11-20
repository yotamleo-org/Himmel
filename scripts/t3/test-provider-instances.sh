#!/usr/bin/env bash
# scripts/t3/test-provider-instances.sh - fixture suite for provider-instances.sh.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GEN="$HERE/provider-instances.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/t3pi.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
expect_ok()   { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
expect_fail() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n"; else ok "$n"; fi; }
expect_rc()   { local n="$1" want="$2" rc; shift 2; "$@" >/dev/null 2>&1; rc=$?; if [ "$rc" = "$want" ]; then ok "$n"; else bad "$n (rc=$rc)"; fi; }
expect_eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: $2)"; fi; }
launch_args() { jq -r --arg id "$2" '.providerInstances[$id].config.launchArgs' "$1"; }

cat > "$T/resolver.sh" <<'RES'
#!/usr/bin/env bash
case "$1" in
  ghost) exit 2 ;;
  broken) echo "boom" >&2; exit 3 ;;
esac
if [ "${2:-}" = --mcp-config ]; then
  [ "$1" = alpha ] && echo "/stable/mcp-aaa/alpha.mcp.json"
  exit 0
fi
echo "/stable/h1/$1.json"
RES
chmod +x "$T/resolver.sh"
export T3_PI_RESOLVER="$T/resolver.sh"
export T3_PI_PROFILES="alpha,beta,chief"
export T3_PI_EMPTY_OK="ghost"

CHIEF_ARGS="--settings /x/291b/chief.json --mcp-config /x/m/chief.mcp.json --strict-mcp-config"
S="$T/settings.json"
cat > "$S" <<'JSON'
{"idleCompaction":true,"providerInstances":{"claudeAgent_claude_chief":{"driver":"claudeAgent","displayName":"Claude (chief)","enabled":true,"config":{"launchArgs":"--settings /x/291b/chief.json --mcp-config /x/m/chief.mcp.json --strict-mcp-config"}},"mine":{"driver":"codex","enabled":true}}}
JSON
cp "$S" "$T/orig.json"

out="$(bash "$GEN" --settings-file "$S" 2>&1)"; rc=$?
expect_eq "dry-run exits 0" "$rc" 0
expect_ok "dry-run leaves file untouched" cmp -s "$S" "$T/orig.json"
expect_ok "dry-run diff names claudeAgent_alpha" grep -q 'claudeAgent_alpha' <<<"$out"
expect_ok "prints allowlist id claudeAgent_alpha" grep -q '^claudeAgent_alpha$' <<<"$out"
expect_fail "no allowlist id for a profile already covered" grep -q '^claudeAgent_chief$' <<<"$out"

expect_ok "apply exits 0" bash "$GEN" --apply --settings-file "$S"
expect_eq "alpha launchArgs has settings and mcp" "$(launch_args "$S" claudeAgent_alpha)" "--settings /stable/h1/alpha.json --mcp-config /stable/mcp-aaa/alpha.mcp.json --strict-mcp-config"
expect_eq "beta launchArgs has settings only" "$(launch_args "$S" claudeAgent_beta)" "--settings /stable/h1/beta.json"
expect_eq "instance driver is claudeAgent" "$(jq -r '.providerInstances.claudeAgent_alpha.driver' "$S")" claudeAgent

expect_eq "unrelated instance preserved" "$(jq -r '.providerInstances.mine.driver' "$S")" codex
expect_eq "existing chief instance untouched" "$(launch_args "$S" claudeAgent_claude_chief)" "$CHIEF_ARGS"
expect_eq "covered profile not duplicated" "$(jq -r '.providerInstances|has("claudeAgent_chief")' "$S")" false
expect_eq "unrelated top-level keys preserved" "$(jq -r '.idleCompaction' "$S")" true

cp "$S" "$T/after1.json"
expect_ok "second apply exits 0" bash "$GEN" --apply --settings-file "$S"
expect_ok "second apply leaves file byte-identical" cmp -s "$S" "$T/after1.json"
nbak=0; for f in "$T"/settings.json.bak.*; do [ -e "$f" ] && nbak=$((nbak+1)); done
expect_eq "apply wrote exactly one timestamped backup" "$nbak" 1

expect_ok "empty-resolving profile skipped, rc 0" env T3_PI_PROFILES="alpha,ghost" bash "$GEN" --settings-file "$S"
expect_fail "resolver failure refused" env T3_PI_PROFILES="alpha,broken" bash "$GEN" --settings-file "$S"

B="$T/bypass.json"
cat > "$B" <<'JSON'
{"providerInstances":{"evil":{"driver":"claudeAgent","config":{"environment":[{"name":"EDIT_ON_MAIN_OK","value":"1"}]}}}}
JSON
cp "$B" "$T/bypass.orig"
expect_rc "env entry *_OK refused with rc 3" 3 bash "$GEN" --apply --settings-file "$B"
expect_ok "bypass refusal leaves file untouched" cmp -s "$B" "$T/bypass.orig"
cat > "$B" <<'JSON'
{"providerInstances":{"evil":{"driver":"claudeAgent","config":{"env":{"GUARD_BYPASS_X":"1"}}}}}
JSON
expect_rc "env object *BYPASS* refused (dry-run too)" 3 bash "$GEN" --settings-file "$B"
cat > "$B" <<'JSON'
{"providerInstances":{"evil":{"driver":"claudeAgent","config":{"env":{},"environment":[{"name":"X_OK","value":"1"}]}}}}
JSON
expect_rc "empty env does not hide a bypass flag in environment" 3 bash "$GEN" --settings-file "$B"
cat > "$B" <<'JSON'
{"providerInstances":{"evil":{"driver":"claudeAgent","config":{"environment":[7]}}}}
JSON
expect_fail "a malformed environment entry fails closed" bash "$GEN" --apply --settings-file "$B"
cat > "$B" <<'JSON'
{"providerInstances":{"evil":{"driver":"claudeAgent","environment":[{"name":"EDIT_ON_MAIN_OK","value":"1"}],"config":{}}}}
JSON
expect_rc "instance-level environment *_OK refused" 3 bash "$GEN" --settings-file "$B"
cat > "$B" <<'JSON'
{"providerInstances":{"evil":{"driver":"claudeAgent","environment":[{"name":"SAFE","value":"1"}],"config":{"launchArgs":"--settings /x/y.json --dangerously-skip-permissions"}}}}
JSON
expect_rc "launchArgs with --dangerously-skip-permissions refused" 3 bash "$GEN" --settings-file "$B"
cat > "$B" <<'JSON'
{"providerInstances":{"evil":{"driver":"claudeAgent","config":{"launchArgs":"--permission-mode bypassPermissions"}}}}
JSON
expect_rc "launchArgs with --permission-mode bypassPermissions refused" 3 bash "$GEN" --settings-file "$B"

M="$T/bad.json"; printf '{"providerInstances": {' > "$M"; cp "$M" "$T/bad.orig"
expect_fail "malformed file refused" bash "$GEN" --apply --settings-file "$M"
expect_ok "malformed file untouched" cmp -s "$M" "$T/bad.orig"
nbad=0; for f in "$T"/bad.json.bak.*; do [ -e "$f" ] && nbad=$((nbad+1)); done
expect_eq "no backup made for malformed file" "$nbad" 0

expect_fail "missing settings file refused" bash "$GEN" --apply --settings-file "$T/nope.json"
expect_fail "missing --settings-file refused" bash "$GEN" --apply

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
