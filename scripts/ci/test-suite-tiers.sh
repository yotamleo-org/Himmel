#!/usr/bin/env bash
# selector: tree-scan
# scripts/ci/test-suite-tiers.sh — lint for scripts/ci/suite-tiers.tsv.
#
# suite-tiers.tsv is the one machine-read tier per suite: path<TAB>tier<TAB>reason.
# No runner reads it yet. This file is both the lint and its own test:
#
#   bash scripts/ci/test-suite-tiers.sh   lints the repo's tier file, then runs the
#                                         RED rows (each a fixture the lint must refuse).
#   bash scripts/ci/test-suite-tiers.sh --lint [--tiers F] [--trust F] [--tracked F]
#                                         the lint alone; prints one FAIL line per
#                                         violation, exit 0 clean / 1 violations.
#
# Rules:
#   - one row per tracked suite (basename test-*.sh, the runner's discovery), no stale rows,
#     no duplicate rows, no malformed rows;
#   - the tier is one of pr, local, flow, quarantine;
#   - a pr reason is catch:<n> | trust-path | static-gate | guard | flow-miss:HIMMEL-<n>;
#   - a trust-owned suite is never local. Trust-owned = its path matches a
#     ci-trust-paths.txt pattern, or it is the sibling of a trust-path file (same
#     directory, the file's stem equals the suite's stem after dropping test- and
#     trailing -words). The rule is computed, not hand-listed.
#
# Exit codes: 0 — all cases passed; 1 — at least one failed; 2 — usage error
# (an unknown --lint option, or one given with no value).
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

