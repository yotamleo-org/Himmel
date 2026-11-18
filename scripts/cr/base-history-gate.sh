#!/usr/bin/env bash
# Platform guard (posix-bash): POSIX bash 3.2+.
#
# scripts/cr/base-history-gate.sh — run the history-comment / ticket-ref gate the way CI does,
# before the first push. CI's "history-comment gate (PR range)" step judges a PR with the BASE
# branch's copies of the gate, the classifier and the allow list, so a row added on the branch
# never helps the branch's own CI run, while the pre-commit and pre-push hooks read the branch's
# own list and pass. This script copies those three files from the base ref to a scratch dir and
# runs the base gate over the branch's range: a key on a path the base list does not cover shows
# up here, not after a paid CI run.
#
# Usage: base-history-gate.sh [--base <ref>] [--tip <ref>]
#   --base  the ref whose copies judge the branch (default: origin/<default branch>)
#   --tip   the branch tip to judge (default: HEAD)
# The judged range is merge-base(base, tip)..tip, so a branch behind its base is not charged
# with the base's own newer commits.
# Exit: 0 clean (or the gate script is absent from the base ref: nothing to mirror)
#       1 findings, printed as path:line: <reason>: <text>, then the way out
#       2 cannot evaluate: a ref does not resolve, the base lacks the classifier or the list, git failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/git-clean.sh
. "$HERE/../lib/git-clean.sh"
git_env_scrub

usage() { echo "usage: base-history-gate.sh [--base <ref>] [--tip <ref>]" >&2; exit 2; }
base="" tip="HEAD"
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || usage; base="$2"; shift 2 ;;
    --tip)  [ $# -ge 2 ] || usage; tip="$2"; shift 2 ;;
    *) usage ;;
  esac
done

if [ -z "$base" ]; then
  # shellcheck disable=SC1091  # path resolved from this script's own directory
  _db="$(. "$HERE/../guardrails/lib.sh" 2>/dev/null && default_branch 2>/dev/null)" || _db=""  # swallow-ok: no resolvable default branch falls back to main, the repo's default
  base="origin/${_db:-main}"
fi

base_sha="$(git rev-parse --verify --quiet "$base^{commit}")" || { echo "base-history-gate: base ref $base does not resolve, cannot evaluate" >&2; exit 2; }
tip_sha="$(git rev-parse --verify --quiet "$tip^{commit}")" || { echo "base-history-gate: tip ref $tip does not resolve, cannot evaluate" >&2; exit 2; }
range_base="$(git merge-base "$base_sha" "$tip_sha")" || { echo "base-history-gate: no merge base between $base and $tip, cannot evaluate" >&2; exit 2; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/base-history-gate.XXXXXX")" || { echo "base-history-gate: mktemp failed" >&2; exit 2; }  # prim-ok: standalone script, the template form is portable
trap 'rm -rf "$scratch"' EXIT
gate="$scratch/scripts/lint"
mkdir -p "$gate"

# A base from before the gate existed has nothing CI would run: nothing to mirror.
if ! git cat-file -e "$base_sha:scripts/lint/check-history-comments.sh" 2>/dev/null; then
  echo "base-history-gate: the gate is absent at $base, nothing to mirror"
  exit 0
fi
for f in check-history-comments.sh ticket-refs.awk ticket-ref-allow.tsv; do
  if ! git show "$base_sha:scripts/lint/$f" > "$gate/$f" 2>/dev/null || [ ! -s "$gate/$f" ]; then
    echo "base-history-gate: scripts/lint/$f absent at $base, cannot evaluate" >&2
    exit 2
  fi
done

bash "$gate/check-history-comments.sh" --range "$range_base" --tip "$tip_sha"
rc=$?
if [ "$rc" -eq 1 ]; then
  echo "base-history-gate: CI judges this range with $base's allow list, so these lines fail its lint job." >&2
  echo "  Fix: keep the key off the line, or on a path $base's scripts/lint/ticket-ref-allow.tsv already covers;" >&2
  echo "  only when a program reads the key, land the one-row allow-list change on $base first." >&2
fi
exit "$rc"
