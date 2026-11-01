#!/usr/bin/env bash
# dedupe-plugin-installs.sh — list (default) or remove (--apply) every
# local- and project-scope install of one plugin, leaving the user-scope entry.
#
#   dedupe-plugin-installs.sh [--plugin <id@marketplace>] [--apply]
#
# Default plugin: atlassian@claude-plugins-official (Jira is CLI-first, so the MCP
# plugin should not load). Dry-run unless --apply. Each removal is
# `claude plugin uninstall <id> --scope <scope> --keep-data` run from the install's projectPath,
# because a local/project uninstall acts on the project of the cwd. An entry whose
# projectPath no longer exists cannot be removed that way (claude answers "installed
# in user scope, not project"), so it is reported STALE and skipped: this script never
# creates a directory. Remove such an entry from ~/.claude/plugins/installed_plugins.json
# by hand, after a backup. A stale entry alone does not fail the run (exit 0).
#
# Test seam: HIMMEL_CLAUDE_BIN (the claude executable). Needs jq.
# Live ~/.claude is touched only by --apply, so run that one from the operator's shell.

set -uo pipefail

PLUGIN='atlassian@claude-plugins-official'
APPLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --plugin) [ $# -ge 2 ] || { echo "dedupe-plugin-installs: --plugin needs an id" >&2; exit 2; }; PLUGIN="$2"; shift ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "dedupe-plugin-installs: unknown argument '$1'" >&2; exit 2 ;;
    esac
    shift
done

command -v jq >/dev/null 2>&1 || { echo "dedupe-plugin-installs: jq is required" >&2; exit 2; }
BIN="${HIMMEL_CLAUDE_BIN:-claude}"
command -v "$BIN" >/dev/null 2>&1 || [ -x "$BIN" ] || { echo "dedupe-plugin-installs: claude not found ('$BIN')" >&2; exit 2; }

list_json="$("$BIN" plugin list --json)" || { echo "dedupe-plugin-installs: 'claude plugin list --json' failed" >&2; exit 1; }
rows="$(printf '%s' "$list_json" | jq -r --arg id "$PLUGIN" '
    if type != "array" then error("not an array") else . end
    | .[] | select(.id == $id and (.scope == "local" or .scope == "project"))
    | [.scope, (.projectPath // "")] | @tsv')" || { echo "dedupe-plugin-installs: plugin list was not a JSON array" >&2; exit 1; }
total="$(printf '%s' "$list_json" | jq --arg id "$PLUGIN" '[.[] | select(.id == $id)] | length')"

n=0
removed=0
failed=0
stale=0
while IFS=$'\t' read -r scope ppath; do
    [ -n "$scope" ] || continue
    n=$((n + 1))
    if [ "$APPLY" -eq 0 ]; then
        if [ -n "$ppath" ] && [ ! -d "$ppath" ]; then
            printf 'would skip (stale)  %-7s %s\n' "$scope" "$ppath"; stale=$((stale + 1))
        else
            printf 'would remove  %-7s %s\n' "$scope" "${ppath:-(no projectPath)}"
        fi
        continue
    fi
    if [ -z "$ppath" ]; then
        printf 'SKIP  %-7s no projectPath on the entry\n' "$scope"; failed=$((failed + 1)); continue
    fi
    if [ ! -d "$ppath" ]; then
        printf 'STALE  %-7s %s  (projectPath no longer exists; claude cannot remove it from there - delete this entry from ~/.claude/plugins/installed_plugins.json by hand, after a backup)\n' "$scope" "$ppath"
        stale=$((stale + 1)); continue
    fi
    if ( cd "$ppath" && "$BIN" plugin uninstall "$PLUGIN" --scope "$scope" --keep-data ) >/dev/null 2>&1; then
        printf 'removed  %-7s %s\n' "$scope" "$ppath"; removed=$((removed + 1))
    else
        printf 'FAIL  %-7s %s\n' "$scope" "$ppath"; failed=$((failed + 1))
    fi
done <<< "$rows"

if [ "$APPLY" -eq 0 ]; then
    echo "dry-run: $n local/project install(s) of $PLUGIN of $total total; re-run with --apply to remove them (the user-scope entry stays)"
    [ "$stale" -eq 0 ] || echo "  $stale of them have a projectPath that no longer exists: --apply skips those and reports them STALE"
else
    echo "applied: removed $removed, failed $failed, stale $stale of $n local/project install(s) of $PLUGIN"
    [ "$failed" -eq 0 ] || exit 1
fi
