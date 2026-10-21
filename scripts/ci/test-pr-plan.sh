#!/usr/bin/env bash
# selector: tree-scan
# scripts/ci/test-pr-plan.sh — scripts/ci/pr-plan.sh: the
# BASE-sourced per-job plan a pull_request prints so jobs whose inputs the diff
# does not touch skip. Each case runs a COPY of the planner inside a throwaway
# git repo whose refs/remotes/origin/main plays the default branch; the input
# list is the REAL scripts/ci/pr-job-gates.txt.
#
#   P1  a trust-path PR                     -> every gate true (mode full)
#   P2  a docs-only PR                      -> every gate false (mode impacted)
#   P3  a single scripts/jira file          -> node_suites + jira_cli_smoke only
#   P4  a path no group names               -> every gate true (unknown-path)
#   P5  a base without pr-job-gates.txt    -> every gate true (fail closed)
#   P6  an unresolvable head                -> every gate true
#   P7  no base (push / schedule)           -> every gate true
#   P8  a .sh edit                          -> bwk_gate true, node_suites false
#   P9  every gate named in ci.yml's plan consumers exists in the plan output
#   P10 an invalid regex in the list         -> every gate true (fail closed)
#   A1-A11 gate audit: every file a gated job's suites execute (one hop) is in
#          that job's gate group or a trust path, so a skip cannot hide a run
#   S1-S5  shard-has-work.sh: empty / [RUN ] / --list failure / no footer fail
#          closed to true, and a >64 KiB listing is not misread under pipefail
#
# Platform guard: bash-only, no .ps1 twin; git + tar, Linux CI is the caller.
#
# Usage: bash scripts/ci/test-pr-plan.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$RST_FIXTURE_DIR/../lib/fixture-tempdir.sh"

SRC_ROOT="$(cd "$RST_FIXTURE_DIR/../.." && pwd)"
PLAN_SRC="$SRC_ROOT/scripts/ci/pr-plan.sh"
INPUTS_SRC="$SRC_ROOT/scripts/ci/pr-job-gates.txt"
for f in "$PLAN_SRC" "$INPUTS_SRC"; do
  if [ ! -f "$f" ]; then
    fail "missing $f"
    rst_tally
  fi
done

SB="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$SB" "$SUITE_LOCK_SANDBOX"' EXIT
(
  fixture_enter_git_init_dir "$SB" || exit 1
  git init -q
  git config user.email t@e
  git config user.name t
) || exit 1
g() { git -C "$SB" "$@"; }

mkdir -p "$SB/scripts/ci" "$SB/scripts/cr" "$SB/scripts/jira" "$SB/scripts/tools" "$SB/scripts/guardrails" "$SB/docs" "$SB/odd"
printf '# baseline\n' > "$SB/scripts/guardrails/git-env-baseline.txt"
printf '# jira\n' > "$SB/scripts/jira/client.ts"
printf '# tool\n' > "$SB/scripts/tools/foo.sh"
printf '# doc\n' > "$SB/docs/note.md"
printf 'x\n' > "$SB/odd/thing.dat"
g add -A; g commit -q -m "chore: pre-planner"
PRE=$(g rev-parse HEAD)

cp "$SRC_ROOT/scripts/ci/impacted-selection.sh" "$SB/scripts/ci/impacted-selection.sh"
cp "$SRC_ROOT/scripts/cr/impacted-suites.sh" "$SB/scripts/cr/impacted-suites.sh"
cp "$SRC_ROOT/scripts/cr/anchor-handoff.sh" "$SB/scripts/cr/anchor-handoff.sh"
cp "$PLAN_SRC" "$SB/scripts/ci/pr-plan.sh"
cp "$INPUTS_SRC" "$SB/scripts/ci/pr-job-gates.txt"
printf '# fixture trust list\n\n^scripts/ci/\n' > "$SB/scripts/ci/ci-trust-paths.txt"
g add -A; g commit -q -m "chore: planner"
BASE=$(g rev-parse HEAD)
g update-ref refs/remotes/origin/main "$BASE"

