#!/usr/bin/env bash
# Smoke test for scripts/guardrails/hook-probe.mjs.
# Feeds planned calls to the REAL wired PreToolUse chain and asserts the
# PROBE verdict, the hook named in the deny, that side-effect state stays
# redirected, and that a settings fixture lacking the guard flips deny to allow.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
# A worker may run with a bypass exported; the probe must see the guards un-bypassed.
unset EDIT_ON_MAIN_OK EDIT_LIVE_SETTINGS_OK

# grepq <text> [grep-args...] — here-string grep, no pipeline.
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
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","timeout":10,"command":"printf '{\"continue\":false,\"stopReason\":\"halted by fixture\",\"hookSpecificOutput\":{\"permissionDecision\":\"allow\"}}'"}]}]}}
EOF
out=$(probe --settings "$TMP/settings-continue-false.json" --tool Bash --command 'git status'); rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^PROBE DENY' && grepq "$out" 'halted by fixture'; then
    pass "continue=false classified as deny with its stopReason"
else
    fail "expected rc=1 PROBE DENY with stopReason; rc=$rc out=$out"
fi

# The probe must fail CLOSED exactly where runChain in run-hook-with-bash.js does
# a chain it cannot fully evaluate is a DENY, never ALLOW.
# chain_settings <file> <member>... writes a one-entry Bash chain settings fixture.
chain_settings() {
    local file="$1" members="" m; shift
    for m in "$@"; do members="$members \\\"$m\\\""; done
    # shellcheck disable=SC2016  # $CLAUDE_PROJECT_DIR is a literal in the settings command
    printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","timeout":10,"command":"node \\"$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js\\" --chain%s"}]}]}}\n' "$members" > "$file"
}

echo "== a missing chain member is a DENY (runChain: chain member not found) =="
chain_settings "$TMP/settings-missing.json" "$TMP/no-such-member.sh"
out=$(probe --settings "$TMP/settings-missing.json" --tool Bash --command 'git status'); rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^PROBE DENY' && grepq "$out" 'no-such-member.sh'; then
    pass "missing member denies and is named"
else
    fail "expected rc=1 PROBE DENY naming the missing member; rc=$rc out=$out"
fi

echo "== a duplicate chain member is a DENY =="
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$TMP/dup-member.sh"
chain_settings "$TMP/settings-dup.json" "$TMP/dup-member.sh" "$TMP/dup-member.sh"
out=$(probe --settings "$TMP/settings-dup.json" --tool Bash --command 'git status'); rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^PROBE DENY'; then
    pass "duplicate member denies"
else
    fail "expected rc=1 PROBE DENY for a duplicate member; rc=$rc out=$out"
fi

echo "== a must-run member that exits non-zero is a DENY (HIMMEL-3601) =="
mkdir -p "$TMP/crash" "$TMP/sig" "$TMP/slow" "$TMP/adv"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho boom >&2\nexit 1\n' > "$TMP/crash/block-git-stash.sh"
chain_settings "$TMP/settings-crash.json" "$TMP/crash/block-git-stash.sh"
out=$(probe --settings "$TMP/settings-crash.json" --tool Bash --command 'git status'); rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^PROBE DENY' && grepq "$out" 'block-git-stash.sh deny'; then
    pass "must-run crash denies"
else
    fail "expected rc=1 PROBE DENY from a crashed must-run member; rc=$rc out=$out"
fi

echo "== a must-run member killed by a signal is a DENY =="
printf '#!/usr/bin/env bash\ncat >/dev/null\nkill -9 $$\n' > "$TMP/sig/block-git-stash.sh"
chain_settings "$TMP/settings-sig.json" "$TMP/sig/block-git-stash.sh"
out=$(probe --settings "$TMP/settings-sig.json" --tool Bash --command 'git status'); rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^PROBE DENY' && grepq "$out" 'block-git-stash.sh deny'; then
    pass "must-run signal death denies"
else
    fail "expected rc=1 PROBE DENY from a signalled must-run member; rc=$rc out=$out"
fi

echo "== a must-run member that outruns its window is a DENY (HIMMEL-2060) =="
printf '#!/usr/bin/env bash\nsleep 4\n' > "$TMP/slow/block-read-secrets.sh"
chain_settings "$TMP/settings-slow.json" "$TMP/slow/block-read-secrets.sh"
out=$(RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS=700 probe --settings "$TMP/settings-slow.json" --tool Bash --command 'git status'); rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^PROBE DENY' && grepq "$out" 'block-read-secrets.sh deny'; then
    pass "must-run timeout denies"
else
    fail "expected rc=1 PROBE DENY from a timed-out must-run member; rc=$rc out=$out"
fi

echo "== CONTROL: an advisory (non-must-run) member that crashes is NOT a deny =="
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 1\n' > "$TMP/adv/advisory-fixture.sh"
chain_settings "$TMP/settings-adv.json" "$TMP/adv/advisory-fixture.sh"
out=$(probe --settings "$TMP/settings-adv.json" --tool Bash --command 'git status'); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" '^PROBE ALLOW' && grepq "$out" '^advisory-fixture.sh error rc=1'; then
    pass "advisory crash stays a non-blocking error row"
