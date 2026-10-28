#!/usr/bin/env bash
# scripts/eval/lane-quality/prune-history.sh - build the pruned arm of the
# comment-prune A/B.
#
# prune-history.sh <repo> <base-sha> [--files N]
#
# Cuts a detached worktree at <base-sha>, deletes the whole-line history
# comments (the same patterns as scripts/lint/check-history-comments.sh: a Jira
# key, a fix note, a review round, a judge qid; a `ponytail:` line keeps its key)
# from the N code files that carry the most of them, commits the result with a
# fixed author and date, and prints the new commit sha on stdout. The count of
# removed lines goes to stderr. Run the same task set at <base-sha> and at the
# printed sha, then compare with `run.sh pair`.
#
# ponytail: line match, also drops a matching line inside a heredoc or multi-line string and adds a final newline, per-language tokeniser in HIMMEL-5629.
# Sample, never the whole repo: N defaults to 40. Fixtures, vendored trees and
# generated output are skipped, as the gate skips them.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

die() { echo "prune-history: $*" >&2; exit 64; }
[ $# -ge 2 ] || die "usage: prune-history.sh <repo> <base-sha> [--files N]"
REPO="$1"; BASE="$2"; shift 2
N=40
while [ $# -gt 0 ]; do
  case "$1" in
    --files) [ $# -ge 2 ] || die "--files needs a value"; N="$2"; shift 2 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
case "$N" in ''|*[!0-9]*) die "--files must be a whole number" ;; esac
[ "$N" -gt 0 ] || die "--files must be positive"
git -C "$REPO" cat-file -e "$BASE^{commit}" 2>/dev/null || die "base sha $BASE not in $REPO"

# shellcheck source=../../lib/prim.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/prim.sh" || die "cannot load scripts/lib/prim.sh"
WT="$(tmpdir)" || die "mktemp failed"
trap 'git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$WT"' EXIT
git -C "$REPO" worktree add -q --detach "$WT" "$BASE" || die "worktree add failed"

# One awk program picks the lines to drop; it is the gate's why() and in_scope().
AWK_DROP='
function in_scope(p) {
  if (p !~ /\.(sh|bash|zsh|ps1|psm1|py|js|mjs|cjs|ts|tsx|mts|cts)$/) return 0
  if (p ~ /(^|\/)[^\/]*fixtures?\// || p ~ /(^|\/)node_modules\//) return 0
  if (p ~ /^(graphify-out|templates|marketplace\/plugins\/claude-hud|marketplace\/plugins\/lean-skills\/skills)\//) return 0
  return 1
}
function history(s,   l) {
  if (!((s ~ /^#/ && s !~ /^#!/) || s ~ /^\/\//)) return 0
  l = tolower(s)
  if (s ~ /HIMMEL-[0-9]+/ && s !~ /^(#|\/\/)[ \t]*ponytail:/) return 1
  if (l ~ /(^|[^a-z0-9])cr fix/ || l ~ /coderabbit round/ || l ~ /(^|[^a-z0-9])round [0-9]+/) return 1
  if (l ~ /(^|[^a-z0-9])j[0-9][0-9][0-9][0-9][a-z]([^a-z0-9]|$)/) return 1
  return 0
}'

LIST="$WT.list"
: >"$LIST"
while IFS= read -r f; do
  [ -L "$WT/$f" ] && continue
  awk -v p="$f" "$AWK_DROP"'
    BEGIN { if (!in_scope(p)) exit; c = 0 }
    { s = $0; sub(/^[ \t]+/, "", s); if (history(s)) c++ }
    END { if (c > 0) printf "%d\t%s\n", c, p }' "$WT/$f" >>"$LIST"
done < <(git -C "$WT" ls-files -- scripts)
[ -s "$LIST" ] || die "no history comments found under scripts/ at $BASE"

TMP="$(mktemp "${TMPDIR:-/tmp}/prune-history.tmp.XXXXXX")" || die "mktemp failed"
while IFS="$(printf '\t')" read -r _ f; do
  awk "$AWK_DROP"'{ s = $0; sub(/^[ \t]+/, "", s); if (!history(s)) print }' "$WT/$f" >"$TMP" || die "could not prune $f"
  cat "$TMP" >"$WT/$f" || die "could not write $f"
done < <(sort -rn "$LIST" | head -n "$N")
rm -f "$TMP"
REMOVED="$(git -C "$WT" diff --numstat | awk '{ d += $2 } END { print d + 0 }')"
rm -f "$LIST"

git -C "$WT" add -A || die "cannot stage the pruned files"
GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
  git -C "$WT" -c user.name=lane-quality -c user.email=lane-quality@invalid -c commit.gpgsign=false \
  commit -q --no-verify -m "lane-quality: history comments pruned from $N files" || die "cannot commit the pruned tree"
echo "prune-history: removed $REMOVED history-comment lines from up to $N files" >&2
SHA="$(git -C "$WT" rev-parse HEAD)"
git -C "$REPO" update-ref "refs/lq-pruned/$SHA" "$SHA" || die "cannot keep the pruned commit"
echo "$SHA"