branch() {
  g checkout -q -B "$1" "$BASE"
  printf '%s\n' "$3" >> "$SB/$2"
  g commit -q -am "change $2"
  g rev-parse HEAD
}
H_TRUST=$(branch trust scripts/ci/ci-trust-paths.txt '# edit')
H_DOCS=$(branch docs docs/note.md '# edit')
H_JIRA=$(branch jira scripts/jira/client.ts '// edit')
H_ODD=$(branch odd odd/thing.dat 'y')
H_SH=$(branch sh scripts/tools/foo.sh '# edit')
H_BASE=$(branch baseline scripts/guardrails/git-env-baseline.txt '# edit')

plan() { (cd "$SB" && bash "$SB/scripts/ci/pr-plan.sh" "$@" 2>/dev/null); }
val() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }
all_is() { # all_is <output> <true|false> — every run_ line has that value
  printf '%s\n' "$1" | grep '^run_' | grep -qv "=$2\$" && return 1  # pipefail-ok: a few lines of output
  printf '%s\n' "$1" | grep -q '^run_'  # pipefail-ok: a few lines of output
}

# P1
out=$(plan "$BASE" "$H_TRUST")
if all_is "$out" true && [ "$(val "$out" mode)" = full ]; then pass "P1 trust path: all gates true, mode full"
else fail "P1 trust path: $out"; fi

# P2
out=$(plan "$BASE" "$H_DOCS")
if all_is "$out" false && [ "$(val "$out" mode)" = impacted ]; then pass "P2 docs-only: all gates false"
else fail "P2 docs-only: $out"; fi

# P3
out=$(plan "$BASE" "$H_JIRA")
if [ "$(val "$out" run_node_suites)" = true ] && [ "$(val "$out" run_jira_cli_smoke)" = true ] \
   && [ "$(val "$out" run_bwk_gate)" = false ] && [ "$(val "$out" run_guardrail_matrices)" = false ]; then
  pass "P3 scripts/jira file: node_suites + jira_cli_smoke only"
else fail "P3 scripts/jira file: $out"; fi

# P4
out=$(plan "$BASE" "$H_ODD")
if all_is "$out" true; then pass "P4 unnamed path: all gates true"
else fail "P4 unnamed path: $out"; fi

# P4b: the git-env baseline is the data input of
# check-git-env-scrub.sh; a baseline-only diff must run the job, not skip it.
# The baseline exists at BASE (a missing file made this plan all-true
# whatever the gates said), so the branch edits a tracked file and only the
# gate line can turn git_env_scrub on while docs-only stays all-false.
out=$(plan "$BASE" "$H_BASE")
if [ "$(val "$out" run_git_env_scrub)" = true ] && [ "$(val "$out" mode)" = impacted ] \
   && [ "$(val "$out" run_deps_audit)" = false ]; then pass "P4b baseline-only diff runs git_env_scrub and nothing else is all-true"
else fail "P4b baseline-only diff: $out"; fi

# P5: a base whose tree has no pr-job-gates.txt
g checkout -q -B noinputs "$PRE"
mkdir -p "$SB/scripts/ci" "$SB/scripts/cr"
cp "$SRC_ROOT/scripts/ci/impacted-selection.sh" "$SB/scripts/ci/impacted-selection.sh"
cp "$SRC_ROOT/scripts/cr/impacted-suites.sh" "$SB/scripts/cr/impacted-suites.sh"
cp "$SRC_ROOT/scripts/cr/anchor-handoff.sh" "$SB/scripts/cr/anchor-handoff.sh"
cp "$PLAN_SRC" "$SB/scripts/ci/pr-plan.sh"
printf '# fixture trust list\n\n^scripts/ci/\n' > "$SB/scripts/ci/ci-trust-paths.txt"
g add -A; g commit -q -m "planner without inputs"
NOIN=$(g rev-parse HEAD)
g update-ref refs/remotes/origin/main "$NOIN"
printf '# edit\n' >> "$SB/docs/note.md"
cp "$INPUTS_SRC" "$SB/scripts/ci/pr-job-gates.txt"
g add -A; g commit -q -m "docs plus the first copy of the inputs list"
H_NOIN=$(g rev-parse HEAD)
out=$(plan "$NOIN" "$H_NOIN")
if all_is "$out" true; then pass "P5 base without inputs file: all gates true"
else fail "P5 base without inputs file: $out"; fi
g update-ref refs/remotes/origin/main "$BASE"

