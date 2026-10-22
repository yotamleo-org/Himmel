#!/usr/bin/env bash
# test-weekly-rollup.sh - weekly-rollup.py: a four-week fixture produces one row
# per week with the right counts and deltas, version rows from tags, a null
# column when a source is absent, an idempotent re-run, and the review lines.
# Hermetic: the git repo, the self-review stub, the cache history and the flake
# ledger all live in a mktemp dir. Never calls a model or the network.
# Exit: 0 = all pass, 1 = a case failed.
# shellcheck disable=SC2015  # `A && pass || fail`: pass always succeeds
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PY="$DIR/weekly-rollup.py"
PASSED=0; FAILED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/weekly-rollup.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT

[ -f "$PY" ] || { fail "weekly-rollup.py exists"; echo "passed=$PASSED failed=$FAILED"; exit 1; }
command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

REPO="$W/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
n=0
merge() { # <date> <subject> [cost-eq]
  n=$((n + 1))
  local body="no burn line"
  [ -n "${3:-}" ] && body="leg-burn s.jsonl: calls=9 avg-ctx=1k first-turn=1k out=1k compactions=0 cost-eq=$3 floor-share=1%"
  GIT_AUTHOR_DATE="$1T12:00:00Z" GIT_COMMITTER_DATE="$1T12:00:00Z" \
    git -C "$REPO" commit -q --allow-empty -m "$2 (#$n)" -m "$body"
}
merge 2026-09-01 'feat(x): [HIMMEL-1] a' 100k
merge 2026-09-02 'fix(x): [HIMMEL-2] b' 50k
git -C "$REPO" tag -a v1.0.0 -m v1.0.0
merge 2026-09-08 'feat(x): [HIMMEL-3] c' 200k
merge 2026-09-09 'fix(x): [HIMMEL-3] d' 100k
merge 2026-09-10 'feat(x): [HIMMEL-4] e' 100k
GIT_COMMITTER_DATE="2026-09-12T12:00:00Z" git -C "$REPO" tag -a v1.1.0 -m v1.1.0
merge 2026-09-15 'fix(x): [HIMMEL-5] f main-red'

# The self-review stub keeps 6865's output shape; it counts first-parent subjects.
cat >"$W/self-review.sh" <<'E'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;; --ref) ref="$2"; shift 2 ;;
    --since) since="$2"; shift 2 ;; --until) until="$2"; shift 2 ;; *) shift ;;
  esac
done
s=$(git -C "$repo" log "$ref" --first-parent --since="$since" --until="$until" --format=%s)
m=$(printf '%s\n' "$s" | grep -c '(#[0-9]*)$')
f=$(printf '%s\n' "$s" | grep -c '^fix')
t=$(printf '%s\n' "$s" | grep -c '^feat')
r=$(printf '%s\n' "$s" | grep -c 'main-red')
echo "merges: $m"
echo "fix-share: fix=$f feat=$t share=$(( m ? 100 * f / m : 0 ))%"
echo "guard-churn: 0"
echo "compaction-share: compacted=0 runs=0 share=0%"
echo "sprawl: none"
echo "red-main: $r"
E

# Cache history: two runs in W37 (90 and 94), none elsewhere.
ts() { python3 -c 'import sys, datetime as d; print(int(d.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).timestamp()))' "$1"; }
printf '{"ts": %s, "overall": 90.0, "roles": {}}\n{"ts": %s, "overall": 94.0, "roles": {}}\n' \
  "$(ts 2026-09-09T10:00:00Z)" "$(ts 2026-09-10T10:00:00Z)" >"$W/cache.jsonl"
# Flake ledger (run-shell-tests.sh schema): one row in W36, two in W37, one other repo.
{
  printf '{"kind":"flake","repo":"fx","ts":%s,"suite":"a.sh"}\n' "$(ts 2026-09-03T10:00:00Z)"
  printf '{"kind":"flake","repo":"fx","ts":%s,"suite":"a.sh"}\n' "$(ts 2026-09-09T10:00:00Z)"
  printf '{"kind":"flake","repo":"fx","ts":%s,"suite":"b.sh"}\n' "$(ts 2026-09-11T10:00:00Z)"
  printf '{"kind":"flake","repo":"other","ts":%s,"suite":"c.sh"}\n' "$(ts 2026-09-09T10:00:00Z)"
} >"$W/flake.jsonl"

