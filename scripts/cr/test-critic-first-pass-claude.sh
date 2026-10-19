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
export CADENCE_BANK_CACHE="$W/bank.json" CADENCE_BANK_SKIP_REFRESH=1 CADENCE_BANK_LEDGER="$W/bank-ledger.jsonl"
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
printf '%s\n' "HIMMEL_API_TOOLS=${HIMMEL_API_TOOLS:-}" "HIMMEL_API_KIND=${HIMMEL_API_KIND:-}" > "$REC/env"
if [ -n "${FAKE_REFUSE:-}" ]; then echo "claude-api: refused: $FAKE_REFUSE" >&2; exit 2; fi
[ -z "${FAKE_FAIL:-}" ] || { echo "boom" >&2; exit 1; }
cat "$ENVELOPE"
EOF
chmod +x "$LAUNCH"
export ENVELOPE="$W/envelope.json" HIMMEL_CLAUDE_BIN="$FAKE" CFP_CLAUDE_API_LAUNCHER="$LAUNCH"

fresh_rec() { REC="$W/rec.$1"; rm -rf "$REC"; mkdir -p "$REC"; export REC; }
run_cfp() { # run_cfp <provider> [extra args]; stdout -> $W/out, stderr -> $W/err
    local p="$1"; shift
    RC=0; printf '%s\n' "$DIFF" | bash "$CFP" --model claude-opus-5-5 --slug claude --provider "$p" "$@" >"$W/out" 2>"$W/err" || RC=$?
}

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

# --- 8. the other families are untouched: --print-prompt still works -------
RC=0; printf '%s\n' "$DIFF" | bash "$CFP" --model claude-opus-5-5 --slug claude --provider claude-api --print-prompt >"$W/out" 2>"$W/err" || RC=$?
check "8 --print-prompt exits 0 for the claude row" 0 "$RC"
has "8 claude family scaffolding" "IMPORTANT: Output EXACTLY" "$W/out"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