lint() { # <tiers> <trust> <tracked-list>
  awk -F'\t' -v tiers="$1" -v trust="$2" '
    function is_trust(p,   i) {
      for (i = 1; i <= nt; i++) if (p ~ tp[i]) return 1
      return 0
    }
    function trust_owned(s,   d, stem) {
      if (is_trust(s)) return 1
      d = s; sub(/[^\/]*$/, "", d)
      stem = s; sub(/^.*\//, "", stem); sub(/^test-/, "", stem); sub(/\.sh$/, "", stem)
      while (stem != "") {
        if ((d stem) in sib) return 1
        if (stem !~ /-/) break
        sub(/-[^-]*$/, "", stem)
      }
      return 0
    }
    BEGIN {
      while ((getline line < trust) > 0)
        if (line !~ /^[ \t]*(#|$)/) tp[++nt] = line
      close(trust)
    }
    FILENAME == tiers {
      if ($0 ~ /^[ \t]*(#|$)/) next
      if (NF != 3 || $1 == "" || $2 == "" || $3 == "") { printf "FAIL malformed row %d: %s\n", FNR, $0; bad++; next }
      if ($1 in tier) { printf "FAIL duplicate row: %s\n", $1; bad++; next }
      tier[$1] = $2; reason[$1] = $3
      next
    }
    {
      tracked[$0] = 1
      b = $0; sub(/^.*\//, "", b)
      if (b ~ /^test-.*\.sh$/) suites[++ns] = $0
      else if (is_trust($0)) { d = $0; sub(/[^\/]*$/, "", d); st = b; sub(/\.[^.]*$/, "", st); sib[d st] = 1 }
    }
    END {
      for (i = 1; i <= ns; i++) {
        s = suites[i]; seen[s] = 1
        if (!(s in tier)) { printf "FAIL suite has no tier row: %s\n", s; bad++; continue }
        t = tier[s]; r = reason[s]
        if (t !~ /^(pr|local|flow|quarantine)$/) { printf "FAIL unknown tier %s: %s\n", t, s; bad++; continue }
        if (t == "pr" && r !~ /^(catch:[0-9]+|trust-path|static-gate|guard|flow-miss:HIMMEL-[0-9]+)$/) {
          printf "FAIL pr suite with an unjustified reason (%s): %s\n", r, s; bad++
        }
        if (t == "local" && trust_owned(s)) { printf "FAIL trust-path suite is local: %s\n", s; bad++ }
      }
      for (s in tier) if (!(s in seen)) { printf "FAIL stale row, no such suite: %s\n", s; bad++ }
      exit (bad > 0)
    }
  ' "$1" "$3"
}

if [ "${1:-}" = "--lint" ]; then
  shift
  tiers="$REPO_ROOT/scripts/ci/suite-tiers.tsv"
  trust="$REPO_ROOT/scripts/ci/ci-trust-paths.txt"
  tracked=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tiers|--trust|--tracked)
        [ $# -ge 2 ] || { echo "usage: $0 --lint [--tiers F] [--trust F] [--tracked F]" >&2; exit 2; }
        case "$1" in
          --tiers) tiers="$2" ;;
          --trust) trust="$2" ;;
          --tracked) tracked="$2" ;;
        esac ;;
      *) echo "usage: $0 --lint [--tiers F] [--trust F] [--tracked F]" >&2; exit 2 ;;
    esac
    shift 2
  done
  [ -r "$tiers" ] || { echo "FAIL tier file unreadable: $tiers"; exit 1; }
  [ -r "$trust" ] || { echo "FAIL trust list unreadable: $trust"; exit 1; }
  if [ -z "$tracked" ]; then
    tracked=$(mktemp "${TMPDIR:-/tmp}/suite-tiers-tracked.XXXXXX") || exit 1
    trap 'rm -f "$tracked"' EXIT
    git -C "$REPO_ROOT" ls-files > "$tracked" || { echo "FAIL git ls-files failed"; exit 1; }
  fi
  lint "$tiers" "$trust" "$tracked"
  exit $?
fi

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/suite-tiers.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

echo "== repo: scripts/ci/suite-tiers.tsv lints clean"
if bash "$SELF" --lint > "$tmp/repo.out" 2>&1; then
  pass "suite-tiers.tsv covers every tracked suite"
else
  fail "suite-tiers.tsv does not lint clean"
  head -20 "$tmp/repo.out"
fi

# Fixture tree: trust list, three tracked suites (one trust-owned by direct match,
# one by sibling of a trust-path file, one ordinary), a tier file that is clean.
printf '%s\n' '# fixture trust list' '^scripts/ci/' '^scripts/cr/impacted-' > "$tmp/trust"
printf '%s\n' scripts/ci/test-alpha.sh scripts/cr/impacted-suites.sh scripts/cr/test-impacted-suites-extra.sh \
  scripts/foo/test-plain.sh scripts/foo/lib.sh > "$tmp/tracked"
printf '%s\t%s\t%s\n' \
  scripts/ci/test-alpha.sh pr trust-path \
  scripts/cr/test-impacted-suites-extra.sh pr trust-path \
  scripts/foo/test-plain.sh local 'behaviour suite' > "$tmp/good.tsv"

# retier <in> <out> <suite> <tier> <reason>: copy a tier file with one row rewritten
retier() { awk -F'\t' -v OFS='\t' -v s="$3" -v t="$4" -v r="$5" '$1 == s { $2 = t; $3 = r } { print }' "$1" > "$2"; }

# row <label> <want-rc> <want-text> <tiers-file> [tracked-file]
row() {
  bash "$SELF" --lint --tiers "$4" --trust "$tmp/trust" --tracked "${5:-$tmp/tracked}" > "$tmp/out" 2>&1; rc=$?
  if [ "$rc" -ne "$2" ]; then fail "$1 -> expected exit $2 got $rc"; return; fi
  if [ -n "$3" ] && ! grep -qF -- "$3" "$tmp/out"; then fail "$1 -> output lacks '$3'"; return; fi
  pass "$1 -> exit $2"
}

echo "== fixture rows"
row "clean fixture" 0 "" "$tmp/good.tsv"

grep -v 'test-plain' "$tmp/good.tsv" > "$tmp/missing.tsv"
row "RED: a suite with no row" 1 "suite has no tier row: scripts/foo/test-plain.sh" "$tmp/missing.tsv"

{ cat "$tmp/good.tsv"; printf 'scripts/gone/test-old.sh\tlocal\tbehaviour suite\n'; } > "$tmp/stale.tsv"
row "RED: a stale row" 1 "stale row, no such suite: scripts/gone/test-old.sh" "$tmp/stale.tsv"

retier "$tmp/good.tsv" "$tmp/badtier.tsv" scripts/foo/test-plain.sh slow 'behaviour suite'
row "RED: an unknown tier" 1 "unknown tier slow" "$tmp/badtier.tsv"

retier "$tmp/good.tsv" "$tmp/unjustified.tsv" scripts/ci/test-alpha.sh pr because
row "RED: a pr suite with an unjustified reason" 1 "unjustified reason (because)" "$tmp/unjustified.tsv"

retier "$tmp/good.tsv" "$tmp/localtrust.tsv" scripts/ci/test-alpha.sh local 'behaviour suite'
row "RED: a local trust-path suite (direct match)" 1 "trust-path suite is local: scripts/ci/test-alpha.sh" "$tmp/localtrust.tsv"

retier "$tmp/good.tsv" "$tmp/localsib.tsv" scripts/cr/test-impacted-suites-extra.sh local 'behaviour suite'
row "RED: a local sibling of a trust-path file" 1 "trust-path suite is local: scripts/cr/test-impacted-suites-extra.sh" "$tmp/localsib.tsv"

{ cat "$tmp/good.tsv"; printf 'scripts/foo/test-plain.sh\tlocal\tbehaviour suite\n'; } > "$tmp/dup.tsv"
row "RED: a duplicate row" 1 "duplicate row: scripts/foo/test-plain.sh" "$tmp/dup.tsv"

printf '%s\t%s\n' scripts/foo/test-plain.sh local > "$tmp/short.tsv"
row "RED: a row with no reason" 1 "malformed row" "$tmp/short.tsv"

for reason in catch:3218 static-gate guard flow-miss:HIMMEL-6001; do
  retier "$tmp/good.tsv" "$tmp/r.tsv" scripts/ci/test-alpha.sh pr "$reason"
  row "pr reason $reason accepted" 0 "" "$tmp/r.tsv"
done

for opt in --tiers --trust --tracked; do
  bash "$SELF" --lint "$opt" > "$tmp/out" 2>&1; rc=$?
  if [ "$rc" -eq 2 ] && grep -qF -- usage "$tmp/out"; then pass "RED: $opt with no value -> usage, exit 2"; else fail "$opt with no value -> rc=$rc, expected usage and exit 2"; fi
done

echo "== real trust list + real tracked suites, one row of the committed file broken"
REAL="$REPO_ROOT/scripts/ci/suite-tiers.tsv"
REAL_TRUST="$REPO_ROOT/scripts/ci/ci-trust-paths.txt"
git -C "$REPO_ROOT" ls-files > "$tmp/real-tracked"
real_row() { # <label> <want-text> <tiers-file>
  bash "$SELF" --lint --tiers "$3" --trust "$REAL_TRUST" --tracked "$tmp/real-tracked" > "$tmp/out" 2>&1; rc=$?
  if [ "$rc" -eq 1 ] && grep -qF -- "$2" "$tmp/out"; then pass "$1 -> exit 1"; else fail "$1 -> rc=$rc, output lacks '$2'"; fi
}
grep -vF 'scripts/hooks/test-block-edit-live-settings.sh' "$REAL" > "$tmp/real-missing.tsv"
real_row "RED: real suite row removed" "suite has no tier row: scripts/hooks/test-block-edit-live-settings.sh" "$tmp/real-missing.tsv"
retier "$REAL" "$tmp/real-local.tsv" scripts/ci/test-run-shell-tests.sh local behaviour
real_row "RED: real ci/ suite demoted to local" "trust-path suite is local: scripts/ci/test-run-shell-tests.sh" "$tmp/real-local.tsv"
retier "$REAL" "$tmp/real-sib.tsv" scripts/cr/test-failure-classify.sh local behaviour
real_row "RED: real sibling of a trust-path file demoted to local" "trust-path suite is local: scripts/cr/test-failure-classify.sh" "$tmp/real-sib.tsv"

echo "== $((failures)) failure(s)"
[ "$failures" -eq 0 ]
