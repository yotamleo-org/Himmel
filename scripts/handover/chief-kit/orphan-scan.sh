#!/usr/bin/env bash
# scripts/handover/chief-kit/orphan-scan.sh - the live sessions and open pull requests
# a chief's fleet list does not hold.
#
#   orphan-scan.sh --fleet <manifest> [--self <session name>]... [--prefix <p>] [--repo <path>]
#
# Prints one line per finding on stdout, nothing else:
#   # orphan session <name> <reason>        a live claude session named <prefix>... (default HIMMEL-)
#                                           that no fleet doc's session names cover
#   # orphan pr <n> <reason>                an open PR whose head branch names no ticket of a listed
#                                           worker and that no `watch` row of the manifest names
#   # orphan finished <name> pr=<n> merged=<sha>
#                                           a live listed worker whose doc names a merged PR (the newest
#                                           `READY <n>` / `PR <n>` bullet) and whose tail is not WRAPPED;
#                                           close-wrapped-worker.sh --finished closes it
# A session counts as listed when its name, or its name without a trailing -r<N>, is one of
# worker_identity's names for a listed doc (each also with -RESUME). A worker relaunched under a
# shortened name the bus chose is found only by the close script's session-id proof, so it reads
# here as an unlisted session. --self names the chief's own session (repeatable, comma lists ok).
# Fork PRs and Dependabot's are left out: the Dependabot sweep owns those.
# Reads only: this script writes nothing and signals nothing.
#
# Seams: ORPHAN_SCAN_GH (the gh binary), CLAUDE_SESSIONS_PROC (the /proc root).
# Exit: 0 scan complete; 2 usage; 3 incomplete (the session census, the PR list or a PR read failed;
# `# orphan-scan: unavailable (...)` goes to stderr and every line that could be read still prints).
# PLATFORM GUARD: Linux bash 3.2+, needs jq and /proc.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/legacy-names.sh
. "$HERE/../../lib/legacy-names.sh"
# shellcheck source=../../lib/worker-identity.sh
. "$HERE/../../lib/worker-identity.sh"
# shellcheck source=../../lib/worker-tail-status.sh
. "$HERE/../../lib/worker-tail-status.sh"
# shellcheck source=../../lanes/lib/claude-sessions.sh
. "$HERE/../../lanes/lib/claude-sessions.sh"
if legacy_names_on; then JQ_W='def W: (.workers // .legs);'; else JQ_W='def W: .workers;'; fi
GH="${ORPHAN_SCAN_GH:-gh}"

usage() { echo "usage: orphan-scan.sh --fleet <manifest> [--self <session name>]... [--prefix <p>] [--repo <path>]" >&2; exit 2; }
fleet=""; prefix="HIMMEL-"; repo="$(cd "$HERE/../../.." && pwd)"; selves=","
while [ "$#" -gt 0 ]; do
    case "$1" in
        --fleet) [ "$#" -ge 2 ] || usage; fleet="$2"; shift 2 ;;
        --prefix) [ "$#" -ge 2 ] || usage; prefix="$2"; shift 2 ;;
        --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
        --self) [ "$#" -ge 2 ] || usage; selves="$selves$2,"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$fleet" ] && [ -r "$fleet" ] || usage
docs=$(jq -r "$JQ_W"'W[]?.doc // empty' "$fleet") || usage
watched=$(jq -r '(.watch // [])[]?.pr // empty' "$fleet") || usage

incomplete=0
unavailable() { echo "# orphan-scan: unavailable ($1)" >&2; incomplete=1; }

listed_names=","; listed_tickets=","
while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    ident=$(worker_identity "$doc")
    for n in $(printf '%s' "${ident#*$'\t'}" | tr ',' ' '); do listed_names="$listed_names$n,$n-RESUME,"; done
    key=$(printf '%s' "${doc##*/}" | grep -oE '^[A-Za-z]+-[0-9]+' | tr '[:lower:]' '[:upper:]') || key=""
    [ -z "$key" ] || listed_tickets="$listed_tickets$key,"
done <<EOF
$docs
EOF

sessions=$(claude_sessions); census_rc=$?
[ "$census_rc" -eq 0 ] || unavailable "session census rc=$census_rc"
live_names=","
while IFS=$'\t' read -r pid name _model _ac; do
    [ -n "$pid" ] || continue
    case "$name" in '#'*|'') continue ;; esac
    case "$name" in "$prefix"*) ;; *) continue ;; esac
    case "$selves" in *",${name},"*) continue ;; esac
    base=$(printf '%s' "$name" | sed -E 's/-r[0-9]+$//')
    case "$listed_names" in
        *",${name},"*|*",${base},"*) live_names="$live_names$name," ;;
        *) echo "# orphan session $name not in the fleet list" ;;
    esac
done <<EOF
$sessions
EOF

while IFS= read -r doc; do
    [ -n "$doc" ] && [ -r "$doc" ] || continue
    ident=$(worker_identity "$doc")
    live=""
    for n in $(printf '%s' "${ident#*$'\t'}" | tr ',' ' '); do
        for cand in "$n" "$n-RESUME"; do
            case "$live_names" in *",${cand},"*) live="$cand"; break 2 ;; esac
        done
    done
    [ -n "$live" ] || continue
    [ "$(worker_tail_status "$doc")" != WRAPPED ] || continue
    pr=$(grep -E '^- .*(READY|PR) #?[0-9]+' "$doc" | tail -n 1 | grep -oE '(READY|PR) #?[0-9]+' | tail -n 1 | grep -oE '[0-9]+') || pr=""
    [ -n "$pr" ] || continue
    if ! view=$(cd "$repo" && GH_READ_QUIET=1 "$GH" pr view "$pr" --json state,mergeCommit); then
        unavailable "gh pr view $pr"; continue
    fi
    [ "$(printf '%s' "$view" | jq -r '.state // empty')" = MERGED ] || continue
    sha=$(printf '%s' "$view" | jq -r '.mergeCommit.oid // empty')
    [ -n "$sha" ] || continue
    echo "# orphan finished $live pr=$pr merged=$sha"
done <<EOF
$docs
EOF

if ! prs=$(cd "$repo" && GH_READ_QUIET=1 "$GH" pr list --state open --limit 200 --json number,headRefName,isCrossRepository,author) \
    || ! rows=$(printf '%s' "$prs" | jq -r '.[] | select((.isCrossRepository | not) and ((.author.login // "") | test("dependabot") | not) and ((.headRefName // "") | startswith("dependabot/") | not)) | [.number, .headRefName] | @tsv'); then
    unavailable "gh pr list"
    rows=""
fi
while IFS=$'\t' read -r num head; do
    [ -n "$num" ] || continue
    case ",$(printf '%s' "$watched" | tr '\n' ','), " in *",${num},"*) continue ;; esac
    key=$(printf '%s' "$head" | grep -oiE '[a-z]+-[0-9]+' | head -n 1 | tr '[:lower:]' '[:upper:]') || key=""
    if [ -z "$key" ]; then
        echo "# orphan pr $num its branch $head names no ticket"
    else
        case "$listed_tickets" in *",${key},"*) ;; *) echo "# orphan pr $num no listed worker holds $key" ;; esac
    fi
done <<EOF
$rows
EOF

[ "$incomplete" -eq 0 ] || exit 3
exit 0
