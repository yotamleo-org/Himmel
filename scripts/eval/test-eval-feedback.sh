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
  --config-json '{"friction_v":1,"days":7}' --metrics-json "{\"refusals\":1000,\"over_deny\":500,\"$CLS\":500}"
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
has "the delivered line names the metric and topic" "$(cat "$D/inbox.md" 2>/dev/null)" "eval/friction $CLS value=0.5 threshold=0.05 topic=shell-and-gate-traps.md"

# --- only a --live review writes the inbox line, once per opened change ---------------------------------
E="$TMP/review-live"; mkdir -p "$E"
: >"$E/ledger.jsonl"
ok "live review row" python3 -I "$RUNS" append --ledger "$E/runs.jsonl" --eval friction --source s \
  --config-json '{"friction_v":1,"days":7}' --metrics-json "{\"refusals\":1000,\"over_deny\":500,\"$CLS\":500}"
for i in 1 2; do
  HIMMEL_EVAL_RUNS_LEDGER="$E/runs.jsonl" HIMMEL_EVAL_CHANGES_LEDGER="$E/changes.jsonl" FAILURE_REVIEW_FRICTION_CMD="" \
    JIRA_PROJECT_KEY=HIMMEL python3 "$FRV" --ledger "$E/ledger.jsonl" --state "$E/state.json" --log "$E/log.jsonl" \
    --inbox "$E/inbox.md" --out-dir "$E/out" --now 2026-10-07T12:00:00Z --notify-cmd true --live >"$E/run$i.out" 2>&1
  eq "live review $i: exit 0" "$?" "0"
  eq "live review $i: exactly one memory-inbox line" "$(rows "$E/inbox.md")" "1"
done
has "live review: the line names the metric and topic" "$(cat "$E/inbox.md" 2>/dev/null)" "eval/friction $CLS value=0.5 threshold=0.05 topic=shell-and-gate-traps.md"

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
# vol <ledger> <refusals> <over-denials>: one friction row
vol() { python3 -I "$RUNS" append --ledger "$1" --eval friction --source s --config-json '{"friction_v":1,"days":7}' \
  --metrics-json "{\"refusals\":$2,\"$CLS\":$3}" >/dev/null 2>&1; }
ok "volume row" vol "$V/runs.jsonl" 10000 300
ok "volume feedback" python3 -I "$FB" run --eval friction --ledger "$V/runs.jsonl" --changes "$V/c.jsonl" --rules "$HERE/feedback-rules.json"
eq "per: 300 over-denials in 10000 refusals (3 %) opens no change under the shipped rule" "$(rows "$V/c.jsonl")" "0"
ok "rate row" vol "$V/runs.jsonl" 1000 300
ok "rate feedback" python3 -I "$FB" run --eval friction --ledger "$V/runs.jsonl" --changes "$V/c.jsonl" --rules "$HERE/feedback-rules.json"
eq "per: the same 300 in 1000 refusals (30 %) opens one change" "$(rows "$V/c.jsonl")" "1"
eq "per: the change's value is the rate" "$(field "$V/c.jsonl" 0 value)" "0.3"
eq "per: the change names its denominator" "$(field "$V/c.jsonl" 0 per)" "refusals"
ok "volume-up row" vol "$V/runs.jsonl" 10000 300
ok "volume-up measure" python3 -I "$FB" run --eval friction --ledger "$V/runs.jsonl" --changes "$V/c.jsonl" --rules "$HERE/feedback-rules.json"
eq "per: the re-measure reads the rate too" "$(field "$V/c.jsonl" 1 after)" "0.03"

# --- a sealed split: rules tune on the open half only, and never read the sealed half ---------------
# A split row carries open.<metric> and sealed.<metric> beside the whole-set metric (score.py).
S="$TMP/sealed"; mkdir -p "$S"
cat >"$S/rules.json" <<'EOF'
{"v": 1, "rules": [{"eval": "review-panel", "metric": "codex.class.*.recall", "threshold": 0.5, "better": "higher",
  "absent": null, "change": "prompt", "target": "scripts/cr/critic-first-pass.sh", "critic": "codex", "min_gain": 0.25}]}
