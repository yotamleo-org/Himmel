#!/usr/bin/env bash
# scripts/eval/conflicts/test-conflicts.sh - suite for conflicts.py (slice S3 of the no-file-holds work): the detector, the body
# parser, the recorder and the backfill. Temp git repos and fixture gh/git shims only: no network, never the
# real bucket, registry or ~/.himmel.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CONF="$HERE/conflicts.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/conflicts-test.XXXXXX")" || { echo "test-conflicts: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/shim"
export HOME="$TMP/home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export HANDOVER_REGISTRY="$TMP/never-registry.json" HIMMEL_CONFIG_DIR="$TMP/never-conf"
export HANDOVER_DIR="$TMP/ho" USER_SLUG=u
unset HIMMEL_REPO
mkdir -p "$TMP/ho"
REAL_GIT="$(command -v git)"
export REAL_GIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1: no '$3' in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1: found '$3' in: $2" ;; *) pass "$1" ;; esac; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-conflicts: python3 not on PATH"; exit 0; }

# fixture gh: `pr view N` answers isCrossRepository (PR 3 is an outside PR), `pr list` returns two merged PRs; argv is logged
cat > "$TMP/shim/gh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TMP_GH_LOG"
case "$1 $2" in
  "pr view")
    case "$3" in
      3) echo '{"isCrossRepository":true}' ;;
      *) echo '{"isCrossRepository":false}' ;;
    esac ;;
  "pr list") cat "$TMP_GH_LIST" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/shim/gh"
mkdir -p "$TMP/gitshim"
cat > "$TMP/gitshim/git" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$GITSHIM_LOG"
exec "$REAL_GIT" "$@"
SH
chmod +x "$TMP/gitshim/git"
export TMP_GH_LOG="$TMP/gh.log" TMP_GH_LIST="$TMP/gh-list.json"
export PATH="$TMP/shim:$PATH"

g() { "$REAL_GIT" -C "$1" "${@:2}"; }

# build NAME MODE: main has f.sh (3 lines); branch B edits line 1; main gets "x (#12)"; B merges main and
# resolves as MODE: merged | ours (B's side) | theirs (main's side) | deleted | clean (different lines)
build() {
  local r="$TMP/$1" mode="$2"
  mkdir -p "$r"
  "$REAL_GIT" init -q -b main "$r"
  g "$r" config user.email t@example.com; g "$r" config user.name t; g "$r" config commit.gpgsign false
  printf 'a\nb\nc\n' > "$r/f.sh"
  g "$r" add f.sh; g "$r" commit -q -m init
  g "$r" checkout -q -b B
  printf 'B1\nb\nc\n' > "$r/f.sh"; g "$r" commit -q -am "branch edit"
  g "$r" checkout -q main
  if [ "$mode" = clean ]; then printf 'a\nb\nM3\n' > "$r/f.sh"; else printf 'M1\nb\nc\n' > "$r/f.sh"; fi
  g "$r" commit -q -am "x (#12)"
  g "$r" checkout -q B
  case "$mode" in
    clean) g "$r" merge -q --no-ff --no-edit main ;;
    *)
      g "$r" merge main >/dev/null 2>&1
      case "$mode" in
        merged) printf 'both\nb\nc\n' > "$r/f.sh"; g "$r" add f.sh ;;
        ours) g "$r" checkout --ours f.sh; g "$r" add f.sh ;;
        theirs) g "$r" checkout --theirs f.sh; g "$r" add f.sh ;;
        deleted) g "$r" rm -q -f f.sh ;;
      esac
      g "$r" commit -q --no-edit ;;
  esac
}

det() { python3 -I "$CONF" detect --repo-dir "$1" --head "$2" --base-ref main "${@:3}" 2>&1; }

# 0. the script exists
if [ -f "$CONF" ]; then pass "conflicts.py exists"; else fail "conflicts.py exists"; echo "RESULT pass=$PASS fail=$FAIL"; exit 1; fi

# 1. detector: the four resolutions and the clean merge
for mode in merged ours theirs deleted; do
  build "d-$mode" "$mode"
  head="$(g "$TMP/d-$mode" rev-parse B)"
  out="$(det "$TMP/d-$mode" "$head")"
  eq "detect $mode" "$out" "$(printf 'f.sh\tother_prs [12]\t%s\t%s' "$mode" "$head")"
done
build d-clean clean
out="$(det "$TMP/d-clean" "$(g "$TMP/d-clean" rev-parse B)")"
eq "detect clean merge prints nothing" "$out" ""

# 2. more than 20 merge commits: unknown, no file listed
build d-many merged
r="$TMP/d-many"
for i in $(seq 1 21); do
  g "$r" checkout -q -b "s$i" main
  printf 'x%s\n' "$i" > "$r/s$i.txt"; g "$r" add "s$i.txt"; g "$r" commit -q -m "s$i"
  g "$r" checkout -q B
  g "$r" merge -q --no-ff --no-edit "s$i"
