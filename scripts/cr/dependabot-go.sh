#!/usr/bin/env bash
# scripts/cr/dependabot-go.sh — record that a Dependabot dependency-only PR has the
# one review it can get: a signed judge GO at its exact head.
#
#   dependabot-go.sh <pr> <head-sha> --judge <qid>
#
# Nobody checks a Dependabot branch out, so review-round.sh judge-go (which needs
# the branch in the working tree and a spent round cap) cannot record it. This
# has ledger-append.sh append one `dependabot-go` row to the CR ledger; the
# merge gate (review-merge-gate.sh) and ready-check row 4 read it for that head
# and that branch only. Refused, with the ledger untouched, unless ALL hold:
#   1. the PR is open, its author is app/dependabot and its head is <head-sha>;
#   2. every file the PR changes (renames' old names included, every page, the
#      count matching changedFiles) has a manifest or lockfile NAME (allowlist
#      below; a directory never qualifies) and the list is not empty;
#   3. a judge verdict under verdicts/<qid>/ is a signed GO for <head-sha> naming
#      this PR (go_trust_verdict, the check go.sh makes for a trust-reviewed GO).
# Exit 0 recorded (or already there); 2 refused or unreadable.
#
#   dependabot-go.sh <pr> <head-sha> --check
#
# runs checks 1 and 2 only (no verdict, no row): exit 0 when the PR is a
# dependency-only Dependabot PR at that head.
#
#   dependabot-go.sh --sweep
#
# lands every open Dependabot PR with no chief turn; tick.sh runs
# it when DEPENDABOT_AUTOLAND=on. A PR gets GitHub auto-merge, armed with
# --match-head-commit at its head, only when ALL hold, in this order:
#   a. --check passes (the allowlist, before any judge spend);
#   b. GitHub reports it CLEAN at that head and every required check `pass`;
#   c. a judge call (DEPENDABOT_JUDGE_CALL, default scripts/api-lane/judge-call.sh:
#      sonnet, 0.50 USD) records a signed GO at that head, under qid
#      dbot-<pr>-<head12>; one call per head, a NO-GO or failed call included;
#   d. the record path above appends the dependabot-go row and the row is there.
# A PR already armed is left alone. Prints one line per PR, then
# `dependabot-go sweep: armed=<n> skipped=<n>`; exit 2 only when the list is unreadable.
#
# ponytail: the row is unsigned like a judge-go row (the ledger is same-uid
# writable, and the merge gate re-reads the PR author), upgrade: a go_msg_mac on
# the row, as cr-disposition.sh signs its rows.
#
# Platform guard (gitbash-only): POSIX bash 3.2+.
set -u

usage() { echo "usage: dependabot-go.sh <pr> <head-sha> --judge <qid> | <pr> <head-sha> --check | --sweep" >&2; exit 2; }

MODE=record PR="" SHA="" QID=""
if [ "$#" -eq 1 ] && [ "$1" = --sweep ]; then
    MODE=sweep
else
    PR="${1:-}"; SHA="${2:-}"
    if [ "$#" -eq 3 ] && [ "$3" = --check ]; then
        MODE=check
    else
        [ "$#" -eq 4 ] && [ "${3:-}" = --judge ] || usage
        QID="$4"
    fi
    case "$PR" in ''|0*|*[!0123456789]*) usage ;; esac
    case "$SHA" in *[!0123456789abcdef]*) usage ;; esac
    [ "${#SHA}" -eq 40 ] || usage
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ANCHOR="$(cd "$HERE/../.." && pwd)"
GH="${GH_CMD:-gh}"
refuse() { echo "dependabot-go: refused - $*" >&2; exit 2; }

# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
if ! . "$ANCHOR/scripts/lib/go-gate.sh" 2>/dev/null || ! declare -F go_trust_verdict >/dev/null 2>&1; then
    echo "dependabot-go: cannot load scripts/lib/go-gate.sh" >&2
    exit 2
fi
# shellcheck source=scripts/lib/git-clean.sh
# shellcheck disable=SC1091
. "$ANCHOR/scripts/lib/git-clean.sh" 2>/dev/null && git_env_scrub
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""  # swallow-ok: empty fails closed on the next line
[ -n "$common" ] || { echo "dependabot-go: not in a git repo, so there is no CR ledger" >&2; exit 2; }

