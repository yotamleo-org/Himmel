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
FRV="$HERE/worker-digest/failure_review.py"
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
  --config-json '{"friction_v":1,"days":7}' --metrics-json "{\"refusals\":1000,\"tool_calls\":1000,\"over_deny\":500,\"$CLS\":500}"
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
has "the delivered line names the metric and topic" "$(cat "$D/inbox.md" 2>/dev/null)" "eval/friction $CLS value=0.5 threshold=0.1 topic=shell-and-gate-traps.md"

# --- only a --live review writes the inbox line, once per opened change ---------------------------------
E="$TMP/review-live"; mkdir -p "$E"
: >"$E/ledger.jsonl"
ok "live review row" python3 -I "$RUNS" append --ledger "$E/runs.jsonl" --eval friction --source s \
  --config-json '{"friction_v":1,"days":7}' --metrics-json "{\"refusals\":1000,\"tool_calls\":1000,\"over_deny\":500,\"$CLS\":500}"
for i in 1 2; do
  HIMMEL_EVAL_RUNS_LEDGER="$E/runs.jsonl" HIMMEL_EVAL_CHANGES_LEDGER="$E/changes.jsonl" FAILURE_REVIEW_FRICTION_CMD="" \
    JIRA_PROJECT_KEY=HIMMEL python3 "$FRV" --ledger "$E/ledger.jsonl" --state "$E/state.json" --log "$E/log.jsonl" \
    --inbox "$E/inbox.md" --out-dir "$E/out" --now 2026-10-07T12:00:00Z --notify-cmd true --live >"$E/run$i.out" 2>&1
  eq "live review $i: exit 0" "$?" "0"
  eq "live review $i: exactly one memory-inbox line" "$(rows "$E/inbox.md")" "1"
done
has "live review: the line names the metric and topic" "$(cat "$E/inbox.md" 2>/dev/null)" "eval/friction $CLS value=0.5 threshold=0.1 topic=shell-and-gate-traps.md"

# --- the shipped rules: a critic class below its threshold yields one improvement record per critic -----
G="$TMP/critics"; mkdir -p "$G"
ok "panel row" python3 -I "$RUNS" append --ledger "$G/runs.jsonl" --eval review-panel --source s \
  --config-json '{"review_panel_v":1}' --metrics-json '{"codex.class.logic.recall":1,"codex.class.quoting.recall":0,
  "codex.class.toctou.recall":0.5,"coderabbit.class.logic.recall":0.25,"coderabbit.class.quoting.recall":1}'
ok "judge row" python3 -I "$RUNS" append --ledger "$G/runs.jsonl" --eval judge-accuracy --source s \
  --config-json '{"judge_accuracy_v":1,"days":28}' --metrics-json '{"class.reader-allowlist.escape_excess":0.036,
  "class.other.escape_excess":-0.007,"cause.ci-selection.escape_rate":0.002}'
ok "shipped rules" python3 -I "$FB" run --ledger "$G/runs.jsonl" --changes "$G/changes.jsonl"
eq "shipped rules: one change per critic" "$(rows "$G/changes.jsonl")" "3"
eq "codex: its weakest class" "$(field "$G/changes.jsonl" 1 metric)" "codex.class.quoting.recall"
eq "codex: a prompt change" "$(field "$G/changes.jsonl" 1 change)" "prompt"
eq "codex: the critic is named" "$(field "$G/changes.jsonl" 1 critic)" "codex"
eq "coderabbit: its weakest class" "$(field "$G/changes.jsonl" 2 metric)" "coderabbit.class.logic.recall"
eq "coderabbit: a config change" "$(field "$G/changes.jsonl" 2 change)" "cr-config"
eq "judges: the class whose interval sits above the whole" "$(field "$G/changes.jsonl" 0 metric)" "class.reader-allowlist.escape_excess"
eq "judges: a judge-brief change" "$(field "$G/changes.jsonl" 0 target)" "docs/handover/judge-brief-template.md"
ok "judge row 2" python3 -I "$RUNS" append --ledger "$G/runs.jsonl" --eval judge-accuracy --source s \
  --config-json '{"judge_accuracy_v":1,"days":28}' --metrics-json '{"class.reader-allowlist.escape_excess":0.01,
  "cause.ci-selection.escape_rate":0.009}'
ok "shipped rules rerun" python3 -I "$FB" run --ledger "$G/runs.jsonl" --changes "$G/changes.jsonl"
eq "judges rerun: a measured record and a new change" "$(rows "$G/changes.jsonl")" "5"
eq "judges rerun: re-measured" "$(field "$G/changes.jsonl" 3 verdict)" "improved"
eq "judges rerun: ci-selection escapes come first" "$(field "$G/changes.jsonl" 4 change)" "impacted-suites"

# --- a rule with `per` judges a rate, so a count that rises only with session volume fires nothing ------
V="$TMP/per"; mkdir -p "$V"
# vol <ledger> <tool calls> <over-denials>: refusal count stays fixed to isolate the call denominator.
vol() { python3 -I "$RUNS" append --ledger "$1" --eval friction --source s --config-json '{"friction_v":1,"days":7}' \
  --metrics-json "{\"refusals\":1000,\"tool_calls\":$2,\"$CLS\":$3}" >/dev/null 2>&1; }
ok "volume row" vol "$V/runs.jsonl" 1000000 300
ok "volume feedback" python3 -I "$FB" run --eval friction --ledger "$V/runs.jsonl" --changes "$V/c.jsonl" --rules "$HERE/feedback-rules.json"
eq "per: 300 over-denials in 1000000 tool calls opens no change under the shipped rule" "$(rows "$V/c.jsonl")" "0"
ok "rate row" vol "$V/runs.jsonl" 1000 300
ok "rate feedback" python3 -I "$FB" run --eval friction --ledger "$V/runs.jsonl" --changes "$V/c.jsonl" --rules "$HERE/feedback-rules.json"
eq "per: the same 300 in 1000 tool calls opens one change" "$(rows "$V/c.jsonl")" "1"
eq "per: the change's value is the rate" "$(field "$V/c.jsonl" 0 value)" "0.3"
eq "per: the change names its denominator" "$(field "$V/c.jsonl" 0 per)" "tool_calls"
ok "volume-up row" vol "$V/runs.jsonl" 1000000 300
ok "volume-up measure" python3 -I "$FB" run --eval friction --ledger "$V/runs.jsonl" --changes "$V/c.jsonl" --rules "$HERE/feedback-rules.json"
eq "per: the re-measure reads the rate too" "$(field "$V/c.jsonl" 1 after)" "0.0003"

