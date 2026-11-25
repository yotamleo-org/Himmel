#!/usr/bin/env bash
# scripts/ci/test-ci-go-gate.sh -- a pull request's CI starts every job at once
# (.github/workflows/ci.yml): opened, synchronize and reopened run every heavy and cheap
# job in one run whatever vars.CI_GO_GATE holds, a label event starts no run, and a first
# failure cancels the rest of the run. Pure text + an evaluator for the job `if:`,
# `name:` and concurrency expressions over sample events, no network.
#
#   G1  the pull_request types are opened, synchronize and reopened: neither
#       `labeled` nor `unlabeled` starts a run
#   G2  the skipped-job rename rule: a job that can be skipped carries a `name:`
#       expression that resolves to its literal name only when it runs and to
#       `<name> (deferred)` otherwise; a job that cannot be skipped has a literal name
#   G3  every heavy and cheap job runs on opened, synchronize and reopened with
#       vars.CI_GO_GATE on, off or unset (a plain push starts every job)
#   G4  on a pull_request event every required non-matrix context is written by
#       exactly one job under its literal name, and no required name resolves for
#       two jobs
#   G5  schedule and workflow_dispatch each run every heavy and cheap job
#       (plan and plugin-version-bump are pull_request-only)
#   G8  every pull_request event shares the PR's concurrency group, cron keeps ci-<run_id>
#   G9  every job is classified cheap or heavy (a new job forces a decision)
#   G10 the security invariants are in the ci.yml header comment
#   G11 on a plain push every required cheap job runs when ci-quick passed every
#       group (a skipped job reports its raw name expression, never the
#       required context, so a skipped sentinel leaves that context missing)
#   G12 against the real check-runs of scratch PR 3792: no job that is skipped on
#       a pull_request event reports a name the cheap or go run wrote as a real
#       result (live defect: ci-quick=failure then a label run's ci-quick=skipped)
#   G13 a plan that succeeded and skipped every optional scan (docs-only change)
#       never skips a required job: the job runs and its steps skip, so the
#       required context is written (a skipped job reports its raw name
#       expression, which satisfies nothing)
#   G16 fail-fast: every job that can fail a pull_request run has a fail-fast-<job>
#       twin that needs only it, starts only when it failed on a pull_request and
#       cancels the whole run; the shard matrix stops its own siblings
#   G17 no `if:`, `name:` or concurrency expression reads vars.CI_GO_GATE,
#       vars.CI_GO_LABEL or a label event
#
# The required-context list is a copy of the live ruleset
# (gh api repos/yotamleo-org/Himmel/rules/branches/main). The PR 3792 check-runs
# are a copy of gh api repos/yotamleo-org/Himmel/commits/<sha>/check-runs.
#
# Usage: bash scripts/ci/test-ci-go-gate.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
REQUIRED="${REQUIRED_CONTEXTS_FILE:-$ROOT/scripts/ci/fixtures/ci-go-gate-required-contexts.txt}"
CHECKS="${PR_CHECKS_FILE:-$ROOT/scripts/ci/fixtures/ci-go-gate-pr3792-checks.tsv}"

python3 -I - "$CI_YML" "$REQUIRED" "$CHECKS" <<'PY'
import re, sys

ci_yml, required_file, checks_file = sys.argv[1], sys.argv[2], sys.argv[3]
required = {l.strip() for l in open(required_file) if l.strip()}
checks = [l.rstrip("\n").split("\t") for l in open(checks_file) if l.strip() and not l.startswith("#")]
lines = open(ci_yml).read().split("\n")

CHEAP = {"plan", "ci-quick", "secret-scan", "bwk-awk-mktemp-gate", "unchecked-mktemp-range",
         "commit-lint", "jira-cli-smoke", "claude-startup", "guardrail-matrices",
         "doc-invariants", "lint", "plugin-version-bump"}
HEAVY = {"leak-classes", "git-env-scrub", "lanes-and-trust-suites", "bun-suites",
         "node-suites", "security-scan", "shell-unit-shard", "shell-unit"}
