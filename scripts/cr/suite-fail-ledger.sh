#!/usr/bin/env bash
# scripts/cr/suite-fail-ledger.sh [<ledger>] — read the CI failure ledger that
# ready-check's item 19 appends: how often a suite left to CI
# failed there, and how often that failure cost an extra round (a new push).
#
# Ledger: <ledger>, else ~/.himmel/state/suite-evidence/ci-failures.jsonl. Rows:
#   fail   {repo, pr, head, suite, run, rc} — a suite left to CI failed at a PR head
#   round  {repo, pr, head, next}           — that PR moved from <head> to <next>
# A failure counts once per (repo, pr, head, suite, run); a head counts once per
# (repo, pr, head); it cost an extra round when a round row names it.
# Report-only: exit 0 with a missing or empty ledger, 2 on a usage error.
set -uo pipefail
if [ $# -gt 1 ]; then
    echo "usage: suite-fail-ledger.sh [<ledger>]" >&2
    exit 2
fi
f="${1:-${HOME:-/tmp}/.himmel/state/suite-evidence/ci-failures.jsonl}"
counts="0 0 0"
if [ -r "$f" ]; then
    counts=$(jq -n -R -r '
        [inputs | fromjson? | select(type == "object")] as $rows
        | ($rows | map(select(.kind == "fail")) | map({repo, pr, head, suite, run}) | unique) as $f
        | ($f | map({repo, pr, head}) | unique) as $h
        | ($rows | map(select(.kind == "round")) | map({repo, pr, head}) | unique) as $r
        | "\($f | length) \($h | length) \([$h[] | select(. as $x | $r | any(. == $x))] | length)"' "$f") || {
        echo "suite-fail-ledger: cannot read $f" >&2
        exit 1
    }
fi
read -r n_fail n_head n_round <<< "$counts"
rate="n/a"
[ "$n_head" -eq 0 ] || rate="$((n_round * 100 / n_head))%"
echo "suite-fail-ledger: $n_fail CI failure(s) of a suite left to CI, at $n_head head(s); $n_round head(s) cost an extra round ($rate)"
