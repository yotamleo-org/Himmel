#!/usr/bin/env bash
# adopted-features-guest.sh -- GUEST side of the VM e2e adopted-features stage.
#
# Runs ON a test VM against a staged himmel tree (scripts/vm/adopted-features-e2e.sh
# stages it and calls this). For each of the ten clone-only feature rows it adopts himmel into
# a scratch git project with scripts/adopt.sh, then HIDES the staged himmel tree
# (mv <tree> <tree>.away) so that nothing a row runs can reach the clone, and runs one
# check per row from the project:
#   1 /pr-check + review-owed gates   2 /cr-scores /cr-tune   3 no force push
#   4 check-ci.sh                     5 merge gate            6 merge-on-green solo
#   7 usage preflight                 8 /morning-report       9 inject-initiative
#  10 /afk-shift
# Each row prints `ROW <n> PASS|FINDING|FAIL <name>: <detail>`. A FINDING is a row that
# cannot run from an adopted project, with the cause; it never fails the stage, and a
# row is never skipped silently. gh is a stub on PATH (the credential-free guest has no
# gh auth), so no row proves a live authenticated forge verdict.
#
# Env: HIMMEL_ADOPTED_E2E_GUEST=1 (required: adopt writes into $HOME, so this refuses
#      anywhere but the VM driver); ADOPTED_E2E_RED=1 (RED control: row 3's adopted
#      gate is deleted before it runs, so row 3 must FAIL).
# Usage: HIMMEL_ADOPTED_E2E_GUEST=1 bash scripts/vm/adopted-features-guest.sh [tree-root]
# Exit: 0 no FAIL row and all ten rows reported; 1 a row failed; 2 not on the VM.
# The final line is `RESULT: N failure(s), M finding(s)`.
#
# Sourced (BASH_SOURCE != $0) it defines only the helpers and row functions, for the
# hermetic test.

row_report() { printf 'ROW %s %s %s: %s\n' "$1" "$3" "$2" "$4"; }

# rows_tally <file> -- prints the RESULT line; rc 1 on any FAIL row or when fewer than
# ten rows were reported (a row that never ran must not read as a pass).
rows_tally() {
  local f="$1" fails findings rows
  fails=$(grep -c '^ROW [0-9]* FAIL ' "$f"); findings=$(grep -c '^ROW [0-9]* FINDING ' "$f")
  rows=$(grep -c '^ROW [0-9]* \(PASS\|FINDING\|FAIL\) ' "$f")
  echo "RESULT: $fails failure(s), $findings finding(s)"
  [ "$fails" -eq 0 ] && [ "$rows" -ge 10 ]
}

# --- per-row state (set by the stage below) ----------------------------------------
# row_N reads: P (the adopted project root for it), SRC (the hidden himmel tree, for byte
# compares only), FH (fake HOME), BIN (stub dir), WORK. Each prints one ROW line.

_fail() { row_report "$1" "$2" FAIL "$3"; }
_pass() { row_report "$1" "$2" PASS "$3"; }
_find() { row_report "$1" "$2" FINDING "$3"; }

# adopt_project <name> -- a fresh git project adopted from the staged tree; prints its path.
adopt_project() {
  local d="$WORK/proj-$1"
  mkdir -p "$d"
  git init -q -b main "$d" || return 1
  git -C "$d" config user.name stage; git -C "$d" config user.email stage@vm.invalid
  HOME="$FH" bash "$TREE/scripts/adopt.sh" --profile core --scope project --target "$d" >"$WORK/adopt-$1.log" 2>&1 || {
    echo "adopt rc!=0 for project $1; log tail:" >&2; tail -n 15 "$WORK/adopt-$1.log" >&2; return 1; }
  printf '%s\n' "$d"
}

_copies_match() { # <row> <name> <project> <file>... -- every file present and byte-identical
  local n="$1" nm="$2" p="$3" f ref="$SRC"; shift 3
  [ -d "$ref" ] || ref="$TREE" # rows 6 and 9 run with the clone put back
  for f in "$@"; do
    [ -f "$p/$f" ] || { _fail "$n" "$nm" "$f was not copied into the project"; return 1; }
    cmp -s "$ref/$f" "$p/$f" || { _fail "$n" "$nm" "the project's $f differs from himmel's"; return 1; }
  done
}

