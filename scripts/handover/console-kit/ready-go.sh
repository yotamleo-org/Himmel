#!/usr/bin/env bash
# scripts/handover/console-kit/ready-go.sh - the console's whole mechanical READY
# turn in one call. A leg's READY used to cost the console a wake, a ready-check,
# a trust-path look, a ticket read, a hand-built GO line and a ledger bullet;
# the only judgement in it is GO or not. This prints everything that decision
# needs and the exact GO line to send. It sends nothing and writes no GO: the
# SendMessage and go.sh stay the console's own, so no trust is widened.
#
# Usage: ready-go.sh [--to <leg session> --token <nonce>] [--ledger <console doc>]
#                    <pr-number> <full-40-hex-head-sha>
#
# Output, one section per line:
#   the ready-check.sh output, verbatim, then READY-GO PASS|FAIL
#   COVERAGE: the ready-check item 7 line
#   TRUST: none | not-adopted | hit <path> | refused <phase> <reason>
#   TICKET: <KEY> <status> | <KEY> UNKNOWN | none  (the first key of the PR title)
#   NEXT: ...  the go.sh command to run, then
#   SENDMESSAGE to=<leg session> :: GO <pr> <sha>, token <nonce>
# Refuses what go.sh refuses: a failed ready-check (which holds the CR-ledger ok
# row at that head) prints no GO line and exits 4; a trust-path hit prints no GO
# line, only the judge-first route (go.sh --trust-reviewed), and exits 0; an
# unreadable or refused trust check exits 5. --ledger appends one bullet to the
# console doc through append-results.sh and only on a clean result.
#
# Exit: 0 printed (a GO line, or a trust-reviewed route); 1 the --ledger bullet
# could not be appended; 2 usage; 4 ready-check did not PASS; 5 the trust check
# refused or could not run.
# Seams (tests): GH_CMD and JIRA_CMD, as in ready-check.sh; READY_GO_ANCHOR
# replaces the harness anchor that trust_path_check and the Jira CLI are read from.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, no mapfile.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh"
git_env_scrub
ANCHOR="${READY_GO_ANCHOR:-$(cd "$HERE/../../.." && pwd)}"
usage() { echo "usage: ready-go.sh [--to <leg session> --token <nonce>] [--ledger <console doc>] <pr-number> <full-40-hex-head-sha>" >&2; exit 2; }

TO=""; TOKEN=""; LEDGER=""
while :; do
    case "${1:-}" in
        --to) [ "$#" -ge 2 ] || usage; TO="$2"; shift 2 ;;
        --token) [ "$#" -ge 2 ] || usage; TOKEN="$2"; shift 2 ;;
        --ledger) [ "$#" -ge 2 ] || usage; LEDGER="$2"; shift 2 ;;
        *) break ;;
    esac
done
[ "$#" -eq 2 ] || usage
PR="$1"; SHA="$2"
case "$PR" in ''|0*|*[!0123456789]*) usage ;; esac
case "$SHA" in *[!0123456789abcdef]*) usage ;; esac
[ "${#SHA}" -eq 40 ] || usage
# the token and session go into a message line verbatim: keep them one plain word
case "$TO$TOKEN" in *[!A-Za-z0-9._:-]*) echo "ready-go: --to and --token must be [A-Za-z0-9._:-]" >&2; exit 2 ;; esac
{ [ -z "$TO" ] && [ -z "$TOKEN" ]; } || { [ -n "$TO" ] && [ -n "$TOKEN" ]; } || usage
[ -z "$LEDGER" ] || [ -f "$LEDGER" ] || { echo "ready-go: --ledger doc not found: $LEDGER" >&2; exit 2; }

GH_BIN="${GH_CMD:-gh}"

# 1. the gate go.sh runs: head, CI, threads, CR-ledger ok row, trailers, tickets, coverage
rc=0
READY_OUT=$(bash "$HERE/ready-check.sh" "$PR" "$SHA" 2>&1) || rc=$?
printf '%s\n' "$READY_OUT"
if [ "$rc" -ne 0 ]; then
    echo "READY-GO FAIL (ready-check exit $rc) - no GO line; the leg fixes what is named above"
    exit 4
fi
echo "READY-GO PASS"
printf 'COVERAGE: %s\n' "$(printf '%s\n' "$READY_OUT" | grep -E '^\[[A-Z]+\] 7\.' | head -n 1)"

