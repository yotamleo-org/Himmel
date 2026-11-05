#!/usr/bin/env bash
# Hermetic test for check-graph-freshness.sh — temp dirs only, never touches a
# real graphify-out. Run: bash scripts/graphify/test-check-graph-freshness.sh
# shellcheck disable=SC2015  # A && pass || fail is the intentional test-assert idiom (pass/fail echo, always rc 0)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/check-graph-freshness.sh"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT

# Build a graphify-out fixture: manifest (flat + nested key) + graph.json + a
# corpus holding both named files. Does NOT write the .graphify_root marker.
build_out() {  # $1=out dir, $2=corpus dir
  mkdir -p "$1" "$2/notes"
  printf '{"real.md": {"mtime": 0, "ast_hash": "x"}, "notes/sub.md": {"mtime": 0}}\n' > "$1/manifest.json"
  printf '{"nodes":[],"edges":[]}\n' > "$1/graph.json"
  printf '# real\n' > "$2/real.md"
  printf '# sub\n' > "$2/notes/sub.md"
}

# Backdate a file's mtime by N days (portable os.utime; touch -d is GNU-only).
backdate_days() {  # $1=file, $2=days ago
  python3 -c 'import os,sys,time
f=sys.argv[1]; d=float(sys.argv[2])*86400; now=time.time(); os.utime(f,(now-d,now-d))' "$1" "$2"
}

# --- T1: ok fresh (marker points at a corpus holding a manifest-named file) ---
OUT="$WS/t1/graphify-out"; CORPUS="$WS/t1/corpus"; build_out "$OUT" "$CORPUS"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>/dev/null ); rc=$?
[ "$rc" -eq 0 ] && pass "T1 fresh + verified corpus exits 0" || fail "T1 exit 0 (got $rc): $out"
printf '%s\n' "$out" | grep -Eq '^graph-freshness: OK \([0-9]+d old, corpus verified\)$' \
  && pass "T1 OK line shape" || fail "T1 OK line shape: $out"

# --- T2: warn old (graph.json backdated beyond --max-age-days) ---
OUT="$WS/t2/graphify-out"; CORPUS="$WS/t2/corpus"; build_out "$OUT" "$CORPUS"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
backdate_days "$OUT/graph.json" 10
bash "$SCRIPT" --out "$OUT" --max-age-days 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "T2 stale graph -> rc=1 (warn)" || fail "T2 rc=1 (got $rc)"

# --- T2b: under --max-age-days stays OK (comparison not inverted; 3d < 7d) ---
OUT="$WS/t2b/graphify-out"; CORPUS="$WS/t2b/corpus"; build_out "$OUT" "$CORPUS"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
backdate_days "$OUT/graph.json" 3
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>/dev/null ); rc=$?
[ "$rc" -eq 0 ] && pass "T2b 3d-old graph under --max-age-days 7 -> rc=0" || fail "T2b rc=0 (got $rc): $out"

# --- T3: fail missing manifest ---
OUT="$WS/t3/graphify-out"; CORPUS="$WS/t3/corpus"; build_out "$OUT" "$CORPUS"
rm -f "$OUT/manifest.json"
bash "$SCRIPT" --out "$OUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "T3 missing manifest -> rc=2" || fail "T3 rc=2 (got $rc)"

# --- T3b: fail unparseable manifest ---
OUT="$WS/t3b/graphify-out"; CORPUS="$WS/t3b/corpus"; build_out "$OUT" "$CORPUS"
printf '{not json' > "$OUT/manifest.json"
bash "$SCRIPT" --out "$OUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "T3b unparseable manifest -> rc=2" || fail "T3b rc=2 (got $rc)"

# --- T4: fail orphaned (no marker AND no --corpus-root) ---
OUT="$WS/t4/graphify-out"; CORPUS="$WS/t4/corpus"; build_out "$OUT" "$CORPUS"
# deliberately no .graphify_root, no --corpus-root
bash "$SCRIPT" --out "$OUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "T4 orphaned (no marker, no --corpus-root) -> rc=2" || fail "T4 rc=2 (got $rc)"

# --- T4b: fail orphaned (marker present but no manifest-named file under it) ---
OUT="$WS/t4b/graphify-out"; CORPUS="$WS/t4b/corpus"; build_out "$OUT" "$CORPUS"
EMPTYCORPUS="$WS/t4b/empty"; mkdir -p "$EMPTYCORPUS"
printf '%s\n' "$EMPTYCORPUS" > "$OUT/.graphify_root"
bash "$SCRIPT" --out "$OUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "T4b orphaned (marker -> empty corpus) -> rc=2" || fail "T4b rc=2 (got $rc)"