row_1() {
  local nm="/pr-check + review-owed gates" p="$P1" f missing=""
  for f in .claude/commands/pr-check.md scripts/hooks/check-cr-before-push.sh scripts/hooks/check-cr-marker-on-pr-create.sh; do
    [ -f "$p/$f" ] || missing="$missing $f"
  done
  if [ -n "$missing" ]; then
    _find 1 "$nm" "not shipped by adopt.sh (absent from PORTABLE_FILES:$missing); HIMMEL-1570 closed with no code; the adopter route is the himmel-ops:pr-check plugin skill, which needs claude installed and logged in, absent on the credential-free guest"
    return 0
  fi
  _pass 1 "$nm" "command and both gate scripts are in the project (presence only)"
}

row_2() {
  local nm="/cr-scores /cr-tune /cr-learnings-refresh" p="$P2" f out anchor="$WORK/anchor-2"
  _copies_match 2 "$nm" "$p" .claude/commands/cr-scores.md .claude/commands/cr-tune.md .claude/commands/cr-learnings-refresh.md \
    scripts/cr/cr-scores.sh scripts/cr/cr-tune.sh scripts/cr/known-findings.sh scripts/cr/known-findings.json \
    scripts/cr/standards-cadence.sh scripts/cr/anchor-handoff.sh scripts/lib/handover-path.sh || return 0
  command -v node >/dev/null 2>&1 || { _fail 2 "$nm" "node is not on the guest PATH (cr-scores.sh needs it)"; return 0; }
  # The anchor hand-off byte-compares a few files against a scratch clone, never himmel's.
  mkdir -p "$anchor"; git init -q -b main "$anchor"
  for f in scripts/cr/anchor-handoff.sh scripts/cr/cr-scores.sh scripts/cr/known-findings.sh scripts/guardrails/lib.sh scripts/lib/load-dotenv.sh; do
    mkdir -p "$anchor/$(dirname "$f")"; cp "$p/$f" "$anchor/$f"
  done
  git -C "$anchor" add scripts
  {
    echo '{"kind":"finding","ts":"2026-07-01T10:00:00Z","branch":"b1","head":"aaaa111","model":"adopted-modelA","finding_id":"adopted-modelA-1","severity":"imp","file":"scripts/foo.sh","line":10,"verdict":"agreed"}'
    echo '{"kind":"finding","ts":"2026-07-01T10:01:00Z","branch":"b1","head":"aaaa111","model":"adopted-modelA","finding_id":"adopted-modelA-2","severity":"crit","file":"scripts/bar.sh","line":5,"verdict":"disproved"}'
  } > "$p/.git/cr-critic-scores.jsonl"
  out=$(cd "$p" && HOME="$FH" HIMMEL_REPO="$anchor" bash scripts/cr/cr-scores.sh 2>"$WORK/row2.err") \
    || { _fail 2 "$nm" "the project's cr-scores.sh failed: $(head -c 300 "$WORK/row2.err")"; return 0; }
  grep -q 'adopted-modelA' <<<"$out" || { _fail 2 "$nm" "cr-scores.sh did not print the project ledger's rows"; return 0; }
  out=$(cd "$p" && HOME="$FH" HIMMEL_REPO="$anchor" bash scripts/cr/cr-tune.sh 2>"$WORK/row2.err") \
    || { _fail 2 "$nm" "the project's cr-tune.sh failed: $(head -c 300 "$WORK/row2.err")"; return 0; }
  grep -q 'adopted-modelA' <<<"$out" || { _fail 2 "$nm" "cr-tune.sh did not mine the project ledger"; return 0; }
  _pass 2 "$nm" "cr-scores.sh and cr-tune.sh read the project's own .git/cr-critic-scores.jsonl; the three commands are byte-identical copies"
}

