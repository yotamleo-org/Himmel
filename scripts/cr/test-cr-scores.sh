#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C intentional in check() and final assert
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

HERE="$(cd "$(dirname "$0")" && pwd)"; CS="$HERE/cr-scores.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; L="$tmp/ledger.jsonl"
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { grepq "$2" -F "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
not_contains() { grepq "$2" -F "$3" && { echo "FAIL - $1: output must NOT contain [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }

# ---------------------------------------------------------------------------
# Fixture: two models (alpha, beta) with known score distributions
# alpha: 12 findings: 8 agreed, 2 disproved, 1 conflict, 1 unaddressed
#        -> agreed%= 8/12 = 66.7%  (above 40 threshold -> no drop advice)
#        avail: 3 ok, 1 unavailable -> availability%= 3/4 = 75%
# beta:  11 findings: 3 agreed, 5 disproved, 2 conflict, 1 unaddressed
#        -> agreed%= 3/11 = 27.3%  (below 40 threshold, >=10 findings -> drop advice)
#        avail: 2 ok, 0 unavailable -> availability%= 2/2 = 100%
# ---------------------------------------------------------------------------
# We use 3 distinct heads (H1, H2, H3) to also exercise the window logic.

# alpha findings (H1/H2/H3) + beta findings (H1/H2/H3) + avail rows — one block
{
  # alpha: 8 agreed, 2 disproved, 1 conflict, 1 unaddressed (total 12)
  echo '{"kind":"finding","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H1","model":"alpha","finding_id":"a-1","severity":"critical","file":"f","line":1,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:01Z","branch":"b","head":"H1","model":"alpha","finding_id":"a-2","severity":"major","file":"f","line":2,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:02Z","branch":"b","head":"H1","model":"alpha","finding_id":"a-3","severity":"minor","file":"f","line":3,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:03Z","branch":"b","head":"H1","model":"alpha","finding_id":"a-4","severity":"minor","file":"f","line":4,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:04Z","branch":"b","head":"H2","model":"alpha","finding_id":"a-5","severity":"major","file":"f","line":5,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:05Z","branch":"b","head":"H2","model":"alpha","finding_id":"a-6","severity":"major","file":"f","line":6,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:06Z","branch":"b","head":"H2","model":"alpha","finding_id":"a-7","severity":"critical","file":"f","line":7,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:07Z","branch":"b","head":"H2","model":"alpha","finding_id":"a-8","severity":"minor","file":"f","line":8,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:08Z","branch":"b","head":"H3","model":"alpha","finding_id":"a-9","severity":"major","file":"f","line":9,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:09Z","branch":"b","head":"H3","model":"alpha","finding_id":"a-10","severity":"minor","file":"f","line":10,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:10Z","branch":"b","head":"H3","model":"alpha","finding_id":"a-11","severity":"critical","file":"f","line":11,"verdict":"conflict"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:11Z","branch":"b","head":"H3","model":"alpha","finding_id":"a-12","severity":"minor","file":"f","line":12,"verdict":"unaddressed"}'
  # beta: 3 agreed, 5 disproved, 2 conflict, 1 unaddressed (total 11)
  echo '{"kind":"finding","ts":"2026-01-01T00:01:00Z","branch":"b","head":"H1","model":"beta","finding_id":"b-1","severity":"critical","file":"f","line":1,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:01Z","branch":"b","head":"H1","model":"beta","finding_id":"b-2","severity":"major","file":"f","line":2,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:02Z","branch":"b","head":"H1","model":"beta","finding_id":"b-3","severity":"minor","file":"f","line":3,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:03Z","branch":"b","head":"H2","model":"beta","finding_id":"b-4","severity":"major","file":"f","line":4,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:04Z","branch":"b","head":"H2","model":"beta","finding_id":"b-5","severity":"minor","file":"f","line":5,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:05Z","branch":"b","head":"H2","model":"beta","finding_id":"b-6","severity":"critical","file":"f","line":6,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:06Z","branch":"b","head":"H2","model":"beta","finding_id":"b-7","severity":"major","file":"f","line":7,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:07Z","branch":"b","head":"H3","model":"beta","finding_id":"b-8","severity":"minor","file":"f","line":8,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:08Z","branch":"b","head":"H3","model":"beta","finding_id":"b-9","severity":"critical","file":"f","line":9,"verdict":"conflict"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:09Z","branch":"b","head":"H3","model":"beta","finding_id":"b-10","severity":"major","file":"f","line":10,"verdict":"conflict"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:10Z","branch":"b","head":"H3","model":"beta","finding_id":"b-11","severity":"minor","file":"f","line":11,"verdict":"unaddressed"}'
  # avail: alpha 3 ok + 1 unavailable; beta 2 ok
  echo '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H1","model":"alpha","status":"ok"}'
  echo '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H2","model":"alpha","status":"ok"}'
  echo '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H3","model":"alpha","status":"unavailable"}'
  echo '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H4","model":"alpha","status":"ok"}'
  echo '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H1","model":"beta","status":"ok"}'
  echo '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H2","model":"beta","status":"ok"}'
  # usage: codex 2 calls (est_total 1200 + 600 = 1800), alpha 1 call (400).
  # ts are LATER than every other record so per-head ts minima (and thus the window
  # ordering exercised by test 8) are unchanged by these rows.
  echo '{"kind":"usage","ts":"2026-01-01T00:02:00Z","branch":"b","head":"H1","model":"codex","prompt_chars":4000,"response_chars":800,"est_prompt_tokens":1000,"est_completion_tokens":200,"est_total_tokens":1200,"estimated":true}'
  echo '{"kind":"usage","ts":"2026-01-01T00:02:01Z","branch":"b","head":"H2","model":"codex","prompt_chars":2000,"response_chars":400,"est_prompt_tokens":500,"est_completion_tokens":100,"est_total_tokens":600,"estimated":true}'
  echo '{"kind":"usage","ts":"2026-01-01T00:02:02Z","branch":"b","head":"H1","model":"alpha","prompt_chars":1200,"response_chars":400,"est_prompt_tokens":300,"est_completion_tokens":100,"est_total_tokens":400,"estimated":true}'
} >> "$L"

# ── Run the script and capture output ──────────────────────────────────────
out="$(CR_LEDGER="$L" CR_SCORES_DROP_BELOW=40 CR_SCORES_MIN_N=10 bash "$CS" 2>&1)"

# 1. Per-model agreed% appears in output
# alpha: 8/12 = 66.7% -> rounds to 67%
contains "alpha agreed% contains 67" "$out" "67"
# beta: 3/11 = 27.3% -> look for "27" in beta row
contains "beta agreed% contains 27" "$out" "27"

# 2. Availability %: alpha= 3ok/(3ok+1unavail)=75%; beta=2ok/2ok=100%
contains "alpha avail% contains 75" "$out" "75"
contains "beta avail% contains 100" "$out" "100"

# 2b. Provenance banner: the ledger is machine-local scratch, so the
#     scorecard must say so, with the row count and the first row's date.
contains "banner says machine-local" "$out" "machine-local"
contains "banner names the ledger path" "$out" "ledger: $L"
contains "banner counts rows" "$out" "$(wc -l < "$L" | tr -d ' ') row(s)"
contains "banner gives the first row date" "$out" "since 2026-01-01"
bb_out="$(CR_LEDGER="$L" bash "$CS" --by-branch 2>&1)"
contains "by-branch carries the banner too" "$bb_out" "machine-local"

# 3. No automatic removal advice: beta is 27% over 11 findings on one PR, which
#    is thin evidence, and alpha/beta are not configured reviewers either.
not_contains "no drop advice for beta" "$out" "consider dropping beta"
contains "the all-time table is labelled history" "$out" "=== History: all-time"

# 4. Drop advice does NOT fire for alpha (66% >= 40 threshold)
not_contains "no drop advice for alpha" "$out" "consider dropping alpha"

# 5. Empty ledger -> friendly message + exit 0
empty="$tmp/empty.jsonl"
touch "$empty"
empty_out="$(CR_LEDGER="$empty" bash "$CS" 2>&1)"
empty_rc=$?
check "empty ledger exit 0" "$empty_rc" "0"
contains "empty ledger friendly message" "$empty_out" "no critic scores"
contains "empty ledger says history may be gone" "$empty_out" "machine-local"

# 6. Missing ledger -> friendly message + exit 0 (treated like empty)
missing_out="$(CR_LEDGER="$tmp/nonexistent.jsonl" bash "$CS" 2>&1)"
missing_rc=$?
check "missing ledger exit 0" "$missing_rc" "0"
contains "missing ledger friendly message" "$missing_out" "no critic scores"

# 7. Below-threshold: a model with 9 findings and low agreed% should NOT get drop advice
#    (CR_SCORES_MIN_N=10 -> need >=10 findings)
L2="$tmp/small.jsonl"
for i in 1 2 3 4 5 6 7 8 9; do
  echo "{\"kind\":\"finding\",\"ts\":\"2026-01-01T00:00:0${i}Z\",\"branch\":\"b\",\"head\":\"H1\",\"model\":\"gamma\",\"finding_id\":\"g-${i}\",\"severity\":\"minor\",\"file\":\"f\",\"line\":${i},\"verdict\":\"disproved\"}" >> "$L2"
done
small_out="$(CR_LEDGER="$L2" CR_SCORES_DROP_BELOW=40 CR_SCORES_MIN_N=10 bash "$CS" 2>&1)"
not_contains "no drop advice for gamma (below CR_SCORES_MIN_N)" "$small_out" "consider dropping gamma"

# 8. Window narrowing: --window 2 uses only the last 2 distinct heads.
#    The fixture has 4 distinct heads in findings+avail (H1-H4); last 2 = H3, H4.
#    Alpha has findings only in H3 (4 findings) and none in H4 -> windowed total=4.
#    All-time alpha total is 12. The two tables must show different totals.
#    Both "4" (windowed) and "12" (all-time) must appear in the combined output.
win_out="$(CR_LEDGER="$L" CR_SCORES_DROP_BELOW=40 CR_SCORES_MIN_N=10 bash "$CS" --window 2 2>&1)"
contains "window section header present" "$win_out" "Last-2-PRs"
# All-time alpha total = 12; windowed alpha total = 4 (only H3 has alpha findings in window).
contains "all-time alpha total 12 appears" "$win_out" "12"
# "4" appears in the windowed table (alpha windowed total) proving narrowing occurred.
# We confirm via the agreed% in the windowed section: alpha H3 has 0 agreed -> "0%"
# which differs from all-time alpha 67%. Assert "0%" appears (windowed agreed%).
contains "windowed alpha shows different agreed pct" "$win_out" "0%"

# 9. Usage section: per-model est tokens + cumulative.
contains "usage section header present" "$out" "Usage (estimated tokens"
contains "usage codex row present" "$out" "codex"
contains "usage codex est_total 1800" "$out" "1800"
contains "usage cumulative line (2200 over 3)" "$out" "cumulative: est_total=2200 over 3"

# 9b. A usage-ONLY model (codex has no finding/avail records) must NOT appear as a
#     phantom zero row in the score tables — it should show ONLY in the Usage
#     section. Both score tables + the usage table start a codex line at col 0, so
#     before the fix codex would start 3 lines; after, exactly 1 (the usage row).
check "usage-only model absent from score tables" "$(echo "$out" | grep -c '^codex')" "1"

# 10. No usage section when the ledger has no usage records (output unchanged).
not_contains "no usage section without usage records" "$small_out" "Usage (estimated tokens"

# 11. cr-scores tolerates a usage record MISSING est_* fields (older/hand-edited
#     schema): the Number()||0 guards must render numeric zeros, never NaN.
L3="$tmp/partial-usage.jsonl"
echo '{"kind":"usage","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H1","model":"codex"}' > "$L3"
partial_out="$(CR_LEDGER="$L3" bash "$CS" 2>&1)"
not_contains "partial usage record produces no NaN" "$partial_out" "NaN"
contains "partial usage record cumulative is 0" "$partial_out" "cumulative: est_total=0 over 1"

# ── WS4: artifact/perspective segmenting reader ─────────────────
# Perspective filter: a dedicated single-model ledger so percentages are unambiguous.
L4="$tmp/persp-scores.jsonl"
{
  echo '{"kind":"finding","ts":"2026-02-01T00:00:00Z","branch":"b","head":"MH1","model":"mix","finding_id":"x-1","severity":"major","file":"f","line":1,"verdict":"agreed","artifact":"diff","perspective":"off"}'
  echo '{"kind":"finding","ts":"2026-02-01T00:00:01Z","branch":"b","head":"MH2","model":"mix","finding_id":"x-2","severity":"major","file":"f","line":2,"verdict":"agreed","artifact":"diff","perspective":"off"}'
  echo '{"kind":"finding","ts":"2026-02-01T00:00:02Z","branch":"b","head":"MH3","model":"mix","finding_id":"x-3","severity":"major","file":"f","line":3,"verdict":"agreed","artifact":"diff","perspective":"on"}'
  echo '{"kind":"finding","ts":"2026-02-01T00:00:03Z","branch":"b","head":"MH4","model":"mix","finding_id":"x-4","severity":"major","file":"f","line":4,"verdict":"disproved","artifact":"diff","perspective":"on"}'
} >> "$L4"
mix_all="$(CR_LEDGER="$L4" bash "$CS" 2>&1)"
contains "mix unfiltered agreed 75" "$mix_all" "75%"
mix_on="$(CR_LEDGER="$L4" bash "$CS" --perspective on 2>&1)"
contains "mix perspective-on agreed 50" "$mix_on" "50%"
not_contains "mix perspective-on excludes off records (no 75)" "$mix_on" "75%"
mix_off="$(CR_LEDGER="$L4" bash "$CS" --perspective off 2>&1)"
contains "mix perspective-off agreed 100" "$mix_off" "100%"
# Artifact filter: mixed artifact records, single model.
L5="$tmp/artifact-scores.jsonl"
{
  echo '{"kind":"finding","ts":"2026-02-01T00:00:00Z","branch":"b","head":"AH1","model":"amix","finding_id":"y-1","severity":"major","file":"f","line":1,"verdict":"agreed","artifact":"diff","perspective":"off"}'
  echo '{"kind":"finding","ts":"2026-02-01T00:00:01Z","branch":"b","head":"AH2","model":"amix","finding_id":"y-2","severity":"major","file":"f","line":2,"verdict":"agreed","artifact":"spec","perspective":"off"}'
  echo '{"kind":"finding","ts":"2026-02-01T00:00:02Z","branch":"b","head":"AH3","model":"amix","finding_id":"y-3","severity":"major","file":"f","line":3,"verdict":"disproved","artifact":"spec","perspective":"off"}'
} >> "$L5"
spec_out="$(CR_LEDGER="$L5" bash "$CS" --artifact spec 2>&1)"
contains "artifact-spec agreed 50" "$spec_out" "50%"
# Legacy records (no perspective field) coerce to off: --perspective off shows them, on hides them.
off_legacy="$(CR_LEDGER="$L" bash "$CS" --perspective off 2>&1)"
contains "legacy records coerce to perspective off (alpha 67 present)" "$off_legacy" "67"
on_legacy="$(CR_LEDGER="$L" bash "$CS" --perspective on 2>&1)"
not_contains "legacy records absent from perspective on (no 67)" "$on_legacy" "67"

# ── Unavailability breakdown (additive, reason-capture) ────────
# 12. A reason-less ledger (every fixture used above) must render NO
#     "Unavailability breakdown" section — output stays byte-identical to
#     pre-capture (same precedent as the Usage section: rendered only
#     when the underlying record type is present).
not_contains "no breakdown section on a reason-less ledger" "$out" "Unavailability breakdown"

# 13. A ledger WITH avail.reason fields renders the breakdown table, grouped
#     per (model, reason), and leaves the existing tables untouched.
L6="$tmp/reason-scores.jsonl"
{
  echo '{"kind":"avail","ts":"2026-03-01T00:00:00Z","branch":"b","head":"RH1","model":"glm","status":"ok"}'
  echo '{"kind":"avail","ts":"2026-03-01T00:00:01Z","branch":"b","head":"RH2","model":"glm","status":"unavailable","reason":"quota-5h"}'
  echo '{"kind":"avail","ts":"2026-03-01T00:00:02Z","branch":"b","head":"RH3","model":"glm","status":"unavailable","reason":"quota-5h"}'
  echo '{"kind":"avail","ts":"2026-03-01T00:00:03Z","branch":"b","head":"RH4","model":"glm","status":"unavailable","reason":"auth"}'
  echo '{"kind":"avail","ts":"2026-03-01T00:00:04Z","branch":"b","head":"RH5","model":"codex","status":"unavailable","reason":"timeout"}'
} >> "$L6"
reason_out="$(CR_LEDGER="$L6" bash "$CS" 2>&1)"
contains "breakdown section header present" "$reason_out" "Unavailability breakdown"
contains "breakdown counts glm/quota-5h=2" "$reason_out" "glm                     quota-5h          2"
contains "breakdown counts glm/auth=1" "$reason_out" "glm                     auth              1"
contains "breakdown counts codex/timeout=1" "$reason_out" "codex                   timeout           1"
# The pre-existing avail% table must be untouched by the new reason field
# (glm: 1 ok / 4 total = 25%).
contains "existing avail table unaffected by reason field (glm 25%)" "$reason_out" "25%"

# 14. A record whose reason is an EMPTY string must NOT be counted (mirrors
#     the "absent, not empty" rule enforced by ledger-append.sh).
L7="$tmp/reason-empty.jsonl"
echo '{"kind":"avail","ts":"2026-03-01T00:00:00Z","branch":"b","head":"EH1","model":"m","status":"unavailable","reason":""}' > "$L7"
empty_reason_out="$(CR_LEDGER="$L7" bash "$CS" 2>&1)"
not_contains "empty-string reason does not trigger breakdown section" "$empty_reason_out" "Unavailability breakdown"

# ── --by-branch review spend ──────────────────────────────────
# The claim under test: a call is one `avail` record = one (head, model) pair,
# and rounds are the distinct heads. A branch reviewed over 3 rounds by 2 lanes
# therefore cost 6 calls — the number that was unanswerable before, and the
# reason a fix-then-re-review loop could run twelve rounds unnoticed.
LB="$tmp/by-branch.jsonl"
{
  for h in BH1 BH2 BH3; do
    echo '{"kind":"avail","ts":"2026-04-01T00:00:00Z","branch":"feat/costly","head":"'"$h"'","model":"coderabbit","status":"ok"}'
    echo '{"kind":"avail","ts":"2026-04-01T00:00:00Z","branch":"feat/costly","head":"'"$h"'","model":"codex","status":"ok"}'
  done
  echo '{"kind":"avail","ts":"2026-04-01T00:00:00Z","branch":"feat/cheap","head":"CH1","model":"codex","status":"unavailable","reason":"timeout"}'
  echo '{"kind":"finding","ts":"2026-04-01T00:00:00Z","branch":"feat/costly","head":"BH1","model":"codex","finding_id":"codex-1","severity":"imp","file":"f","line":1,"verdict":"agreed"}'
  echo '{"kind":"usage","ts":"2026-04-01T00:00:00Z","branch":"feat/costly","head":"BH1","model":"codex","est_total_tokens":4242}'
} > "$LB"
bb_out="$(CR_LEDGER="$LB" bash "$CS" --by-branch 2>&1)"
contains "by-branch reports the costly branch" "$bb_out" "feat/costly"
contains "by-branch counts one call per (head, model)" "$bb_out" "3 round(s), 6 critic call(s), 1 finding(s) recorded"
contains "by-branch counts a FAILED call as spend too" "$bb_out" "1 round(s), 1 critic call(s), 0 finding(s) recorded"
contains "by-branch carries the token estimate" "$bb_out" "4242"
contains "by-branch names the most expensive branch" "$bb_out" "Most expensive branch: feat/costly"

# A branch filter scopes the report and drops the cross-branch superlative.
bb_one="$(CR_LEDGER="$LB" bash "$CS" --by-branch feat/cheap 2>&1)"
contains "branch filter keeps the requested branch" "$bb_one" "feat/cheap"
not_contains "branch filter excludes other branches" "$bb_one" "feat/costly"
not_contains "branch filter drops the cross-branch superlative" "$bb_one" "Most expensive branch"

# An unknown branch is an explicit no-data message, not an empty table.
bb_none="$(CR_LEDGER="$LB" bash "$CS" --by-branch feat/does-not-exist 2>&1)"
contains "unknown branch says so" "$bb_none" "no review spend recorded for branch feat/does-not-exist"

# --by-branch must not swallow a following FLAG as its optional branch arg.
bb_flag="$(CR_LEDGER="$LB" bash "$CS" --by-branch --window 5 2>&1)"
contains "--by-branch does not eat a following flag" "$bb_flag" "feat/costly"

# Records predating the branch field are not attributable and must be skipped,
# not bucketed under a phantom branch.
LBN="$tmp/by-branch-nobranch.jsonl"
echo '{"kind":"avail","ts":"2026-04-01T00:00:00Z","head":"NH1","model":"codex","status":"ok"}' > "$LBN"
bb_nb="$(CR_LEDGER="$LBN" bash "$CS" --by-branch 2>&1)"
contains "branch-less records are not attributed" "$bb_nb" "no branch-attributed review spend recorded yet"

# The default report must not gain the new section.
base_out="$(CR_LEDGER="$L" bash "$CS" 2>&1)"
not_contains "default output does not gain the spend table" "$base_out" "Review spend per branch"

# ── unadjudicated findings at each branch's latest head ───────
# feat/wedge: QH1 (older, superseded) then QH2 (latest by ts). At QH2: w-1 has
# no verdict (stays unadjudicated), w-2 has no verdict but is adjudicated by a
# later amend (must NOT count), w-3 is already disproved (must NOT count).
# w-old sits on the superseded QH1 head with no verdict and must NOT count —
# only the latest head is gated. feat/clean is fully adjudicated -> 0.
LU="$tmp/by-branch-unadjudicated.jsonl"
{
  echo '{"kind":"finding","ts":"2026-05-01T00:00:00Z","branch":"feat/wedge","head":"QH1","model":"codex","finding_id":"w-old","severity":"sug","file":"f","line":1,"verdict":""}'
  echo '{"kind":"avail","ts":"2026-05-01T00:00:01Z","branch":"feat/wedge","head":"QH1","model":"codex","status":"ok"}'
  echo '{"kind":"finding","ts":"2026-05-01T00:01:00Z","branch":"feat/wedge","head":"QH2","model":"codex","finding_id":"w-1","severity":"sug","file":"f","line":2,"verdict":""}'
  echo '{"kind":"finding","ts":"2026-05-01T00:01:01Z","branch":"feat/wedge","head":"QH2","model":"codex","finding_id":"w-2","severity":"sug","file":"f","line":3,"verdict":""}'
  echo '{"kind":"finding","ts":"2026-05-01T00:01:02Z","branch":"feat/wedge","head":"QH2","model":"codex","finding_id":"w-3","severity":"imp","file":"f","line":4,"verdict":"disproved"}'
  echo '{"kind":"amend","ts":"2026-05-01T00:01:03Z","branch":"feat/wedge","target_head":"QH2","finding_id":"w-2","artifact":"diff","perspective":"off","set":{"verdict":"agreed"},"reason":"adjudicated"}'
  echo '{"kind":"avail","ts":"2026-05-01T00:01:04Z","branch":"feat/wedge","head":"QH2","model":"codex","status":"ok"}'
  echo '{"kind":"finding","ts":"2026-05-02T00:00:00Z","branch":"feat/clean","head":"RH1","model":"codex","finding_id":"c-1","severity":"sug","file":"f","line":1,"verdict":"agreed"}'
  echo '{"kind":"avail","ts":"2026-05-02T00:00:01Z","branch":"feat/clean","head":"RH1","model":"codex","status":"ok"}'
} > "$LU"
lu_out="$(CR_LEDGER="$LU" bash "$CS" --by-branch 2>&1)"
contains "unadjudicated count for feat/wedge (1 at latest head; old-head and amended findings excluded)" "$lu_out" "1 unadjudicated at latest head"
contains "unadjudicated count for feat/clean (0, fully adjudicated)" "$lu_out" "0 unadjudicated at latest head"
contains "repo-wide unadjudicated total across both branches" "$lu_out" "Unadjudicated at latest head: 1 finding(s) across 2 branch(es)."
lu_one="$(CR_LEDGER="$LU" bash "$CS" --by-branch feat/wedge 2>&1)"
contains "branch-filtered report still shows the per-branch unadjudicated count" "$lu_one" "1 unadjudicated at latest head"
not_contains "branch filter drops the repo-wide unadjudicated total" "$lu_one" "Unadjudicated at latest head"

# ── scoring pass tallies the amend-MERGED verdict ──────────────
# A finding row is always written with an EMPTY verdict; the
# real verdict arrives only as a later `amend` record keyed on target_head.
# amend-1: adjudicated (must count as agreed). amend-2: no matching amend
# (target_head does not match its finding's head) -> stays unadjudicated.
# amend-3: an amend targeting a DIFFERENT head than the finding actually
# carries -> guards the (head, finding_id) key shape (must NOT be applied).
LA="$tmp/amend-scores.jsonl"
{
  echo '{"kind":"finding","ts":"2026-06-01T00:00:00Z","branch":"b","head":"AMH1","model":"delta","finding_id":"d-1","severity":"major","file":"f","line":1,"verdict":""}'
  echo '{"kind":"amend","ts":"2026-06-01T00:00:01Z","branch":"b","target_head":"AMH1","finding_id":"d-1","artifact":"diff","perspective":"off","set":{"verdict":"agreed"},"reason":"adjudicated"}'
  echo '{"kind":"finding","ts":"2026-06-01T00:00:02Z","branch":"b","head":"AMH1","model":"delta","finding_id":"d-2","severity":"minor","file":"f","line":2,"verdict":""}'
  echo '{"kind":"finding","ts":"2026-06-01T00:00:03Z","branch":"b","head":"AMH1","model":"delta","finding_id":"d-3","severity":"minor","file":"f","line":3,"verdict":""}'
  echo '{"kind":"amend","ts":"2026-06-01T00:00:04Z","branch":"b","target_head":"WRONG-HEAD","finding_id":"d-3","artifact":"diff","perspective":"off","set":{"verdict":"agreed"},"reason":"adjudicated"}'
} > "$LA"
amend_out="$(CR_LEDGER="$LA" bash "$CS" 2>&1)"
# d-1 amend-merged -> agreed, d-2/d-3 stay empty-verdict -> delta agreed% = 1/3 = 33%.
# Before the fix every row tallied off the empty raw verdict -> agreed% = 0%.
# Pin the WHOLE row (total=3, agreed%=33%) so a blanket "call everything
# agreed" regression (total=3, agreed%=100%) would also fail this assertion.
contains "amend-merged finding counts as agreed; total stays 3 (denominator untouched)" \
  "$amend_out" "delta                   3        33%"

# A finding with NO matching amend must stay unadjudicated (guards against
# "call everything agreed"): d-2 has no amend at all, d-3's amend targets a
# DIFFERENT head (WRONG-HEAD) so it must not apply either — only 1 of the 3
# findings is counted agreed.
not_contains "amend-merged finding does not make delta 100pct agreed" "$amend_out" "delta                   3        100%"

# ── drop advice uses the merged verdict, not the raw one ───────
# codex: 12 raw-empty findings, 8 of which are amended to "agreed" -> merged
# agreed% = 8/12 = 67% (>=40 threshold -> NO drop advice). Off the raw rows
# alone every finding would tally as empty-verdict -> 0% agreed -> drop advice
# WOULD have fired. This pins that the fix suppresses the spurious advice.
LD="$tmp/drop-amend-scores.jsonl"
{
  for i in 1 2 3 4 5 6 7 8; do
    echo "{\"kind\":\"finding\",\"ts\":\"2026-06-02T00:00:0${i}Z\",\"branch\":\"b\",\"head\":\"DH1\",\"model\":\"codex\",\"finding_id\":\"dc-${i}\",\"severity\":\"minor\",\"file\":\"f\",\"line\":${i},\"verdict\":\"\"}" >> "$LD"
    echo "{\"kind\":\"amend\",\"ts\":\"2026-06-02T00:00:1${i}Z\",\"branch\":\"b\",\"target_head\":\"DH1\",\"finding_id\":\"dc-${i}\",\"artifact\":\"diff\",\"perspective\":\"off\",\"set\":{\"verdict\":\"agreed\"},\"reason\":\"adjudicated\"}" >> "$LD"
  done
  # Minute 01 with a zero-padded second, NOT "00:00:2${i}" -- that spelling
  # produced 00:00:210Z / 00:00:211Z / 00:00:212Z for i >= 10, i.e. three-digit
  # seconds. Those parse today only because cr-scores.sh never validates the
  # ts format, so the case was quietly asserting scoring behaviour on ledger
  # dates that can never occur, and would break for an unrelated reason the
  # day a timestamp check is added.
  for i in 9 10 11 12; do
    echo "{\"kind\":\"finding\",\"ts\":\"2026-06-02T00:01:$(printf '%02d' "$i")Z\",\"branch\":\"b\",\"head\":\"DH1\",\"model\":\"codex\",\"finding_id\":\"dc-${i}\",\"severity\":\"minor\",\"file\":\"f\",\"line\":${i},\"verdict\":\"\"}" >> "$LD"
  done
}
drop_amend_out="$(CR_LEDGER="$LD" CR_SCORES_DROP_BELOW=40 CR_SCORES_MIN_N=10 bash "$CS" 2>&1)"
not_contains "merged verdicts above threshold suppress drop advice for codex" "$drop_amend_out" "consider dropping codex"
contains "codex merged agreed% shows 67" "$drop_amend_out" "67%"

# ── `fixed` verdicts count as agreement ────────────────────────
# epsilon: 10 findings, ALL verdict="fixed". A fixed finding is an accepted
# finding (the code was changed in response to it) — it must count toward
# agreed% and must NOT trigger drop advice, even though `total` >= MIN_N.
# Before the fix, `fixed` tallied into a dynamic (never-displayed) bucket and
# left `agreed` at 0, so agreed%=0% and drop advice fired for a 100%-accepted critic.
LF="$tmp/fixed-scores.jsonl"
for i in 1 2 3 4 5 6 7 8 9 10; do
  echo "{\"kind\":\"finding\",\"ts\":\"2026-07-01T00:00:$(printf '%02d' "$i")Z\",\"branch\":\"b\",\"head\":\"FH1\",\"model\":\"epsilon\",\"finding_id\":\"e-${i}\",\"severity\":\"minor\",\"file\":\"f\",\"line\":${i},\"verdict\":\"fixed\"}" >> "$LF"
done
fixed_out="$(CR_LEDGER="$LF" CR_SCORES_DROP_BELOW=40 CR_SCORES_MIN_N=10 bash "$CS" 2>&1)"
not_contains "all-fixed critic gets NO drop advice" "$fixed_out" "consider dropping epsilon"
contains "all-fixed critic shows 100% agreed" "$fixed_out" "100%"

# ── `score` rows (one per completed critic run) are invisible to
# every table: the same ledger with a score row added at each head (stamped at
# that head's earliest ts, the worst case for the last-N-heads window) renders
# byte-identically, plain and --by-branch.
LS="$tmp/ledger-with-score.jsonl"
L="$L" LS="$LS" node -e '
const fs=require("fs"), rows=fs.readFileSync(process.env.L,"utf8").split("\n").filter(Boolean).map(JSON.parse);
const first={}; for(const r of rows){ if(r.head&&(!first[r.head]||r.ts<first[r.head])) first[r.head]=r.ts; }
const extra=Object.keys(first).map(h=>JSON.stringify({kind:"score",ts:first[h],branch:"b",head:h,model:"alpha",critical:0,important:0,suggestions:0,raw_path:"/r/"+h+".raw"}));
fs.writeFileSync(process.env.LS, extra.join("\n")+"\n"+rows.map(r=>JSON.stringify(r)).join("\n")+"\n");'
check "score rows are present in the augmented fixture" "$(grep -c '"kind":"score"' "$LS" | tr -d ' ')" "$(L="$L" node -e 'const s=new Set(require("fs").readFileSync(process.env.L,"utf8").split("\n").filter(Boolean).map(JSON.parse).map(r=>r.head).filter(Boolean));console.log(s.size)')"
check "cr-scores output is identical with score rows present" "$(CR_LEDGER="$LS" bash "$CS" 2>&1 | sed "s#$LS#LEDGER#")" "$(CR_LEDGER="$L" bash "$CS" 2>&1 | sed "s#$L#LEDGER#")"
check "cr-scores --by-branch output is identical with score rows present" "$(CR_LEDGER="$LS" bash "$CS" --by-branch 2>&1 | sed "s#$LS#LEDGER#")" "$(CR_LEDGER="$L" bash "$CS" --by-branch 2>&1 | sed "s#$L#LEDGER#")"

# ── --window counts PRs, not heads ─────────────────────────────────────────
# PR 101 spans two heads (A1, A2), PR 102 one (B1). A window of 2 PRs holds all
# three findings; counting the last 2 heads would drop the A1 row (total 2).
LP="$tmp/pr-window.jsonl"
{
  echo '{"kind":"finding","ts":"2026-10-01T00:00:00Z","branch":"p1","head":"A1","model":"gamma","finding_id":"g-1","severity":"sug","file":"f","line":1,"verdict":"fixed","pr":101,"thread_id":"T1"}'
  echo '{"kind":"finding","ts":"2026-10-01T01:00:00Z","branch":"p1","head":"A2","model":"gamma","finding_id":"g-2","severity":"sug","file":"f","line":2,"verdict":"fixed","pr":101,"thread_id":"T2"}'
  echo '{"kind":"finding","ts":"2026-10-02T00:00:00Z","branch":"p2","head":"B1","model":"gamma","finding_id":"g-3","severity":"sug","file":"f","line":3,"verdict":"fixed","pr":102,"thread_id":"T3"}'
} > "$LP"
gamma_win() { printf '%s\n' "$1" | awk '/Last-/{f=1} f && $1=="gamma"{print $2; exit}'; }
pr_out="$(CR_LEDGER="$LP" bash "$CS" --window 2 2>&1)"; pr_rc=$?
check "window of 2 PRs: cr-scores exits 0" "$pr_rc" "0"
check "window of 2 PRs counts all 3 findings across 3 heads" "$(gamma_win "$pr_out")" "3"
contains "header says the window unit is PR" "$pr_out" "window unit: PR"
pr1_out="$(CR_LEDGER="$LP" bash "$CS" --window 1 2>&1)"; pr1_rc=$?
check "window of 1 PR: cr-scores exits 0" "$pr1_rc" "0"
check "window of 1 PR counts only the newest PR's finding" "$(gamma_win "$pr1_out")" "1"
# a hand-written row with no pr joins the PR its head maps to
echo '{"kind":"finding","ts":"2026-10-01T00:30:00Z","branch":"p1","head":"A2","model":"gamma","finding_id":"g-4","severity":"sug","file":"f","line":4,"verdict":"agreed"}' >> "$LP"
pr4_out="$(CR_LEDGER="$LP" bash "$CS" --window 2 2>&1)"; pr4_rc=$?
check "no-pr row on a known head: cr-scores exits 0" "$pr4_rc" "0"
check "a no-pr row on a known head follows its PR into the window" "$(gamma_win "$pr4_out")" "4"
# a ledger with no pr field anywhere keeps the head window and says so
head_out="$(CR_LEDGER="$L" bash "$CS" --window 2 2>&1)"; head_rc=$?
check "head fallback: cr-scores exits 0" "$head_rc" "0"
contains "header says head fallback when no row carries a pr" "$head_out" "window unit: head"

# the PR mapping is built from every row, so a perspective filter keeps it: the
# recorder rows (perspective off) map heads A1 and A2 to PR 101 while the
# findings scored are the perspective-on rows with no pr of their own.
LF2="$tmp/pr-filter.jsonl"
{
  echo '{"kind":"finding","ts":"2026-10-01T00:00:00Z","branch":"p1","head":"A1","model":"gamma","finding_id":"r-1","severity":"sug","file":"f","line":1,"verdict":"fixed","pr":101,"perspective":"off"}'
  echo '{"kind":"finding","ts":"2026-10-01T01:00:00Z","branch":"p1","head":"A2","model":"gamma","finding_id":"r-2","severity":"sug","file":"f","line":2,"verdict":"fixed","pr":101,"perspective":"off"}'
  echo '{"kind":"finding","ts":"2026-10-01T00:10:00Z","branch":"p1","head":"A1","model":"gamma","finding_id":"o-1","severity":"sug","file":"f","line":3,"verdict":"fixed","perspective":"on"}'
  echo '{"kind":"finding","ts":"2026-10-01T01:10:00Z","branch":"p1","head":"A2","model":"gamma","finding_id":"o-2","severity":"sug","file":"f","line":4,"verdict":"fixed","perspective":"on"}'
  echo '{"kind":"finding","ts":"2026-10-02T00:10:00Z","branch":"p2","head":"B1","model":"gamma","finding_id":"o-3","severity":"sug","file":"f","line":5,"verdict":"fixed","perspective":"on","pr":102}'
} > "$LF2"
flt_out="$(CR_LEDGER="$LF2" bash "$CS" --perspective on --window 2 2>&1)"; flt_rc=$?
check "perspective filter: cr-scores exits 0" "$flt_rc" "0"
check "a perspective filter keeps the PR mapping, so two heads of one PR are one window unit" "$(gamma_win "$flt_out")" "3"

# a branch seen under two PRs (reused) maps a no-pr row to neither
LB="$tmp/pr-reused-branch.jsonl"
{
  echo '{"kind":"finding","ts":"2026-10-01T00:00:00Z","branch":"p3","head":"C1","model":"gamma","finding_id":"b-1","severity":"sug","file":"f","line":1,"verdict":"fixed","pr":201}'
  echo '{"kind":"finding","ts":"2026-10-02T00:00:00Z","branch":"p3","head":"C3","model":"gamma","finding_id":"b-2","severity":"sug","file":"f","line":2,"verdict":"fixed"}'
  echo '{"kind":"finding","ts":"2026-10-03T00:00:00Z","branch":"p3","head":"C2","model":"gamma","finding_id":"b-3","severity":"sug","file":"f","line":3,"verdict":"fixed","pr":202}'
} > "$LB"
reuse_out="$(CR_LEDGER="$LB" bash "$CS" --window 2 2>&1)"; reuse_rc=$?
check "reused branch: cr-scores exits 0" "$reuse_rc" "0"
check "a reused branch does not pull a no-pr row into the last PR's window unit" "$(gamma_win "$reuse_out")" "2"

# branch names that are Object.prototype members are ordinary keys
LO="$tmp/pr-proto-branch.jsonl"
{
  echo '{"kind":"finding","ts":"2026-10-01T00:00:00Z","branch":"constructor","head":"D1","model":"gamma","finding_id":"c-1","severity":"sug","file":"f","line":1,"verdict":"fixed","pr":301}'
  echo '{"kind":"finding","ts":"2026-10-02T00:00:00Z","branch":"__proto__","head":"D2","model":"gamma","finding_id":"c-2","severity":"sug","file":"f","line":2,"verdict":"fixed","pr":302}'
  echo '{"kind":"finding","ts":"2026-10-03T00:00:00Z","branch":"toString","head":"D3","model":"gamma","finding_id":"c-3","severity":"sug","file":"f","line":3,"verdict":"fixed"}'
} > "$LO"
proto_out="$(CR_LEDGER="$LO" bash "$CS" --window 3 2>&1)"; proto_rc=$?
check "prototype-named branches: cr-scores exits 0" "$proto_rc" "0"
check "prototype-named branches count as three window units" "$(gamma_win "$proto_out")" "3"

# ── Quality view and advice ────────────────────────────────────────────────
# gen <ledger> <slug> <responding-model|-> <n> <verdict> <prs> <days-ago> <amend|raw> <tag>
# appends n findings of one verdict spread over <prs> branches (one PR each), dated
# <days-ago> before now; amend = an explicit amend sets the verdict, raw = the row carries it.
gen() { python3 -I -c 'import json,sys,datetime
out,slug,rm,n,verdict,prs,days,how,tag=sys.argv[1:10]
n,prs=int(n),int(prs)
ts=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=float(days))).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(out,"a") as fh:
    w=lambda r: fh.write(json.dumps(r)+"\n")
    for p in range(prs):
        b="%s-%s-p%d"%(tag,slug,p)
        if rm!="-": w({"kind":"attempt","ts":ts,"branch":b,"head":"H"+b,"model":slug,"status":"ok","artifact":"diff","responding_model":rm})
    for i in range(n):
        b="%s-%s-p%d"%(tag,slug,i%prs); fid="%s-%s-%d"%(slug,verdict,i)
        row={"kind":"finding","ts":ts,"branch":b,"head":"H"+b,"model":slug,"finding_id":fid,"severity":"imp","file":"f","line":i,"verdict":verdict if how=="raw" else "","artifact":"diff","perspective":"off"}
        w(row)
        if how=="amend": w({"kind":"amend","ts":ts,"branch":b,"target_head":"H"+b,"finding_id":fid,"artifact":"diff","perspective":"off","set":{"verdict":verdict},"reason":"r"})
' "$@"; }
# advice_for <output> <label> - the advice line for one reviewer identity.
advice_for() { printf '%s\n' "$1" | awk -v k="$2" '/^=== Advice/{f=1; next} /^===/{f=0} f && $1==k {print; exit}'; }
# jrow <json> <slug> <model> <field> - one field of the recorded-disposition diff row.
jrow() { python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]))
r=[x for x in d["rows"] if (x["slug"],x["responding_model"],x["scope"],x["verdict_source"])==(sys.argv[2],sys.argv[3],"diff","recorded-disposition")]
v=r[0].get(sys.argv[4]) if r else "NO-ROW"
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$@"; }

