#!/usr/bin/env bash
# escape-classes.sh — tally deferred-escape tickets by class-<id> label for /cr-tune.
#
#   escape-classes.sh
#
# WHY: a fix whose root cause was a deferred review residual is labelled `deferred-escape` (plus the
# residual's class-<id>) by scripts/cr/mark-deferred-escape.sh; /cr-tune calibrates on the class that
# escapes most. A ticket with no class-<id> label is reported as unclassified, never given a class;
# a ticket with several class labels counts toward each.
# Seam (tests): ESCAPE_CLASSES_JIRA_CMD replaces `node <primary>/scripts/jira/dist/index.js`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/git-clean.sh
. "$SCRIPT_DIR/../lib/git-clean.sh"

# The jira CLI finds its .env through git from its cwd, so run it from the primary checkout.
jira() {
    if [ -n "${ESCAPE_CLASSES_JIRA_CMD:-}" ]; then bash -c "$ESCAPE_CLASSES_JIRA_CMD \"\$@\"" _ "$@"; return; fi
    local common
    common="$(git_clean -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir)" || return 1
    (cd "$(dirname "$common")" && JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-HIMMEL}" node scripts/jira/dist/index.js "$@")
}

rows="$(jira list --jql 'project = HIMMEL AND labels = deferred-escape' --labels --limit 500)" \
    || { echo "ERR escape-classes: cannot list deferred-escape tickets" >&2; exit 1; }
[ -n "$rows" ] || { echo "escape classes: no deferred-escape tickets"; exit 0; }

# Rows are key, type, status, summary, labels (tab separated).
printf '%s\n' "$rows" | awk -F'\t' '
NF {
    total++
    n = split($5, l, ","); c = 0
    for (i = 1; i <= n; i++) {
        gsub(/ /, "", l[i])
        if (l[i] ~ /^class-/) { cnt[l[i]]++; keys[l[i]] = keys[l[i]] (keys[l[i]] ? ", " : "") $1; c = 1 }
    }
    if (!c) un = un (un ? ", " : "") $1
    if (!c) nun++
}
END {
    printf "escape classes: %d deferred-escape tickets\n", total
    fflush()
    m = 0
    for (k in cnt) if (cnt[k] > m) m = cnt[k]
    top = ""; ties = ""
    for (k in cnt) if (cnt[k] == m) { if (top == "" || k < top) top = k }
    for (k in cnt) if (cnt[k] == m && k != top) ties = ties (ties ? ", " : "") k
    for (k in cnt) printf "%s %d\n", k, cnt[k] | "sort -k2,2nr -k1,1"
    close("sort -k2,2nr -k1,1")
    if (top == "") print "top escape class: none (no ticket carries a class-<id> label)"
    else printf "top escape class: %s (%d: %s)%s\n", top, m, keys[top], (ties ? " tied with " ties : "")
    if (nun) printf "unclassified: %d (%s) - no class-<id> label, no class assigned\n", nun, un
}'
