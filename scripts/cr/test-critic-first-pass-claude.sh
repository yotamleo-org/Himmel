#!/usr/bin/env bash
# test-critic-first-pass-claude.sh — the Claude critic row.
# critic-first-pass.sh routes a claude-api / claude-subscription provider to the
# official claude binary instead of hermes. Fakes record argv/env/cwd; nothing
# here reaches a network or spends.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CFP="$REPO/scripts/cr/critic-first-pass.sh"
PASS=0; FAIL=0
W="$(mktemp -d -t cfp-claude-test.XXXXXX)" || { echo "FAIL - mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
ok() { PASS=$((PASS+1)); echo "ok - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2' got '$3'"; fi; }
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1: '$2' not in $3"; fi; }
hasnt() { if grep -qE -- "$2" "$3" 2>/dev/null; then bad "$1: /$2/ found in $3"; else ok "$1"; fi; }

# throwaway HOME: bank-preflight, the ledger and the registry never touch the real ones
export HOME="$W/home" HIMMEL_FLOW_RUNS_LEDGER="$W/flow-runs.jsonl" CR_LEDGER="$W/ledger.jsonl"
mkdir -p "$HOME"
printf '%s' '{"oauthAccount":{"accountUuid":"uuid-cfp-claude-test"}}' > "$HOME/.claude.json"
# shellcheck source=../lib/usage-cache-identity.sh
# shellcheck disable=SC1091
. "$REPO/scripts/lib/usage-cache-identity.sh"
ACCT="$(current_account_hash)"
bank() { # bank <five_hour %>: a fresh usage cache at that utilization
    printf '{"account":"%s","five_hour":{"utilization":%s},"seven_day":{"utilization":20},"primaries_refreshed_at":%s}\n' "$ACCT" "$1" "$(date +%s)" > "$W/bank.json"
}
export CADENCE_USAGE_CACHE="$W/bank.json" CADENCE_USAGE_SKIP_REFRESH=1 CADENCE_USAGE_LEDGER="$W/bank-ledger.jsonl"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$W/no-fleet.sh"; chmod +x "$W/no-fleet.sh"
export FLEET_PS_CMD="$W/no-fleet.sh"

DIFF='diff --git a/foo.sh b/foo.sh
index 0000000..1111111 100644
--- a/foo.sh
+++ b/foo.sh
@@ -1,2 +1,3 @@
 line
+for i in 1 2 3; do :; done
+another line'

cat > "$W/review.txt" <<'EOF'
## Critical Issues (1 found)
- [CRITIC-1]: off-by-one in loop bound [foo.sh:3]
## Important Issues (0 found)
## Suggestions (0 found)
EOF
# the JSON envelope both fakes print: the review text rides in .result
node -e 'const fs=require("fs");process.stdout.write(JSON.stringify({type:"result",subtype:"success",is_error:false,result:fs.readFileSync(process.argv[1],"utf8"),total_cost_usd:0.1234,usage:{input_tokens:1000,output_tokens:200}}))' "$W/review.txt" > "$W/envelope.json"

# fake claude (subscription path): records argv, cwd, stdin, and the canonical env
FAKE="$W/fake-claude.sh"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REC/argv"
pwd > "$REC/cwd"
cat > "$REC/stdin"
env | grep -E '^(ANTHROPIC_|CLAUDE_CODE_USE_)' > "$REC/env" || true
cat "$ENVELOPE"
EOF
chmod +x "$FAKE"
# fake API launcher (api path): records argv/env, prints the envelope or refuses like claude-api.sh
LAUNCH="$W/fake-claude-api.sh"
cat > "$LAUNCH" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REC/argv"
pwd > "$REC/cwd"
printf '%s\n' "HIMMEL_API_TOOLS=${HIMMEL_API_TOOLS:-}" "HIMMEL_API_KIND=${HIMMEL_API_KIND:-}" \
    "HIMMEL_API_BRANCH=${HIMMEL_API_BRANCH:-}" "HIMMEL_API_HEAD=${HIMMEL_API_HEAD:-}" "HIMMEL_API_PR=${HIMMEL_API_PR:-}" > "$REC/env"
if [ -n "${FAKE_REFUSE:-}" ]; then echo "claude-api: refused: $FAKE_REFUSE" >&2; exit "${FAKE_REFUSE_RC:-2}"; fi
[ -z "${FAKE_FAIL:-}" ] || { echo "boom" >&2; exit 1; }
[ -z "${FAKE_RC5:-}" ] || { echo "boom" >&2; exit 5; }
cat "$ENVELOPE"
EOF
chmod +x "$LAUNCH"
export ENVELOPE="$W/envelope.json" HIMMEL_CLAUDE_BIN="$FAKE" CFP_CLAUDE_API_LAUNCHER="$LAUNCH"

fresh_rec() { REC="$W/rec.$1"; rm -rf "$REC"; mkdir -p "$REC"; export REC; }
run_cfp() { # run_cfp <provider> [extra args]; stdout -> $W/out, stderr -> $W/err
    local p="$1"; shift
    RC=0; printf '%s\n' "$DIFF" | bash "${CFP_RUN:-$CFP}" --model claude-opus-5-5 --slug claude --provider "$p" "$@" >"$W/out" 2>"$W/err" || RC=$?
}

# A readonly routing variable survives the pin: skip without leaking its scratch.
_test_native_auth_skip() {
    fresh_rec native-auth-skip; bank 10
    mkdir -p "$W/native-auth-tmp"
    printf 'readonly ANTHROPIC_TEST_PIN=fixture\n' > "$W/readonly-pin.sh"
    BASH_ENV="$W/readonly-pin.sh" TMPDIR="$W/native-auth-tmp" run_cfp claude-subscription
    check "native-auth refusal exits 5" 5 "$RC"
    has "native-auth refusal reaches the skip branch" "native auth pin could not clear" "$W/err"
    check "native-auth refusal prints no review" "" "$(cat "$W/out")"
    check "native-auth refusal does not launch claude" no "$([ -e "$REC/argv" ] && echo yes || echo no)"
    check "native-auth refusal removes the critic scratch directory" "" "$(find "$W/native-auth-tmp" -name 'prim.*' -type d -print)"
}

if [ "${1:-}" = --native-auth-skip ]; then
    _test_native_auth_skip
    echo "pass=$PASS fail=$FAIL"
    [ "$FAIL" -eq 0 ]; exit "$?"
fi

# --- 0. the shipped registry row -------------------------------------------
row="$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).panel.find(r=>r.slug==="claude");process.stdout.write(p?[p.model,p.effort,p.route_provider,p.tier].join(" "):"MISSING")' "$REPO/scripts/cr/critics.json")"
check "0 critics.json carries the claude row: opus, medium, claude-api, paid" "claude-opus-5-5 medium claude-api paid" "$row"

# --- 1. api provider: the review parses through the normalizer ------------
fresh_rec 1; unset FAKE_REFUSE FAKE_FAIL
run_cfp claude-api
check "1 api review exits 0" 0 "$RC"
has "1 header carries the slug" "# claude First-Pass Review" "$W/out"
has "1 the finding is renumbered under the slug" "- [claude-1]: off-by-one in loop bound [foo.sh:3]" "$W/out"
has "1 model passed" "claude-opus-5-5" "$REC/argv"
has "1 effort medium by default" "medium" "$REC/argv"
has "1 explicit dontAsk permission mode" "dontAsk" "$REC/argv"
has "1 json output" "json" "$REC/argv"
hasnt "1 never bypassPermissions" "bypassPermissions" "$REC/argv"
has "1 read-only tool grant" "HIMMEL_API_TOOLS=Read,Glob,Grep" "$REC/env"
has "1 cost logged from the usage block" "cost_usd=0.1234" "$W/err"
fresh_rec 1k
CR_TARGET_BRANCH=feat/keyed CR_TARGET_HEAD=abc1234 CR_TARGET_PR=4242 run_cfp claude-api
has "1k branch reaches the launcher" "HIMMEL_API_BRANCH=feat/keyed" "$REC/env"
has "1k head reaches the launcher" "HIMMEL_API_HEAD=abc1234" "$REC/env"
has "1k PR reaches the launcher" "HIMMEL_API_PR=4242" "$REC/env"

# --- 2. api provider refusal (lane off / no key / exhausted) is a clean skip ---
fresh_rec 2; export FAKE_REFUSE="api lane is OFF (set HIMMEL_API_LANE=on)"
run_cfp claude-api
check "2 a refusal exits 5 (skipped), not 1 (failed)" 5 "$RC"
check "2 a skip prints no review" "" "$(cat "$W/out")"
has "2 stderr names the skip and the reason" "SKIPPED" "$W/err"
has "2 the refusal reason is forwarded" "api lane is OFF" "$W/err"
unset FAKE_REFUSE

# --- 3. api provider real failure stays a failure (exit 1) -----------------
fresh_rec 3; export FAKE_FAIL=1
run_cfp claude-api
check "3 a launcher crash exits 1" 1 "$RC"
unset FAKE_FAIL
fresh_rec 3b; export FAKE_RC5=1
run_cfp claude-api
check "3b a child crash that happens to exit 5 is a failure (1), not a skip" 1 "$RC"
unset FAKE_RC5

# --- 4. subscription provider: PROCEED runs the native read-only call ------
fresh_rec 4; bank 10
run_cfp claude-subscription
check "4 subscription review exits 0" 0 "$RC"
has "4 finding present" "- [claude-1]: off-by-one in loop bound [foo.sh:3]" "$W/out"
has "4 -p print mode" "-p" "$REC/argv"
has "4 json output" "json" "$REC/argv"
has "4 dontAsk" "dontAsk" "$REC/argv"
has "4 read-only allowedTools" "Read,Glob,Grep" "$REC/argv"
has "4 model" "claude-opus-5-5" "$REC/argv"
hasnt "4 never bypassPermissions" "bypassPermissions" "$REC/argv"
case "$(cat "$REC/cwd" 2>/dev/null)" in "$REPO"|"$REPO"/*) bad "4 cwd must not be the repo" ;; *) ok "4 cwd is a scratch dir outside the repo" ;; esac
has "4 the prompt reaches claude on stdin" "<diff>" "$REC/stdin"

# --- 5. subscription provider: bank exhausted skips, never launches --------
fresh_rec 5; bank 99
run_cfp claude-subscription
check "5 SKIPPED-BANK exits 5" 5 "$RC"
check "5 claude is not launched" "no" "$([ -e "$REC/argv" ] && echo yes || echo no)"
has "5 stderr names SKIPPED-BANK" "SKIPPED-BANK" "$W/err"
check "5 no review on stdout" "" "$(cat "$W/out")"

# --- 6. native-auth pin: an inherited proxy var never reaches claude --------
fresh_rec 6; bank 10
RC=0; printf '%s\n' "$DIFF" | ANTHROPIC_BASE_URL=http://127.0.0.1:9 ANTHROPIC_AUTH_TOKEN=tok bash "$CFP" --model claude-opus-5-5 --slug claude --provider claude-subscription >"$W/out" 2>"$W/err" || RC=$?
check "6 still reviews under an ambient ANTHROPIC_BASE_URL" 0 "$RC"
check "6 claude saw no ANTHROPIC_/CLAUDE_CODE_USE_ variable" "" "$(cat "$REC/env" 2>/dev/null)"

# --- 7. effort override ---------------------------------------------------
fresh_rec 7; unset FAKE_REFUSE
RC=0; printf '%s\n' "$DIFF" | CR_CLAUDE_CRITIC_EFFORT=high bash "$CFP" --model claude-opus-5-5 --slug claude --provider claude-api >"$W/out" 2>"$W/err" || RC=$?
has "7 CR_CLAUDE_CRITIC_EFFORT overrides the row" "high" "$REC/argv"

# --- 7b. the claude row's effort follows the merged registry (overlay over base) ---
unset CR_CLAUDE_CRITIC_EFFORT CRITICS_JSON
printf '%s\n' '{"panel":[{"slug":"claude","effort":"xhigh"}]}' > "$W/local-effort.json"
fresh_rec 7b; unset FAKE_REFUSE
RC=0; printf '%s\n' "$DIFF" | CRITICS_BASE_JSON="$REPO/scripts/cr/critics.json" CRITICS_LOCAL_JSON="$W/local-effort.json" bash "$CFP" --model claude-opus-5-5 --slug claude --provider claude-api >"$W/out" 2>"$W/err" || RC=$?
effort_of() { awk 'p{print;exit} $0=="--effort"{p=1}' "$REC/argv"; }
check "7b the run succeeds" 0 "$RC"
check "7b an overlay effort reaches the claude critic as --effort" xhigh "$(effort_of)"
fresh_rec 7c; unset FAKE_REFUSE
RC=0; printf '%s\n' "$DIFF" | CR_CLAUDE_CRITIC_EFFORT=low CRITICS_BASE_JSON="$REPO/scripts/cr/critics.json" CRITICS_LOCAL_JSON="$W/local-effort.json" bash "$CFP" --model claude-opus-5-5 --slug claude --provider claude-api >"$W/out" 2>"$W/err" || RC=$?
check "7c the run succeeds" 0 "$RC"
check "7c CR_CLAUDE_CRITIC_EFFORT still wins over the overlay" low "$(effort_of)"
printf '%s\n' '{"panel":[{"slug":"claude","effort":"extreme"}]}' > "$W/local-bad.json"
fresh_rec 7d; unset FAKE_REFUSE
RC=0; printf '%s\n' "$DIFF" | CRITICS_BASE_JSON="$REPO/scripts/cr/critics.json" CRITICS_LOCAL_JSON="$W/local-bad.json" bash "$CFP" --model claude-opus-5-5 --slug claude --provider claude-api >"$W/out" 2>"$W/err" || RC=$?
check "7d the run succeeds" 0 "$RC"
check "7d an unknown overlay effort falls to medium" medium "$(effort_of)"
printf '%s\n' '{"panel":[{"slug":"claude","drop":true}]}' > "$W/local-drop.json"
fresh_rec 7e; unset FAKE_REFUSE
RC=0; printf '%s\n' "$DIFF" | CRITICS_BASE_JSON="$REPO/scripts/cr/critics.json" CRITICS_LOCAL_JSON="$W/local-drop.json" bash "$CFP" --model claude-opus-5-5 --slug claude --provider claude-api >"$W/out" 2>"$W/err" || RC=$?
check "7e the run succeeds" 0 "$RC"
check "7e a dropped claude row falls to medium" medium "$(effort_of)"

# --- 8. the other families are untouched: --print-prompt still works -------
RC=0; printf '%s\n' "$DIFF" | bash "$CFP" --model claude-opus-5-5 --slug claude --provider claude-api --print-prompt >"$W/out" 2>"$W/err" || RC=$?
check "8 --print-prompt exits 0 for the claude row" 0 "$RC"
has "8 claude family scaffolding" "IMPORTANT: Output EXACTLY" "$W/out"

# --- 9. the short provider spellings api / subscription ---------------------
fresh_rec 9; unset FAKE_REFUSE FAKE_FAIL
run_cfp api
check "9 provider 'api' routes to the API launcher" 0 "$RC"
has "9 launcher saw the call" "dontAsk" "$REC/argv"
fresh_rec 10; bank 10
run_cfp subscription
check "9 provider 'subscription' routes to the native claude" 0 "$RC"
has "9 claude saw the call" "Read,Glob,Grep" "$REC/argv"

_test_native_auth_skip

# --- 10. broke is not disabled: a crashed gate exits 1 (BROKE), a decision exits 5 (SKIPPED) ---
unset FAKE_REFUSE FAKE_REFUSE_RC
broke_case() { # broke_case <id> <refusal text>: the launcher refuses with that text
    fresh_rec "$1"; export FAKE_REFUSE="$2"
    run_cfp claude-api
    unset FAKE_REFUSE
}
broke_case 10a "no scratch file"
check "10a a scratch-file refusal is broke: exits 1" 1 "$RC"
has "10a stderr names BROKE" "claude critic BROKE" "$W/err"
broke_case 10b 'reservation refused: '
check "10b a reservation that returned no verdict is broke: exits 1" 1 "$RC"
has "10b stderr names BROKE" "claude critic BROKE" "$W/err"
broke_case 10c 'reservation refused: {"verdict":"HOLD","reason":"cap"}'
check "10c a reservation that said HOLD is a decision: exits 5" 5 "$RC"
has "10c stderr names SKIPPED" "claude critic SKIPPED" "$W/err"
broke_case 10c2 'reservation refused: {"verdict":"BANK-UNKNOWN","reason":"state-io-failure"}'
check "10c2 a reservation that answered BANK-UNKNOWN is broke: exits 1" 1 "$RC"
has "10c2 stderr names BROKE" "claude critic BROKE" "$W/err"
broke_case 10c4 'reservation refused: {"verdict":"SKIPPED-BANK","reason":"insufficient-headroom"}'
check "10c4 a reservation that said SKIPPED-BANK is a decision: exits 5" 5 "$RC"
broke_case 10c5 'reservation refused: {"verdict":""}'
check "10c5 a reservation with an empty verdict is broke: exits 1" 1 "$RC"
broke_case 10c6 'reservation refused: {"verdict":"WAT"}'
check "10c6 a reservation with an unrecognized verdict is broke: exits 1" 1 "$RC"
broke_case 10c3 'reservation refused: {"verdict":null}'
check "10c3 a reservation whose verdict is not a string is broke: exits 1" 1 "$RC"
broke_case 10d "api bank gate said BANK-UNKNOWN"
check "10d a bank preflight that crashed (BANK-UNKNOWN) is broke: exits 1" 1 "$RC"
has "10d stderr names BROKE" "claude critic BROKE" "$W/err"
broke_case 10e "api bank gate said HOLD"
check "10e a bank gate that said HOLD is a decision: exits 5" 5 "$RC"
# a refusal-shaped line from anything but the launcher's own exit 2 is not a skip
fresh_rec 10f; export FAKE_REFUSE="api lane is OFF (set HIMMEL_API_LANE=on)" FAKE_REFUSE_RC=1
run_cfp claude-api
check "10f a refusal line with exit 1 (not the launcher's own exit 2) is a failure" 1 "$RC"
unset FAKE_REFUSE FAKE_REFUSE_RC

fresh_rec 10k
ALERT_DIR_10K="$W/alerts.10k"; mkdir -p "$ALERT_DIR_10K"
printf '#!/bin/sh\ntouch "%s"\n' "$W/alert-ran.10k" > "$W/alert-stub.10k"; chmod +x "$W/alert-stub.10k"
RC=0; printf '%s\n' "$DIFF" | env -u ANTHROPIC_API_KEY CFP_CLAUDE_API_LAUNCHER="$REPO/scripts/api-lane/claude-api.sh" \
    HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=auto HIMMEL_API_ALERT_CMD="$W/alert-stub.10k" HIMMEL_API_ALERT_DIR="$ALERT_DIR_10K" \
    bash "$CFP" --model claude-opus-5-5 --slug claude --provider claude-api >"$W/out" 2>"$W/err" || RC=$?
check "10k the real launcher's policy refusal is broke: exits 1" 1 "$RC"
has "10k stderr names BROKE" "claude critic BROKE" "$W/err"
hasnt "10k stderr never says SKIPPED" "SKIPPED" "$W/err"
check "10k a broke critic prints no review" "" "$(cat "$W/out")"
check "10k the launcher recorded the policy refusal (one record per attempt)" yes "$([ "$(grep -c '"kind":"critic"' "$ALERT_DIR_10K/policy-refusals.jsonl" 2>/dev/null)" -ge 1 ] && echo yes || echo no)"
check "10k the policy refusal sent no alert" no "$([ -e "$W/alert-ran.10k" ] && echo yes || echo no)"
fresh_rec 10l; export FAKE_REFUSE="auto routing is for the himmel graph pass only (kind critic, repo none); name HIMMEL_API_ACCOUNT=A, B or C"
run_cfp claude-api
check "10l the policy wording without the launcher's marker line is a decision: exits 5" 5 "$RC"
unset FAKE_REFUSE

# a tree whose cfp is the real one but whose usage-preflight and hermes invoke are stubs
mk_tree() { # mk_tree <name>
    local T="$W/tree.$1" f
    rm -rf "$T"; mkdir -p "$T/scripts/cr" "$T/scripts/lib" "$T/scripts/hermes"
    for f in "$REPO"/scripts/cr/*; do ln -s "$f" "$T/scripts/cr/$(basename "$f")"; done
    for f in "$REPO"/scripts/lib/*; do ln -s "$f" "$T/scripts/lib/$(basename "$f")"; done
    rm "$T/scripts/cr/critic-first-pass.sh"; cp "$CFP" "$T/scripts/cr/critic-first-pass.sh"
    CFP_RUN="$T/scripts/cr/critic-first-pass.sh"; TREE="$T"
}
fresh_rec 10g; bank 10; mk_tree 10g
rm "$TREE/scripts/lib/usage-preflight.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 3' > "$TREE/scripts/lib/usage-preflight.sh"
run_cfp claude-subscription
check "10g a subscription bank preflight that crashed (no verdict) is broke: exits 1" 1 "$RC"
has "10g stderr names BROKE" "claude critic BROKE" "$W/err"
check "10g claude is not launched" "no" "$([ -e "$REC/argv" ] && echo yes || echo no)"
fresh_rec 10h; mk_tree 10h
rm "$TREE/scripts/lib/usage-preflight.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo HOLD' > "$TREE/scripts/lib/usage-preflight.sh"
run_cfp claude-subscription
check "10h a subscription bank verdict that is not PROCEED is a decision: exits 5" 5 "$RC"
fresh_rec 10i; mk_tree 10i
rm "$TREE/scripts/lib/usage-preflight.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo BANK-UNKNOWN' > "$TREE/scripts/lib/usage-preflight.sh"
run_cfp claude-subscription
check "10i a subscription bank verdict of BANK-UNKNOWN is broke: exits 1" 1 "$RC"
has "10i stderr names BROKE" "claude critic BROKE" "$W/err"
fresh_rec 10j; mk_tree 10j
rm "$TREE/scripts/lib/usage-preflight.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo SKIPPED-BANK' > "$TREE/scripts/lib/usage-preflight.sh"
run_cfp claude-subscription
check "10j a subscription bank verdict of SKIPPED-BANK is a decision: exits 5" 5 "$RC"

# --- 11. an rc 5 from the hermes invoke or the envelope unwrap is a failure, never a skip ---
fresh_rec 11a; mk_tree 11a
printf '%s\n' '#!/usr/bin/env bash' 'echo "invoke crashed" >&2' 'exit 5' > "$TREE/scripts/hermes/invoke.sh"
RC=0; printf '%s\n' "$DIFF" | bash "$CFP_RUN" --model qwen/qwen3-coder-480b-a35b-instruct >"$W/out" 2>"$W/err" || RC=$?
check "11a a hermes invoke that exits 5 is a failure (1), not a skip" 1 "$RC"
fresh_rec 11b; bank 10; mk_tree 11b
mkdir -p "$W/shim11b"
printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in *"j.type"*) cat >/dev/null; exit 5 ;; esac' "exec $(command -v node) \"\$@\"" > "$W/shim11b/node"
chmod +x "$W/shim11b/node"
PATH="$W/shim11b:$PATH" run_cfp claude-subscription
check "11b an envelope unwrap that exits 5 is a failure (1), not a skip" 1 "$RC"
unset CFP_RUN

# --- 12. R8: what a hostile diff can make the critic read stays inside the directory it is given ---
# The recorder shows the launch shape: a scratch cwd under TMPDIR, outside the repo, no widening flag, the grant exactly Read,Glob,Grep.
# What the claude binary itself does with an absolute path under dontAsk is NOT-VERIFIED here (no recorder sees it).
reach_shape() { # reach_shape <label> <rec dir> <route>: prints "ok" or the reason the reach could be wider
    local cwd argv grant
    cwd="$(cat "$2/cwd" 2>/dev/null)"; argv="$(cat "$2/argv" 2>/dev/null)"
    case "$cwd" in ""|/) echo "cwd '$cwd'"; return;; esac
    case "$cwd" in "${TMPDIR:-/tmp}"/*) ;; *) echo "cwd '$cwd' not under TMPDIR"; return;; esac
    case "$REPO/" in "$cwd"/*) echo "the repo sits inside cwd '$cwd'"; return;; esac
    case "$cwd/" in "$REPO"/*) echo "cwd '$cwd' is inside the repo"; return;; esac
    case "$argv" in *--add-dir*) echo "--add-dir in argv"; return;; esac
    if [ "$3" = sub ]; then
        grant="$(printf '%s\n' "$argv" | awk 'p { print; exit } $0 == "--allowedTools" { p = 1 }')"
    else
        grant="$(sed -n 's/^HIMMEL_API_TOOLS=//p' "$2/env")"
    fi
    [ "$grant" = "Read,Glob,Grep" ] || { echo "grant '$grant'"; return; }
    echo ok
}
fresh_rec 12a; unset FAKE_REFUSE FAKE_FAIL; run_cfp claude-api
check "12a api route: scratch cwd, no --add-dir, grant exactly Read,Glob,Grep" ok "$(reach_shape 12a "$REC" api)"
fresh_rec 12b; bank 10; run_cfp claude-subscription
check "12b subscription route: scratch cwd, no --add-dir, grant exactly Read,Glob,Grep" ok "$(reach_shape 12b "$REC" sub)"
fresh_rec 12c; bank 10; mk_tree 12c
sed 's|--allowedTools Read,Glob,Grep|--add-dir / --allowedTools Read,Glob,Grep|' "$TREE/scripts/cr/critic-first-pass.sh" > "$W/mutant.sh" && cp "$W/mutant.sh" "$TREE/scripts/cr/critic-first-pass.sh"
run_cfp claude-subscription
check "12c control: a call that widens the reach with --add-dir is told apart" "--add-dir in argv" "$(reach_shape 12c "$REC" sub)"
unset CFP_RUN
fresh_rec 12d; bank 10; mk_tree 12d
sed 's|--allowedTools Read,Glob,Grep|--allowedTools Read,Glob,Grep,Bash|' "$TREE/scripts/cr/critic-first-pass.sh" > "$W/mutant.sh" && cp "$W/mutant.sh" "$TREE/scripts/cr/critic-first-pass.sh"
run_cfp claude-subscription
check "12d control: a wider tool grant is told apart" "grant 'Read,Glob,Grep,Bash'" "$(reach_shape 12d "$REC" sub)"
unset CFP_RUN
ok "12e NOT-VERIFIED: the claude binary's refusal of an absolute Read outside the scratch cwd under dontAsk (a recorder cannot see it)"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
