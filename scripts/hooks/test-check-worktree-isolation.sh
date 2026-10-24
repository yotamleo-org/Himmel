#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-worktree-isolation.sh.
# The main-branch refusal must name only what exists in an adopted project
# (the plugin skill or the docs-site URL), and its decision must not change.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HOOKS/check-worktree-isolation.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/fixture-tempdir.sh"
R=$(fixture_mktemp_dir) || exit 1
trap 'rm -rf "$R"' EXIT
git -C "$R" init -q -b main
git -C "$R" config user.email t@t
git -C "$R" config user.name t

failures=0
check() {
  local name="$1"
  shift
  if "$@"; then
    printf '  PASS  %s\n' "$name"
  else
    printf '  FAIL  %s\n' "$name"
    failures=$((failures + 1))
  fi
}

out=$( cd "$R" && bash "$SCRIPT" 2>&1 ); rc=$?
has() { case "$out" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
lacks() { ! has "$1"; }

check "on main: refused (rc 1)" test "$rc" -eq 1
check "on main: still says commits on main are not allowed" has "Committing directly on 'main' is not allowed"
check "on main: names the plugin skill" has "himmel-ops:stuck-playbook"
check "on main: names the docs-site URL" has "https://yotamleo-org.github.io/Himmel/internals/stuck-playbook/"
check "on main: no repo-relative himmel docs path" lacks "docs/internals/"

git -C "$R" checkout -q -b feat/x
out=$( cd "$R" && bash "$SCRIPT" 2>&1 ); rc=$?
check "off main: allowed (rc 0)" test "$rc" -eq 0

[ "$failures" -eq 0 ] || { printf '%s failure(s)\n' "$failures"; exit 1; }
printf 'all passed\n'
