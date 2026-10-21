#!/usr/bin/env bash
# scripts/eval/test-eval-feedback.sh - suite for the eval feedback step (scripts/eval/lib/eval_feedback.py),
# the friction eval-runs row (friction.py --record) and the failure review's eval feedback subsection.
# Fixture ledgers only: no live ledger, no model, no Jira.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FB="$HERE/lib/eval_feedback.py"
RUNS="$HERE/lib/eval_runs.py"
FRICTION="$HERE/friction/friction.py"
FRV="$HERE/leg-digest/failure_review.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/eval-feedback-test.XXXXXX")" || { echo "test-eval-feedback: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Never the live files, whatever a case forgets to pass.
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never-runs.jsonl"
export HIMMEL_EVAL_CHANGES_LEDGER="$TMP/never-changes.jsonl"
export HIMMEL_FAILURE_INBOX="$TMP/never-inbox.md"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }
# ok <label> <cmd>...: run a setup command quietly and assert it exited 0
ok() { local l="$1"; shift; "$@" >/dev/null 2>&1; eq "$l: exit 0" "$?" "0"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-eval-feedback: python3 not on PATH"; exit 0; }

# field <ledger> <row index> <dotted key>; a key segment may hold ':' and '/', never '.'
field() { python3 -I -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1]) if l.strip()][int(sys.argv[2])]
v=r
for k in sys.argv[3].split("."): v=v.get(k) if isinstance(v,dict) else None
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$@"; }
rows() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

CLS="over_deny:hook:guard-pr-check-literal/text-mentions-gate-path"
RULES="$TMP/rules.json"
cat >"$RULES" <<'EOF'
{"v": 1, "rules": [{"eval": "friction", "metric": "over_deny:*", "threshold": 0, "better": "lower", "absent": 0,
  "change": "learning", "target": "shell-and-gate-traps.md"}]}
EOF

# --- friction --record: the friction eval writes one eval-runs row ---------------------------------
L="$TMP/runs.jsonl"
python3 -I "$FRICTION" --repo "$REPO" --now 2026-10-08T00:00:00Z --days 7 --projects "$HERE/friction/fixtures/proj" \
  --docs "$HERE/friction/fixtures/docs" --record --eval-ledger "$L" --md "$TMP/f.md" >/dev/null 2>"$TMP/f.err"
eq "friction --record: exit 0" "$?" "0"
eq "friction --record: one eval-runs row" "$(rows "$L")" "1"
eq "friction row: eval" "$(field "$L" 0 eval)" "friction"
eq "friction row: over_deny" "$(field "$L" 0 metrics.over_deny)" "1"
eq "friction row: per-class over-deny metric" "$(field "$L" 0 "metrics.$CLS")" "1"
eq "friction row: an explicit --projects scope is part of the config" "$(field "$L" 0 config.projects)" "[\"$HERE/friction/fixtures/proj\"]"
python3 -I "$RUNS" validate "$L" >/dev/null 2>&1
eq "friction row: a valid eval-runs row" "$?" "0"
RUN1="$(field "$L" 0 run_id)"

# --- an unreadable transcript makes the scan partial: the row is never a baseline --------------------
P2="$TMP/proj"; cp -R "$HERE/friction/fixtures/proj" "$P2"; mkdir -p "$P2/sess-x/unreadable.jsonl"
L2="$TMP/runs-partial.jsonl"
ok "partial scan" python3 -I "$FRICTION" --repo "$REPO" --now 2026-10-08T00:00:00Z --days 7 --projects "$P2" \
  --docs "$HERE/friction/fixtures/docs" --record --eval-ledger "$L2" --md "$TMP/f2.md"
eq "partial scan: the row says partial" "$(field "$L2" 0 status)" "partial"
eq "partial scan: names the unreadable count" "$(field "$L2" 0 meta.unreadable)" "1"

# --- run 1: a result past the threshold produces one change record ---------------------------------
C="$TMP/changes.jsonl"
IN="$TMP/inbox.md"
out=$(python3 -I "$FB" run --ledger "$L" --changes "$C" --rules "$RULES" --inbox "$IN" 2>&1); rc=$?
eq "run 1: exit 0" "$rc" "0"
eq "run 1: one change record and its inbox mark" "$(rows "$C")" "2"
eq "inbox mark: written" "$(field "$C" 1 inbox_written)" "true"
eq "change: status open" "$(field "$C" 0 status)" "open"
eq "change: metric" "$(field "$C" 0 metric)" "$CLS"
eq "change: kind" "$(field "$C" 0 change)" "learning"
eq "change: baseline is the friction run" "$(field "$C" 0 baseline_run_id)" "$RUN1"
eq "change: value" "$(field "$C" 0 value)" "1"
has "run 1: prints the change" "$out" "change"
eq "learning change: one memory-inbox line" "$(rows "$IN")" "1"
has "inbox line names the metric and topic" "$(cat "$IN" 2>/dev/null)" "eval/friction $CLS value=1 threshold=0 topic=shell-and-gate-traps.md"

