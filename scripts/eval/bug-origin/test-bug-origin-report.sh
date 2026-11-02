#!/usr/bin/env bash
# scripts/eval/bug-origin/test-bug-origin-report.sh - suite for bug-origin-report.py: the line parser, the
# layer map, the review evidence, the five report sections, the eval-runs row and the trace of a fix's
# introducing commits. Fixtures only: no model, no network, never the live ledgers.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPORT="$HERE/bug-origin-report.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bug-origin-test.XXXXXX")" || { echo "test-bug-origin-report: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never-runs.jsonl"
# the ledger resolves through these two; neither exists, so no test reads the real bucket or the real registry
export HANDOVER_DIR="$TMP/never-handover" HANDOVER_REGISTRY="$TMP/never-registry.json"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
FIX="$TMP/fix"
mkdir -p "$FIX/verdicts/q1" "$FIX/verdicts-early/q2" "$FIX/mirror"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1: no '$3' in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1: found '$3'" ;; *) pass "$1" ;; esac; }
# the one report line holding $1, from the output $2
line_of() { printf '%s\n' "$2" | grep -F -- "$1" | head -n 1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-bug-origin-report: python3 not on PATH"; exit 0; }

python3 -I - "$FIX" <<'PY' || { echo "test-bug-origin-report: writing the fixtures failed" >&2; exit 1; }
import json, os, sys
d = sys.argv[1]
def pr(n, title, body="", day=10):
    return {"number": n, "title": title, "body": body, "mergedAt": "2026-10-%02dT12:00:00Z" % day,
            "headRefName": "b%d" % n, "headRefOid": "%040x" % n, "mergeCommit": {"oid": "%040x" % (n + 1000)}}
prs = [pr(2, "fix(a): [HIMMEL-2] older than every row", day=2),
       pr(5, "feat(a): [HIMMEL-5] older than the ledger", day=2),
       pr(10, "feat(a): [HIMMEL-10] seen by all three", day=10),
       pr(11, "feat(a): [HIMMEL-11] seen by none", day=11),
       pr(20, "fix(a): [HIMMEL-20] x", "bug-origin: #10 review-miss:cr — dropped exit code", 20),
       pr(21, "fix(a): [HIMMEL-21] x", "bug-origin: #11 review-miss:judge — no evidence for the claim", 21),
       pr(22, "fix(a): [HIMMEL-22] x", "bug-origin: #5 review-miss:cr — wrong variable", 22),
       pr(23, "fix(a): [HIMMEL-23] x", "bug-origin: #10 design-gap — the body wins", 23),
       pr(24, "fix(a): [HIMMEL-24] x", "", 24),
       pr(25, "fix(a): [HIMMEL-25] a Bug with no row", "", 25),
       pr(26, "fix(a): [HIMMEL-26] fix-titled and not a Bug", "", 26),
       pr(27, "chore(a): [HIMMEL-27] a row on a non-Bug", "bug-origin: unknown unknown — slice, origin on HIMMEL-9", 27),
       pr(28, "fix(a): [HIMMEL-28] x", "bug-origin: #12 test-gap", 28),
       pr(29, "fix(a): [HIMMEL-29] x", "bug-origin: #29 test-gap — names itself", 29),
       pr(30, "fix(a): [HIMMEL-30] x", "bug-origin: #31 test-gap — merged later", 29),
       pr(31, "feat(a): [HIMMEL-31] x", "", 31),
       pr(32, "fix(a): [HIMMEL-32] x", "bug-origin: #10 test-gap — see #11 as well", 30),
       pr(33, "fix(a): [HIMMEL-33] x", "bug-origin: abcdef1 review-miss:panel — no such commit", 30)]
json.dump(prs, open(os.path.join(d, "prs.json"), "w"))
for row in [{"pr": 23, "origin": "#11", "class": "test-gap", "reason": "the seed loses"},
            {"pr": 24, "origin": "#11", "class": "test-gap", "reason": "only the seed has it"}]:
    open(os.path.join(d, "seed.jsonl"), "a").write(json.dumps(row) + "\n")
def avail(br, model, ts, rm=None):
    r = {"kind": "avail", "ts": ts, "branch": br, "head": "h", "model": model, "status": "ok",
         "artifact": "diff", "perspective": "off"}
    if rm:
        r["responding_model"] = rm
    return r
cr = [avail("first", "codex", "2026-10-03T00:00:00Z"),
      avail("b10", "codex", "2026-10-09T00:00:00Z", "gpt-6.1-sol"),
      avail("b10", "coderabbit-outside", "2026-10-09T00:00:00Z"),
      avail("b10", "worker-scope", "2026-10-09T00:00:00Z"),
      avail("b11", "codex", "2026-10-25T00:00:00Z", "gpt-6.1-sol")]
with open(os.path.join(d, "cr.jsonl"), "w") as fh:
    for r in cr:
        fh.write(json.dumps(r) + "\n")
    fh.write("not json at all\n")
with open(os.path.join(d, "cr-judge.jsonl"), "w") as fh:
    fh.write(json.dumps(avail("b11", "judge-opus", "2026-10-09T00:00:00Z")) + "\n")
def verdict(path, pr_n, day):
    with open(path, "w") as fh:
        fh.write("pr: %d\nmodel: claude-opus-5-5\nwritten-at: 2026-10-%02dT00:00:00Z\n\n**GO** for head `%040x`\n" % (pr_n, day, pr_n))
verdict(os.path.join(d, "verdicts", "q1", "judge.md"), 10, 9)
verdict(os.path.join(d, "verdicts-early", "q2", "judge.md"), 99, 1)
def ticket(key, typ, body=""):
    with open(os.path.join(d, "mirror", key + ".md"), "w") as fh:
        fh.write('---\ntype: "%s"\nlabels: []\ncreated: "2026-10-01T00:00:00Z"\n---\n%s\n' % (typ, body))
for n in (2, 20, 21, 22, 23, 24, 25, 28, 29, 30, 33):
    ticket("HIMMEL-%d" % n, "Bug")
ticket("HIMMEL-32", "Bug", "caused-by: #11")
for n in (26, 27):
    ticket("HIMMEL-%d" % n, "Task")
PY

# --- the units
rm -f "$TMP/units.out"
python3 -I - "$REPORT" "$FIX" "$HERE/line-table.tsv" "$TMP" > "$TMP/units.out" 2>&1 <<'PY'
import importlib.util, json, os, re, subprocess, sys
path, d, table, tmp = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("bug_origin_report", path)
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
def eq(name, got, want):
    print(("PASS " + name) if got == want else "FAIL %s: expected %r, got %r" % (name, want, got))

# I3: the table test-ready-check.sh reads too
ESC = {"n": "\n", "r": "\r", "t": "\t"}
rows = 0
for nr, line in enumerate(open(table, encoding="utf-8").read().splitlines(), 1):
    want, _, body = line.partition("\t")
    body = re.sub(r"\\([nrt])", lambda m: ESC[m.group(1)], body)
    eq("line table row %d (%s)" % (nr, want), r.parse_body(body)[0], want)
    rows += 1
eq("line table has its rows", rows >= 50, True)
state, got = r.parse_body("intro\nbug-origin: abcdef1 review-miss:cr - a hyphenated-reason\r\n")
eq("parse_body fields", got, {"origin": "abcdef1", "class": "review-miss:cr", "reason": "a hyphenated-reason"})
eq("parse_body null", r.parse_body(None), ("none", None))
eq("parse_body unknown origin", r.parse_body("bug-origin: unknown unknown — x")[1],
   {"origin": "unknown", "class": "unknown", "reason": "x"})

# the layer map
for name, want in [("coderabbit-outside", "cr"), ("claude-floor", "panel"), ("codex-adv", "panel"),
                   ("claude-session", "panel"), ("opus", "panel"), ("gpt-6.1-sol", "panel"),
                   ("claude:claude-opus-5-5", "panel"), ("codex:gpt-6.1-sol", "panel"), ("judge-opus", "judge"),
                   ("judge", "judge"), ("worker-scope", None), ("", None), ("native-n3323", None)]:
    eq("layer map %r" % name, r.layer_of(name), want)

# the evidence states
prs = json.load(open(os.path.join(d, "prs.json")))
merged = {p["number"]: p for p in prs}
ledger, vs = os.path.join(d, "cr.jsonl"), os.path.join(d, "verdicts")
full = r.load_sources(ledger, [vs])
e = r.evidence(merged[10], merged, full)
eq("evidence on record: cr", e["cr"], "on record: coderabbit-outside")
eq("evidence on record: panel", e["panel"], "on record: codex")
eq("evidence on record: judge", e["judge"], "on record: claude-opus-5-5")
e = r.evidence(merged[11], merged, full)
eq("evidence not on record: panel, and a review row after the merge is out", e["panel"], "not on record")
eq("evidence not on record: cr carries the clean pass", e["cr"], "not on record (a clean pass leaves no row)")
eq("evidence not on record: judge", e["judge"], "not on record")
e = r.evidence(merged[5], merged, full)
eq("evidence no coverage: cr", e["cr"], "no coverage before 2026-10-03T00:00:00Z")
eq("evidence no coverage: judge older than both", e["judge"], "no coverage before 2026-10-03T00:00:00Z")
early = r.load_sources(ledger, [os.path.join(d, "verdicts-early")])
eq("evidence no coverage: judge needs older than both", r.evidence(merged[5], merged, early)["judge"], "not on record")
for name, s in [("no sources", r.load_sources(None, [])),
                ("a missing ledger and tree", r.load_sources(os.path.join(d, "nope.jsonl"), [os.path.join(d, "nope")]))]:
    e = r.evidence(merged[10], merged, s)
    eq("evidence not read, %s" % name, e, {"cr": "not read", "panel": "not read", "judge": "not read"})
e = r.evidence(merged[11], merged, r.load_sources(os.path.join(d, "cr-judge.jsonl"), []))
eq("evidence: a ledger judge row with no verdict tree is on record", e["judge"], "on record: judge-opus")
e = r.evidence(merged[10], merged, r.load_sources(None, [vs]))
eq("evidence: a verdict with no ledger is on record", e["judge"], "on record: claude-opus-5-5")
eq("evidence: no ledger reads cr not read", e["cr"], "not read")
e = r.evidence(merged[11], merged, r.load_sources(None, [vs]))
eq("evidence: judge with one source unread is not read", e["judge"], "not read")

# commit_to_pr on a throwaway repo
repo = os.path.join(tmp, "sha-repo")
os.makedirs(repo)
def git(*a):
    return subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", *a],
                          capture_output=True, text=True, check=True).stdout.strip()
