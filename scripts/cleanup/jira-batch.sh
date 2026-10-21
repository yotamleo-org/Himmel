#!/usr/bin/env bash
# jira-batch.sh — Jira project hygiene in batches of at most 20 tickets.
#
# Usage: jira-batch.sh plan <stale|version|status>   list the next batch (read-only)
#        jira-batch.sh apply <file>                  label each listed ticket
#
# Kinds and the label each one adds:
#   stale    To Do and created over 90 days ago (no epics)         -> stale
#   version  open in a released version, or Done in a future one  -> version-drift
#   status   In Progress, no status change in 14 days (no epics)   -> status-drift
# Status history and creation date, not `updated`: bulk field edits touch
# nearly every open ticket each week, so `updated` never ages.
# plan prints "<KEY><TAB><label>" for the first 20 unlabelled candidates, then
# "# candidates=<n> batch=<k> next-run=<m>" (a "+" after both counts when the
# 500-row list limit was hit). apply refuses a file with more
# than 20 rows, or a label outside the three above, before writing anything;
# then it adds each label with `jira edit --add-labels` (reversible with
# --remove-labels) and ends with "jira-batch: labeled=<n> failed=<n>".
# Titles are never edited. JIRA_PROJECT_KEY is required.
set -uo pipefail

# ponytail: the cap lives in this runner, HIMMEL-6778 (bulk-edit guard in the jira CLI) replaces it.
CAP=20
LIST_LIMIT=500

usage() { sed -n '4,5p' "$0" | sed 's/^# //'; }

anchor="$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir)" || exit 1
JIRA=(node "${anchor%/.git}/scripts/jira/dist/index.js")

case "${1:-}" in
  plan)
    : "${JIRA_PROJECT_KEY:?JIRA_PROJECT_KEY is required}"
    p="project = $JIRA_PROJECT_KEY"
    case "${2:-}" in
      stale) label=stale; jql="$p AND issuetype != Epic AND statusCategory = \"To Do\" AND created <= -90d" ;;
      version) label=version-drift
        jql="$p AND ((statusCategory != Done AND fixVersion in releasedVersions()) OR (statusCategory = Done AND fixVersion in unreleasedVersions() AND fixVersion not in (earliestUnreleasedVersion($JIRA_PROJECT_KEY))))" ;;
      status) label=status-drift; jql="$p AND issuetype != Epic AND status = \"In Progress\" AND NOT status CHANGED AFTER -14d" ;;
      *) usage >&2; exit 2 ;;
    esac
    jql="$jql AND (labels is EMPTY OR labels not in (\"$label\")) ORDER BY created ASC"
    listed="$("${JIRA[@]}" list --jql "$jql" --limit "$LIST_LIMIT")" || exit 1
    keys="$(printf '%s\n' "$listed" | cut -f1 | grep -E '^[A-Z][A-Z0-9]*-[0-9]+$' || true)"
    n="$(printf '%s\n' "$keys" | grep -c . || true)"
    k=$(( n < CAP ? n : CAP ))
    more=""
    [ "$n" -lt "$LIST_LIMIT" ] || more="+"
    printf '%s\n' "$keys" | grep . | head -n "$CAP" | sed "s/\$/$(printf '\t')$label/" || true
    echo "# candidates=$n$more batch=$k next-run=$(( n - k ))$more"
    ;;
  apply)
    list="${2:?apply needs the file plan wrote}"
    [ -r "$list" ] || { echo "jira-batch: cannot read $list; nothing written" >&2; exit 2; }
    rows="$(grep -v -e '^#' -e '^[[:space:]]*$' "$list")"
    [ $? -le 1 ] || { echo "jira-batch: cannot read $list; nothing written" >&2; exit 2; }
    n="$(printf '%s\n' "$rows" | grep -c . || true)"
    if [ "$n" -gt "$CAP" ]; then
      echo "jira-batch: REFUSED — $n tickets over the cap of $CAP; nothing written" >&2
      exit 1
    fi
    bad="$(printf '%s\n' "$rows" | grep . | awk -F'\t' '$1 !~ /^[A-Z][A-Z0-9]*-[0-9]+$/ || $2 !~ /^(stale|version-drift|status-drift)$/ || NF != 2' || true)"
    if [ -n "$bad" ]; then
      echo "jira-batch: REFUSED — rows outside <KEY><TAB>stale|version-drift|status-drift; nothing written:" >&2
      printf '%s\n' "$bad" >&2
      exit 1
    fi
    labeled=0
    failed=0
    while IFS="$(printf '\t')" read -r key label; do
      [ -n "$key" ] || continue
      if "${JIRA[@]}" edit "$key" --add-labels "$label" >/dev/null; then
        echo "LABELED $key $label"; labeled=$((labeled + 1))
      else
        echo "FAILED $key $label"; failed=$((failed + 1))
      fi
    done <<< "$rows"
    echo "jira-batch: labeled=$labeled failed=$failed"
    [ "$failed" -eq 0 ]
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