row_3() {
  local nm="no force push" p="$P3" remote="$WORK/remote-3.git" seed="$WORK/seed-3" out rc
  [ "${ADOPTED_E2E_RED:-0}" != 1 ] || rm -f "$p/scripts/hooks/check-no-force-push.sh"
  [ -f "$p/scripts/hooks/check-no-force-push.sh" ] || { _fail 3 "$nm" "check-no-force-push.sh was not copied into the project"; return 0; }
  git init -q --bare "$remote"; git init -q -b main "$seed"
  git -C "$seed" config user.name stage; git -C "$seed" config user.email stage@vm.invalid
  git -C "$p" remote add origin "$remote"; git -C "$seed" remote add origin "$remote"
  git -C "$seed" commit -q --allow-empty -m 'seed remote main'
  git -C "$seed" push -q origin main >/dev/null 2>&1 || { _fail 3 "$nm" "could not seed the remote's main"; return 0; }
  git -C "$p" checkout -q -b feat/force-3
  git -C "$p" commit -q --allow-empty --no-verify -m 'unrelated history' >/dev/null 2>&1
  out=$(HOME="$FH" git -C "$p" push --force origin HEAD:refs/heads/main 2>&1); rc=$?
  [ "$rc" -ne 0 ] || { _fail 3 "$nm" "a force push to main succeeded"; return 0; }
  grep -q "Force-push to 'main' is not allowed" <<<"$out" || { _fail 3 "$nm" "the force push was refused, but not by the no-force-push gate: $(head -c 300 <<<"$out")"; return 0; }
  [ "$(git -C "$remote" rev-parse main)" = "$(git -C "$seed" rev-parse main)" ] || { _fail 3 "$nm" "the remote's main moved despite the refusal"; return 0; }
  HOME="$FH" git -C "$p" push -q origin HEAD:refs/heads/feat/force-3 >/dev/null 2>&1 || { _fail 3 "$nm" "a fast-forward feature push was refused"; return 0; }
  _pass 3 "$nm" "force push to main refused by the project's pre-push gate (rc=$rc); fast-forward push landed"
}

_gh_stub_checkci() { # writes the check-ci gh stub (acme/widgets PR 7, all green) to $BIN/gh
  cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_GH_LOG:-/dev/null}"
jq_arg=""
a=("$@")
for ((i = 0; i < ${#a[@]}; i++)); do
  [ "${a[$i]}" = "--jq" ] && jq_arg="${a[$((i + 1))]}"
done
emit() { if [ -n "$jq_arg" ]; then printf '%s' "$1" | jq -r "$jq_arg"; else printf '%s\n' "$1"; fi; }
case "$1 ${2:-}" in
  "pr view"|"pr checks") [ "${3:-}" = "7" ] || { echo "unexpected PR selector: $*" >&2; exit 1; } ;;
esac
case "$1 ${2:-}" in
  "pr view")
    emit '{"url":"https://github.com/acme/widgets/pull/7","reviewDecision":"","headRefOid":"abc123","baseRefName":"main","title":"feat: x","mergeStateStatus":"CLEAN"}' ;;
  "pr checks") echo '[{"name":"ci","bucket":"pass","state":"SUCCESS"}]' ;;
  "api graphql")
    emit '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}' ;;
  "api repos/acme/widgets/rules/branches/main") : ;;
  "api repos/acme/widgets/branches/main/protection/required_status_checks") echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
  "api repos/acme/widgets/commits/abc123/statuses?per_page=100"|"api repos/acme/widgets/pulls/7/reviews") echo '[]' ;;
  "api -i") printf 'X-Ratelimit-Remaining: 4000\nX-Ratelimit-Reset: 9999999999\n' ;;
  *) echo "unhandled: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$BIN/gh"
}

