#!/usr/bin/env bash
# scripts/usage/test-usage.sh -- fixture test for usage-compute.sh and
# usage-read.sh. Synthetic transcripts and a synthetic CR ledger
# only: no real transcript, no network.
# Platform guard: pure bash 3.2-safe + jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPUTE="$HERE/usage-compute.sh"
READ="$HERE/usage-read.sh"
BANK="$HERE/../lib/usage-attribution.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-usage.XXXXXX")"
T1=HIMMEL-9001; T2=HIMMEL-9002; T7=HIMMEL-7777
trap 'rm -rf "$ROOT"' EXIT
PROJ="$ROOT/projects"; SLUG="$PROJ/slug"; mkdir -p "$SLUG"
FAIL=0
check() { # label expected actual
  if [ "$2" != "$3" ]; then echo "FAIL: $1 -- expected [$2] got [$3]" >&2; FAIL=1; else echo "ok: $1"; fi
}

row() { # sid sidechain ts req in cr cc out
  printf '{"type":"assistant","sessionId":"%s","isSidechain":%s,"timestamp":"%s","requestId":"%s","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"output_tokens":%s}}}\n' "$@"
}
WORKER="aaaaaaaa-0000-0000-0000-000000000001"
CON="bbbbbbbb-0000-0000-0000-000000000002"
JDG="cccccccc-0000-0000-0000-000000000003"
{
  echo '{"type":"custom-title","customTitle":"HIMMEL-9001-N1-thing","sessionId":"'$WORKER'"}'
  row $WORKER false 2026-01-01T00:00:02.000Z r1 10 100 5 20
  row $WORKER false 2026-01-01T00:00:02.000Z r1 10 100 5 20
  row $WORKER false 2026-01-01T00:00:03.000Z r2 11 101 6 21
  echo '{"type":"user","sessionId":"'$WORKER'","message":{"content":"subagent prompt SECRETSENTINEL"}}'
} > "$SLUG/$WORKER.jsonl"
mkdir -p "$SLUG/$WORKER/subagents"
row $WORKER true 2026-01-01T00:00:04.000Z s1 50 500 25 100 > "$SLUG/$WORKER/subagents/agent-1.jsonl"
{
  echo '{"type":"custom-title","customTitle":"HIMMEL-nextleg-chief","sessionId":"'$CON'"}'
  row $CON false 2026-01-01T00:00:02.000Z c1 3 30 2 7
} > "$SLUG/$CON.jsonl"
{
  echo '{"type":"custom-title","customTitle":"HIMMEL-9001-judge-call","sessionId":"'$JDG'"}'
  row $JDG false 2026-01-01T00:00:02.000Z j1 4 40 3 8
} > "$SLUG/$JDG.jsonl"

LEDGER="$ROOT/ledger.jsonl"
cat > "$LEDGER" <<'L'
{"kind":"finding","ts":"2026-01-01T01:00:00Z","branch":"feat/himmel-9001-thing","head":"h1","model":"codex","finding_id":"codex-1","severity":"imp","verdict":""}
{"kind":"finding","ts":"2026-01-01T01:00:00Z","branch":"feat/himmel-9001-thing","head":"h1","model":"codex","finding_id":"codex-2","severity":"sug","verdict":"agreed"}
{"kind":"amend","ts":"2026-01-01T01:05:00Z","branch":"","target_head":"h1","finding_id":"codex-1","set":{"verdict":"disproved"}}
{"kind":"avail","ts":"2026-01-01T02:00:00Z","branch":"feat/himmel-9001-thing","head":"h2","model":"codex","status":"ok"}
{"kind":"usage","ts":"2026-01-01T01:00:00Z","branch":"feat/himmel-9001-thing","head":"h1","model":"codex","est_total_tokens":1000,"estimated":true}
{"kind":"usage","ts":"2026-01-01T02:00:00Z","branch":"feat/himmel-9001-thing","head":"h2","model":"codex","est_total_tokens":500,"estimated":true}
{"kind":"avail","ts":"2026-01-01T02:00:00Z","branch":"feat/himmel-9002-other","head":"h9","model":"codex","status":"ok"}
L



STORE="$ROOT/store"
run() { bash "$COMPUTE" --projects "$PROJ" --ledger "$LEDGER" --range HIMMEL-9001..HIMMEL-9002 "$@"; }

# 1. per-session totals equal usage-attribution.sh on the same fixture
BA="$(bash "$BANK" "$PROJ")"
ba_worker="$(printf '%s\n' "$BA" | grep -F "| $T1-N1-thing | slug" | awk -F' [|] ' '{print $4"/"$5"/"$6"/"$7"/"$8}')"
OUT="$(run --print)"
rec="$(printf '%s\n' "$OUT" | jq -c --arg t "$T1" 'select(.ticket==$t)')"
rec_worker="$(printf '%s' "$rec" | jq -r '.legs[]|select(.name=="HIMMEL-9001-N1-thing")|"\(.turns)/\(.input)/\(.cache_read)/\(.cache_create)/\(.output)"')"
check "worker totals match bank-attribution" "$ba_worker" "$rec_worker"
check "worker totals literal (dedup'd turn)" "2/21/201/11/41" "$rec_worker"
check "subagent tokens carried" "1/50/500/25/100" "$(printf '%s' "$rec" | jq -r '.legs[]|select(.name=="HIMMEL-9001-N1-thing")|"\(.sub_turns)/\(.sub_input)/\(.sub_cache_read)/\(.sub_cache_create)/\(.sub_output)"')"

# 2. separate fields per kind
check "judge kind separate" "judge" "$(printf '%s' "$rec" | jq -r '.legs[]|select(.name=="HIMMEL-9001-judge-call").kind')"
check "totals.leg has no judge" "21" "$(printf '%s' "$rec" | jq -r '.totals.leg.input')"
check "totals.judge" "4" "$(printf '%s' "$rec" | jq -r '.totals.judge.input')"
check "chief not attributed to ticket" "0" "$(printf '%s' "$rec" | jq -r '.totals.console.input')"
check "chief pool record, unallocated" "3" "$(printf '%s\n' "$OUT" | jq -r 'select(.ticket=="_chief")|.totals.console.input')"

# 3. CR
check "cr rounds" "2" "$(printf '%s' "$rec" | jq -r '.cr.rounds')"
check "cr findings by verdict" '{"agreed":1,"disproved":1}' "$(printf '%s' "$rec" | jq -c '.cr.findings')"
check "cr est tokens" "1500" "$(printf '%s' "$rec" | jq -r '.cr.est_tokens')"

# explicit inputs that are missing fail closed and write nothing
FC="$ROOT/store-fc"
rc=0; bash "$COMPUTE" --projects "$PROJ" --ledger "$ROOT/no-such-ledger" --range HIMMEL-9001..HIMMEL-9002 --store "$FC" >/dev/null 2>&1 || rc=$?
check "missing explicit ledger fails closed" "1" "$rc"
rc=0; bash "$COMPUTE" --projects "$ROOT/no-such-dir" --ledger "$LEDGER" --range HIMMEL-9001..HIMMEL-9002 --store "$FC" >/dev/null 2>&1 || rc=$?
check "missing explicit projects fails closed" "1" "$rc"
check "fail-closed runs wrote nothing" "no" "$([ -e "$FC" ] && echo yes || echo no)"
# selector validation: --tickets as strict as --range, nothing-matches and conflicts fail closed
sel() { rc=0; bash "$COMPUTE" --projects "$PROJ" --ledger "$LEDGER" --store "$FC" "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
check "--tickets bad key fails" "1" "$(sel --tickets 'not a key')"
check "--tickets empty element fails" "1" "$(sel --tickets "$T1,")"
check "--tickets matching nothing fails" "1" "$(sel --tickets "$T7")"
check "--tickets valid still works" "0" "$(sel --tickets "$T1" --print)"
check "--since empty fails" "1" "$(sel --since '' --print)"
check "--range with --tickets fails" "1" "$(sel --range "$T1..$T2" --tickets "$T1" --print)"
# every value-taking flag: empty or missing value fails closed
for flag in --projects --ledger --store --range --tickets --since; do
  check "$flag empty value fails" "1" "$(sel "$flag" '' --print)"
  check "$flag missing value fails" "1" "$(sel "$flag")"
done

printf '%s\n' '{"kind":"avail","ts":"2026-01-01T03:00:00Z","branch":"feat/himmel-9001-thing","head":"h3","model":"codex","status":"unavailable"}' >> "$LEDGER"
check "unavailable avail not a round" "2" "$(run --print | jq -r 'select(.ticket=="HIMMEL-9001")|.cr.rounds')"

# 4. idempotency: byte-identical print + store unchanged on rerun
OUT2="$(run --print)"
check "print byte-identical" "$OUT" "$OUT2"
run --store "$STORE" >/dev/null
h1="$(cksum < "$STORE/records.jsonl")"
run --store "$STORE" >/dev/null
check "store byte-identical on rerun" "$h1" "$(cksum < "$STORE/records.jsonl")"

# 5. append-only: changed input appends a new version, old lines kept
before="$(jq -c 'select(.ticket != null)' "$STORE/records.jsonl" | wc -l | tr -d ' ')"
row $WORKER false 2026-01-01T00:00:09.000Z r3 1 1 1 1 >> "$SLUG/$WORKER.jsonl"
run --store "$STORE" >/dev/null
after="$(jq -c 'select(.ticket != null)' "$STORE/records.jsonl" | wc -l | tr -d ' ')"
check "changed input appends one version" "$((before + 1))" "$after"

# 6. consumer read test (no JSONL touched)
check "read latest turns" "3" "$(bash "$READ" --store "$STORE" --ticket HIMMEL-9001 | jq -r '.legs[]|select(.name=="HIMMEL-9001-N1-thing").turns')"
check "read all versions" "2" "$(bash "$READ" --store "$STORE" --ticket "$T1" --all | wc -l | tr -d ' ')"

# 6b. two concurrent runs on a fresh store publish ONE record per ticket
# (the lock spans compute+append, so the second run sees the first's line)
STORE2="$ROOT/store2"
run --store "$STORE2" >/dev/null & p1=$!
run --store "$STORE2" >/dev/null & p2=$!
wait "$p1"; wait "$p2"
check "concurrent runs: one record per ticket" "1" "$(jq -r 'select(.ticket=="HIMMEL-9001")|.ticket' "$STORE2/records.jsonl" | wc -l | tr -d ' ')"
check "concurrent runs: lock released" "no" "$([ -d "$STORE2/.lock" ] && echo yes || echo no)"

# 7. no message text anywhere in the output
check "no transcript text leaks" "0" "$(grep -c 'SECRETSENTINEL' "$STORE/records.jsonl" || true)"

# 8. PR/CI join: a stub gh, never the network. Fixtures are files
# the stub prints; GHFAIL / GHWANT_REPO make it fail like auth or a wrong repo.
STUB="$ROOT/stub"; mkdir -p "$STUB" "$ROOT/dir with space"
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
# logs every call; fails on GHFAIL or when -R is not GHWANT_REPO
printf '%s\n' "$*" >> "$GHLOG"
[ -z "${GHFAIL:-}" ] || { echo "gh: auth error" >&2; exit 4; }
repo=""; prev=""; search=""; branch=""
for a in "$@"; do
  [ "$prev" != "-R" ] || repo="$a"
  [ "$prev" != "--search" ] || search="$a"
  [ "$prev" != "--branch" ] || branch="$a"
  prev="$a"
done
[ "$repo" = "${GHWANT_REPO:-o/r}" ] || { echo "gh: repository not found: $repo" >&2; exit 1; }
case "$1 $2" in
  "pr list")  f="$GHFIX/pr-${search%% *}.json" ;;
  "run list") f="$GHFIX/run-$(printf '%s' "$branch" | tr '/' '_').json" ;;
  *) echo "stub: unexpected $*" >&2; exit 2 ;;
