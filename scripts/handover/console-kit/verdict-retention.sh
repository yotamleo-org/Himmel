#!/usr/bin/env bash
# scripts/handover/console-kit/verdict-retention.sh - retire verdict records and
# judge scratch.
#
# Usage:
#   verdict-retention.sh archive [--apply] [--days N] [--verdicts-dir DIR] [--repo OWNER/NAME]
#   verdict-retention.sh prune   [--apply] [--days N] [--cache DIR] [--verdicts-dir DIR] [--repo OWNER/NAME]
#
# archive: every <verdicts>/<qid>/ whose verdict files all name a PR that has
#   been closed or merged for N days (default 14) gets one row per file in the
#   append-only <verdicts>/_ledger.jsonl (qid, pr, head, verdict, model,
#   written_at, sha256, closed_at, archive_path), then moves with git mv to
#   <bucket>/archive/<YYYY-MM>/verdicts/<qid>/ (plain mv when the dir is not
#   tracked). The verdict line and the pr: line parse exactly as go-gate.sh's
#   go_trust_verdict does. A dir stays in place, and is listed as KEEP, when
#   its PR is open, cannot be looked up, closed inside the age, a file has no
#   parsable verdict or pr: line, or it holds anything but *.md files. The pr:
#   line names no repo, so a dir also stays when a verdict head is not a commit
#   of --repo (a fork's PR number): the repo is proven or the dir is kept.
#   Nothing is ever deleted. A rerun appends no second row.
# prune: removes ~/.cache/himmel/verdicts/<qid>/ judge-scratch dirs untouched
#   for N days whose PR is provably closed: the qid has a verdict dir in
#   <verdicts> whose PRs are all CLOSED or MERGED with heads in --repo, or a
#   _ledger.jsonl row. An open, unresolvable or unproven one is KEEP. Only real
#   directories with a qid name are candidates, so files, symlinks and young
#   dirs stay. A cache inside the handover root is refused.
#
# Both verbs are a dry run (PRUNE/MOVE/KEEP lines, nothing changed) unless
# --apply is given.
#
# Seams: HIMMEL_VERDICT_PR_STATE_CMD (a command run with the PR number that
# prints `<OPEN|CLOSED|MERGED> [<closedAt ISO>]`; default gh pr view),
# HIMMEL_VERDICT_HEAD_CHECK_CMD (run with `<repo> <sha>`, rc 0 when the commit
# is in the repo; default gh api), HIMMEL_VERDICT_NOW (epoch seconds).
#
# Exit codes: 0 ok; 1 a move or lookup tool failed; 2 usage or refused target;
# 3 a required tool or lib is missing.
# shellcheck disable=SC2015,SC2016  # A && B || C is intentional; the backticks are the verdict line's literal text
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LC_ALL=C
export LC_ALL

verb="${1:-}"
[ $# -gt 0 ] && shift
apply=0 days=14 vdir="" repo="" cache=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) apply=1; shift ;;
        --days) [ $# -ge 2 ] || { echo "verdict-retention: --days needs a value" >&2; exit 2; }; days="$2"; shift 2 ;;
        --verdicts-dir) [ $# -ge 2 ] || { echo "verdict-retention: --verdicts-dir needs a value" >&2; exit 2; }; vdir="$2"; shift 2 ;;
        --repo) [ $# -ge 2 ] || { echo "verdict-retention: --repo needs a value" >&2; exit 2; }; repo="$2"; shift 2 ;;
        --cache) [ $# -ge 2 ] || { echo "verdict-retention: --cache needs a value" >&2; exit 2; }; cache="$2"; shift 2 ;;
        *) echo "verdict-retention: unknown argument '$1'" >&2; exit 2 ;;
    esac
done
case "$days" in ''|*[!0-9]*|0*) echo "verdict-retention: --days must be a positive integer (got '$days')" >&2; exit 2 ;; esac
case "$verb" in archive|prune) ;; *) echo "usage: verdict-retention.sh archive|prune [--apply] [--days N] ..." >&2; exit 2 ;; esac

now="${HIMMEL_VERDICT_NOW:-$(date +%s)}"
case "$now" in ''|*[!0-9]*) echo "verdict-retention: HIMMEL_VERDICT_NOW must be epoch seconds" >&2; exit 2 ;; esac

# shellcheck source=scripts/lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh" && git_env_scrub || { echo "verdict-retention: cannot load scripts/lib/git-clean.sh" >&2; exit 3; }
# shellcheck source=scripts/lib/handover-path.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/handover-path.sh" || { echo "verdict-retention: cannot load scripts/lib/handover-path.sh" >&2; exit 3; }