git("init", "-q")
def commit(subject):
    git("commit", "-q", "--allow-empty", "-m", subject)
    return git("rev-parse", "HEAD")
squash, subj, plain = commit("squashed"), commit("fix(a): thing (#77)"), commit("no number here")
snap = {7: {"mergeCommit": {"oid": squash}}, 8: {"mergeCommit": {"oid": "abcdef1" + "0" * 33}},
        9: {"mergeCommit": {"oid": "abcdef1" + "1" * 33}}, 6: {"mergeCommit": None}}
eq("sha maps: the snapshot's squash oid", r.commit_to_pr(squash[:9], snap, repo), 7)
eq("sha maps: a (#n) subject", r.commit_to_pr(subj, snap, repo), 77)
eq("sha maps: a plain commit", r.commit_to_pr(plain, snap, repo), None)
eq("sha maps: an ambiguous prefix", r.commit_to_pr("abcdef1", snap, repo), None)
eq("sha maps: an absent commit", r.commit_to_pr("0" * 40, snap, repo), None)

# Assumption 13, on existing code
fx = [{"number": 1, "title": "feat: a", "body": "", "mergedAt": "2026-10-01T00:00:00Z"},
      {"number": 2, "title": "fix: b", "body": "bug-origin: #1 test-gap — x", "mergedAt": "2026-10-02T00:00:00Z"}]
sig = r.escapes.signals(fx, [])[1]
eq("fix-forward feed", ("fix-forward", "P") in sig.get(1, ()), True)

# the title key against the bash one
for title in ["fix: [HIMMEL-1] x", "fix: [himmel-2] x", "fix: [A1-3] [B-4] x", "fix: no key", "fix: [1A-5] x", "fix: [A-] x"]:
    sh = subprocess.run(["bash", "-c", '. "$1" 2>/dev/null; ticket_key_from_title "$2"', "_",
                         os.path.join(os.path.dirname(path), "..", "..", "lib", "ticket-status.sh"), title],
                        capture_output=True, text=True).stdout.strip()
    eq("title key %r" % title, r.title_key(title) or "", sh)
PY
units_rc=$?
cat "$TMP/units.out"
PASS=$((PASS + $(grep -c '^PASS ' "$TMP/units.out")))
FAIL=$((FAIL + $(grep -c '^FAIL ' "$TMP/units.out")))
eq "units ran to their end" "$units_rc" "0"