row_4() {
  local nm="check-ci.sh" p="$P4" out rc
  [ -f "$p/scripts/check-ci.sh" ] || { _fail 4 "$nm" "check-ci.sh was not copied into the project"; return 0; }
  mkdir -p "$BIN/r4"; BIN="$BIN/r4" _gh_stub_checkci
  out=$(cd "$p" && PATH="$BIN/r4:$PATH" HOME="$FH" STUB_GH_LOG="$WORK/gh-4.log" CHECK_CI_POLL_INTERVAL=0 CHECK_CI_SETTLE=0 \
        CHECK_CI_CACHE=0 WORKER_SESSION_JIRA_STATUS=0 bash scripts/check-ci.sh 7 --max-wait 30 --grace 0 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { _fail 4 "$nm" "the project's check-ci.sh did not reach a green verdict (rc=$rc): $(tail -c 300 <<<"$out")"; return 0; }
  grep -q "all checks green + all review threads resolved (PR #7 @ abc123)" <<<"$out" \
    || { _fail 4 "$nm" "no green verdict line: $(tail -c 300 <<<"$out")"; return 0; }
  grep -q 'repos/acme/widgets/' "$WORK/gh-4.log" || { _fail 4 "$nm" "check-ci.sh did not query the project's own repo"; return 0; }
  if grep -qi 'yotamleo' "$WORK/gh-4.log" "$p/scripts/check-ci.sh"; then _fail 4 "$nm" "the copied script or its gh calls name the himmel repo"; return 0; fi
  _pass 4 "$nm" "green verdict for acme/widgets PR 7 from the project's own copy; gh is a stub (the guest has no gh auth, so a live authenticated verdict is not proven)"
}

row_5() {
  local nm="merge gate (block-unresolved-cr-merge.sh)" p="$P5" hook_cmd out rc head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "$BIN/r5"
  hook_cmd=$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command | select(contains("block-unresolved-cr-merge"))] | .[0] // empty' "$p/.claude/settings.json")
  [ -n "$hook_cmd" ] || { _fail 5 "$nm" "adopt did not wire the merge-gate PreToolUse hook"; return 0; }
  git -C "$p" config --local himmel.coderabbit true
  git -C "$p" remote add origin https://github.com/adopter/project.git
  git -C "$p" add scripts/ci/ci-trust-paths.txt
  git -C "$p" -c commit.gpgsign=false commit -q --no-verify -m 'chore: install merge trust policy' || { _fail 5 "$nm" "could not commit the seeded trust list"; return 0; }
  printf '%s\n' "{\"kind\":\"avail\",\"head\":\"$head\",\"model\":\"codex\",\"status\":\"ok\"}" \
    "{\"kind\":\"avail\",\"head\":\"$head\",\"model\":\"claude\",\"status\":\"ok\"}" > "$p/.git/cr-critic-scores.jsonl"
  cat > "$BIN/r5/gh" <<'EOF'
#!/usr/bin/env bash
H=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "$1 $2" in
  'pr view') printf '%s\n' "{\"number\":42,\"headRefOid\":\"$H\",\"url\":\"https://github.com/adopter/project/pull/42\"}" ;;
  'repo view')
    case "$*" in
      *defaultBranchRef*) echo main ;;
      *'json url'*) echo https://github.com/adopter/project ;;
      *) echo adopter/project ;;
    esac ;;
  'api graphql')
    case "$*" in
      *reviewThreads*)
        jq -n --argjson resolved "$(cat .git/fixture-resolved)" '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false},nodes:[{isResolved:$resolved,path:"README.md",line:1,comments:{nodes:[{author:{login:"coderabbitai"}}]}}]}}}}}' ;;
      *reviews*) echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":0,"nodes":[]}}}}}' ;;
      *) exit 1 ;;
    esac ;;
  'api repos/adopter/project/contents/scripts/ci/ci-trust-paths.txt?ref=main')
    git show refs/heads/main:scripts/ci/ci-trust-paths.txt 2>/dev/null || { echo 'HTTP 404' >&2; exit 1; } ;;
  "api repos/adopter/project/pulls/42") echo "$H|1" ;;
  'api repos/adopter/project/pulls/42/files'*) printf 'README.md\t\n' ;;
  "api repos/adopter/project/commits/$H/check-runs"*) echo '{"total_count":1,"check_runs":[{"name":"tests","status":"completed","conclusion":"success"}]}' ;;
  "api repos/adopter/project/commits/$H/statuses"*) echo '[{"context":"ci","state":"success","creator":{"id":1}}]' ;;
  *) printf 'unexpected gh fixture request: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$BIN/r5/gh"
  jq -n --arg cwd "$p" --arg h "$head" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:("gh pr merge 42 --squash --match-head-commit " + $h)}}' > "$WORK/row5-payload.json"
  _r5_run() (
    cd "$p" || exit 1
    unset GH GH_CMD CR_PROFILE CRITICS_JSON CRITICS_BASE_JSON CRITICS_LOCAL_JSON CR_MERGE_GATE_OK CI_MERGE_GATE_OK HIMMEL_CONSOLE_LEG HIMMELCTL_CACHE_DIR
    PATH="$BIN/r5:$PATH" HOME="$FH" CLAUDE_PROJECT_DIR="$p" bash -c "$hook_cmd" < "$WORK/row5-payload.json"
  )
  printf 'false\n' > "$p/.git/fixture-resolved"
  rc=0; out=$(_r5_run 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || { _fail 5 "$nm" "an unresolved finding must refuse with rc 2 (rc=$rc): $(head -c 300 <<<"$out")"; return 0; }
  grep -q 'unresolved CodeRabbit review thread' <<<"$out" || { _fail 5 "$nm" "refused for something other than the finding: $(head -c 300 <<<"$out")"; return 0; }
  printf 'true\n' > "$p/.git/fixture-resolved"
  rc=0; out=$(_r5_run 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || { _fail 5 "$nm" "a resolved finding with green CI must allow the merge (rc=$rc): $(head -c 300 <<<"$out")"; return 0; }
  _pass 5 "$nm" "the project's wired hook refused an unresolved finding (rc=2) and allowed the resolved one; gh is a stub"
}

row_6() {
  local nm="merge-on-green solo mode" p="$P6" out rc gdir="$BIN/gh6"
  _copies_match 6 "$nm" "$p" scripts/handover/merge-on-green.sh scripts/lib/check-pr-title.sh scripts/lib/ticket-id-internal.sh \
    scripts/ci/ticket-id-internal-authors.txt scripts/chokepoints.json || return 0
  # merge-on-green is anchored: HIMMEL_REPO names a himmel clone (a git repo with a himmel origin and chief-kit/go.sh).
  if [ ! -d "$TREE/.git" ]; then
    git -C "$TREE" init -q -b main || { _fail 6 "$nm" "could not make the staged clone a git anchor"; return 0; }
    git -C "$TREE" remote add origin https://github.com/himmel-org/himmel.git
  fi
  mkdir -p "$gdir"
  cat > "$gdir/gh" <<'EOS'
#!/usr/bin/env bash
a=("$@"); jq_arg=""
for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[$i]}" = "--jq" ] && jq_arg="${a[$((i + 1))]}"; done
emit() { if [ -n "$jq_arg" ]; then printf '%s' "$1" | jq -r "$jq_arg"; else printf '%s\n' "$1"; fi; }
H=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "$*" in
  'pr view 5'*) emit "{\"number\":5,\"headRefOid\":\"$H\",\"url\":\"https://github.com/acme/widgets/pull/5\",\"baseRefName\":\"main\",\"title\":\"feat(widgets): add the widget #1\",\"state\":\"OPEN\",\"isDraft\":false,\"reviewDecision\":\"\",\"headRefName\":\"feat/x\",\"mergeStateStatus\":\"CLEAN\"}" ;;
  'repo view acme/widgets'*) emit '{"isPrivate":true,"defaultBranchRef":{"name":"main"},"nameWithOwner":"acme/widgets"}' ;;
  'repo view'*) emit '{"nameWithOwner":"acme/widgets","url":"https://github.com/acme/widgets"}' ;;
  'pr checks 5'*) emit '[{"name":"ci","bucket":"pass","state":"SUCCESS"}]' ;;
  'api -i'*) printf 'HTTP/2 200\nX-Ratelimit-Remaining: 4000\nX-Ratelimit-Reset: 9999999999\n\n{}\n' ;;
  'api rate_limit'*) emit '{"resources":{"core":{"remaining":4000,"reset":9999999999},"graphql":{"remaining":4000,"reset":9999999999}}}' ;;
  'api --method GET --include '*check-runs*) printf 'HTTP/2 200\n\n{"total_count":1,"check_runs":[{"name":"ci","status":"completed","conclusion":"success"}]}\n' ;;
  'api graphql'*) emit '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}' ;;
  'api repos/acme/widgets/rules/branches/main'*) : ;;
  'api repos/acme/widgets/branches/main/protection'*) echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
  'api repos/acme/widgets/commits/'*statuses*|'api repos/acme/widgets/pulls/5/reviews'*) echo '[]' ;;
  'api repos/acme/widgets/pulls/5/files'*) printf 'README.md\t\n' ;;
  'api repos/acme/widgets/contents/scripts/ci/ci-trust-paths.txt'*) cat "$ROW6_PROJ/scripts/ci/ci-trust-paths.txt" ;;
  'api repos/acme/widgets/pulls/5 '*|'api repos/acme/widgets/pulls/5') echo "$H|1" ;;
  'run list'*) emit '[{"databaseId":1,"status":"completed","conclusion":"success","event":"push","headSha":"bbbb","attempt":1,"createdAt":"2026-10-30T00:00:00Z"}]' ;;
  'pr merge'*) echo "UNEXPECTED gh pr merge in a dry run" >&2; exit 1 ;;
  *) echo "unhandled gh $*" >&2; exit 1 ;;
