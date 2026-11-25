#!/usr/bin/env bash
# check-version-timing-words.sh — refuses a version name used as a timing word.
#
# A version is a set of promises cut when it is true, not a date. A sentence
# that waits "until" or "after" a named version tells a reader nothing about
# what must be true, and it lets a ticket wait on a date that never comes. Name
# the condition instead.
#
# A hit is a version name (vN.N or vN.N.N, optional letter suffix) written
# straight after a timing word: until, till, after, before, following, by,
# once, "at the close of", "at the end of", "by the close of", "by the end of",
# the prefix "post-", or a version name followed by close / closes / closed /
# closing / ship / ships ("at the vN.N close"). A version used only as a name
# does not match.
#
# Exempt (a version name is a name there): the version field of a ticket (a
# line naming fixVersion / "fix version" / "version field"), a tag (a line
# naming `git tag` or refs/tags), release notes (CHANGELOG*, release-notes*,
# docs/release/v*-notes.md). A line that orders versions rather than waits on
# one (a sort-order case) ends with `version-timing-ok` and is skipped.
#
# Modes:
#   check-version-timing-words.sh <file> ...      scan those files whole
#   check-version-timing-words.sh --added <base>  scan only the lines added
#                                                  since <base> (git diff)
#   check-version-timing-words.sh                  scan every tracked file under
#                                                  docs/ and scripts/, the root
#                                                  *.md and llms.txt (the
#                                                  census: lists today's hits)
#
# Platform guard (posix-bash): POSIX bash 3.2+ plus git/grep/awk.
# Exit: 0 = no hit, 1 = at least one hit (each printed as path:line: text),
#       2 = usage error, a named file that does not exist, or a base that could
#       not be diffed (never a silent pass).
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel)

VER='v[0-9]+\.[0-9]+(\.[0-9]+)?[a-z]?'
TIMING='(until|till|after|before|following|by|once|at the (close|end) of|by the (close|end) of)'
FILLER='(the |this |next |that |our )?'
HIT_RE="(^|[^A-Za-z0-9_-])${TIMING}[[:space:]]+${FILLER}${VER}([^A-Za-z0-9]|\$)|(^|[^A-Za-z0-9_])post-${VER}([^A-Za-z0-9]|\$)|(^|[^A-Za-z0-9_])${VER}[[:space:]]+(close[sd]?|closing|ships?)([^A-Za-z0-9]|\$)"
EXEMPT_RE='fixVersion|fix version|version field|git tag|refs/tags|version-timing-ok[[:space:]]*$'

exempt_file() {
  case "$1" in
    CHANGELOG*|*/CHANGELOG*|docs/release/v*-notes.md|*release-notes*) return 0 ;;
  esac
  return 1
}

records_of_files() {
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    exempt_file "$f" && continue
    [ -f "$ROOT/$f" ] || continue
    grep -In '' "$ROOT/$f" 2>/dev/null | sed "s|^|$f:|" || true
  done
}

records_of_diff() {
  git -C "$ROOT" diff -U0 --no-color "$1" -- | awk '
    /^\+\+\+ b\// { path = substr($0, 7); next }
    /^\+\+\+ / { path = ""; next }
    /^@@ / { s = $0; sub(/^@@ -[0-9,]+ \+/, "", s); sub(/[ ,].*/, "", s); n = s + 0; next }
    /^\+/ { if (path != "") printf "%s:%d:%s\n", path, n, substr($0, 2); n++ }
  ' | while IFS= read -r rec; do
    exempt_file "${rec%%:*}" && continue
    printf '%s\n' "$rec"
  done
}

if [ "${1:-}" = "--added" ]; then
  [ "$#" -eq 2 ] || { echo "usage: $0 --added <base>" >&2; exit 2; }
  git -C "$ROOT" rev-parse --verify --quiet "$2^{commit}" >/dev/null || { echo "check-version-timing-words: no such base: $2" >&2; exit 2; }
  fork_point=$(git -C "$ROOT" merge-base "$2" HEAD) || { echo "check-version-timing-words: no common history with base: $2" >&2; exit 2; }
  records=$(records_of_diff "$fork_point") || { echo "check-version-timing-words: git diff against $2 failed" >&2; exit 2; }
elif [ "$#" -gt 0 ]; then
  for named in "$@"; do
    [ -f "$ROOT/$named" ] || { echo "check-version-timing-words: no such file under the repo root: $named" >&2; exit 2; }
  done
  records=$(printf '%s\n' "$@" | records_of_files)
else
  records=$(git -C "$ROOT" ls-files -- docs scripts ':(glob)*.md' llms.txt | records_of_files)
fi

hits=$(printf '%s\n' "$records" | grep -iE -- "$HIT_RE" | grep -ivE -- "$EXEMPT_RE" || true)

if [ -n "$hits" ]; then
  echo "check-version-timing-words: FAIL a version name is used as a timing word; name the condition that must be true instead:" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
echo "check-version-timing-words: OK — no version name used as a timing word"