EXEMPT = {"guard-corpus-full"}
PR_ONLY = {"plan", "plugin-version-bump"}  # their base condition already names pull_request
AGGREGATOR = {"shell-unit"}                # needs the shards; the shards' twin covers it

fails = 0
def ok(m): print("ok - " + m)
def bad(m):
    global fails
    fails += 1
    print("FAIL - " + m, file=sys.stderr)

def strip_comment(s):
    return re.sub(r"\s+#.*$", "", s)

jobs, cur, in_jobs, mat = {}, None, False, False
for ln in lines:
    if ln == "jobs:":
        in_jobs = True
        continue
    if not in_jobs:
        continue
    m = re.match(r"^  ([A-Za-z0-9_-]+):\s*(#.*)?$", ln)
    if m:
        cur = m.group(1)
        jobs[cur] = {"if": None, "name": None, "needs": None, "matrix": False, "mvals": {}, "failfast": None}
        mat = False
        continue
    if cur is None:
        continue
    m = re.match(r"^    (if|name|needs):\s*(.*)$", ln)
    if m:
        jobs[cur][m.group(1)] = strip_comment(m.group(2)).strip()
    m = re.match(r"^      fail-fast:\s*(.*)$", ln)
    if m:
        jobs[cur]["failfast"] = strip_comment(m.group(1)).strip()
    if re.match(r"^      matrix:", ln):
        jobs[cur]["matrix"] = True
        mat = True
        continue
    if mat:
        body = strip_comment(ln)
        if body.strip() and len(body) - len(body.lstrip()) <= 6:
            mat = False
        else:
            kv = re.match(r"^\s*(?:-\s*)?([A-Za-z0-9_-]+):\s*(.+)$", body)
            if kv:
                jobs[cur]["mvals"].setdefault(kv.group(1), set()).update(
                    v.strip() for v in kv.group(2).strip("[] ").split(","))
TWINS = {j for j in jobs if j.startswith("fail-fast-")}
EXEMPT |= TWINS

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

def to_py(expr):
    e = re.sub(r"(?<=\.)([A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)+)", lambda m: m.group(1).replace("-", "_"), expr)
    e = e.replace("&&", " and ").replace("||", " or ")
    return re.sub(r"!(?!=)", " not ", e)

def ev_inner(expr, ctx):
    env = {"__builtins__": {}, "cancelled": lambda: False, "always": lambda: True,
           "success": lambda: True, "failure": lambda: False,
           "format": lambda f, *a: re.sub(r"\{(\d+)\}", lambda m: str(a[int(m.group(1))]), f),
           "needs": N({}), "matrix": N({}), "strategy": N({}), "job": N({}), **ctx}
    return eval(to_py(expr), env)

def ev_text(text, ctx):
    out, pos = "", 0
    for m in re.finditer(r"\$\{\{\s*(.*?)\s*\}\}", text, re.DOTALL):
        out += text[pos:m.start()] + str(ev_inner(m.group(1), ctx))
        pos = m.end()
    return out + text[pos:]

def event(name, action="", label="", gate=None, label_var=None):
    v = {}
    if gate is not None: v["CI_GO_GATE"] = gate
    if label_var is not None: v["CI_GO_LABEL"] = label_var
    gh = {"event_name": name, "run_id": "99", "event": {"action": action, "label": {"name": label},
          "pull_request": {"number": "42"}}}
    return {"github": N(gh), "vars": N(v)}

def runs(job, ctx):
    cond = jobs[job]["if"]
    if cond is None:
        return True
    cond = cond.strip()
    m = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", cond, re.DOTALL)
    return bool(ev_inner(m.group(1) if m else cond, ctx))

def name_of(job, ctx):
    n = jobs[job]["name"]
    return job if n is None else ev_text(n, ctx)

def skipped_name(j):  # a skipped job reports its raw name template, or its id when it has none
    n = jobs[j]["name"]
    return j if n is None else n