# --- the report
rep() { python3 "$REPORT" report --prs "$FIX/prs.json" "$@" 2>&1; }

rc=0; out="$(rep --seed "$FIX/seed.jsonl" --cr-ledger "$FIX/cr.jsonl" --verdicts "$FIX/verdicts" --mirror "$FIX/mirror")" || rc=$?
eq "report: exit 0" "$rc" "0"
has "report: the header says one worker, no second reader" "$out" "hand-classified by one worker"
# I4: 20 21 22 23 24 27 29 30 32 33 are rows, the malformed 28 is not
eq "counts: rows" "$(line_of 'rows: ' "$out")" "rows: 10"
has "counts: review-miss:cr" "$out" "review-miss:cr: 2"
has "counts: review-miss:judge" "$out" "review-miss:judge: 1"
has "counts: review-miss:panel" "$out" "review-miss:panel: 1"
has "counts: review-miss subtotal" "$out" "review-miss: 4"
has "body wins and counts sum: design-gap" "$out" "design-gap: 1"
has "body wins and counts sum: test-gap" "$out" "test-gap: 4"
has "counts: unknown" "$out" "unknown: 1"
# I6
has "credit: cr" "$out" "credit cr: 1"
has "credit: panel" "$out" "credit panel: 1"
has "credit: judge" "$out" "credit judge: 1"
has "credit: says it may sum above the rows" "$out" "may sum above"
l="$(line_of 'fix #20 ' "$out")"
has "review-miss row names the review" "$l" "cr=on record: coderabbit-outside"
has "review-miss row names the ticket and origin" "$l" "HIMMEL-20 origin #10"
hasnt "review-miss row with its layer on record: no flag" "$l" "claimed layer"
l="$(line_of 'fix #21 ' "$out")"
has "claimed layer not on record is flagged" "$l" "claimed layer not on record"
l="$(line_of 'fix #22 ' "$out")"
has "no coverage row reads its state" "$l" "cr=no coverage before 2026-10-03T00:00:00Z"
hasnt "no coverage is no claim flag" "$l" "claimed layer"
l="$(line_of 'fix #33 ' "$out")"
has "flags: origin maps to no PR" "$l" "origin maps to no PR"
has "a row whose cr is claimed carries the clean pass wording" "$(rep --seed "$FIX/seed.jsonl" --cr-ledger "$FIX/cr-judge.jsonl" | grep -F 'fix #20 ')" "cr=not on record (a clean pass leaves no row)"
has "claimed cr with no row: the flag carries the wording" "$(rep --cr-ledger "$FIX/cr-judge.jsonl" | grep -F 'fix #20 ')" "claimed layer not on record (a clean pass leaves no row)"
hasnt "not read is no claim flag" "$(rep | grep -F 'fix #20 ')" "claimed layer"
has "flags: impossible origin, the fix PR" "$out" "impossible origin: fix #29 origin #29"
has "flags: impossible origin, a later merge" "$out" "impossible origin: fix #30 origin #31"
has "flags: caused-by disagrees" "$out" "caused-by #11 disagrees: fix #32 origin #10"
has "flags: reason names a PR" "$out" "reason names a PR: fix #32"
has "flags: unparsed" "$out" "unparsed: #28"
hasnt "flags: the seed is not a flag" "$out" "unparsed: #24"
# from the oldest row, 2026-10-20: Bug PRs 20 21 22 23 24 25 28 29 30 32 33, and not the older 2
has "coverage: starts at the oldest row" "$out" "from 2026-10-20T12:00:00Z"
has "coverage: Bug-ticket PRs" "$out" "Bug-ticket PRs: 11"
has "coverage: with a row" "$out" "with a row: 9"
has "coverage: distinct Bug keys" "$out" "distinct Bug keys: 11"
has "coverage: rows on non-Bug PRs" "$out" "rows on non-Bug PRs: 1"
has "coverage: uncovered" "$out" "fix-titled non-Bug PRs with no row: 1"
has "a row on a non-Bug PR is tagged" "$(rep --mirror "$FIX/mirror")" "non-Bug row: #27"
has "coverage: no mirror reads n/a" "$(rep)" "coverage: n/a"
has "coverage: an absent mirror reads n/a" "$(rep --mirror "$FIX/nope")" "coverage: n/a"
hasnt "no mirror: no caused-by flag" "$(rep)" "disagrees"