esac
EOS
  chmod +x "$gdir/gh"
  git -C "$p" config --local himmel.mergeMode solo
  git -C "$p" remote get-url origin >/dev/null 2>&1 || git -C "$p" remote add origin https://github.com/acme/widgets.git
  out=$(cd "$p" && ARMAUTOMERGE=1 ROW6_PROJ="$p" PATH="$gdir:$PATH" HOME="$FH" HIMMEL_REPO="$TREE" \
          CHECK_CI_POLL_INTERVAL=0 CHECK_CI_SETTLE=0 CHECK_CI_CACHE=0 WORKER_SESSION_JIRA_STATUS=0 \
          bash "$TREE/scripts/handover/merge-on-green.sh" --dry-run 5 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then _fail 6 "$nm" "solo-mode --dry-run from the project refused (rc=$rc): $(tail -c 400 <<<"$out")"; return 0; fi
  grep -q 'DRYRUN would-merge .*mode=solo' <<<"$out" || { _fail 6 "$nm" "no solo-mode would-merge audit line: $(tail -c 300 <<<"$out")"; return 0; }
  _pass 6 "$nm" "project solo-mode --dry-run passed every gate (check-ci, title, trust paths, main-red) and audited would-merge mode=solo; anchored on the staged clone, gh is a stub"
}