# iso_epoch <ISO-8601 UTC>: epoch seconds on stdout, rc 1 when unparsable.
iso_epoch() {
    local e
    # swallow-ok: GNU date rejects BSD syntax and vice versa; both failing returns 1, never a value
    e=$(date -u -d "$1" +%s 2>/dev/null) || e=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null) || return 1
    printf '%s' "$e"
}

# sha256_of <file>: the file's sha256 as 64 hex, rc 1 when it cannot be hashed.
sha256_of() {
    local h
    if command -v sha256sum >/dev/null 2>&1; then h=$(sha256sum "$1"); else h=$(shasum -a 256 "$1"); fi || return 1
    h="${h%% *}"
    case "$h" in ''|*[!0-9a-f]*) return 1 ;; esac
    printf '%s' "$h"
}

command -v jq >/dev/null 2>&1 || { echo "verdict-retention: jq is required" >&2; exit 3; }
if [ -z "$vdir" ]; then
    # shellcheck source=scripts/lib/go-gate.sh
    # shellcheck disable=SC1091
    . "$HERE/../../lib/go-gate.sh" || { echo "verdict-retention: cannot load scripts/lib/go-gate.sh" >&2; exit 3; }
    anchor="$(cd "$HERE/../../.." && pwd)"
    root=$(go_resolve_root "$anchor") && scope=$(go_verdict_scope "$anchor") \
        || { echo "verdict-retention: cannot resolve the handover root / verdict scope" >&2; exit 3; }
    vdir="$root/$scope/verdicts"
fi
[ -d "$vdir" ] || { echo "verdict-retention: $vdir is not a directory" >&2; exit 2; }
bucket="$(cd "$vdir/.." && pwd)"
ledger="$vdir/_ledger.jsonl"

# The repo the PR numbers and heads must belong to. Resolved once, in this
# shell, so the lookups below can run in command substitutions.
if [ -z "$repo" ] && { [ -z "${HIMMEL_VERDICT_PR_STATE_CMD:-}" ] || [ -z "${HIMMEL_VERDICT_HEAD_CHECK_CMD:-}" ]; }; then
    repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner) \
        || { echo "verdict-retention: cannot resolve the repo; pass --repo OWNER/NAME" >&2; exit 3; }
fi

pr_state_raw() {
    if [ -n "${HIMMEL_VERDICT_PR_STATE_CMD:-}" ]; then
        "$HIMMEL_VERDICT_PR_STATE_CMD" "$1"
    else
        gh pr view "$1" --repo "$repo" --json state,closedAt,mergedAt --jq '[.state, (.closedAt // .mergedAt // "")] | join(" ")'
    fi
}
# pr_state <n>: sets PRST to `<STATE> [closedAt]`, rc 1 on a failed lookup.
# Memoized for this run (many dirs share a PR); a failed lookup is memoized too.
memo=""
PRST=""
pr_state() {
    local hit res
    hit=$(printf '%s' "$memo" | grep -F "|$1|" | head -1)
    if [ -n "$hit" ]; then
        res="${hit#*|"$1"|}"
    else
        # swallow-ok: a failed lookup is memoized as `-` and keeps the dir in place
        res=$(pr_state_raw "$1" 2>/dev/null) || res="-"
        [ -n "$res" ] || res="-"
        memo="$memo|$1|$res"$'\n'
    fi
    PRST="$res"
    [ "$res" != "-" ]
}

# head_in_repo <sha>: rc 0 when the commit exists in $repo. A verdict's pr:
# line carries no repo, so a head that is not in the target repo means the PR
# number may belong to another repo (a fork) and the verdict is not retired.
head_check_raw() {
    if [ -n "${HIMMEL_VERDICT_HEAD_CHECK_CMD:-}" ]; then
        "$HIMMEL_VERDICT_HEAD_CHECK_CMD" "$repo" "$1"
    else
        gh api "repos/$repo/commits/$1" --jq .sha >/dev/null
    fi
}
hmemo=""
head_in_repo() {
    local hit res
    hit=$(printf '%s' "$hmemo" | grep -F "|$1|" | head -1)
    if [ -n "$hit" ]; then
        res="${hit#*|"$1"|}"
    else
        # swallow-ok: a head that cannot be confirmed is memoized as `no` and keeps the dir in place
        if head_check_raw "$1" >/dev/null 2>&1; then res=yes; else res=no; fi
        hmemo="$hmemo|$1|$res"$'\n'
    fi
    [ "$res" = yes ]
}