# all_deferred_insufficient: 40 deferred over 12 PRs decide nothing.
LQ1="$tmp/q-deferred.jsonl"; gen "$LQ1" codex gpt-t 40 deferred 12 2 amend q1
q1_out="$(CR_LEDGER="$LQ1" bash "$CS" 2>&1)"
not_contains "all_deferred_insufficient: no drop advice" "$q1_out" "consider dropping"
contains "all_deferred_insufficient: insufficient evidence" "$(advice_for "$q1_out" codex:gpt-t)" "insufficient evidence"
CR_LEDGER="$LQ1" bash "$CS" --json > "$tmp/q1.json" 2>/dev/null
check "all_deferred_insufficient: no author_agreement" "$(jrow "$tmp/q1.json" codex gpt-t author_agreement)" "null"

# repeated_same_pr_low_evidence: 40 disproved, all on one PR.
LQ2="$tmp/q-onepr.jsonl"; gen "$LQ2" codex gpt-r 40 disproved 1 2 amend q2
q2_out="$(CR_LEDGER="$LQ2" bash "$CS" 2>&1)"
not_contains "repeated_same_pr_low_evidence: no drop advice" "$q2_out" "consider dropping"
contains "repeated_same_pr_low_evidence: insufficient evidence" "$(advice_for "$q2_out" codex:gpt-r)" "insufficient evidence"
# PRs that hold only deferred findings do not lift the PR floor for decided ones.
LQ2b="$tmp/q-onepr-deferred.jsonl"; gen "$LQ2b" codex gpt-s 40 disproved 1 2 amend q2b; gen "$LQ2b" codex gpt-s 9 deferred 9 2 amend q2c
q2b_out="$(CR_LEDGER="$LQ2b" bash "$CS" 2>&1)"
contains "repeated_same_pr_low_evidence: deferred-only PRs do not count" "$(advice_for "$q2b_out" codex:gpt-s)" "insufficient evidence (40 decided over 1 PR(s)"