# --- a sealed split: rules tune on the open half only, and never read the sealed half ---------------
# A split row carries open.<metric> and sealed.<metric> beside the whole-set metric (score.py).
S="$TMP/sealed"; mkdir -p "$S"
cat >"$S/rules.json" <<'EOF'
{"v": 1, "rules": [{"eval": "review-panel", "metric": "codex.class.*.recall", "threshold": 0.5, "better": "higher",
  "absent": null, "change": "prompt", "target": "scripts/cr/critic-first-pass.sh", "critic": "codex", "min_gain": 0.25}]}
EOF
# split <ledger> <whole> <open> <sealed>: one review-panel row for the quoting class
split() { python3 -I "$RUNS" append --ledger "$1" --eval "${SPLIT_EVAL:-review-panel}" --source s --config-json '{"review_panel_v":2}' \
  --metrics-json "{\"codex.class.quoting.recall\":$2,\"open.codex.class.quoting.recall\":$3,\"sealed.codex.class.quoting.recall\":$4}" >/dev/null 2>&1; }
ok "sealed-bad row" split "$S/a.jsonl" 0.5 1 0
ok "sealed-bad feedback" python3 -I "$FB" run --ledger "$S/a.jsonl" --changes "$S/a-changes.jsonl" --rules "$S/rules.json"
eq "sealed: a bad sealed half (and whole set) with a good open half opens no change" "$(rows "$S/a-changes.jsonl")" "0"
ok "open-bad row" split "$S/b.jsonl" 0.5 0 1
ok "open-bad feedback" python3 -I "$FB" run --ledger "$S/b.jsonl" --changes "$S/b-changes.jsonl" --rules "$S/rules.json"
eq "sealed: a bad open half opens one change" "$(rows "$S/b-changes.jsonl")" "1"
eq "sealed: the change names the open-half metric, unprefixed" "$(field "$S/b-changes.jsonl" 0 metric)" "codex.class.quoting.recall"
eq "sealed: its value is the open half's" "$(field "$S/b-changes.jsonl" 0 value)" "0"
# A sweep of sealed cases only (--only) has sealed. metrics and no open. half.
ok "sealed-only row" python3 -I "$RUNS" append --ledger "$S/c.jsonl" --eval review-panel --source s --config-json '{"review_panel_v":2}' \
  --metrics-json '{"codex.class.quoting.recall":0,"sealed.codex.class.quoting.recall":0}'
ok "sealed-only feedback" python3 -I "$FB" run --ledger "$S/c.jsonl" --changes "$S/c-changes.jsonl" --rules "$S/rules.json"
eq "sealed: a row with no open half opens no change from its sealed or whole-set metrics" "$(rows "$S/c-changes.jsonl")" "0"

# --- train/test keep rule: keep only when train AND test both gain more than min_gain, over noise --------
T="$TMP/keep"; mkdir -p "$T"
SPLIT_EVAL=split-eval
sed 's/"eval": "review-panel"/"eval": "split-eval"/' "$S/rules.json" >"$T/rules.json"
ok "keep base 1" split "$T/up-flat.jsonl" 0 0 0
ok "keep base 2" split "$T/up-flat.jsonl" 0 0 0
ok "keep open" python3 -I "$FB" run --ledger "$T/up-flat.jsonl" --changes "$T/up-flat-c.jsonl" --rules "$T/rules.json"
ok "train-up/test-flat row" split "$T/up-flat.jsonl" 0.5 1 0
ok "train-up/test-flat measure" python3 -I "$FB" run --ledger "$T/up-flat.jsonl" --changes "$T/up-flat-c.jsonl" --rules "$T/rules.json"
eq "keep rule: a train-up/test-flat change is reverted" "$(field "$T/up-flat-c.jsonl" 1 verdict)" "revert"
has "keep rule: the revert says why" "$(field "$T/up-flat-c.jsonl" 1 reason)" "test"
eq "keep rule: the test half is recorded" "$(field "$T/up-flat-c.jsonl" 1 test_after)" "0"
ok "both-up base 1" split "$T/both.jsonl" 0 0 0
ok "both-up base 2" split "$T/both.jsonl" 0 0 0
ok "both-up open" python3 -I "$FB" run --ledger "$T/both.jsonl" --changes "$T/both-c.jsonl" --rules "$T/rules.json"
ok "both-up row" split "$T/both.jsonl" 1 1 1
ok "both-up measure" python3 -I "$FB" run --ledger "$T/both.jsonl" --changes "$T/both-c.jsonl" --rules "$T/rules.json"
eq "keep rule: train and test both up, no noise: kept" "$(field "$T/both-c.jsonl" 1 verdict)" "keep"
eq "keep rule: the noise is the spread of the runs before the change" "$(field "$T/both-c.jsonl" 1 noise)" "0"
ok "noisy base 1" split "$T/noisy.jsonl" 0 0.5 0
ok "noisy base 2" split "$T/noisy.jsonl" 0 0 0
ok "noisy open" python3 -I "$FB" run --ledger "$T/noisy.jsonl" --changes "$T/noisy-c.jsonl" --rules "$T/rules.json"
ok "noisy row" split "$T/noisy.jsonl" 1 1 1
ok "noisy measure" python3 -I "$FB" run --ledger "$T/noisy.jsonl" --changes "$T/noisy-c.jsonl" --rules "$T/rules.json"
eq "keep rule: run-to-run noise (0.5) not below min_gain (0.25) is not kept" "$(field "$T/noisy-c.jsonl" 1 verdict)" "revert"
has "keep rule: the noisy revert names the noise" "$(field "$T/noisy-c.jsonl" 1 reason)" "noise"
ok "one-run base" split "$T/one.jsonl" 0 0 0
ok "one-run open" python3 -I "$FB" run --ledger "$T/one.jsonl" --changes "$T/one-c.jsonl" --rules "$T/rules.json"
ok "one-run row" split "$T/one.jsonl" 1 1 1
ok "one-run measure" python3 -I "$FB" run --ledger "$T/one.jsonl" --changes "$T/one-c.jsonl" --rules "$T/rules.json"
eq "keep rule: one run before the change leaves the noise unmeasured: not kept" "$(field "$T/one-c.jsonl" 1 verdict)" "revert"
# A rule with absent=0 must not stand in for a sealed half the row never measured.
cat >"$T/absent-rules.json" <<'EOF'
{"v": 1, "rules": [{"eval": "split-eval", "metric": "codex.fp_rate", "threshold": 0.2, "better": "lower",
  "absent": 0, "change": "prompt", "target": "scripts/cr/critic-first-pass.sh", "critic": "codex", "min_gain": 0.1}]}
EOF
fp() { python3 -I "$RUNS" append --ledger "$1" --eval split-eval --source s --config-json '{"review_panel_v":2}' \
  --metrics-json "$2" >/dev/null 2>&1; }