# --- T4c: traversal/absolute manifest keys must NOT verify the corpus (codex CR) ---
# Manifest carries only an absolute key and a ..-traversal key, both resolving
# to REAL files OUTSIDE the (empty) corpus root — the guard must still call it
# orphaned (rc=2), never "verified" through an escaped path join.
OUT="$WS/t4c/graphify-out"; CORPUS="$WS/t4c/corpus"; build_out "$OUT" "$CORPUS"
EMPTYCORPUS="$WS/t4c/empty"; mkdir -p "$EMPTYCORPUS"
printf '# outside\n' > "$WS/t4c/outside.md"
printf '{"%s": {"mtime": 0}, "../outside.md": {"mtime": 0}}\n' "$WS/t4c/outside.md" > "$OUT/manifest.json"
printf '%s\n' "$EMPTYCORPUS" > "$OUT/.graphify_root"
bash "$SCRIPT" --out "$OUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "T4c absolute/traversal manifest keys skipped -> rc=2" || fail "T4c rc=2 (got $rc)"

# --- T4d: majority of manifest paths exist -> corpus verified ---
# 3 of 4 manifest-named paths exist under the corpus (75%, above the >50%
# threshold) -- must NOT be called orphaned, unlike the old "at least one
# match" rule this replaces (which also would have passed here, but this
# fixture is the one the ratio-based rule is built for).
OUT="$WS/t4d/graphify-out"; CORPUS="$WS/t4d/corpus"
mkdir -p "$OUT" "$CORPUS/notes"
printf '{"a.md":{"mtime":0},"b.md":{"mtime":0},"notes/c.md":{"mtime":0},"missing.md":{"mtime":0}}\n' > "$OUT/manifest.json"
printf '{"nodes":[],"edges":[]}\n' > "$OUT/graph.json"
printf '# a\n' > "$CORPUS/a.md"; printf '# b\n' > "$CORPUS/b.md"; printf '# c\n' > "$CORPUS/notes/c.md"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 >/dev/null ); rc=$?
[ "$rc" -eq 0 ] && pass "T4d 3/4 manifest paths exist (75%) -> corpus verified, rc=0" || fail "T4d rc=0 (got $rc): $out"
printf '%s\n' "$out" | grep -q '3/4 manifest paths exist' \
  && pass "T4d prints the measured ratio" || fail "T4d ratio not printed: $out"

# --- T4e: majority of manifest paths MISSING -> orphaned ---
# The exact regression this ticket reports: most manifest paths exist on
# disk (75% here too, just the complement of T4d) is NOT this case -- this
# is 1 of 4 existing (25%, below >50% missing threshold), which must FAIL.
OUT="$WS/t4e/graphify-out"; CORPUS="$WS/t4e/corpus"
mkdir -p "$OUT" "$CORPUS"
printf '{"only-real.md":{"mtime":0},"gone1.md":{"mtime":0},"gone2.md":{"mtime":0},"gone3.md":{"mtime":0}}\n' > "$OUT/manifest.json"
printf '{"nodes":[],"edges":[]}\n' > "$OUT/graph.json"
printf '# real\n' > "$CORPUS/only-real.md"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 >/dev/null ); rc=$?
[ "$rc" -eq 2 ] && pass "T4e 1/4 manifest paths exist (25%) -> orphaned, rc=2" || fail "T4e rc=2 (got $rc): $out"

# --- T4f: EXACTLY 50% existing -> corpus verified, not orphaned (boundary) ---
# codex-1 CR nit: the fail message said "threshold >50% required" but the
# implemented condition (exist*2 < total) passes at exactly 50% -- pin the
# boundary so the message and the behavior can never silently drift apart.
OUT="$WS/t4f/graphify-out"; CORPUS="$WS/t4f/corpus"
mkdir -p "$OUT" "$CORPUS"
printf '{"real1.md":{"mtime":0},"real2.md":{"mtime":0},"gone1.md":{"mtime":0},"gone2.md":{"mtime":0}}\n' > "$OUT/manifest.json"
printf '{"nodes":[],"edges":[]}\n' > "$OUT/graph.json"
printf '# 1\n' > "$CORPUS/real1.md"; printf '# 2\n' > "$CORPUS/real2.md"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 >/dev/null ); rc=$?
[ "$rc" -eq 0 ] && pass "T4f exactly 2/4 (50%) exist -> corpus verified, rc=0" || fail "T4f rc=0 (got $rc): $out"

