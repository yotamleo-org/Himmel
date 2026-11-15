#!/usr/bin/env bash
# note-polish.sh — the reader-visible record of polish findings noted with no
# ticket (decisions 746, 762): ONE `polish-noted:` Jira comment on the PR's own
# ticket. review-round.sh defer and file-deferred-issues.sh call it on a
# Jira-tracked repo before anything else in their run is commented, filed or
# amended.
#
#   note-polish.sh --branch <name> --head <sha> --list-file <path>
#
# list-file: one JSON object per line {id, file, line, severity, class_source, text}.
# A batch line's id is batch-<n>-<hash> (file-deferred-issues.sh): line 1 then
# carries crbatch<hash>, and a ticket whose comments already hold it is skipped.
#
# The PR ticket, from --branch only (there is no ticket argument):
#   1. exactly one open PR for the branch: the first [KEY-n] of its title
#      (ticket_key_from_title, scripts/lib/ticket-status.sh);
#   2. no open PR: the one <JIRA_PROJECT_KEY>-<n> key in the branch name,
#      case-insensitive;
#   3. anything else: exit 6, ambiguous or missing PR ticket, nothing posted.
#
# Jira CLI: $JIRA_CMD (word-split) if set, else this checkout's primary
# scripts/jira/dist/index.js. gh: $GH_CMD if set, else gh_read (read token).
#
# Exit: 0 posted or already noted | 2 usage | 6 ambiguous or missing ticket, or
# any CLI failure (the comments read included).
# Bash 3.2-safe.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The checkout lookup for the Jira CLI answers about this script's own repo,
# never one a caller's repository-redirecting GIT_* variables point at.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE \
    GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT

usage() {
    echo "usage: note-polish.sh --branch <name> --head <sha> --list-file <path>" >&2
    exit 2
}
die() {
    echo "note-polish: $1; nothing posted" >&2
    exit 6
}

branch="" head_sha="" list_file=""
while [ $# -gt 0 ]; do
    case "$1" in
        --branch) [ $# -ge 2 ] || usage; branch="$2"; shift 2 ;;
        --head) [ $# -ge 2 ] || usage; head_sha="$2"; shift 2 ;;
        --list-file) [ $# -ge 2 ] || usage; list_file="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$branch" ] && [ -n "$head_sha" ] && [ -n "$list_file" ] || usage
[ -s "$list_file" ] && [ -r "$list_file" ] || usage

# shellcheck source=scripts/lib/ticket-status.sh
# shellcheck disable=SC1091
. "$HERE/../lib/ticket-status.sh" || die "could not load scripts/lib/ticket-status.sh"

jira_run() {
    local common primary
    if [ -n "${JIRA_CMD:-}" ]; then
        # shellcheck disable=SC2086  # JIRA_CMD is a command line, e.g. "node <path>"
        $JIRA_CMD "$@"
        return $?
    fi
    # swallow-ok: a copy outside any git checkout falls back to its own checkout root below
    if common="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && [ -n "$common" ]; then
        primary="$(dirname "$common")"
    else
        primary="$(cd "$HERE/../.." && pwd)"
    fi
    node "$primary/scripts/jira/dist/index.js" "$@"
}

if [ -n "${GH_CMD:-}" ]; then
    titles="$("$GH_CMD" pr list --head "$branch" --state open --json title -q '.[].title')" \
        || die "could not list the open PRs for $branch"
else
    titles="$(gh_read pr list --head "$branch" --state open --json title -q '.[].title')" \
        || die "could not list the open PRs for $branch"
fi
open_prs="$(printf '%s\n' "$titles" | awk 'NF { n++ } END { print n + 0 }')"
key=""
if [ "$open_prs" = 1 ]; then
    key="$(ticket_key_from_title "$titles")" || key=""
elif [ "$open_prs" = 0 ] && [ -n "${JIRA_PROJECT_KEY:-}" ]; then
    branch_keys="$(printf '%s\n' "$branch" | grep -oiE "${JIRA_PROJECT_KEY}-[0-9]+" | tr '[:lower:]' '[:upper:]' | sort -u)" || branch_keys=""
    [ "$(printf '%s\n' "$branch_keys" | grep -c .)" = 1 ] && key="$branch_keys"
fi
[ -n "$key" ] || die "ambiguous or missing PR ticket for $branch (put the ticket key in the PR title as [KEY-n], or in the branch name)"

body="$(mktemp -t note-polish.XXXXXX)" || die "could not create the comment file"
trap 'rm -f "$body"' EXIT
batch_hash="$(LIST="$list_file" node -e '
const fs = require("fs");
const first = JSON.parse(fs.readFileSync(process.env.LIST, "utf8").split("\n").filter(Boolean)[0]);
const m = /^batch-[0-9]+-([0-9A-Za-z]+)$/.exec(String(first.id || ""));
process.stdout.write(m ? m[1] : "");
' 2>/dev/null)" || usage
line1="polish-noted: $branch $head_sha"
[ -z "$batch_hash" ] || line1="$line1 crbatch$batch_hash"
if ! { printf '%s\n' "$line1" && LIST="$list_file" node -e '
const fs = require("fs");
for (const l of fs.readFileSync(process.env.LIST, "utf8").split("\n").filter(Boolean)) {
  const f = JSON.parse(l);
  const where = String(f.file || "?") + (f.line !== undefined && f.line !== null && String(f.line) !== "" ? ":" + f.line : "");
  const text = String(f.text || "").replace(/\s+/g, " ").trim().slice(0, 300);
  process.stdout.write("- " + f.id + " " + where + " [" + f.severity + ", class " + f.class_source + "]: " + text + "\n");
}
'; } > "$body"; then
    usage
fi

if [ -n "$batch_hash" ]; then
    existing="$(JIRA_PROJECT_KEY="${key%%-*}" jira_run comments "$key")" || die "could not read the comments of $key"
    case "$existing" in
        *"crbatch$batch_hash"*)
            echo "note-polish: already noted on $key (crbatch$batch_hash)"
            exit 0
            ;;
    esac
fi
JIRA_PROJECT_KEY="${key%%-*}" jira_run comment "$key" --comment-file "$body" >/dev/null || die "could not post the polish-noted comment on $key"
echo "note-polish: polish-noted comment posted on $key"
