#!/usr/bin/env bash
# scripts/ci/test-macos-cadence-matrix.sh -- a `suites` dispatch of
# .github/workflows/macos-cadence.yml fans out as one job per suite (a plan job
# splits the input, a `suite` matrix runs one --only-list call per job, each job
# uploads its own failed-log artifact), the summary stays red when any of them
# is red, and an empty input keeps the eight-shard `shell` path. Parses the
# workflow with PyYAML (python3 -I) and RUNS the plan job's script. No network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="${WF:-$ROOT/.github/workflows/macos-cadence.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

tmpd="$(mktemp -d -t macos-matrix.XXXXXX)" || exit 1
trap 'rm -rf "$tmpd"' EXIT

# check_wf <workflow file>: prints one line per failed assertion, rc 1 if any.
check_wf() {
  python3 -I - "$1" <<'PY'
import sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
jobs = doc.get("jobs") or {}
bad = []

def steps(j):
    return (jobs.get(j) or {}).get("steps") or []

plan, suite, shell, summary = (jobs.get(k) or {} for k in ("plan", "suite", "shell", "summary"))
if not plan:
    bad.append("no plan job splits the suites input")
elif str(plan.get("if", "")).strip() != "inputs.suites != ''":
    bad.append("plan runs on an empty suites input (if: %r)" % plan.get("if"))
if plan and "suites" not in (plan.get("outputs") or {}):
    bad.append("plan exposes no `suites` output for the matrix")

if not suite:
    bad.append("no `suite` matrix job: a suites dispatch is not one job per suite")
else:
    if "plan" not in ([suite["needs"]] if isinstance(suite.get("needs"), str) else suite.get("needs") or []):
        bad.append("suite job does not need plan")
    strat = suite.get("strategy") or {}
    if "fromJSON(needs.plan.outputs.suites)" not in str((strat.get("matrix") or {}).get("suite", "")).replace(" ", ""):
        bad.append("suite matrix is not fromJSON(needs.plan.outputs.suites)")
    if strat.get("fail-fast") is not False:
        bad.append("suite matrix does not set fail-fast: false (one red suite would cancel the others)")
    name = str(suite.get("name", ""))
    if "matrix.suite.path" not in name:
        bad.append("suite job name does not carry the suite path: %r" % name)
    if "macos-latest" not in name + str((strat.get("matrix") or {}).get("os", "")) or "matrix.os" not in name:
        bad.append("suite job name lacks the macos-latest runner label check-macos-nightly-health.sh matches: %r" % name)
    if not name.startswith("macos-cadence / "):
        bad.append("suite job name lacks the 'macos-cadence / ' prefix: %r" % name)
    if "continue-on-error" in suite:
        bad.append("suite job tolerates failure (continue-on-error)")
    runs = [s for s in steps("suite") if "--only-list" in str(s.get("run", ""))]
    if len(runs) != 1:
        bad.append("suite job has %d --only-list steps (want exactly 1)" % len(runs))
    else:
        r = runs[0]
        if "SUITES" in str(r.get("run", "")) or "inputs.suites" in str(r.get("run", "")):
            bad.append("suite run step reads the whole input, not its one suite")
        if "matrix.suite.path" not in str((r.get("env") or {}).get("SUITE", "")):
            bad.append("suite run step takes its suite from env SUITE = matrix.suite.path")
        if "--shard" in str(r.get("run", "")):
            bad.append("suite run step runs a shard")
    ups = [s for s in steps("suite") if str(s.get("uses", "")).startswith("actions/upload-artifact@") and "failed-suite-logs" in str((s.get("with") or {}).get("path", ""))]
    if len(ups) != 1:
        bad.append("suite job has %d failed-log uploads (want exactly 1)" % len(ups))
    else:
        u = ups[0]
        if "matrix.suite.slug" not in str((u.get("with") or {}).get("name", "")):
            bad.append("failed-log artifact is not named after the suite (name: %r)" % (u.get("with") or {}).get("name"))
        if "failure()" not in str(u.get("if", "")):
            bad.append("failed-log upload does not run on failure")

if not shell:
    bad.append("the eight-shard shell job is gone")
elif "inputs.suites == ''" not in str(shell.get("if", "")):
    bad.append("shell job still runs on a suites dispatch (if: %r)" % shell.get("if"))

if not summary:
    bad.append("no summary job")
else:
    needs = [summary["needs"]] if isinstance(summary.get("needs"), str) else summary.get("needs") or []
    if "suite" not in needs or "shell" not in needs:
        bad.append("summary does not wait on both shell and suite (needs: %r)" % needs)
    if not str(summary.get("if", "")).startswith("always() && "):
        bad.append("summary lost always(): a red suite would skip its verdict")
    if not any("check-macos-nightly-health.sh" in str(s.get("run", "")) for s in steps("summary")):
        bad.append("summary no longer runs the macOS health check that fails on any red job")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
}