# --days narrows rows and denominators, against today's clock
python3 -I - "$FIX" <<'PY'
import datetime, json, os, sys
d = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)
def stamp(days):
    return (now - datetime.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
prs = [{"number": 1, "title": "fix: [HIMMEL-20] old", "body": "bug-origin: unknown unknown — old", "mergedAt": stamp(40), "headRefName": "a", "headRefOid": "a", "mergeCommit": None},
       {"number": 2, "title": "fix: [HIMMEL-21] new", "body": "bug-origin: unknown unknown — new", "mergedAt": stamp(2), "headRefName": "b", "headRefOid": "b", "mergeCommit": None},
       {"number": 3, "title": "fix: [HIMMEL-22] new, no row", "body": "", "mergedAt": stamp(2), "headRefName": "c", "headRefOid": "c", "mergeCommit": None}]
json.dump(prs, open(os.path.join(d, "recent.json"), "w"))
PY
out2="$(python3 "$REPORT" report --prs "$FIX/recent.json" --mirror "$FIX/mirror" --days 7 2>&1)"
eq "days: narrows the rows" "$(line_of 'rows: ' "$out2")" "rows: 1"
has "days: narrows the denominators" "$out2" "Bug-ticket PRs: 2"
out2="$(python3 "$REPORT" report --prs "$FIX/recent.json" --mirror "$FIX/mirror" 2>&1)"
eq "no days: every row" "$(line_of 'rows: ' "$out2")" "rows: 2"

# I5
rm -f "$HIMMEL_EVAL_RUNS_LEDGER"
cat > "$TMP/audit.py" <<'PY'
import os, runpy, sys
log, target = sys.argv[1], sys.argv[2]
sys.argv = sys.argv[2:]
BANNED = {"gh", "curl", "node"}
def named(v):
    return os.path.basename(str(v)) in BANNED
def hook(event, args):
    hit = event == "socket.connect"
    if event == "subprocess.Popen":
        hit = named(args[0]) or any(named(a) for a in (args[1] if isinstance(args[1], (list, tuple)) else [args[1]]))
    if hit:
        with open(log, "a") as fh:
            fh.write(event + "\n")
        raise RuntimeError("audit: " + event)
sys.addaudithook(hook)
runpy.run_path(target, run_name="__main__")
PY
cat > "$TMP/control.py" <<'PY'
import subprocess
try:
    subprocess.run(["gh", "--version"])
except Exception:
    pass
PY
sum_before="$(find "$FIX" -type f -exec cksum {} + | sort | cksum)"
out3="$(python3 "$TMP/audit.py" "$TMP/audit.log" "$REPORT" report --prs "$FIX/prs.json" --seed "$FIX/seed.jsonl" --cr-ledger "$FIX/cr.jsonl" --verdicts "$FIX/verdicts" --mirror "$FIX/mirror" --ledger "$FIX/never.jsonl" 2>&1)"
has "no write, no network: the report ran" "$out3" "rows: 10"
eq "no write, no network: no attempt logged" "$(cat "$TMP/audit.log" 2>/dev/null)" ""
eq "no write, no network: the fixture tree is unchanged" "$(find "$FIX" -type f -exec cksum {} + | sort | cksum)" "$sum_before"
eq "no write, no network: the runs ledger stays absent" "$([ -e "$HIMMEL_EVAL_RUNS_LEDGER" ] && echo present || echo absent)" "absent"
if printf '%s\n' "$out3" | grep -qE '\brate\b|\bCI\b'; then fail "no write, no network: no rate or CI text"; else pass "no write, no network: no rate or CI text"; fi
python3 "$TMP/audit.py" "$TMP/control.log" "$TMP/control.py" >/dev/null 2>&1
has "no write, no network: the control logs its attempt" "$(cat "$TMP/control.log" 2>/dev/null)" "subprocess.Popen"

# the refusals
rc=0; out3="$(rep --seed "$FIX/seed.jsonl")"; rc=$?
eq "seed inside the snapshot: exit 0" "$rc" "0"
printf '{"pr": 999, "origin": "#10", "class": "test-gap", "reason": "not in the snapshot"}\n' > "$TMP/seed-out.jsonl"
rc=0; out3="$(rep --seed "$TMP/seed-out.jsonl")" || rc=$?
eq "seed outside snapshot: exit non-zero" "$rc" "1"
has "seed outside snapshot: listed" "$out3" "seed PR outside snapshot: #999"
eq "seed outside snapshot: counted in no section" "$(line_of 'rows: ' "$out3")" "rows: 9"
printf '{"pr": 20, "origin": "unknown", "class": "test-gap", "reason": "x"}\n' > "$TMP/seed-bad.jsonl"
rc=0; out3="$(rep --seed "$TMP/seed-bad.jsonl")" || rc=$?
eq "a seed row off the grammar: exit 2" "$rc" "2"
python3 -I - "$FIX" "$TMP" <<'PY'
import json, os, sys
d, tmp = sys.argv[1:3]
prs = json.load(open(os.path.join(d, "prs.json")))
for field in ("headRefName", "body"):
    json.dump([{k: v for k, v in p.items() if k != field} for p in prs], open(os.path.join(tmp, "short-%s.json" % field), "w"))
PY
for field in headRefName body; do
    rc=0; out3="$(python3 "$REPORT" report --prs "$TMP/short-$field.json" 2>&1)" || rc=$?
    eq "refuses short snapshot: no $field, exit 2" "$rc" "2"
    has "refuses short snapshot: names $field" "$out3" "$field"
done

# --record
rc=0; out3="$(rep --seed "$FIX/seed.jsonl" --record --ledger "$TMP/runs.jsonl")" || rc=$?
eq "record row: exit 0" "$rc" "0"
eq "record row: the runs ledger env stays absent" "$([ -e "$HIMMEL_EVAL_RUNS_LEDGER" ] && echo present || echo absent)" "absent"
eq "record row: one row, valid, numeric, n is the row count" "$(python3 -I - "$HERE/../lib" "$TMP/runs.jsonl" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import eval_runs
rows = [json.loads(l) for l in open(sys.argv[2])]
r = rows[0]
print(len(rows), not eval_runs.validate(r), r["n"], r["eval"], r["ci"],
      all(isinstance(v, int) for v in r["metrics"].values()), r["metrics"]["class.test-gap"])
PY
)" "1 True 10 bug-origin {} True 4"

# null fields, a bad ledger line (the fixture ledger has one) and an empty window
python3 -I - "$TMP" <<'PY'
import json, os, sys
tmp = sys.argv[1]
null = [{"number": 1, "title": None, "body": None, "mergedAt": "2026-10-01T00:00:00Z", "headRefName": None, "headRefOid": None, "mergeCommit": None},
        {"number": 2, "title": None, "body": "bug-origin: #1 review-miss:cr — x", "mergedAt": "2026-10-02T00:00:00Z", "headRefName": None, "headRefOid": None, "mergeCommit": None},
        {"number": 3, "title": "open", "body": "bug-origin: #1 test-gap — unmerged", "mergedAt": None, "headRefName": "o", "headRefOid": "o", "mergeCommit": None}]
json.dump(null, open(os.path.join(tmp, "null.json"), "w"))
json.dump([], open(os.path.join(tmp, "empty.json"), "w"))
PY
rc=0; out3="$(python3 "$REPORT" report --prs "$TMP/null.json" --cr-ledger "$FIX/cr.jsonl" --verdicts "$FIX/verdicts" --mirror "$FIX/mirror" 2>&1)" || rc=$?
eq "null fields and a bad ledger line: exit 0" "$rc" "0"
has "null fields and a bad ledger line: the row counts, the unmerged PR does not" "$out3" "rows: 1"
hasnt "null fields and a bad ledger line: no traceback" "$out3" "Traceback"
rc=0; out3="$(python3 "$REPORT" report --prs "$TMP/empty.json" --mirror "$FIX/mirror" 2>&1)" || rc=$?
eq "empty window: exit 0" "$rc" "0"
has "empty window: zero rows" "$out3" "rows: 0"
hasnt "empty window: no traceback" "$out3" "Traceback"