row_7() {
  local nm="usage preflight" p="$P7" out acct cache="$WORK/usage-cache.json" now
  [ -f "$p/scripts/lib/usage-preflight.sh" ] || { _fail 7 "$nm" "usage-preflight.sh was not copied into the project"; return 0; }
  mkdir -p "$FH/.himmel"
  printf '{"policy":{"HIMMEL_FLEET_CAP":50}}\n' > "$FH/.himmel/config.json"
  printf '{"oauthAccount":{"accountUuid":"11111111-2222-3333-4444-555555555555"}}\n' > "$FH/.claude.json"
  acct=$(printf '%s' "11111111-2222-3333-4444-555555555555" | sha256sum | cut -c1-16)
  now=$(date +%s)
  _r7_cache() {
    jq -n --argjson five "$1" --argjson seven "$2" --arg acct "$acct" --argjson now "$now" '{
      five_hour: {utilization: $five, resets_at: "2026-10-22T05:39:59.541164+00:00"},
      seven_day: {utilization: $seven, resets_at: "2026-10-24T08:59:59.541212+00:00"},
      extra_usage: {is_enabled: false, utilization: null},
      oauth_checked_at: $now, derived_at: $now, primaries_refreshed_at: $now, account: $acct}' > "$cache"
  }
  _r7_run() {
    (cd "$p" && HOME="$FH" CADENCE_USAGE_CACHE="$cache" CADENCE_USAGE_LEDGER="$FH/.himmel/cadence-ledger.jsonl" \
       CADENCE_USAGE_SKIP_REFRESH=1 HIMMEL_POLICY_FOLLOWS_HOME=1 HIMMEL_FLEET_SLOTS="$WORK/usage-slots" \
       bash scripts/lib/usage-preflight.sh 2>"$WORK/row7.err")
  }
  _r7_cache 10 20
  out=$(_r7_run) || { _fail 7 "$nm" "the project's usage-preflight.sh failed: $(head -c 300 "$WORK/row7.err")"; return 0; }
  [ "$out" = "PROCEED" ] || { _fail 7 "$nm" "no PROCEED on a low-usage cache: $out $(head -c 200 "$WORK/row7.err")"; return 0; }
  _r7_cache 10 99
  out=$(_r7_run) || { _fail 7 "$nm" "usage-preflight.sh failed on a high-usage cache"; return 0; }
  [ "$out" = "SKIPPED-BANK" ] || { _fail 7 "$nm" "no hold on a 99% seven_day cache: $out"; return 0; }
  grep -q '"verdict":"PROCEED"' "$FH/.himmel/cadence-ledger.jsonl" || { _fail 7 "$nm" "no ledger row under the project's HOME"; return 0; }
  _pass 7 "$nm" "PROCEED on a 20% cache, SKIPPED-BANK on 99%, ledger row written under the project's HOME"
}