# P6
out=$(plan "$BASE" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef)
if all_is "$out" true; then pass "P6 unresolvable head: all gates true"
else fail "P6 unresolvable head: $out"; fi

# P7
out=$(plan "" "$H_DOCS")
if all_is "$out" true; then pass "P7 no base: all gates true"
else fail "P7 no base: $out"; fi

# P8
out=$(plan "$BASE" "$H_SH")
if [ "$(val "$out" run_bwk_gate)" = true ] && [ "$(val "$out" run_node_suites)" = false ]; then
  pass "P8 .sh edit: bwk_gate true, node_suites false"
else fail "P8 .sh edit: $out"; fi

# P10: an invalid regex in the base's list is a broken gate list, not a miss
g checkout -q -B badre "$BASE"
printf 'node_suites\t[\n' >> "$SB/scripts/ci/pr-job-gates.txt"
g commit -q -am "gates list with an invalid regex"
BADRE=$(g rev-parse HEAD)
g update-ref refs/remotes/origin/main "$BADRE"
printf '# edit\n' >> "$SB/docs/note.md"
g commit -q -am "docs edit on a broken list"
H_BADRE=$(g rev-parse HEAD)
out=$(plan "$BADRE" "$H_BADRE")
if all_is "$out" true && [ "$(val "$out" mode)" = full ]; then pass "P10 invalid regex in the list: all gates true"
else fail "P10 invalid regex in the list: $out"; fi
g update-ref refs/remotes/origin/main "$BASE"

# P9: every needs.plan.outputs.run_X the workflow reads is a gate the planner prints
CI_YML="$SRC_ROOT/.github/workflows/ci.yml"
want=$(grep -oE 'needs\.plan\.outputs\.run_[a-z_]+' "$CI_YML" | sed 's/.*outputs\.//' | sort -u)
have=$(grep -oE '^[a-z_]+' "$SRC_ROOT/scripts/ci/pr-job-gates.txt" | grep -v '^benign$' | sed 's/^/run_/' | sort -u)
missing=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))
if [ -n "$want" ] && [ -z "$missing" ]; then pass "P9 ci.yml reads only gates the input list defines"
else fail "P9 ci.yml reads undefined gates: ${missing:-<none read>}"; fi