# --- trace, on a throwaway repo
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
R="$TMP/trace-repo"
mkdir -p "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@t "$@"; }
commit() { g add -A && g commit -q -m "$1" && g rev-parse HEAD; }
edit_line() { awk -v k="$2" -v t="$3" 'NR==k{print t;next}{print}' "$R/$1" > "$R/$1.new" && mv "$R/$1.new" "$R/$1"; }
insert_at() { awk -v k="$2" -v t="$3" 'NR==k{print t}{print}' "$R/$1" > "$R/$1.new" && mv "$R/$1.new" "$R/$1"; }
tr_() { (cd "$R" && python3 "$REPORT" trace "$@" 2>&1); }
s12() { printf '%s' "$1" | cut -c1-12; }
g init -q -b main
seq 1 12 | sed 's/^/script line /' > "$R/script.sh"
c1="$(commit 'feat: the script (#1)')"
edit_line script.sh 5 'script line five'
c2="$(commit 'fix: line five (#2)')"
seq 1 6 | sed 's/^/test line /' > "$R/test-a.sh"
ct="$(commit 'test: the suite (#4)')"
g branch fork
edit_line script.sh 10 'script line ten'
c3="$(commit 'fix: main moved on (#3)')"

g checkout -q -b moved fork
edit_line script.sh 5 'script line five again'
commit 'fix: on the branch' >/dev/null
out="$(tr_ --base main --head moved)"
has "main moved: blames the branch's line" "$out" "$(s12 "$c2") "
hasnt "main moved: not main's later commit" "$out" "$(s12 "$c3")"
has "main moved: the count" "$out" "lines=1"
has "main moved: the PR of the subject" "$out" "PR #2"
hasnt "main moved: a changed line is not adjacent" "$out" "adjacent"

g checkout -q -b addonly fork
insert_at script.sh 5 'a new line'
commit 'fix: add a line' >/dev/null
out="$(tr_ --base fork --head addonly)"
has "add-only reads adjacent: the line before" "$(line_of "$(s12 "$c1")" "$out")" "adjacent"
has "add-only reads adjacent: the line after" "$(line_of "$(s12 "$c2")" "$out")" "adjacent"

g checkout -q -b both fork
edit_line script.sh 1 'script line one'
edit_line test-a.sh 1 'test line one'
commit 'fix: both' >/dev/null
out="$(tr_ --base fork --head both)"
has "tests left out unless alone: the script" "$out" "$(s12 "$c1") "
hasnt "tests left out unless alone: not the test" "$out" "$(s12 "$ct")"
g checkout -q -b onlytest fork
edit_line test-a.sh 1 'test line one'
commit 'test: only' >/dev/null
has "tests left out unless alone: alone, the test" "$(tr_ --base fork --head onlytest)" "$(s12 "$ct") "

g checkout -q -b newfile fork
printf 'new\n' > "$R/brand-new.sh"
commit 'feat: new' >/dev/null
out="$(tr_ --base fork --head newfile)"
has "new, renamed, top of file: new at head has no candidate" "$out" "no candidate"
hasnt "new, renamed, top of file: new at head, no traceback" "$out" "Traceback"
g checkout -q -b renamed fork
g mv script.sh tool.sh
edit_line tool.sh 5 'script line five renamed'
commit 'fix: rename' >/dev/null
out="$(tr_ --base fork --head renamed)"
has "new, renamed, top of file: a rename blames the old path" "$out" "$(s12 "$c2") "
hasnt "new, renamed, top of file: a rename, no traceback" "$out" "Traceback"
g checkout -q -b top fork
insert_at script.sh 1 'a first line'
commit 'fix: top' >/dev/null
has "new, renamed, top of file: add-only at line 1 is adjacent" "$(line_of "$(s12 "$c1")" "$(tr_ --base fork --head top)")" "adjacent"
rc=0; out="$(tr_ --base no-such-ref --head top)" || rc=$?
eq "a bad ref: exit 2" "$rc" "2"
hasnt "a bad ref: no traceback" "$out" "Traceback"

# a failed git read refuses; it never reads as a diff that changes nothing
SHIM="$TMP/shim"
mkdir -p "$SHIM"
# shellcheck disable=SC2016  # the shim's own "$@" and "$a" expand when it runs
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "$FAIL_ON" ] && exit 1; done\nexec "%s" "$@"\n' "$(command -v git)" > "$SHIM/git"
chmod +x "$SHIM/git"
rc=0; out="$(cd "$R" && FAIL_ON=no-such-arg PATH="$SHIM:$PATH" python3 "$REPORT" trace --base fork --head top 2>&1)" || rc=$?
eq "failed git control: exit 0" "$rc" "0"
has "failed git control: a candidate" "$out" "$(s12 "$c1")"
for step in --name-status -U0 blame; do
    rc=0; out="$(cd "$R" && FAIL_ON="$step" PATH="$SHIM:$PATH" python3 "$REPORT" trace --base fork --head top 2>&1)" || rc=$?
    eq "failed git $step: exit 2" "$rc" "2"
    has "failed git $step: refused" "$out" "refused"
    hasnt "failed git $step: no false claim" "$out" "no candidate"
done

# evidence
GCD="$(g rev-parse --path-format=absolute --git-common-dir)"
printf '[{"number":2,"mergedAt":"2026-10-10T00:00:00Z","headRefName":"b2","headRefOid":"h2","mergeCommit":{"oid":"%s"}}]\n' "$c2" > "$TMP/bodyless.json"
rm -f "$GCD/cr-critic-scores.jsonl"
out="$(tr_ --base main --head moved)"
has "no prs reads not read" "$out" "cr=not read; panel=not read; judge=not read"
out="$(tr_ --base main --head moved --prs "$TMP/bodyless.json")"
has "body-less snapshot: the PR from the snapshot" "$out" "PR #2"
has "default ledger: a missing file reads not read" "$out" "panel=not read"
printf '{"kind":"avail","ts":"2026-10-09T00:00:00Z","branch":"b2","head":"h2","model":"codex","status":"ok","artifact":"diff","perspective":"off"}\n' > "$GCD/cr-critic-scores.jsonl"
out="$(tr_ --base main --head moved --prs "$TMP/bodyless.json")"
has "default ledger: read from the git common dir" "$out" "panel=on record: codex"
has "default ledger: judge still needs its tree" "$out" "judge=not read"
has "no prs reads not read, ledger or no ledger" "$(tr_ --base main --head moved)" "panel=not read"
python3 -I - "$TMP" <<'PY'
import json, os, sys
json.dump([{"number": 2, "mergedAt": "2026-10-10T00:00:00Z"}], open(os.path.join(sys.argv[1], "tooshort.json"), "w"))
PY
rc=0; out="$(tr_ --base main --head moved --prs "$TMP/tooshort.json")" || rc=$?
eq "a snapshot too short for trace: exit 2" "$rc" "2"