ok "absent base 1" fp "$T/absent.jsonl" '{"open.codex.fp_rate":0.5,"sealed.codex.fp_rate":0.5}'
ok "absent base 2" fp "$T/absent.jsonl" '{"open.codex.fp_rate":0.5,"sealed.codex.fp_rate":0.5}'
ok "absent open" python3 -I "$FB" run --ledger "$T/absent.jsonl" --changes "$T/absent-c.jsonl" --rules "$T/absent-rules.json"
ok "absent row" fp "$T/absent.jsonl" '{"open.codex.fp_rate":0,"sealed.codex.clean_scored":0}'
ok "absent measure" python3 -I "$FB" run --ledger "$T/absent.jsonl" --changes "$T/absent-c.jsonl" --rules "$T/absent-rules.json"
eq "keep rule: a sealed half with no value is unmeasured, not the rule's absent" "$(field "$T/absent-c.jsonl" 1 reason)" "test half unmeasured"
ok "absent-open base 1" fp "$T/absent2.jsonl" '{"open.codex.fp_rate":0.5,"sealed.codex.fp_rate":0.5}'
ok "absent-open base 2" fp "$T/absent2.jsonl" '{"open.codex.fp_rate":0.5,"sealed.codex.fp_rate":0.5}'
ok "absent-open open" python3 -I "$FB" run --ledger "$T/absent2.jsonl" --changes "$T/absent2-c.jsonl" --rules "$T/absent-rules.json"
ok "absent-open row" fp "$T/absent2.jsonl" '{"open.codex.clean_scored":0,"sealed.codex.fp_rate":0}'
ok "absent-open measure" python3 -I "$FB" run --ledger "$T/absent2.jsonl" --changes "$T/absent2-c.jsonl" --rules "$T/absent-rules.json"
eq "a split row's open half with no value is unmeasured, not the rule's absent: nothing measured" "$(rows "$T/absent2-c.jsonl")" "1"
# Noise under the record's rounding is still noise: min_gain 0 keeps only a change over zero noise.
sed 's/"min_gain": 0.25/"min_gain": 0/' "$T/rules.json" >"$T/zero-rules.json"
ok "tiny-noise base 1" split "$T/tiny.jsonl" 0 0.4 0
ok "tiny-noise base 2" split "$T/tiny.jsonl" 0 0.4000004 0
ok "tiny-noise open" python3 -I "$FB" run --ledger "$T/tiny.jsonl" --changes "$T/tiny-c.jsonl" --rules "$T/zero-rules.json"
ok "tiny-noise row" split "$T/tiny.jsonl" 1 1 1
ok "tiny-noise measure" python3 -I "$FB" run --ledger "$T/tiny.jsonl" --changes "$T/tiny-c.jsonl" --rules "$T/zero-rules.json"
eq "keep rule: noise that rounds to 0 is still not below a min_gain of 0" "$(field "$T/tiny-c.jsonl" 1 reason)" "noise not below min gain"
# Two finite train values can still differ by more than a float holds: that noise is unmeasured, never Infinity.
ok "overflow base 1" fp "$T/inf.jsonl" '{"open.codex.fp_rate":-1e308,"sealed.codex.fp_rate":0.5}'
ok "overflow base 2" fp "$T/inf.jsonl" '{"open.codex.fp_rate":1e308,"sealed.codex.fp_rate":0.5}'
ok "overflow open" python3 -I "$FB" run --ledger "$T/inf.jsonl" --changes "$T/inf-c.jsonl" --rules "$T/absent-rules.json"
ok "overflow row" fp "$T/inf.jsonl" '{"open.codex.fp_rate":-1e308,"sealed.codex.fp_rate":0}'
ok "overflow measure" python3 -I "$FB" run --ledger "$T/inf.jsonl" --changes "$T/inf-c.jsonl" --rules "$T/absent-rules.json"
eq "keep rule: overflowing noise is unmeasured: not kept" "$(field "$T/inf-c.jsonl" 1 reason)" "noise unmeasured: not a finite spread"
eq "keep rule: the record holds no Infinity" "$(grep -c Infinity "$T/inf-c.jsonl")" "0"
SPLIT_EVAL=review-panel

R6="$TMP/m6-repo"; mkdir -p "$R6/scripts/eval/review-panel" "$R6/scripts/cr"
gitc6() { git -C "$R6" -c user.name=t -c user.email=t@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }
commit6() { gitc6 add -A && gitc6 commit -q -m "$1" && gitc6 rev-parse HEAD; }
printf 'scripts/cr/critic-first-pass.sh\nscripts/cr/critic-panel.sh\n' >"$R6/scripts/eval/review-panel/cbs.txt"
printf 'v1\n' >"$R6/scripts/cr/critic-first-pass.sh"; printf 'p1\n' >"$R6/scripts/cr/critic-panel.sh"; printf 'd1\n' >"$R6/README"
git init -q "$R6"
ROOT6="$(commit6 root)"
printf 'v2\n' >"$R6/scripts/cr/critic-first-pass.sh"; printf 'd2\n' >"$R6/README"
APPLY6="$(commit6 'the prompt change, and a note outside the behaviour set')"
printf 'd3\n' >"$R6/README"
DOCS6="$(commit6 'outside the behaviour set only')"
chmod +x "$R6/scripts/cr/critic-first-pass.sh"
MODE6="$(commit6 'the target mode only: same bytes')"
printf 'p2\n' >"$R6/scripts/cr/critic-panel.sh"
OTHER6="$(commit6 'another behaviour path, not the target')"
printf 'v4\n' >"$R6/scripts/cr/critic-first-pass.sh"; printf 'p3\n' >"$R6/scripts/cr/critic-panel.sh"
BOTH6="$(commit6 'the target and another behaviour path')"
MAIN6="$(gitc6 symbolic-ref --short HEAD)"
gitc6 checkout -q -b side; printf 's\n' >"$R6/SIDE"; commit6 side >/dev/null
gitc6 checkout -q "$MAIN6"; printf 'v3\n' >"$R6/scripts/cr/critic-first-pass.sh"; commit6 main >/dev/null
gitc6 merge -q --no-ff -m merge side >/dev/null 2>&1
MERGE6="$(gitc6 rev-parse HEAD)"
eq "M6 fixture repo: seven distinct commits" "$(printf '%s\n' "$ROOT6" "$APPLY6" "$DOCS6" "$MODE6" "$OTHER6" "$BOTH6" "$MERGE6" | sort -u | grep -c .)" "7"

SELPY="$TMP/sel.py"
cat >"$SELPY" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import eval_feedback as fb

S1, S2 = "a" * 64, "b" * 64
def row(rid, ex=None, sup=None, scorer=None, bundle=None, **kw):
    r = {"run_id": rid, "outputs_sha256": bundle or "raw-" + rid, "scorer_sha256": scorer}
    if ex:
        r["execution_id"] = ex
    if sup:
        r["supersedes_run_id"] = sup
    r.update(kw)
    return r