# assess <qid> <dir> <strict> <min-age-days>: sets keep (empty = retire),
# files, prs, newest_iso. strict=1: any entry that is not a plain *.md file
# keeps the dir; strict=0 ignores such entries. Every verdict file must parse
# and name a PR that is CLOSED or MERGED for at least <min-age-days>, and every
# verdict head must exist in $repo.
assess() {
    local e f line word vpr vhead p st state closed ce h
    keep="" files=() prs="" heads="" newest_iso=""
    local newest_close=0
    for e in "$2"/* "$2"/.[!.]*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        if [ -f "$e" ] && [ ! -L "$e" ] && [ "${e##*.}" = md ]; then files+=("$e")
        elif [ "$3" = 1 ]; then keep="holds a non-verdict entry (${e##*/})"; return 0; fi
    done
    [ "${#files[@]}" -gt 0 ] || { keep="empty"; return 0; }
    for f in "${files[@]}"; do
        line=$(tr -d '\r' < "$f" | awk '/^## Verdict[[:space:]]*$/ { p = 1; next } p && NF { print; exit }')
        word=$(printf '%s\n' "$line" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `[0-9a-f]{40}`\.?$/\1/p')
        vhead=$(printf '%s\n' "$line" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `([0-9a-f]{40})`\.?$/\2/p')
        vpr=$(tr -d '\r' < "$f" | awk '/^## Verdict[[:space:]]*$/ { p = 1; next } p && NF && !n { n = NR + 2; next } n && NR == n { print; exit }' \
            | sed -nE 's/^pr: ([1-9][0-9]*)$/\1/p')
        if [ -z "$word" ]; then keep="${f##*/} has no parsable verdict line"; return 0; fi
        if [ -z "$vpr" ]; then keep="${f##*/} has no pr: line"; return 0; fi
        case " $prs " in *" $vpr "*) ;; *) prs="$prs $vpr" ;; esac
        case " $heads " in *" $vhead "*) ;; *) heads="$heads $vhead" ;; esac
    done
    for p in $prs; do
        pr_state "$p" || { keep="PR $p lookup failed"; return 0; }
        st="$PRST"
        state="${st%% *}"
        closed="${st#* }"
        [ "$closed" = "$st" ] && closed=""
        case "$state" in
            CLOSED|MERGED) ;;
            OPEN) keep="PR $p is open"; return 0 ;;
            *) keep="PR $p state unknown ('$state')"; return 0 ;;
        esac
        if [ "$4" -gt 0 ]; then
            ce=$(iso_epoch "$closed") || { keep="PR $p has no readable close time"; return 0; }
            if [ $((ce + $4 * 86400)) -gt "$now" ]; then keep="PR $p closed inside the ${4}-day age"; return 0; fi
            [ "$ce" -gt "$newest_close" ] && { newest_close=$ce; newest_iso="$closed"; }
        fi
    done
    for h in $heads; do
        head_in_repo "$h" || { keep="head ${h:0:12} not found in ${repo:-the target repo}, PR number not proven to be this repo's"; return 0; }
    done
    return 0
}

valid_qid() {
    case "$1" in [A-Za-z0-9]*) ;; *) return 1 ;; esac
    case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac
}

if [ "$verb" = prune ]; then
    cache="${cache:-${HOME:-}/.cache/himmel/verdicts}"
    [ -d "$cache" ] || { echo "verdict-retention: no cache dir at $cache - nothing to prune"; exit 0; }
    phys_cache=$(cd "$cache" && pwd -P) || exit 2
    hroot=$(handover_root) && [ -d "$hroot" ] || { echo "verdict-retention: cannot resolve the handover root; refusing to prune" >&2; exit 3; }
    phys_root=$(cd "$hroot" && pwd -P) || exit 3
    case "$phys_cache/" in
        "$phys_root"/*) echo "verdict-retention: refusing - $cache is inside the handover root $hroot; this pruner never touches vault verdicts" >&2; exit 2 ;;
    esac
    rc=0 n=0 kept=0 kb_total=0 recent=""
    for d in "$cache"/*/; do
        d="${d%/}"
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        q="${d##*/}"
        valid_qid "$q" || continue
        recent=$(find "$d" -mtime "-$days" -print -quit) || { echo "FAILED $q: cannot scan for recent files" >&2; rc=1; continue; }
        [ -z "$recent" ] || continue
        # Only scratch whose PR is provably closed goes: a qid already in the
        # ledger was archived on that proof; a live verdict dir is assessed now.
        if [ -d "$vdir/$q" ] && [ ! -L "$vdir/$q" ]; then
            assess "$q" "$vdir/$q" 0 0
        elif [ -f "$ledger" ] && grep -qF "\"qid\":\"$q\"" "$ledger"; then
            keep=""
        else
            keep="no verdict dir or ledger row names its PR"
        fi
        if [ -n "$keep" ]; then
            echo "KEEP $q $keep"
            kept=$((kept + 1))
            continue
        fi
        kb=$(du -sk "$d" | awk '{print $1}')
        kb_total=$((kb_total + ${kb:-0}))
        n=$((n + 1))
        if [ "$apply" = 1 ]; then
            if rm -rf -- "$d"; then echo "PRUNED $q ${kb:-?}K"; else echo "FAILED $q" >&2; rc=1; fi
        else
            echo "PRUNE $q ${kb:-?}K"
        fi
    done
    echo "verdict-retention: prune $n dir(s), ${kb_total}K, kept $kept$([ "$apply" = 1 ] || echo ' (dry run; --apply removes)')"
    exit "$rc"
