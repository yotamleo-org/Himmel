#!/usr/bin/env bash
# empty-sector-check.sh: list the open tickets whose Sector is empty. READ-ONLY.
#
# USAGE  JIRA_PROJECT_KEY=HIMMEL empty-sector-check.sh [--limit N]
#
# Output: `<KEY>\t<type>\t<status>\t<summary>` rows, then one `# empty-sector open=<n>` line
# (`open>=<n>` when --limit was reached, since more may exist).
# Exit 0 when none is empty, 1 when at least one is, 2 on a usage or CLI error. Backfill the rows
# with `jira edit-batch --file <key<TAB>sector lines>`.
# Open means statusCategory is not Done. The CLI is $JIRA_CLI (default: dist/index.js beside this
# script); it needs jira.sectorField configured, else Jira rejects the Sector clause.
set -u

limit=500
while [ $# -gt 0 ]; do
    case "$1" in
        --limit) [ $# -ge 2 ] || { echo "usage: empty-sector-check.sh [--limit N]" >&2; exit 2; }; limit="$2"; shift 2 ;;
        *) echo "usage: empty-sector-check.sh [--limit N]" >&2; exit 2 ;;
    esac
done
case "$limit" in ''|*[!0-9]*) echo "empty-sector-check: --limit must be a positive integer" >&2; exit 2 ;; esac
[ "$limit" -ge 1 ] || { echo "empty-sector-check: --limit must be a positive integer" >&2; exit 2; }
project="${JIRA_PROJECT_KEY:-}"
[ -n "$project" ] || { echo "empty-sector-check: JIRA_PROJECT_KEY is required" >&2; exit 2; }
cli="${JIRA_CLI:-$(cd "$(dirname "$0")" && pwd)/dist/index.js}"
[ -f "$cli" ] || { echo "empty-sector-check: no jira CLI at $cli (run npm run build, or set JIRA_CLI)" >&2; exit 2; }

rows=$(node "$cli" list --jql "project = $project AND statusCategory != Done AND Sector is EMPTY ORDER BY key" --limit "$limit") \
    || { echo "empty-sector-check: jira list failed" >&2; exit 2; }
n=0
if [ -n "$rows" ]; then
    printf '%s\n' "$rows"
    n=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
fi
if [ "$n" -ge "$limit" ]; then
    echo "# empty-sector open>=$n (--limit $limit reached, there may be more: raise --limit)"
else
    echo "# empty-sector open=$n"
fi
[ "$n" -eq 0 ]