done
out="$(det "$r" "$(g "$r" rev-parse B)")"
eq "detect over 20 merges" "$out" "unknown (over 20 merges)"
hasnt "over 20 merges lists no file" "$out" "f.sh"

# 3. a head missing from the store: one bounded no-write-fetch-head fetch, FETCH_HEAD untouched
build fork merged
g "$TMP/fork" update-ref refs/pull/7/head "$(g "$TMP/fork" rev-parse B)"
R2="$TMP/fork2"
"$REAL_GIT" init -q -b main "$R2"
g "$R2" remote add origin "$TMP/fork"
g "$R2" config remote.origin.fetch "+refs/heads/main:refs/remotes/origin/main"
g "$R2" fetch -q origin main
FH="$R2/.git/FETCH_HEAD"
before="$(sha "$FH")"
head="$(g "$TMP/fork" rev-parse B)"
: > "$TMP/gitshim.log"
out="$(PATH="$TMP/gitshim:$PATH" GITSHIM_LOG="$TMP/gitshim.log" python3 -I "$CONF" detect --repo-dir "$R2" --head "$head" --base-ref origin/main --pr 7 2>&1)"
has "fork head fetched" "$(cat "$TMP/gitshim.log")" "fetch --no-write-fetch-head origin refs/pull/7/head"
eq "fork head fetched once" "$(grep -c 'fetch --no-write-fetch-head' "$TMP/gitshim.log")" "1"
eq "FETCH_HEAD byte-identical" "$(sha "$FH")" "$before"
has "fork head detected after fetch" "$out" "f.sh"

# 4. body parser
parsed="$(python3 -I - "$HERE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import conflicts
body = ("intro\r\n## Summary\r\n- a vs #9: not me\r\n## Conflicts resolved\r\n"
        "- f.sh vs #12: kept main's line\r\n- `g/h.txt` vs #3, #4: both\r\n- bare.sh vs #5\r\nprose line\r\n## Other\r\n- z vs #1: no\r\n")
for row in conflicts.parse_body(body):
    print(row)
print(conflicts.parse_body("## Summary\nnothing\n"))
PY
)"
has "parser: first line" "$parsed" "('f.sh', [12], \"kept main's line\")"
has "parser: backticks and two PRs" "$parsed" "('g/h.txt', [3, 4], 'both')"
has "parser: no note" "$parsed" "('bare.sh', [5], '')"
hasnt "parser: stops at next ##" "$parsed" "'z'"
hasnt "parser: ignores other sections" "$parsed" "'a'"
has "parser: no section is empty" "$parsed" "[]"

# 5. record
build rec merged
rec="$TMP/rec"
mkdir -p "$rec/scripts/ci"
RHEAD="$(g "$rec" rev-parse B)"
cat > "$TMP/snap.json" <<JSON
{"number":31,"title":"feat(x): [HIMMEL-9] t","body":"## Summary\nx\n\n## Conflicts resolved\n- f.sh vs #12: kept the main side\n- g.txt vs #3: undetected\n\n## Other\n- z\n","mergedAt":"2026-11-08T10:00:00Z","mergeCommit":{"oid":"abc123"},"headRefOid":"$RHEAD","isCrossRepository":false}
JSON
L="$TMP/L"
out="$(python3 -I "$CONF" record --snapshot "$TMP/snap.json" --repo-dir "$rec" --base-ref main --ledger-dir "$L" 2>&1)"
eq "record machine line" "$out" "wrote:2 f.sh vs #12 merged; g.txt vs #3 reported"
F="$L/conflicts/31.jsonl"
if [ -f "$F" ]; then pass "record wrote the ledger file"; else fail "record wrote the ledger file"; fi
rows="$(python3 -I - "$F" "$RHEAD" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
keys = {"v", "repo", "pr", "key", "head", "merge_commit", "merged_at", "merge", "file", "other_prs", "resolution",
        "detected", "reported", "note", "trust_path", "outside", "source", "recorded_at"}
print("keys", all(set(r) == keys for r in rows))
f, g = rows
print("f", f["v"], f["pr"], f["key"], f["head"] == sys.argv[2], f["merge_commit"], f["merged_at"], f["merge"] == sys.argv[2],
      f["file"], f["other_prs"], f["resolution"], f["detected"], f["reported"], f["note"], f["outside"], f["source"])
print("g", g["file"], g["other_prs"], g["resolution"], g["detected"], g["reported"], g["note"], g["outside"], repr(g["merge"]))
PY
)"
has "row fields exact" "$rows" "keys True"
has "detected + reported row" "$rows" "f 1 31 HIMMEL-9 True abc123 2026-11-08T10:00:00Z True f.sh [12] merged True True kept the main side False merge-on-green"
has "reported-only row" "$rows" "g g.txt [3] reported False True undetected True ''"
b4="$(sha "$F")"
out="$(python3 -I "$CONF" record --snapshot "$TMP/snap.json" --repo-dir "$rec" --base-ref main --ledger-dir "$L" 2>&1)"
eq "second run prints kept" "$out" "kept"
eq "second run leaves bytes alone" "$(sha "$F")" "$b4"
eq "no temp file left behind" "$(find "$L/conflicts" -name '31.jsonl*' | sed 's|.*/||')" "31.jsonl"