# bookkeeping_no_drop: a bookkeeping slug gets no reviewer advice at any rate.
LQ3="$tmp/q-bookkeeping.jsonl"; gen "$LQ3" coverage-deferral - 40 disproved 12 2 amend q3
q3_out="$(CR_LEDGER="$LQ3" bash "$CS" 2>&1)"
not_contains "bookkeeping_no_drop: no drop advice" "$q3_out" "consider dropping"
not_contains "bookkeeping_no_drop: no low-agreement advice" "$q3_out" "low author agreement"
contains "bookkeeping_no_drop: named as not a reviewer" "$(advice_for "$q3_out" not)" "not a reviewer (bookkeeping or unmapped slug), no reviewer advice: coverage-deferral:unknown"
CR_LEDGER="$LQ3" bash "$CS" --json > "$tmp/q3.json" 2>/dev/null
check "bookkeeping_no_drop: JSON advice says not-a-reviewer" "$(python3 -I -c 'import json,sys
print([a["advice"] for a in json.load(open(sys.argv[1]))["advice"]])' "$tmp/q3.json")" "['not-a-reviewer']"

# advice_uses_window: 80 disproved two months ago, 40 agreed this week. The
# default 14-day view says ok; an explicit --since over both says investigate.
LQ4="$tmp/q-window.jsonl"; gen "$LQ4" codex gpt-w 80 disproved 12 60 amend q4old; gen "$LQ4" codex gpt-w 40 agreed 12 2 amend q4new
q4_out="$(CR_LEDGER="$LQ4" bash "$CS" 2>&1)"
not_contains "advice_uses_window: no all-time drop advice" "$q4_out" "consider dropping"
contains "advice_uses_window: the default window is the trailing 14 days" "$q4_out" "trailing 14 days"
contains "advice_uses_window: ok in the default window" "$(advice_for "$q4_out" codex:gpt-w)" "ok"
since90="$(python3 -I -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=90)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
q4w_out="$(CR_LEDGER="$LQ4" bash "$CS" --since "$since90" 2>&1)"
contains "advice_uses_window: the explicit window is named" "$q4w_out" "$since90"
contains "advice_uses_window: investigate in the explicit window" "$(advice_for "$q4w_out" codex:gpt-w)" "low author agreement; investigate"
until30="$(python3 -I -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
CR_LEDGER="$LQ4" bash "$CS" --since "$since90" --until "$until30" --json > "$tmp/q4u.json" 2>/dev/null
check "--until cuts the quality view" "$(jrow "$tmp/q4u.json" codex gpt-w agreed) $(jrow "$tmp/q4u.json" codex gpt-w disproved)" "0 80"

