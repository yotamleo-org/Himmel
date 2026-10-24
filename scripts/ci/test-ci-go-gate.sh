#!/usr/bin/env bash
# scripts/ci/test-ci-go-gate.sh -- the ci:go label gate in .github/workflows/ci.yml
# A push runs only the cheap jobs; the heavy jobs run once the
# ci:go label is added (vars.CI_GO_GATE=on). vars.CI_GO_GATE off restores
# today's behaviour. Pure text + an evaluator for the job `if:`, `name:` and
# concurrency expressions over sample events, no network.
#
#   G1  `labeled` is in the pull_request types, `unlabeled` is not
#   G2  a non-go labeled event runs nothing, and no skipped job reports a name
#       that any job writes when it runs (a skipped check-run under a real name
#       replaces an earlier failure under the latest-per-name rule)
#   G3  every heavy job is skipped on a plain push with the gate on, and its
#       skipped name differs from its required context
#   G4  on the go run every required non-matrix context is written by exactly one
#       job under its literal name
#   G5  schedule and workflow_dispatch each run every heavy and cheap job
#       (plan and plugin-version-bump are pull_request-only before this gate)
#   G6  on a go run no required name resolves for two jobs
#   G7  gate off: a push runs every job as today and a label event runs none
#   G8  the go run shares the PR's concurrency group, an unrelated label gets its own
#   G9  every job is classified cheap or heavy (a new job forces a decision)
#   G10 the five security invariants are in the ci.yml header comment
#   G11 on a plain push every required cheap job runs when ci-quick passed every
#       group (a skipped job reports its raw name expression, never the
#       required context, so a skipped sentinel leaves that context missing)
#   G12 against the real check-runs of scratch PR 3792: no job that is skipped on
#       a pull_request event reports a name the cheap or go run wrote as a real
#       result (live defect: ci-quick=failure then a label run's ci-quick=skipped)
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

fails = 0
def ok(m): print("ok - " + m)
def bad(m):
    global fails
    fails += 1
    print("FAIL - " + m, file=sys.stderr)

def strip_comment(s):
    return re.sub(r"\s+#.*$", "", s)

# ---- parse jobs ----
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
        jobs[cur] = {"if": None, "name": None, "matrix": False, "mvals": {}}
        mat = False
        continue
    if cur is None:
        continue
    m = re.match(r"^    (if|name):\s*(.*)$", ln)
    if m:
        jobs[cur][m.group(1)] = strip_comment(m.group(2)).strip()
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
for j in jobs:
    if j.startswith("fail-fast-"):
        EXEMPT.add(j)

# ---- expression evaluator ----
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

classified = CHEAP | HEAVY
unclassified = sorted(set(jobs) - classified - EXEMPT)
if unclassified:
    bad("G9 jobs neither cheap nor heavy: " + " ".join(unclassified))
else:
    ok("G9 every job is classified cheap or heavy")
missing = sorted(classified - set(jobs))
if missing:
    bad("G9 classified jobs missing from ci.yml: " + " ".join(missing))

# ---- G1 ----
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
if "labeled" in tl and "unlabeled" not in tl:
    ok("G1 labeled is in the pull_request types, unlabeled is not")
else:
    bad("G1 pull_request types are %r (want labeled, never unlabeled)" % tl)

# ---- G2 ----
nongo = [event("pull_request", "labeled", "bug", g) for g in ("on", "off", "")]
nongo += [event("pull_request", "labeled", "ci:go", "off"), event("pull_request", "labeled", "ci:go", "")]
go = event("pull_request", "labeled", "ci:go", "on")
go_custom = event("pull_request", "labeled", "release-me", "on", "release-me")
pr_events = [event("pull_request", a, "", g) for a in ("opened", "synchronize", "reopened") for g in ("on", "off", "")]
pr_events += [go, go_custom] + nongo

def skipped_name(j):  # a skipped job reports its raw name template, or its id when it has none
    n = jobs[j]["name"]
    return j if n is None else n

# a matrix job's unexpanded id is only ever posted by a skip or a cancel; its results carry the expanded name
UNEXPANDED = {j for j in jobs if jobs[j]["matrix"] and jobs[j]["name"] is None}
SCHEDULE_ONLY = {"guard-corpus-full"}  # never runs on a pull_request event, so it replaces nothing there
written = set(required)  # every name a job writes when it runs on a pull_request event
for ctx in pr_events:
    for j in jobs:
        # a fail-fast job runs on a failure, which the evaluator cannot model: take its name as if it ran
        if (runs(j, ctx) or j.startswith("fail-fast-")) and not jobs[j]["matrix"]:
            written.add(name_of(j, ctx))
written -= UNEXPANDED

bad2 = []
for ctx in nongo:
    for j in sorted(jobs):
        if runs(j, ctx):
            bad2.append("%s runs on a non-go label event" % j)
        elif j not in SCHEDULE_ONLY and skipped_name(j) in written:
            bad2.append("%s is skipped under the real name %r" % (j, skipped_name(j)))
if bad2:
    bad("G2 " + "; ".join(sorted(set(bad2))))
else:
    ok("G2 a non-go label event runs nothing and skips no job under a name any job writes")

# ---- G3 ----
push = [event("pull_request", a, "", "on") for a in ("opened", "synchronize", "reopened")]
bad3 = []
for ctx in push:
    for j in sorted(HEAVY & set(jobs)):
        if runs(j, ctx):
            bad3.append("%s runs on a plain push with the gate on" % j)
        elif name_of(j, ctx) in required:
            bad3.append("%s is skipped under the required name %r" % (j, name_of(j, ctx)))
    for j in sorted(CHEAP & set(jobs)):
        if j.startswith("fail-fast"): continue
        if not runs(j, ctx):
            bad3.append("cheap %s does not run on a plain push" % j)