# A1-A11: gate-completeness audit. A gated job that skips because the diff
# touched none of its listed paths is only safe if every file its entry suites
# EXECUTE (the file plus the files it names, one hop, comments stripped) falls in
# its own gate group or is a trust path (trust paths force every gate true).
# Regression: claude-startup ran headed-arm-leg.sh and
# plugin-profiles.mjs, which the group did not name, so it skipped and passed.
TRACKED="$SB/tracked.txt"
git -C "$SRC_ROOT" ls-files > "$TRACKED"
cat > "$SB/refs.awk" <<'AWK'
BEGIN { while ((getline p < tracked) > 0) T[p] = 1 }
{
  e = $0; out[e] = 1
  if (e !~ /\.(sh|bash|mjs|cjs|js|ts|py|awk)$/) next
  d = e; if (!sub(/\/[^\/]*$/, "", d)) d = ""
  f = root "/" e
  while ((getline line < f) > 0) {
    t = line; sub(/^[ \t]+/, "", t)
    if (t ~ /^(#|\/\/|\*)/) continue
    while (match(line, /[A-Za-z0-9_.@+\/-]+\.(sh|bash|mjs|cjs|json|js|ts|txt|yaml|yml|py|awk)/)) {
      tok = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
      n = split(tok, parts, "/")
      for (i = 1; i <= n; i++) {
        s = parts[i]
        for (j = i + 1; j <= n; j++) s = s "/" parts[j]
        sub(/^(\.\/)+/, "", s)
        if (s in T) out[s] = 1
        c = (d == "" ? s : d "/" s)
        while (c ~ /[^\/]+\/\.\.\//) sub(/[^\/]+\/\.\.\//, "", c)
        if (c in T) out[c] = 1
      }
    }
  }
  close(f)
}
END { for (k in out) print k }
AWK
TRUST_ALT=$(grep -vE '^[[:space:]]*(#|$)' "$SRC_ROOT/scripts/ci/ci-trust-paths.txt" | sed -E 's/.*/(&)/' | paste -sd'|' -)
audit_closure() { # audit_closure <entries-file> — entries plus the files they name
  awk -v tracked="$TRACKED" -v root="$SRC_ROOT" -f "$SB/refs.awk" "$1" | sort -u
}
audit_gap() { # audit_gap <group> <entries-file> — executed files outside the group
  local alt
  alt=$(grep -E "^$1[[:space:]]" "$INPUTS_SRC" | sed -E 's/^[^[:space:]]+[[:space:]]+//; s/.*/(&)/' | paste -sd'|' -)
  if [ -z "$alt" ]; then echo "<group $1 has no gate lines>"; return; fi
  audit_closure "$2" | grep -E '\.(sh|bash|mjs|cjs|json|js|ts|txt|yaml|yml|py|awk)$' \
    | { grep -vE "$alt" || true; } | { grep -vE "$TRUST_ALT" || true; } | { grep -v '^\.github/' || true; }
}
audit_case() { # audit_case <label> <group> <entries-file>
  local gap
  gap=$(audit_gap "$2" "$3" | head -8 | paste -sd' ' -)
  if [ -z "$gap" ]; then pass "$1 gate $2 covers every file its suites execute"
  else fail "$1 gate $2 misses executed files: $gap"; fi
}
tests_under() { # tests_under <ERE of dirs> — tracked test files under those dirs
  grep -E "^($1)/" "$TRACKED" | grep -E '(\.test\.|\.spec\.|/tests?/|/test-[^/]*$)' | grep -E '\.(ts|js|mjs|sh)$' || true  # pipefail-ok: filtered listing
}
EF="$SB/entries.txt"
printf '%s\n' scripts/testing/test-fakekey-claude-startup.sh scripts/testing/test-claude-mock-turn.sh \
  scripts/testing/test-mock-consult-sandbox.sh scripts/testing/test-mock-hook-smoke.sh \
  scripts/testing/test-mock-hook-live-turn.sh > "$EF"
# A1 (claude_startup) is gone: the job is ungated.
printf '%s\n' scripts/hooks/check-guardrail-matrices.sh > "$EF"
audit_case A2 guardrail_matrices "$EF"
printf '%s\n' scripts/guardrails/check-git-env-scrub.sh > "$EF"
audit_case A3 git_env_scrub "$EF"
printf '%s\n' scripts/ci/run-unchecked-mktemp-under-bwk.sh > "$EF"
audit_case A4 bwk_gate "$EF"
printf '%s\n' scripts/hooks/check-lockfile-integrity.sh scripts/hooks/check-uv-lock.sh scripts/hooks/check-npm-audit.sh \
  scripts/hooks/check-npm-licenses.sh scripts/hooks/check-npm-audit-signatures.sh > "$EF"
audit_case A5 deps_audit "$EF"
printf '%s\n' scripts/check-plugin-drift.sh scripts/lib/vm-mode.sh > "$EF"
audit_case A6 plugin_version_bump "$EF"
# A7 (lint) is gone: the job is ungated.
# A8 (lanes_and_trust) is gone: the job is ungated. The A8 test below
# pins that no gate group or ci.yml output brings it back.
tests_under 'scripts/jira|scripts/bitbucket|scripts/himmel-run|scripts/ci-orchestrator|plugins/himmel-gh|plugins/himmel-jira|marketplace/plugins/himmel-bus' > "$EF"
audit_case A9 node_suites "$EF"
# A10 (bun_suites) is gone: the job is ungated.
# A11 control: the audit sees the one-hop reference the judge found (a vacuous
# closure would pass every A case above).
printf '%s\n' scripts/testing/test-fakekey-claude-startup.sh > "$EF"
if audit_closure "$EF" | grep -qx 'scripts/lanes/plugin-profiles.mjs'; then
  pass "A11 audit closure reaches scripts/lanes/plugin-profiles.mjs from test-fakekey-claude-startup.sh"
else fail "A11 audit closure missed a known reference (vacuous audit)"; fi
# A8: structural pin. Jobs whose suites glob or run files no
# gate group can enumerate stay ungated: parse each job's block in ci.yml for a
# plan dependency or an if: on the plan outputs, and require no gate group of
# their old name and no run_<group> plan output.
job_block() { # job_block <job> — the lines of one top-level job in ci.yml
  awk -v j="  $1:" '$0 == j { on = 1; next } on && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit } on { print }' "$CI_YML"
}
plan_gated() { grep -qE 'needs:[[:space:]]*(\[[^]]*)?plan|needs\.plan'; }
if printf '    needs: plan\n' | plan_gated && printf "    if: \${{ needs.plan.outputs.run_x == 'false' }}\n" | plan_gated; then
  pass "A8 control: the matcher detects a plan dependency"
else fail "A8 control: the matcher missed a plan dependency (vacuous pin)"; fi
for pair in lanes-and-trust-suites:lanes_and_trust lint:lint claude-startup:claude_startup bun-suites:bun_suites; do
  job=${pair%%:*}; grp=${pair##*:}
  blk=$(job_block "$job")
  if [ -z "$blk" ]; then fail "A8 job $job not found in ci.yml (vacuous pin)"
  elif printf '%s\n' "$blk" | plan_gated; then fail "A8 job $job depends on plan or gates on its outputs again"
  elif grep -qE "^${grp}[[:space:]]" "$INPUTS_SRC" || grep -q "run_${grp}" "$CI_YML"; then fail "A8 gate group $grp is back (gate line or ci.yml output)"
  else pass "A8 job $job is ungated"; fi
done

# S1-S5: scripts/ci/shard-has-work.sh against a stub run-shell-tests.sh whose
# --list output STUB_MODE picks (the real selector is covered by its own suite).
SHW="$SB/shw"
mkdir -p "$SHW"
cp "$SRC_ROOT/scripts/ci/shard-has-work.sh" "$SHW/shard-has-work.sh"
cat > "$SHW/run-shell-tests.sh" <<'STUB'
#!/usr/bin/env bash
case "$STUB_MODE" in
  fail) exit 1 ;;
  args) printf '%s\n' "$*" > "$ARGS_OUT"; echo "== Summary =="; exit 0 ;;
  nofooter) echo "[RUN ] a/test-x.sh"; exit 0 ;;
  empty) echo "[SKIP] a/test-x.sh"; echo "== Summary =="; exit 0 ;;
  run) echo "[SKIP] a/test-x.sh"; echo "[RUN ] a/test-y.sh"; echo "== Summary =="; exit 0 ;;
  big) echo "[RUN ] a/test-y.sh"; i=0; while [ "$i" -lt 4000 ]; do echo "[SKIP] a/some/long/path/test-$i.sh # padding padding padding"; i=$((i+1)); done; echo "== Summary =="; exit 0 ;;