# deferrals_visible: deferred findings sit outside author_agreement but in sight.
LQ5="$tmp/q-defer.jsonl"; gen "$LQ5" codex gpt-d 30 agreed 10 2 amend q5; gen "$LQ5" codex gpt-d 10 deferred 10 2 amend q5
q5_out="$(CR_LEDGER="$LQ5" bash "$CS" 2>&1)"
CR_LEDGER="$LQ5" bash "$CS" --json > "$tmp/q5.json" 2>/dev/null
check "deferrals_visible: JSON deferred" "$(jrow "$tmp/q5.json" codex gpt-d deferred)" "10"
check "deferrals_visible: coverage leaves deferred out of decided" "$(jrow "$tmp/q5.json" codex gpt-d adjudication_coverage)" "0.75"
check "deferrals_visible: agreement ignores deferred" "$(jrow "$tmp/q5.json" codex gpt-d author_agreement)" "1.0"
contains "deferrals_visible: the text names the deferred count" "$q5_out" "10 deferred"

# JSON_counts_match_text: every text row carries the JSON row's counts.
LQ6="$tmp/q-mixed.jsonl"; cat "$LQ5" "$LQ2" "$LQ3" > "$LQ6"; gen "$LQ6" codex - 3 agreed 1 1 raw q6
q6_txt="$(CR_LEDGER="$LQ6" bash "$CS" 2>&1)"
CR_LEDGER="$LQ6" bash "$CS" --json > "$tmp/q6.json" 2>/dev/null; q6_rc=$?
check "--json exits 0" "$q6_rc" "0"
q6_cmp="$(printf '%s\n' "$q6_txt" | python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1])); text={}; on=False
for l in sys.stdin:
    if l.startswith("=== Quality view"): on=True; continue
    if l.startswith("==="): on=False
    c=l.split()
    if on and len(c)>=10 and ":" in c[0] and c[4].isdigit(): text[(c[0],c[1],c[2])]=c[3:9]