# --- the seed file, on the real rows
rm -f "$TMP/seed.out"
python3 -I - "$REPORT" "$HERE/seed.jsonl" > "$TMP/seed.out" 2>&1 <<'PY'
import importlib.util, json, sys
path, seed = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("bug_origin_report", path)
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
def eq(name, got, want):
    print(("PASS " + name) if got == want else "FAIL %s: expected %r, got %r" % (name, want, got))
FROZEN = [4502, 4503, 4459, 4460, 4458, 4450, 4436, 4325, 4432, 4428, 4402, 4411, 4403, 4407, 4406, 4380, 4364, 4343, 4358, 4357]
rows = [json.loads(l) for l in open(seed, encoding="utf-8") if l.strip()]
eq("seed validator: the frozen 20 PRs", sorted(x["pr"] for x in rows), sorted(FROZEN))
for x in rows:
    state, got = r.parse_body("bug-origin: %s %s — %s" % (x["origin"], x["class"], x["reason"]))
    eq("seed validator: #%d re-rendered parses" % x["pr"], state, "ok")
    eq("seed validator: #%d has a reason" % x["pr"], bool(x["reason"].strip()), True)
    eq("seed validator: #%d does not name itself" % x["pr"], x["origin"] == "#%d" % x["pr"], False)
eq("seed validator: at most 6 unknown", sum(x["class"] == "unknown" for x in rows) <= 6, True)
PY
seed_rc=$?
cat "$TMP/seed.out"
PASS=$((PASS + $(grep -c '^PASS ' "$TMP/seed.out")))
FAIL=$((FAIL + $(grep -c '^FAIL ' "$TMP/seed.out")))
eq "seed validator: ran to its end" "$seed_rc" "0"

# --- the Luna ledger, the further classes and the class filter. Every path below is under $TMP;
# the real bucket, the real index, the real registry and Jira are never touched (the fake jira only logs).
mkdir -p "$TMP/nojira-bin"
printf '#!/bin/sh\necho called >> "%s/jira-called"\nexit 0\n' "$TMP" > "$TMP/nojira-bin/node"
chmod +x "$TMP/nojira-bin/node"
FAKEJIRA="$TMP/fakejira.sh"
# shellcheck disable=SC2016  # the fake script expands its own variables
printf '#!/bin/sh\necho "$1 $2" >> "$FAKE_JIRA_LOG"\ncat "$4" >> "$FAKE_JIRA_LOG"\n[ -z "${FAKE_JIRA_FAIL:-}" ] || exit 1\nexit 0\n' > "$FAKEJIRA"
chmod +x "$FAKEJIRA"
LED="$TMP/ledger-root"
ing() { PATH="$TMP/nojira-bin:$PATH" python3 "$REPORT" ingest --prs "$FIX/prs.json" --ledger-dir "$@" 2>&1; }
# the ledger's resolution: configured root, user and bucket from the registry, never a literal project name
rm -f "$TMP/res.out"
python3 -I - "$REPORT" "$TMP" > "$TMP/res.out" 2>&1 <<'PY'
import importlib.util, json, os, subprocess, sys
path, tmp = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("bug_origin_report", path)
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
def eq(name, got, want):
    print(("PASS " + name) if got == want else "FAIL %s: expected %r, got %r" % (name, want, got))
root = os.path.join(tmp, "hroot"); os.makedirs(root)
repo = os.path.join(tmp, "my-project"); os.makedirs(repo)
subprocess.run(["git", "-C", repo, "init", "-q", "-b", "main"], check=True)
reg = os.path.join(tmp, "registry.json")
json.dump({"repos": {"mine": {"path": repo, "bucket_name": "mybucket", "user": "ann"}}}, open(reg, "w"))
env = {"HANDOVER_DIR": root, "USER_SLUG": "zed", "HANDOVER_REGISTRY": reg}
eq("resolve: root, registry user and bucket", r.judge_accuracy.ledger_dir(repo, env), os.path.join(root, "ann", "mybucket", "bug-origin"))
json.dump({"repos": {}}, open(reg, "w"))
eq("resolve: no registry entry falls back to USER_SLUG and the project's own name", r.judge_accuracy.ledger_dir(repo, env), os.path.join(root, "zed", "my-project", "bug-origin"))
eq("resolve: no HANDOVER_DIR is no ledger", r.judge_accuracy.ledger_dir(repo, {"USER_SLUG": "zed"}), None)
eq("resolve: a HANDOVER_DIR that is no directory is no ledger", r.judge_accuracy.ledger_dir(repo, {"HANDOVER_DIR": os.path.join(tmp, "nope")}), None)
PY
cat "$TMP/res.out"
PASS=$((PASS + $(grep -c '^PASS ' "$TMP/res.out")))
FAIL=$((FAIL + $(grep -c '^FAIL ' "$TMP/res.out")))
eq "resolve: ran to its end" "$(grep -c '^PASS resolve' "$TMP/res.out")" "4"