export HOME="$W/home"; mkdir -p "$HOME"
export SELF_REVIEW_SCRIPT="$W/self-review.sh"
export CACHE_HEALTH_HISTORY="$W/cache.jsonl"
export SUITE_FLAKE_LEDGER="$W/flake.jsonl" SUITE_FLAKE_REPO_ID=fx
export WEEKLY_ROLLUP_NOW="2026-09-24T00:00:00Z"
OUT="$W/rollup.jsonl"
run() { python3 -I "$PY" "$@"; }

run write --repo "$REPO" --ref main --weeks 4 --end 2026-09-27 --out "$OUT" >"$W/w.out" 2>&1
check "write exits 0" 0 $?
check "four week rows" 4 "$(jq -s '[.[] | select(.kind=="week")] | length' "$OUT")"
row() { jq -c --arg k "$1" 'select(.kind=="week" and .key==$k)' "$OUT"; }
f() { row "$1" | jq -r ".$2"; }

check "week key is the ISO week" "2026-W36 2026-W37 2026-W38 2026-W39" \
  "$(jq -r 'select(.kind=="week") | .key' "$OUT" | tr '\n' ' ' | sed 's/ $//')"
check "W36 merges" 2 "$(f 2026-W36 merges)"
check "W36 tickets" 2 "$(f 2026-W36 tickets)"
check "W36 fix share" 50 "$(f 2026-W36 fix_share_pct)"
check "W36 cost-eq sums k-suffixed lines" 150000 "$(f 2026-W36 cost_eq)"
check "W36 days" 7 "$(f 2026-W36 days)"
check "W36 cost per ticket" 75000 "$(f 2026-W36 cost_eq_per_ticket)"
check "W36 flake rows" 1 "$(f 2026-W36 flake_rows)"
check "W36 has no cache data" null "$(f 2026-W36 cache_hit_pct)"
check "W37 merges" 3 "$(f 2026-W37 merges)"
check "W37 tickets counts distinct keys" 2 "$(f 2026-W37 tickets)"
check "W37 cost per ticket" 200000 "$(f 2026-W37 cost_eq_per_ticket)"
check "W37 cache mean" 92 "$(f 2026-W37 cache_hit_pct)"
check "W37 flake rows ignore another repo" 2 "$(f 2026-W37 flake_rows)"
check "W38 red main" 1 "$(f 2026-W38 red_main)"
check "W38 cost is null with no leg-burn line" null "$(f 2026-W38 cost_eq)"
check "W39 empty week has zero merges" 0 "$(f 2026-W39 merges)"
check "an empty week has no fix share" null "$(f 2026-W39 fix_share_pct)"
check "first week has no delta" null "$(f 2026-W36 delta.merges)"
check "delta merges W37 vs W36" 1 "$(f 2026-W37 delta.merges)"
check "delta tickets W37 vs W36" 0 "$(f 2026-W37 delta.tickets)"
check "delta fix share W37 vs W36" -16.67 "$(f 2026-W37 delta.fix_share_pct)"
check "delta cost per ticket W37 vs W36" 125000 "$(f 2026-W37 delta.cost_eq_per_ticket)"
check "delta is null when a side is null" null "$(f 2026-W38 delta.cost_eq_per_ticket)"
check "unsourced series stay null" "null null null" \
  "$(row 2026-W37 | jq -r '[.failure_rate_pct, .denial_rate_pct, .ship_stage_median_min] | map(tostring) | join(" ")')"
check "unsourced series are named" '["failure_rate_pct","denial_rate_pct","ship_stage_median_min"]' \
  "$(row 2026-W37 | jq -c .no_source)"
check "the week holding now is partial" true "$(f 2026-W39 partial)"
check "a finished week is not partial" false "$(f 2026-W36 partial)"

cp "$OUT" "$W/first.jsonl"
run write --repo "$REPO" --ref main --weeks 4 --end 2026-09-27 --out "$OUT" >/dev/null 2>&1
check "re-run exits 0" 0 $?
check "a re-run is idempotent" "$(cat "$W/first.jsonl")" "$(cat "$OUT")"
WEEKLY_ROLLUP_NOW="2026-09-25T00:00:00Z" run write --repo "$REPO" --ref main --weeks 1 --end 2026-09-27 --out "$OUT" >/dev/null 2>&1
check "shorter re-run exits 0" 0 $?
check "a shorter re-run keeps older rows" 4 "$(jq -s '[.[] | select(.kind=="week")] | length' "$OUT")"
check "a shorter re-run rewrites its own week" "$(ts 2026-09-25T00:00:00Z)" "$(f 2026-W39 ts)"