# sweep_one <pr> <head> <auto-merge armed: true|false> - arm auto-merge when every guard holds; 0 = armed
sweep_one() {
    local pr="$1" sha="$2" qid q state buckets row judged="$common/dependabot-judged"
    skip() { echo "dependabot-go sweep: #$pr skipped - $*"; }
    case "$pr" in ''|0*|*[!0123456789]*) skip "not a PR number"; return 1 ;; esac
    [ "$3" = false ] || { skip "auto-merge is already armed"; return 1; }
    bash "$0" "$pr" "$sha" --check || { skip "not a dependency-only Dependabot PR at $sha"; return 1; }
    state=$("$GH" pr view "$pr" --json mergeStateStatus,headRefOid 2>/dev/null | jq -r '"\(.mergeStateStatus) \(.headRefOid)"' 2>/dev/null) || state=""  # swallow-ok: empty fails the equality below
    [ "$state" = "CLEAN $sha" ] || { skip "GitHub reports '${state:-unreadable}', not CLEAN at $sha"; return 1; }
    # gh exits 1 on a failed check and 8 on a pending one: only exit 0 with every bucket pass arms
    buckets=$("$GH" pr checks "$pr" --required --json bucket --jq '.[].bucket' 2>/dev/null) || { skip "a required check is not pass"; return 1; }  # swallow-ok: a failed read refuses here, never a value
    if [ -z "$buckets" ] || grep -qvx pass <<<"$buckets"; then
        skip "a required check is not pass"; return 1
    fi
    qid="dbot-$pr-$(printf '%.12s' "$sha")"
    if ! grep -qxF "$qid" "$judged" 2>/dev/null; then
        q=$(mktemp "${TMPDIR:-/tmp}/dependabot-judge.XXXXXX") || { skip "mktemp failed"; return 1; }
        {
            printf 'Dependabot PR #%s at head %s changes only dependency manifests and lockfiles (the allowlist was checked). Its full diff follows.\n' "$pr" "$sha"
            printf 'Rule GO only if the diff is a plain version bump: changed versions, hashes, integrity and resolved URLs on the same registry. Rule NO-GO for a new or changed install script or lifecycle hook, a git, URL, file or tarball dependency, a new registry or index URL, a new package that is not a transitive of the bumped one, or anything you cannot account for.\n\n'
            "$GH" pr diff "$pr" 2>/dev/null || echo "DIFF-UNREADABLE"
        } > "$q"
        if grep -qx DIFF-UNREADABLE "$q" || [ "$(wc -c < "$q")" -gt 60000 ]; then
            rm -f "$q"; skip "the diff is unreadable or too big for one judge question"; return 1
        fi
        # recorded before the call: a head gets one judge spend, a failed call included
        printf '%s\n' "$qid" >> "$judged" || { rm -f "$q"; skip "cannot record the judged head"; return 1; }
        bash "${DEPENDABOT_JUDGE_CALL:-$ANCHOR/scripts/api-lane/judge-call.sh}" --qid "$qid" --pr "$pr" --head "$sha" --question-file "$q" \
            --model claude-sonnet-5-5 --max-budget-usd 0.50 --effort medium --timeout 600 --judge dbot-judge >/dev/null 2>&1 || :  # swallow-ok: the record step below refuses without a signed GO
        rm -f "$q"
    fi
    bash "$0" "$pr" "$sha" --judge "$qid" || { skip "no dependabot-go row (judge $qid)"; return 1; }
    row=$(jq -cR --arg h "$sha" --argjson p "$pr" 'fromjson? | select(.kind == "dependabot-go" and .head == $h and .pr == $p and .status == "ok")' "$common/cr-critic-scores.jsonl" 2>/dev/null) || row=""  # swallow-ok: an unreadable ledger reads as no row and refuses below
    [ -n "$row" ] || { skip "the dependabot-go row is not in the ledger"; return 1; }
    "$GH" pr merge "$pr" --auto --squash --match-head-commit "$sha" >/dev/null 2>&1 || { skip "GitHub refused to arm auto-merge"; return 1; }
    echo "dependabot-go sweep: #$pr armed at $sha (judge:$qid)"
}

if [ "$MODE" = sweep ]; then
    list=$("$GH" pr list --author app/dependabot --state open --limit 100 --json number,headRefOid,autoMergeRequest \
        --jq '.[] | "\(.number) \(.headRefOid) \(.autoMergeRequest != null)"' 2>/dev/null) || { echo "dependabot-go sweep: cannot list the open Dependabot PRs" >&2; exit 2; }
    armed=0 skipped=0
    while read -r n h a; do
        [ -n "$n" ] || continue
        if sweep_one "$n" "$h" "$a" 2>&1; then armed=$((armed + 1)); else skipped=$((skipped + 1)); fi
    done <<EOF
$list
EOF
    echo "dependabot-go sweep: armed=$armed skipped=$skipped"
    exit 0