classified = CHEAP | HEAVY
unclassified = sorted(set(jobs) - classified - EXEMPT)
if unclassified:
    bad("G9 jobs neither cheap nor heavy: " + " ".join(unclassified))
else:
    ok("G9 every job is classified cheap or heavy")
missing = sorted(classified - set(jobs))
if missing:
    bad("G9 classified jobs missing from ci.yml: " + " ".join(missing))

pr = ""
for ln in lines:
    if re.match(r"^  pull_request:", ln):
        pr = "start"
        continue
    if pr and re.match(r"^  [a-z_]+:", ln):
        break
    if pr:
        pr += "\n" + strip_comment(ln)
types = re.search(r"types:\s*\[(.*?)\]", pr, re.DOTALL)
tl = [t.strip() for t in types.group(1).split(",")] if types else []
if sorted(tl) == ["opened", "reopened", "synchronize"]:
    ok("G1 the pull_request types are opened, synchronize, reopened: a label event starts no run")
else:
    bad("G1 pull_request types are %r (want exactly opened, synchronize, reopened)" % tl)

GATES = ("on", "off", "")
pr_events = [event("pull_request", a, "", g) for a in ("opened", "synchronize", "reopened") for g in GATES]

class PassOutputs:
    def __getattr__(self, k): return "pass"
class AllPass:  # a needs entry whose job succeeded: result 'success', every group output 'pass'
    def __getattr__(self, k):
        if k == "outputs": return PassOutputs()
        if k == "result": return "success"
        return self
class Planned:  # a plan that succeeded and skipped every optional scan; ci-quick passed every group
    def __init__(self, job): self.job = job
    def __getattr__(self, k):
        if k == "result": return "success"
        if k == "outputs": return Planned(self.job)
        return "pass" if self.job == "ci_quick" else "false"
class PlanNeeds:
    def __getattr__(self, k): return Planned(k)

bad2 = []
sample = [event(n, a, "", g) for n, a in (("pull_request", "synchronize"), ("schedule", ""), ("workflow_dispatch", "")) for g in ("on", "")]
for base in sample:
    for needs in (N({}), AllPass(), PlanNeeds()):
        ctx = dict(base, needs=needs)
        for j in sorted(set(jobs) - EXEMPT):
            if jobs[j]["matrix"] and jobs[j]["name"] is None:
                continue  # a matrix job's results carry the expanded name, a skip reports its unexpanded id
            if jobs[j]["name"] is None or "${{" not in jobs[j]["name"]:
                if not runs(j, ctx):
                    bad2.append("%s is skipped on %s with a literal name %r" % (j, base["github"].event_name, skipped_name(j)))
                continue
            if j in ("shell-unit",):
                continue  # shell-unit's own name carries the dispatch suffix and the os, and it always runs
            want = j if runs(j, ctx) else j + " (deferred)"
            got = name_of(j, ctx)
            if got != want:
                bad2.append("%s resolves to %r, want %r" % (j, got, want))
for j in sorted(TWINS):
    n = jobs[j]["name"] or ""
    if "${{" not in n or (j + " (deferred)") not in n:
        bad2.append("%s has no name expression that defers when the twin is skipped" % j)
if bad2:
    bad("G2 " + "; ".join(sorted(set(bad2))))
else:
    ok("G2 a job that can be skipped reports a deferred or raw-expression name; a job that cannot be skipped has a literal name")

bad3 = []
for ctx in pr_events:
    for j in sorted(classified & set(jobs)):
        if not runs(j, ctx):
            bad3.append("%s does not run on %s with CI_GO_GATE %r" % (j, ctx["github"].event.action, ctx["vars"].d.get("CI_GO_GATE")))
if bad3:
    bad("G3 " + "; ".join(sorted(set(bad3))))
else:
    ok("G3 opened, synchronize and reopened run every heavy and cheap job whatever CI_GO_GATE holds")

