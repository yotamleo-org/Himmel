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
ba_worker="$(printf '%s\n' "$BA" | grep -F '| HIMMEL-9001-N1-thing | slug' | awk -F' [|] ' '{print $4"/"$5"/"$6"/"$7"/"$8}')"
OUT="$(run --print)"
rec="$(printf '%s\n' "$OUT" | jq -c 'select(.ticket=="HIMMEL-9001")')"
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
check "--tickets empty element fails" "1" "$(sel --tickets 'HIMMEL-9001,')"
check "--tickets matching nothing fails" "1" "$(sel --tickets HIMMEL-7777)"
check "--tickets valid still works" "0" "$(sel --tickets HIMMEL-9001 --print)"
check "--since empty fails" "1" "$(sel --since '' --print)"
check "--range with --tickets fails" "1" "$(sel --range HIMMEL-9001..HIMMEL-9002 --tickets HIMMEL-9001 --print)"
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
before="$(wc -l < "$STORE/records.jsonl" | tr -d ' ')"
row $WORKER false 2026-01-01T00:00:09.000Z r3 1 1 1 1 >> "$SLUG/$WORKER.jsonl"
run --store "$STORE" >/dev/null
after="$(wc -l < "$STORE/records.jsonl" | tr -d ' ')"
check "changed input appends one version" "$((before + 1))" "$after"

# 6. consumer read test (no JSONL touched)
check "read latest turns" "3" "$(bash "$READ" --store "$STORE" --ticket HIMMEL-9001 | jq -r '.legs[]|select(.name=="HIMMEL-9001-N1-thing").turns')"
check "read all versions" "2" "$(bash "$READ" --store "$STORE" --ticket HIMMEL-9001 --all | wc -l | tr -d ' ')"

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
jrec="$(printf '%s\n' "$J" | jq -c 'select(.ticket=="HIMMEL-9001")')"
check "pr facts (decoy HIMMEL-90019 excluded, numbers sorted)" '{"closed":1,"merged":1,"numbers":[11,12],"open":0,"state":"found"}' "$(printf '%s' "$jrec" | jq -cS .pr)"
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
check "a letter after the key is not the key (HIMMEL-9001A)" '{"state":"none"}' "$(GHFIX="$ROOT/fix4" jrun --print | jq -cS 'select(.ticket=="HIMMEL-9001")|.pr')"
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
check "reconcile: --until bounds both sides (the 13:00 transcript and the 14:00 row drop out)" "yes" \
  "$(rj --until 2026-11-04T13:00:00Z | grep -qxF "transcripts with no launch row: 0  total \$0  (with a launch-log line: 0)" && echo yes || echo no)"
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

if [ "$FAIL" -eq 0 ]; then echo "PASS"; else echo "FAILED" >&2; exit 1; fi