OUT4="$W/kept.jsonl"
run write --repo "$REPO" --ref main --weeks 4 --end 2026-09-27 --out "$OUT4" >/dev/null 2>&1
SELF_REVIEW_SCRIPT="$W/missing.sh" CACHE_HEALTH_HISTORY="$W/no-cache.jsonl" FLAKE_SUMMARY_SCRIPT="$W/missing.sh" \
  run write --repo "$REPO" --ref main --weeks 4 --end 2026-09-27 --out "$OUT4" >/dev/null 2>&1
k() { jq -r --arg k "$1" "select(.kind==\"week\" and .key==\$k) | $2" "$OUT4"; }
check "a finished week keeps its merges when self-review goes absent" 3 "$(k 2026-W37 .merges)"
check "a finished week keeps its fix share when self-review goes absent" 33.33 "$(k 2026-W37 .fix_share_pct)"
check "a finished week keeps its cache hit when the history is gone" 92 "$(k 2026-W37 .cache_hit_pct)"
check "a finished week keeps its flake rows when the script is gone" 2 "$(k 2026-W37 .flake_rows)"
check "a kept source is still named ok" "ok ok ok" "$(k 2026-W37 '[.sources.self_review, .sources.cache, .sources.flake] | join(" ")')"
check "a partial week is replaced, not kept" absent "$(k 2026-W39 .sources.self_review)"

OUT6="$W/aged.jsonl"
run write --repo "$REPO" --ref main --weeks 4 --end 2026-09-27 --out "$OUT6" >/dev/null 2>&1
: >"$W/empty-cache.jsonl"
CACHE_HEALTH_HISTORY="$W/empty-cache.jsonl" run write --repo "$REPO" --ref main --weeks 4 --end 2026-09-27 --out "$OUT6" >/dev/null 2>&1
check "a finished week keeps its cache hit when the history has aged out" 92 \
  "$(jq -r 'select(.kind=="week" and .key=="2026-W37") | .cache_hit_pct' "$OUT6")"

OUT7="$W/moved.jsonl"
run write --repo "$REPO" --ref main --weeks 4 --end 2026-09-27 --out "$OUT7" >/dev/null 2>&1
jq -c 'if .key=="2026-W37" then .since="2026-01-01T00:00:00Z" else . end' "$OUT7" >"$W/moved.tmp" && mv "$W/moved.tmp" "$OUT7"
CACHE_HEALTH_HISTORY="$W/empty-cache.jsonl" run write --repo "$REPO" --ref main --weeks 4 --end 2026-09-27 --out "$OUT7" >/dev/null 2>&1
check "a row whose window moved does not keep the old window's values" null \
  "$(jq -r 'select(.kind=="week" and .key=="2026-W37") | .cache_hit_pct' "$OUT7")"

run write --repo "$REPO" --ref main --weeks 0 --versions 2 --out "$OUT" >"$W/w2.out" 2>&1
check "version rows come from stable tags" "v1.0.0 v1.1.0" \
  "$(jq -r 'select(.kind=="version") | .key' "$OUT" | tr '\n' ' ' | sed 's/ $//')"
vrow() { jq -r --arg k "$1" "select(.kind==\"version\" and .key==\$k) | .$2" "$OUT"; }
check "v1.1.0 merges are the tag window" 3 "$(vrow v1.1.0 merges)"
check "v1.1.0 delta merges vs v1.0.0" 1 "$(vrow v1.1.0 delta.merges)"

# A commit landed after the tag but dated inside its window must not enter the version row.
git clone -q "$REPO" "$W/repo2"
git -C "$W/repo2" config user.email t@example.com
git -C "$W/repo2" config user.name t
GIT_AUTHOR_DATE="2026-09-10T12:00:00Z" GIT_COMMITTER_DATE="2026-09-10T12:00:00Z" \
  git -C "$W/repo2" commit -q --allow-empty -m 'feat(x): [HIMMEL-9] late (#99)' \
  -m "leg-burn s.jsonl: calls=9 avg-ctx=1k first-turn=1k out=1k compactions=0 cost-eq=900k floor-share=1%"