esac
if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
STUBEOF
chmod +x "$STUB/gh"; cp "$STUB/gh" "$ROOT/dir with space/gh"
export GHLOG="$ROOT/gh.log"; : > "$GHLOG"
GHFIX="$ROOT/fix"; export GHFIX; mkdir -p "$GHFIX"
cat > "$GHFIX/pr-HIMMEL-9001.json" <<'J'
[{"number":12,"state":"CLOSED","title":"[HIMMEL-9001] retry","headRefName":"feat/himmel-9001-retry"},
 {"number":11,"state":"MERGED","title":"[HIMMEL-9001] thing","headRefName":"feat/himmel-9001-thing"},
 {"number":13,"state":"OPEN","title":"[HIMMEL-90019] decoy","headRefName":"feat/himmel-90019-decoy"}]
J
cat > "$GHFIX/run-feat_himmel-9001-thing.json" <<'J'
[{"databaseId":1,"status":"completed","conclusion":"success","createdAt":"2026-01-01T00:00:00Z","startedAt":"2026-01-01T00:00:10Z","updatedAt":"2026-01-01T00:01:10Z"},
 {"databaseId":2,"status":"completed","conclusion":"failure","createdAt":"2026-01-01T00:02:00Z","startedAt":"2026-01-01T00:02:00Z","updatedAt":"2026-01-01T00:02:30Z"},
 {"databaseId":3,"status":"in_progress","conclusion":"","createdAt":"2026-01-01T00:03:00Z","startedAt":"2026-01-01T00:03:00Z","updatedAt":"2026-01-01T00:03:05Z"}]
J
cat > "$GHFIX/run-feat_himmel-9001-retry.json" <<'J'
[{"databaseId":1,"status":"completed","conclusion":"success","createdAt":"2026-01-01T00:00:00Z","startedAt":"2026-01-01T00:00:10Z","updatedAt":"2026-01-01T00:01:10Z"}]
J
jrun() { run --repo o/r --gh "$STUB/gh" "$@"; }
J="$(jrun --print)"
jrec="$(printf '%s\n' "$J" | jq -c --arg t "$T1" 'select(.ticket==$t)')"
check "pr facts (a decoy key with extra digits excluded, numbers sorted)" '{"closed":1,"merged":1,"numbers":[11,12],"open":0,"state":"found"}' "$(printf '%s' "$jrec" | jq -cS .pr)"
check "ci facts (runs deduped by id, secs from startedAt, in_progress not summed)" '{"basis":"startedAt","completed":2,"runs":3,"secs":90,"state":"found"}' "$(printf '%s' "$jrec" | jq -cS .ci)"
check "no PR: pr is none" '{"state":"none"}' "$(printf '%s\n' "$J" | jq -c 'select(.ticket=="HIMMEL-9002")|.pr')"
check "no PR: ci is no-pr, not zero runs" '{"state":"no-pr"}' "$(printf '%s\n' "$J" | jq -c 'select(.ticket=="HIMMEL-9002")|.ci')"
check "pseudo-tickets carry no pr/ci" "null" "$(printf '%s\n' "$J" | jq -c 'select(.ticket=="_chief")|.pr')"
check "no --repo: records carry no pr/ci" "null/null" "$(run --print | jq -r 'select(.ticket=="HIMMEL-9001")|"\(.pr)/\(.ci)"')"
mkdir -p "$ROOT/fix2"
echo '[{"number":5,"state":"OPEN","title":"HIMMEL-9001 x","headRefName":"b"}]' > "$ROOT/fix2/pr-HIMMEL-9001.json"
check "a PR with zero runs is runs:0, not no-pr" '{"basis":"none","completed":0,"runs":0,"secs":0,"state":"found"}' "$(GHFIX="$ROOT/fix2" jrun --print | jq -cS 'select(.ticket=="HIMMEL-9001")|.ci')"
mkdir -p "$ROOT/fix3"
echo '[{"number":6,"state":"OPEN","title":"HIMMEL-9001 y","headRefName":"b"}]' > "$ROOT/fix3/pr-HIMMEL-9001.json"
echo '[{"databaseId":9,"status":"completed","conclusion":"success","createdAt":"2026-01-01T00:00:00Z","startedAt":null,"updatedAt":"2026-01-01T00:00:45Z"}]' > "$ROOT/fix3/run-b.json"
check "missing startedAt falls back to createdAt and says so" '{"basis":"createdAt","completed":1,"runs":1,"secs":45,"state":"found"}' "$(GHFIX="$ROOT/fix3" jrun --print | jq -cS 'select(.ticket=="HIMMEL-9001")|.ci')"
mkdir -p "$ROOT/fix4"
echo '[{"number":7,"state":"OPEN","title":"HIMMEL-9001A decoy","headRefName":"b"}]' > "$ROOT/fix4/pr-HIMMEL-9001.json"
check "a letter after the key is not the key" '{"state":"none"}' "$(GHFIX="$ROOT/fix4" jrun --print | jq -cS --arg t "$T1" 'select(.ticket==$t)|.pr')"
mkdir -p "$ROOT/fix5"
echo '[{"number":8,"state":"OPEN","title":"HIMMEL-9001 z","headRefName":"b"}]' > "$ROOT/fix5/pr-HIMMEL-9001.json"
echo '[{"databaseId":20,"status":"completed","conclusion":"success","createdAt":"2026-01-01T00:00:00Z","startedAt":"2026-01-01T00:01:00Z","updatedAt":"2026-01-01T00:00:50Z"},
 {"databaseId":21,"status":"completed","conclusion":"success","createdAt":"2026-01-01T00:00:00Z","startedAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:05:00Z"}]' > "$ROOT/fix5/run-b.json"