EOF
# split <ledger> <whole> <open> <sealed>: one review-panel row for the quoting class
split() { python3 -I "$RUNS" append --ledger "$1" --eval review-panel --source s --config-json '{"review_panel_v":2}' \
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
ok "keep base 1" split "$T/up-flat.jsonl" 0 0 0
ok "keep base 2" split "$T/up-flat.jsonl" 0 0 0
ok "keep open" python3 -I "$FB" run --ledger "$T/up-flat.jsonl" --changes "$T/up-flat-c.jsonl" --rules "$S/rules.json"
ok "train-up/test-flat row" split "$T/up-flat.jsonl" 0.5 1 0
ok "train-up/test-flat measure" python3 -I "$FB" run --ledger "$T/up-flat.jsonl" --changes "$T/up-flat-c.jsonl" --rules "$S/rules.json"
eq "keep rule: a train-up/test-flat change is reverted" "$(field "$T/up-flat-c.jsonl" 1 verdict)" "revert"
has "keep rule: the revert says why" "$(field "$T/up-flat-c.jsonl" 1 reason)" "test"
eq "keep rule: the test half is recorded" "$(field "$T/up-flat-c.jsonl" 1 test_after)" "0"
ok "both-up base 1" split "$T/both.jsonl" 0 0 0
ok "both-up base 2" split "$T/both.jsonl" 0 0 0
ok "both-up open" python3 -I "$FB" run --ledger "$T/both.jsonl" --changes "$T/both-c.jsonl" --rules "$S/rules.json"
ok "both-up row" split "$T/both.jsonl" 1 1 1
ok "both-up measure" python3 -I "$FB" run --ledger "$T/both.jsonl" --changes "$T/both-c.jsonl" --rules "$S/rules.json"
eq "keep rule: train and test both up, no noise: kept" "$(field "$T/both-c.jsonl" 1 verdict)" "keep"
eq "keep rule: the noise is the spread of the runs before the change" "$(field "$T/both-c.jsonl" 1 noise)" "0"
ok "noisy base 1" split "$T/noisy.jsonl" 0 0.5 0
ok "noisy base 2" split "$T/noisy.jsonl" 0 0 0
ok "noisy open" python3 -I "$FB" run --ledger "$T/noisy.jsonl" --changes "$T/noisy-c.jsonl" --rules "$S/rules.json"
ok "noisy row" split "$T/noisy.jsonl" 1 1 1
ok "noisy measure" python3 -I "$FB" run --ledger "$T/noisy.jsonl" --changes "$T/noisy-c.jsonl" --rules "$S/rules.json"
eq "keep rule: run-to-run noise (0.5) not below min_gain (0.25) is not kept" "$(field "$T/noisy-c.jsonl" 1 verdict)" "revert"
has "keep rule: the noisy revert names the noise" "$(field "$T/noisy-c.jsonl" 1 reason)" "noise"
ok "one-run base" split "$T/one.jsonl" 0 0 0
ok "one-run open" python3 -I "$FB" run --ledger "$T/one.jsonl" --changes "$T/one-c.jsonl" --rules "$S/rules.json"
ok "one-run row" split "$T/one.jsonl" 1 1 1
ok "one-run measure" python3 -I "$FB" run --ledger "$T/one.jsonl" --changes "$T/one-c.jsonl" --rules "$S/rules.json"
eq "keep rule: one run before the change leaves the noise unmeasured: not kept" "$(field "$T/one-c.jsonl" 1 verdict)" "revert"
# A rule with absent=0 must not stand in for a sealed half the row never measured.
cat >"$T/absent-rules.json" <<'EOF'
{"v": 1, "rules": [{"eval": "review-panel", "metric": "codex.fp_rate", "threshold": 0.2, "better": "lower",
  "absent": 0, "change": "prompt", "target": "scripts/cr/critic-first-pass.sh", "critic": "codex", "min_gain": 0.1}]}
EOF
fp() { python3 -I "$RUNS" append --ledger "$1" --eval review-panel --source s --config-json '{"review_panel_v":2}' \
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
sed 's/"min_gain": 0.25/"min_gain": 0/' "$S/rules.json" >"$T/zero-rules.json"
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

echo "eval-feedback: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