else
    fail "expected rc=0 PROBE ALLOW with an error row; rc=$rc out=$out"
fi

echo "== an ADVISORY member killed by a signal is a DENY (runChain maps a null status to 2) =="
printf '#!/usr/bin/env bash\ncat >/dev/null\nkill -9 $$\n' > "$TMP/adv/advisory-killed.sh"
chain_settings "$TMP/settings-adv-sig.json" "$TMP/adv/advisory-killed.sh"
out=$(probe --settings "$TMP/settings-adv-sig.json" --tool Bash --command 'git status'); rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^PROBE DENY' && grepq "$out" '^advisory-killed.sh deny'; then
    pass "advisory signal death denies"
else
    fail "expected rc=1 PROBE DENY from a signalled advisory member; rc=$rc out=$out"
fi

echo "== integrity: not checked without a session record, DENY on a pin mismatch with one =="
# A real in-repo member pinned to a wrong blob sha in a fixture record.
mkdir -p "$TMP/integ"
printf '{"pins":{"scripts/hooks/block-git-stash.sh":"0000000000000000000000000000000000000000"}}\n' > "$TMP/integ/probe-fixture.json"
chain_settings "$TMP/settings-integ.json" "$REPO_ROOT/scripts/hooks/block-git-stash.sh"
out=$(HIMMEL_HOOK_INTEGRITY_BYPASS_OK=0 HIMMEL_HOOK_INTEGRITY_DIR="$TMP/integ" probe --settings "$TMP/settings-integ.json" --tool Bash --command 'git status'); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" '^integrity: not checked'; then
    pass "no session id: output says integrity was not checked"
else
    fail "expected rc=0 and an 'integrity: not checked' line; rc=$rc out=$out"
fi
out=$(HIMMEL_HOOK_INTEGRITY_BYPASS_OK=0 HIMMEL_HOOK_INTEGRITY_DIR="$TMP/integ" probe --settings "$TMP/settings-integ.json" --session probe-fixture --tool Bash --command 'git status'); rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^PROBE DENY' && grepq "$out" 'integrity mismatch' && ! grepq "$out" 'integrity: not checked'; then
    pass "--session with a mismatching pin record denies"
else
    fail "expected rc=1 PROBE DENY with 'integrity mismatch'; rc=$rc out=$out"
fi

echo "== zero matched entries is an error, not PROBE ALLOW =="
printf '{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"true"}]}]}}\n' > "$TMP/settings-none.json"
out=$(probe --settings "$TMP/settings-none.json" --tool Bash --command 'git status'); rc=$?
if [ "$rc" -eq 2 ] && ! grepq "$out" '^PROBE ALLOW' && grepq "$out" 'no PreToolUse'; then
    pass "no matching entry exits 2 with a message"
else
    fail "expected rc=2 with a no-PreToolUse message; rc=$rc out=$out"
fi

echo "== a non-chain command runs on the entry's own timeout, not the member window =="
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","timeout":10,"command":"sleep 1.5"}]}]}}\n' > "$TMP/settings-nonchain-slow.json"
out=$(RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS=500 probe --settings "$TMP/settings-nonchain-slow.json" --tool Bash --command 'git status'); rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" 'passthrough rc=0' && ! grepq "$out" ' error '; then
    pass "non-chain command not cut short by the member window"
else
    fail "expected passthrough rc=0 for a 1.5s non-chain command; rc=$rc out=$out"
fi

echo "== --chain-file is not a --chain entry =="
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","timeout":10,"command":"printf ran > %s/chainfile-ran # --chain-file %s/list.txt"}]}]}}\n' "$TMP" "$TMP" > "$TMP/settings-chainfile.json"
out=$(probe --settings "$TMP/settings-chainfile.json" --tool Bash --command 'git status'); rc=$?
# Positive evidence: the entry ran as one whole command (the sentinel exists), rc 0, no chain rows.
if [ "$rc" -eq 0 ] && [ -f "$TMP/chainfile-ran" ] && grepq "$out" '^PROBE ALLOW' && ! grepq "$out" "^-file " && ! grepq "$out" "list.txt"; then
    pass "--chain-file ran as one command, no chain member rows"
else
    fail "--chain-file was tokenised as a chain; rc=$rc out=$out"
fi
cat > "$TMP/chain-token.mjs" <<EOF
import { chainMembers } from '$REPO_ROOT/scripts/hooks/bench-hook-stack.mjs';
const r = [
  chainMembers('node r.js --chain-file /a/b.sh', '/p'),
  chainMembers('node r.js --chainx /a/b.sh', '/p'),
  chainMembers('node r.js --chain /a/b.sh', '/p'),
];
process.stdout.write(JSON.stringify(r));
EOF
out=$(node "$TMP/chain-token.mjs" 2>&1)
if [ "$out" = '[null,null,["/a/b.sh"]]' ]; then
    pass "chainMembers matches the --chain token exactly"
else
    fail "expected [null,null,[\"/a/b.sh\"]]; got $out"
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
