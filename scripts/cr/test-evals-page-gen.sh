#!/usr/bin/env bash
# scripts/cr/test-evals-page-gen.sh - suite for evals-page-gen.py, the generator behind docs/evals/README.md:
# Wilson 95% precision per critic and pooled from a fixture ledger with known counts, counts pinned to
# cr-scores.sh, a rendered page whose every percentage carries "as of <date>, n = <n>", and no typed figure.
# Fixture ledger and fixture cache-probe output only: no model call, no network, never the live ledger.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GEN="$HERE/evals-page-gen.py"
PAGE="$ROOT/docs/evals/README.md"
DATA="$ROOT/docs/evals/evals-data.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/evals-page-test.XXXXXX")" || { echo "test-evals-page-gen: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Never the live ledger, whatever a case forgets to pass.
export CR_LEDGER="$TMP/never.jsonl"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }
lacks() { case "$2" in *"$3"*) fail "$1: '$3' found";; *) pass "$1";; esac; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-evals-page-gen: python3 not on PATH"; exit 0; }

# jget <json-file> <a/b/c> - one value from a JSON file.
jget() { python3 -I -c 'import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("/"): v=v.get(k) if isinstance(v,dict) else None
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2"; }

# bare_pct <file> - every line that holds a percentage but not "as of <date>, n = <n>".
bare_pct() { grep -E '[0-9]%' "$1" | grep -Ev 'as of [0-9]{4}-[0-9]{2}-[0-9]{2}, n = [0-9,]+' || true; }

# ── Fixture ledger ──────────────────────────────────────────────────────────
# alpha: 12 findings on 2 PRs: 6 agreed + 2 fixed, 2 disproved, 1 deferred, 1 unadjudicated
#        ruled 10, precision 8/10 = 80.0%, Wilson 49.0-94.3
# beta:  50 findings on 5 PRs: 45 agreed, 5 disproved
#        precision 45/50 = 90.0%, Wilson 78.6-95.7
# pooled: 62 findings, ruled 60, precision 53/60 = 88.3%, Wilson 77.8-94.2
L="$TMP/ledger.jsonl"
: > "$L"
finding() { # model branch id
  printf '{"kind":"finding","ts":"2026-10-01T10:00:00Z","branch":"%s","head":"h1","model":"%s","finding_id":"%s","severity":"imp","verdict":"","artifact":"diff","perspective":"off","text":"t"}\n' "$2" "$1" "$3" >> "$L"
}
amend() { # branch id verdict
  printf '{"kind":"amend","ts":"2026-10-02T10:00:00Z","branch":"%s","target_head":"h1","finding_id":"%s","artifact":"diff","perspective":"off","set":{"verdict":"%s"},"reason":"r"}\n' "$1" "$2" "$3" >> "$L"
}
i=0
while [ "$i" -lt 12 ]; do
  b="a$((i % 2))"; finding alpha "$b" "alpha-$i"
  case "$i" in
    0|1|2|3|4|5) amend "$b" "alpha-$i" agreed;;
    6|7) amend "$b" "alpha-$i" fixed;;
    8|9) amend "$b" "alpha-$i" disproved;;
    10) amend "$b" "alpha-$i" deferred;;
  esac
  i=$((i + 1))
done
i=0
while [ "$i" -lt 50 ]; do
  b="b$((i % 5))"; finding beta "$b" "beta-$i"
  if [ "$i" -lt 45 ]; then amend "$b" "beta-$i" agreed; else amend "$b" "beta-$i" disproved; fi
  i=$((i + 1))
done

C="$TMP/cache-probe.txt"
printf 'cache-probe first-turn\nsession\tstart\tinput\tcache_read\tcache_create\nread-ratio: 97.4%% over 1200000 tokens\nverdict: warm-start warm=9 cold=1\n' > "$C"

OUT="$TMP/data.json"
python3 -I "$GEN" data --ledger "$L" --cache-probe "$C" --as-of 2026-10-25 --out "$OUT" > "$TMP/data.out" 2> "$TMP/data.err"; rc=$?
eq "data: exit 0" "$rc" "0"

# RED row: precision and Wilson interval to one decimal.
eq "pooled: precision to one decimal" "$(jget "$OUT" review/pooled/precision_pct)" "88.3"
eq "pooled: Wilson low" "$(jget "$OUT" review/pooled/wilson/lo)" "77.8"
eq "pooled: Wilson high" "$(jget "$OUT" review/pooled/wilson/hi)" "94.2"
eq "pooled: n is the ruled findings" "$(jget "$OUT" review/pooled/n)" "60"
eq "pooled: findings raised" "$(jget "$OUT" review/pooled/findings)" "62"
eq "pooled: PRs" "$(jget "$OUT" review/pooled/prs)" "7"
eq "alpha: precision" "$(jget "$OUT" review/critics/alpha/precision_pct)" "80.0"
eq "alpha: Wilson low" "$(jget "$OUT" review/critics/alpha/wilson/lo)" "49.0"
eq "alpha: Wilson high" "$(jget "$OUT" review/critics/alpha/wilson/hi)" "94.3"
eq "alpha: fixed counts as agreed" "$(jget "$OUT" review/critics/alpha/agreed)" "8"
eq "alpha: unadjudicated stays out of n" "$(jget "$OUT" review/critics/alpha/n)" "10"
eq "beta: precision" "$(jget "$OUT" review/critics/beta/precision_pct)" "90.0"
eq "beta: Wilson low" "$(jget "$OUT" review/critics/beta/wilson/lo)" "78.6"
eq "beta: Wilson high" "$(jget "$OUT" review/critics/beta/wilson/hi)" "95.7"
eq "pooled: bootstrap interval sits beside Wilson" "$(python3 -I -c 'import json,sys
b=json.load(open(sys.argv[1]))["review"]["pooled"]["bootstrap"]
print(b is not None and 0 <= b["lo"] <= b["hi"] <= 100)' "$OUT")" "True"
eq "meta: as-of date" "$(jget "$OUT" review/as_of)" "2026-10-25"