row_8() {
  local nm="/morning-report" p="$P8" out="$WORK/morning-report.md" rc fakegh="$BIN/fake-gh-8"
  _copies_match 8 "$nm" "$p" .claude/commands/morning-report.md scripts/handover/generate-morning-briefing.sh scripts/lib/result.sh || return 0
  cat > "$fakegh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*"--state merged"*|*"pr list"*"merged"*) echo '[{"number":7,"title":"add widget","mergedAt":"2026-05-25T00:00:00Z"}]' ;;
  *"pr list"*) echo '[]' ;;
  *) echo '[]' ;;
esac
EOF
  chmod +x "$fakegh"
  git -C "$p" remote add origin git@github.com:acme/widgets.git 2>/dev/null
  git -C "$p" -c commit.gpgsign=false commit -q --allow-empty --no-verify -m "feat: second widget"
  (cd "$p" && env -u JIRA_PROJECT_KEY -u JIRA_CMD -u TRACKER HOME="$FH" GH_CMD="$fakegh" \
     bash scripts/handover/generate-morning-briefing.sh --out "$out" >"$WORK/row8.out" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ -f "$out" ] || { _fail 8 "$nm" "the generator did not write a report (rc=$rc): $(head -c 300 "$WORK/row8.out")"; return 0; }
  grep -q 'Morning Report' "$out" || { _fail 8 "$nm" "the report has no Morning Report heading"; return 0; }
  grep -q 'feat: second widget' "$out" || { _fail 8 "$nm" "the report does not list the project's own commit"; return 0; }
  if grep -q 'HIMMEL' "$out"; then _fail 8 "$nm" "the report names HIMMEL (it read himmel state, not the project's)"; return 0; fi
  _pass 8 "$nm" "the project's generator wrote a report from the project's own git history, with no himmel tracker state; gh is a stub"
}

row_9() {
  local nm="inject-initiative SessionStart hook" p="$P9" s ss_cmd out clone="$WORK/clone-9"
  s="$p/.claude/settings.json"
  ss_cmd=$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command | select(contains("inject-initiative"))] | .[0] // empty' "$s")
  [ -n "$ss_cmd" ] || { _fail 9 "$nm" "adopt did not wire the inject-initiative SessionStart hook in the project"; return 0; }
  mkdir -p "$clone"; printf 'HIMMEL_INITIATIVE=pr\n' > "$clone/.env"
  out=$(cd "$p" && unset HIMMEL_INITIATIVE HIMMEL_AFK HIMMEL_INITIATIVE_AFK && HOME="$FH" HIMMEL_REPO="$clone" bash -c "$ss_cmd" </dev/null 2>&1)
  grep -q 'HIMMEL_INITIATIVE is active' <<<"$out" || { _fail 9 "$nm" "a set step did not reach the session: $(head -c 300 <<<"$out")"; return 0; }
  out=$(cd "$p" && unset HIMMEL_INITIATIVE HIMMEL_AFK HIMMEL_INITIATIVE_AFK && HOME="$FH" HIMMEL_REPO="$WORK/no-such-clone" bash -c "$ss_cmd" </dev/null 2>&1)
  ! grep -q 'HIMMEL_INITIATIVE is active' <<<"$out" || { _fail 9 "$nm" "an unset step still injected"; return 0; }
  _pass 9 "$nm" "the project-scope hook injects a set step and nothing when unset"
}