# 1. the real workflow.
if out="$(check_wf "$WF")"; then ok "a suites dispatch is plan -> one named job and one failed-log artifact per suite; summary waits on all; full path kept"
else bad "macos-cadence.yml: $out"; fi

# 2. RED control: the workflow as it stood on main (554788c), jobs head copied
# verbatim -- one `shell` job whose matrix shrinks to [1] and runs the whole list.
old="$tmpd/old.yml"
cat > "$old" <<'YML'
jobs:
  shell:
    name: macos-cadence / shell (${{ matrix.os }}, ${{ matrix.shard }})
    if: github.event_name != 'pull_request' || (contains(github.event.pull_request.labels.*.name, 'ci:macos') && (github.event.action != 'labeled' || github.event.label.name == 'ci:macos'))
    strategy:
      fail-fast: false
      matrix:
        os: [macos-latest]
        shard: ${{ fromJSON(inputs.suites == '' && '[1, 2, 3, 4, 5, 6, 7, 8]' || '[1]') }}
    runs-on: ${{ matrix.os }}
    steps:
      - id: tests
        run: |
          if [ -n "$SUITES" ]; then
            bash scripts/ci/run-shell-tests.sh --only-list macos-suites.txt .
          fi
        env:
          SUITES: ${{ inputs.suites }}
  summary:
    name: macos-cadence / summary
    needs: shell
    if: always() && (github.event_name != 'pull_request')
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/ci/check-macos-nightly-health.sh
YML
if out="$(check_wf "$old")"; then bad "main's single-job shape passes the check (the check is vacuous)"
else
  case "$out" in
    *"no \`suite\` matrix job"*) ok "main's one-job-runs-all shape is rejected: no per-suite matrix" ;;
    *) bad "main's shape rejected for the wrong reason: $out" ;;
  esac
fi

# 3. the plan job's script, run for real: it splits, dedups, slugs and rejects.
python3 -I - "$WF" "$tmpd/plan.sh" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
step = next((s for s in (doc["jobs"].get("plan") or {}).get("steps", []) if s.get("run")), None)
open(sys.argv[2], "w").write(step["run"] if step else "exit 99\n")
PY
run_plan() { ( cd "$tmpd" && : > out && SUITES="$1" GITHUB_OUTPUT="$tmpd/out" bash "$tmpd/plan.sh" ); }
if run_plan "scripts/ci/test-a.sh   scripts/hooks/test-b.sh scripts/ci/test-a.sh" >/dev/null 2>&1 \
   && json="$(sed -n 's/^suites=//p' "$tmpd/out")" \
   && [ "$(jq -r 'length' <<< "$json")" = 2 ] \
   && [ "$(jq -r '.[0].path' <<< "$json")" = "scripts/ci/test-a.sh" ] \
   && [ "$(jq -r '.[1].slug' <<< "$json")" = "scripts__hooks__test-b.sh" ]; then
  ok "plan turns 'a b a' into two matrix entries (deduped, order kept) with an artifact-safe slug"
else bad "plan did not split 'a b a' into 2 entries with slugs (output: $(cat "$tmpd/out" 2>/dev/null))"; fi
for badin in "../etc/passwd" 'a.sh;rm' "scripts/x\$(id).sh"; do
  run_plan "$badin" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 2 ]; then ok "plan rejects the unsafe suites input '$badin' (exit 2)"
  else bad "plan exited $rc, not 2, for the unsafe suites input '$badin'"; fi
done

[ "$fails" -eq 0 ] || { echo "$fails failed" >&2; exit 1; }
echo "all passed"
