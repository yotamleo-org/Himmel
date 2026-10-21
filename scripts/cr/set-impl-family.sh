#!/usr/bin/env bash
# cr/set-impl-family.sh — record which model family implemented a branch, so
# clear-review-marker.sh gate 3c can require a responder of ANOTHER family.
#
# Usage: set-impl-family.sh <family> [<branch>]
#   family  claude | codex | ... the underlying model that wrote the change (the
#           first token of a critic's model slug), not a harness name like hermes
#   branch  defaults to the current branch
#
# Writes <git-common-dir>/cr-impl-family/<branch>. No record = gate 3c is off.
# git-env-ok: the only git calls are rev-parse for the branch and --git-common-dir; a caller's GIT_DIR is the intended repo
set -uo pipefail
family=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
case "$family" in
    ""|*[!a-z0-9_.]*) echo "usage: set-impl-family.sh <family> [<branch>]  (family: lowercase a-z 0-9 _ .)" >&2; exit 10 ;;
esac
branch="${2:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}" # swallow-ok: an empty branch is refused two lines below
gd=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "set-impl-family: not in a git repo" >&2; exit 12; } # swallow-ok: failure exits 12 here
case "$branch" in ""|HEAD|*..*|/*) echo "set-impl-family: bad branch '$branch'" >&2; exit 12 ;; esac
mkdir -p "$gd/cr-impl-family/$(dirname "$branch")" || exit 12
printf '%s\n' "$family" > "$gd/cr-impl-family/$branch" || exit 12
echo "set-impl-family: $branch implemented by '$family'"