# --- T5: fail bad --corpus-root (dir does not exist) ---
OUT="$WS/t5/graphify-out"; CORPUS="$WS/t5/corpus"; build_out "$OUT" "$CORPUS"
bash "$SCRIPT" --out "$OUT" --corpus-root "$WS/nope" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "T5 missing --corpus-root -> rc=2" || fail "T5 rc=2 (got $rc)"

# --- T6: ok with explicit --corpus-root (no marker needed) ---
OUT="$WS/t6/graphify-out"; CORPUS="$WS/t6/corpus"; build_out "$OUT" "$CORPUS"
out=$( bash "$SCRIPT" --out "$OUT" --corpus-root "$CORPUS" --max-age-days 7 2>/dev/null ); rc=$?
[ "$rc" -eq 0 ] && pass "T6 explicit --corpus-root exits 0 (no marker)" || fail "T6 exit 0 (got $rc): $out"

# --- T7: fail missing out dir ---
bash "$SCRIPT" --out "$WS/no-such-dir" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "T7 missing out dir -> rc=2" || fail "T7 rc=2 (got $rc)"

# --- T8: usage error on missing --out ---
bash "$SCRIPT" --max-age-days 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "T8 missing --out -> usage rc=1" || fail "T8 usage rc=1 (got $rc)"

# Make a git commit N days ago in $1 (repo dir); print its SHA.
git_commit_days_ago() {  # $1=repo dir, $2=days ago
  local repo="$1" days="$2" epoch
  epoch=$(python3 -c 'import time,sys; print(int(time.time()-float(sys.argv[1])*86400))' "$days")
  ( cd "$repo" \
    && git init -q . \
    && git config user.email test@example.com \
    && git config user.name test \
    && git add -A \
    && GIT_AUTHOR_DATE="@$epoch +0000" GIT_COMMITTER_DATE="@$epoch +0000" git commit -q -m init \
    && git rev-parse HEAD )
}

# --- T9: build-identity age overrides a FALSE-FRESH mtime ---
# graph.json's own mtime is fresh (just written) but its embedded
# built_at_commit points at a commit 10 days old -- the exact checkout/
# restore shape the ticket describes. Must WARN off the commit's age.
OUT="$WS/t9/graphify-out"; CORPUS="$WS/t9/corpus"; build_out "$OUT" "$CORPUS"
SHA="$(git_commit_days_ago "$CORPUS" 10)"
python3 -c 'import json,sys
json.dump({"built_at_commit": sys.argv[2]}, open(sys.argv[1], "w"))' "$OUT/graph.json" "$SHA"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
bash "$SCRIPT" --out "$OUT" --max-age-days 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "T9 fresh mtime + old built_at_commit -> rc=1 (identity wins)" || fail "T9 rc=1 (got $rc)"

# --- T9b: build-identity age also clears a falsely-stale mtime ---
# graph.json's mtime is backdated (would WARN under mtime-only logic) but its
# built_at_commit is fresh (today) -- must report OK.
OUT="$WS/t9b/graphify-out"; CORPUS="$WS/t9b/corpus"; build_out "$OUT" "$CORPUS"
SHA="$(git_commit_days_ago "$CORPUS" 0)"
python3 -c 'import json,sys
json.dump({"built_at_commit": sys.argv[2]}, open(sys.argv[1], "w"))' "$OUT/graph.json" "$SHA"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
backdate_days "$OUT/graph.json" 30
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>/dev/null ); rc=$?
[ "$rc" -eq 0 ] && pass "T9b stale mtime + fresh built_at_commit -> rc=0 (identity wins)" || fail "T9b rc=0 (got $rc): $out"

# --- T9c: unresolvable built_at_commit falls back to mtime (unaffected) ---
OUT="$WS/t9c/graphify-out"; CORPUS="$WS/t9c/corpus"; build_out "$OUT" "$CORPUS"
python3 -c 'import json,sys
json.dump({"built_at_commit": "deadbeef"}, open(sys.argv[1], "w"))' "$OUT/graph.json"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
backdate_days "$OUT/graph.json" 10
bash "$SCRIPT" --out "$OUT" --max-age-days 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "T9c unresolvable built_at_commit falls back to mtime -> rc=1" || fail "T9c rc=1 (got $rc)"