def case(name, rows, want, reason=None, **kw):
    sel, diag = fb.select_review_runs(rows, **kw)
    got = [r["run_id"] for r in sel]
    ok = got == want and (reason is None or any(d["reason"] == reason for d in diag))
    print("PASS " + name if ok else "FAIL %s: got %s, diagnostics %s" % (name, got, [d["reason"] for d in diag]))

case("scorer_only_rescore_not_new_execution",
     [row("A", "x1", scorer=S1), row("A~b", "x1", sup="A", scorer=S2, bundle="raw-A")], ["A~b"], "superseded")
case("a rescore appended before its source still selects the head",
     [row("A~b", "x1", sup="A", scorer=S2, bundle="raw-A"), row("A", "x1", scorer=S1)], ["A~b"])
case("a chain of three selects its head",
     [row("A", "x1"), row("B", "x1", sup="A"), row("C", "x1", sup="B")], ["C"], "superseded")
case("supersession_cycle", [row("A", "x1", sup="B"), row("B", "x1", sup="A")], [], "supersession-cycle")
case("a cycle with a tail names the fork or the cycle, never selects",
     [row("A", "x1", sup="B"), row("B", "x1", sup="A"), row("C", "x1", sup="A")], [])
case("two_successors_ambiguous",
     [row("A", "x1"), row("B", "x1", sup="A"), row("C", "x1", sup="A")], [], "two-successors-ambiguous")
case("a successor of an unknown run is named, not selected", [row("B", "x1", sup="ghost"), row("C", "x1")], [],
     "supersedes-unknown-run")
case("a linked chain beside an unlinked row is ambiguous",
     [row("A", "x1"), row("B", "x1", sup="A"), row("Z", "x1")], [], "several-heads-ambiguous")
case("legacy repeat: the same raw-output bundle counts once, first row wins",
     [row("A", bundle="same"), row("B", bundle="same")], ["A"], "repeat-of-execution")
case("legacy repeat: the same run_id counts once", [row("A", bundle="p"), row("A", bundle="q")], ["A"])
case("an execution_id binds rows whose raw-output hashes differ",
     [row("A", "x1", bundle="p"), row("B", "x1", bundle="q")], ["A"])
case("distinct executions both count", [row("A", "x1"), row("B", "x2")], ["A", "B"])
case("a rescore with no execution_id on either row joins its source through supersedes_run_id",
     [row("A"), row("B"), row("A~b", sup="A")], ["A~b", "B"], "superseded")
case("a lone row promoted without its source stands", [row("A~b", "x1", sup="A")], ["A~b"])
case("a rescore of an execution is not a second repeat of its cohort",
     [row("A", "x1"), row("B", "x2"), row("A~b", "x1", sup="A")], ["A~b", "B"])
case("revision_not_prev_run: a rescore appended last is not the newest run",
     [row("A", "x1"), row("B", "x2"), row("A~b", "x1", sup="A")], ["A~b", "B"])
case("scorer: only the running scorer's heads stay", [row("A", scorer=S1), row("B", scorer=S2), row("C")], ["B"],
     "other-scorer", scorer=S2)
case("scorer: a row with no digest is named without-scorer-sha256", [row("C")], [], "without-scorer-sha256", scorer=S1)
case("scorer: an unlinked re-score under the same run_id still replaces the older scorer's row",
     [row("A", scorer=S1, bundle="p"), row("A", scorer=S2, bundle="p")], ["A"], scorer=S2)
sel, _ = fb.select_review_runs([row("A", scorer=S1, bundle="p", marker=1), row("A", scorer=S2, bundle="p", marker=2)],
                               scorer=S2)
print("PASS scorer: the unlinked re-score is the row that stays" if [r["marker"] for r in sel] == [2]
      else "FAIL scorer: the unlinked re-score is the row that stays: %s" % sel)
case("scorer: the rescore replaces the obsolete row even though it comes later",
     [row("A", "x1", scorer=S1), row("A~b", "x1", sup="A", scorer=S2)], ["A~b"], scorer=S2)
case("old_unknown_provenance_diagnostic_only: an ineligible head is dropped with its reasons",
     [row("A", decision_eligible=False, ineligibility_reasons=["provenance-reconstructed"])], [],
     "not-decision-eligible", eligible_only=True)
case("old_unknown_provenance: without eligible_only the row is still listed",
     [row("A", decision_eligible=False)], ["A"])
case("a row that carries no decision_eligible keeps its legacy standing", [row("A")], ["A"], eligible_only=True)
case("eval-runs rows: the fields are read from meta",
     [{"run_id": "A", "meta": {"execution_id": "x", "scorer_sha256": S1}},
      {"run_id": "B", "meta": {"execution_id": "x", "supersedes_run_id": "A", "scorer_sha256": S2}}], ["B"], scorer=S2)
case("a non-dict row is skipped", [None, row("A")], ["A"])
bad_ids = [{"run_id": ["a"], "outputs_sha256": [1]}, {"run_id": {"x": 1}, "outputs_sha256": [1]}, row("A")]
case("non-string ids name nothing: each such row is its own run, no TypeError", bad_ids, [["a"], {"x": 1}, "A"],
     scorer=None)
counted = {"cbs_hash": "h", "confighash": "c", "status": "ok", "metrics": {fb.GATE_RECALL: 0.5, fb.GATE_FP: 0.1}}
bad_counted = [dict(counted, run_id=["a"], outputs_sha256=[1]), dict(counted, run_id={"x": 1}, outputs_sha256=[2]),
               dict(counted, run_id="A", outputs_sha256="p")]
try:
    got, _, _ = fb.gate_side(bad_counted, "h", "c")
    print("PASS gate_side: list-valued ids on counted rows are no TypeError, each row counts once" if len(got) == 3
          else "FAIL gate_side: %d rows counted" % len(got))
except TypeError as e:
    print("FAIL gate_side: a list-valued run_id raised %s" % e)

def er(conf="h", scorer=S1, cov=None):
    m = {"scorer_sha256": scorer}
    if cov is not None:
        m["coverage"] = cov
    return {"confighash": conf, "meta": m}
cov = {"scored": 3, "critics": {"codex": {"answer": 3}}}
for name, a, b, want in (
        ("equal everything compares", er(cov=cov), er(cov=cov), None),
        ("another confighash", er("h", cov=cov), er("g", cov=cov), "confighash"),
        ("an unknown scorer", er(scorer=None, cov=cov), er(scorer=None, cov=cov), "scorer_sha256"),
        ("another scorer", er(cov=cov), er(scorer=S2, cov=cov), "scorer_sha256"),
        ("unequal participation_no_promotion", er(cov=cov), er(cov={"scored": 3, "critics": {"codex": {"answer": 2}}}),
         "participation differs"),
        ("participation unrecorded", er(cov=cov), er(), "unrecorded")):
    got = fb.review_incompat(a, b)
    ok = (got is None) if want is None else (got is not None and want in got)
    print(("PASS " if ok else "FAIL ") + "review_incompat: %s (%s)" % (name, got))