want={("%s:%s"%(r["slug"],r["responding_model"]),r["scope"],r["verdict_source"]):[str(r[k]) for k in ("total","agreed","disproved","deferred","unresolved","prs")] for r in d["rows"]}
print("match" if want and text==want else "text=%r json=%r"%(text,want))' "$tmp/q6.json")"
check "JSON_counts_match_text: text and JSON agree row for row" "$q6_cmp" "match"

# flags: bad dates refused, --json is not a --by-branch mode, existing flags kept.
CR_LEDGER="$LQ6" bash "$CS" --since not-a-date >/dev/null 2>&1; check "--since not a date: exit 2" "$?" "2"
CR_LEDGER="$LQ6" bash "$CS" --until not-a-date >/dev/null 2>&1; check "--until not a date: exit 2" "$?" "2"
CR_LEDGER="$LQ6" bash "$CS" --since >/dev/null 2>&1; check "--since without a value: exit 2" "$?" "2"
CR_LEDGER="$LQ6" bash "$CS" --by-branch --json >/dev/null 2>&1; check "--json with --by-branch: exit 2" "$?" "2"
q7_out="$(CR_LEDGER="$LQ6" bash "$CS" --window 3 --artifact diff --perspective off 2>&1)"; q7_rc=$?
check "existing flags with the quality view: exit 0" "$q7_rc" "0"
contains "existing flags: the window table stays" "$q7_out" "Last-3-PRs"
contains "accept_yield_not_precision: the yield is labelled not precision" "$q7_out" "acceptance_yield = agreed / all findings, not precision"

# ── Final ──────────────────────────────────────────────────────────────────
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