# the join fails closed: a failing gh writes nothing and leaves prior versions alone
SJ="$ROOT/store-join"
jrun --store "$SJ" >/dev/null
hj="$(cksum < "$SJ/records.jsonl")"
row $WORKER false 2026-01-01T00:00:20.000Z r4 1 1 1 1 >> "$SLUG/$WORKER.jsonl"   # input changed: a good run WOULD append
frc() { rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
check "gh auth failure exits non-zero" "1" "$(GHFAIL=1 frc jrun --store "$SJ")"
check "wrong repo (gh error) exits non-zero" "1" "$(GHWANT_REPO=x/y frc jrun --store "$SJ")"
check "missing gh exits non-zero" "1" "$(frc run --repo o/r --gh "$ROOT/no-such-gh" --store "$SJ")"
check "one negative run duration aborts even when the sum is positive" "1" "$(GHFIX="$ROOT/fix5" frc jrun --store "$SJ")"
check "gh failure left the store byte-identical" "$hj" "$(cksum < "$SJ/records.jsonl")"
check "failed run released the lock" "no" "$([ -d "$SJ/.lock" ] && echo yes || echo no)"
cp -R "$GHFIX" "$ROOT/fix-bad"
echo 'not json' > "$ROOT/fix-bad/pr-HIMMEL-9001.json"
check "malformed pr JSON aborts" "1" "$(GHFIX="$ROOT/fix-bad" frc jrun --store "$SJ")"
echo '{"a":1}' > "$ROOT/fix-bad/pr-HIMMEL-9001.json"
check "non-array pr JSON aborts" "1" "$(GHFIX="$ROOT/fix-bad" frc jrun --store "$SJ")"
cp "$GHFIX/pr-HIMMEL-9001.json" "$ROOT/fix-bad/pr-HIMMEL-9001.json"
echo '[{"databaseId":1}]' > "$ROOT/fix-bad/run-feat_himmel-9001-thing.json"
check "run JSON missing fields aborts" "1" "$(GHFIX="$ROOT/fix-bad" frc jrun --store "$SJ")"
check "every abort left the store byte-identical" "$hj" "$(cksum < "$SJ/records.jsonl")"
SF="$ROOT/store-fresh"
check "failed run on a fresh store" "1" "$(GHFAIL=1 frc jrun --store "$SF")"
check "failed fresh run stored nothing" "no" "$([ -e "$SF/records.jsonl" ] && echo yes || echo no)"
check "good run still appends after the aborts" "0" "$(frc jrun --store "$SJ")"

# a --gh path with a space works; the repo is pinned whatever the cwd
: > "$GHLOG"
check "--gh path with a space works" "0" "$(frc run --repo o/r --gh "$ROOT/dir with space/gh" --print)"
mkdir -p "$ROOT/elsewhere"
(cd "$ROOT/elsewhere" && jrun --print >/dev/null)
check "gh was called" "yes" "$([ -s "$GHLOG" ] && echo yes || echo no)"
check "every gh call pinned -R o/r" "0" "$(grep -vcE '^(pr|run) list -R o/r ' "$GHLOG" || true)"
# join flags are validated
check "--gh without --repo fails" "1" "$(frc run --gh "$STUB/gh" --print)"
check "--repo malformed fails" "1" "$(frc run --repo 'not a repo' --print)"
check "--repo empty value fails" "1" "$(frc run --repo '' --print)"

# usage-read.sh waits on the store lock (no torn read) and releases it
mkdir "$SJ/.lock"
bash "$READ" --store "$SJ" > "$ROOT/read.out" 2>&1 & rp=$!
sleep 1
check "reader blocks while a writer holds the lock" "yes" "$(kill -0 "$rp" 2>/dev/null && echo yes || echo no)"
rmdir "$SJ/.lock"
rc=0; wait "$rp" || rc=$?
check "reader proceeds once the lock drops" "0" "$rc"
check "reader released its own lock" "no" "$([ -d "$SJ/.lock" ] && echo yes || echo no)"

# a store the reader cannot lock is read lock-free, but a torn last line fails closed
RO="$ROOT/store-ro"; mkdir "$RO"; cp "$SJ/records.jsonl" "$RO/records.jsonl"; chmod 555 "$RO"
if [ -w "$RO" ]; then
  echo "skip: store stays writable for this user (privileged runner); lock-free read path not exercised"
else
  check "read-only store with an intact file is read" "0" "$(frc bash "$READ" --store "$RO")"
  chmod 755 "$RO"; printf '{"ticket":"HIMMEL-1"}' >> "$RO/records.jsonl"; chmod 555 "$RO"   # valid JSON, newline not yet written
  check "read-only store with a torn last line aborts" "1" "$(frc bash "$READ" --store "$RO")"
fi
chmod 755 "$RO"

# an unknown run status aborts the whole run (gh's set only)
cp -R "$GHFIX" "$ROOT/fix-status"
echo '[{"databaseId":1,"status":"bogus","conclusion":"","createdAt":"2026-01-01T00:00:00Z","startedAt":null,"updatedAt":"2026-01-01T00:00:10Z"}]' > "$ROOT/fix-status/run-feat_himmel-9001-thing.json"
hs="$(cksum < "$SJ/records.jsonl")"
check "unknown run status aborts" "1" "$(GHFIX="$ROOT/fix-status" frc jrun --store "$SJ")"
check "unknown run status left the store byte-identical" "$hs" "$(cksum < "$SJ/records.jsonl")"
for st in queued in_progress completed waiting requested pending; do
  echo "[{\"databaseId\":1,\"status\":\"$st\",\"conclusion\":\"\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"startedAt\":null,\"updatedAt\":\"2026-01-01T00:00:10Z\"}]" > "$ROOT/fix-status/run-feat_himmel-9001-thing.json"
  check "gh status $st is accepted" "0" "$(GHFIX="$ROOT/fix-status" frc jrun --print)"
done

# --- ci-minutes.sh: billed minutes per run, listing paged past 1,000 ---
# A stub gh serves a runs listing like the real one: --paginate returns pages of 100
# rows, a filtered window returns at most 1,000 rows however large total_count is,
# and /timing answers 404 for a run with no billing answer. REAL is one real
# run's /timing answer (yotamleo-org/Himmel run 41372286597, 2026-11-05).
CIM="$HERE/ci-minutes.sh"
CD="$ROOT/cim"; mkdir -p "$CD/bin"
UNTIL="2026-11-05T12:00:00Z"
FROM_E="$(jq -nr '"2026-10-29T12:00:00Z" | fromdateiso8601')"
REAL='{"billable":{"UBUNTU":{"total_ms":0,"jobs":2,"job_runs":[{"job_id":125045113057,"duration_ms":0},{"job_id":125045598141,"duration_ms":0}]}},"run_duration_ms":127000}'
cat > "$CD/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
[ "${1:-}" = api ] || exit 2
ep="$2"; shift 2
pag=0; for a in "$@"; do [ "$a" = --paginate ] && pag=1; done
echo "api $ep" >> "$CIM_LOG"
case "$ep" in
  repos/o/r/actions/runs/*/timing)
    id="${ep#repos/o/r/actions/runs/}"; id="${id%/timing}"
    [ ! -e "$CIM_FIX/timing-fail" ] || { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
    jq -ce --arg id "$id" '.[$id]' "$CIM_FIX/timing.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    ;;
  repos/o/r/actions/runs\?*)
    rng="${ep##*created=}"; rng="${rng%%&*}"; from="${rng%%..*}"; to="${rng##*..}"
    jq -c --arg f "$from" --arg t "$to" --argjson pag "$pag" '
      [.[] | select(.created_at >= $f and .created_at <= $t)] as $m
      | ($m | length) as $n | $m[0:1000] as $cap | ($cap | length) as $c
      | if $pag == 1 then [range(0; ([$c, 1] | max); 100)] | map({total_count: $n, workflow_runs: $cap[.:. + 100]}) | .[]
        else {total_count: $n, workflow_runs: $cap[0:100]} end' "$CIM_FIX/runs.json"
    ;;
  *) echo "stub gh: unexpected $ep" >&2; exit 2 ;;
esac
STUB
chmod +x "$CD/bin/gh"
gen_runs() { # first_id count spacing_secs wall_secs -> runs.json on stdout (created_at = window start + n*spacing)
  jq -nc --argjson id0 "$1" --argjson n "$2" --argjson sp "$3" --argjson w "$4" --argjson base "$FROM_E" \
    '[range(0; $n) | ($base + . * $sp) as $s | {id: ($id0 + .), name: "CI", created_at: ($s | todate), run_started_at: ($s | todate), updated_at: ($s + $w | todate)}]'
}
cim() { # fixture-dir store args...
  local fx="$1" st="$2"; shift 2
  CIM_FIX="$fx" CIM_LOG="$CD/gh.log" bash "$CIM" "$@" --repo o/r --days 7 --until "$UNTIL" --store "$st" --gh "$CD/bin/gh"
}
nrows() { cat "$1" 2>/dev/null | wc -l | tr -d ' '; }   # read-sink-ok: callers pass only ledger paths under the suite's own mktemp dir
circ() { local rc=0; cim "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

# (a) pagination: 2,500 runs over a window the API caps at 1,000 rows, all land
F1="$CD/fx-2500"; mkdir -p "$F1"; gen_runs 100000 2500 241 60 > "$F1/runs.json"; echo '{}' > "$F1/timing.json"
S1="$CD/store-2500"; : > "$CD/gh.log"
check "2,500 runs: writer exits 0" "0" "$(circ "$F1" "$S1" write)"
check "2,500 runs: 2,500 distinct run ids stored" "2500" "$(jq -r '.run_id' "$S1/ci-minutes.jsonl" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
check "2,500 runs: one row per run" "2500" "$(nrows "$S1/ci-minutes.jsonl")"
: > "$CD/gh.log"
check "rerun on the same window exits 0" "0" "$(circ "$F1" "$S1" write)"
check "rerun appends no second row for a run id" "2500" "$(nrows "$S1/ci-minutes.jsonl")"
# control: a 40-run window is one listing call, 40 rows
F2="$CD/fx-40"; mkdir -p "$F2"; gen_runs 200000 40 1000 60 > "$F2/runs.json"; echo '{}' > "$F2/timing.json"
S2="$CD/store-40"; : > "$CD/gh.log"
check "40 runs: writer exits 0" "0" "$(circ "$F2" "$S2" write)"
check "40 runs: 40 rows" "40" "$(nrows "$S2/ci-minutes.jsonl")"
check "40 runs: one listing call" "1" "$(grep -c 'actions/runs?' "$CD/gh.log")"
# a second that holds more runs than the API will ever return fails closed, stores nothing
F3="$CD/fx-dense"; mkdir -p "$F3"; gen_runs 300000 1200 0 60 > "$F3/runs.json"; echo '{}' > "$F3/timing.json"
check "1,200 runs in one second: fails closed" "1" "$(circ "$F3" "$CD/store-dense" write)"
check "truncated window stored nothing" "0" "$(nrows "$CD/store-dense/ci-minutes.jsonl")"

# (b) billed minutes beside wall minutes; (c) absent billing is "unknown", a real 0 stays 0
F4="$CD/fx-bill"; mkdir -p "$F4"
jq -nc '[{id: 7001, name: "CI", created_at: "2026-11-01T10:00:00Z", run_started_at: "2026-11-01T10:00:00Z", updated_at: "2026-11-01T10:04:00Z"},
         {id: 7002, name: "CI", created_at: "2026-11-02T10:00:00Z", run_started_at: "2026-11-02T10:00:00Z", updated_at: "2026-11-02T10:05:00Z"},
         {id: 7003, name: "CI", created_at: "2026-11-03T10:00:00Z", run_started_at: "2026-11-03T10:00:00Z", updated_at: "2026-11-03T10:03:00Z"},
         {id: 7004, name: "CI", created_at: "2026-11-04T10:00:00Z", run_started_at: "2026-11-04T10:00:00Z", updated_at: "2026-11-04T10:02:00Z"}]' > "$F4/runs.json"
jq -nc --argjson real "$REAL" '{"7001": ($real | .billable.UBUNTU.total_ms = 420000), "7002": ($real | .billable.UBUNTU.total_ms = 720000), "7004": $real}' > "$F4/timing.json"
S4="$CD/store-bill"
check "billing run: writer exits 0" "0" "$(circ "$F4" "$S4" write)"
LG="$S4/ci-minutes.jsonl"
check "run A: billed 7 beside wall 4" "7/4" "$(jq -r 'select(.run_id==7001) | "\(.billed_min)/\(.wall_min)"' "$LG")"
check "run B: billed 12 beside wall 5" "12/5" "$(jq -r 'select(.run_id==7002) | "\(.billed_min)/\(.wall_min)"' "$LG")"
check "A+B billed sum 19, wall sum 9" "19/9" "$(jq -rs '[.[] | select(.run_id==7001 or .run_id==7002)] | "\(map(.billed_min) | add)/\(map(.wall_min) | add)"' "$LG")"
check "run with no billing answer is the string unknown, not 0" '"unknown"' "$(jq -c 'select(.run_id==7003) | .billed_min' "$LG")"
check "real answer of 0 billed ms stays the number 0" "0" "$(jq -c 'select(.run_id==7004) | .billed_min' "$LG")"

# (d) report: billed next to wall, unknowns on their own line, run count beside gh's total_count
REP="$(CIM_FIX="$F4" CIM_LOG="$CD/gh.log" bash "$CIM" report --repo o/r --days 7 --until "$UNTIL" --store "$S4" --gh "$CD/bin/gh" 2>&1)" || REP="rc=$? $REP"
check "report: minutes line, billed beside wall" "yes" "$(grep -qx 'minutes: billed=19 wall=14' <<<"$REP" && echo yes || echo no)"
check "report: unknown runs on their own line" "yes" "$(grep -qx 'billed_unknown_runs: 1' <<<"$REP" && echo yes || echo no)"
check "report: run count beside gh total_count" "yes" "$(grep -qx 'runs: 4  gh_total_count: 4' <<<"$REP" && echo yes || echo no)"
# a timing failure that is not a 404/410 (rate limit, server error) aborts, never becomes unknown
F5="$CD/fx-502"; mkdir -p "$F5"; gen_runs 400000 3 1000 60 > "$F5/runs.json"; echo '{}' > "$F5/timing.json"; : > "$F5/timing-fail"
check "non-404 timing failure aborts the run" "1" "$(circ "$F5" "$CD/store-502" write)"
check "non-404 timing failure stored no unknown row" "0" "$(nrows "$CD/store-502/ci-minutes.jsonl")"
# (e) a rerun of a recorded run (same id, higher run_attempt, new timing) replaces its row:
# the id is stored once with the new attempt's minutes; the same attempt listed again stays untouched
F6="$CD/fx-rerun"; mkdir -p "$F6"
jq -nc '[{id: 8001, name: "CI", run_attempt: 1, created_at: "2026-11-01T10:00:00Z", run_started_at: "2026-11-01T10:00:00Z", updated_at: "2026-11-01T10:04:00Z"},
         {id: 8002, name: "CI", run_attempt: 1, created_at: "2026-11-02T10:00:00Z", run_started_at: "2026-11-02T10:00:00Z", updated_at: "2026-11-02T10:05:00Z"}]' > "$F6/runs.json"
jq -nc --argjson real "$REAL" '{"8001": ($real | .billable.UBUNTU.total_ms = 420000), "8002": ($real | .billable.UBUNTU.total_ms = 300000)}' > "$F6/timing.json"
S6="$CD/store-rerun"; LR="$S6/ci-minutes.jsonl"
check "rerun fixture: first write exits 0" "0" "$(circ "$F6" "$S6" write)"
check "attempt 1 stored: billed 7 beside wall 4, attempt 1" "7/4/1" "$(jq -r 'select(.run_id==8001) | "\(.billed_min)/\(.wall_min)/\(.run_attempt)"' "$LR")"
jq -nc '[{id: 8001, name: "CI", run_attempt: 2, created_at: "2026-11-01T10:00:00Z", run_started_at: "2026-11-01T11:00:00Z", updated_at: "2026-11-01T11:06:00Z"},
         {id: 8002, name: "CI", run_attempt: 1, created_at: "2026-11-02T10:00:00Z", run_started_at: "2026-11-02T10:00:00Z", updated_at: "2026-11-02T10:05:00Z"}]' > "$F6/runs.json"
jq -nc --argjson real "$REAL" '{"8001": ($real | .billable.UBUNTU.total_ms = 900000), "8002": ($real | .billable.UBUNTU.total_ms = 999000)}' > "$F6/timing.json"
: > "$CD/gh.log"
check "rerun listed again: writer exits 0" "0" "$(circ "$F6" "$S6" write)"
check "rerun: the run id is stored once" "" "$(jq -r '.run_id' "$LR" | sort | uniq -d)"
check "rerun: two runs, two rows" "2" "$(nrows "$LR")"
check "rerun: the row carries the new attempt's minutes" "15/6/2" "$(jq -r 'select(.run_id==8001) | "\(.billed_min)/\(.wall_min)/\(.run_attempt)"' "$LR")"
check "same attempt listed again keeps its stored minutes" "5/5/1" "$(jq -r 'select(.run_id==8002) | "\(.billed_min)/\(.wall_min)/\(.run_attempt)"' "$LR")"
check "same attempt is not re-fetched, the rerun is" "1" "$(grep -c 'timing' "$CD/gh.log")"
REP6="$(CIM_FIX="$F6" CIM_LOG="$CD/gh.log" bash "$CIM" report --repo o/r --days 7 --until "$UNTIL" --store "$S6" --gh "$CD/bin/gh" 2>&1)" || REP6="rc=$? $REP6"
check "report counts the rerun run once" "yes" "$(grep -qx 'minutes: billed=20 wall=11' <<<"$REP6" && grep -qx 'runs: 2  gh_total_count: 2' <<<"$REP6" && echo yes || echo no)"
# a store row written before run_attempt existed counts as attempt 1: a rerun refreshes it, a plain relist does not
S7="$CD/store-legacy"; mkdir -p "$S7"
printf '%s\n' '{"schema":1,"repo":"o/r","run_id":8001,"workflow":"CI","created_at":"2026-11-01T10:00:00Z","wall_min":4,"billed_min":7}' > "$S7/ci-minutes.jsonl"
check "legacy row (no run_attempt): rerun writer exits 0" "0" "$(circ "$F6" "$S7" write)"
check "legacy row refreshed by a rerun" "15/6/2" "$(jq -r 'select(.run_id==8001) | "\(.billed_min)/\(.wall_min)/\(.run_attempt)"' "$S7/ci-minutes.jsonl")"
check "legacy row: the run id is stored once" "" "$(jq -r '.run_id' "$S7/ci-minutes.jsonl" | sort | uniq -d)"
# a flag typo or a missing repo is refused
check "no --repo is refused" "1" "$(CIM_FIX="$F4" CIM_LOG="$CD/gh.log" bash "$CIM" write --store "$CD/store-x" --gh "$CD/bin/gh" >/dev/null 2>&1; echo $?)"

# --- release-judge-reconcile.sh: release judge transcripts against launch rows --------------------------
RJ="$HERE/release-judge-reconcile.sh"
RJD="$ROOT/rj"; mkdir -p "$RJD/projects/-tmp-rm-run-judge-AAA" "$RJD/logs"
rj_tr() { # sid first-ts last-ts cost
  { printf '{"type":"user","timestamp":"%s","message":{"content":"x"}}\n' "$2"
    printf '{"type":"assistant","timestamp":"%s"}\n' "$3"
    printf '{"type":"cost-state","sessionId":"%s","totalCostUSD":%s}\n' "$1" "$4"; } > "$RJD/projects/-tmp-rm-run-judge-AAA/$1.jsonl"
}
S1=11111111-1111-4111-8111-111111111111; S2=22222222-2222-4222-8222-222222222222
S3=33333333-3333-4333-8333-333333333333; S4=44444444-4444-4444-8444-444444444444
rj_tr $S1 2026-11-04T10:00:00.000Z 2026-11-04T10:01:00.000Z 1.5
rj_tr $S2 2026-11-04T11:00:00.000Z 2026-11-04T11:00:30.500Z 1.3725738
rj_tr $S3 2026-11-04T12:00:00.000Z 2026-11-04T12:00:01.000Z 0
rj_tr $S4 2026-11-04T13:00:00.000Z 2026-11-04T13:01:00.000Z 2
printf 'headed-arm-worker: profile=bare lane=native model=opus role=release-manager session=rm-judge-44444444 session_id=%s launched=2026-11-04T13:00:00Z\n' "$S4" > "$RJD/logs/rm-judge-44444444.log"
{
  printf '{"ts":"2026-11-04T10:01:01Z","kind":"judge","lane":"native","session_id":"%s","sub_cost_usd":"1.500000","cost_usd":""}\n' "$S1"
  printf '{"ts":"2026-11-04T11:00:31Z","kind":"judge","lane":"sub-fallback","sub_cost_usd":"1.372574","cost_usd":""}\n'
  printf '{"ts":"2026-11-04T12:00:02Z","kind":"judge","lane":"api","cost_usd":"0.000000"}\n'
  printf '{"ts":"2026-11-04T14:00:00Z","kind":"judge","lane":"sub-fallback","sub_cost_usd":"9.990000","cost_usd":""}\n'
  printf '{"ts":"2026-11-04T10:01:02Z","kind":"critic","lane":"api","cost_usd":"1.500000"}\n'
  echo null
} > "$RJD/launches.jsonl"
rj() { bash "$RJ" --launches "$RJD/launches.jsonl" --launch-logs "$RJD/logs" --projects "$RJD/projects" "$@"; }
RJ1="$(rj --tolerance 2)"
check "reconcile: rows and transcripts counted, the critic row and the null line ignored" "yes" \
  "$(grep -qxF "launch rows (kind=judge): 4  total \$12.86" <<<"$RJ1" && grep -qxF "transcripts: 4  total \$4.87" <<<"$RJ1" && echo yes || echo no)"
check "reconcile: matched by session id and by cost and time (a zero-cost row too)" "yes" \
  "$(grep -qx 'matched: 3  (by session id 1, by cost and time 2)' <<<"$RJ1" && echo yes || echo no)"
check "reconcile: the transcript with no row is counted, priced, and shows its launch-log line" "yes" \
  "$(grep -qxF "transcripts with no launch row: 1  total \$2  (with a launch-log line: 1)" <<<"$RJ1" && echo yes || echo no)"
check "reconcile: the row with no transcript is counted" "yes" "$(grep -qx 'launch rows with no transcript: 1' <<<"$RJ1" && echo yes || echo no)"
check "reconcile: class totals are far apart and the verdict says so" "yes" \
  "$(grep -qx 'OUTSIDE TOLERANCE 2%' <<<"$RJ1" && echo yes || echo no)"
RJU="$(rj --until 2026-11-04T13:00:00Z)"
check "reconcile: --until bounds both sides (the 13:00 transcript and the 14:00 row drop out)" "yes" \
  "$(grep -qxF "transcripts with no launch row: 0  total \$0  (with a launch-log line: 0)" <<<"$RJU" && echo yes || echo no)"
# GREEN: the missing row exists (carrying the session id) and the orphan row is gone
grep -v '9.990000' "$RJD/launches.jsonl" > "$RJD/launches.green"; mv "$RJD/launches.green" "$RJD/launches.jsonl"
printf '{"ts":"2026-11-04T13:01:01Z","kind":"judge","lane":"native","session_id":"%s","sub_cost_usd":"2.000000","cost_usd":""}\n' "$S4" >> "$RJD/launches.jsonl"
RJ2="$(rj --tolerance 2)"
check "reconcile green: no unmatched transcript, all four matched" "yes" \
  "$(grep -qxF "matched: 4  (by session id 2, by cost and time 2)" <<<"$RJ2" && grep -qxF "transcripts with no launch row: 0  total \$0  (with a launch-log line: 0)" <<<"$RJ2" && echo yes || echo no)"
check "reconcile green: the class totals agree inside the tolerance" "yes" \
  "$(grep -qx 'WITHIN TOLERANCE 2%' <<<"$RJ2" && grep -q 'difference 0%' <<<"$RJ2" && echo yes || echo no)"
# idempotent control: a second run changes nothing, in the ledger or in the output
SUM1="$(cksum < "$RJD/launches.jsonl")"; RJ3="$(rj --tolerance 2)"
check "reconcile is read-only and repeatable: ledger bytes and output unchanged" "yes" \
  "$([ "$SUM1" = "$(cksum < "$RJD/launches.jsonl")" ] && [ "$RJ2" = "$RJ3" ] && echo yes || echo no)"
# a row written before the run ended cannot be that run's row; the default ledger follows the writers' state path
S5=55555555-5555-4555-8555-555555555555
RJE="$ROOT/rj-early"; mkdir -p "$RJE/projects/-tmp-rm-run-judge-BBB"
{ printf '{"type":"user","timestamp":"2026-11-04T15:00:00.000Z"}\n{"type":"assistant","timestamp":"2026-11-04T15:00:30.000Z"}\n'
  printf '{"type":"cost-state","sessionId":"%s","totalCostUSD":3}\n' "$S5"; } > "$RJE/projects/-tmp-rm-run-judge-BBB/$S5.jsonl"
printf '{"ts":"2026-11-04T15:00:10Z","kind":"judge","lane":"sub-fallback","sub_cost_usd":"3.000000","cost_usd":""}\n' > "$RJE/launches.jsonl"
RJEO="$(bash "$RJ" --launches "$RJE/launches.jsonl" --launch-logs "$RJE/none" --projects "$RJE/projects")"
check "reconcile: a row stamped 20s before the run ended does not match it" "yes" \
  "$(grep -qx "matched: 0  (by session id 0, by cost and time 0)" <<<"$RJEO" && grep -qxF "launch rows with no transcript: 1" <<<"$RJEO" && echo yes || echo no)"
# an unreadable transcript is never a green verdict: it is counted, the verdict reads INCOMPLETE and the exit is 1
RJB="$ROOT/rj-bad"; mkdir -p "$RJB/projects/-tmp-rm-run-judge-CCC"
cp "$RJD/projects/-tmp-rm-run-judge-AAA/$S1.jsonl" "$RJB/projects/-tmp-rm-run-judge-CCC/$S1.jsonl"
printf '{"type":"assistant","timestamp":"2026-11-04T10:00:00.000Z"}\n{"type":"cost-st' > "$RJB/projects/-tmp-rm-run-judge-CCC/$S2.jsonl"
printf '{"ts":"2026-11-04T10:01:01Z","kind":"judge","lane":"native","session_id":"%s","sub_cost_usd":"1.500000","cost_usd":""}\n' "$S1" > "$RJB/launches.jsonl"
RJBO="$(bash "$RJ" --launches "$RJB/launches.jsonl" --launch-logs "$RJB/none" --projects "$RJB/projects" --tolerance 2 2>/dev/null)" && RJBRC=0 || RJBRC=$?
check "reconcile: an unreadable transcript gives INCOMPLETE, never WITHIN TOLERANCE, and exit 1" "yes" \
  "$([ "$RJBRC" = 1 ] && grep -qxF "unreadable transcripts skipped: 1  (not in any count or total above)" <<<"$RJBO" && grep -q '^INCOMPLETE: 1 transcript' <<<"$RJBO" && ! grep -q 'WITHIN TOLERANCE' <<<"$RJBO" && echo yes || echo no)"
bash "$RJ" --launches "$RJD/launches.jsonl" --launch-logs "$RJD/logs" --projects "$RJD/projects" --tolerance abc >/dev/null 2>&1 && RJTRC=0 || RJTRC=$?
check "reconcile: a failing report (a malformed --tolerance) exits non-zero, never 0" "yes" "$([ "$RJTRC" -ne 0 ] && echo yes || echo no)"
RJD2="$(HIMMEL_API_CREDIT_STATE="$RJD/ledger.json" bash "$RJ" --launch-logs "$RJD/logs" --projects "$RJD/projects" --tolerance 2)"
check "reconcile: with no --launches the ledger is the one beside HIMMEL_API_CREDIT_STATE" "$RJ3" "$RJD2"

# 9. phase-cost rows: one row per (day, session, phase), priced from scripts/lanes/lib/model-prices.tsv.
# Synthetic transcripts, a sandboxed HOME and TZ=UTC (the day is the local day); never the real store.
PCH="$ROOT/pc-home"; mkdir -p "$PCH"
PCP="$ROOT/pc/projects"; PCS="$PCP/slug"; mkdir -p "$PCS"
PCW=11111111-1111-4111-8111-111111111111; PCC=22222222-2222-4222-8222-222222222222
PCU=33333333-3333-4333-8333-333333333333
arow() { # sid ts msgid model in out cr c5 c1 [toolname toolinput-json]
  jq -nc --arg s "$1" --arg ts "$2" --arg id "$3" --arg m "$4" --argjson i "$5" --argjson o "$6" --argjson cr "$7" \
    --argjson c5 "$8" --argjson c1 "$9" --arg tn "${10:-}" --argjson ti "${11:-null}" \
    '{type:"assistant",sessionId:$s,timestamp:$ts,requestId:("req_"+$id),message:{id:$id,model:$m,
      content:(if $tn == "" then [{type:"text",text:"x"}] else [{type:"tool_use",name:$tn,input:$ti}] end),
      usage:{input_tokens:$i,output_tokens:$o,cache_read_input_tokens:$cr,cache_creation_input_tokens:($c5+$c1),
             cache_creation:{ephemeral_5m_input_tokens:$c5,ephemeral_1h_input_tokens:$c1}}}}'
}
OP=claude-opus-5-5
{
  echo '{"type":"custom-title","customTitle":"HIMMEL-9999-N1-pc","sessionId":"'$PCW'"}'
  arow $PCW 2026-11-04T10:00:00.000Z m1 $OP 1000 100 10000 2000 1000                                  # no tool before: boot
  arow $PCW 2026-11-04T10:00:01.000Z m1 $OP 1000 100 10000 2000 1000 Bash '{"command":"bash scripts/cr/pr-check-context.sh"}'
  arow $PCW 2026-11-04T10:00:05.000Z m2 $OP 2000 200 20000 0 0 Read '{"file_path":"/x"}'              # after a cr script: review
  arow $PCW 2026-11-04T10:00:10.000Z m3 $OP 500 50 5000 0 0 Bash '{"command":"git commit -m x"}'      # after a Read: build
  arow $PCW 2026-11-05T09:00:00.000Z m4 $OP 100 10 1000 0 0                                           # after a commit: ship, next day
} > "$PCS/$PCW.jsonl"
mkdir -p "$PCS/$PCW/subagents"
arow $PCW 2026-11-04T10:00:07.000Z j1 claude-sonnet-5-5 1000 100 0 0 0 > "$PCS/$PCW/subagents/agent-j1.jsonl"
echo '{"agentType":"judge"}' > "$PCS/$PCW/subagents/agent-j1.meta.json"
{
  echo '{"type":"custom-title","customTitle":"HIMMEL-9998-N2-codex","sessionId":"'$PCC'"}'
  arow $PCC 2026-11-04T11:00:00.000Z g1 gpt-6.1-sol 1000 100 10000 0 0
} > "$PCS/$PCC.jsonl"
{
  echo '{"type":"custom-title","customTitle":"HIMMEL-9997-N3-mystery","sessionId":"'$PCU'"}'
  arow $PCU 2026-11-04T12:00:00.000Z u1 mystery-model-9 1000 100 10000 0 0
} > "$PCS/$PCU.jsonl"
PCSTORE="$ROOT/pc-store"
pcrun() { HOME="$PCH" TZ=UTC bash "$COMPUTE" --projects "$PCP" --ledger "$LEDGER" --store "$PCSTORE"; }
# the stub nice/ionice record that the pass asked for idle priority
PCBIN="$ROOT/pc-bin"; mkdir -p "$PCBIN"
for t in renice ionice nice; do printf '#!/bin/sh\necho "%s $*" >> "%s/idle.log"\nexit 0\n' "$t" "$PCBIN" > "$PCBIN/$t"; chmod +x "$PCBIN/$t"; done
pcphase() { jq -c 'select(.kind=="phase-cost")' "$PCSTORE/records.jsonl" 2>/dev/null || true; }
PATH="$PCBIN:$PATH" pcrun >/dev/null
PC1="$(pcphase)"
check "phase-cost: one row per (day, session, phase), 4 for the worker" "4" \
  "$(printf '%s\n' "$PC1" | jq -rs --arg s "$PCW" '[.[] | select(.session==$s)] | length')"
check "phase-cost: the rows exist for the worker, codex, mystery and judge sessions (7)" "7" "$(printf '%s\n' "$PC1" | jq -s 'length')"
check "phase-cost: the review row, every field" \
  '{"kind":"phase-cost","day":"2026-11-04","session":"'$PCW'","parent":null,"lane":"claude","class":"worker","model":"claude-opus-5-5","phase":"review","phase_rule":"v1","calls":1,"in":2000,"out":200,"cache_read":20000,"cc_5m":0,"cc_1h":0,"usd":0.016,"mark":"derived"}' \
  "$(printf '%s\n' "$PC1" | jq -c --arg s "$PCW" 'select(.session==$s and .phase=="review")')"
check "phase-cost: the day changes the row (ship on 11-05)" "2026-11-05" \
  "$(printf '%s\n' "$PC1" | jq -r --arg s "$PCW" 'select(.session==$s and .phase=="ship") | .day')"
check "phase-cost: calls before any tool are boot" "1" \
  "$(printf '%s\n' "$PC1" | jq -r --arg s "$PCW" 'select(.session==$s and .phase=="boot") | .calls')"
check "phase-cost: a streamed message (two rows, one id) is one call with the cache-write split" \
  "1/2000/1000" "$(printf '%s\n' "$PC1" | jq -r --arg s "$PCW" 'select(.session==$s and .phase=="boot") | "\(.calls)/\(.cc_5m)/\(.cc_1h)"')"
check "phase-cost: the judge subagent has its own session, the worker as parent, class judge, counted" \
  "agent-j1/$PCW/judge/judge/counted/0.003" \
  "$(printf '%s\n' "$PC1" | jq -r 'select(.class=="judge") | "\(.session)/\(.parent)/\(.class)/\(.phase)/\(.mark)/\(.usd)"')"
# reconcile: the priced total of the worker equals the fixture's hand-priced sum
# m1 26000 + m2 16000 + m3 4000 + m4 800 micro-dollars = 0.0468
check "phase-cost: the worker's priced total reconciles to the fixture (0.0468)" "0.0468" \
  "$(printf '%s\n' "$PC1" | jq -rs --arg s "$PCW" '[.[] | select(.session==$s) | .usd] | add | . * 1000000 | round / 1000000')"
# a codex-lane session is priced at its own row, never Opus; an unpriced model is null, never a fallback
check "phase-cost: a gpt-6.1-sol session is codex lane at its own price (0.004, not the Opus 0.008)" \
  "codex/gpt-6.1-sol/0.004/derived" \
  "$(printf '%s\n' "$PC1" | jq -r --arg s "$PCC" 'select(.session==$s) | "\(.lane)/\(.model)/\(.usd)/\(.mark)"')"
check "phase-cost: a model with no price row is usd null and marked unpriced" "null/unpriced" \
  "$(printf '%s\n' "$PC1" | jq -r --arg s "$PCU" 'select(.session==$s) | "\(.usd)/\(.mark)"')"
# the pass asked for idle priority
check "phase-cost: the run asked for idle cpu and io priority" "yes" \
  "$(grep -q 'renice -n 19' "$PCBIN/idle.log" 2>/dev/null && grep -q 'ionice -c3' "$PCBIN/idle.log" 2>/dev/null && echo yes || echo no)"
# a reader without --ticket still works with phase-cost rows in the store
rc=0; PCREAD="$(bash "$READ" --store "$PCSTORE" 2>"$ROOT/pc-read.err")" || rc=$?
check "usage-read with no --ticket works with phase-cost rows present" "0" "$rc"
check "usage-read returns only ticket records" "0" "$(printf '%s\n' "$PCREAD" | jq -s '[.[] | select(.kind=="phase-cost")] | length')"
# a second run adds nothing
pc_h="$(cksum < "$PCSTORE/records.jsonl")"
pcrun >/dev/null
check "phase-cost: a second run adds nothing (store byte-identical)" "$pc_h" "$(cksum < "$PCSTORE/records.jsonl")"
# byte offset: new bytes (a repeat of m4's id, as when a message streams across two runs, and a new call)
# change one row only; a re-read from byte 0 would double every call
pc_n="$(pcphase | wc -l | tr -d ' ')"
{ arow $PCW 2026-11-05T09:00:00.500Z m4 $OP 100 10 1000 0 0
  arow $PCW 2026-11-05T09:30:00.000Z m5 $OP 100 10 1000 0 0; } >> "$PCS/$PCW.jsonl"
pcrun >/dev/null
check "phase-cost: new bytes append exactly one changed row" "$((pc_n + 1))" "$(pcphase | wc -l | tr -d ' ')"
check "phase-cost: the changed row counts the repeated id once and the new call once (2 calls, 200 in)" "2/200" \
  "$(pcphase | jq -sr --arg s "$PCW" '[.[] | select(.session==$s and .phase=="ship")] | last | "\(.calls)/\(.in)"')"
check "phase-cost: the unchanged rows were not re-counted (review still 1 call)" "1" \
  "$(pcphase | jq -sr --arg s "$PCW" '[.[] | select(.session==$s and .phase=="review")] | last | .calls')"
# --print touches no store
PCPRINT="$(HOME="$PCH" TZ=UTC bash "$COMPUTE" --projects "$PCP" --ledger "$LEDGER" --print | jq -c 'select(.kind=="phase-cost")' | wc -l | tr -d ' ')"
check "phase-cost: --print shows the rows and writes no store" "7/no" "$PCPRINT/$([ -e "$PCH/.himmel" ] && echo yes || echo no)"

# 10. phase-cost: classes, the live-file and replaced-file cases, repeated ids, long paths, and what the state keeps.
PC2P="$ROOT/pc2/projects"; PC2S="$PC2P/slug"; mkdir -p "$PC2S"
PC2STORE="$ROOT/pc2-store"
pc2run() { HOME="$PCH" TZ=UTC bash "$COMPUTE" --projects "$PC2P" --ledger "$LEDGER" --store "$PC2STORE" >/dev/null; }
pc2() { # session -> "class/phase/mark/calls" for each phase's latest row, comma-joined
  jq -sr --arg s "$1" '[.[] | select(.kind=="phase-cost" and .session==$s)] | group_by(.phase) | map(last) | map("\(.class)/\(.phase)/\(.mark)/\(.calls)") | join(",")' "$PC2STORE/records.jsonl"
}
uprow() { jq -nc --arg t "$1" '{type:"user",message:{content:$t}}'; }
SCH=aaaaaaaa-2222-4222-8222-000000000001; SW2=aaaaaaaa-2222-4222-8222-000000000002; SCR=aaaaaaaa-2222-4222-8222-000000000003
SRM=aaaaaaaa-2222-4222-8222-000000000004; SNA=aaaaaaaa-2222-4222-8222-000000000005; SPL=aaaaaaaa-2222-4222-8222-000000000006
SSH=aaaaaaaa-2222-4222-8222-000000000007; SCL=aaaaaaaa-2222-4222-8222-000000000008; SLG=aaaaaaaa-2222-4222-8222-000000000009
T=2026-11-04T10:00
{ echo '{"type":"custom-title","customTitle":"HIMMEL-nextleg-chief"}'; arow $SCH $T:00.000Z h1 $OP 10 1 100 0 0 Read '{"file_path":"/x"}'; } > "$PC2S/$SCH.jsonl"
mkdir -p "$PC2S/$SCH/subagents"
arow $SCH $T:05.000Z h2 $OP 10 1 100 0 0 > "$PC2S/$SCH/subagents/agent-c1.jsonl"; echo '{"agentType":"general-purpose"}' > "$PC2S/$SCH/subagents/agent-c1.meta.json"
{ echo '{"type":"custom-title","customTitle":"HIMMEL-9996-N4-w"}'; arow $SW2 $T:00.000Z w1 $OP 10 1 100 0 0; } > "$PC2S/$SW2.jsonl"
mkdir -p "$PC2S/$SW2/subagents"
arow $SW2 $T:05.000Z w2 $OP 10 1 100 0 0 > "$PC2S/$SW2/subagents/agent-w1.jsonl"; echo '{"agentType":"general-purpose"}' > "$PC2S/$SW2/subagents/agent-w1.meta.json"
arow $SW2 $T:06.000Z w3 $OP 10 1 100 0 0 > "$PC2S/$SW2/subagents/agent-b1.jsonl"; echo '{"agentType":"brief-drafter"}' > "$PC2S/$SW2/subagents/agent-b1.meta.json"
{ uprow "Read ./review-prompt.md SECRETSENTINEL2"; arow $SCR $T:00.000Z r1 $OP 10 1 100 0 0; } > "$PC2S/$SCR.jsonl"
{ uprow "You are the release manager for SECRETSENTINEL2"; arow $SRM $T:00.000Z m1 $OP 10 1 100 0 0; } > "$PC2S/$SRM.jsonl"
{ echo '{"type":"custom-title","customTitle":"HIMMEL-9995-N5-na"}'
  arow $SNA $T:00.000Z n1 $OP 10 1 100 0 0 Read '{"file_path":"/x"}'; arow $SNA $T:01.000Z n2 $OP 10 1 100 0 0
  arow $SNA $T:02.000Z n1 $OP 10 1 100 0 0; } > "$PC2S/$SNA.jsonl"
{ echo '{"type":"custom-title","customTitle":"HIMMEL-9994-N6-pl"}'; arow $SPL $T:00.000Z p1 $OP 10 1 100 0 0; } > "$PC2S/$SPL.jsonl"
{ echo '{"type":"custom-title","customTitle":"HIMMEL-9993-N7-sh"}'; arow $SSH $T:00.000Z s1 $OP 10 1 100 0 0; arow $SSH $T:01.000Z s2 $OP 10 1 100 0 0; } > "$PC2S/$SSH.jsonl"
arow $SCL $T:00.000Z c1 $OP 10 1 100 0 0 > "$PC2S/$SCL.jsonl"
LONGSLUG="$(printf '%0190d' 0 | tr 0 a)"; mkdir -p "$PC2P/$LONGSLUG/$SLG/subagents"
arow $SLG $T:00.000Z l1 $OP 10 1 100 0 0 > "$PC2P/$LONGSLUG/$SLG/subagents/agent-aaaaaaaaaaaaaaaaa.jsonl"
rc=0; pc2run || rc=$?
check "phase-cost: a path of about 270 characters does not fail the run" "0" "$rc"
check "phase-cost: a subagent under a 190-character project slug is priced" "1" \
  "$(jq -sr '[.[] | select(.kind=="phase-cost" and .session=="agent-aaaaaaaaaaaaaaaaa")] | length' "$PC2STORE/records.jsonl")"
check "phase-cost: a chief session is all chief-turns, counted" "chief/chief-turns/counted/1" "$(pc2 $SCH)"
check "phase-cost: a chief's subagent goes to chief-turns, counted" "subagent/chief-turns/counted/1" "$(pc2 agent-c1)"
check "phase-cost: a worker's subagent is phase agent, counted" "subagent/agent/counted/1" "$(pc2 agent-w1)"
check "phase-cost: a brief-drafter is chief-turns, counted" "brief-drafter/chief-turns/counted/1" "$(pc2 agent-b1)"
check "phase-cost: a critic (first prompt Read ./review-prompt.md) is its own phase, counted" "critic/critic/counted/1" "$(pc2 $SCR)"
check "phase-cost: a release manager (first prompt) is its own phase, counted" "release-mgr/release-mgr/counted/1" "$(pc2 $SRM)"
check "phase-cost: a message id repeated non-adjacently counts once" "worker/boot/derived/1,worker/build/derived/1" "$(pc2 $SNA)"
# a live transcript: a last line with no newline is still being written, so it waits for its newline
# (the row is whole JSON, which usage-attribution accepts; the half-JSON case stops that script first)
r2="$(arow $SPL $T:05.000Z p2 $OP 10 1 100 0 0)"
printf '%s' "$r2" >> "$PC2S/$SPL.jsonl"
pc2run
check "phase-cost: a last line with no newline is not read yet" "worker/boot/derived/1" "$(pc2 $SPL)"
printf '\n' >> "$PC2S/$SPL.jsonl"
pc2run
check "phase-cost: once its newline arrives the line is counted, once" "worker/boot/derived/2" "$(pc2 $SPL)"
# a replaced (shorter) transcript is read again from its start
{ echo '{"type":"custom-title","customTitle":"HIMMEL-9993-N7-sh"}'; arow $SSH $T:00.000Z s9 $OP 10 1 100 0 0; } > "$PC2S/$SSH.jsonl"
pc2run
check "phase-cost: a file that shrank is read again, not skipped" "worker/boot/derived/1" "$(pc2 $SSH)"
# a class that changes closes the rows it moved: the old key gets a zero row, the new one the calls
check "phase-cost: before a title the session is class other, phase boot" "other/boot/derived/1" "$(pc2 $SCL)"
echo '{"type":"custom-title","customTitle":"HIMMEL-9992-chief"}' >> "$PC2S/$SCL.jsonl"
pc2run
check "phase-cost: a later title moves the calls and closes the old row with zero" "other/boot/derived/0,chief/chief-turns/counted/1" "$(pc2 $SCL)"
check "phase-cost: the closed row has zero tokens and zero dollars" "0/0" \
  "$(jq -sr --arg s $SCL '[.[] | select(.kind=="phase-cost" and .session==$s and .phase=="boot")] | last | "\(.in)/\(.usd)"' "$PC2STORE/records.jsonl")"
# the state holds ids, counts and class words only: no title and no message text
check "phase-cost: the state directory holds no title and no message text" "0" \
  "$(grep -rlE 'N4-w|N5-na|SECRETSENTINEL2' "$PC2STORE/phase-cost-state" | wc -l | tr -d ' ')"
check "phase-cost: the store holds no message text" "0" "$(grep -c 'SECRETSENTINEL2' "$PC2STORE/records.jsonl" || true)"

# the phase-cost dollars equal the repo's other price reader (model-price.mjs transcripts) on the same directory:
# one table, the same per-message dedupe, and the sums reach cents
PC3P="$ROOT/pc3/projects"; PC3S="$PC3P/slug"; mkdir -p "$PC3S"
SQ=aaaaaaaa-3333-4333-8333-000000000001
{ echo '{"type":"custom-title","customTitle":"HIMMEL-9991-N8-q"}'
  arow $SQ 2026-11-04T10:00:00.000Z q1 $OP 1000000 100000 5000000 200000 100000 Read '{"file_path":"/x"}'
  arow $SQ 2026-11-04T10:00:01.000Z q2 claude-sonnet-5-5 2000000 50000 1000000 0 400000
  arow $SQ 2026-11-04T10:00:02.000Z q1 $OP 1000000 100000 5000000 200000 100000
  arow $SQ 2026-11-04T10:00:03.000Z q3 gpt-6.1-sol 3000000 30000 0 0 0; } > "$PC3S/$SQ.jsonl"
mkdir -p "$PC3S/$SQ/subagents"
arow $SQ 2026-11-04T10:00:04.000Z q4 $OP 500000 20000 2500000 0 300000 > "$PC3S/$SQ/subagents/agent-q.jsonl"
PC3STORE="$ROOT/pc3-store"
HOME="$PCH" TZ=UTC bash "$COMPUTE" --projects "$PC3P" --ledger "$LEDGER" --store "$PC3STORE" >/dev/null
MP_CENTS="$(node "$HERE/../lanes/model-price.mjs" transcripts "$PC3P" | sed -n 's/^total usd=\([0-9]*\)\.\([0-9][0-9]\).*/\1\2/p')"
check "phase-cost: the dollars equal model-price.mjs on the same directory, in cents (non-adjacent repeat included)" "$((10#$MP_CENTS))" \
  "$(jq -sr '[.[] | select(.kind=="phase-cost") | .usd] | add | . * 100 | round' "$PC3STORE/records.jsonl")"

# 11. the build runs in windows: the sessions whose newest transcript changed on one day, newest day first.
# Each window appends its phase-cost rows and moves the checkpoint; a budget or a window count ends a run
# cleanly; a killed run resumes where it stopped and ends byte-identical to one uninterrupted run.
WP="$ROOT/win/projects"; WS="$WP/slug"; mkdir -p "$WS"
WX1=bbbbbbbb-1111-4111-8111-000000000001; WX2=bbbbbbbb-1111-4111-8111-000000000002; WX3=bbbbbbbb-1111-4111-8111-000000000003
{ echo '{"type":"custom-title","customTitle":"HIMMEL-9001-N1-w1"}'
  row $WX1 false 2026-11-02T10:00:00.000Z x1 10 100 5 20; arow $WX1 2026-11-02T10:00:01.000Z y1 $OP 10 1 100 0 0; } > "$WS/$WX1.jsonl"
{ echo '{"type":"custom-title","customTitle":"HIMMEL-nextleg-chief"}'
  row $WX2 false 2026-11-03T10:00:00.000Z x2 11 101 6 21; arow $WX2 2026-11-03T10:00:01.000Z y2 $OP 10 1 100 0 0; } > "$WS/$WX2.jsonl"
{ echo '{"type":"custom-title","customTitle":"HIMMEL-9002-N2-w3"}'
  row $WX3 false 2026-11-04T10:00:00.000Z x3 12 102 7 22; arow $WX3 2026-11-04T10:00:01.000Z y3 $OP 10 1 100 0 0; } > "$WS/$WX3.jsonl"
mkdir -p "$WS/$WX3/subagents"
arow $WX3 2026-11-04T10:00:02.000Z y4 $OP 10 1 100 0 0 > "$WS/$WX3/subagents/agent-w3.jsonl"
TZ=UTC touch -t 202611021200 "$WS/$WX1.jsonl"; TZ=UTC touch -t 202611031200 "$WS/$WX2.jsonl"
TZ=UTC touch -t 202611041200 "$WS/$WX3.jsonl" "$WS/$WX3/subagents/agent-w3.jsonl"
WL="$ROOT/win/ledger.jsonl"; : > "$WL"
wrun() { # store args... ; stderr to $ROOT/win/err
  local st="$1"; shift
  HOME="$PCH" TZ=UTC bash "$COMPUTE" --projects "$WP" --ledger "$WL" --store "$st" "$@" 2>"$ROOT/win/err"
}
wdays() { jq -r 'select(.kind=="phase-cost") | .day' "$1/records.jsonl" 2>/dev/null | sort -u | tr '\n' ' '; }
# start a run that holds at a pause point, wait until it gets there, then SIGKILL it
wkill() { # store point
  local st="$1" pf="$ROOT/win/pause-$2" i=0 pid
  : > "$pf"
  HOME="$PCH" TZ=UTC USAGE_COMPUTE_TEST_PAUSE_AT="$2" USAGE_COMPUTE_TEST_PAUSE_FILE="$pf" \
    bash "$COMPUTE" --projects "$WP" --ledger "$WL" --store "$st" >/dev/null 2>&1 & pid=$!
  while [ ! -e "$pf.reached" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
  kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  rm -f "$pf"
  [ -e "$pf.reached" ] && echo reached || echo "never reached"
}

# (a) chunked: after window 1 the newest day's rows are in the store, two windows pending
WA="$ROOT/win/store-a"
rc=0; wrun "$WA" --max-windows 1 >/dev/null || rc=$?
check "windows (a): a run stopped after window 1 exits 0" "0" "$rc"
check "windows (a): the newest day's phase rows are stored while two windows are pending" "2026-11-04 " "$(wdays "$WA")"
check "windows (a): the run names the windows that remain" "yes" "$(grep -q '2 window(s) remain' "$ROOT/win/err" && echo yes || echo no)"
check "windows (a): no ticket record while windows remain (no partial totals)" "0" \
  "$(jq -s '[.[] | select(.ticket != null)] | length' "$WA/records.jsonl" 2>/dev/null || echo missing)"

# (b) bounded: a budget spent during window 1 ends the run after it, rc 0, naming what remains
WB="$ROOT/win/store-b"; PB="$ROOT/win/pause-b"; : > "$PB"
HOME="$PCH" TZ=UTC USAGE_COMPUTE_TEST_PAUSE_AT=window:1 USAGE_COMPUTE_TEST_PAUSE_FILE="$PB" \
  bash "$COMPUTE" --projects "$WP" --ledger "$WL" --store "$WB" --budget-seconds 1 >/dev/null 2>"$ROOT/win/err-b" & bp=$!
i=0; while [ ! -e "$PB.reached" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
sleep 2; rm -f "$PB"
rc=0; wait "$bp" || rc=$?
check "windows (b): a run past its budget exits 0" "0" "$rc"
check "windows (b): it stops after the window in flight and says 2 remain" "yes" "$(grep -q 'budget' "$ROOT/win/err-b" && grep -q '2 window(s) remain' "$ROOT/win/err-b" && echo yes || echo no)"
check "windows (b): only the first window's rows were stored" "2026-11-04 " "$(wdays "$WB")"
check "windows (b): the budget run released the store lock" "no" "$([ -d "$WB/.lock" ] && echo yes || echo no)"

# the reference: one uninterrupted run, no budget
WU="$ROOT/win/store-u"
rc=0; wrun "$WU" --budget-seconds 0 >/dev/null || rc=$?
check "windows: one uninterrupted run exits 0 with all three days" "0/2026-11-02 2026-11-03 2026-11-04 " "$rc/$(wdays "$WU")"
check "windows: the uninterrupted run appends the ticket records at its end" "3" \
  "$(jq -s '[.[] | select(.ticket != null)] | length' "$WU/records.jsonl")"
# each window reads its sessions through a scratch root of symlinks: the totals equal usage-attribution.sh on the real root
WBA="$(bash "$BANK" "$WP" | grep -F "| $T1-N1-w1 |" | awk -F' [|] ' '{print $4"/"$5"/"$6"/"$7"/"$8}')"
check "windows: attribution on the real root counts the session (fixture guard)" "2/20/200/5/21" "$WBA"
check "windows: a session read through the symlinked window root keeps its rows (equal to attribution on the real root)" "$WBA" \
  "$(bash "$READ" --store "$WU" --ticket HIMMEL-9001 2>/dev/null | jq -r '.legs[0] | "\(.turns)/\(.input)/\(.cache_read)/\(.cache_create)/\(.output)"')"

# (c) resumable: SIGKILL after window 1 committed; the rerun does windows 2 and 3 only and ends byte-identical
WC="$ROOT/win/store-c"
check "windows (c): the run reached the pause after window 1" "reached" "$(wkill "$WC" window:1)"
check "windows (c): a SIGKILL leaves the store lock (no trap runs)" "yes" "$([ -d "$WC/.lock" ] && echo yes || echo no)"
check "windows (c): the left lock names the killed run's pid" "yes" "$([ -s "$WC/.lock/pid" ] && echo yes || echo no)"
rm -f "$WC/.lock/pid"; rmdir "$WC/.lock"   # what the refusal tells the operator to do once no run is active
rc=0; wrun "$WC" --budget-seconds 0 >/dev/null || rc=$?
check "windows (c): the rerun exits 0" "0" "$rc"
check "windows (c): the rerun did not rebuild window 1 (2026-11-04)" "no" "$(grep -q 'window 2026-11-04' "$ROOT/win/err" && echo yes || echo no)"
check "windows (c): the rerun built the two windows left" "2" "$(grep -c '^usage-compute: window .* done' "$ROOT/win/err" || true)"
check "windows (c): killed then resumed ends byte-identical to one uninterrupted run" "same" \
  "$(cmp -s "$WC/records.jsonl" "$WU/records.jsonl" && echo same || echo differ)"

# (d) a rerun with nothing new builds no window and appends nothing
wc_h="$(cksum < "$WC/records.jsonl")"
rc=0; wrun "$WC" >/dev/null || rc=$?
check "windows (d): a rerun with nothing new exits 0 and appends nothing" "0/$wc_h" "$rc/$(cksum < "$WC/records.jsonl")"
check "windows (d): it says no window is left to build" "yes" "$(grep -q '0 window(s) to build' "$ROOT/win/err" && echo yes || echo no)"

# (e) the phase-cost offsets are saved per transcript: a SIGKILL after the first one keeps its state,
# and the rerun reads only the transcript that was not saved yet
WE="$ROOT/win/store-e"
check "windows (e): the run reached the pause after the first transcript" "reached" "$(wkill "$WE" file:1)"
check "windows (e): the first transcript's offset is saved before its window is committed" "1/0" \
  "$(find "$WE/phase-cost-state" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')/$(if [ -f "$WE/records.jsonl" ]; then wc -l < "$WE/records.jsonl" | tr -d ' '; else echo 0; fi)"
rm -f "$WE/.lock/pid"; rmdir "$WE/.lock"
rc=0; wrun "$WE" --budget-seconds 0 >/dev/null || rc=$?
check "windows (e): the rerun reads only the transcript left in window 1" "yes" \
  "$(grep -q '^usage-compute: window 2026-11-04 done: 1 sessions, 1 transcripts read' "$ROOT/win/err" && echo yes || echo no)"
check "windows (e): the rerun ends byte-identical to one uninterrupted run" "same" \
  "$(cmp -s "$WE/records.jsonl" "$WU/records.jsonl" && echo same || echo differ)"

# a store written before the windows (one global emitted.json, no checkpoint) re-emits its phase rows once with the
# same values; usage-read keeps the latest row per (day, session, phase), so the total read back is not doubled
WLG="$ROOT/win/store-legacy"; cp -R "$WU" "$WLG"
rm -rf "$WLG/build-checkpoint.json" "$WLG/phase-cost-state/emitted"; echo '{}' > "$WLG/phase-cost-state/emitted.json"
n0="$(jq -s '[.[] | select(.kind=="phase-cost")] | length' "$WLG/records.jsonl")"
rc=0; wrun "$WLG" --budget-seconds 0 >/dev/null || rc=$?
check "windows: a legacy store's rerun exits 0 and re-emits each phase row once" "0/$((n0 * 2))" \
  "$rc/$(jq -s '[.[] | select(.kind=="phase-cost")] | length' "$WLG/records.jsonl")"
check "windows: the re-emitted rows read back as the same rows, calls not doubled" \
  "$(bash "$READ" --store "$WU" --phase-cost | jq -s '[length, (map(.calls) | add)]' | tr -d ' \n')" \
  "$(bash "$READ" --store "$WLG" --phase-cost | jq -s '[length, (map(.calls) | add)]' | tr -d ' \n')"

# a held store lock: the refusal names the lock, the owner pid it holds and whether that pid runs
WK="$ROOT/win/store-lock"; mkdir -p "$WK/.lock"
# lockmsg <text>: yes when the refused run's last stderr line holds <text> (the run's own rc 1 is expected)
lockmsg() {
  local m
  m="$(HOME="$PCH" TZ=UTC USAGE_COMPUTE_TEST_LOCK_TRIES=2 bash "$COMPUTE" --projects "$WP" --ledger "$WL" --store "$WK" 2>&1 >/dev/null || true)"
  grep -qF "$1" <<<"$(tail -n 1 <<<"$m")" && echo yes || echo no
}
echo 999999 > "$WK/.lock/pid"
check "lock: a dead owner pid is named as not running" "yes" "$(lockmsg "store locked: $WK/.lock (owner pid 999999, not running")"
echo $$ > "$WK/.lock/pid"
check "lock: a live owner pid is named as running" "yes" "$(lockmsg "store locked: $WK/.lock (owner pid $$, running")"
rm -f "$WK/.lock/pid"
check "lock: a lock with no pid (a reader's) says the owner is unknown" "yes" "$(lockmsg "store locked: $WK/.lock (owner unknown")"
rmdir "$WK/.lock"

if [ "$FAIL" -eq 0 ]; then echo "PASS"; else echo "FAILED" >&2; exit 1; fi
