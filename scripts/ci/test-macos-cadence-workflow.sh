#!/usr/bin/env bash
# scripts/ci/test-macos-cadence-workflow.sh -- pins the shape of
# .github/workflows/macos-cadence.yml, the lower-frequency os:macos workflow.
# Text assertions over the workflow with comments stripped (a comment cannot
# satisfy a policy check). No network, no PyYAML.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="${WF:-$ROOT/.github/workflows/macos-cadence.yml}"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

[ -f "$WF" ] || { bad "macos-cadence.yml does not exist at $WF"; echo "$fails failed" >&2; exit 1; }
strip() { sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]][[:space:]]*#.*$//' "$1"; }
s="$(strip "$WF")"

# 1. identifiable as os:macos.
if grep -q '^name: "CI (os:macos cadence)"$' <<< "$s"; then ok "workflow name carries os:macos"
else bad "workflow name is not exactly \"CI (os:macos cadence)\""; fi

# 2. triggers: schedule + workflow_dispatch + a labelled-PR run, never a bare
# per-PR / per-push run. pull_request fires only for label / push events, and
# the job-level guards in 2b keep an unlabelled PR from running anything.
on_block="$(awk '/^on:/ {f=1; next} f && /^[a-z]/ {f=0} f' <<< "$s")"
keys="$(sed -n 's/^  \([a-z_]*\):.*/\1/p' <<< "$on_block" | tr '\n' ' ')"
if [ "$keys" = "workflow_dispatch pull_request schedule " ]; then ok "triggers are workflow_dispatch + pull_request + schedule (no push)"
else bad "triggers are '$keys' (want workflow_dispatch + pull_request + schedule; never push)"; fi
types="$(sed -n 's/^    types: \[\(.*\)\]$/\1/p' <<< "$on_block" | tr -d ' ')"
if [ "$types" = "labeled,synchronize" ]; then ok "pull_request fires only on labeled + synchronize"
else bad "pull_request types are '$types' (want exactly labeled, synchronize)"; fi

# 2b. an unlabelled PR runs no macOS job: both jobs carry the label guard, and
# `summary` (always()) must not outlive a skipped `shell`.
job_of() { awk -v n="$1" '$0 == "  " n ":" {f=1; next} f && /^  [a-z]/ {f=0} f' <<< "$s"; }
for j in shell summary; do
  jif="$(job_of "$j" | sed -n 's/^    if: //p' | head -1)"
  if grep -q "contains(github.event.pull_request.labels.\*.name, 'ci:macos')" <<< "$jif" \
     && grep -q "github.event_name != 'pull_request'" <<< "$jif"; then ok "job $j runs on a PR only when it carries ci:macos"
  else bad "job $j has no ci:macos label guard (if: '$jif')"; fi
done
sum_if="$(job_of summary | sed -n 's/^    if: //p' | head -1)"
if grep -q '^always() && ' <<< "$sum_if"; then ok "summary keeps always() so a red shard still gets its verdict"
else bad "summary's if no longer starts with always(): '$sum_if'"; fi
# 2c. the header must not promise the old per-PR ban.
if grep -q 'never on an unlabelled PR' "$WF" && ! grep -q 'NOT on pull_request/push, ever' "$WF"; then ok "header says the macOS workers never run on an unlabelled PR"
else bad "header still carries the old 'NOT on pull_request/push, ever' wording"; fi

# 3. lower frequency than nightly: the cron's day-of-week field is restricted.
cron="$(sed -n "s/^[[:space:]]*- cron: '\([^']*\)'.*/\1/p" <<< "$s")"
dow="$(awk '{print $5}' <<< "$cron")"
if [ -n "$cron" ] && [ "$(wc -l <<< "$cron" | tr -d ' ')" = 1 ] && [ "$dow" != "*" ] && [ -n "$dow" ]; then
  ok "one cron ('$cron'), day-of-week restricted -> less often than nightly"
