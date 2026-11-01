#!/usr/bin/env bash
# check-critic-eval.sh <base> <head> — the reviewer-eval merge gate.
# A diff that changes a critic behaviour path (scripts/eval/review-panel/cbs.txt, expanded at base AND at
# head, so deleting a line from cbs.txt does not hide the file it named) merges only when
# `score.py gate <base> <head>` says keep or no-loss: two eval rows at the base's cbs_hash and two at the
# head's, all at the head tree's confighash, in the head tree's results.jsonl. Rows come from the chief's
# sweeps (scripts/eval/review-panel/README.md "The merge gate").
# Run from inside the checkout; CI passes the PR base sha and HEAD (the merge ref).
# Exit 0 no critic path changed, or keep / no-loss; 1 loss / unmeasured / no rows; 2 usage.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCORE="$HERE/../eval/review-panel/score.py"
[ $# -eq 2 ] || { echo "usage: check-critic-eval.sh <base> <head>" >&2; exit 2; }
base="$1"; head="$2"
repo="$(git rev-parse --show-toplevel)" || { echo "check-critic-eval: not inside a git checkout" >&2; exit 2; }

changed="$(git -C "$repo" diff --name-only --no-renames "$base" "$head")" \
    || { echo "check-critic-eval: cannot diff $base..$head" >&2; exit 2; }
cbs_base="$(python3 "$SCORE" cbs-paths "$base" --repo "$repo")" || exit 2
cbs_head="$(python3 "$SCORE" cbs-paths "$head" --repo "$repo")" || exit 2
hit="$(printf '%s\n%s\n' "$cbs_base" "$cbs_head" | sort -u | grep -vx '' | grep -Fxf - <(printf '%s\n' "$changed"))"
if [ -z "$hit" ]; then
    echo "check-critic-eval: no protected critic path changed"
    exit 0
fi
echo "check-critic-eval: critic behaviour paths changed:"
printf '%s\n' "$hit" | sed 's/^/  /'
if python3 "$SCORE" gate "$base" "$head" --repo "$repo"; then
    exit 0
fi
echo "check-critic-eval: FAIL - a critic change merges only with keep or no-loss eval rows (scripts/eval/review-panel/README.md)" >&2
exit 1