# The counts are cr-scores.sh's counts: same ledger, same total and agreed share per model.
CS="$(CR_LEDGER="$L" bash "$HERE/cr-scores.sh" 2>/dev/null)"
a_row="$(printf '%s\n' "$CS" | awk '$1 == "alpha" { print $2, $3; exit }')"
b_row="$(printf '%s\n' "$CS" | awk '$1 == "beta" { print $2, $3; exit }')"
eq "parity: alpha total and agreed% match cr-scores.sh" "$a_row" "12 67%"
eq "parity: beta total and agreed% match cr-scores.sh" "$b_row" "50 90%"
eq "parity: generator alpha findings" "$(jget "$OUT" review/critics/alpha/findings)" "12"
eq "parity: generator alpha agreed share" "$(python3 -I -c 'import json,sys
c=json.load(open(sys.argv[1]))["review"]["critics"]["alpha"]
print(str(round(100*c["agreed"]/c["findings"]))+"%")' "$OUT")" "67%"

# Cache figure from cache-probe output.
eq "cache: read ratio" "$(jget "$OUT" cache/read_ratio_pct)" "97.4"
eq "cache: tokens" "$(jget "$OUT" cache/tokens)" "1200000"
eq "cache: sessions" "$(jget "$OUT" cache/sessions)" "10"

# Render.
R="$TMP/page.md"
python3 -I "$GEN" render --data "$OUT" --out "$R" > "$TMP/render.out" 2> "$TMP/render.err"; rc=$?
eq "render: exit 0" "$rc" "0"
has "render: draft marker" "$(head -5 "$R")" "draft: true"
has "render: pooled figure" "$(cat "$R")" "88.3%"
has "render: interval printed" "$(cat "$R")" "77.8 to 94.2"
has "render: date and n under a figure" "$(cat "$R")" "as of 2026-10-25, n = 60"
has "render: cache regenerate saves the probe output" "$(cat "$R")" "1. \`bash scripts/eval/cache-probe.sh first-turn"
has "render: cache regenerate then feeds the data step" "$(cat "$R")" "2. \`python3 scripts/cr/evals-page-gen.py data --cache-probe cache-probe.txt"
has "render: cache regenerate ends with the render step" "$(cat "$R")" "3. \`python3 scripts/cr/evals-page-gen.py render\`"
has "render: cache figure says cache reads, not tokens omitted from a request" "$(cat "$R")" "were cache reads"
has "render: links the review panel method page" "$(cat "$R")" "(review-panel.md)"
has "render: links the prompt cache method page" "$(cat "$R")" "(prompt-cache.md)"
eq "render: no bare percentage" "$(bare_pct "$R")" ""

# The checker itself must catch one.
printf 'precision is 50%% overall\n' > "$TMP/bad.md"
eq "checker: a bare percentage is reported" "$(bare_pct "$TMP/bad.md")" "precision is 50% overall"

# Determinism: the same inputs give the same bytes.
python3 -I "$GEN" data --ledger "$L" --cache-probe "$C" --as-of 2026-10-25 --out "$TMP/data2.json" > /dev/null 2>&1
eq "data: byte-stable across runs" "$(cmp -s "$OUT" "$TMP/data2.json" && echo same || echo differ)" "same"

# Refusals.
python3 -I "$GEN" data --ledger "$TMP/missing.jsonl" --cache-probe "$C" --as-of 2026-10-25 --out "$TMP/x.json" > /dev/null 2>&1; rc=$?
eq "data: a missing ledger is refused" "$rc" "2"
printf 'nothing here\n' > "$TMP/junk.txt"
python3 -I "$GEN" data --ledger "$L" --cache-probe "$TMP/junk.txt" --as-of 2026-10-25 --out "$TMP/x.json" > /dev/null 2>&1; rc=$?
eq "data: cache-probe output without a read-ratio is refused" "$rc" "2"

# ── The committed page ───────────────────────────────────────────────────────
eq "page: committed README is the render of the committed data file" \
  "$(python3 -I "$GEN" render --data "$DATA" --out "$TMP/committed.md" > /dev/null 2>&1; cmp -s "$TMP/committed.md" "$PAGE" && echo same || echo differ)" "same"
eq "page: no bare percentage" "$(bare_pct "$PAGE")" ""
has "page: draft marker" "$(head -5 "$PAGE")" "draft: true"
eq "page: not on the site allowlist" "$(grep -cx 'evals/README.md' "$ROOT/site/allowlist.txt")" "0"
# The frame's literal numbers live in the data file only, never in the generator.
for lit in '83.5' '81.4' '85.6' '3,386' '3386' '914' '98.3'; do
  eq "no typed figure: '$lit' absent from the generator" "$(grep -cF -- "$lit" "$GEN")" "0"
done

echo "evals-page-gen: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