fi

# ---- archive ---------------------------------------------------------------
rc=0 moved=0 kept=0
for d in "$vdir"/*/; do
    d="${d%/}"
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    q="${d##*/}"
    valid_qid "$q" || continue

    assess "$q" "$d" 1 "$days"
    if [ -n "$keep" ]; then
        echo "KEEP $q $keep"
        kept=$((kept + 1))
        continue
    fi

    month=$(printf '%s' "$newest_iso" | cut -c1-7)
    rel="archive/$month/verdicts/$q"
    echo "MOVE $q pr=${prs# } closed=$newest_iso -> $rel"
    moved=$((moved + 1))
    [ "$apply" = 1 ] || continue

    if [ -e "$bucket/$rel" ]; then echo "FAILED $q: $rel already exists" >&2; rc=1; continue; fi
    for f in "${files[@]}"; do
        name="${f##*/}"
        ap="$rel/$name"
        sha=$(sha256_of "$f") || { echo "FAILED $q: cannot hash $name" >&2; rc=1; continue 2; }
        if [ -f "$ledger" ] && grep -F "\"sha256\":\"$sha\"" "$ledger" | grep -qF "\"archive_path\":\"$ap\""; then continue; fi
        line=$(tr -d '\r' < "$f" | awk '/^## Verdict[[:space:]]*$/ { p = 1; next } p && NF { print; exit }')
        row=$(jq -cn \
            --arg qid "$q" \
            --arg pr "$(tr -d '\r' < "$f" | awk '/^## Verdict[[:space:]]*$/ { p = 1; next } p && NF && !n { n = NR + 2; next } n && NR == n { print; exit }' | sed -nE 's/^pr: ([1-9][0-9]*)$/\1/p')" \
            --arg head "$(printf '%s\n' "$line" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `([0-9a-f]{40})`\.?$/\2/p')" \
            --arg verdict "$(printf '%s\n' "$line" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `[0-9a-f]{40}`\.?$/\1/p')" \
            --arg model "$(sed -nE 's/^model: (.*)$/\1/p' "$f" | head -1)" \
            --arg written_at "$(sed -nE 's/^written-at: (.*)$/\1/p' "$f" | head -1)" \
            --arg sha256 "$sha" \
            --arg closed_at "$newest_iso" \
            --arg archive_path "$ap" \
            '{qid: $qid, pr: ($pr | tonumber), head: $head, verdict: $verdict, model: $model, written_at: $written_at, sha256: $sha256, closed_at: $closed_at, archive_path: $archive_path}') \
            && printf '%s\n' "$row" >> "$ledger" || { echo "FAILED $q: ledger row for $name" >&2; rc=1; continue 2; }
    done
    mkdir -p "$bucket/archive/$month/verdicts" || { rc=1; continue; }
    if git -C "$bucket" ls-files --error-unmatch -- "verdicts/$q" >/dev/null 2>&1; then
        git -C "$bucket" mv -- "verdicts/$q" "$rel" || { echo "FAILED $q: git mv" >&2; rc=1; }
    else
        mv -- "$d" "$bucket/$rel" || { echo "FAILED $q: mv" >&2; rc=1; }
    fi
done
echo "verdict-retention: archive $moved dir(s), kept $kept$([ "$apply" = 1 ] || echo ' (dry run; --apply moves)')"
exit "$rc"