bad4 = []
for g in pr_events:
    names = {}
    for j in sorted(set(jobs) - EXEMPT):
        if runs(j, g):
            names.setdefault(name_of(j, g), []).append(j)
    for ctx in sorted(required):
        if ctx.startswith(("codeowner-review-gate", "pr-title-lint")):
            continue
        job = ctx.split(" (")[0]
        if jobs.get(job, {}).get("matrix"):
            if not runs(job, g):
                bad4.append("%r: matrix job %s does not run" % (ctx, job))
            else:
                entry = ctx[len(job) + 2:-1]
                keys = [k for k, v in jobs[job]["mvals"].items() if entry in v]
                if not keys:
                    bad4.append("%r: no %r entry in the %s matrix" % (ctx, entry, job))
                else:
                    mctx = dict(g, matrix=N({keys[0]: entry}))
                    nm = jobs[job]["name"]
                    got = "%s (%s)" % (job, entry) if nm is None else ev_text(nm, mctx)
                    if got != ctx:
                        bad4.append("%r: the %s matrix entry %r is named %r" % (ctx, job, entry, got))
            continue
        if names.get(ctx) != [ctx]:
            bad4.append("%r is written by %r" % (ctx, names.get(ctx)))
    for n, js in names.items():
        if n in required and len(js) > 1:
            bad4.append("%r written twice: %s" % (n, js))
if bad4:
    bad("G4 " + "; ".join(sorted(set(bad4))))
else:
    ok("G4 every required non-matrix context is written once, by its literal name, on every pull_request event, and no required name resolves for two jobs")

bad5 = []
for evn in ("schedule", "workflow_dispatch"):
    for gate in GATES:
        ctx = event(evn, "", "", gate)
        for j in sorted((HEAVY | CHEAP) & set(jobs) - PR_ONLY):
            if not runs(j, ctx):
                bad5.append("%s skipped on %s (gate %r)" % (j, evn, gate))
if bad5:
    bad("G5 " + "; ".join(sorted(set(bad5))))
else:
    ok("G5 schedule and workflow_dispatch run every heavy and cheap job")

grp = None
for i, ln in enumerate(lines):
    if ln.startswith("concurrency:"):
        for nxt in lines[i + 1:i + 4]:
            m = re.match(r"^  group:\s*(.*)$", strip_comment(nxt))
            if m: grp = m.group(1).strip()
        break
if not grp:
    bad("G8 no workflow-level concurrency group")
else:
    groups = {ev_text(grp, c) for c in pr_events}
    g_sched = ev_text(grp, event("schedule"))
    if groups == {"ci-pr-42"} and g_sched == "ci-99":
        ok("G8 every pull_request event shares ci-pr-<N>, cron keeps ci-<run_id>")
    else:
        bad("G8 groups: pull_request=%r schedule=%r" % (sorted(groups), g_sched))

bad11 = []
for ctx0 in pr_events:
    ctx = dict(ctx0, needs=AllPass())
    for j in sorted(CHEAP & required & set(jobs)):
        if not runs(j, ctx):
            bad11.append("%s is skipped on %s while ci-quick passed" % (j, ctx0["github"].event.action))
        elif name_of(j, ctx) != j:
            bad11.append("%s is named %r on %s" % (j, name_of(j, ctx), ctx0["github"].event.action))
if bad11:
    bad("G11 " + "; ".join(sorted(set(bad11))))
else:
    ok("G11 every required cheap job runs on a plain push when ci-quick passed every group")

req_jobs = sorted({c.split(" (")[0] for c in required
                   if not c.startswith(("codeowner-review-gate", "pr-title-lint"))} & set(jobs))
bad13 = []
for ctx0 in pr_events:
    for j in req_jobs:
        if not runs(j, dict(ctx0, needs=PlanNeeds())):
            bad13.append("%s is skipped on %s when the plan skips every scan, leaving its required context missing" % (j, ctx0["github"].event.action))
if bad13:
    bad("G13 " + "; ".join(sorted(set(bad13))))
else:
    ok("G13 a plan that skips every optional scan never skips a required job (the job runs and its steps skip)")

