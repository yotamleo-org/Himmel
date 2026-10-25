#!/usr/bin/env bash
# Tests for check-unwired-hooks.sh: a hook-named script that no wiring
# file references fails the lint unless it is on the allowlist with a reason, and the
# allowlist cannot rot (a wired or vanished entry fails too).
#
# Usage: bash scripts/testing/test-unwired-hooks.sh
# shellcheck disable=SC2015  # ok/no never fail, so A && ok || no is a safe if/else here
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LINT="$HERE/check-unwired-hooks.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/unwired-hooks.XXXXXX")" || exit 1
[ -d "$T" ] || exit 1
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

# mk <name>: a minimal fixture repo with one wired hook (wired-hook.sh).
mk() {
  local d="$T/$1"
  mkdir -p "$d/scripts/hooks" "$d/scripts/testing" "$d/.claude"
  : > "$d/scripts/hooks/wired-hook.sh"
  echo '{"hooks":{"PreToolUse":[{"hooks":[{"command":"bash scripts/hooks/wired-hook.sh"}]}]}}' > "$d/.claude/settings.json"
  : > "$d/scripts/testing/unwired-hooks-allowlist.txt"
  echo "$d"
}
run() { bash "$LINT" "$1" 2>&1; }

echo "== U lint behaviour on fixtures =="
d=$(mk clean)
out=$(run "$d"); rc=$?
[ "$rc" -eq 0 ] && ok "U1 a fully wired fixture passes" || no "U1 clean fixture failed: $out"

d=$(mk unwired); : > "$d/scripts/hooks/orphan-hook.sh"
out=$(run "$d"); rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'UNWIRED orphan-hook.sh' <<<"$out"; } && ok "U2 RED: an unregistered hook-named script fails and is named" || no "U2 orphan not caught (rc=$rc): $out"

d=$(mk js); : > "$d/scripts/hooks/orphan.mjs"
out=$(run "$d"); rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'UNWIRED orphan.mjs' <<<"$out"; } && ok "U3 a .mjs hook-named script is covered too" || no "U3 mjs orphan not caught (rc=$rc): $out"

d=$(mk skip); : > "$d/scripts/hooks/test-thing.sh"; : > "$d/scripts/hooks/lib-x.sh"; : > "$d/scripts/hooks/thing.test.mjs"
out=$(run "$d"); rc=$?
[ "$rc" -eq 0 ] && ok "U4 tests and libs are not hook-named" || no "U4 test/lib flagged: $out"

d=$(mk allow); : > "$d/scripts/hooks/orphan-hook.sh"
echo 'orphan-hook.sh|called only from install.sh' > "$d/scripts/testing/unwired-hooks-allowlist.txt"
out=$(run "$d"); rc=$?
[ "$rc" -eq 0 ] && ok "U5 an allowlisted unwired script passes" || no "U5 allowlisted script failed: $out"

d=$(mk noreason); : > "$d/scripts/hooks/orphan-hook.sh"
echo 'orphan-hook.sh|' > "$d/scripts/testing/unwired-hooks-allowlist.txt"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && ok "U6 an allowlist entry with no reason fails" || no "U6 reasonless entry passed: $out"

d=$(mk stale); echo 'wired-hook.sh|was unwired once' > "$d/scripts/testing/unwired-hooks-allowlist.txt"
out=$(run "$d"); rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'STALE' <<<"$out"; } && ok "U7 an allowlist entry that is now wired fails (no rot)" || no "U7 stale entry passed: $out"

d=$(mk gone); echo 'ghost.sh|never existed' > "$d/scripts/testing/unwired-hooks-allowlist.txt"
out=$(run "$d"); rc=$?
[ "$rc" -eq 1 ] && ok "U8 an allowlist entry naming no script fails" || no "U8 ghost entry passed: $out"

d=$(mk substr); : > "$d/scripts/hooks/orphan-hook.sh"; : > "$d/scripts/hooks/not-orphan-hook.sh"
echo '{"hooks":{"PreToolUse":[{"hooks":[{"command":"bash scripts/hooks/wired-hook.sh"},{"command":"bash scripts/hooks/not-orphan-hook.sh"}]}]}}' > "$d/.claude/settings.json"
out=$(run "$d"); rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'UNWIRED orphan-hook.sh' <<<"$out"; } && ok "U9 a longer basename does not register a shorter one" || no "U9 substring counted as wired (rc=$rc): $out"

d=$(mk suffix); : > "$d/scripts/hooks/orphan-hook.sh"
echo '{"hooks":{"PreToolUse":[{"hooks":[{"command":"bash scripts/hooks/wired-hook.sh"},{"command":"bash scripts/hooks/orphan-hook.sh.bak"}]}]}}' > "$d/.claude/settings.json"
out=$(run "$d"); rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'UNWIRED orphan-hook.sh' <<<"$out"; } && ok "U9b a suffixed reference (.bak) does not register the script" || no "U9b suffix counted as wired (rc=$rc): $out"

out=$(run "$T/no-such-root"); rc=$?
[ "$rc" -eq 2 ] && ok "U10 a root with no scripts/hooks is an error, not OK" || no "U10 bad root passed (rc=$rc): $out"

echo "== A the real repo =="
out=$(bash "$LINT" "$REPO" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "A1 every hook-named script in this checkout is wired or allowlisted" || no "A1 real repo: $out"
al="$REPO/scripts/testing/unwired-hooks-allowlist.txt"
n=0; for b in bus-deliver-hook.sh bus-deliver-sessionstart.sh; do grep -q "^$b|" "$al" && n=$((n+1)); done
[ "$n" -eq 0 ] && grep -q "^bus-deliver-run.js|.*HIMMEL-5030" "$al" && ok "A2 the two wired bus-deliver hooks are off the allowlist; bus-deliver-run.js stays listed" || no "A2 bus-deliver allowlist entries: hooks listed $n/2, run.js not listed citing HIMMEL-5030"

echo; if [ "$fail" -eq 0 ]; then echo "ALL PASSED ($pass)"; exit 0; fi
echo "FAILED: $fail"; exit 1