else bad "cron is not a single weekday-restricted schedule: '$cron'"; fi

# 4. least privilege + no advisory masking.
top_perm="$(awk '/^permissions:/ {f=1; next} f && /^[a-z]/ {f=0} f' <<< "$s" | sed '/^[[:space:]]*$/d')"
if [ "$top_perm" = "  contents: read" ]; then ok "top-level permissions are exactly contents: read"
else bad "top-level permissions are not exactly contents: read: $top_perm"; fi
extra="$(grep -E '^[[:space:]]+[a-z-]+: (read|write)$' <<< "$s" | sed 's/^[[:space:]]*//' | sort -u | tr '\n' ' ')"
if [ "$extra" = "actions: read contents: read " ]; then ok "the only permissions anywhere are contents: read and actions: read"
else bad "permission set is '$extra' (want exactly actions: read + contents: read)"; fi
if grep -q 'continue-on-error' <<< "$s"; then bad "a job tolerates failure (continue-on-error): a macOS red must redden THIS run"
else ok "no continue-on-error: a macOS red is a red of this workflow"; fi

# 5. every job is named with the cadence prefix; shards run on macOS, full corpus.
if [ "$(grep -c '^    name: ' <<< "$s")" = "$(grep -cE '^  [a-z][a-z-]*:$' <<< "$(awk '/^jobs:/ {f=1; next} f' <<< "$s")")" ] \
   && ! grep '^    name: ' <<< "$s" | grep -qv 'macos-cadence / '; then
  ok "every job name starts with 'macos-cadence / '"
else bad "a job has no name or one without the 'macos-cadence / ' prefix"; fi
# shellcheck disable=SC2016 # the ${{ }} is literal workflow text
if grep -q 'os: \[macos-latest\]' <<< "$s" && grep -q 'runs-on: \${{ matrix.os }}' <<< "$s"; then ok "shard matrix is macos-latest"
else bad "shard matrix is not macos-latest"; fi
if grep -q "SUITE_TIER_MODE: all" <<< "$s"; then ok "SUITE_TIER_MODE is all (the nightly's macOS coverage)"
else bad "SUITE_TIER_MODE is not all"; fi

# 6. shard count spelled three ways must agree, and match ci.yml's partition.
list="$(sed -n "s/^[[:space:]]*shard: .*== '' && '\[\([0-9, ]*\)\]'.*\$/\1/p" <<< "$s" | tr -d ' ')"
n_list="$(tr ',' '\n' <<< "$list" | grep -c .)"
n_run="$(sed -n 's/.*--shard \${{ matrix.shard }}\/\([0-9]*\) .*/\1/p' <<< "$s" | head -1)"
n_exp="$(sed -n 's/.*--shards-expected \([0-9]*\).*/\1/p' <<< "$s" | head -1)"
# ci.yml builds its matrix from the plan job; its fail-open default is the full list.
ci_list="$(strip "$CI_YML" | sed -n "s/^[[:space:]]*shard: .*|| '\[\(.*\)\]').*\$/\1/p" | head -1 | tr -d ' ')"
if [ "$n_list" = "$n_run" ] && [ "$n_run" = "$n_exp" ] && [ "$list" = "$ci_list" ]; then
  ok "shard list ($n_list), --shard /$n_run and --shards-expected $n_exp agree with ci.yml's partition"
else bad "shard spellings disagree: list=$n_list run=/$n_run expected=$n_exp ci.yml-list='$ci_list' here='$list'"; fi

# 7. same pinned action versions as ci.yml.
unpinned=""
# shellcheck disable=SC2013 # action refs contain no whitespace
for u in $(grep -o 'uses: [^ ]*' <<< "$s" | sed 's/uses: //' | sort -u); do
  grep -q "uses: $u\$" <<< "$(strip "$CI_YML")" || unpinned="$unpinned $u"