# --- T9d: non-SHA built_at_commit ("--all") is rejected, falls back to mtime ---
# codex-1 CR finding: an unvalidated built_at_commit passed straight to
# `git log` lets a value like "--all" be parsed as a git OPTION (not a
# revision), resolving to an unrelated, often-fresher timestamp. Must be
# rejected before reaching git.
OUT="$WS/t9d/graphify-out"; CORPUS="$WS/t9d/corpus"; build_out "$OUT" "$CORPUS"
git_commit_days_ago "$CORPUS" 0 >/dev/null
python3 -c 'import json,sys
json.dump({"built_at_commit": "--all"}, open(sys.argv[1], "w"))' "$OUT/graph.json"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
backdate_days "$OUT/graph.json" 10
bash "$SCRIPT" --out "$OUT" --max-age-days 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "T9d built_at_commit=--all rejected, falls back to mtime -> rc=1" || fail "T9d rc=1 (got $rc)"

# --- T9e: non-SHA built_at_commit ("HEAD") is rejected, falls back to mtime ---
OUT="$WS/t9e/graphify-out"; CORPUS="$WS/t9e/corpus"; build_out "$OUT" "$CORPUS"
git_commit_days_ago "$CORPUS" 0 >/dev/null
python3 -c 'import json,sys
json.dump({"built_at_commit": "HEAD"}, open(sys.argv[1], "w"))' "$OUT/graph.json"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
backdate_days "$OUT/graph.json" 10
bash "$SCRIPT" --out "$OUT" --max-age-days 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "T9e built_at_commit=HEAD rejected, falls back to mtime -> rc=1" || fail "T9e rc=1 (got $rc)"

# Semantic run rows: one merge row per argument, each argument "<failed files>|<refused files>" (comma lists).
# Rows are dated today (UTC), so they sit inside the semantic age bound.
SEM_DAY="$(date -u +%Y-%m-%d)"
semantic_rows() {  # $1=out dir, $2...=rows
  local out="$1"; shift
  python3 - "$out/semantic-runs.jsonl" "$SEM_DAY" "$@" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    for i, spec in enumerate(sys.argv[3:]):
        failed, refused, backed = (s.split(",") if s else [] for s in (spec.split("|") + [""])[:3])
        f.write(json.dumps({"ts": "%sT0%d:00:00Z" % (sys.argv[2], i), "name": "t", "batch": 3, "failed": len(failed),
                            "shrink_refused": len(refused), "failed_files": failed, "refused_files": refused,
                            "backed_off_files": backed}) + "\n")
        f.write(json.dumps({"ts": "2026-10-19T0%d:30:00Z" % i, "name": "ast-update", "ast_restored_nodes": 1}) + "\n")
PY
}

# --- T10: the same file failed in each of the last 3 semantic runs -> FAIL ---
OUT="$WS/t10/graphify-out"; CORPUS="$WS/t10/corpus"; build_out "$OUT" "$CORPUS"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
semantic_rows "$OUT" "x.md|" "x.md,real.md|" "x.md|"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 3 ] && [[ "$out" == *"x.md"* ]] && pass "T10 a file stuck for 3 runs -> rc=3 (not rc=2: the graph itself is verified) naming it" || fail "T10 rc=3 (got $rc): $out"

# --- T10b: a file shrink-refused in each of the last 3 runs -> FAIL too ---
OUT="$WS/t10b/graphify-out"; CORPUS="$WS/t10b/corpus"; build_out "$OUT" "$CORPUS"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
semantic_rows "$OUT" "|y.md" "|y.md" "x.md|y.md"
bash "$SCRIPT" --out "$OUT" --max-age-days 7 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && pass "T10b a refused file stuck for 3 runs -> rc=3" || fail "T10b rc=3 (got $rc)"

# --- T10e: a file that failed twice and is then backed off stays stuck while it stays backed off ---
OUT="$WS/t10e/graphify-out"; CORPUS="$WS/t10e/corpus"; build_out "$OUT" "$CORPUS"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
semantic_rows "$OUT" "x.md||" "x.md||" "||x.md"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 3 ] && [[ "$out" == *"semantic refresh stuck: x.md failed, was refused or stayed backed off in each of the last 3 runs"* ]] \
  && pass "T10e a backed-off file keeps the check non-zero" || fail "T10e rc=3 (got $rc): $out"
