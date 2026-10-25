#!/usr/bin/env bash
# scripts/handover/move-renamed-dirs.sh — rename slice M: git mv each
# old-vocabulary directory to its new name, leave a relative symlink at the old
# path so every caller that spells it keeps working, and rewrite the data files
# that key on a real tracked path (suite lists, lint and guard baselines, the
# dev graph). Patterns that must match both spellings (ci-trust-paths.txt,
# pr-job-gates.txt, the guards) are edited by hand, not here.
#
# Idempotent: a pair whose old path is already a symlink is left alone, and a
# rewrite only replaces old spellings, so a second run changes nothing.
#
# Usage, at a himmel worktree root:
#   bash scripts/handover/move-renamed-dirs.sh           apply and stage
#   bash scripts/handover/move-renamed-dirs.sh --check   exit 1 naming each pair
#                                                        or keyed file still old
# Exit: 0 done, 1 --check found pending work, 2 refused (nothing changed).
#
# Merge-forward: revert the move commit, merge main, run this again, commit.
#
# Platform guard (linux-only): the move leaves symlinks, which a Windows
# checkout without core.symlinks cannot hold.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../lib/git-clean.sh" || exit 2
git_env_scrub   # not a git hook - safe to scrub GIT_INDEX_FILE too

# old path, then the new basename beside it
PAIRS='scripts/handover/console-kit chief-kit
scripts/handover/console chief
scripts/console chief
scripts/overnight afk
scripts/eval/leg-digest worker-digest
docs/handover/console-sections chief-sections
docs/handover/leg-sections worker-sections'

KEYED='docs/guide/dev-graph/graph.json
scripts/ci/macos-poc-suites.txt
scripts/ci/suite-durations.tsv
scripts/ci/suite-tiers.tsv
scripts/guardrails/git-env-baseline.txt
scripts/lint/flag-parity-baseline.tsv
scripts/lint/shell-lint-baseline.tsv
scripts/lint/swallowed-errors-baseline.txt'

mode=apply
case "${1:-}" in
  '') ;;
  --check) mode=check ;;
  *) echo "usage: move-renamed-dirs.sh [--check]" >&2; exit 2 ;;
esac

# One sed -E expression per pair: the old path as a whole path segment run,
# not preceded by a path character (so a nested scripts/console/ stays) and
# not followed by a name character (so scripts/overnight-shift.sh stays).
sed_args=()
while read -r old new; do
  sed_args+=(-e "s#(^|[^A-Za-z0-9_./-])${old}([^A-Za-z0-9_.-]|\$)#\\1${old%/*}/${new}\\2#g")
done <<< "$PAIRS"
# A match consumes its trailing boundary, so a second pass catches a path that
# directly follows another on the same line.
rewrite() { sed -E "${sed_args[@]}" "$1" | sed -E "${sed_args[@]}"; }

pending=0
errors=()
while read -r old new; do
  dst="${old%/*}/$new"
  if [ -L "$old" ]; then continue; fi
  pending=1
  if [ "$mode" = check ]; then echo "pending: $old to $dst"; continue; fi
  [ -d "$old" ] || errors+=("$old is missing")
  [ -e "$dst" ] && errors+=("$dst already exists")
done <<< "$PAIRS"
while read -r f; do
  [ -f "$f" ] || continue
  if ! rewrite "$f" | cmp -s - "$f"; then
    pending=1
    [ "$mode" = check ] && echo "pending: $f keys an old path"
  fi
done <<< "$KEYED"

if [ "$mode" = check ]; then exit "$pending"; fi
if [ "${#errors[@]}" -gt 0 ]; then
  printf 'move-renamed-dirs: refused, nothing changed: %s\n' "${errors[@]}" >&2
  exit 2
fi

while read -r old new; do
  [ -L "$old" ] && continue
  git mv -- "$old" "${old%/*}/$new" || { echo "move-renamed-dirs: git mv $old failed" >&2; exit 1; }
  if ! { ln -s -- "$new" "$old" && git add -- "$old"; }; then echo "move-renamed-dirs: symlink at $old failed" >&2; exit 1; fi
  echo "moved $old to ${old%/*}/$new, symlink left"
done <<< "$PAIRS"
tmp="$(mktemp "${TMPDIR:-/tmp}/move-renamed-dirs.XXXXXX")" || exit 1; trap 'rm -f "$tmp"' EXIT
while read -r f; do
  [ -f "$f" ] || continue
  rewrite "$f" > "$tmp" || { echo "move-renamed-dirs: rewrite of $f failed" >&2; exit 1; }
  cmp -s "$tmp" "$f" && continue
  if ! { cat "$tmp" > "$f" && git add -- "$f"; }; then echo "move-renamed-dirs: writing $f failed" >&2; exit 1; fi
  echo "rewrote $f"
done <<< "$KEYED"