# 2. trust path: the same question merge-on-green asks, on the default branch's list
TRUST_RC=0
NWO=$("$GH_BIN" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || NWO=""
DEFAULT_BRANCH=$("$GH_BIN" repo view --json defaultBranchRef --jq '.defaultBranchRef.name // ""' 2>/dev/null) || DEFAULT_BRANCH=""
TRUST_OUT=""
if [ -z "$NWO" ] || [ -z "$DEFAULT_BRANCH" ]; then
    TRUST_RC=2; TRUST_OUT="repo cannot resolve the repo name or default branch (gh repo view failed)"
else
    unset -f trust_path_check 2>/dev/null || true
    # shellcheck source=scripts/lib/go-gate.sh
    # shellcheck disable=SC1091
    if . "$ANCHOR/scripts/lib/go-gate.sh" 2>/dev/null && declare -F trust_path_check >/dev/null 2>&1; then
        TRUST_OUT=$(GH="$GH_BIN" trust_path_check "$NWO" "$PR" "$SHA" "$DEFAULT_BRANCH" "$ANCHOR") || TRUST_RC=$?
    else
        TRUST_RC=2; TRUST_OUT="go-lib cannot load trust_path_check from scripts/lib/go-gate.sh"
    fi
fi
if [ "$TRUST_RC" -ne 0 ]; then
    printf 'TRUST: refused %s\n' "${TRUST_OUT:-check trust_path_check exited $TRUST_RC with no reason}"
    echo "READY-GO: no GO line - the trust check refused (above); same refusal merge-on-green would give"
    exit 5
fi
printf 'TRUST: %s\n' "$TRUST_OUT"

# 3. the ticket: first key of the PR title and its Jira status
TITLE=$("$GH_BIN" pr view "$PR" --json title --jq .title 2>/dev/null) || TITLE=""
KEY=$(printf '%s' "$TITLE" | grep -oE '[A-Z][A-Z0-9]*-[0-9]+' | head -n 1)
if [ -z "$KEY" ]; then
    echo "TICKET: none (no key in the PR title)"
else
    if [ -n "${JIRA_CMD:-}" ]; then
        JOUT=$("$JIRA_CMD" get "$KEY" 2>&1) || JOUT=""
    else
        # dist/ is an untracked build in the primary checkout, absent from a worktree
        JCOMMON=$(git -C "$ANCHOR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || JCOMMON=""
        JANCHOR="$ANCHOR"; [ -z "$JCOMMON" ] || JANCHOR=$(dirname "$JCOMMON")
        JOUT=$(node "$JANCHOR/scripts/jira/dist/index.js" get "$KEY" 2>&1) || JOUT=""
    fi
    # the first line is "<KEY>\t<type>\t<status>\t<summary>"
    STATUS=$(printf '%s\n' "$JOUT" | head -n 1 | awk -F'\t' -v k="$KEY" '$1 == k { print $3 }')
    printf 'TICKET: %s %s\n' "$KEY" "${STATUS:-UNKNOWN}"
fi

# 4. the GO: file by go.sh (console only), notification by SendMessage (console only)
case "$TRUST_OUT" in
    "hit "*)
        printf 'NEXT: trust-path hit (%s) - no plain GO. Dispatch the opus judge; on its GO verdict for this head run: bash %q/go.sh --trust-reviewed <judge qid> %s %s\n' \
            "${TRUST_OUT#hit }" "$HERE" "$PR" "$SHA" ;;
    *)
        printf 'NEXT: bash %q/go.sh %s %s\n' "$HERE" "$PR" "$SHA"
        if [ -n "$TO" ]; then
            printf 'SENDMESSAGE to=%s :: GO %s %s, token %s\n' "$TO" "$PR" "$SHA" "$TOKEN"
        else
            echo "SENDMESSAGE skipped (pass --to <leg session> --token <nonce> for the GO line)"
        fi ;;
esac

# 5. the ledger bullet, on request, only for a clean result
if [ -n "$LEDGER" ]; then
    bash "$HERE/append-results.sh" "$LEDGER" "ready-go PR $PR $SHA: ready-check PASS, trust ${TRUST_OUT%% *}, ticket ${KEY:-none}" >/dev/null \
        || { echo "ready-go: could not append the ledger bullet to $LEDGER" >&2; exit 1; }
    echo "LEDGER: appended to $LEDGER"
fi