# trust_path comes from the base ref's ci-trust-paths.txt
printf '# c\n^f\\.sh$\n' > "$rec/scripts/ci/ci-trust-paths.txt"
g "$rec" checkout -q main; g "$rec" add scripts/ci/ci-trust-paths.txt; g "$rec" commit -q -m "trust list"; g "$rec" checkout -q B
sed -e 's/"number":31/"number":32/' "$TMP/snap.json" > "$TMP/snap32.json"
python3 -I "$CONF" record --snapshot "$TMP/snap32.json" --repo-dir "$rec" --base-ref main --ledger-dir "$L" >/dev/null 2>&1
trust="$(python3 -I -c 'import json,sys; print([(r["file"], r["trust_path"]) for r in map(json.loads, open(sys.argv[1]))])' "$L/conflicts/32.jsonl")"
eq "trust_path from the base ref list" "$trust" "[('f.sh', True), ('g.txt', False)]"

# no section and no conflict: none, no file; no --ledger-dir: the judge_accuracy bucket rule
build rec-clean clean
CH="$(g "$TMP/rec-clean" rev-parse B)"
cat > "$TMP/snap-none.json" <<JSON
{"number":33,"title":"feat(x): [HIMMEL-9] t","body":"## Summary\nnothing\n","mergedAt":"","mergeCommit":null,"headRefOid":"$CH","isCrossRepository":false}
JSON
out="$(python3 -I "$CONF" record --snapshot "$TMP/snap-none.json" --repo-dir "$TMP/rec-clean" --base-ref main --ledger-dir "$L" 2>&1)"
eq "nothing to record prints none" "$out" "none"
if [ ! -e "$L/conflicts/33.jsonl" ]; then pass "none writes no file"; else fail "none writes no file"; fi
sed -e "s/\"headRefOid\":\"[0-9a-f]*\"/\"headRefOid\":\"$RHEAD\"/" -e 's/"number":31/"number":34/' "$TMP/snap.json" > "$TMP/snap34.json"
out="$(python3 -I "$CONF" record --snapshot "$TMP/snap34.json" --repo-dir "$rec" --base-ref main 2>&1)"
has "default ledger dir wrote" "$out" "wrote:2"
if [ -f "$TMP/ho/u/rec/conflicts/34.jsonl" ]; then pass "default ledger dir is the bucket's conflicts dir"; else fail "default ledger dir is the bucket's conflicts dir: $(find "$TMP/ho" -type f)"; fi

# unknown detection writes nothing
cat > "$TMP/snap-unk.json" <<JSON
{"number":35,"title":"feat(x): [HIMMEL-9] t","body":"## Conflicts resolved\n- f.sh vs #12: x\n","mergedAt":"","mergeCommit":null,"headRefOid":"$(g "$r" rev-parse B)","isCrossRepository":false}
JSON
out="$(python3 -I "$CONF" record --snapshot "$TMP/snap-unk.json" --repo-dir "$r" --base-ref main --ledger-dir "$L" 2>&1)"
eq "unknown detection prints unknown" "$out" "unknown"
if [ ! -e "$L/conflicts/35.jsonl" ]; then pass "unknown writes no file"; else fail "unknown writes no file"; fi

# 6. backfill: two merged PRs from the fixture gh
cat > "$TMP/gh-list.json" <<JSON
[{"number":41,"title":"feat(x): [HIMMEL-9] a","body":"## Conflicts resolved\n- f.sh vs #12: a\n","mergedAt":"2026-11-03T10:00:00Z","mergeCommit":{"oid":"c41"},"headRefOid":"$RHEAD","isCrossRepository":false},
 {"number":42,"title":"feat(x): [HIMMEL-9] b","body":"## Conflicts resolved\n- f.sh vs #12: b\n","mergedAt":"2026-11-04T10:00:00Z","mergeCommit":{"oid":"c42"},"headRefOid":"$RHEAD","isCrossRepository":false}]
JSON
BL="$TMP/BL"
: > "$TMP_GH_LOG"
out="$(python3 -I "$CONF" backfill --since 2026-11-01T00:00:00Z --repo-dir "$rec" --base-ref main --ledger-dir "$BL" 2>&1)"
has "backfill ran the merged search" "$(cat "$TMP_GH_LOG")" "merged:>=2026-11-01"
eq "backfill wrote two files" "$(find "$BL/conflicts" -name '*.jsonl' | sort | sed 's|.*/||' | tr '\n' ' ')" "41.jsonl 42.jsonl "
srcs="$(python3 -I -c 'import json,sys; print(sorted({json.loads(l)["source"] for f in sys.argv[1:] for l in open(f)}))' "$BL/conflicts/41.jsonl" "$BL/conflicts/42.jsonl")"
eq "backfill rows say source backfill" "$srcs" "['backfill']"

echo "RESULT pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