if bad3:
    bad("G3 " + "; ".join(sorted(set(bad3))))
else:
    ok("G3 a push with the gate on runs the cheap jobs and defers every heavy job under a non-required name")

# ---- G4 / G6 ----
bad4 = []
for g in (go, go_custom):
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
                bad4.append("%r: matrix job %s does not run on the go run" % (ctx, job))
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
                        bad4.append("%r: the %s matrix entry %r is named %r on the go run" % (ctx, job, entry, got))
            continue
        if names.get(ctx) != [ctx]:
            bad4.append("%r is written by %r on the go run" % (ctx, names.get(ctx)))
    for n, js in names.items():
        if n in required and len(js) > 1:
            bad4.append("%r written twice on the go run: %s" % (n, js))
if bad4:
    bad("G4/G6 " + "; ".join(sorted(set(bad4))))
else:
    ok("G4 every required non-matrix context is written once, by its literal name, on the go run (default and custom label)")
    ok("G6 no required name resolves for two jobs on the go run")

# ---- G5 ----
bad5 = []
for evn in ("schedule", "workflow_dispatch"):
    for gate in ("on", "off", ""):
        ctx = event(evn, "", "", gate)
        for j in sorted((HEAVY | CHEAP) & set(jobs) - PR_ONLY):
            if not runs(j, ctx):
                bad5.append("%s skipped on %s (gate %r)" % (j, evn, gate))
if bad5:
    bad("G5 " + "; ".join(sorted(set(bad5))))
else:
    ok("G5 schedule and workflow_dispatch run every heavy and cheap job")

# ---- G7 ----
bad7 = []
for gate in ("off", ""):
    for a in ("opened", "synchronize", "reopened"):
        ctx = event("pull_request", a, "", gate)
        for j in sorted(classified & set(jobs)):
            if not runs(j, ctx):
                bad7.append("%s skipped on %s with the gate %r" % (j, a, gate))
if bad7:
    bad("G7 " + "; ".join(sorted(set(bad7))))
else:
    ok("G7 gate off: a push runs every job as today (label events run none, see G2)")

# ---- G8 ----
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
    g_push = ev_text(grp, event("pull_request", "synchronize", "", "on"))
    g_go = ev_text(grp, event("pull_request", "labeled", "ci:go", "on"))
    g_other = ev_text(grp, event("pull_request", "labeled", "bug", "on"))
    g_sched = ev_text(grp, event("schedule"))
    if g_push == g_go == "ci-pr-42" and g_other != "ci-pr-42" and g_sched == "ci-99":
        ok("G8 the go run shares ci-pr-<N>, an unrelated label has its own group, cron keeps ci-<run_id>")
    else:
        bad("G8 groups: push=%r go=%r other-label=%r schedule=%r" % (g_push, g_go, g_other, g_sched))

# ---- G11 ----
class PassOutputs:
    def __getattr__(self, k): return "pass"
class AllPass:  # a needs entry whose job succeeded: result 'success', every group output 'pass'
    def __getattr__(self, k):
        if k == "outputs": return PassOutputs()
        if k == "result": return "success"
        return self
bad11 = []
for gate in ("on", "off", ""):
    for a in ("opened", "synchronize", "reopened"):
        ctx = dict(event("pull_request", a, "", gate), needs=AllPass())
        for j in sorted(CHEAP & required & set(jobs)):
            if not runs(j, ctx):
                bad11.append("%s is skipped on %s with the gate %r while ci-quick passed" % (j, a, gate))
            elif name_of(j, ctx) != j:
                bad11.append("%s is named %r on %s with the gate %r" % (j, name_of(j, ctx), a, gate))
if bad11:
    bad("G11 " + "; ".join(sorted(set(bad11))))
else:
    ok("G11 every required cheap job runs on a plain push when ci-quick passed every group")

# ---- G12 ----
real = {n for k, n, c in checks if k in ("cheap", "go") and c != "skipped" and "&&" not in n and "${{" not in n}
real -= UNEXPANDED
recorded = {n: c for k, n, c in checks if k == "label"}
bad12 = []
if not ({"ci-quick", "plan", "plugin-version-bump"} <= real and recorded.get("ci-quick") == "skipped"):
    bad12.append("the PR 3792 fixture no longer shows ci-quick written by the cheap run and skipped by the label run")
for ctx in pr_events:
    for j in sorted(jobs):
        if not runs(j, ctx) and j not in SCHEDULE_ONLY and skipped_name(j) in real:
            bad12.append("%s is skipped under %r, a name the PR 3792 cheap or go run wrote" % (j, skipped_name(j)))
if bad12:
    bad("G12 " + "; ".join(sorted(set(bad12))))
else:
    ok("G12 no job skipped on a pull_request event reports a name the PR 3792 cheap or go run wrote")

# ---- G10 ----
head = "\n".join(lines[:lines.index("jobs:")])
inv = ["never satisfies a gate", "Never pull_request_target", "approve and run", "required-context names are literal on the go path", "manual release"]
miss = [s for s in inv if s not in head]
if miss:
    bad("G10 header comment lacks invariants: " + "; ".join(miss))
else:
    ok("G10 the five security invariants are in the ci.yml header comment")

sys.exit(1 if fails else 0)
PY
rc=$?
if [ "$rc" -ne 0 ]; then echo "test-ci-go-gate: FAILED" >&2; exit 1; fi
echo "test-ci-go-gate: all passed"
