#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=../../lib/git-clean.sh
. "$(dirname "$0")/../../lib/git-clean.sh"
git_env_scrub

KINDS='wake|relay|go|unowned'
kind=""
labels=""
have_labels=0
args=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --kind) kind="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        --kind=*) kind="${1#--kind=}"; shift ;;
        --labels) have_labels=1; labels="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
        --labels=*) have_labels=1; labels="${1#--labels=}"; shift ;;
        *) args+=("$1"); shift ;;
    esac
done

case "$kind" in
    wake | relay | go | unowned) ;;
    *) echo "usage: file-chief-miss.sh --kind <$KINDS> <jira create args>; --kind is required (got '${kind:-none}'); nothing was filed" >&2; exit 2 ;;
esac

if [ "$have_labels" = 1 ] && [ -n "$labels" ]; then labels="$labels,chief-miss"; else labels="chief-miss"; fi

if [ -n "${FILE_CHIEF_MISS_JIRA_CLI:-}" ]; then
    JIRA=("$FILE_CHIEF_MISS_JIRA_CLI")
else
    common="$(git rev-parse --path-format=absolute --git-common-dir)" || { echo "file-chief-miss: not in a git checkout" >&2; exit 1; }
    JIRA=(env "JIRA_PROJECT_KEY=${JIRA_PROJECT_KEY:-HIMMEL}" node "$(dirname "$common")/scripts/jira/dist/index.js")
fi

out="$("${JIRA[@]}" create "${args[@]}" --labels "$labels" 2>&1)"
rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || exit "$rc"

key="$(printf '%s\n' "$out" | sed -n 's/^Created \([A-Z][A-Z0-9]*-[0-9][0-9]*\).*/\1/p' | head -n 1)"
if [ -z "$key" ]; then
    echo "file-chief-miss: the ticket was filed with chief-miss but no key was printed, so the kind '$kind' was not recorded; add it with jira comment" >&2
    exit 0
fi
"${JIRA[@]}" comment "$key" "chief-miss kind: $kind" >/dev/null || echo "file-chief-miss: $key carries chief-miss but the kind comment failed; add 'chief-miss kind: $kind' with jira comment" >&2
exit 0
