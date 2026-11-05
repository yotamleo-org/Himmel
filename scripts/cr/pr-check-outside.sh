#!/usr/bin/env bash
# pr-check-outside.sh <pr-number> - prints `outside-pr: yes|no`: the question /pr-check
# step 0 asks once the PR is open. It reads only guarded files (scripts/lib), so a "no"
# step-0 verdict still covers the bytes it runs. Exit 2 when the PR snapshot or
# the repository cannot be read; the caller treats that as yes.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 2
lib="$here/../lib"

PR="${1:-}"
case "$PR" in
    ''|0*|*[!0123456789]*)
        echo "usage: pr-check-outside.sh <pr-number>" >&2
        exit 2 ;;
esac
[ "$#" -eq 1 ] || { echo "usage: pr-check-outside.sh <pr-number>" >&2; exit 2; }

GH="${GH_CMD:-gh}"
# Every call below is a read: with no GH_CMD seam they ride the read-only token.
if [ -z "${GH_CMD:-}" ] && [ -f "$lib/gh-read.sh" ]; then
    # shellcheck source=../lib/gh-read.sh
    . "$lib/gh-read.sh"
    gh_read_init
    GH="$lib/gh-read.sh"
fi
command -v "$GH" >/dev/null 2>&1 || { echo "pr-check-outside: gh not found on PATH" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "pr-check-outside: jq not found on PATH" >&2; exit 2; }

nwo=$("$GH" repo view --json owner,name,defaultBranchRef --jq '"\(.owner.login)/\(.name) \(.defaultBranchRef.name // "")"' 2>/dev/null)  # swallow-ok: an empty result is reported just below (exit 2)
nwo="${nwo%% *}"
if [ -z "$nwo" ]; then
    echo "pr-check-outside: cannot resolve owner/repo (gh repo view failed)" >&2
    exit 2
fi
snapshot=$(GH_CMD="$GH" bash "$lib/gh-pr-snapshot.sh" "$nwo" 0 "$PR" 2>/dev/null) || snapshot=""  # swallow-ok: an empty snapshot makes outside_pr_of fail, reported below (exit 2)

# shellcheck source=../lib/outside-contributors.sh
. "$lib/outside-contributors.sh" || { echo "pr-check-outside: cannot load scripts/lib/outside-contributors.sh" >&2; exit 2; }
if ! op=$(outside_pr_of "$snapshot"); then
    echo "pr-check-outside: cannot read PR #$PR's author or fork flag (PR snapshot unreadable)" >&2
    exit 2
fi
echo "outside-pr: $op"