row_10() {
  local nm="/afk-shift" p="$P10" key rc out
  _copies_match 10 "$nm" "$p" .claude/commands/afk-shift.md scripts/afk/build-plan.sh scripts/afk/self-heal.sh scripts/afk/stop-marker.sh \
    scripts/afk/morning-report.sh scripts/afk/morning-report.default.tmpl scripts/afk/project-state.sh .claude/commands/stop.md || return 0
  mkdir -p "$WORK/handovers"
  key=$(cd "$p" && HOME="$FH" HANDOVER_DIR="$WORK/handovers" bash scripts/afk/project-state.sh key 2>&1) || { _fail 10 "$nm" "project-state.sh key failed: $key"; return 0; }
  (cd "$p" && HOME="$FH" HANDOVER_DIR="$WORK/handovers" bash scripts/afk/project-state.sh legacy >/dev/null 2>&1); rc=$?
  [ "$rc" -eq 1 ] || { _fail 10 "$nm" "an adopted project must not use the clone's legacy paths (legacy rc=$rc)"; return 0; }
  (cd "$p" && HOME="$FH" HANDOVER_DIR="$WORK/handovers" bash scripts/afk/stop-marker.sh set) || { _fail 10 "$nm" "stop-marker set failed"; return 0; }
  [ -e "$FH/.claude/afk/$key/.overnight-stop" ] || { _fail 10 "$nm" "the stop marker is not under ~/.claude/afk/$key/"; return 0; }
  [ ! -e "$FH/.claude/.overnight-stop" ] || { _fail 10 "$nm" "the stop marker landed on the clone's global path"; return 0; }
  printf 'ACME-1\tfeat/acme-1\t#12\tdone\tshipped the widget\nACME-2\tfeat/acme-2\t\tblocked\twaiting on review\tpick a vendor\n' > "$WORK/rows-10.tsv"
  out=$(cd "$p" && HOME="$FH" HANDOVER_DIR="$WORK/handovers" REVIEW_ROUNDS_TXT=/dev/null bash scripts/afk/morning-report.sh --rows "$WORK/rows-10.tsv" --no-unlanded --dry-run 2>&1); rc=$?
  if [ "$rc" -ne 0 ] || ! grep -q 'ACME-2' <<<"$out"; then _fail 10 "$nm" "the project's morning-report.sh did not render the rows (rc=$rc): $(head -c 300 <<<"$out")"; return 0; fi
  (cd "$p" && HOME="$FH" HANDOVER_DIR="$WORK/handovers" bash scripts/afk/stop-marker.sh clear) >/dev/null 2>&1
  _pass 10 "$nm" "per-project key $key, stop marker and shift report under the project's own state paths, not the clone's"
}

# Sourced for the helpers and rows only: stop here.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  # shellcheck disable=SC2317  # reached when sourced
  return 0
fi

# --- stage ------------------------------------------------------------------------
set -uo pipefail

if [ "${HIMMEL_ADOPTED_E2E_GUEST:-}" != 1 ]; then
  echo "adopted-features-guest: HIMMEL_ADOPTED_E2E_GUEST=1 is required (adopt writes into HOME: run this on the test VM via adopted-features-e2e.sh)" >&2
  exit 2
fi

TREE="$(cd -- "${1:-$(dirname -- "${BASH_SOURCE[0]}")/../..}" && pwd)"
SRC="$TREE.away"
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$PATH"
WORK="$HOME/.himmel-adopted-stage"   # fixed: the stage rm -rf's it, so no caller-chosen path
rm -rf "$WORK" "$SRC"; mkdir -p "$WORK"
FH="$WORK/home"; BIN="$WORK/bin"; mkdir -p "$FH" "$BIN"
LOG="$WORK/rows.txt"; : > "$LOG"

echo "---- VM: $(uname -srm) ----"
for t in git jq bash python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "adopted-features-guest: $t is not on the guest" >&2; exit 2; }
done

# Adopt every project first, while the staged tree is still in place.
adopt_failed=""
for n in 1 2 3 4 5 6 7 8 9 10; do
  if p=$(adopt_project "$n"); then printf -v "P$n" '%s' "$p"; else adopt_failed="$adopt_failed $n"; printf -v "P$n" '%s' ""; fi
done
# From here on nothing may reach the staged himmel tree: the rows run from the projects.
mv "$TREE" "$SRC" || { echo "adopted-features-guest: cannot hide the staged tree" >&2; exit 2; }
cd "$WORK" || exit 2

for n in 1 2 3 4 5 6 7 8 9 10; do
  case " $adopt_failed " in
    *" $n "*) row_report "$n" "adopt" FAIL "adopt.sh failed for this row's project (see $WORK/adopt-$n.log)" | tee -a "$LOG"; continue ;;
  esac
  # Rows 6 and 9 are clone-anchored by design (adopt wires the hook and the merge anchor to the clone path): bring it back for those rows only.
  case "$n" in 6|9) mv "$SRC" "$TREE" ;; esac
  "row_$n" | tee -a "$LOG"
  case "$n" in 6|9) mv "$TREE" "$SRC" ;; esac
done

rows_tally "$LOG"
rc=$?
mv "$SRC" "$TREE" 2>/dev/null
exit "$rc"
