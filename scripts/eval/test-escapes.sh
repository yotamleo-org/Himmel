#!/usr/bin/env bash
# scripts/eval/test-escapes.sh - suite for escapes.py: bugs found after merge (a revert, a caused-by bug,
# a fix PR naming an earlier PR) counted per merged PR, then per critic that reviewed it and per judge
# that passed it, and the eval-runs row it records. Fixtures only: no model, no network, never the
# live ledgers.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
EVAL="$HERE/escapes.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/escapes-test.XXXXXX")" || { echo "test-escapes: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never-runs.jsonl"
export CR_LEDGER="$TMP/never-cr.jsonl"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-escapes: python3 not on PATH"; exit 0; }

# PR 10 is reverted by PR 11; PR 20 is named by a later fix PR 21; PR 30 is the caused-by of a Bug;
# PR 40 is clean (a revert cites it only as context); PR 70 is reverted by a PR naming its merge commit.
# codex reviewed 10, 20 and 40; CodeRabbit reviewed 20; one judge passed 10 at its merged head, another
# passed 20 at a head that was not merged and 30 after it merged.
python3 -I - "$TMP" <<'PY' || { echo "test-escapes: writing the fixtures failed" >&2; exit 1; }
import json, os, sys
d = sys.argv[1]
def pr(n, title, body="", day=10):
    return {"number": n, "title": title, "body": body, "state": "MERGED", "mergedAt": "2026-10-%02dT12:00:00Z" % day,
            "headRefName": "b%d" % n, "headRefOid": "%040x" % n, "mergeCommit": {"oid": "%040x" % (n + 1000)}}
prs = [pr(10, "feat(x): [HIMMEL-1] add x", day=10),
       pr(11, 'Revert "feat(x): [HIMMEL-1] add x"', "Reverts #10, it broke main.", day=11),
       pr(20, "feat(y): [HIMMEL-2] add y", day=12),
       pr(21, "fix(y): [HIMMEL-3] y handles an empty file", "Follow-up to #20.", day=13),
       pr(30, "feat(z): [HIMMEL-4] add z", day=14),
       pr(40, "feat(w): [HIMMEL-5] add w; see #999 and #50", day=15),
       pr(50, "fix(v): [HIMMEL-6] v", "Names #60, which merged after it.", day=16),
       pr(60, "feat(v): [HIMMEL-7] v", day=17),
       pr(70, "feat(u): [HIMMEL-8] u", day=18),
       pr(71, "revert(u): [HIMMEL-9] withdraw u", "This reverts commit `%040x`; #40 and `%040x` are only context." % (70 + 1000, 40 + 1000), day=19)]
json.dump(prs, open(os.path.join(d, "prs.json"), "w"))
def avail(br, model, rm=None, status="ok", ts="2026-10-10T00:00:00Z"):
    r = {"kind": "avail", "ts": ts, "branch": br, "head": "h", "model": model, "status": status,
         "artifact": "diff", "perspective": "off"}
    if rm:
        r["responding_model"] = rm
    return r
cr = [avail("b10", "codex", "gpt-6.1-sol"), avail("b20", "codex", "gpt-6.1-sol"), avail("b40", "codex", "gpt-6.1-sol"),
      avail("b20", "coderabbit"), avail("b30", "claude", status="unavailable"), avail("b10", "judge"),
      avail("b10", "coderabbit", ts="2026-10-12T00:00:00Z")]
with open(os.path.join(d, "cr.jsonl"), "w") as fh:
    for r in cr:
        fh.write(json.dumps(r) + "\n")
os.makedirs(os.path.join(d, "mirror"))
with open(os.path.join(d, "mirror", "HIMMEL-90.md"), "w") as fh:
    fh.write('---\nkey: "HIMMEL-90"\ntype: "Bug"\nlabels: ["main-red"]\ncreated: "2026-10-20T00:00:00.000+0200"\n---\n\n'
             '# HIMMEL-90\n\nmain went red.\ncaused-by: #30\n')
with open(os.path.join(d, "mirror", "HIMMEL-91.md"), "w") as fh:
    fh.write('---\nkey: "HIMMEL-91"\ntype: "Bug"\nlabels: []\ncreated: "2026-10-01T00:00:00.000+0200"\n---\n\n'
             '# HIMMEL-91\n\nfiled before #40 merged.\ncaused-by: #40\n')
os.makedirs(os.path.join(d, "verdicts", "j1"))
os.makedirs(os.path.join(d, "verdicts", "j2"))
with open(os.path.join(d, "verdicts", "j2", "stale.md"), "w") as fh:
    fh.write("pr: 20\nmodel: opus\nwritten-at: 2026-10-12T11:00:00Z\n\n**GO** for head `%040x`\n" % 999)