done
if [ -z "$unpinned" ]; then ok "every action is pinned to a version ci.yml already uses"
else bad "actions not pinned like ci.yml:$unpinned"; fi

# 8. the breakage metric is wired into the final job.
if grep -q 'scripts/ci/macos-breakage.sh record' <<< "$s" && grep -q 'macos-breakage-record' <<< "$s" \
   && grep -q 'GITHUB_STEP_SUMMARY' <<< "$s"; then ok "the summary job records the breakage metric (record + artifact + step summary)"
else bad "breakage metric is not wired into the workflow"; fi

# 9. fail closed: the record step pipes into tee, so it needs `shell: bash`
# (pipefail; the default `bash -e {0}` reports tee's status and a die inside
# record goes green), and a missing record.json must fail the upload.
step_of() { awk -v n="$1" 'index($0, "- name: " n) {f=1; print; next} f && /^      - / {f=0} f' <<< "$s"; }
if step_of "Record breakages" | grep -q '^        shell: bash$'; then ok "the record step runs under shell: bash (pipefail through | tee)"
else bad "the record step has no 'shell: bash': a die in record is masked by | tee"; fi
if step_of "Upload breakage record" | grep -q 'if-no-files-found: error'; then ok "a missing record.json fails the upload"
else bad "the record upload does not use if-no-files-found: error"; fi

# 9b. a PR run never writes the main cadence breakage record.
for st in "Record breakages" "Upload breakage record"; do
  if step_of "$st" | grep -q "^        if: .*github.event_name != 'pull_request'"; then ok "'$st' is skipped on a pull_request run"
  else bad "'$st' is not guarded by github.event_name != 'pull_request'"; fi
done

# 10. a shard without the completion sentinel (suites-from-logs rc 3)
# uploads NO failed.txt, so `summary` sees a missing report (infra_suspect).
lst="$(step_of "List failed suites")"
# shellcheck disable=SC2016 # literal workflow text, not an expansion
if grep -q 'suites-from-logs' <<< "$lst" && grep -q '"\$rc" = 3' <<< "$lst" && grep -q 'rm -f macos-failed/failed.txt' <<< "$lst"; then
  ok "the list step drops failed.txt when suites-from-logs reports no sentinel (rc 3)"
else bad "the list step does not handle suites-from-logs rc 3 by removing failed.txt"; fi
# Any other nonzero rc (a crash) also leaves the `>`-created failed.txt behind for
# the always-running upload: the rm must come first, before the step exits.
rm_ln="$(grep -n 'rm -f macos-failed/failed.txt' <<< "$lst" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016 # literal workflow text, not an expansion
exit_ln="$(grep -n 'exit "\$rc"' <<< "$lst" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016 # literal workflow text, not an expansion
ne_ln="$(grep -n '"\$rc" != 0' <<< "$lst" | head -1 | cut -d: -f1)"
if [ -n "$ne_ln" ] && [ -n "$rm_ln" ] && [ -n "$exit_ln" ] && [ "$ne_ln" -lt "$rm_ln" ] && [ "$rm_ln" -lt "$exit_ln" ]; then
  ok "any nonzero suites-from-logs status removes failed.txt before the step exits"
else bad "a nonzero suites-from-logs status other than 3 exits without removing failed.txt"; fi

# 11. a `suites` dispatch runs only the named suites on one runner;
# an empty input leaves the full 8-shard cadence and its breakage record alone.
inputs_block="$(awk '/^on:/ {f=1; next} f && /^[a-z]/ {f=0} f' <<< "$s" | awk '/^    inputs:/ {g=1; next} g && /^  [a-z]/ {g=0} g')"
if grep -q '^      suites:$' <<< "$inputs_block" && grep -q "^        type: string$" <<< "$inputs_block" && grep -q "^        default: ''$" <<< "$inputs_block"; then
  ok "workflow_dispatch has a string input 'suites' defaulting to empty"