# R1: a row is written and read with no Jira call
rc=0; out="$(ing "$LED" --seed "$FIX/seed.jsonl")" || rc=$?
eq "ingest: exit 0" "$rc" "0"
has "ingest: ten rows written" "$out" "ingest: wrote 10"
count_files() { local n=0 f; for f in "$@"; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
eq "ingest: one file per row" "$(count_files "$LED"/*.md)" "10"
row20="$(cat "$LED/20.md")"
has "row: front matter class" "$row20" 'class: "review-miss:cr"'
has "row: front matter bug key" "$row20" 'bug_key: "HIMMEL-20"'
has "row: front matter source" "$row20" 'source: "body"'
has "row: starts unsynced" "$row20" 'synced: false'
has "row: one plain body line a search finds without the front matter" "$row20" 'PR #20 (HIMMEL-20) bug-origin: #10 review-miss:cr — dropped exit code'
has "row: the seed row is marked seed" "$(cat "$LED/24.md")" 'source: "seed"'
has "row: the body wins over the seed" "$(cat "$LED/23.md")" 'class: "design-gap"'
eq "ingest: no temp file is left behind" "$(count_files "$LED"/*tmp* "$LED"/.*tmp*)" "0"
eq "ingest: the Jira stand-in was never called" "$([ -e "$TMP/jira-called" ] && echo called || echo never)" "never"
sum1="$(cat "$LED"/*.md | cksum)"
out="$(ing "$LED" --seed "$FIX/seed.jsonl")"
has "ingest: a second run writes nothing" "$out" "ingest: wrote 0"
eq "ingest: a second run changes no file" "$(cat "$LED"/*.md | cksum)" "$sum1"
# a PR snapshot with no bodies: the rows come from the ledger alone, and the Jira mirror is unreachable
python3 -I - "$FIX/prs.json" "$FIX/prs-nobody.json" <<'PY'
import json, sys
prs = json.load(open(sys.argv[1]))
for p in prs:
    p["body"] = ""
json.dump(prs, open(sys.argv[2], "w"))
PY
rc=0; out="$(PATH="$TMP/nojira-bin:$PATH" python3 "$REPORT" report --prs "$FIX/prs-nobody.json" --ledger-dir "$LED" --mirror "$TMP/no-such-mirror" 2>&1)" || rc=$?
eq "ledger only, Jira unreachable: exit 0" "$rc" "0"
eq "ledger only, Jira unreachable: the rows" "$(line_of 'rows: ' "$out")" "rows: 10"
has "ledger only, Jira unreachable: class counts" "$out" "review-miss:cr: 2"
has "ledger only, Jira unreachable: test-gap" "$out" "test-gap: 4"
eq "ledger only: the Jira stand-in was never called" "$([ -e "$TMP/jira-called" ] && echo called || echo never)" "never"
out="$(python3 "$REPORT" report --prs "$FIX/prs-nobody.json" 2>&1)"
eq "no ledger dir and no bodies: no rows" "$(line_of 'rows: ' "$out")" "rows: 0"
# the ledger is read first: a row that disagrees with the body wins
mkdir -p "$TMP/led-first"
sed 's/review-miss:cr/test-gap/g' "$LED/20.md" > "$TMP/led-first/20.md"
out="$(python3 "$REPORT" report --prs "$FIX/prs.json" --ledger-dir "$TMP/led-first" 2>&1)"
has "ledger first: the row's class counts with the three body test-gaps" "$out" "test-gap: 4"
has "ledger first: the body of another PR still counts" "$out" "review-miss:cr: 1"
hasnt "ledger first: #20 is no review-miss row" "$out" "fix #20 "

# R1: the Jira sync
sy() { JIRA_PROJECT_KEY=HIMMEL FAKE_JIRA_LOG="$2" python3 "$REPORT" sync --ledger-dir "$1" --jira-cmd "$FAKEJIRA" 2>&1; }
rc=0; out="$(sy "$LED" "$TMP/jira1.log")" || rc=$?
eq "sync configured: exit 0" "$rc" "0"
has "sync configured: ten rows updated" "$out" "jira sync: 10 updated"
eq "sync configured: a comment per key" "$(grep -c '^comment HIMMEL-' "$TMP/jira1.log")" "10"
has "sync configured: the comment carries the line" "$(cat "$TMP/jira1.log")" "bug-origin: #10 review-miss:cr — dropped exit code"
has "sync configured: the row is marked synced" "$(cat "$LED/20.md")" "synced: true"
rc=0; out="$(sy "$LED" "$TMP/jira1.log")" || rc=$?
has "sync re-run: nothing to update" "$out" "jira sync: 0 updated"
eq "sync re-run: no second comment" "$(grep -c '^comment HIMMEL-' "$TMP/jira1.log")" "10"
# a Jira error warns, leaves the row unsynced, and the next sync retries it
ing "$TMP/led-fail" >/dev/null
rc=0; out="$(JIRA_PROJECT_KEY=HIMMEL FAKE_JIRA_FAIL=1 FAKE_JIRA_LOG="$TMP/jira2.log" python3 "$REPORT" sync --ledger-dir "$TMP/led-fail" --jira-cmd "$FAKEJIRA" 2>&1)" || rc=$?
eq "sync Jira error: exit 0" "$rc" "0"
has "sync Jira error: warns" "$out" "warn: jira comment on HIMMEL-20 failed"
has "sync Jira error: the row stays unsynced" "$(cat "$TMP/led-fail/20.md")" "synced: false"
out="$(sy "$TMP/led-fail" "$TMP/jira2.log")"
has "sync retry: the next run updates it" "$out" "jira sync: 9 updated"
has "sync retry: the row is now synced" "$(cat "$TMP/led-fail/20.md")" "synced: true"
eq "sync retry: HIMMEL-20 was tried twice, once failed and once sent" "$(grep -c '^comment HIMMEL-20' "$TMP/jira2.log")" "2"
# no Jira configured: skipped with no error, the rows untouched
ing "$TMP/led-nojira" >/dev/null
rc=0; out="$(env -u JIRA_PROJECT_KEY FAKE_JIRA_LOG="$TMP/jira3.log" python3 "$REPORT" sync --ledger-dir "$TMP/led-nojira" --jira-cmd "$FAKEJIRA" 2>&1)" || rc=$?
eq "sync not configured: exit 0" "$rc" "0"
has "sync not configured: says skipped" "$out" "jira sync skipped: not configured"
eq "sync not configured: nothing sent" "$([ -e "$TMP/jira3.log" ] && echo sent || echo none)" "none"
has "sync not configured: the row stays unsynced" "$(cat "$TMP/led-nojira/20.md")" "synced: false"

# R3: the further classes parse, are counted in the report and are written to the ledger
python3 -I - "$FIX/prs.json" "$FIX/prs-r3.json" <<'PY'
import json, sys
prs = json.load(open(sys.argv[1]))
base = [p for p in prs if p["number"] == 10]
def pr(n, body):
    return {"number": n, "title": "fix(a): [HIMMEL-%d] x" % n, "body": body, "mergedAt": "2026-10-%02dT12:00:00Z" % (n - 30),
            "headRefName": "b%d" % n, "headRefOid": "%040x" % n, "mergeCommit": {"oid": "%040x" % (n + 1000)}}
bodies = ["#10 review-deferred — the finding was deferred", "#10 residual:HIMMEL-8802 — a partly done finding",
          "#10 trigger:cron — only the weekly run shows it", "#10 commit:abcdef1 — the commit is the origin",
          "#10 review-miss:cr,judge — two layers saw it", "#10 review-miss:panel — one layer saw it"]
json.dump(base + [pr(50 + i, "bug-origin: " + b) for i, b in enumerate(bodies)], open(sys.argv[2], "w"))
PY
rep3() { python3 "$REPORT" report --prs "$FIX/prs-r3.json" "$@" 2>&1; }
out="$(rep3 --record --ledger "$TMP/r3-runs.jsonl")"
eq "R3: six rows" "$(line_of 'rows: ' "$out")" "rows: 6"
has "R3: review-deferred counted" "$out" "review-deferred: 1"
has "R3: residual counted" "$out" "residual: 1"
has "R3: trigger counted" "$out" "trigger: 1"
has "R3: commit counted" "$out" "commit: 1"
has "R3: a one-layer review-miss counts under its layer" "$out" "review-miss:panel: 1"
has "R3: a many-layer review-miss counts apart" "$out" "review-miss:multi: 1"
has "R3: the review-miss subtotal counts both" "$out" "review-miss: 2"
has "R3: the many-layer row names its claimed layers" "$(line_of 'fix #54 ' "$out")" "claimed cr,judge"
eq "R3: the eval-runs row carries the class count" "$(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["metrics"]["class.residual"])' "$TMP/r3-runs.jsonl")" "1"
ing "$TMP/led-r3" >/dev/null
rc=0; out="$(PATH="$TMP/nojira-bin:$PATH" python3 "$REPORT" ingest --prs "$FIX/prs-r3.json" --ledger-dir "$TMP/led-r3" 2>&1)" || rc=$?
has "R3: ingest writes the six" "$out" "ingest: wrote 6"
has "R3: a payload class is kept whole in the row" "$(cat "$TMP/led-r3/51.md")" 'class: "residual:HIMMEL-8802"'

# R4: the class filter in the report, on a family and on an exact class
out="$(rep --seed "$FIX/seed.jsonl" --class test-gap)"
eq "filter test-gap: rows" "$(line_of 'rows: ' "$out")" "rows: 4"
has "filter test-gap: counts the class" "$out" "test-gap: 4"
has "filter test-gap: another class is excluded" "$out" "design-gap: 0"
has "filter test-gap: review-miss is excluded" "$out" "review-miss: 0"
out="$(rep --seed "$FIX/seed.jsonl" --class review-miss)"
eq "filter family review-miss: rows" "$(line_of 'rows: ' "$out")" "rows: 4"
out="$(rep3 --class residual:HIMMEL-8802)"
eq "filter exact payload class: rows" "$(line_of 'rows: ' "$out")" "rows: 1"
out="$(rep3 --class residual:nope)"
eq "negative control: a class with no rows returns none, not all" "$(line_of 'rows: ' "$out")" "rows: 0"
out="$(rep3 --class bogus)"
eq "negative control: an unknown class returns none, not all" "$(line_of 'rows: ' "$out")" "rows: 0"

# R4: the class filter in escapes.signals, by a fix PR's class and by a bug's key
mkdir -p "$TMP/esc/mirror" "$TMP/led-esc"
python3 -I - "$TMP/esc" <<'PY'
import json, os, sys
d = sys.argv[1]
def pr(n, title, day):
    return {"number": n, "title": title, "body": "", "mergedAt": "2026-10-%02dT12:00:00Z" % day,
            "headRefName": "b%d" % n, "headRefOid": "%040x" % n, "mergeCommit": {"oid": "%040x" % (n + 1000)}}
json.dump([pr(1, "feat(a): [K-1] target one", 1), pr(2, "fix(a): [K-2] later fix (#1)", 2),
           pr(3, "feat(a): [K-3] target two", 1), pr(4, 'Revert "target two" (#3)', 3)], open(os.path.join(d, "prs.json"), "w"))
open(os.path.join(d, "mirror", "HIMMEL-9.md"), "w").write('---\ntype: "Bug"\nlabels: []\ncreated: "2026-10-20T09:00:00.000+0200"\n---\ncaused-by: #1\n')
open(os.path.join(d, "cr.jsonl"), "w").close()
PY
lrow() { printf -- '---\npr: %s\nbug_key: "%s"\norigin: "#1"\nclass: "%s"\nreason: "x"\nsource: "body"\ningested: "2026-11-02T00:00:00Z"\nsynced: false\n---\nPR #%s bug-origin: #1 %s — x\n' "$1" "$2" "$3" "$1" "$3" > "$TMP/led-esc/$1.md"; }
lrow 2 K-2 test-gap
lrow 4 K-4 design-gap
lrow 90 HIMMEL-9 design-gap
esc() { python3 "$HERE/../escapes.py" --prs "$TMP/esc/prs.json" --mirror "$TMP/esc/mirror" --cr-ledger "$TMP/esc/cr.jsonl" "$@" 2>&1 \
  | python3 -I -c 'import json,sys; m=json.load(sys.stdin)["metrics"]; print(m["escapes"], m["escapes_plausible"])'; }
eq "escapes unfiltered: sure and plausible" "$(esc)" "2 2"
eq "escapes class test-gap: only the test-gap fix's escape, plausible" "$(esc --bug-origin-dir "$TMP/led-esc" --class test-gap)" "0 1"
eq "escapes class design-gap: the revert and the bug" "$(esc --bug-origin-dir "$TMP/led-esc" --class design-gap)" "2 2"
eq "negative control: escapes class with no rows counts none" "$(esc --bug-origin-dir "$TMP/led-esc" --class residual)" "0 0"
rc=0; python3 "$HERE/../escapes.py" --prs "$TMP/esc/prs.json" --mirror "$TMP/esc/mirror" --cr-ledger "$TMP/esc/cr.jsonl" --class test-gap >/dev/null 2>&1 || rc=$?
eq "escapes class with no ledger to read is refused" "$rc" "2"
eq "escapes.signals takes the filter directly" "$(python3 -I - "$HERE/.." <<'PY'
import importlib.util, json, sys
sys.path[:0] = [sys.argv[1] + "/lib", sys.argv[1] + "/cr-ledger", sys.argv[1] + "/judge-accuracy", sys.argv[1]]
import escapes
prs = [{"number": 1, "title": "x", "mergedAt": "2026-10-01T00:00:00Z"},
       {"number": 2, "title": "fix(a): later (#1)", "mergedAt": "2026-10-02T00:00:00Z"}]
classes = {"pr": {2: "test-gap"}, "key": {}}
print(sorted(escapes.signals(prs, [], "test-gap", classes)[1]), sorted(escapes.signals(prs, [], "design-gap", classes)[1]))
PY
)" "[1] []"

# --- the template's Ship step
TEMPLATE="$(cat "$HERE/../../../docs/handover/worker-brief-template.md")"
has "template names the line" "$TEMPLATE" 'bug-origin: <#pr|sha|unknown> <class> — <reason>'
has "template names the snapshot command" "$TEMPLATE" 'gh pr list --state merged --limit 10000 --json number,mergedAt,headRefName,headRefOid,mergeCommit'
has "template names the trace command" "$TEMPLATE" 'bug-origin-report.py trace --base origin/main --head HEAD --prs'

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; else echo "$FAIL FAILED"; exit 1; fi