esac
STUB
shw() { STUB_MODE="$1" bash "$SHW/shard-has-work.sh" 1/8 . 2>/dev/null; }
s_case() { # s_case <label> <mode> <expected>
  got=$(shw "$2")
  if [ "$got" = "$3" ]; then pass "$1: $3"; else fail "$1 got: $got"; fi
}
s_case "S1 clean empty listing" empty has_work=false
s_case "S2 a [RUN ] line" run has_work=true
s_case "S3 --list failure (fail closed)" fail has_work=true
s_case "S4 no summary footer (fail closed)" nofooter has_work=true
s_case "S5 listing over 64 KiB with an early [RUN ]" big has_work=true
# S6: runner args after the root reach the --list that decides the shard.
ARGS_OUT="$SHW/args.out" STUB_MODE=args bash "$SHW/shard-has-work.sh" 1/8 /some/root -- --impacted a..b >/dev/null 2>&1
if [ "$(cat "$SHW/args.out" 2>/dev/null)" = "--list --shard 1/8 --impacted a..b /some/root" ]; then pass "S6 runner args reach the --list"; else fail "S6 got: $(cat "$SHW/args.out" 2>/dev/null)"; fi
ARGS_OUT="$SHW/args.out" STUB_MODE=args bash "$SHW/shard-has-work.sh" 1/8 >/dev/null 2>&1
if [ "$(cat "$SHW/args.out" 2>/dev/null)" = "--list --shard 1/8 ." ]; then pass "S6 no runner args, the plain --list"; else fail "S6 plain got: $(cat "$SHW/args.out" 2>/dev/null)"; fi

rst_tally