# --- the same run again changes nothing --------------------------------------------------------------
ok "rerun" python3 -I "$FB" run --ledger "$L" --changes "$C" --rules "$RULES" --inbox "$IN"
eq "rerun on the same eval run: no second record" "$(rows "$C")" "2"
eq "rerun: no second inbox line" "$(rows "$IN")" "1"

# --- run 2: the next run of the same series re-measures the change ----------------------------------
ok "run 2 row" python3 -I "$RUNS" append --ledger "$L" --eval friction --source scripts/eval/friction/friction.py \
  --config-json "{\"friction_v\":1,\"days\":7,\"projects\":[\"$HERE/friction/fixtures/proj\"]}" \
  --metrics-json '{"refusals":2,"over_deny":0,"over_deny_share":0}'
out=$(python3 -I "$FB" run --ledger "$L" --changes "$C" --rules "$RULES" --inbox "$IN" 2>&1); rc=$?
eq "run 2: exit 0" "$rc" "0"
eq "run 2: a measured record" "$(rows "$C")" "3"
eq "measured: status" "$(field "$C" 2 status)" "measured"
eq "measured: same change id" "$(field "$C" 2 id)" "$(field "$C" 0 id)"
eq "measured: before" "$(field "$C" 2 before)" "1"
eq "measured: after (absent metric counts as 0)" "$(field "$C" 2 after)" "0"
eq "measured: delta" "$(field "$C" 2 delta)" "-1"
eq "measured: verdict" "$(field "$C" 2 verdict)" "improved"
has "run 2: prints the before and after" "$out" "before=1 after=0 delta=-1 improved"
ok "rerun after measure" python3 -I "$FB" run --ledger "$L" --changes "$C" --rules "$RULES" --inbox "$IN"
eq "a measured change is not measured again" "$(rows "$C")" "3"

# --- a run of another config is another series: it neither measures nor is measured ------------------
L3="$TMP/runs3.jsonl"; C3="$TMP/changes3.jsonl"
ok "days-7 row" python3 -I "$RUNS" append --ledger "$L3" --eval friction --source s \
  --config-json '{"friction_v":1,"days":7}' --metrics-json "{\"over_deny\":5,\"$CLS\":5}"
ok "days-7 feedback" python3 -I "$FB" run --ledger "$L3" --changes "$C3" --rules "$RULES"
ok "days-14 row" python3 -I "$RUNS" append --ledger "$L3" --eval friction --source s \
  --config-json '{"friction_v":1,"days":14}' --metrics-json "{\"over_deny\":3,\"$CLS\":3}"
ok "days-14 feedback" python3 -I "$FB" run --ledger "$L3" --changes "$C3" --rules "$RULES"
eq "another config: the open change stays unmeasured" "$(field "$C3" 1 status)" "open"
eq "another config: its own change opens on the same metric" "$(rows "$C3")" "2"
eq "another config: the new change is that config's" "$(field "$C3" 1 value)" "3"

# --- under the threshold: no change ------------------------------------------------------------------
L4="$TMP/runs4.jsonl"; C4="$TMP/changes4.jsonl"
ok "threshold row" python3 -I "$RUNS" append --ledger "$L4" --eval friction --source s \
  --config-json '{"friction_v":1,"days":7}' --metrics-json "{\"over_deny\":0,\"$CLS\":0}"
ok "threshold feedback" python3 -I "$FB" run --ledger "$L4" --changes "$C4" --rules "$RULES"
eq "a result at the threshold makes no change record" "$(rows "$C4")" "0"

# --- an inbox write that fails after the ledger write is marked, then retried once on the next run ------
L5="$TMP/runs5.jsonl"; C5="$TMP/changes5.jsonl"; IN5="$TMP/inbox5.md"
ok "inbox-fail row" python3 -I "$RUNS" append --ledger "$L5" --eval friction --source s \
  --config-json '{"friction_v":1,"days":7}' --metrics-json "{\"over_deny\":2,\"$CLS\":2}"
