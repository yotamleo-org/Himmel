#!/usr/bin/env bash
# Fixture-repo tests for scripts/insights/self-review.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/insights/self-review.sh"
passes=0
fails=0

ok() { echo "ok - $1"; passes=$((passes + 1)); }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
grepq() { local text="$1"; shift; grep -q "$@" <<< "$text"; }

TMP="$(mktemp -d -t test-self-review.XXXXXX)" || { echo "FAIL - mktemp -d failed (rc=$?)" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false

n=0
merge() { # <date> <subject> [body]
  n=$((n + 1))
  GIT_AUTHOR_DATE="$1T12:00:00Z" GIT_COMMITTER_DATE="$1T12:00:00Z" \
    git -C "$REPO" commit -q --allow-empty -m "$2 (#$n)" -m "${3:-body}"
}

merge 2026-08-01 'fix(hooks): [HIMMEL-1] outside the window' 'main is red
leg-burn: calls=1 avg-ctx=1k first-turn=1k compactions=5'
merge 2026-09-02 'fix(hooks): [HIMMEL-10] tighten the write fence' 'leg-burn: calls=9 avg-ctx=1k first-turn=1k compactions=2'
merge 2026-09-03 'fix: [HIMMEL-10] guard misses a shape' 'leg-burn: calls=9 avg-ctx=1k first-turn=1k compactions=0'
merge 2026-09-04 'fix(docs): [HIMMEL-10] prune history comments' 'fixes-main-red: #2
leg-burn: calls=9 avg-ctx=1k first-turn=1k compactions=1'
merge 2026-09-05 'feat(console): [HIMMEL-11] new verb' 'leg-burn: calls=9 avg-ctx=1k first-turn=1k compactions=0'
merge 2026-09-06 'chore: [HIMMEL-12] bump' 'no burn line here'
merge 2026-09-07 'Revert "feat(x): [HIMMEL-11] new verb"' 'red main after merge'
merge 2026-09-08 'feature-flag: [HIMMEL-13] not a feat prefix'

out="$(bash "$SCRIPT" --repo "$REPO" --ref main --since 2026-09-01 --until 2026-09-30 2>&1)"
rc=$?
check() { # <name> <cmd...>
  local name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name: $out"; fi
}

check "exits 0 on a fixture repo" [ "$rc" -eq 0 ]
check "counts only in-window merges" grepq "$out" -x 'merges: 7'
check "fix share counts fix vs feat subjects" grepq "$out" -x 'fix-share: fix=3 feat=1 share=42%'
check "guard churn counts fix(hooks) and guard subjects" grepq "$out" -x 'guard-churn: 2'
check "compaction share reads compactions= from bodies" grepq "$out" -x 'compaction-share: compacted=2 runs=4 share=50%'
check "sprawl names the ticket with the most merges" grepq "$out" -x 'sprawl: HIMMEL-10 merges=3'
check "red-main counts bodies that mention a red main" grepq "$out" -x 'red-main: 2'

out="$(bash "$SCRIPT" --repo "$REPO" --ref main --since 2026-07-01 --until 2026-08-31 2>&1)"
check "a different window gives different numbers" grepq "$out" -x 'merges: 1'
check "the earlier window counts its own red main" grepq "$out" -x 'red-main: 1'

out="$(bash "$SCRIPT" --repo "$REPO" --ref main --since 2025-01-01 --until 2025-01-31 2>&1)"
check "an empty window prints zero shares" grepq "$out" -x 'fix-share: fix=0 feat=0 share=0%'
check "an empty window names no sprawl" grepq "$out" -x 'sprawl: none'

REPO="$TMP/skew"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
merge 2026-09-10 'feat: [HIMMEL-20] in the window, under skewed history'
for i in $(seq 1 8); do merge 2020-01-01 "chore: [HIMMEL-21] skewed date $i"; done
merge 2026-09-20 'feat: [HIMMEL-22] in the window at the tip'
out="$(bash "$SCRIPT" --repo "$REPO" --ref main --since 2026-09-01 --until 2026-09-30 2>&1)"
check "a run of skewed older dates does not stop the walk" grepq "$out" -x 'merges: 2'

out="$(bash "$SCRIPT" --bogus 2>&1)"
rc=$?
check "an unknown flag exits 2" [ "$rc" -eq 2 ]

echo "passed=$passes failed=$fails"
[ "$fails" -eq 0 ]