fi

pr_json=$("$GH" pr view "$PR" --json author,headRefName,headRefOid,state,changedFiles 2>/dev/null) || refuse "cannot read PR #$PR"  # swallow-ok: rc is checked, an unreadable PR refuses
author=$(printf '%s' "$pr_json" | jq -r '.author.login // empty' 2>/dev/null) || author=""  # swallow-ok: empty fails the author check
[ "$author" = app/dependabot ] || refuse "PR #$PR is authored by '${author:-unknown}', not app/dependabot - a human PR goes through the review panel"
[ "$(printf '%s' "$pr_json" | jq -r '.state // empty' 2>/dev/null)" = OPEN ] || refuse "PR #$PR is not open"  # swallow-ok: an unreadable state fails the equality
[ "$(printf '%s' "$pr_json" | jq -r '.headRefOid // empty' 2>/dev/null)" = "$SHA" ] || refuse "PR #$PR's head is not $SHA (a GO is for one head)"  # swallow-ok: an unreadable head fails the equality
BRANCH=$(printf '%s' "$pr_json" | jq -r '.headRefName // empty' 2>/dev/null) || BRANCH=""  # swallow-ok: empty fails closed below
case "$BRANCH" in
    ''|*[\"\\]*|*[[:cntrl:]]*) refuse "the head branch '$BRANCH' cannot be written into a ledger row" ;;
esac
want=$(printf '%s' "$pr_json" | jq -r '.changedFiles // empty' 2>/dev/null) || want=""  # swallow-ok: empty fails the count check
nwo=$("$GH" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || nwo=""  # swallow-ok: empty fails closed on the next line
[ -n "$nwo" ] || refuse "cannot resolve the repository"
# every changed name (counted against changedFiles) and each rename's old name; same name pattern as ready-check.sh dep_pr_generated
files=$("$GH" api --paginate "repos/$nwo/pulls/$PR/files" --jq '.[].filename' 2>/dev/null) || refuse "cannot read PR #$PR's files"  # swallow-ok: rc is checked, an unreadable list refuses
prev=$("$GH" api --paginate "repos/$nwo/pulls/$PR/files" --jq '.[].previous_filename // empty' 2>/dev/null) || refuse "cannot read PR #$PR's renamed paths"  # swallow-ok: rc is checked, an unreadable list refuses
[ -n "$files" ] || refuse "PR #$PR lists no changed files"
case "$want" in ''|*[!0-9]*) refuse "PR #$PR reports no changedFiles count" ;; esac
[ "$(printf '%s\n' "$files" | sort -u | wc -l | tr -d ' ')" -ge "$want" ] || refuse "the file list is shorter than the $want changed files (truncated)"
names="$files"
[ -z "$prev" ] || names="$files
$prev"
if bad=$(printf '%s\n' "$names" | grep -Ev '(^|/)(package\.json|package-lock\.json|bun\.lock|requirements[A-Za-z0-9._-]*\.txt)$'); then
    refuse "PR #$PR changes a file that is not a dependency manifest or lockfile: $(printf '%s' "$bad" | head -n 1)"
fi
[ "$MODE" = record ] || { echo "dependabot-go: PR #$PR at $SHA is a dependency-only Dependabot PR"; exit 0; }

ROOT=""
# shellcheck source=scripts/lib/handover-path.sh
# shellcheck disable=SC1091
if . "$ANCHOR/scripts/lib/handover-path.sh" 2>/dev/null; then
    ROOT=$(go_resolve_root "$ANCHOR" 2>/dev/null) || ROOT=""  # swallow-ok: empty ROOT fails closed on the next line
fi
[ -n "$ROOT" ] || refuse "cannot resolve the handover root to read judge $QID's verdict"
why=$(go_trust_verdict "$ROOT" "$QID" "$SHA" "$ANCHOR" "$PR") || refuse "judge $QID has no signed GO for this head: $why"

# the files were read after the head check; a head that moved since is not the head the GO signed
now=$("$GH" pr view "$PR" --json headRefOid 2>/dev/null | jq -r '.headRefOid // empty' 2>/dev/null) || now=""  # swallow-ok: empty fails the equality below
[ "$now" = "$SHA" ] || refuse "PR #$PR's head moved to '${now:-unknown}' while its files were read"

env -u CR_LEDGER bash "$HERE/ledger-append.sh" dependabot-go --branch "$BRANCH" --head "$SHA" --source "judge:$QID" --pr "$PR" >/dev/null || exit 2
echo "dependabot-go: recorded PR #$PR at $SHA (judge:$QID)"