else bad "workflow_dispatch has no 'suites' string input defaulting to ''"; fi
# shellcheck disable=SC2016 # literal workflow text
if grep -q "^run-name: .*inputs.suites != ''.*macos-cadence suites: {0}.*|| 'CI (os:macos cadence)'" <<< "$s"; then
  ok "run-name carries the named suites (ready-check item 10 reads it); an unfiltered run keeps the workflow name"
else bad "run-name does not carry 'macos-cadence suites: <list>' for a filtered run"; fi
# shellcheck disable=SC2016 # literal workflow text
if grep -qF "shard: \${{ fromJSON(inputs.suites == '' && '[1, 2, 3, 4, 5, 6, 7, 8]' || '[1]') }}" <<< "$s"; then
  ok "a suites dispatch is one runner, an unfiltered run is the eight shards"
else bad "the shard matrix does not shrink to one runner for a suites dispatch"; fi
tests_step="$(awk '/^      - id: tests$/ {f=1; next} f && /^      - / {f=0} f' <<< "$s")"
# shellcheck disable=SC2016 # literal workflow text
if grep -q 'SUITES: \${{ inputs.suites }}' <<< "$tests_step" && grep -q -- '--only-list macos-suites.txt' <<< "$tests_step" \
   && ! grep -q 'run-shell-tests.sh.*inputs.suites' <<< "$tests_step"; then
  ok "the tests step passes the input through env SUITES and runs --only-list; it is never interpolated into the script"
else bad "the tests step does not take the input through env SUITES into --only-list"; fi
# shellcheck disable=SC2016 # literal workflow text
if grep -q -- '--shard \${{ matrix.shard }}/8 \.' <<< "$tests_step"; then ok "an empty input still runs the unchanged --shard i/8 partition"
else bad "the unfiltered --shard i/8 run is gone from the tests step"; fi
rec="$(step_of "Record breakages")"; upl="$(step_of "Upload breakage record")"
if grep -q "^        if: github.event_name != 'pull_request' && inputs.suites == ''$" <<< "$rec" \
   && grep -q "^        if: always() && github.event_name != 'pull_request' && inputs.suites == ''$" <<< "$upl"; then
  ok "a suites dispatch records no breakage metric (a partial run would read unlisted suites as fixed)"
else bad "the breakage record/upload steps are not skipped for a suites dispatch"; fi

# 12. a label event that is not ci:macos runs no macOS job and queues behind nothing. Real data:
# every label event on scratch PR 3841 (no ci:macos) started a macos-cadence run whose shell and
# summary jobs were skipped (fixture, kind macos-label). Such a run in the shared PR group would
# replace the one PENDING real run there (a newer push waiting behind a running macOS run).
if ! python3 -I - "$WF" "${PR3841_FIXTURE:-$ROOT/scripts/ci/fixtures/ci-go-gate-pr3841-push.tsv}" <<'PY'
import re, sys

wf, fixture = sys.argv[1], sys.argv[2]
fails = 0
def ok(m): print("ok - " + m)
def bad(m):
    global fails
    fails += 1
    print("FAIL - " + m, file=sys.stderr)

lines = [re.sub(r"\s+#.*$", "", l) for l in open(wf).read().split("\n") if not l.lstrip().startswith("#")]

class N:
    def __init__(self, d): self.d = d
    def __getattr__(self, k):
        v = self.d.get(k)
        if v is None: return N({})
        return N(v) if isinstance(v, dict) else v
    def __bool__(self): return bool(self.d)
    def __eq__(self, o): return not self.d and o == ""
    def __ne__(self, o): return not self.__eq__(o)
    def __str__(self): return ""

