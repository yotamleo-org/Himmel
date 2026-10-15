#!/usr/bin/env bash
# scripts/ci/shard-has-work.sh — does shell-unit shard <i/n> have
# any suite to run under the current selection env? Prints one
# `has_work=true|false` line (GITHUB_OUTPUT-compatible) so the shard job can
# skip its heavy setup (apt, bun, ffmpeg, gitleaks, pre-commit) when a
# pull_request's impacted selection leaves this shard empty.
#
# Usage: shard-has-work.sh <i/n> [<scan root>]      (root defaults .)
#
# It asks run-shell-tests.sh itself (`--list`, which executes nothing), under
# the SAME SUITE_* env the run step gets, so the probe and the run cannot
# disagree about the selection. FAIL-CLOSED: a non-zero --list, output without
# the summary footer, or any `[RUN ]` line prints `true`. Only a clean listing
# with zero `[RUN ]` lines prints `false`.
#
# Platform guard: bash 3.2+; Linux CI is the only caller.
set -uo pipefail

shard="${1:-}"
root="${2:-.}"
[ -n "$shard" ] || { echo "usage: shard-has-work.sh <i/n> [<root>]" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"

if ! out=$(bash "$here/run-shell-tests.sh" --list --shard "$shard" "$root" 2>&1); then
  echo "shard-has-work: --list failed, assuming work" >&2
  echo "has_work=true"
  exit 0
fi
case "$out" in
  *"== Summary =="*) ;;
  *) echo "shard-has-work: no summary footer, assuming work" >&2; echo "has_work=true"; exit 0 ;;
esac
# No pipe: a long listing under pipefail would SIGPIPE the producer of a
# `| grep -q` and read a shard that HAS work as empty (fail-open).
nl='
'
run_marker='[RUN ]'
case "$nl$out" in
  *"${nl}${run_marker}"*) echo "has_work=true" ;;
  *) echo "has_work=false" ;;
esac
