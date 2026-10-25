#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/review-rounds.sh - review rounds per merged PR
# for a [--since, --until) window, and their per-day distribution.
#
# A round is one counted review-round.sh start on the PR's head branch. That
# script keeps the count in <git common dir>/cr-review-rounds/<branch>.round, so
# the count is read from that record, never from transcripts. A merged PR whose
# branch has no (or a non-numeric) counter is unmeasured: shown as `-`, kept out
# of the distribution and counted apart.
#
# Default output, one line per UTC merge day:
#   <day> prs=<n> median=<m> p90=<p> max=<x> top=#<pr>:<rounds>,... unmeasured=<k>
# --tsv prints the per-PR rows instead:  <day> <pr> <branch> <rounds|->
#
# ponytail: the counter lives on the station that ran the reviews, so a PR
# reviewed from another checkout reads as unmeasured here; upgrade path is a
# rounds= field on the PR's leg-burn line once leg-burn.sh owns the count.
#
# Platform guard: no .ps1 twin, by design, same as the rest of this
# directory - POSIX bash 3.2+ plus jq and gh.
#
# Usage: review-rounds.sh --since <ISO8601> [--until <ISO8601>] [--repo <owner/repo>] [--tsv]
# Seams: REVIEW_ROUNDS_GH (gh), REVIEW_ROUNDS_STATE_DIR (the counter dir).
set -u

usage() { echo "usage: review-rounds.sh --since <ISO8601> [--until <ISO8601>] [--repo <owner/repo>] [--tsv]" >&2; }

SINCE=""; UNTIL=""; TSV=0
REPO="yotamleo/Himmel"  # env-literal-ok: the scorecard default, same as merged-count.sh
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:?--since needs a value}"; shift 2 ;;
        --until) UNTIL="${2:?--until needs a value}"; shift 2 ;;
        --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
        --tsv) TSV=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "review-rounds: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[ -n "$SINCE" ] || { usage; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../lib/git-clean.sh
. "$HERE/../../../lib/git-clean.sh" || exit 1
# shellcheck source=../../../lib/prim.sh
. "$HERE/../../../lib/prim.sh" || exit 1
git_env_scrub
GH="${REVIEW_ROUNDS_GH:-gh}"
STATE_DIR="${REVIEW_ROUNDS_STATE_DIR:-}"
if [ -z "$STATE_DIR" ]; then
    common="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
        || { echo "review-rounds: cannot resolve the git common directory" >&2; exit 1; }
    STATE_DIR="$common/cr-review-rounds"
fi

# GNU `date -d` first; BSD/macOS `date -j -f` fallback (same convention as
# merged-count.sh's to_epoch()).
to_epoch() {
    date -d "$1" +%s 2>/dev/null && return 0  # gnu-ok: BSD/macOS fallback on the next line
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(printf '%s' "$1" | sed 's/\.[0-9]*Z$/Z/')" +%s 2>/dev/null
}
SINCE_EPOCH=$(to_epoch "$SINCE") || { echo "review-rounds: bad --since: $SINCE" >&2; exit 2; }
UNTIL_EPOCH=9999999999
if [ -n "$UNTIL" ]; then
    UNTIL_EPOCH=$(to_epoch "$UNTIL") || { echo "review-rounds: bad --until: $UNTIL" >&2; exit 2; }
fi

RUN=$(tmpdir) || { echo "review-rounds: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$RUN"' EXIT

"$GH" pr list -R "$REPO" --state merged --limit 1000 --json number,headRefName,mergedAt > "$RUN/prs.json" 2>/dev/null \
    || { echo "review-rounds: gh pr list failed" >&2; exit 1; }
jq -r --argjson s "$SINCE_EPOCH" --argjson u "$UNTIL_EPOCH" '
  [.[] | . + {t: (.mergedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)}
       | select(.t >= $s and .t < $u)] | sort_by(.t)[]
  | [(.mergedAt[0:10]), (.number | tostring), .headRefName] | @tsv' "$RUN/prs.json" > "$RUN/window.tsv" \
    || { echo "review-rounds: could not parse gh pr list output" >&2; exit 1; }

[ -d "$STATE_DIR" ] || echo "review-rounds: no counter dir at $STATE_DIR - every PR reads as unmeasured" >&2

: > "$RUN/rows.tsv"
while IFS="$(printf '\t')" read -r day pr branch; do
    rounds="-"
    case "$branch" in
        *..*) ;;
        *)
            if [ -f "$STATE_DIR/$branch.round" ]; then
                n="$(tr -d '[:space:]' < "$STATE_DIR/$branch.round")"
                case "$n" in ''|*[!0-9]*) ;; *) rounds="$n" ;; esac
            fi ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$day" "$pr" "$branch" "$rounds" >> "$RUN/rows.tsv"
done < "$RUN/window.tsv"

if [ "$TSV" -eq 1 ]; then
    cat "$RUN/rows.tsv"
    exit 0
fi

awk -F'\t' '
$4 == "-" { days[$1] = 1; um[$1]++; next }
{
    days[$1] = 1; k = ++n[$1]
    # insertion sort by rounds, then PR number, ascending
    i = k
    while (i > 1 && (r[$1, i-1] + 0 > $4 + 0 || (r[$1, i-1] + 0 == $4 + 0 && p[$1, i-1] + 0 > $2 + 0))) {
        r[$1, i] = r[$1, i-1]; p[$1, i] = p[$1, i-1]; i--
    }
    r[$1, i] = $4; p[$1, i] = $2
}
END {
    for (d in days) {
        c = n[d] + 0
        if (c == 0) {
            printf "%s\tprs=0\tmedian=-\tp90=-\tmax=-\ttop=-\tunmeasured=%d\n", d, um[d]
            continue
        }
        med = (c % 2) ? r[d, (c + 1) / 2] : (r[d, c / 2] + r[d, c / 2 + 1]) / 2
        idx = int(0.9 * c); if (idx < 0.9 * c) idx++
        top = ""
        for (i = c; i >= 1 && i > c - 3; i--) top = top (top == "" ? "" : ",") "#" p[d, i] ":" r[d, i]
        printf "%s\tprs=%d\tmedian=%g\tp90=%d\tmax=%d\ttop=%s\tunmeasured=%d\n", d, c, med, r[d, idx], r[d, c], top, um[d]
    }
}' "$RUN/rows.tsv" | sort