[[ "$out" == *"semantic-merge.py unstick --out $OUT"* ]] && pass "T10e the message names the unstick verb to clear a back-off" || fail "T10e no unstick hint: $out"
OUT="$WS/t10e sp/graphify-out"; CORPUS="$WS/t10e sp/corpus"; build_out "$OUT" "$CORPUS"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
semantic_rows "$OUT" "x.md||" "x.md||" "||x.md"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ) || true
[[ "$out" == *"unstick --out $(printf '%q' "$OUT")"* ]] && pass "T10e2 a path with a space is shell-escaped in the unstick command" || fail "T10e2 unescaped unstick path: $out"

# --- T10f: a stuck semantic layer on a STALE graph still reports stale (rc=1) and still names the stuck file ---
OUT="$WS/t10f/graphify-out"; CORPUS="$WS/t10f/corpus"; build_out "$OUT" "$CORPUS"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
backdate_days "$OUT/graph.json" 10
semantic_rows "$OUT" "x.md|" "x.md|" "x.md|"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"semantic refresh stuck: x.md"* ]] && pass "T10f stale + stuck -> rc=1, stuck file still named" || fail "T10f rc=1 (got $rc): $out"

# --- T10c: failures that drain (different files) stay OK and print the semantic line ---
OUT="$WS/t10c/graphify-out"; CORPUS="$WS/t10c/corpus"; build_out "$OUT" "$CORPUS"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
semantic_rows "$OUT" "x.md|" "|y.md" "|"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>/dev/null ); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -Eq "^graph-freshness: semantic last=${SEM_DAY}T02:00:00Z failed=0 refused=0 " \
  && pass "T10c draining failures -> rc=0 with the semantic line" || fail "T10c (rc=$rc): $out"

# --- T10d: the semantic line reports backed-off files and the oldest unstamped file's age ---
OUT="$WS/t10d/graphify-out"; CORPUS="$WS/t10d/corpus"; build_out "$OUT" "$CORPUS"
printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
semantic_rows "$OUT" "|"
python3 -c 'import hashlib,json,sys
h=lambda p: hashlib.sha256(open(p,"rb").read()).hexdigest()
json.dump({"version":1,"files":{"real.md":h(sys.argv[2])},"stuck":{"notes/sub.md":{"hash":h(sys.argv[3]),"attempts":3,"reason":"r"}}},open(sys.argv[1],"w"))' \
  "$OUT/semantic-manifest.json" "$CORPUS/real.md" "$CORPUS/notes/sub.md"
backdate_days "$CORPUS/notes/sub.md" 5
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>/dev/null ); rc=$?
printf '%s\n' "$out" | grep -q 'backed_off=1 unstamped=1 oldest_unstamped=5d' \
  && pass "T10d backed_off and oldest unstamped age" || fail "T10d (rc=$rc): $out"

# One merge row at an explicit ts ("" = no ts key): $1=out dir, $2=ts, $3=failed csv, $4=refused csv.
semantic_row_at() {
  python3 - "$1/semantic-runs.jsonl" "$2" "${3:-}" "${4:-}" <<'PY'
import json, sys
failed = [s for s in sys.argv[3].split(",") if s]
refused = [s for s in sys.argv[4].split(",") if s]
row = {"name": "t", "batch": 3, "failed": len(failed), "shrink_refused": len(refused),
       "failed_files": failed, "refused_files": refused, "backed_off_files": []}
if sys.argv[2]:
    row["ts"] = sys.argv[2]
open(sys.argv[1], "w").write(json.dumps(row) + "\n")
PY
}
ts_hours_ago() { python3 -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-float(sys.argv[1])*3600)))' "$1"; }
csv_files() { local p="$1" n="$2" i=1 s=""; while [ "$i" -le "$n" ]; do s="$s${s:+,}$p$i.md"; i=$((i+1)); done; printf '%s' "$s"; }
new_sem_fixture() {  # $1=test id: sets OUT and CORPUS, AST layer fresh
  OUT="$WS/$1/graphify-out"; CORPUS="$WS/$1/corpus"; build_out "$OUT" "$CORPUS"
  printf '%s\n' "$CORPUS" > "$OUT/.graphify_root"
}

