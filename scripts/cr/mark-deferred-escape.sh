#!/usr/bin/env bash
# mark-deferred-escape.sh — record that a fix's root cause was a deferred review residual.
#
#   mark-deferred-escape.sh <fix-key> <residual-key>
#
# WHY: the stability scorecard counts `deferred-escape` tickets per class, and /cr-tune
# calibrates on them; nothing applied the label. This relates the fix to the residual (the
# jira CLI has no caused-by link type), labels the fix `deferred-escape`, and copies the
# residual's class-<id> labels. A residual with no class label gets a warning and none copied:
# a class is never invented.
# Seam (tests): MARK_ESCAPE_JIRA_CMD replaces `node <primary>/scripts/jira/dist/index.js`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/git-clean.sh
. "$SCRIPT_DIR/../lib/git-clean.sh"
key_re='^[A-Z][A-Z0-9]*-[0-9]+$'

[ $# -eq 2 ] || { echo "Usage: mark-deferred-escape.sh <fix-key> <residual-key>" >&2; exit 64; }
fix="$1"; residual="$2"
[[ "$fix" =~ $key_re && "$residual" =~ $key_re ]] || { echo "ERR mark-deferred-escape: keys must look like <PROJECT>-<number>" >&2; exit 64; }
[ "$fix" != "$residual" ] || { echo "ERR mark-deferred-escape: the fix and the residual are the same ticket" >&2; exit 64; }

# The jira CLI finds its .env through git from its cwd, so run it from the primary checkout.
jira() {
    if [ -n "${MARK_ESCAPE_JIRA_CMD:-}" ]; then bash -c "$MARK_ESCAPE_JIRA_CMD \"\$@\"" _ "$@"; return; fi
    local common
    common="$(git_clean -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir)" || return 1
    (cd "$(dirname "$common")" && JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-HIMMEL}" node scripts/jira/dist/index.js "$@")
}

info="$(jira get "$residual")" || { echo "ERR mark-deferred-escape: cannot read $residual, nothing written" >&2; exit 1; }
classes="$(printf '%s\n' "$info" | sed -n 's/^Labels: //p' | tr ',' '\n' | tr -d ' ' | grep -E '^class-' | paste -sd, -)"
[ -n "$classes" ] || echo "WARN mark-deferred-escape: $residual has no class-<id> label, copying none" >&2

jira link "$fix" "$residual" --type Relates || { echo "ERR mark-deferred-escape: link $fix to $residual failed" >&2; exit 1; }
jira edit "$fix" --add-labels "deferred-escape${classes:+,$classes}" || { echo "ERR mark-deferred-escape: labelling $fix failed" >&2; exit 1; }
echo "mark-deferred-escape: $fix relates to $residual, labelled deferred-escape${classes:+ and $classes}"