import json, os, tempfile
sys.path.insert(0, os.path.join(sys.argv[1]))
import eval_runs
d = tempfile.mkdtemp()
rules = os.path.join(d, "rules.json")
open(rules, "w").write('{"v":1,"rules":[{"eval":"review-panel","metric":"codex.class.quoting.recall","threshold":0.5,'
                       '"better":"higher","absent":null,"change":"prompt","target":"scripts/cr/critic-first-pass.sh",'
                       '"critic":"codex","min_gain":0.25}]}')
ledger, changes = os.path.join(d, "l.jsonl"), os.path.join(d, "c.jsonl")
repo, root_sha, apply_sha = sys.argv[2:5]
COV = {"scored": 4, "critics": {"codex": {"answer": 4}}}
def add(rid, open_v, sealed_v, ex, sup=None, sc=S1, code=root_sha, ts=None):
    cfg = {"review_panel_v": 2}
    meta = {"execution_id": ex, "scorer_sha256": sc, "coverage": COV, "code_under_test_sha": code,
            "decision_eligible": True}
    if sup:
        meta["supersedes_run_id"] = sup
    r = eval_runs.make_row("review-panel", "s", cfg, {"codex.class.quoting.recall": open_v,
                           "open.codex.class.quoting.recall": open_v, "sealed.codex.class.quoting.recall": sealed_v},
                           run_id=rid, meta=meta, gitsha="g")
    if ts:
        r["ts"] = ts
    eval_runs.append_row(r, ledger)
def recs():
    return [__import__("json").loads(l) for l in open(changes)] if os.path.exists(changes) else []
add("base1", 0, 0, "x1")
add("base2", 0, 0, "x2")
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
opened = [c for c in recs() if c["status"] == "open"]
print(("PASS " if len(opened) == 1 and opened[0]["baseline_run_id"] == "base2" else "FAIL ") + "noise series: change opened on the newest execution")
fb.apply_review(opened[0]["id"], apply_sha, changes, repo=repo)
add("base2~r", 0, 0, "x2", sup="base2", sc=S2)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
meas = [c for c in recs() if c["status"] == "measured"]
print(("PASS " if not meas else "FAIL ") + "revision_not_prev_run: a rescore of the baseline execution does not measure its applied change")
print(("PASS " if len([c for c in recs() if c["status"] == "open"]) == 1 else "FAIL ")
      + "revision_not_prev_run: a rescore opens no second change")
add("cand", 1, 1, "x3", sc=S2, code=apply_sha, ts="2999-01-01T00:00:00Z")
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
meas = [c for c in recs() if c["status"] == "measured"]
print(("PASS " if len(meas) == 1 and meas[0]["verdict"] == "keep" and meas[0]["noise"] == 0 else "FAIL ")
      + "revision_not_prev_run: a later execution measures it, the rescore adds no noise sample (%s)"
      % [(m.get("verdict"), m.get("noise")) for m in meas])

l3, c3 = os.path.join(d, "l3.jsonl"), os.path.join(d, "c3.jsonl")
def add3(rid, ex, recall, sup=None, sc=S1):
    meta = {"execution_id": ex, "scorer_sha256": sc}
    if sup:
        meta["supersedes_run_id"] = sup
    m = {"codex.class.quoting.recall": recall, "open.codex.class.quoting.recall": recall,
         "sealed.codex.class.quoting.recall": recall}
    eval_runs.append_row(eval_runs.make_row("review-panel", "s", {"review_panel_v": 2}, m, run_id=rid, meta=meta,
                                            gitsha="g"), l3)
add3("p1", "z1", 0.9)
add3("p2", "z2", 0.0)
add3("p1~r", "z1", 0.9, sup="p1", sc=S2)
order = [r["run_id"] for r in fb.review_series(eval_runs.read_rows(l3))[0]]
print(("PASS " if order == ["p1~r", "p2"] else "FAIL ")
      + "revision_not_prev_run: review_series keeps the selection's execution order, a late rescore is not last (%s)" % order)
fb.run(ledger=l3, changes=c3, rules=rules)
opened3 = [json.loads(l) for l in open(c3) if '"status":"open"' in l]
print(("PASS " if [c["baseline_run_id"] for c in opened3] == ["p2"] else "FAIL ")
      + "revision_not_prev_run: the feedback step grades the newest execution, not the late rescore (%s)"
      % [c["baseline_run_id"] for c in opened3])

glob_rules = os.path.join(d, "glob-rules.json")
open(glob_rules, "w").write('{"v":1,"rules":[{"eval":"review-panel","metric":"codex.class.*.recall","threshold":0.5,'
                            '"better":"higher","absent":null,"change":"prompt","target":"scripts/cr/critic-first-pass.sh",'
                            '"critic":"codex","min_gain":0.25}]}')
l2, c2 = os.path.join(d, "l2.jsonl"), os.path.join(d, "c2.jsonl")
def add2(rid, ex, sup=None, sc=S1):
    meta = {"execution_id": ex, "scorer_sha256": sc}
    if sup:
        meta["supersedes_run_id"] = sup
    m = {"open.codex.class.quoting.recall": 0.0, "open.codex.class.logic.recall": 0.1,
         "sealed.codex.class.quoting.recall": 0.0, "sealed.codex.class.logic.recall": 0.1}
    eval_runs.append_row(eval_runs.make_row("review-panel", "s", {"review_panel_v": 2}, m, run_id=rid, meta=meta,
                                            gitsha="g"), l2)
add2("g1", "y1")
fb.run(ledger=l2, changes=c2, rules=glob_rules)
n1 = len([1 for l in open(c2) if '"status":"open"' in l])
add2("g1~r", "y1", sup="g1", sc=S2)
fb.run(ledger=l2, changes=c2, rules=glob_rules)
n2 = len([1 for l in open(c2) if '"status":"open"' in l])
print(("PASS " if (n1, n2) == (1, 1) else "FAIL ")
      + "revision_not_prev_run: a rescore of the newest execution opens no second change under a glob rule with two "
        "metrics past threshold (%d then %d open changes)" % (n1, n2))
EOF
SELOUT="$(python3 -I "$SELPY" "$HERE/lib" "$R6" "$ROOT6" "$APPLY6" 2>&1)"
while IFS= read -r line; do
  case "$line" in PASS*) PASS=$((PASS + 1)); echo "$line";; *) FAIL=$((FAIL + 1)); echo "$line";; esac
done <<<"$SELOUT"