# --- T11a: AST fresh, semantic last merge 3 days old -> SEMANTIC-STALE, non-zero, never OK ---
new_sem_fixture t11a
semantic_row_at "$OUT" "$(ts_hours_ago 72)" "" ""
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 3 ] && [[ "$out" == *"SEMANTIC-STALE"* ]] && [[ "$out" == *"3d ago"* ]] && ! printf '%s\n' "$out" | grep -q '^graph-freshness: OK' \
  && pass "T11a semantic 3 days old on a fresh AST graph -> rc=3 SEMANTIC-STALE naming the age, no OK" || fail "T11a (rc=$rc): $out"
[[ "$out" == *"run the semantic pass"* ]] && pass "T11a the message names the remedy" || fail "T11a no remedy: $out"

# --- T11b: semantic last merge 2h old -> OK ---
new_sem_fixture t11b
semantic_row_at "$OUT" "$(ts_hours_ago 2)" "" ""
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^graph-freshness: OK' && [[ "$out" != *"SEMANTIC-STALE"* ]] \
  && pass "T11b a fresh semantic layer -> rc=0 OK" || fail "T11b (rc=$rc): $out"

# --- T11c: 11 content files failed (bound 10) -> SEMANTIC-STALE ---
new_sem_fixture t11c
semantic_row_at "$OUT" "$(ts_hours_ago 2)" "$(csv_files docs/page 11)" ""
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 3 ] && [[ "$out" == *"SEMANTIC-STALE"* ]] && [[ "$out" == *"content failed=11"* ]] \
  && pass "T11c content failures above the bound -> rc=3 SEMANTIC-STALE with the count" || fail "T11c (rc=$rc): $out"

# --- T11d: the same 11 failures on vendored, template and fixture paths are not counted -> OK ---
new_sem_fixture t11d
mkdir -p "$CORPUS/marketplace/plugins/vend"; printf '# vendored\n' > "$CORPUS/marketplace/plugins/vend/VENDORED.md"
nc="$(csv_files marketplace/plugins/vend/skills/s 3),$(csv_files templates/second-brain/t 2),$(csv_files plugins/p/templates/e 1),$(csv_files scripts/ci/test-x-fixtures/f 2),$(csv_files scripts/hooks/testdata/d 1),$(csv_files plugins/q/evals/case/graders/g 2)"
semantic_row_at "$OUT" "$(ts_hours_ago 2)" "$nc" ""
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [[ "$out" != *"SEMANTIC-STALE"* ]] && [[ "$out" == *"failed=11 "* ]] && [[ "$out" == *"non_content_failed=11"* ]] \
  && pass "T11d 11 vendored/template/fixture failures -> counted separately, rc=0 OK" || fail "T11d (rc=$rc): $out"

# --- T11e: 11 files shrink-refused (bound 10) -> SEMANTIC-STALE ---
new_sem_fixture t11e
semantic_row_at "$OUT" "$(ts_hours_ago 2)" "" "$(csv_files docs/r 11)"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 3 ] && [[ "$out" == *"refused=11"* ]] && [[ "$out" == *"SEMANTIC-STALE"* ]] \
  && pass "T11e refusals above the bound -> rc=3 SEMANTIC-STALE" || fail "T11e (rc=$rc): $out"

# --- T11f: a content file unstamped for 8 days (bound 7d) -> SEMANTIC-STALE ---
new_sem_fixture t11f
semantic_row_at "$OUT" "$(ts_hours_ago 2)" "" ""
python3 -c 'import hashlib,json,sys
json.dump({"version":1,"files":{"real.md":hashlib.sha256(open(sys.argv[2],"rb").read()).hexdigest()}},open(sys.argv[1],"w"))' \
  "$OUT/semantic-manifest.json" "$CORPUS/real.md"
backdate_days "$CORPUS/notes/sub.md" 8
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 3 ] && [[ "$out" == *"SEMANTIC-STALE"* ]] && [[ "$out" == *"oldest content unstamped 8."* ]] \
  && pass "T11f a content file unstamped past 7 days -> rc=3 SEMANTIC-STALE" || fail "T11f (rc=$rc): $out"
# 7.5 days is past the 7-day bound even though it floors to 7 whole days
backdate_days "$CORPUS/notes/sub.md" 7.5
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 3 ] && [[ "$out" == *"oldest content unstamped 7.5d (bound 7d)"* ]] \
  && pass "T11f2 a content file unstamped 7.5 days -> rc=3, not floored under the bound" || fail "T11f2 (rc=$rc): $out"

