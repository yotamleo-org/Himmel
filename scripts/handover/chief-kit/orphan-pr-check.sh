#!/usr/bin/env bash
# orphan-pr-check.sh — every open PR must map to a live worker in the fleet
# manifest or to a named hold on the chief doc's `queue:` line.
#
#   orphan-pr-check.sh --doc <chief doc> [--workers-from <fleet.json>] [--repo <path>]
#
# Prints `UNMAPPED <n> <head branch>` per open PR that maps to neither, and exits 1.
# A PR maps when
#   - a manifest worker whose doc exists and whose newest marker is not WRAPPED carries the
#     branch's ticket key in its doc name, or names the branch in its text; or
#   - the chief doc's Live state `queue:` line names the PR (`#<n>` or `<n>`) or that key.
# A WRAPPED worker is not live: its open PR is exactly the orphan this check exists for.
#
# The PR set is `gh pr list --state open --json number,headRefName` run in <repo>
# (default: this checkout). Seam (tests): ORPHAN_PR_CHECK_PRS = a file holding that JSON.
# An unreadable PR list is not an orphan: it prints `orphan-pr-check: unavailable ...` on
# stderr and exits 0, so a gh outage never blocks a handover.
#
# Exit: 0 every PR mapped (or list unavailable); 1 at least one orphan; 2 usage.
# PLATFORM GUARD: Linux-only kit, bash 3.2-safe; needs jq.
# ponytail: the worker is matched by the ticket key in the branch name (as tick.sh's unowned-prs= does),
# so a branch with no key maps only through the doc text or a hold on its PR number;
# upgrade = match the worker's own recorded branch.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DEFAULT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../lib/worker-tail-status.sh
. "$HERE/../../lib/worker-tail-status.sh"
# shellcheck source=../../lib/legacy-names.sh
. "$HERE/../../lib/legacy-names.sh"
if legacy_names_on; then JQ_W='def W: (.workers // .legs);'; else JQ_W='def W: .workers;'; fi

usage() { echo "usage: orphan-pr-check.sh --doc <chief doc> [--workers-from <fleet.json>] [--repo <path>]" >&2; exit 2; }
doc=""; manifest=""; repo="$REPO_DEFAULT"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc) [ "$#" -ge 2 ] || usage; doc="$2"; shift 2 ;;
        --workers-from) [ "$#" -ge 2 ] || usage; manifest="$2"; shift 2 ;;
        --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$doc" ] || usage
[ -n "$manifest" ] || manifest="${doc%.md}.fleet.json"

unavailable() { echo "orphan-pr-check: unavailable ($1)" >&2; exit 0; }
if [ -n "${ORPHAN_PR_CHECK_PRS:-}" ]; then
    prs_json="$(cat "$ORPHAN_PR_CHECK_PRS" 2>/dev/null)" || prs_json=""  # swallow-ok: an empty read exits as unavailable below, never as an orphan
else
    prs_json="$(cd "$repo" 2>/dev/null && timeout -k 2 30 gh pr list --state open --limit 200 --json number,headRefName 2>/dev/null)" || prs_json=""  # gnu-ok: Linux-only kit; swallow-ok: an empty read exits as unavailable below, never as an orphan
fi
[ -n "$prs_json" ] || unavailable "the open-PR list could not be read"
rows="$(printf '%s\n' "$prs_json" | jq -r '.[] | "\(.number)\t\(.headRefName)"' 2>/dev/null)" || unavailable "the open-PR list is not a JSON array"  # swallow-ok: a parse failure exits as unavailable, never as an orphan
[ -n "$rows" ] || exit 0

ticket_key() { printf '%s\n' "$1" | grep -oiE '[a-z][a-z0-9]*-[0-9]+' | head -n 1 | tr '[:lower:]' '[:upper:]'; }

# the live workers' docs: in the manifest, present, newest marker not WRAPPED
live_docs=""
if [ -f "$manifest" ]; then
    manifest_docs="$(jq -r "$JQ_W"'W[] | .doc // empty' "$manifest" 2>/dev/null)" || unavailable "the fleet manifest could not be read"  # swallow-ok: an unreadable manifest exits as unavailable, never as an orphan
    while IFS= read -r wdoc; do
        [ -f "$wdoc" ] || continue
        [ "$(worker_tail_status "$wdoc")" != WRAPPED ] || continue
        live_docs="$live_docs$wdoc"$'\n'
    done <<EOF_DOCS
$manifest_docs
EOF_DOCS
fi
live_keys=" "
while IFS= read -r wdoc; do
    [ -n "$wdoc" ] || continue
    k="$(ticket_key "${wdoc##*/}")"
    [ -z "$k" ] || live_keys="$live_keys$k "
done <<EOF_KEYS
$live_docs
EOF_KEYS

queue_line="$(awk '
    $0 == "## Live state" { s = 1; next }
    s && /^## / { exit }
    s && index($0, "queue:") == 1 { print; exit }
' "$doc" 2>/dev/null)"

orphans=0
while IFS="$(printf '\t')" read -r n branch; do
    [ -n "$n" ] || continue
    key="$(ticket_key "$branch")"
    if [ -n "$key" ]; then
        case "$live_keys" in *" $key "*) continue ;; esac
    fi
    mapped=""
    while IFS= read -r wdoc; do
        [ -n "$wdoc" ] || continue
        if grep -qF -- "$branch" "$wdoc" 2>/dev/null; then mapped=1; break; fi
    done <<EOF_TXT
$live_docs
EOF_TXT
    [ -z "$mapped" ] || continue
    if printf '%s\n' "$queue_line" | grep -qE "(^|[^0-9A-Za-z-])#?$n([^0-9]|\$)"; then continue; fi
    if [ -n "$key" ] && printf '%s\n' "$queue_line" | grep -qiE "(^|[^A-Za-z0-9])$key([^0-9]|\$)"; then continue; fi
    printf 'UNMAPPED %s %s\n' "$n" "$branch"
    orphans=$((orphans + 1))
done <<EOF_ROWS
$rows
EOF_ROWS
[ "$orphans" -eq 0 ] || exit 1
exit 0
