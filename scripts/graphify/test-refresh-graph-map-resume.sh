#!/usr/bin/env bash
# test-refresh-graph-map-resume.sh — refresh-graph-map.sh must finish an
# unseeded corpus ACROSS runs: cap the chunks per run, keep every finished
# chunk's cache when a run stops early (without promoting a partial graph),
# resume from that cache, and bound the retry of a hollow chunk.
# Hermetic: stubs graphify (GRAPHIFY_MAP_BIN, no model call), no network, no
# real vault. Run: bash scripts/graphify/test-refresh-graph-map-resume.sh
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom (pass/fail echo, always rc 0)
# shellcheck disable=SC2016  # the heredoc report fixture is literal on purpose (no expansion wanted)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/refresh-graph-map.sh"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

WS="$(mktemp -d "${TMPDIR:-/tmp}/rgm-resume.XXXXXX")" || { echo "cannot create test workspace" >&2; exit 1; }; trap 'rm -rf "$WS"' EXIT
export TMPDIR="$WS/tmp"; mkdir -p "$TMPDIR"
export GRAPHIFY_LEDGER="$WS/graphify-egress.jsonl"
unset ANTHROPIC_BASE_URL
HERMETIC_HOME="$WS/hermetic-home"; mkdir -p "$HERMETIC_HOME/.claude"
printf 'test-subscription-auth\n' > "$HERMETIC_HOME/.claude/.credentials.json"
printf '{}\n' > "$HERMETIC_HOME/.claude/settings.json"
export HOME="$HERMETIC_HOME"
export CADENCE_BANK_SKIP_REFRESH=1
export CADENCE_BANK_CACHE="$WS/no-bank-cache.json"
unset CLAUDE_USAGE_CACHE CLAUDE_ACCOUNT_CONFIG GRAPHIFY_MAX_CHUNKS_PER_RUN GRAPHIFY_SECONDS_PER_CHUNK GRAPHIFY_HOLLOW_RETRY_MAX

REPORT_FIXTURE='# Graph Report - X

## Summary
- 42 nodes · 30 edges · 5 communities (5 shown)

## God Nodes (most connected - your core abstractions)
1. `Core` - 9 edges

## Communities (5 total)

### Community 0 - "Alpha"
Cohesion: 0.06
Nodes (20): a, b (+18 more)
'

# Stub graphify. `<target> --update`: walks STUB_CHUNKS chunks; a chunk whose
# cache file already exists is a hit (no call logged), otherwise it is "called"
# (logged to STUB_CALLS), cached, and announced like graphify does. The chunk
# STUB_HOLLOW_AT never recovers: it prints hollow-retry lines (counted in
# STUB_HOLLOW_COUNT) until the run kills it. `cluster-only <target>` writes the
# graph + report.
BIN="$WS/bin"; mkdir -p "$BIN"
cat > "$BIN/graphify" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "graphify 0.9.93"; exit 0; fi
[ -z "${STUB_IGNORE_TERM:-}" ] || trap '' TERM
if [ "$1" = "cluster-only" ]; then
  [ -z "${STUB_CLUSTER_FAIL:-}" ] || exit 1
  mkdir -p "$2/graphify-out"
  printf '{"nodes":[],"links":[]}' > "$2/graphify-out/graph.json"
  printf '%s\n' "$STUB_REPORT" > "$2/graphify-out/GRAPH_REPORT.md"
  exit 0
fi
target="$1"
mkdir -p "$target/graphify-out/cache"
todo=()
for i in $(seq 1 "$STUB_CHUNKS"); do
  [ -e "$target/graphify-out/cache/c$i.json" ] || todo+=("$i")