# --- T11j: 11 refusals on template/vendored paths are not counted -> OK ---
new_sem_fixture t11j
semantic_row_at "$OUT" "$(ts_hours_ago 2)" "" "$(csv_files templates/r 11)"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [[ "$out" != *"SEMANTIC-STALE"* ]] \
  && pass "T11j 11 template refusals -> not counted, rc=0 OK" || fail "T11j (rc=$rc): $out"

# --- T11k: an unreadable semantic manifest -> SEMANTIC-STALE, never OK on unjudged unstamped bounds ---
new_sem_fixture t11k
semantic_row_at "$OUT" "$(ts_hours_ago 2)" "" ""
printf 'not json\n' > "$OUT/semantic-manifest.json"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 3 ] && [[ "$out" == *"unstamped counts unavailable"* ]] \
  && pass "T11k an unreadable semantic manifest -> rc=3 SEMANTIC-STALE naming it" || fail "T11k (rc=$rc): $out"

# --- T11g: 51 content files unstamped (bound 50) -> SEMANTIC-STALE; the same count under templates/ is not counted ---
new_sem_fixture t11g
semantic_row_at "$OUT" "$(ts_hours_ago 2)" "" ""
mkdir -p "$CORPUS/docs" "$CORPUS/templates"
i=1; while [ "$i" -le 51 ]; do printf '# d%s\n' "$i" > "$CORPUS/docs/d$i.md"; printf '# t%s\n' "$i" > "$CORPUS/templates/t$i.md"; i=$((i+1)); done
printf '{"version":1,"files":{}}\n' > "$OUT/semantic-manifest.json"
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 3 ] && [[ "$out" == *"content unstamped=53"* ]] && [[ "$out" == *" unstamped=53 "* ]] && [[ "$out" == *"non_content_unstamped=0"* ]] \
  && pass "T11g 53 content files unstamped -> rc=3, the 51 template files are not in the corpus at all (HIMMEL-9140)" || fail "T11g (rc=$rc): $out"
rm -f "$CORPUS"/docs/d*.md
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && [[ "$out" != *"SEMANTIC-STALE"* ]] \
  && pass "T11g2 51 unstamped template files alone -> rc=0 OK" || fail "T11g2 (rc=$rc): $out"

# --- T11h: AST stale AND semantic stale -> rc=1 (stale), SEMANTIC-STALE still printed ---
new_sem_fixture t11h
backdate_days "$OUT/graph.json" 10
semantic_row_at "$OUT" "$(ts_hours_ago 72)" "" ""
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"SEMANTIC-STALE"* ]] && pass "T11h stale AST + stale semantic -> rc=1, SEMANTIC-STALE printed" || fail "T11h (rc=$rc): $out"

# --- T11i: a merge row with no ts -> age unknown is not fresh ---
new_sem_fixture t11i
semantic_row_at "$OUT" "" "" ""
out=$( bash "$SCRIPT" --out "$OUT" --max-age-days 7 2>&1 ); rc=$?
[ "$rc" -eq 3 ] && [[ "$out" == *"SEMANTIC-STALE"* ]] && [[ "$out" == *"age unknown"* ]] \
  && pass "T11i a merge row without a ts -> SEMANTIC-STALE (age unknown), never OK" || fail "T11i (rc=$rc): $out"

# --- T12: --print-built-at prints the validated built_at_commit, rc 2 when none ---
OUT="$WS/t12/graphify-out"; mkdir -p "$OUT"
printf '{"nodes":[],"built_at_commit":"5b13e5f169046cf285a51ca21ad47f44064218b5"}\n' > "$OUT/graph.json"
out=$( bash "$SCRIPT" --out "$OUT" --print-built-at 2>/dev/null ); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "5b13e5f169046cf285a51ca21ad47f44064218b5" ] \
  && pass "T12 --print-built-at prints the commit" || fail "T12 print (rc=$rc): $out"
printf '{"nodes":[],"built_at_commit":"--all"}\n' > "$OUT/graph.json"
out=$( bash "$SCRIPT" --out "$OUT" --print-built-at 2>/dev/null ); rc=$?
[ "$rc" -eq 2 ] && [ -z "$out" ] && pass "T12 a non-SHA built_at_commit prints nothing, rc 2" || fail "T12 invalid (rc=$rc): $out"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS FAILURES"; exit 1; fi
echo "ALL PASS"