def ev_inner(expr, ctx):
    e = expr.replace("github.event.pull_request.labels.*.name", "LABELS")
    e = e.replace("&&", " and ").replace("||", " or ")
    e = re.sub(r"!(?!=)", " not ", e)
    env = {"__builtins__": {}, "always": lambda: True, "contains": lambda a, b: b in a,
           "format": lambda f, *a: re.sub(r"\{(\d+)\}", lambda m: str(a[int(m.group(1))]), f), **ctx}
    return eval(e, env)

def ev_text(text, ctx):
    return re.sub(r"\$\{\{\s*(.*?)\s*\}\}", lambda m: str(ev_inner(m.group(1), ctx)), text)

def event(name, ref, action="", label="", labels=(), suites="", run_id="99"):
    gh = {"event_name": name, "ref": ref, "run_id": run_id,
          "event": {"action": action, "label": {"name": label}, "pull_request": {"labels": list(labels)}}}
    return {"github": N(gh), "inputs": N({"suites": suites} if suites else {}), "LABELS": list(labels)}

group = next((m.group(1) for l in lines for m in [re.match(r"^  group:\s*(macos-cadence-.*)$", l)] if m), "")
def job_if(job):
    inside = False
    for l in lines:
        if re.match(r"^  [a-z][a-z-]*:$", l):
            inside = l.strip() == job + ":"
        elif inside and l.startswith("    if: "):
            return l[len("    if: "):]
    return ""

PR = "refs/pull/9/merge"
sync = event("pull_request", PR, "synchronize", labels=["ci:macos"])
mac = event("pull_request", PR, "labeled", "ci:macos", ["ci:macos"])
other = event("pull_request", PR, "labeled", "ci:go", ["ci:macos", "ci:go"])
other2 = event("pull_request", PR, "labeled", "ci:go", ["ci:macos", "ci:go"], run_id="100")
sched = event("schedule", "refs/heads/main")
disp = event("workflow_dispatch", "refs/heads/x", suites="a.sh")
g = {k: ev_text(group, c) for k, c in [("sync", sync), ("mac", mac), ("other", other), ("other2", other2), ("sched", sched), ("disp", disp)]}

if g["sync"] == g["mac"] == "macos-cadence-%s-full" % PR and g["sched"] == "macos-cadence-refs/heads/main-full" \
        and g["disp"] == "macos-cadence-refs/heads/x-suites":
    ok("push, ci:macos label, schedule and suites dispatch keep their group (%s)" % g["sync"])
else:
    bad("groups changed for a run that must keep its group: %r" % g)
if g["other"] != g["sync"] and g["other"] != g["other2"] and g["other"].startswith("macos-cadence-"):
    ok("a label event other than ci:macos has its own group per run (%s)" % g["other"])
else:
    bad("a non-macos label event shares group %r with the push group %r (it replaces a pending macOS run)" % (g["other"], g["sync"]))

bad_if = []
for job in ("shell", "summary"):
    cond = job_if(job)
    if not cond:
        bad_if.append("job %s has no if" % job)
        continue
    for label, c, want in [("a non-macos label event", other, False), ("a push on a ci:macos PR", sync, True),
                           ("the ci:macos label", mac, True), ("schedule", sched, True),
                           ("a push on a PR without ci:macos", event("pull_request", PR, "synchronize", labels=["bug"]), False)]:
        if bool(ev_inner(cond, c)) != want:
            bad_if.append("job %s %s %s" % (job, "skips" if want else "runs", label))
if bad_if:
    bad("; ".join(bad_if))
else:
    ok("shell and summary skip a non-macos label event and a PR without ci:macos, and run for the rest")

rows = [l.rstrip("\n").split("\t") for l in open(fixture) if l.startswith("check\tmacos-label\t")]
if rows and all(r[3] == "skipped" for r in rows):
    ok("PR 3841: the real non-macos label event started a macos-cadence run with every job skipped (%d check-runs)" % len(rows))
else:
    bad("PR 3841 fixture lacks skipped macos-label check-runs: %r" % rows)
sys.exit(1 if fails else 0)
PY
then fails=$((fails + 1)); fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