done
m=${#todo[@]}; k=0
for i in "${todo[@]}"; do
  sleep 0.3
  echo "c$i" >> "$STUB_CALLS"
  if [ "${STUB_HOLLOW_AT:-0}" = "$i" ]; then
    for _ in $(seq 1 60); do
      echo "[graphify] retrying the same chunk of 38 in 0s after a hollow response" >&2
      echo x >> "$STUB_HOLLOW_COUNT"
      sleep 0.05
    done
    exit 1
  fi
  if [ "${STUB_HOLLOW_BLIP_AT:-0}" = "$i" ]; then
    for _ in $(seq 1 "${STUB_HOLLOW_BLIP:-5}"); do
      echo "[graphify] retrying the same chunk of 38 in 0s after a hollow response" >&2
    done
  fi
  printf '{}' > "$target/graphify-out/cache/c$i.json"
  k=$((k+1))
  echo "[graphify extract] chunk $k/$m done" >&2
  [ "${STUB_DIE_AFTER:-0}" = "$k" ] && exit 137
done
printf '{"nodes":[],"links":[]}' > "$target/graphify-out/graph.json"
exit 0
STUB
chmod +x "$BIN/graphify"
export PATH="$BIN:$PATH"
export GRAPHIFY_MAP_BIN="$BIN/graphify"
export STUB_REPORT="$REPORT_FIXTURE"

CORPUS="$WS/vault"; mkdir -p "$CORPUS/notes"; printf '# n\ncontent\n' > "$CORPUS/notes/a.md"
MAPS="$WS/vault/60-Maps"; mkdir -p "$MAPS"
SP="$WS/scratch"; mkdir -p "$SP"
OUTD="$CORPUS/graphify-out"
export STUB_CALLS="$WS/calls.log" STUB_HOLLOW_COUNT="$WS/hollow.log"

run_refresh() {
  bash "$SCRIPT" --name luna --corpus-root "$CORPUS" --backend claude \
    --maps-dir "$MAPS" --title "Graphify Luna Map" --slug graphify-luna-map --corpus-tag luna \
    --scratch "$SP"
}
reset() { rm -rf "$OUTD" "${MAPS:?}"/*; rm -f "$STUB_CALLS" "$STUB_HOLLOW_COUNT"; }

# --- R1: a chunk that keeps coming back hollow is retried a bounded number of
# times, then the run stops as FAILED (rc 5), keeping the finished chunks and
# promoting nothing. ---
echo "R1: a persistently hollow chunk is retried a bounded number of times"
reset
out=$( STUB_CHUNKS=4 STUB_HOLLOW_AT=2 GRAPHIFY_HOLLOW_RETRY_MAX=3 GRAPHIFY_MAX_CONCURRENCY=1 run_refresh 2>&1 ); rc=$?
[ "$rc" -eq 5 ] && pass "R1 exits 5 (chunk failed)" || fail "R1 should exit 5 (got $rc): $out"
n=$(wc -l < "$STUB_HOLLOW_COUNT" 2>/dev/null || echo 0)
[ "$n" -ge 3 ] && [ "$n" -le 4 ] && pass "R1 the hollow retry stopped after $n lines (limit 3, stub would emit 60)" \
  || fail "R1 the hollow retry should stop at 3 lines (4 at most), saw $n"
[ -f "$OUTD/cache/c1.json" ] && pass "R1 the finished chunk c1 is kept in the cache" || fail "R1 finished chunk c1 was thrown away"
[ ! -e "$OUTD/graph.json" ] && pass "R1 nothing partial was promoted" || fail "R1 a partial graph.json was promoted"
grep -q 'chunk' "$OUTD/.graphify_failed_chunks" 2>/dev/null \
  && pass "R1 the failed chunk is recorded" || fail "R1 the failed chunk should be recorded in .graphify_failed_chunks"

# --- R2: a corpus larger than the per-run cap stops at the cap, cached, with a
# distinct resumable status and no partial promote. ---
echo "R2: a run stops at the chunk cap with its chunks cached"
reset
out=$( STUB_CHUNKS=6 GRAPHIFY_MAX_CHUNKS_PER_RUN=3 run_refresh 2>&1 ); rc=$?
[ "$rc" -eq 4 ] && pass "R2 exits 4 (capped, resumable)" || fail "R2 should exit 4 (got $rc): $out"
cached=$( cd "$OUTD/cache" 2>/dev/null && printf '%s ' *.json )
[ "$cached" = "c1.json c2.json c3.json " ] \
  && pass "R2 exactly the 3 finished chunks are cached" || fail "R2 cache should hold c1..c3 only: $cached"
[ ! -e "$OUTD/graph.json" ] && pass "R2 nothing partial was promoted" || fail "R2 a partial graph.json was promoted"
echo "$out" | grep -q 'chunk cap=3' && pass "R2 the cap is printed" || fail "R2 stderr should print chunk cap=3: $out"

# --- R3: the next run resumes from the cached chunks. ---
echo "R3: the next run resumes and completes"
rm -f "$STUB_CALLS"
out=$( STUB_CHUNKS=6 GRAPHIFY_MAX_CHUNKS_PER_RUN=3 run_refresh 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && pass "R3 completes (rc 0)" || fail "R3 should exit 0 (got $rc): $out"
calls=$(tr '\n' ' ' < "$STUB_CALLS" 2>/dev/null)
[ "$calls" = "c4 c5 c6 " ] && pass "R3 only the uncached chunks were called" || fail "R3 should call only c4 c5 c6, called: $calls"
[ -f "$OUTD/graph.json" ] && pass "R3 the graph is promoted" || fail "R3 graph.json was not promoted"

# --- R4: the default cap derives from the deadline over seconds-per-chunk. ---
echo "R4: the cap is the run deadline divided by the seconds per chunk"
reset
out=$( STUB_CHUNKS=1 GRAPHIFY_RUN_DEADLINE_SECONDS=7200 GRAPHIFY_SECONDS_PER_CHUNK=130 run_refresh 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && pass "R4 the run itself completes (rc 0)" || fail "R4 should exit 0 (got $rc): $out"
echo "$out" | grep -q 'chunk cap=55' && pass "R4 7200 / 130 prints chunk cap=55" || fail "R4 stderr should print chunk cap=55: $out"

# --- R5: a deadline that needed timeout's SIGKILL (rc 137) keeps the finished
# chunks just like a plain deadline (rc 124). ---
echo "R5: a SIGKILL-escalated deadline stop keeps the finished chunks"
reset
out=$( STUB_CHUNKS=6 STUB_DIE_AFTER=2 run_refresh 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "R5 exits 2" || fail "R5 should exit 2 (got $rc): $out"
cached=$( cd "$OUTD/cache" 2>/dev/null && printf '%s ' *.json )
[ "$cached" = "c1.json c2.json " ] \
  && pass "R5 the 2 finished chunks are kept" || fail "R5 cache should hold c1 c2: $cached"
[ ! -e "$OUTD/graph.json" ] && pass "R5 nothing partial was promoted" || fail "R5 a partial graph.json was promoted"

# --- R6: an all-zero tunable is rejected, not divided by. ---
echo "R6: all-zero tunables are usage errors"
reset
out=$( STUB_CHUNKS=1 GRAPHIFY_SECONDS_PER_CHUNK=00 run_refresh 2>&1 ); rc=$?
[ "$rc" -eq 1 ] && pass "R6 seconds-per-chunk 00 exits 1" || fail "R6 should exit 1 (got $rc): $out"
echo "$out" | grep -q 'positive integer' && pass "R6 names the positive-integer rule" || fail "R6 should say positive integer: $out"
out=$( STUB_CHUNKS=1 GRAPHIFY_HOLLOW_RETRY_MAX=00 run_refresh 2>&1 ); rc=$?
[ "$rc" -eq 1 ] && pass "R6 hollow-retry-max 00 exits 1" || fail "R6 hollow max 00 should exit 1 (got $rc): $out"

# --- R7: extraction finished but clustering failed: the whole extraction is the
# expensive part, so its cache is kept for the next run. ---
echo "R7: a failure after extraction keeps the extraction cache"
reset
out=$( STUB_CHUNKS=3 STUB_CLUSTER_FAIL=1 run_refresh 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && pass "R7 exits 2" || fail "R7 should exit 2 (got $rc): $out"
cached=$( cd "$OUTD/cache" 2>/dev/null && printf '%s ' *.json )
[ "$cached" = "c1.json c2.json c3.json " ] \
  && pass "R7 the extraction cache is kept" || fail "R7 cache should hold c1..c3: $cached"
[ ! -e "$OUTD/graph.json" ] && pass "R7 nothing partial was promoted" || fail "R7 a partial graph.json was promoted"

# --- R8: a graphify that ignores the stop TERM is SIGKILLed after the grace, so
# the cap still ends the run. ---
echo "R8: a TERM-ignoring graphify is killed after the grace at the cap"
reset
out=$( STUB_CHUNKS=12 STUB_IGNORE_TERM=1 GRAPHIFY_MAX_CHUNKS_PER_RUN=2 GRAPHIFY_STOP_KILL_GRACE_SECONDS=1 timeout 60 bash -c 'bash "$0" --name luna --corpus-root "$1" --backend claude --maps-dir "$2" --title "Graphify Luna Map" --slug graphify-luna-map --corpus-tag luna --scratch "$3"' "$SCRIPT" "$CORPUS" "$MAPS" "$SP" 2>&1 ); rc=$?
[ "$rc" -eq 4 ] && pass "R8 exits 4 despite the ignored TERM" || fail "R8 should exit 4 (got $rc): $out"
[ -f "$OUTD/cache/c2.json" ] && [ ! -e "$OUTD/cache/c12.json" ] \
  && pass "R8 the run was cut short after the cap (c2 cached, c12 never reached)" || fail "R8 the TERM-ignoring graphify ran to the end or lost its chunks"

# --- R9: the hollow limit scales with the effective concurrency: with several
# API workers, retries from different chunks interleave with no completion
# between them, so 5 hollow lines at concurrency 6 are not a failed chunk; an
# all-hollow run still stops, at limit x concurrency. ---
echo "R9: the hollow limit scales with the API concurrency"
reset
out=$( STUB_CHUNKS=4 STUB_HOLLOW_BLIP_AT=2 STUB_HOLLOW_BLIP=5 GRAPHIFY_HOLLOW_RETRY_MAX=3 GRAPHIFY_MAX_CONCURRENCY=6 run_refresh 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && pass "R9 5 interleaved hollow lines at concurrency 6 do not stop the run" || fail "R9 should exit 0 (got $rc): $out"
reset
out=$( STUB_CHUNKS=4 STUB_HOLLOW_AT=2 GRAPHIFY_HOLLOW_RETRY_MAX=3 GRAPHIFY_MAX_CONCURRENCY=2 run_refresh 2>&1 ); rc=$?
[ "$rc" -eq 5 ] && pass "R9 an all-hollow run at concurrency 2 still exits 5" || fail "R9 all-hollow should exit 5 (got $rc): $out"
n=$(wc -l < "$STUB_HOLLOW_COUNT" 2>/dev/null || echo 0)
[ "$n" -ge 6 ] && [ "$n" -le 7 ] && pass "R9 it stopped after $n lines (limit 3 x concurrency 2)" || fail "R9 should stop at 6 lines (7 at most), saw $n"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
