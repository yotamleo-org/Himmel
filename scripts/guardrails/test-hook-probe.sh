#!/usr/bin/env bash
# Smoke test for scripts/guardrails/hook-probe.mjs (HIMMEL-4425).
# Feeds planned calls to the REAL wired PreToolUse chain and asserts the
# PROBE verdict, the hook named in the deny, that side-effect state stays
# redirected, and that a settings fixture lacking the guard flips deny to allow.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
# A leg may run with a bypass exported; the probe must see the guards un-bypassed.
unset EDIT_ON_MAIN_OK EDIT_LIVE_SETTINGS_OK

# grepq <text> [grep-args...] — here-string grep, no pipeline (HIMMEL-1430).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROBE="$REPO_ROOT/scripts/guardrails/hook-probe.mjs"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/fixture-tempdir.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

if [ ! -f "$PROBE" ]; then
    echo "FAIL: $PROBE not found"
    exit 1
fi

TMP="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$TMP"' EXIT

probe() { (cd "$REPO_ROOT" && CLAUDE_PROJECT_DIR="$REPO_ROOT" node "$PROBE" "$@") 2>&1; }

echo "== rm -rf / → PROBE DENY naming block-destructive-commands =="
out=$(probe --tool Bash --command 'rm -rf /'); rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^PROBE DENY' && grepq "$out" 'block-destructive-commands.sh deny'; then
    pass "destructive command denied by block-destructive-commands"
else
    fail "expected rc=1 PROBE DENY + block-destructive-commands deny; rc=$rc out=$out"
fi

echo "== git status → PROBE ALLOW =="
out=$(probe --tool Bash --command 'git status'); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" '^PROBE ALLOW'; then
    pass "git status allowed"
else
    fail "expected rc=0 PROBE ALLOW; rc=$rc out=$out"
fi

echo "== Edit on a main-checkout path → DENY from block-edit-on-main =="
primary="$(git rev-parse --path-format=absolute --git-common-dir)"
primary="${primary%/.git}"
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/README.md","old_string":"a","new_string":"b"}}\n' "$primary" > "$TMP/edit.json"
out=$(probe --payload "$TMP/edit.json"); rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^PROBE DENY' && grepq "$out" 'block-edit-on-main.sh deny'; then
    pass "main-checkout edit denied by block-edit-on-main"
else
    fail "expected rc=1 PROBE DENY + block-edit-on-main deny; rc=$rc out=$out"
fi

echo "== state-writing hook leaves the real state dir untouched =="
mkdir -p "$TMP/real-arm" "$TMP/real-where"
printf 'seed\n' > "$TMP/real-arm/seed"
before=$(find "$TMP/real-arm" "$TMP/real-where" | sort | cksum; cat "$TMP/real-arm/seed" | cksum)
out=$(AUTO_ARM_STATE_DIR="$TMP/real-arm" WHERE_ARE_WE_STATE_DIR="$TMP/real-where" probe --tool Bash --command 'git status'); rc=$?
after=$(find "$TMP/real-arm" "$TMP/real-where" | sort | cksum; cat "$TMP/real-arm/seed" | cksum)
if [ "$rc" -eq 0 ] && [ "$before" = "$after" ] && grepq "$out" -E '^auto-arm-on-cap.sh (allow|passthrough) rc=0'; then
    pass "auto-arm-on-cap ran and real state dir unchanged"
else
    fail "state dir changed or auto-arm-on-cap not probed; before=$before after=$after out=$out"
fi

echo "== RED control: settings fixture without the destructive hook → ALLOW =="
cat > "$TMP/settings-no-destructive.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","timeout":60,"command":"node \"$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js\" --chain \"$CLAUDE_PROJECT_DIR/scripts/hooks/block-git-stash.sh\""}]}]}}
EOF
out=$(probe --settings "$TMP/settings-no-destructive.json" --tool Bash --command 'rm -rf /'); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" '^PROBE ALLOW' && ! grepq "$out" 'block-destructive-commands'; then
    pass "fixture lacking the hook allows rm -rf /"
else
    fail "expected rc=0 PROBE ALLOW without the hook; rc=$rc out=$out"
fi

echo "== --json is machine-parseable =="
out=$(probe --json --tool Bash --command 'rm -rf /'); rc=$?
verdict=$(node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(j.verdict+":"+j.hooks.some(h=>h.hook==="block-destructive-commands.sh"&&h.decision==="deny"))' <<< "$out" 2>&1)
if [ "$rc" -eq 1 ] && [ "$verdict" = "DENY:true" ]; then
    pass "--json carries verdict and per-hook decisions"
else
    fail "expected DENY:true rc=1; rc=$rc verdict=$verdict"
fi

echo "== the probed command is never executed =="
out=$(probe --tool Bash --command "touch $TMP/sentinel"); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" '^PROBE ALLOW' && [ ! -e "$TMP/sentinel" ]; then
    pass "probed command did not run"
else
    fail "sentinel created: the probed command ran"
fi

echo "== a hook printing continue=false is a DENY =="
cat > "$TMP/settings-continue-false.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","timeout":10,"command":"printf '{\"continue\":false,\"stopReason\":\"halted by fixture\"}'"}]}]}}
EOF
out=$(probe --settings "$TMP/settings-continue-false.json" --tool Bash --command 'git status'); rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^PROBE DENY' && grepq "$out" 'halted by fixture'; then
    pass "continue=false classified as deny with its stopReason"
else
    fail "expected rc=1 PROBE DENY with stopReason; rc=$rc out=$out"
fi

echo "== usage errors exit 2 =="
out=$(probe --tool Bash); rc=$?
if [ "$rc" -eq 2 ]; then pass "missing --command rejected"; else fail "expected rc=2 got rc=$rc out=$out"; fi
out=$(probe --bogus); rc=$?
if [ "$rc" -eq 2 ]; then pass "unknown flag rejected"; else fail "expected rc=2 got rc=$rc out=$out"; fi

if [ "$failures" -eq 0 ]; then
    echo "OK: all cases passed"
    exit 0
else
    echo "FAIL: $failures case(s) failed"
    exit 1
fi