M6PY="$TMP/m6.py"
cat >"$M6PY" <<'EOF'
import json, os, re, sys, tempfile
sys.path.insert(0, sys.argv[1])
import eval_feedback as fb
import eval_runs

repo, ROOT, APPLY, DOCS, MODE, OTHER, MERGE, BOTH = sys.argv[2:10]
S1, S2 = "a" * 64, "b" * 64
COV = {"scored": 4, "critics": {"codex": {"answer": 4}}}
TARGET = "scripts/cr/critic-first-pass.sh"
d = tempfile.mkdtemp()
rules = os.path.join(d, "rules.json")
with open(rules, "w") as fh:
    json.dump({"v": 1, "rules": [
        {"eval": "review-panel", "metric": "codex.class.quoting.recall", "threshold": 0.5, "better": "higher",
         "absent": None, "change": "prompt", "target": TARGET, "critic": "codex", "min_gain": 0.25},
        {"eval": "judge-accuracy", "metric": "class.*.escape_excess", "threshold": 0, "better": "lower",
         "absent": None, "change": "prompt", "target": "docs/handover/judge-brief-template.md", "critic": "judge"}]}, fh)

def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else ": %s" % (detail,)))

def recs(p):
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []

def status(p, s):
    return [c for c in recs(p) if c.get("status") == s]

INELIGIBLE = {"decision_eligible": False, "ineligibility_reasons": ["provenance-reconstructed"]}
ELIGIBLE = {"decision_eligible": True, "ineligibility_reasons": []}

def add(ledger, rid, val, code, ts, ex=None, sup=None, sc=S1, cov=COV, split=True, extra=None):
    m = {"codex.class.quoting.recall": val}
    if split:
        m.update({"open.codex.class.quoting.recall": val, "sealed.codex.class.quoting.recall": val})
    meta = dict({"execution_id": ex or rid, "scorer_sha256": sc, "coverage": cov, "code_under_test_sha": code},
                **(ELIGIBLE if extra is None else extra))
    if sup:
        meta["supersedes_run_id"] = sup
    r = eval_runs.make_row("review-panel", "s", {"review_panel_v": 2}, m, run_id=rid, meta=meta, gitsha="g")
    r["ts"] = ts
    eval_runs.append_row(r, ledger)

def proposal(name, base_code=ROOT, bases=2, base_extra=None):
    ledger, changes = os.path.join(d, name + ".jsonl"), os.path.join(d, name + "-c.jsonl")
    for i in range(1, bases + 1):
        add(ledger, "%s-b%d" % (name, i), 0, base_code, "2026-01-0%dT00:00:00Z" % i, extra=base_extra)
    fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
    opened = status(changes, "open")
    return ledger, changes, opened[0]["id"] if opened else None

def refused(name, cid, commit, changes, want):
    try:
        fb.apply_review(cid, commit, changes, repo=repo)
    except ValueError as e:
        check(name, want in str(e), "refusal %r lacks %r" % (str(e), want))
        return
    except Exception as e:
        check(name, False, "raised %r, not a refusal" % e)
        return
    check(name, False, "the receipt was written")

LATER = "2999-01-01T00:00:00Z"

ledger, changes, cid = proposal("noreceipt")
check("M6 fixture: the proposal opens", cid is not None)
add(ledger, "noreceipt-c", 1, APPLY, LATER)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
check("no_receipt_no_measurement: a better run after the change, but no receipt: nothing measured",
      not status(changes, "measured"), status(changes, "measured"))
ledger, changes, cid = proposal("unchanged")
add(ledger, "unchanged-c", 1, ROOT, LATER)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
check("no_receipt_no_measurement: the unchanged-version synthetic improvement yields no keep",
      not [c for c in recs(changes) if c.get("verdict") == "keep"], recs(changes))

ledger, changes, cid = proposal("ident")
refused("identical_effective_hash_refused: a commit outside the behaviour set", cid, DOCS, changes, "no effective change")
refused("identical_effective_hash_refused: a mode-only change of the target", cid, MODE, changes, "no effective change")
check("identical_effective_hash_refused: no receipt written", not status(changes, "applied"), status(changes, "applied"))

refused("wrong_target_refused: a commit that changes another behaviour path", cid, OTHER, changes,
        "does not change the proposal's target")
cr = fb.envelope(id="cr:coderabbit.class.logic.recall", eval="review-panel", metric="coderabbit.class.logic.recall",
                 status="open", value=0.0, threshold=0.5, better="higher", absent=None, change="cr-config",
                 target=".coderabbit.yaml", baseline_run_id="ident-b2", confighash="c", critic="coderabbit", per=None,
                 min_gain=None)
fr = fb.envelope(id="fr:over_deny:x", eval="friction", metric="over_deny:x", status="open", value=1, threshold=0,
                 better="lower", absent=0, change="learning", target="shell-and-gate-traps.md", baseline_run_id="f",
                 confighash="c", critic=None, per=None, min_gain=None)
fb.append(changes, cr)
fb.append(changes, fr)
refused("wrong_target_refused: a target outside the measured behaviour set is unsupported", cr["id"], APPLY, changes,
        "outside the measured behaviour set")
refused("other_eval_unchanged: a receipt binds a review-panel change only", fr["id"], APPLY, changes, "review-panel")
refused("a merge commit is an ambiguous parent", cid, MERGE, changes, "parent")
refused("a root commit has no parent", cid, ROOT, changes, "parent")
refused("a commit that is not in the repo is refused", cid, "0" * 40, changes, "not a commit")
refused("an id with no open change is refused", "no-such-id", APPLY, changes, "no open change")
check("refusals write no receipt", not status(changes, "applied"), status(changes, "applied"))

rec = fb.apply_review(cid, APPLY[:12], changes, repo=repo)
check("receipt: one applied record", len(status(changes, "applied")) == 1)
check("receipt: the full commit sha, resolved from an abbreviation", rec.get("commit") == APPLY, rec.get("commit"))
check("receipt: before and after cbs_hash are distinct 64-hex digests",
      all(re.match(r"^[0-9a-f]{64}$", str(rec.get(k))) for k in ("before_cbs_hash", "after_cbs_hash"))
      and rec["before_cbs_hash"] != rec["after_cbs_hash"], rec)
check("receipt: target_paths are the behaviour paths the commit changed, the note outside it left off",
      rec.get("target_paths") == [TARGET], rec.get("target_paths"))
check("receipt: a 64-hex diff_sha256", bool(re.match(r"^[0-9a-f]{64}$", str(rec.get("diff_sha256")))), rec)
check("receipt: applied_at is the receipt's own time", rec.get("applied_at") == rec.get("ts") and rec.get("applied_at"), rec)
refused("a second receipt for one change is refused", cid, APPLY, changes, "already")

