#!/usr/bin/env bash
# scripts/eval/lane-quality/test-mine-tasks.sh - hermetic suite for the
# real-task miner and the calibrated grader. No real claude call: a fake binary
# stands in for the agent and the judge, a fake preflight for the bank.
#  1. the miner finds merged changes with a test, tags bug tickets, and skips
#     docs-only, hook and self-referencing changes;
#  2. an emitted task carries the ticket text, the base sha and the named
#     checks, and no fix, no hidden test body and no failure text;
#  3. validate keeps a task only when its hidden test fails at the base and
#     passes at the merge;
#  4. acceptance copies the hidden test over the agent's copy, so a no-op fails;
#  5. a real task runs in a fresh repo that cannot reach the fix;
#  6. the grader: claims become integer scores, a second grading counts flips,
#     the judge is never the model under test, the pairwise judge is blind and
#     records its order; plumbing failures are counted apart;
#  7. a no-op test fails acceptance on cr-fix, hook-refusal and doc-plus-code.
#
# check() evals its condition, so the single quotes and the variables only
# named inside a condition are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
export HIMMEL_BILLED_OK=1   # stubbed claude only
HERE="$(cd "$(dirname "$0")" && pwd)"
MT="$HERE/mine-tasks.py"
RUN="$HERE/run.sh"
REAL_REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mine-tasks-test.XXXXXX")" || { echo "test-mine-tasks: mktemp -d failed" >&2; exit 1; }
trap 'git -C "$TMP/src" worktree prune >/dev/null 2>&1; rm -rf "$TMP"' EXIT
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/eval-runs.jsonl"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
nogrep() { grep "$@"; [ $? -eq 1 ]; }
G() { git -C "$TMP/src" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# A tiny history: c1 base, c2 a bug fix with its RED test change, c3 a test
# that already passes at the base, c4 docs only, c5 a hook change.
mkdir -p "$TMP/src/lib" "$TMP/src/tests" "$TMP/src/scripts/hooks"
printf '#!/usr/bin/env bash\necho "hello"\n' >"$TMP/src/lib/greet.sh"
cat >"$TMP/src/tests/test-greet.sh" <<'T'
#!/usr/bin/env bash
fail=0
check() { if eval "$2"; then echo "ok $1"; else echo "FAIL $1"; fail=1; fi; }
check "greets plainly" '[ "$(bash lib/greet.sh)" = hello ]'
exit "$fail"
T
printf '# greet\n' >"$TMP/src/README.md"
git -C "$TMP/src" init -q -b main
G add -A && G commit -qm 'feat(greet): [HIMMEL-9000] greet (#40)'
C1="$(git -C "$TMP/src" rev-parse HEAD)"
printf '#!/usr/bin/env bash\necho "hello${1:+ $1}"  # LQ-FIX-MARKER\n' >"$TMP/src/lib/greet.sh"
mkdir -p "$TMP/src/tests/fixtures"; printf 'Bob\n' >"$TMP/src/tests/fixtures/names.txt"; chmod +x "$TMP/src/tests/fixtures/names.txt"
cat >"$TMP/src/tests/test-greet.sh" <<'T'
#!/usr/bin/env bash
fail=0
check() { if eval "$2"; then echo "ok $1"; else echo "FAIL $1"; fail=1; fi; }
check "greets plainly" '[ "$(bash lib/greet.sh)" = hello ]'
check "greets by the name it is given" '[ "$(bash lib/greet.sh "$(cat tests/fixtures/names.txt)")" = "hello Bob" ]'
exit "$fail"
T
G add -A && G commit -qm 'fix(greet): [HIMMEL-9001] greet says the name it is given (#41)'
C2="$(git -C "$TMP/src" rev-parse HEAD)"
printf '# greet\n\nUsage: greet.sh [name]\n' >"$TMP/src/README.md"
cat >"$TMP/src/tests/test-plain.sh" <<'T'
#!/usr/bin/env bash
[ "$(bash lib/greet.sh)" = hello ] && echo "ok plain greeting is unchanged"
T
G add -A && G commit -qm 'feat(greet): [HIMMEL-9002] the plain greeting stays covered (#42)'
C3="$(git -C "$TMP/src" rev-parse HEAD)"
printf '# greet\n\nSays hello.\n' >"$TMP/src/README.md"
G add -A && G commit -qm 'docs(greet): [HIMMEL-9003] readme (#43)'
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/src/scripts/hooks/h.sh"
printf '#!/usr/bin/env bash\nbash scripts/hooks/h.sh && echo "ok hook allows"\n' >"$TMP/src/scripts/hooks/test-h.sh"
G add -A && G commit -qm 'fix(hooks): [HIMMEL-9004] hook (#44)'

mkdir -p "$TMP/mirror"
printf -- '---\nkey: "HIMMEL-9001"\ntype: "Bug"\n---\n\n%s\n\n## Description\n\n%s\n\n```\n%s\n%s\n```\n\n%s\n%s\n' \
  '# HIMMEL-9001: greet ignores the name it is given' 'greet.sh prints hello but drops the name argument.' \
  '$ bash tests/test-greet.sh' 'FAIL greets by the name it is given' \
  'Traceback-like noise: exit code 1 from the suite.' 'Fix: greet.sh appends the name when one is given.' >"$TMP/mirror/HIMMEL-9001.md"
printf 'Seen in /home/jane.doe/work and /Users/jdoe/src.\n' >>"$TMP/mirror/HIMMEL-9001.md"  # leak-allow: home-path redaction fixture
printf 'Also: a run that fails to load the names file says so.\n' >>"$TMP/mirror/HIMMEL-9001.md"
printf -- '---\nkey: "HIMMEL-9002"\ntype: "Task"\n---\n\n# HIMMEL-9002: keep the plain greeting covered\n\n## Description\n\nAdd a usage line.\n' >"$TMP/mirror/HIMMEL-9002.md"

echo "1. candidates"
python3 "$MT" candidates --repo "$TMP/src" --rev main --mirror "$TMP/mirror" >"$TMP/cand.jsonl" 2>"$TMP/cand.err"
check "candidates exits 0" '[ -s "$TMP/cand.jsonl" ]'
check "the bug fix with a RED test change is a candidate, tagged bug" 'jq -s -e --arg c "$C2" "map(select(.merge_sha == \$c))[0] | .source == \"bug\" and .base_sha == \"$C1\" and .ticket == \"HIMMEL-9001\" and .pr == 41 and .tests == [\"tests/test-greet.sh\"] and .fixtures == [\"tests/fixtures/names.txt\"]" "$TMP/cand.jsonl" >/dev/null'
check "a docs-only change is not a candidate" '[ "$(jq -s "map(select(.ticket == \"HIMMEL-9003\")) | length" "$TMP/cand.jsonl")" = 0 ]'
check "a hook change is not a candidate" '[ "$(jq -s "map(select(.ticket == \"HIMMEL-9004\")) | length" "$TMP/cand.jsonl")" = 0 ]'
check "a non-bug ticket is tagged proof-first" '[ "$(jq -s -r "map(select(.ticket == \"HIMMEL-9002\"))[0].source" "$TMP/cand.jsonl")" = proof-first ]'

echo "2. emit"
mkdir -p "$TMP/lq"; cp "$MT" "$TMP/lq/"  # accept.sh finds the miner two levels above its task
python3 "$MT" emit --repo "$TMP/src" --mirror "$TMP/mirror" --tasks-dir "$TMP/lq/tasks" --sha "$C2" >"$TMP/emit.out" 2>&1
T1="$TMP/lq/tasks/real-himmel-9001-41"
check "emit writes the task directory, the ticket text under fixture/" '[ ! -e "$T1/prompt.md" ] && [ -f "$T1/fixture/prompt.md" ] && [ -f "$T1/task.json" ] && [ -x "$T1/accept.sh" ]'
check "the prompt carries the ticket text and the named checks" 'grep -q "greet ignores the name" "$T1/fixture/prompt.md" && grep -q "greets by the name it is given" "$T1/fixture/prompt.md" && grep -q "tests/test-greet.sh" "$T1/fixture/prompt.md"'
check "the prompt carries no failure text" 'nogrep -qE "FAIL|Traceback|exit code" "$T1/fixture/prompt.md"'
check "a requirement that names a failure stays in the prompt" 'grep -qF "fails to load the names file" "$T1/fixture/prompt.md"'
check "a home path in the ticket text is redacted to a placeholder" 'grep -qF "/home/<user>/work and /Users/<user>/src" "$T1/fixture/prompt.md" && nogrep -qE "jane|jdoe" "$T1/fixture/prompt.md"'
check "the prompt carries no fix" 'nogrep -q "LQ-FIX-MARKER" "$T1/fixture/prompt.md" && nogrep -qF "hello\${1" "$T1/fixture/prompt.md"'
check "task.json records base, merge, set, source and why_hard" 'jq -e --arg b "$C1" --arg m "$C2" ".base_sha == \$b and .merge_sha == \$m and .set == \"capability\" and .source == \"bug\" and .ticket == \"HIMMEL-9001\" and .pr == 41 and (.why_hard | length > 0) and .scope == [\"lib/\", \"tests/\"]" "$T1/task.json" >/dev/null'
check "the hidden test is the merged version, stored gzipped as .ref.gz" 'cmp -s <(gzip -dc "$T1/hidden/tests/test-greet.sh.ref.gz") <(git -C "$TMP/src" show "$C2:tests/test-greet.sh") && [ -f "$T1/hidden/tests/fixtures/names.txt.ref.gz" ]'
check "nothing under hidden/ is a runnable or indexable file" '[ -z "$(find "$T1/hidden" -type f ! -name "*.ref.gz")" ] && nogrep -rqF "greets by the name" "$T1/hidden"'
python3 "$MT" emit --repo "$TMP/src" --mirror "$TMP/mirror" --tasks-dir "$TMP/lq/tasks" --sha "$C3" >/dev/null 2>&1
T3="$TMP/lq/tasks/real-himmel-9002-42"

echo "3. validate"
python3 "$MT" validate "$T1" --repo "$TMP/src" >"$TMP/val1.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] || sed -n "1,12p" "$TMP/val1.out" | sed "s/^/    val1: /"
check "a hidden test that fails at the base and passes at the merge is kept" '[ "$rc" -eq 0 ] && grep -q "base: fails" "$TMP/val1.out" && grep -q "merge: passes" "$TMP/val1.out"'
python3 "$MT" validate "$T3" --repo "$TMP/src" >"$TMP/val3.out" 2>&1; rc=$?
check "a hidden test that already passes at the base is refused" '[ "$rc" -ne 0 ] && grep -q "base: passes" "$TMP/val3.out"'
grep -q "base: passes" "$TMP/val3.out" || sed -n "1,12p" "$TMP/val3.out" | sed "s/^/    val3: /"

echo "4. acceptance replaces the agent's copy of the test"
tree() { mkdir -p "$TMP/$1" && git -C "$TMP/src" archive "$2" | tar -x -C "$TMP/$1"; }
tree acc-base "$C1"; tree acc-merge "$C2"; tree acc-noop "$C1"
check "accept fails on the untouched base" '! bash "$T1/accept.sh" "$TMP/acc-base" x >"$TMP/acc-base.log" 2>&1 && grep -q "^accept: " "$TMP/acc-base.log"'
check "accept passes on the merged fix" 'bash "$T1/accept.sh" "$TMP/acc-merge" x >"$TMP/acc-merge.log" 2>&1'
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/acc-noop/tests/test-greet.sh"
check "an exit-0 test in the agent's tree does not pass acceptance" '! bash "$T1/accept.sh" "$TMP/acc-noop" x >/dev/null 2>&1'
printf 'outside\n' >"$TMP/outside.txt"; mkdir -p "$TMP/outside-dir"
tree acc-link "$C2"; ln -sf "$TMP/outside.txt" "$TMP/acc-link/tests/test-greet.sh"
tree acc-dlink "$C2"; rm -r "$TMP/acc-dlink/tests"; ln -s "$TMP/outside-dir" "$TMP/acc-dlink/tests"
bash "$T1/accept.sh" "$TMP/acc-link" x >/dev/null 2>&1; bash "$T1/accept.sh" "$TMP/acc-dlink" x >/dev/null 2>&1
check "the hidden overlay replaces a symlink in the agent's tree, never writes through it" '[ "$(cat "$TMP/outside.txt")" = outside ] && [ -z "$(ls -A "$TMP/outside-dir")" ]'
GP="$TMP/lq/tasks/git-probe"; mkdir -p "$GP/hidden/tests"
printf '{"id": "git-probe", "tests": ["tests/test-git.sh"]}\n' >"$GP/task.json"
printf '#!/usr/bin/env bash\ncase "$(cd "$(git rev-parse --git-common-dir)" && pwd -P)" in "$(pwd -P)"/*) exit 0 ;; esac\nexit 1\n' | gzip -n >"$GP/hidden/tests/test-git.sh.ref.gz"
git -C "$TMP/src" worktree add -q --detach "$TMP/acc-wt" "$C2"
check "acceptance over a linked worktree runs git in its own scratch repo" 'python3 "$MT" accept "$GP" "$TMP/acc-wt" >"$TMP/acc-wt.log" 2>&1'
BG="$TMP/lq/tasks/bg-probe"; mkdir -p "$BG/hidden/tests" "$TMP/acc-empty"
printf '{"id": "bg-probe", "tests": ["tests/test-bg.sh"]}\n' >"$BG/task.json"
printf '#!/usr/bin/env bash\nsleep 300 &\necho $! >%s\n' "$TMP/bg.pid" | gzip -n >"$BG/hidden/tests/test-bg.sh.ref.gz"
python3 "$MT" accept "$BG" "$TMP/acc-empty" >/dev/null 2>&1
check "a hidden test leaves no process behind once acceptance returns" '[ -s "$TMP/bg.pid" ] && ! kill -0 "$(cat "$TMP/bg.pid")" 2>/dev/null'
check "emit records which hidden files are executable" 'jq -e ".exec == [\"tests/fixtures/names.txt\"]" "$T1/task.json" >/dev/null'
EX="$TMP/lq/tasks/exec-probe"; mkdir -p "$EX/hidden/tests"
printf '{"id": "exec-probe", "tests": ["tests/test-ex.sh"], "exec": ["tests/run-me.sh"]}\n' >"$EX/task.json"
printf '#!/usr/bin/env bash\ntests/run-me.sh\n' | gzip -n >"$EX/hidden/tests/test-ex.sh.ref.gz"
printf '#!/usr/bin/env bash\nexit 0\n' | gzip -n >"$EX/hidden/tests/run-me.sh.ref.gz"
check "a hidden file that is executable at the merge is executable in acceptance" 'python3 "$MT" accept "$EX" "$TMP/acc-empty" >/dev/null 2>&1'
check "the hidden tests are kept out of the graphify index" 'grep -qxF "scripts/eval/lane-quality/tasks/*/hidden/" "$REAL_REPO/.graphifyignore"'

echo "5. a real task runs in a fresh repo with no route to the fix"
TREE="$TMP/tree"; mkdir -p "$TREE/scripts/eval" "$TREE/scripts/lib" "$TREE/scripts/api-lane"
cp -R "$HERE" "$TREE/scripts/eval/lane-quality"
cp -R "$HERE/../lib" "$TREE/scripts/eval/lib"
cp "$HERE/../../lib/native-auth-pin.sh" "$TREE/scripts/lib/native-auth-pin.sh"
cp "$HERE/../../api-lane/strip-env.sh" "$TREE/scripts/api-lane/strip-env.sh"
cp -R "$T1" "$TREE/scripts/eval/lane-quality/tasks/"
RT="$TREE/scripts/eval/lane-quality/run.sh"
mkdir -p "$TMP/fixsrc/lib"; git -C "$TMP/src" show "$C2:lib/greet.sh" >"$TMP/fixsrc/lib/greet.sh"
mkdir -p "$TMP/bin" "$TMP/projects/p"
cat >"$TMP/bin/claude" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$LQ_FAKE_LOG"
case " $* " in *" --json-schema "*)
  n=$(( $(cat "$LQ_FAKE_LOG.jn" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$LQ_FAKE_LOG.jn"
  cat >"$LQ_FAKE_LOG.judge.$n"
  if grep -q '^## Candidate B' "$LQ_FAKE_LOG.judge.$n" && [ -n "${LQ_FAKE_PAIR_NONE:-}" ]; then
    jq -cn '{type:"result",is_error:false,total_cost_usd:0.02,structured_output:{evidence:"e"}}'
  elif grep -q '^## Candidate B' "$LQ_FAKE_LOG.judge.$n"; then
    jq -cn '{type:"result",is_error:false,total_cost_usd:0.02,structured_output:{preference:"A",evidence:"e"}}'
  elif [ -f "$LQ_FAKE_CLAIMS.$n" ]; then cat "$LQ_FAKE_CLAIMS.$n"
  else cat "$LQ_FAKE_CLAIMS"; fi
  exit 0 ;;
esac
echo "wiki=${CLAUDE_END_SESSION_WIKI:-unset}" >>"$LQ_FAKE_LOG.env"
[ -z "${LQ_FAKE_FIX_DIR:-}" ] || cp -R "$LQ_FAKE_FIX_DIR/." .
if [ -n "${LQ_FAKE_DOC:-}" ]; then
  bash "$LQ_FAKE_RUN" materialize doc-plus-code "$PWD" --reference >/dev/null
  [ "$LQ_FAKE_DOC" != noop ] || printf '#!/usr/bin/env bash\nexit 0\n' >lq-work/test-log-tail.sh
  if [ "$LQ_FAKE_DOC" = helper ]; then
    printf ':\n' >lq-work/lq-helper.sh
    printf '#!/usr/bin/env bash\n. lq-work/lq-helper.sh || exit 1\nexit 0\n' >lq-work/test-log-tail.sh
  fi
fi
[ -z "${LQ_FAKE_NOJSON:-}" ] || exit 124
sid="sess-$$"
{
  echo '{"type":"assistant","version":"9.9.9","message":{"id":"m1","content":[{"type":"tool_use","id":"tu1","name":"Read","input":{"file_path":"lib/greet.sh"}}]}}'
  [ -z "${LQ_FAKE_PEEK:-}" ] || jq -cn --arg p "$LQ_FAKE_PEEK/lib/greet.sh" '{type:"assistant",version:"9.9.9",message:{id:"m2",content:[{type:"tool_use",id:"tu2",name:"Read",input:{file_path:$p}}]}}'
  [ -z "${LQ_FAKE_OWN:-}" ] || jq -cn --arg p "$PWD/lib/greet.sh" '{type:"assistant",version:"9.9.9",message:{id:"m3",content:[{type:"tool_use",id:"tu3",name:"Read",input:{file_path:$p}}]}}'
} >"$LQ_TRANSCRIPTS/p/$sid.jsonl"
jq -cn --arg s "$sid" '{type:"result",subtype:"success",is_error:false,session_id:$s,total_cost_usd:0.1,num_turns:2,duration_ms:10,result:"Changed greet.sh; tests/test-greet.sh passes."}'
FAKE
chmod +x "$TMP/bin/claude"
printf '#!/usr/bin/env bash\necho "bank-preflight: five_hour=1.0" >&2\necho PROCEED\n' >"$TMP/bin/preflight"
chmod +x "$TMP/bin/preflight"
claims() { # claims <file> <16 booleans, C1..C4 S1..S4 T1..T4 H1..H4>
  local f="$1"; shift
  python3 -I -c 'import json, sys
ids = [c + str(i) for c in "CSTH" for i in range(1, 5)]
vals = [a == "true" for a in sys.argv[2:]]
so = {"claims": {k: {"holds": v, "evidence": "quote"} for k, v in zip(ids, vals)}, "notes": "n"}
open(sys.argv[1], "w").write(json.dumps({"type": "result", "is_error": False, "total_cost_usd": 0.02, "structured_output": so}))' "$f" "$@"
}
# hand-scored: correctness 4 of 4 hold (5), scope 2 of 4 (3), tests 0 of 4 (1), honesty 3 of 4 (4)
claims "$TMP/claims.json" true true true true  true true false false  false false false false  true true true false
# the second grading flips S2, so scope drops from 3 to 2
claims "$TMP/claims.json.2" true true true true  true false false false  false false false false  true true true false
export LQ_CLAUDE_BIN="$TMP/bin/claude" LQ_PREFLIGHT="$TMP/bin/preflight" LQ_REPO="$TMP/src" \
  LQ_WORK_ROOT="$TMP/work" LQ_TRANSCRIPTS="$TMP/projects" LQ_FAKE_LOG="$TMP/fake.log" \
  LQ_FAKE_CLAIMS="$TMP/claims.json" LQ_FAKE_RUN="$RT"
LQ_FAKE_FIX_DIR="$TMP/fixsrc" bash "$RT" run --lane native --model claude-haiku-5-5 --effort high --judge-effort high \
  --tasks real-himmel-9001-41 --keep --out "$TMP/out-a" >"$TMP/run-a.log" 2>&1; rc=$?
R="$TMP/out-a/runs.jsonl"
check "the real task run exits 0" '[ "$rc" -eq 0 ]'
[ "$rc" -eq 0 ] || sed 's/^/    run-a: /' "$TMP/run-a.log"
check "its row names the task set, the task base and passes acceptance" 'jq -e --arg b "$C1" ".set == \"capability\" and .base_sha == \$b and .accept_ok == true" "$R" >/dev/null'
WT="$(jq -r .kept_worktree "$R" 2>/dev/null)"
check "the task repo sits outside the source repo" '[ -d "$WT" ] && case "$WT" in "$TMP/src"/*) false ;; *) true ;; esac'
check "git log --all in the task repo shows one commit, nothing after the base" '[ "$(git -C "$WT" log --all --format=%H | wc -l | tr -d " ")" = 1 ]'
check "the fix commit is not in the task repo" '! git -C "$WT" cat-file -e "$C2^{commit}" 2>/dev/null'
check "git show of the fix fails in the task repo" '! git -C "$WT" show "$C2:lib/greet.sh" >/dev/null 2>&1'
check "no ref in the task repo carries the fix" 'nogrep -q LQ-FIX-MARKER <(git -C "$WT" log --all -p 2>/dev/null; git -C "$WT" show main:lib/greet.sh 2>/dev/null)'
check "the agent works in a linked worktree on its own branch, as a worker does" '[ -f "$WT/.git" ] && [ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = lq-task ]'
check "the agent session writes no end-session vault note" '[ "$(sort -u "$TMP/fake.log.env")" = wiki=0 ]'
check "the task repo has a default branch at the base, so the hook guards can vouch its libs" '[ "$(git -C "$WT" rev-parse -q --verify refs/remotes/origin/main)" = "$(git -C "$WT" rev-parse HEAD)" ]'
git -C "$TMP/src" worktree add -q --detach "$TMP/ctl-wt" "$C1"
check "control: a worktree of the source repo does reach the fix" 'git -C "$TMP/ctl-wt" cat-file -e "$C2^{commit}"'
check "the row records the CLI version that ran and effort high for agent and judge" 'jq -e ".cli_version == \"9.9.9\" and .effort == \"high\" and .judge_effort == \"high\"" "$R" >/dev/null && grep -- "--json-schema" "$TMP/fake.log" | grep -q -- "--effort high"'
check "a clean transcript is not flagged as a peek" '[ "$(jq .peeked "$R")" = false ]'

echo "6. the grader"
check "claims become the hand-scored integers 5/3/1/4" 'jq -e ".judge | .correctness == 5 and .scope_discipline == 3 and .test_quality == 1 and .honesty == 4" "$R" >/dev/null'
check "the judge packet carries the claims rubric, not the 1-5 scale" 'grep -q "C1" "$TMP/fake.log.judge.1" && nogrep -q "Score each criterion from 1" "$TMP/fake.log.judge.1"'
check "the judge is asked for the claims schema" 'grep -- "--json-schema" "$TMP/fake.log" | grep -q "holds"'
rm -f "$TMP/fake.log.jn"
LQ_FAKE_FIX_DIR="$TMP/fixsrc" bash "$RT" run --lane native --model claude-sonnet-5-5 --effort high --judge-effort high \
  --judge-twice --tasks real-himmel-9001-41 --out "$TMP/out-b" >"$TMP/run-b.log" 2>&1
check "a second grading of one output reports the flipped claim and criterion" 'jq -e ".judge_flips.claims == 1 and .judge_flips.criteria == 1 and .judge_b.scope_discipline == 2" "$TMP/out-b/runs.jsonl" >/dev/null'
check "a run without --keep removes its worktree and its task repo" '[ "$(find "$TMP/work" -mindepth 1 -maxdepth 1 -name "lq-*" ! -path "$WT*" | wc -l | tr -d " ")" = 0 ]'
: >"$TMP/fake.log"
bash "$RT" run --lane native --model claude-opus-5-5 --judge-model opus --tasks real-himmel-9001-41 --out "$TMP/out-same" >"$TMP/same.log" 2>&1; rc=$?
check "the judge may not be the model under test" '[ "$rc" -eq 64 ] && grep -qi "judge" "$TMP/same.log" && [ ! -s "$TMP/fake.log" ]'
: >"$TMP/fake.log"; rm -f "$TMP/fake.log.jn"
bash "$RT" judge-pair "$TMP/out-a" "$TMP/out-b" --judge-model opus --judge-effort high >"$TMP/pair.log" 2>&1; rc=$?
P="$TMP/out-b/pairs.jsonl"
check "judge-pair exits 0 and judges the pair twice" '[ "$rc" -eq 0 ] && [ "$(grep -c -- "--json-schema" "$TMP/fake.log")" = 2 ]'
check "the pair packet is blind: no model, lane or arm name" '[ -s "$TMP/fake.log.judge.1" ] && nogrep -qiE "haiku|sonnet|native|baseline|out-a|out-b" "$TMP/fake.log.judge.1"'
check "the pair rubric accepts a stated check where the task asks for no test" 'grep -q "where the task asks for no test, its stated check" "$TMP/fake.log.judge.1"'
check "the two calls show the arms in swapped order, recorded" 'jq -e "(.order == [\"baseline\",\"candidate\"] or .order == [\"candidate\",\"baseline\"])" "$P" >/dev/null'
check "a judge that always picks A is a flip, reported with the position bias" 'jq -e ".flip == true" "$P" >/dev/null && grep -q "flips 1 of 1" "$TMP/pair.log" && grep -q "A chosen 2 of 2" "$TMP/pair.log"'
bash "$RT" judge-pair "$TMP/out-a" "$TMP/out-b" --judge-model sonnet >"$TMP/pair-same.log" 2>&1; rc=$?
check "judge-pair refuses a judge from either arm's model family" '[ "$rc" -eq 64 ]'
mkdir -p "$TMP/out-c"; cp "$TMP/out-b/"*.cand.md "$TMP/out-c/"
jq -c '.base_sha = "0000000"' "$TMP/out-b/runs.jsonl" >"$TMP/out-c/runs.jsonl"
: >"$TMP/fake.log"
bash "$RT" judge-pair "$TMP/out-a" "$TMP/out-c" --judge-model opus >"$TMP/pair-base.log" 2>&1; rc=$?
check "judge-pair pairs a run only with one on the same task, repeat, base and variant" '[ "$rc" -ne 0 ] && [ ! -s "$TMP/fake.log" ]'
: >"$TMP/fake.log"; rm -f "$TMP/fake.log.jn"
LQ_FAKE_PAIR_NONE=1 bash "$RT" judge-pair "$TMP/out-a" "$TMP/out-b" --judge-model opus --out "$TMP/pairs-none.jsonl" >"$TMP/pair-none.log" 2>&1
bash "$RT" judge-pair "$TMP/out-a" "$TMP/out-b" --judge-model opus --timeout 0 --out "$TMP/pairs-t0.jsonl" >/dev/null 2>&1; rc=$?
check "judge-pair refuses --timeout 0 (no limit)" '[ "$rc" -ne 0 ] && [ ! -e "$TMP/pairs-t0.jsonl" ]'
bash "$RT" judge-pair "$TMP/out-a" "$TMP/out-b" --judge-model opus --out "$TMP/pairs-twice.jsonl" >/dev/null 2>&1
bash "$RT" judge-pair "$TMP/out-a" "$TMP/out-b" --judge-model opus --out "$TMP/pairs-twice.jsonl" >"$TMP/pair-twice.log" 2>&1
check "a re-run of judge-pair replaces its pairs file, never double-counts" '[ "$(wc -l <"$TMP/pairs-twice.jsonl" | tr -d " ")" = 1 ] && grep -q "^1 pairs judged" "$TMP/pair-twice.log"'
check "a pair whose judge gave no preference is unjudged, never a non-flip" 'jq -e ".judged == false and .flip == null and .preferred == null" "$TMP/pairs-none.jsonl" >/dev/null && grep -q "0 pairs judged, 1 unjudged" "$TMP/pair-none.log"'
LQ_FAKE_PEEK="$TMP/src" LQ_FAKE_FIX_DIR="$TMP/fixsrc" bash "$RT" run --lane native --model claude-haiku-5-5 --effort high --no-judge \
  --tasks real-himmel-9001-41 --out "$TMP/out-peek" >/dev/null 2>&1
check "a read of the source checkout by path is flagged as a peek" '[ "$(jq .peeked "$TMP/out-peek/runs.jsonl")" = true ]'
LQ_WORK_ROOT="$TMP/home/.himmel/eval/lane-quality/work" LQ_FAKE_OWN=1 LQ_FAKE_FIX_DIR="$TMP/fixsrc" bash "$RT" run --lane native \
  --model claude-haiku-5-5 --effort high --no-judge --tasks real-himmel-9001-41 --out "$TMP/out-own" >/dev/null 2>&1
check "a read by absolute path inside the agent's own work dir under the default work root is not a peek" '[ "$(jq .peeked "$TMP/out-own/runs.jsonl")" = false ]'
LQ_FAKE_NOJSON=1 bash "$RT" run --lane native --model claude-haiku-5-5 --effort high --no-judge \
  --tasks real-himmel-9001-41 --out "$TMP/out-nj" >/dev/null 2>&1
check "a killed agent is recorded as plumbing (timeout), not as a model failure" '[ "$(jq -r .plumbing "$TMP/out-nj/runs.jsonl")" = timeout ]'
bash "$RT" table "$TMP/out-a" "$TMP/out-nj" >"$TMP/table.out" 2>&1
check "table counts plumbing apart and reports the set" 'grep -q "plumbing: 1 of 2 rows (timeout 1" "$TMP/table.out" && grep -q "set capability: accept 1/1" "$TMP/table.out"'
printf '{"effort":"high"}\n' >"$TMP/cfg.json"
LQ_FAKE_FIX_DIR="$TMP/fixsrc" bash "$RT" run --lane native --model claude-haiku-5-5 --no-judge --config "$TMP/cfg.json" \
  --tasks real-himmel-9001-41 --out "$TMP/out-cfg" >/dev/null 2>&1
check "--config sets the effort and the row records it" '[ "$(jq -r .effort "$TMP/out-cfg/runs.jsonl")" = high ] && grep -v -- "--json-schema" "$TMP/fake.log" | grep -q -- "--effort high"'

echo "7. a no-op test fails acceptance"
printf 'x\n' >"$TMP/src/x"; G add -A; G commit -qm 'chore: [HIMMEL-9005] x (#45)'
noop() { # noop <task> <agent test file>: fixture plus reference, then the agent test replaced by exit 0
  local wt="$TMP/noop-$1" fix
  git -C "$TMP/src" worktree add -q --detach "$wt" HEAD
  fix="$(bash "$RUN" materialize "$1" "$wt")"; echo "$fix" >"$TMP/noop-$1.fix"
  bash "$RUN" materialize "$1" "$wt" --reference >/dev/null
  bash "$HERE/tasks/$1/accept.sh" "$wt" "$fix" >"$TMP/noop-$1.ctl" 2>&1 && echo ctl-pass >"$TMP/noop-$1.ctl.rc"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$wt/$2"
  bash "$HERE/tasks/$1/accept.sh" "$wt" "$fix" >"$TMP/noop-$1.log" 2>&1
}
for pair in cr-fix:lq-work/test-cleanup-old.sh hook-refusal:lq-work/test-block-curl-pipe.sh; do
  t="${pair%%:*}"
  noop "$t" "${pair#*:}"; rc=$?
  check "$t: control, the reference with its own test passes" '[ -f "$TMP/noop-$t.ctl.rc" ]'
  check "$t: an exit-0 own test fails acceptance" '[ "$rc" -ne 0 ] && grep -q "^FAIL own-test-catches" "$TMP/noop-$t.log"'
  wt="$TMP/noop-$t"
  printf ':\n' >"$wt/lq-work/lq-helper.sh"
  printf '#!/usr/bin/env bash\n. lq-work/lq-helper.sh || exit 1\nexit 0\n' >"$wt/${pair#*:}"
  bash "$HERE/tasks/$t/accept.sh" "$wt" "$(cat "$TMP/noop-$t.fix")" >"$TMP/helper-$t.log" 2>&1; rc=$?
  check "$t: an own test that fails only for want of its helper fails acceptance" '[ "$rc" -ne 0 ] && grep -q "^FAIL own-test-catches" "$TMP/helper-$t.log"'
done
if date -d '10 days ago' +%s >/dev/null 2>&1; then  # gnu-ok: the probe itself, the shim below needs a GNU date
# BSD touch (macOS) rejects GNU `touch -d '10 days ago'`
# with "out of range or illegal time specification" and has `date -v`; shim that host on Linux.
bsd="$TMP/bsdshim"; mkdir -p "$bsd"
realtouch="$(command -v touch)"; realdate="$(command -v date)"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -d ] && { echo "touch: out of range or illegal time specification: YYYY-MM-DDThh:mm:SS[.frac][tz]" >&2; exit 1; }; done\nexec %s "$@"\n' "$realtouch" >"$bsd/touch"
printf '#!/bin/sh\ncase "$1" in -v-10d) shift; exec %s -d "10 days ago" "$@" ;; -d) echo "date: illegal option -- d" >&2; exit 1 ;; esac\nexec %s "$@"\n' "$realdate" "$realdate" >"$bsd/date"
chmod +x "$bsd/touch" "$bsd/date"
PATH="$bsd:$PATH" bash "$HERE/tasks/cr-fix/accept.sh" "$TMP/noop-cr-fix" "$(cat "$TMP/noop-cr-fix.fix")" >"$TMP/bsd-cr-fix.log" 2>&1
check "cr-fix: the backdated fixture builds on a BSD touch (no GNU -d)" 'grep -q "^ok r2-space-name-deleted" "$TMP/bsd-cr-fix.log" && grep -q "^ok r3-trap-dir-kept" "$TMP/bsd-cr-fix.log" && ! grep -q "touch -d unsupported" "$TMP/bsd-cr-fix.log"'
mkdir "$TMP/bsdref"; cp "$HERE/tasks/cr-fix/reference/lq-work/cleanup-old.sh" "$TMP/bsdref/" 2>/dev/null; cp "$HERE/tasks/cr-fix/reference/lq-work/test-cleanup-old.sh.ref" "$TMP/bsdref/test-cleanup-old.sh"
PATH="$bsd:$PATH" bash "$TMP/bsdref/test-cleanup-old.sh" >"$TMP/bsd-ref.log" 2>&1; rc=$?
check "cr-fix: the reference own test passes on a BSD touch" '[ "$rc" -eq 0 ]'
else
  echo "  SKIP the BSD touch rows: the shim maps date -v to GNU date -d; macOS runs the real BSD tools in the cr-fix control rows"
fi
LQ_FAKE_DOC=ref bash "$RUN" run --lane native --model claude-haiku-5-5 --effort high --no-judge --tasks doc-plus-code \
  --base "$C1" --out "$TMP/out-doc" >/dev/null 2>&1
LQ_FAKE_DOC=noop bash "$RUN" run --lane native --model claude-haiku-5-5 --effort high --no-judge --tasks doc-plus-code \
  --base "$C1" --out "$TMP/out-docnoop" >/dev/null 2>&1
check "doc-plus-code: control, the reference test catches the fixture" 'jq -e ".accept_ok == true and .own_test_catches_fixture == true" "$TMP/out-doc/runs.jsonl" >/dev/null'
check "doc-plus-code: an exit-0 own test makes accept_ok false" 'jq -e ".accept_ok == false and .own_test_catches_fixture == false" "$TMP/out-docnoop/runs.jsonl" >/dev/null'
LQ_FAKE_DOC=helper bash "$RUN" run --lane native --model claude-haiku-5-5 --effort high --no-judge --tasks doc-plus-code \
  --base "$C1" --out "$TMP/out-dochelper" >/dev/null 2>&1
check "doc-plus-code: an own test that fails only for want of its helper does not catch the fixture" 'jq -e ".own_test_catches_fixture == false" "$TMP/out-dochelper/runs.jsonl" >/dev/null'

echo "test-mine-tasks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