UNEXPANDED = {j for j in jobs if jobs[j]["matrix"] and jobs[j]["name"] is None}
SCHEDULE_ONLY = {"guard-corpus-full"}  # never runs on a pull_request event, so it replaces nothing there
real = {n for k, n, c in checks if k in ("cheap", "go") and c != "skipped" and "&&" not in n and "${{" not in n}
real -= UNEXPANDED
recorded = {n: c for k, n, c in checks if k == "label"}
bad12 = []
if not ({"ci-quick", "plan", "plugin-version-bump"} <= real and recorded.get("ci-quick") == "skipped"):
    bad12.append("the PR 3792 fixture no longer shows ci-quick written by the cheap run and skipped by the label run")
for ctx0 in pr_events:
    for needs in (N({}), AllPass(), PlanNeeds()):
        ctx = dict(ctx0, needs=needs)
        for j in sorted(jobs):
            if not runs(j, ctx) and j not in SCHEDULE_ONLY and skipped_name(j) in real:
                bad12.append("%s is skipped under %r, a name the PR 3792 cheap or go run wrote" % (j, skipped_name(j)))
if bad12:
    bad("G12 " + "; ".join(sorted(set(bad12))))
else:
    ok("G12 no job skipped on a pull_request event reports a name the PR 3792 cheap or go run wrote")

bad16 = []
for j in sorted(set(jobs) - EXEMPT - AGGREGATOR):
    t = "fail-fast-" + j
    if t not in jobs:
        bad16.append("%s has no %s twin" % (j, t))
        continue
    if jobs[t]["needs"] != j:
        bad16.append("%s needs %r, want only %s" % (t, jobs[t]["needs"], j))
    cond = jobs[t]["if"] or ""
    if "needs.%s.result == 'failure'" % j not in cond or "github.event_name == 'pull_request'" not in cond or "failure()" not in cond:
        bad16.append("%s does not start only on a failed %s on a pull_request" % (t, j))
body = "\n".join(lines)
twin_run = re.findall(r"\n  fail-fast-[a-z0-9-]+:.*?(?=\n  [A-Za-z0-9_-]+:\s*(?:#.*)?\n)", body, re.DOTALL)
if not twin_run or any('gh run cancel "$RUN_ID"' not in blk for blk in twin_run):
    bad16.append("a fail-fast twin does not cancel the run (gh run cancel \"$RUN_ID\")")
ff = jobs.get("shell-unit-shard", {}).get("failfast")
if ff not in ("true", "${{ github.event_name == 'pull_request' }}"):
    bad16.append("the shell-unit-shard matrix does not stop at its first red shard on a pull_request (fail-fast: %r)" % ff)
if bad16:
    bad("G16 " + "; ".join(sorted(set(bad16))))
else:
    ok("G16 every job has a fail-fast twin that needs only it, starts only on a pull_request failure and cancels the run; the shard matrix stops its siblings")

bad17 = []
for i, ln in enumerate(lines, 1):
    s = strip_comment(ln) if not ln.lstrip().startswith("#") else ""
    if re.search(r"CI_GO_GATE|CI_GO_LABEL|ci:go|event\.label|action\s*[=!]=\s*'labeled'", s):
        bad17.append("ci.yml:%d reads the label gate: %s" % (i, s.strip()[:80]))
if bad17:
    bad("G17 " + "; ".join(bad17[:5]) + ("; %d more" % (len(bad17) - 5) if len(bad17) > 5 else ""))
else:
    ok("G17 no expression in ci.yml reads CI_GO_GATE, CI_GO_LABEL, a label name or a labeled action")

head = "\n".join(lines[:lines.index("jobs:")])
inv = ["Never pull_request_target", "approve and run", "Rename rule"]
miss = [s for s in inv if s not in head]
if miss:
    bad("G10 header comment lacks: " + "; ".join(miss))
else:
    ok("G10 the header comment states the rename rule and the security invariants")

sys.exit(1 if fails else 0)
PY
rc=$?
if [ "$rc" -ne 0 ]; then echo "test-ci-go-gate: FAILED" >&2; exit 1; fi
echo "test-ci-go-gate: all passed"