ledger, changes, cid = proposal("rescore")
add(ledger, "rescore-pre", 1, APPLY, "2026-01-03T00:00:00Z")
fb.apply_review(cid, APPLY, changes, repo=repo)
add(ledger, "rescore-pre~r", 1, APPLY, LATER, ex="rescore-pre", sup="rescore-pre", sc=S2)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
check("rescore_old_execution_not_after_apply: a rescore, written after the receipt, of an execution run before it",
      not status(changes, "measured"), status(changes, "measured"))
ledger, changes, cid = proposal("rebase")
fb.apply_review(cid, APPLY, changes, repo=repo)
add(ledger, "rebase-b2~r", 1, ROOT, LATER, ex="rebase-b2", sup="rebase-b2", sc=S2)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
check("rescore_old_execution_not_after_apply: a rescore of the baseline execution is not a treatment result",
      not status(changes, "measured"), status(changes, "measured"))
ledger, changes, cid = proposal("lone")
fb.apply_review(cid, APPLY, changes, repo=repo)
add(ledger, "lone~r", 1, APPLY, LATER, ex="lone-x", sup="lone-gone")
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
check("a revision whose source execution is not in the ledger has no known run time: nothing measured",
      not status(changes, "measured"), status(changes, "measured"))

for name, kw, want in (("scorer", {"sc": S2}, "scorer"),
                       ("coverage", {"cov": {"scored": 4, "critics": {"codex": {"answer": 3}}}}, "participation"),
                       ("nosplit", {"split": False}, "split")):
    ledger, changes, cid = proposal("inc-" + name)
    fb.apply_review(cid, APPLY, changes, repo=repo)
    add(ledger, "inc-%s-c" % name, 1, APPLY, LATER, **kw)
    fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
    m = status(changes, "measured")
    check("incomparable_protocol_inconclusive: another %s is inconclusive, never keep" % name,
          len(m) == 1 and m[0].get("verdict") == "inconclusive" and want in (m[0].get("reason") or ""), m)
ledger, changes, cid = proposal("inc-base", base_code=OTHER)
try:
    fb.apply_review(cid, APPLY, changes, repo=repo)
except ValueError as e:
    check("M6 fixture: a receipt for a baseline at another version", False, e)
add(ledger, "inc-base-c", 1, APPLY, LATER)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
m = status(changes, "measured")
check("incomparable_protocol_inconclusive: a baseline not at the receipt's parent version is inconclusive",
      len(m) == 1 and m[0].get("verdict") == "inconclusive" and "baseline" in (m[0].get("reason") or ""), m)

ledger, changes, cid = proposal("valid")
rec = fb.apply_review(cid, APPLY, changes, repo=repo)
add(ledger, "valid-old", 1, ROOT, LATER)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
check("a later run that is not at the applied version measures nothing", not status(changes, "measured"),
      status(changes, "measured"))
add(ledger, "valid-c", 1, APPLY, "2999-01-02T00:00:00Z")
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
m = status(changes, "measured")
check("valid_applied_after_run_measured: keep", len(m) == 1 and m[0].get("verdict") == "keep", m)
check("valid_applied_after_run_measured: the record names the receipt's commit and after hash",
      m and m[0].get("applied_commit") == APPLY and m[0].get("after_cbs_hash") == rec["after_cbs_hash"], m)
check("valid_applied_after_run_measured: the applied run is the one measured", m and m[0].get("after_run_id") == "valid-c", m)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
check("a measured change is not measured again", len(status(changes, "measured")) == 1)
ledger, changes, cid = proposal("revert")
fb.apply_review(cid, APPLY, changes, repo=repo)
add(ledger, "revert-c", 0, APPLY, LATER)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
m = status(changes, "measured")
check("valid_applied_after_run_measured: no gain is revert", len(m) == 1 and m[0].get("verdict") == "revert", m)

def one_inconclusive(name, want):
    m = status(changes, "measured")
    check(name, len(m) == 1 and m[0].get("verdict") == "inconclusive" and want in (m[0].get("reason") or ""), m)

ledger, changes, cid = proposal("onebase", bases=1)
fb.apply_review(cid, APPLY, changes, repo=repo)
add(ledger, "onebase-c", 1, APPLY, LATER)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
one_inconclusive("insufficient data is inconclusive, not revert: one baseline run leaves the noise unmeasured",
                 "noise unmeasured")
ledger, changes, cid = proposal("nosealed")
fb.apply_review(cid, APPLY, changes, repo=repo)
r = eval_runs.make_row("review-panel", "s", {"review_panel_v": 2},
                       {"codex.class.quoting.recall": 1, "open.codex.class.quoting.recall": 1,
                        "sealed.codex.clean_scored": 0},
                       run_id="nosealed-c", gitsha="g",
                       meta=dict(ELIGIBLE, execution_id="nosealed-c", scorer_sha256=S1, coverage=COV,
                                 code_under_test_sha=APPLY))
r["ts"] = LATER
eval_runs.append_row(r, ledger)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
one_inconclusive("insufficient data is inconclusive, not revert: an unmeasured test half", "test half unmeasured")

ledger, changes, cid = proposal("inelig-new")
fb.apply_review(cid, APPLY, changes, repo=repo)
add(ledger, "inelig-new-c", 1, APPLY, LATER, extra=INELIGIBLE)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
one_inconclusive("an applied run that is not decision-eligible, with a better metric, is inconclusive with its reasons",
                 "provenance-reconstructed")
ledger, changes, cid = proposal("inelig-base", base_extra=INELIGIBLE)
fb.apply_review(cid, APPLY, changes, repo=repo)
add(ledger, "inelig-base-c", 1, APPLY, LATER)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
one_inconclusive("a baseline run that is not decision-eligible makes the measurement inconclusive",
                 "provenance-reconstructed")

ledger, changes = os.path.join(d, "noise-inelig.jsonl"), os.path.join(d, "noise-inelig-c.jsonl")
add(ledger, "noise-inelig-b1", 0, ROOT, "2026-01-01T00:00:00Z", extra=INELIGIBLE)
add(ledger, "noise-inelig-b2", 0, ROOT, "2026-01-02T00:00:00Z")
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
fb.apply_review(status(changes, "open")[0]["id"], APPLY, changes, repo=repo)
add(ledger, "noise-inelig-c", 1, APPLY, LATER)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
one_inconclusive("an ineligible earlier run is no noise sample: with it left out the noise is unmeasured",
                 "noise unmeasured")
ledger, changes, cid = proposal("unrecorded")
fb.apply_review(cid, APPLY, changes, repo=repo)
add(ledger, "unrecorded-c", 1, APPLY, LATER, extra={})
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
one_inconclusive("an applied run with no recorded eligibility is inconclusive", "eligibility unrecorded")