OUT3="$W/late.jsonl"
run write --repo "$W/repo2" --ref main --weeks 0 --versions 2 --out "$OUT3" >/dev/null 2>&1
check "a post-tag commit stays out of the version merges" 3 \
  "$(jq -r 'select(.key=="v1.1.0") | .merges' "$OUT3")"
check "a post-tag commit stays out of the version cost" 400000 \
  "$(jq -r 'select(.key=="v1.1.0") | .cost_eq' "$OUT3")"
check "rows carry ts, host and source" "true true weekly-rollup" \
  "$(jq -r 'select(.key=="v1.1.0") | [(.ts|type=="number"), (.host|length>0), .source] | map(tostring) | join(" ")' "$OUT3")"

# Merges dated out of order: git stops at a run of commits older than --since unless told to filter.
git init -q -b main "$W/repo3"
git -C "$W/repo3" config user.email t@example.com
git -C "$W/repo3" config user.name t
git -C "$W/repo3" config commit.gpgsign false
GIT_AUTHOR_DATE="2026-09-08T12:00:00Z" GIT_COMMITTER_DATE="2026-09-08T12:00:00Z" \
  git -C "$W/repo3" commit -q --allow-empty -m 'feat(x): [HIMMEL-7] in window (#1)' \
  -m "leg-burn s.jsonl: calls=9 avg-ctx=1k first-turn=1k out=1k compactions=0 cost-eq=70k floor-share=1%"
for i in 1 2 3 4 5 6 7; do
  GIT_AUTHOR_DATE="2026-01-0${i}T12:00:00Z" GIT_COMMITTER_DATE="2026-01-0${i}T12:00:00Z" \
    git -C "$W/repo3" commit -q --allow-empty -m "feat(x): [HIMMEL-8] old $i (#1$i)" -m "no burn line"
done
OUT5="$W/skew.jsonl"
run write --repo "$W/repo3" --ref main --weeks 1 --end 2026-09-10 --out "$OUT5" >/dev/null 2>&1
check "an out-of-order history still counts the in-window merge" "1 70000" \
  "$(jq -r 'select(.key=="2026-W37") | [.tickets, .cost_eq] | map(tostring) | join(" ")' "$OUT5")"

OUT2="$W/noscript.jsonl"
SELF_REVIEW_SCRIPT="$W/missing.sh" run write --repo "$REPO" --ref main --weeks 4 --end 2026-09-27 --out "$OUT2" >/dev/null 2>&1
check "absent self-review still exits 0" 0 $?
check "absent self-review nulls merges" null "$(jq -r 'select(.key=="2026-W37") | .merges' "$OUT2")"
check "absent self-review keeps cost" 400000 "$(jq -r 'select(.key=="2026-W37") | .cost_eq' "$OUT2")"
check "absent self-review is named in sources" absent "$(jq -r 'select(.key=="2026-W37") | .sources.self_review' "$OUT2")"

run review --version v1.1.0 --file "$OUT" >"$W/review.out" 2>&1
check "review exits 0" 0 $?
check "review prints three lines" 3 "$(wc -l <"$W/review.out" | tr -d ' ')"
check "review velocity line" "velocity: merges=3 (+1 vs v1.0.0) tickets=2 (+0) fix-share=33.33% (-16.67) window=8d" \
  "$(sed -n 1p "$W/review.out")"
check "review cost line" "cost: cost-eq=400k legs=3 per-ticket=200k (+125k vs v1.0.0)" \
  "$(sed -n 2p "$W/review.out")"
check "review health line" "health: red-main=0 (+0) cache-hit=92% (n/a) flakes=2 (+2); failure and denial rates: no source yet" \
  "$(sed -n 3p "$W/review.out")"
run review --version v9.9.9 --file "$OUT" >"$W/review2.out" 2>&1
check "an unknown version reads no data yet" "velocity: no data yet cost: no data yet health: no data yet" \
  "$(tr '\n' ' ' <"$W/review2.out" | sed 's/ $//')"
run review --version v1.1.0 --file "$W/absent.jsonl" >"$W/review3.out" 2>&1
check "a missing roll-up reads no data yet" "velocity: no data yet cost: no data yet health: no data yet" \
  "$(tr '\n' ' ' <"$W/review3.out" | sed 's/ $//')"

echo "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
