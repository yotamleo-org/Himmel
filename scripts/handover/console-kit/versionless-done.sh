#!/usr/bin/env bash
# versionless-done.sh — Done tickets that carry no fixVersion.
# A ticket closed with no version counts in no version, so the tracker and Jira
# drift. merge-on-green stamps the version on a merge close; this catches the
# tickets closed outside it (product sessions, research, Done-truth closes).
#
#   versionless-done.sh            print <n>, the count, or `unknown` when Jira
#                                  or the version list cannot be read
#   versionless-done.sh --list     print the matching tickets, one TSV row each
#   versionless-done.sh --backfill print `would-set <KEY> <version>` per ticket
#                                  and write nothing
#   versionless-done.sh --backfill --apply
#                                  add the current version to each ticket
#
# Match: project Done, no fixVersion, not an Epic, resolved on/after the last
# release date (every Done ticket when nothing is released yet). The current
# version is the earliest unreleased one by release date, like jira create's
# Bug default. The backfill never runs from tick.sh; the console runs it
# after reading the list.
# Env: JIRA_PROJECT_KEY (default HIMMEL), HIMMEL_JIRA_CLI (a command line,
# default: the primary checkout's dist/index.js).
# ponytail: a Done ticket moved out through `jira move` is not excluded, so a
# moved source in the project would count; exclude moves once one shows up.
# bash 3.2-safe; no .ps1 twin (the console kit is Linux-only).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh"
git_env_scrub

mode=count apply=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --list) mode=list ;;
        --backfill) mode=backfill ;;
        --apply) apply=1 ;;
        *) echo "usage: versionless-done.sh [--list | --backfill [--apply]]" >&2; exit 2 ;;
    esac
    shift
done
if [ "$apply" -eq 1 ] && [ "$mode" != backfill ]; then
    echo "versionless-done: --apply needs --backfill" >&2; exit 2
fi

project="${JIRA_PROJECT_KEY:-HIMMEL}"
if [ -n "${HIMMEL_JIRA_CLI:-}" ]; then
    read -r -a jira <<<"$HIMMEL_JIRA_CLI"
else
    anchor="$(cd "$HERE" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"  # swallow-ok: an unresolved anchor fails the jira call below, which reads unknown
    jira=(node "${anchor%/.git}/scripts/jira/dist/index.js")
fi

unknown() { echo unknown; exit 1; }

versions="$(JIRA_PROJECT_KEY="$project" "${jira[@]}" versions --project "$project" 2>/dev/null)" || unknown  # swallow-ok: a failed read prints unknown, not a count
# versions rows: name, released (true|false), releaseDate.
last_release="$(printf '%s\n' "$versions" | awk -F'\t' '$2 == "true" && $3 != "" && $3 > m { m = $3 } END { print m }')"
current="$(printf '%s\n' "$versions" | awk -F'\t' '
    $2 == "false" && $1 != "" {
        if ($3 != "" && (best == "" || bestdate == "" || $3 < bestdate)) { best = $1; bestdate = $3 }
        else if (first == "") first = $1
    }
    END { print (best != "" ? best : first) }')"

limit="${VERSIONLESS_DONE_LIMIT:-500}"
jql="project = $project AND status = Done AND fixVersion is EMPTY AND issuetype != Epic"
[ -z "$last_release" ] || jql="$jql AND resolved >= \"$last_release\""

rows="$(JIRA_PROJECT_KEY="$project" "${jira[@]}" list --jql "$jql" --limit "$limit" 2>/dev/null)" || unknown  # swallow-ok: a failed read prints unknown, not a count
rows="$(printf '%s\n' "$rows" | grep -E '^[A-Z][A-Z0-9]*-[0-9]+')" || rows=""
# A full page means the search may have stopped short: say so, never undercount quietly.
# Judged before the exceptions are dropped, since they take rows from the page too.
truncated=0
[ -z "$rows" ] || [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" -lt "$limit" ] || truncated=1

# Tickets closed with no PR on purpose (a Done-truth audit close, a product-session close).
exceptions="${VERSIONLESS_DONE_EXCEPTIONS-HIMMEL-3011 HIMMEL-1528}"
for ex in $exceptions; do
    rows="$(printf '%s\n' "$rows" | grep -v -E "^$ex([[:space:]]|\$)")" || rows=""
done

n=0
[ -z "$rows" ] || n="$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"

case "$mode" in
    count)
        if [ "$truncated" -eq 1 ]; then echo "$n+"; else echo "$n"; fi ;;
    list)
        [ -z "$rows" ] || printf '%s\n' "$rows"
        [ "$truncated" -eq 0 ] || echo "versionless-done: list stopped at the $limit-row limit" >&2 ;;
    backfill)
        if [ -z "$current" ]; then echo "versionless-done: no unreleased version to set" >&2; exit 1; fi
        rc=0
        while IFS=$'\t' read -r key _; do
            [ -n "$key" ] || continue
            if [ "$apply" -eq 1 ]; then
                if JIRA_PROJECT_KEY="$project" "${jira[@]}" edit "$key" --add-fix-version "$current" >/dev/null 2>&1; then
                    echo "set $key $current"
                else
                    echo "FAILED $key $current"; rc=1
                fi
            else
                echo "would-set $key $current"
            fi
        done <<<"$rows"
        [ "$truncated" -eq 0 ] || { echo "versionless-done: backfill stopped at the $limit-row limit; run it again" >&2; rc=1; }
        exit "$rc" ;;
esac