mkdir -p "$IN5"
ok "failed inbox write" python3 -I "$FB" run --ledger "$L5" --changes "$C5" --rules "$RULES" --inbox "$IN5"
eq "failed inbox write: the change is marked unwritten" "$(field "$C5" 1 inbox_written)" "false"
rmdir "$IN5"
ok "inbox retry" python3 -I "$FB" run --ledger "$L5" --changes "$C5" --rules "$RULES" --inbox "$IN5"
eq "inbox retry: the next run writes the line once" "$(rows "$IN5")" "1"
eq "inbox retry: the change is marked written" "$(field "$C5" 2 inbox_written)" "true"
ok "after retry" python3 -I "$FB" run --ledger "$L5" --changes "$C5" --rules "$RULES" --inbox "$IN5"
eq "a written change is not retried" "$(rows "$IN5")" "1"

# --- the daily failure review runs the feedback step and shows it ------------------------------------
D="$TMP/review"; mkdir -p "$D"
: >"$D/ledger.jsonl"
ok "review row" python3 -I "$RUNS" append --ledger "$D/runs.jsonl" --eval friction --source s \
  --config-json '{"friction_v":1,"days":7}' --metrics-json "{\"over_deny\":500,\"$CLS\":500}"
HIMMEL_EVAL_RUNS_LEDGER="$D/runs.jsonl" HIMMEL_EVAL_CHANGES_LEDGER="$D/changes.jsonl" FAILURE_REVIEW_FRICTION_CMD="" \
  JIRA_PROJECT_KEY=HIMMEL python3 "$FRV" --ledger "$D/ledger.jsonl" --state "$D/state.json" --log "$D/log.jsonl" \
  --inbox "$D/inbox.md" --out-dir "$D/out" --now 2026-10-07T12:00:00Z --notify-cmd true >"$D/run.out" 2>&1
eq "failure review: exit 0" "$?" "0"
digest="$(cat "$D"/out/failure-review-*.md 2>/dev/null)"
has "failure review: eval feedback subsection" "$digest" "### Eval feedback"
has "failure review: names the new change" "$digest" "$CLS"
eq "failure review: the change record is written" "$(rows "$D/changes.jsonl")" "1"
eq "failure review dry run: no memory-inbox line" "$(rows "$D/inbox.md")" "0"
for i in 1 2; do
  HIMMEL_EVAL_RUNS_LEDGER="$D/runs.jsonl" HIMMEL_EVAL_CHANGES_LEDGER="$D/changes.jsonl" FAILURE_REVIEW_FRICTION_CMD="" \
    JIRA_PROJECT_KEY=HIMMEL python3 "$FRV" --ledger "$D/ledger.jsonl" --state "$D/state.json" --log "$D/log.jsonl" \
    --inbox "$D/inbox.md" --out-dir "$D/out" --now 2026-10-07T12:00:00Z --notify-cmd true --live >"$D/live$i.out" 2>&1
  eq "live review $i after a dry run: exit 0" "$?" "0"
  eq "live review $i after a dry run: the dry-run change is delivered once" "$(rows "$D/inbox.md")" "1"
done
has "the delivered line names the metric and topic" "$(cat "$D/inbox.md" 2>/dev/null)" "eval/friction $CLS value=500 threshold=100 topic=shell-and-gate-traps.md"

# --- only a --live review writes the inbox line, once per opened change ---------------------------------
E="$TMP/review-live"; mkdir -p "$E"
: >"$E/ledger.jsonl"
ok "live review row" python3 -I "$RUNS" append --ledger "$E/runs.jsonl" --eval friction --source s \
  --config-json '{"friction_v":1,"days":7}' --metrics-json "{\"over_deny\":500,\"$CLS\":500}"
for i in 1 2; do
  HIMMEL_EVAL_RUNS_LEDGER="$E/runs.jsonl" HIMMEL_EVAL_CHANGES_LEDGER="$E/changes.jsonl" FAILURE_REVIEW_FRICTION_CMD="" \
    JIRA_PROJECT_KEY=HIMMEL python3 "$FRV" --ledger "$E/ledger.jsonl" --state "$E/state.json" --log "$E/log.jsonl" \
    --inbox "$E/inbox.md" --out-dir "$E/out" --now 2026-10-07T12:00:00Z --notify-cmd true --live >"$E/run$i.out" 2>&1
  eq "live review $i: exit 0" "$?" "0"
  eq "live review $i: exactly one memory-inbox line" "$(rows "$E/inbox.md")" "1"
done
has "live review: the line names the metric and topic" "$(cat "$E/inbox.md" 2>/dev/null)" "eval/friction $CLS value=500 threshold=100 topic=shell-and-gate-traps.md"

echo "eval-feedback: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
