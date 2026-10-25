#!/usr/bin/env bash
# scripts/eval/test-deferred-outcome.sh - suite for deferred-outcome.py: CR-ledger findings left deferred
# to a follow-up ticket, joined to that ticket's state in a fixture Jira mirror (fixed later, still open,
# disproved), overall and per critic, and the eval-runs row it records. Fixtures only: no model, no
# network, never the live ledgers.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
EVAL="$HERE/deferred-outcome.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/deferred-outcome-test.XXXXXX")" || { echo "test-deferred-outcome: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never-runs.jsonl"
export CR_LEDGER="$TMP/never-cr.jsonl"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-deferred-outcome: python3 not on PATH"; exit 0; }

# Six findings: deferred to a Done ticket (by amend), to an open ticket (on the finding row), to a
# Won't Do ticket, to a ticket the mirror lacks, deferred with no ticket, and deferred then fixed.
python3 -I - "$TMP/cr.jsonl" "$TMP/mirror" <<'PY' || { echo "test-deferred-outcome: writing the fixtures failed" >&2; exit 1; }
import json, os, sys
def fin(fid, br, model, **kw):
    return dict({"kind": "finding", "ts": "2026-10-10T00:00:00Z", "branch": br, "head": "h-" + br, "model": model,
                 "finding_id": fid, "severity": "sug", "file": "a.sh", "line": 1, "verdict": "",
                 "artifact": "diff", "perspective": "off", "text": fid}, **kw)
def amend(fid, br, ts="2026-10-11T00:00:00Z", **st):
    return {"kind": "amend", "ts": ts, "branch": br, "target_head": "h-" + br, "finding_id": fid,
            "artifact": "diff", "perspective": "off", "set": st, "reason": "r"}
rows = [
    {"kind": "avail", "ts": "2026-10-10T00:00:00Z", "branch": "b1", "head": "h-b1", "model": "codex", "status": "ok",
     "artifact": "diff", "perspective": "off", "responding_model": "gpt-6.1-sol"},
    fin("f1", "b1", "codex"), amend("f1", "b1", verdict="deferred", deferred_to="HIMMEL-10"),
    fin("f2", "b2", "coderabbit", verdict="deferred", deferred_to="HIMMEL-11", reason="later"),
    fin("f3", "b3", "codex"), amend("f3", "b3", verdict="deferred", deferred_to="HIMMEL-12"),
    fin("f4", "b4", "codex"), amend("f4", "b4", verdict="deferred", deferred_to="HIMMEL-99"),
    fin("f5", "b5", "codex"), amend("f5", "b5", verdict="deferred"),
    fin("f6", "b6", "codex"), amend("f6", "b6", verdict="deferred", deferred_to="HIMMEL-10"),
    amend("f6", "b6", ts="2026-10-12T00:00:00Z", verdict="fixed"),
    fin("f7", "b7", "codex"), amend("f7", "b7", verdict="agreed"),
]
with open(sys.argv[1], "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
os.makedirs(sys.argv[2])
def ticket(key, status, cat, res):
    with open(os.path.join(sys.argv[2], key + ".md"), "w") as fh:
        fh.write('---\nkey: "%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "%s"\nresolution: %s\n---\n\n# %s\n'
                 % (key, status, cat, json.dumps(res), key))
ticket("HIMMEL-10", "Done", "Done", "Done")
ticket("HIMMEL-11", "To Do", "To Do", None)
ticket("HIMMEL-12", "wont do", "Done", "Won't Do")
PY

out="$(python3 -I "$EVAL" --cr-ledger "$TMP/cr.jsonl" --mirror "$TMP/mirror" 2>"$TMP/err")"; rc=$?
eq "run: exit 0" "$rc" "0"
pick() { printf '%s' "$out" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["metrics"].get(sys.argv[1]))' "$1"; }
eq "a deferred row joined to a Done ticket counts as fixed later" "$(pick fixed_later)" "1"
eq "a deferred row joined to an open ticket counts as still open" "$(pick still_open)" "1"
eq "a deferred row joined to a Won't Do ticket counts as disproved" "$(pick disproved)" "1"
eq "a ticket the mirror lacks counts as unknown" "$(pick unknown)" "1"
eq "a deferral with no ticket counts as no ticket" "$(pick no_ticket)" "1"
eq "only findings still deferred count, not an agreed one or one fixed after deferral" "$(pick deferred)" "5"
eq "the fixed-later share is over the rulable outcomes" "$(pick fixed_later_share)" "0.3333"
eq "per critic: the critic is the slug plus the model that answered" "$(pick codex:gpt-6.1-sol.fixed_later)" "1"
eq "per critic: CodeRabbit's open deferral" "$(pick coderabbit.still_open)" "1"
eq "the row is the deferred-outcome series" "$(printf '%s' "$out" | python3 -I -c 'import json, sys; r = json.load(sys.stdin); print(r["eval"], r["status"])')" "deferred-outcome ok"

python3 -I "$EVAL" --cr-ledger "$TMP/cr.jsonl" --mirror "$TMP/mirror" --record --ledger "$TMP/runs.jsonl" >/dev/null 2>&1; rc=$?
eq "--record: exit 0" "$rc" "0"
eq "--record appends one ok deferred-outcome row" "$(grep -c '"eval":"deferred-outcome","status":"ok"' "$TMP/runs.jsonl" 2>/dev/null)" "1"
eq "--record writes a valid eval-runs row" "$(python3 -I "$HERE/lib/eval_runs.py" validate "$TMP/runs.jsonl" 2>&1 | tail -n 1)" "eval-runs validate: OK"

python3 -I "$EVAL" --cr-ledger "$TMP/cr.jsonl" --mirror "$TMP/no-mirror" >/dev/null 2>&1; rc=$?
eq "a missing Jira mirror is refused, never an all-unknown run" "$rc" "2"
python3 -I "$EVAL" --cr-ledger "$TMP/no-cr.jsonl" --mirror "$TMP/mirror" >/dev/null 2>&1; rc=$?
eq "a missing CR ledger is refused" "$rc" "2"

echo "test-deferred-outcome: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