def receipt(cid, commit, parent, before_at, after_at, paths=None):
    true_paths, digest = fb.behaviour_diff(repo, parent, commit)
    return fb.envelope(id=cid, eval="review-panel", metric="codex.class.quoting.recall", status="applied",
                       applied_at="2026-06-01T00:00:00Z", before_cbs_hash=fb._score().cbs_hash(repo, before_at),
                       after_cbs_hash=fb._score().cbs_hash(repo, after_at), commit=commit,
                       target_paths=paths or true_paths, diff_sha256=digest)

ledger, changes, cid = proposal("rehash", base_code=OTHER)
fb.append(changes, receipt(cid, APPLY, ROOT, OTHER, BOTH))
add(ledger, "rehash-c", 1, BOTH, LATER)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
one_inconclusive("a receipt with its commit's true paths and digest but another commit's versions is inconclusive",
                 "before and after versions")
ledger, changes, cid = proposal("twopath", base_code=OTHER)
fb.append(changes, receipt(cid, BOTH, OTHER, OTHER, BOTH))
add(ledger, "twopath-c", 1, BOTH, LATER)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
one_inconclusive("a true two-path receipt Git reproduces is still not exactly the proposal's target: inconclusive",
                 "not exactly the proposal's target")

ledger, changes, cid = proposal("forged")
fb.append(changes, fb.envelope(id=cid, eval="review-panel", metric="codex.class.quoting.recall", status="applied",
                               applied_at="2026-06-01T00:00:00Z", before_cbs_hash=fb._score().cbs_hash(repo, ROOT),
                               after_cbs_hash=fb._score().cbs_hash(repo, APPLY), commit=OTHER,
                               target_paths=[TARGET], diff_sha256="0" * 64))
add(ledger, "forged-c", 1, APPLY, LATER)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
one_inconclusive("a receipt whose hashes Git does not reproduce at its commit is inconclusive, never keep",
                 "does not match Git")
ledger, changes, cid = proposal("narrowed", base_code=OTHER)
fb.append(changes, fb.envelope(id=cid, eval="review-panel", metric="codex.class.quoting.recall", status="applied",
                               applied_at="2026-06-01T00:00:00Z", before_cbs_hash=fb._score().cbs_hash(repo, OTHER),
                               after_cbs_hash=fb._score().cbs_hash(repo, BOTH), commit=BOTH,
                               target_paths=[TARGET], diff_sha256="0" * 64))
add(ledger, "narrowed-c", 1, BOTH, LATER)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
one_inconclusive("a hand-written receipt that narrows a two-path commit to the target is inconclusive, never keep",
                 "does not match Git")
ledger, changes, cid = proposal("wide")
fb.apply_review(cid, APPLY, changes, repo=repo)
with open(changes) as fh:
    lines = fh.read().splitlines()
with open(changes, "w") as fh:
    for ln in lines:
        row = json.loads(ln)
        if row.get("status") == "applied":
            row["target_paths"] = [TARGET, "scripts/cr/critic-panel.sh"]
        fh.write(json.dumps(row) + "\n")
add(ledger, "wide-c", 1, APPLY, LATER)
fb.run(ledger=ledger, changes=changes, rules=rules, repo=repo)
one_inconclusive("a receipt whose target_paths are not exactly the proposal's target is inconclusive", "target")
ledger, changes, cid = proposal("both")
refused("a commit that also changes another behaviour path is refused", cid, BOTH, changes, "beyond the proposal's target")

jl, jc = os.path.join(d, "judge.jsonl"), os.path.join(d, "judge-c.jsonl")
for i, v in enumerate((0.04, 0.01)):
    eval_runs.append_row(eval_runs.make_row("judge-accuracy", "s", {"judge_accuracy_v": 1, "days": 28},
                                            {"class.guard.escape_excess": v}, run_id="j%d" % i, gitsha="g"), jl)
    fb.run(ledger=jl, changes=jc, rules=rules, repo=repo)
m = status(jc, "measured")
check("other_eval_unchanged: a judge change is measured as before, with no receipt",
      len(m) == 1 and m[0].get("verdict") == "improved" and "applied_commit" not in m[0], m)
EOF
M6OUT="$(python3 -I "$M6PY" "$HERE/lib" "$R6" "$ROOT6" "$APPLY6" "$DOCS6" "$MODE6" "$OTHER6" "$MERGE6" "$BOTH6" 2>&1)"
while IFS= read -r line; do
  case "$line" in PASS*) PASS=$((PASS + 1)); echo "$line";; *) FAIL=$((FAIL + 1)); echo "$line";; esac
done <<<"$M6OUT"

AC="$TMP/apply-cli.jsonl"
python3 -I - "$HERE/lib" "$AC" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import eval_feedback as fb
fb.append(sys.argv[2], fb.envelope(id="cli:codex.class.quoting.recall", eval="review-panel",
          metric="codex.class.quoting.recall", status="open", value=0.0, threshold=0.5, better="higher", absent=None,
          change="prompt", target="scripts/cr/critic-first-pass.sh", baseline_run_id="cli", confighash="c",
          critic="codex", per=None, min_gain=None))
PY
python3 -I "$FB" apply-review --id cli:codex.class.quoting.recall --commit "$APPLY6" --repo "$R6" >/dev/null 2>&1
eq "apply-review: refused without an explicit --changes ledger" "$?" "2"
python3 -I "$FB" apply-review --id cli:codex.class.quoting.recall --commit "$APPLY6" --repo "$R6" --changes "$AC" \
  --after-cbs-hash "$(printf 'f%.0s' $(seq 64))" >/dev/null 2>&1
eq "apply-review: a caller-supplied hash is not an option" "$?" "2"
out="$(python3 -I "$FB" apply-review --id cli:codex.class.quoting.recall --commit "$DOCS6" --repo "$R6" --changes "$AC" 2>&1)"; rc=$?
eq "apply-review: a refused application exits 2" "$rc" "2"
has "apply-review: the refusal says why" "$out" "no effective change"
eq "apply-review: refusals write nothing" "$(rows "$AC")" "1"
out="$(python3 -I "$FB" apply-review --id cli:codex.class.quoting.recall --commit "$APPLY6" --repo "$R6" --changes "$AC" 2>&1)"; rc=$?
eq "apply-review: exit 0" "$rc" "0"
has "apply-review: prints the receipt" "$out" "applied review-panel codex.class.quoting.recall commit ${APPLY6:0:12}"
eq "apply-review: one applied record appended" "$(field "$AC" 1 status)" "applied"
eq "apply-review: the fixture repo's HEAD is unchanged" "$(gitc6 rev-parse HEAD)" "$MERGE6"

eq "score.py's panel check calls gate_side, not a copy of its row selection" \
  "$(grep -c 'eval_feedback.gate_side(rows' "$HERE/review-panel/score.py")" "1"

echo "eval-feedback: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