with open(os.path.join(d, "verdicts", "j2", "late.md"), "w") as fh:
    fh.write("pr: 30\nmodel: opus\nwritten-at: 2026-10-14T13:00:00Z\n\n**GO** for head `%040x`\n" % 30)
with open(os.path.join(d, "verdicts", "j1", "judge.md"), "w") as fh:
    fh.write("pr: 10\nmodel: opus\neffort: high\nwritten-at: 2026-10-10T11:00:00Z\n\n**GO** for head `%040x`\n" % 10)
with open(os.path.join(d, "verdicts", "j1", "console.md"), "w") as fh:
    fh.write("pr: 40\nmodel: opus\nwritten-at: 2026-10-15T11:00:00Z\n\n**GO** for head `%040x`\n" % 40)
PY

run() { python3 -I "$EVAL" --prs "$TMP/prs.json" --cr-ledger "$TMP/cr.jsonl" --mirror "$TMP/mirror" --verdicts "$TMP/verdicts" "$@"; }
out="$(run 2>"$TMP/err")"; rc=$?
eq "run: exit 0" "$rc" "0"
pick() { printf '%s' "$out" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["metrics"].get(sys.argv[1]))' "$1"; }
eq "every merged PR is in the sample" "$(pick merged)" "10"
eq "a revert PR naming #n counts one escape against #n's reviewers" "$(pick critic.codex:gpt-6.1-sol.escapes)" "1"
eq "sure escapes: the two reverted PRs and the caused-by PR" "$(pick escapes)" "3"
eq "plausible escapes add the PR a later fix names" "$(pick escapes_plausible)" "4"
eq "a fix naming a PR that merged after it is no escape" "$(pick signal.fix-forward)" "1"
eq "a revert naming the merge commit counts" "$(pick signal.revert)" "2"
eq "a caused-by bug is one signal, a bug filed before the merge none" "$(pick signal.caused-by)" "1"
eq "per critic: PRs it reviewed" "$(pick critic.codex:gpt-6.1-sol.prs)" "3"
eq "per critic: a fix-forward is plausible, not sure" "$(pick critic.coderabbit.escapes)" "0"
eq "per critic: a review after the merge is not credited" "$(pick critic.coderabbit.prs)" "1"
eq "per critic: CodeRabbit's plausible escape" "$(pick critic.coderabbit.escapes_plausible)" "1"
eq "an unavailable critic did not review the PR" "$(pick critic.claude.prs)" "None"
eq "per judge: the judge that passed the reverted PR" "$(pick judge.claude-opus-5-5.escapes)" "1"
eq "per judge: a console GO, a GO at an unmerged head and a GO after the merge are not counted" "$(pick judge.claude-opus-5-5.prs)" "1"
eq "a critic slug named judge stays a critic" "$(pick critic.judge.prs)" "1"
eq "a critic slug named judge is no judge model" "$(pick judge.prs)" "None"
eq "the row is the escapes series" "$(printf '%s' "$out" | python3 -I -c 'import json, sys; r = json.load(sys.stdin); print(r["eval"], r["status"])')" "escapes ok"

run --record --ledger "$TMP/runs.jsonl" >/dev/null 2>&1; rc=$?
eq "--record: exit 0" "$rc" "0"
eq "--record appends one ok escapes row" "$(grep -c '"eval":"escapes","status":"ok"' "$TMP/runs.jsonl" 2>/dev/null)" "1"
eq "--record writes a valid eval-runs row" "$(python3 -I "$HERE/lib/eval_runs.py" validate "$TMP/runs.jsonl" 2>&1 | tail -n 1)" "eval-runs validate: OK"

python3 -I "$EVAL" --prs "$TMP/prs.json" --cr-ledger "$TMP/cr.jsonl" --mirror "$TMP/mirror" >"$TMP/nov.json" 2>/dev/null; rc=$?
eq "no --verdicts: exit 0" "$rc" "0"
eq "no --verdicts: no judge numbers" "$(python3 -I -c 'import json, sys; print(sum(k.startswith("judge.") for k in json.load(open(sys.argv[1]))["metrics"]))' "$TMP/nov.json")" "0"
python3 -I "$EVAL" --prs "$TMP/no-prs.json" --cr-ledger "$TMP/cr.jsonl" --mirror "$TMP/mirror" >/dev/null 2>&1; rc=$?
eq "a missing PR snapshot is refused" "$rc" "2"

out="$(run --until 2026-10-18T23:59:59Z 2>/dev/null)"
eq "--until: a PR merged after the cut is out of the sample" "$(pick merged)" "9"
eq "--until: a revert merged after the cut is no signal" "$(pick signal.revert)" "1"
eq "--until: a bug created after the cut is no signal" "$(pick signal.caused-by)" "0"
case "$(python3 -I "$EVAL" --help 2>&1)" in *"Exit 0 done"*) pass "--help prints the whole usage text";; *) fail "--help prints the whole usage text";; esac

echo "test-escapes: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
