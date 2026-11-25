#!/usr/bin/env bash
# chief-duty-sweep.sh — one line per chief action still owed, nothing when none is.
#
#   chief-duty-sweep.sh --doc <chief doc> --workers-from <fleet manifest> [--bucket <dir>]
#
# This reads the fleet manifest, the worker docs' Results tails, the open PRs, the CI runs cache, the
# verdicts, the Jira mirror (through the dispatcher's dispositions) and owed.jsonl, and prints
#   DUTY <kind> <id> :: <why> :: next: <command>
# for each of seven kinds:
#   go-owed        a standing READY (no FINDING, HALTED, BLOCKED, PARKED-*, WRAPPED or MERGED after
#                  it) at the PR's current head, with no GO file
#   merge-owed     the GO file exists (10 min old or more), the PR is open at that head, and the
#                  worker's lane is not native (a native worker merges itself)
#   answer-owed    a BLOCKED, or a FINDING, with no RESOLVED, READY, HALTED, WRAPPED or MERGED after it
#   ci-masked      an open non-draft same-repo PR to main whose newest CI run at its head is cancelled
#                  or failed while an older CI run at that head succeeded
#   judge-owed     a standing READY at a head with no verdict, where the PR has a verdict at another
#                  head and delta-class.sh says the push needs a judge (judge-running once its spec
#                  was dispatched within 60 min)
#   dispatch-owed  an operator-directed To Do ticket the dispatcher lists LOCAL, CLOUD, DESIGN or SERIES
#   owed-stale     an owed.jsonl row open for OWED_STALE_SECS (default 14400) or more
# A clean fleet prints nothing and exits 0. An input that cannot be read prints one
#   DUTY? <source> unread
# line and the kinds that depend on it are left out: an unread input never adds an item.
#
# Two acts are done here, both reserved in a file before they happen so a kill never repeats one:
#   DUTY-RAN ci-masked <pr>@<head7> rerun <run id> rc=<rc>
#       one `gh run rerun <id> --failed` for a cancelled first-attempt run that masks a green one;
#       never for a failure, an attempt 2 or more, a draft, a fork, a base other than main, a run
#       already tried, within 60 min of a cancel-runs.sh stamp, more than 2 per sweep or 10 per hour;
#       CHIEF_DUTY_AUTORUN=0 turns it off.
#   <state>/chief-duty-judge/<pr>-<head7>.json
#       a spec for gen-judge-brief.py (--dispatch-json), written once and never rewritten.
# It writes nothing else: no GO, verdict, message, bucket file or Jira row.
#
# Seams (tests): CHIEF_DUTY_SWEEP_NOW (epoch), _PRS (a `gh pr list` JSON file), _RUNS (the CI runs
# cache), _GO_ROOT, _MIRROR, _DISPOSITIONS (dispatcher output), _GH, _DELTA (delta-class.sh), _OWE,
# TICK_STATE_DIR, CANCEL_RUNS_PACE_STATE.
# Exit 0, or 2 on a usage error. Linux-only kit; bash 3.2-safe apart from flock.
# shellcheck disable=SC2031  # bucket, anchor and gh_bin are assigned once in the main shell; the pipelines below only read them
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../lib/git-clean.sh
. "$REPO/scripts/lib/git-clean.sh" || exit 2
git_env_scrub

usage() { echo "usage: chief-duty-sweep.sh --doc <chief doc> --workers-from <fleet manifest> [--bucket <dir>]" >&2; exit 2; }
doc="" from="" bucket=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc) [ "$#" -ge 2 ] || usage; doc="$2"; shift 2 ;;
        --workers-from) [ "$#" -ge 2 ] || usage; from="$2"; shift 2 ;;
        --bucket) [ "$#" -ge 2 ] || usage; bucket="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$doc" ] && [ -n "$from" ] || usage
[ -n "$bucket" ] || bucket="$(dirname "$doc")"
if [ -d "$bucket" ]; then bucket="$(cd "$bucket" && pwd)"; fi
q() { printf '%q' "$1"; }

now="${CHIEF_DUTY_SWEEP_NOW:-$(date +%s)}"
state="${TICK_STATE_DIR:-${HOME:-/tmp}/.himmel/state}"
mkdir -p "$state" 2>/dev/null || true
gh_bin="${CHIEF_DUTY_SWEEP_GH:-gh}"
delta_bin="${CHIEF_DUTY_SWEEP_DELTA:-$HERE/delta-class.sh}"
owe_bin="${CHIEF_DUTY_SWEEP_OWE:-$HERE/owe.sh}"
kit="$HERE"
anchor="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && anchor="${anchor%/.git}" || anchor="$REPO"  # swallow-ok: no repo means this checkout stands in for the anchor in the printed commands

items=""
ran=""
add() { items="$items$1"$'\n'; }
unread() { add "DUTY? $1 unread"; }
short() { printf '%s' "${1:0:7}"; }

legs=$(jq -r '(.legs // [])[]? | [(.label // ""), (.doc // ""), (.lane // "unknown")] | @tsv' "$from" 2>/dev/null) || legs=""  # swallow-ok: an unreadable manifest reads as no legs, named below
if ! jq -e '.legs | type == "array" and all(.[]; type == "object")' "$from" >/dev/null 2>&1; then
    unread "fleet"
    legs=""
fi

prs_ok=0; prs_tsv=""
read_prs() {
    local raw="" cache="$state/chief-duty-sweep-prs.json" age
    if [ -n "${CHIEF_DUTY_SWEEP_PRS:-}" ]; then
        raw=$(cat "$CHIEF_DUTY_SWEEP_PRS" 2>/dev/null) || return 1  # read-sink-ok: a test seam set by the invoking process, a JSON fixture read once; swallow-ok: an unreadable seam file is an unread input
    else
        if [ -s "$cache" ]; then
            age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))  # gnu-ok: Linux-only kit; swallow-ok: an unreadable cache reads as old, so the list is read live
            [ "$age" -lt 300 ] && raw=$(cat "$cache" 2>/dev/null)  # swallow-ok: a failed cache read falls through to a live read
        fi
        if [ -z "$raw" ]; then
            raw=$(cd "$REPO" && timeout -k 2 30 "$gh_bin" pr list --limit 200 --json number,headRefName,headRefOid,isDraft,isCrossRepository,baseRefName 2>/dev/null) || return 1  # swallow-ok: a failed read is an unread input
            ( . "$REPO/scripts/lib/prim.sh" && printf '%s\n' "$raw" | atomic_write "$cache" ) 2>/dev/null
        fi
    fi
    printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
    prs_tsv=$(printf '%s' "$raw" | jq -r '.[] | [.number, .headRefName, .headRefOid, .isDraft, .isCrossRepository, .baseRefName] | @tsv' 2>/dev/null) || return 1  # swallow-ok: a parse failure is an unread input
    return 0
}
if read_prs; then prs_ok=1; else unread "prs"; fi
pr_field() {
    printf '%s\n' "$prs_tsv" | awk -F'\t' -v p="$1" -v c="$2" '$1 == p { print $c; exit }'
}

doc_state() {
    local body
    body=$(sed -n '/^## Results/,$p' "$1" 2>/dev/null)  # swallow-ok: an unreadable doc is named by the caller before this runs
    [ -n "$body" ] || body=$(sed -n 'p' "$1" 2>/dev/null)  # swallow-ok: a doc with no Results heading is scanned whole
    printf '%s\n' "$body" | sed -nE '/^- /p' | awk '
        function marker(s,   m) {
            if (match(s, /^- ([0-9]{1,2}:[0-9]{2}[ \t]+)?(\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|PARKED-[A-Z]+|RESUMED|MERGED)([^A-Za-z0-9_]|$)/)) {
                m = substr(s, RSTART, RLENGTH); sub(/^- ([0-9]{1,2}:[0-9]{2}[ \t]+)?(\*\*)?/, "", m); sub(/[^A-Za-z0-9-].*$/, "", m); return m
            }
            return ""
        }
        { m = marker($0) }
        m == "READY" {
            rp = ""; rh = ""
            if (match($0, /READY[ \t]+[0-9]+[ \t]+[0-9a-f]{40}/)) { split(substr($0, RSTART, RLENGTH), a, /[ \t]+/); rp = a[2]; rh = a[3] }
            ready_pr = rp; ready_head = rh; ask = ""; next
        }
        m == "LIVE" && match($0, /holding at READY[ \t]+[0-9]+[ \t]+[0-9a-f]{40}/) { split(substr($0, RSTART, RLENGTH), a, /[ \t]+/); ready_pr = a[4]; ready_head = a[5]; next }
        m == "BLOCKED" || m == "FINDING" { ask = m; ready_pr = ""; ready_head = ""; next }
        m == "HALTED" || m == "WRAPPED" || m == "MERGED" { ask = ""; ready_pr = ""; ready_head = ""; next }
        m ~ /^PARKED/ { ready_pr = ""; ready_head = ""; next }
        m == "RESOLVED" { ask = ""; next }
        END {
            if (ready_pr != "") printf "ready %s %s\n", ready_pr, ready_head
            if (ask != "") printf "ask %s\n", ask
        }'
}

go_root="${CHIEF_DUTY_SWEEP_GO_ROOT:-}"
if [ -z "$go_root" ]; then
    go_root=$( . "$REPO/scripts/lib/handover-path.sh" 2>/dev/null && . "$REPO/scripts/lib/go-gate.sh" 2>/dev/null && go_resolve_root "$REPO" 2>/dev/null ) || go_root=""  # swallow-ok: an unresolved GO root is reported as unread below, and go-owed and merge-owed are left out
fi
[ -n "$go_root" ] || unread "go-root"

verdict_heads() {
    local f q h
    [ -d "$bucket/verdicts" ] || return 0
    grep -rlE --include='*.md' "^pr: $1\$" "$bucket/verdicts" 2>/dev/null | while IFS= read -r f; do
        q="${f#"$bucket"/verdicts/}"; q="${q%%/*}"
        case "$q" in go-pr-*) continue ;; esac
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
        h=$(sed -nE 's/.*for head `([0-9a-f]{40})`.*/\1/p' "$f" 2>/dev/null | head -n 1)  # swallow-ok: a record that names no head is skipped
        [ -n "$h" ] && printf '%s %s %s\n' "$q" "$h" "$f"
    done
}

judge_prs=""
legitems=""
while IFS=$'\t' read -r label ldoc lane; do
    [ -n "$label" ] || continue
    { [ -f "$ldoc" ] && [ -r "$ldoc" ]; } || { add "DUTY? worker $label unread"; continue; }
    st=$(doc_state "$ldoc")
    ask=$(printf '%s\n' "$st" | sed -n 's/^ask //p')
    rd=$(printf '%s\n' "$st" | sed -n 's/^ready //p')
    if [ -n "$ask" ]; then
        legitems="$legitems$(printf 'DUTY answer-owed %s :: %s is the newest open ask in %s :: next: read %s, then reply by SendMessage, the bus, or t3-send.sh for a t3 lane' "$label" "$ask" "$(basename "$ldoc")" "$(q "$ldoc")")"$'\n'
    fi
    [ -n "$rd" ] && [ "$prs_ok" = 1 ] || continue
    pr="${rd%% *}"; head="${rd#* }"
    [ "$(pr_field "$pr" 3)" = "$head" ] || continue
    id="$pr@$(short "$head")"
    gofile="$go_root/.locks/go/$pr.$head"
    if [ -n "$go_root" ] && [ -e "$gofile" ]; then
        [ "$lane" != native ] || continue
        gm=$(stat -c %Y "$gofile" 2>/dev/null) || continue  # gnu-ok: Linux-only kit; swallow-ok: an unreadable GO file reads as not there
        age=$(( now - gm )); [ "$age" -ge 0 ] || age=0
        [ "$age" -ge 600 ] || continue
        flag=""; grep -qiE '^>? ?\*{0,2}completes[ -]ticket:?\*{0,2} *yes' "$ldoc" 2>/dev/null && flag=" --jira-transition"
        legitems="$legitems$(printf 'DUTY merge-owed %s :: GO file %sm old, PR open at this head, lane %s so the chief merges :: next: bash %s/scripts/handover/merge-on-green.sh %s%s --worker-doc %s --go %s' "$id" "$((age / 60))" "$lane" "$(q "$anchor")" "$pr" "$flag" "$(q "$ldoc")" "$(q "$gofile")")"$'\n'
        continue
    fi
    [ -n "$go_root" ] || continue
    vh=$(verdict_heads "$pr")
    if [ -n "$vh" ] && ! printf '%s\n' "$vh" | awk -v h="$head" '$2 == h { f = 1 } END { exit !f }'; then
        newest=$(printf '%s\n' "$vh" | while read -r q h f; do printf '%s %s %s %s\n' "$(stat -c %Y "$f" 2>/dev/null || echo 0)" "$q" "$h" "$f"; done | sort -rn | head -n 1)  # gnu-ok: Linux-only kit; swallow-ok: an unreadable record sorts last
        jq_q=$(printf '%s' "$newest" | cut -d' ' -f2); jh=$(printf '%s' "$newest" | cut -d' ' -f3); jf=$(printf '%s' "$newest" | cut -d' ' -f4-)
        dj=$(sed -nE 's/^delta-judged: ([0-9a-f]{40})\r?$/\1/p' "$jf" 2>/dev/null | head -n 1)  # swallow-ok: a record with no delta-judged line is a real record
        noop_open=0
        if [ -n "$dj" ]; then
            real=$(printf '%s\n' "$vh" | awk -v d="$dj" '$2 == d { print; exit }')
            if [ -n "$real" ]; then
                jq_q=$(printf '%s' "$real" | cut -d' ' -f1); jh="$dj"; jf=$(printf '%s' "$real" | cut -d' ' -f3-)
            else
                noop_open=1
            fi
        fi
        if [ "$noop_open" = 1 ]; then
            cls=trust
        elif [ -z "${CHIEF_DUTY_SWEEP_DELTA:-}" ] && ! { git -C "$REPO" cat-file -e "$jh^{commit}" && git -C "$REPO" cat-file -e "$head^{commit}"; } 2>/dev/null; then
            cls="?"
        else
            cls=$(cd "$REPO" && timeout -k 1 5 "$delta_bin" --verdict-file "$jf" "$jh" "$head" 2>/dev/null | head -n 1) || cls=""  # swallow-ok: a failed call fails closed to trust below
            case "$cls" in none|finding|trust) ;; *) cls=trust ;; esac
        fi
        case "$cls" in
            none) ;;
            "?")
                judge_prs="$judge_prs $pr"
                legitems="$legitems$(printf 'DUTY judge-owed %s :: judge-pending: a head is not in this checkout, so the delta class is unknown :: next: git -C %s fetch origin, then bash %s/delta-class.sh --qid %s %s %s' "$id" "$(q "$anchor")" "$(q "$kit")" "$jq_q" "$jh" "$head")"$'\n'
                continue ;;
            *)
                judge_prs="$judge_prs $pr"
                spec_dir="$state/chief-duty-judge"; spec="$spec_dir/$pr-$(short "$head").json"
                branch=$(pr_field "$pr" 2)
                tkt=$(printf '%s' "$branch" | sed -nE 's/.*[a-z]+-([0-9]+).*/\1/p' | head -n 1)
                tkt_key=""; [ -z "$tkt" ] || tkt_key="HIMMEL-$tkt"
                if [ -s "$spec.dispatched" ] || [ -e "$spec.dispatched" ]; then
                    dm=$(stat -c %Y "$spec.dispatched" 2>/dev/null || echo 0)  # gnu-ok: Linux-only kit; swallow-ok: an unreadable receipt reads as old, so the judge is owed again
                    if [ $(( $(date +%s) - dm )) -lt 3600 ]; then
                        legitems="$legitems$(printf 'DUTY judge-running %s :: a judge for this head was dispatched within 60 min :: next: wait for its verdict at this head' "$id")"$'\n'
                        continue
                    fi
                fi
                if [ ! -e "$spec" ] && [ -n "$tkt_key" ]; then
                    mkdir -p "$spec_dir" 2>/dev/null || true
                    ( flock -w 5 9 || exit 1  # prim-ok: Linux-only kit, flock serialises the qid pick and spec write
                      [ ! -e "$spec" ] || exit 0
                      sfx=""; for c in a b c d e f g h i j k l m n o p q r s t u v w x y z; do
                          [ ! -e "$bucket/verdicts/j$pr$c" ] || continue
                          ! grep -qs "\"qid\": \"j$pr$c\"" "$spec_dir"/*.json 2>/dev/null || continue
                          sfx="$c"; break
                      done
                      [ -n "$sfx" ] || exit 1
                      if [ "$cls" = finding ]; then
                          jq -n --arg q "j$pr$sfx" --arg t "$tkt_key" --arg pr "$pr" --arg h "$head" --arg j7 "$(short "$jh")" --arg h7 "$(short "$head")" \
                             --arg pq "$jq_q" --arg ad "$ldoc" --arg ev "$jf" \
                             '{qid:$q, ticket:$t, pr:($pr|tonumber), head:$h, author_doc:$ad, delta_class:"finding",
                               question:("Does the push " + $j7 + ".." + $h7 + " on PR " + $pr + " resolve the prior judge'"'"'s findings and add no new defect?"),
                               reason:("re-judge after a push (prior verdict " + $pq + " at " + $j7 + ", delta finding)"),
                               prior:("the prior judge " + $pq + " at " + $j7),
                               evidence:[{item:$ev, for:("the prior judge'"'"'s findings at " + $j7)}]}' > "$spec.tmp" \
                          && mv "$spec.tmp" "$spec"
                      else
                          jq -n --arg q "j$pr$sfx" --arg t "$tkt_key" --arg pr "$pr" --arg h "$head" --arg j7 "$(short "$jh")" --arg h7 "$(short "$head")" \
                             --arg pq "$jq_q" --arg ad "$ldoc" --arg ev "$jf" \
                             '{qid:$q, ticket:$t, pr:($pr|tonumber), head:$h, author_doc:$ad, delta_class:"trust",
                               question:("Does the push " + $j7 + ".." + $h7 + " on PR " + $pr + " resolve the prior judge'"'"'s findings and add no new defect?"),
                               reason:("re-judge after a push (prior verdict " + $pq + " at " + $j7 + ", delta touches a trust path or could not be classified)"),
                               prior:("the prior judge " + $pq + " at " + $j7),
                               tier:{category:"unverified-finding", reason:"the delta needs a judge and delta-class.sh printed trust"},
                               evidence:[{item:$ev, for:("the prior judge'"'"'s findings at " + $j7)}]}' > "$spec.tmp" \
                          && mv "$spec.tmp" "$spec"
                      fi
                    ) 9> "$state/chief-duty-qids.lock" 2>/dev/null || true
                fi
                if [ -s "$spec" ]; then
                    legitems="$legitems$(printf 'DUTY judge-owed %s :: the push after prior verdict %s at %s is a %s delta :: next: touch %s.dispatched, then python3 -I %s/gen-judge-brief.py %s --chief <your session> --dispatch-json and one Agent call with its output' "$id" "$jq_q" "$(short "$jh")" "$cls" "$(q "$spec")" "$(q "$kit")" "$(q "$spec")")"$'\n'
                else
                    legitems="$legitems$(printf 'DUTY judge-owed %s :: the push after prior verdict %s at %s is a %s delta (no spec: the branch names no ticket) :: next: write a judge spec by hand for PR %s' "$id" "$jq_q" "$(short "$jh")" "$cls" "$pr")"$'\n'
                fi
                continue ;;
        esac
    fi
    qkit=$(q "$kit")
    if [ "$lane" = native ]; then
        nx="bash $qkit/auto-go.sh --dry-run --doc $(q "$doc") --fleet $(q "$from") --worker $label $pr $head"
    else
        nx="bash $qkit/ready-check.sh $pr $head, then the judge or trust review, then bash $qkit/go.sh $pr $head (merges.md)"
    fi
    legitems="$legitems$(printf 'DUTY go-owed %s :: READY holds at the PR head with no GO file (lane %s) :: next: %s' "$id" "$lane" "$nx")"$'\n'
done <<< "$legs"
items="$items$legitems"

runs_file="${CHIEF_DUTY_SWEEP_RUNS:-$state/tick-ciguard-runs.json}"
runs_ok=0
if [ -f "$runs_file" ] && jq -e 'type == "array"' "$runs_file" >/dev/null 2>&1; then
    runs_ok=1
    if [ -z "${CHIEF_DUTY_SWEEP_RUNS:-}" ] && [ $(( $(date +%s) - $(stat -c %Y "$runs_file" 2>/dev/null || echo 0) )) -gt 1800 ]; then runs_ok=0; fi  # gnu-ok: Linux-only kit; swallow-ok: an unreadable cache reads as old, which is reported as unread
fi
if [ "$runs_ok" = 0 ]; then unread "ciguard"; fi
reruns="$state/chief-duty-sweep-reruns"
slug=$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')  # swallow-ok: no origin means no slug, so the rerun is held
if [ "$prs_ok" = 1 ] && [ "$runs_ok" = 1 ]; then
    rerun_count=0
    while IFS=$'\t' read -r pr branch head draft fork base; do
        [ -n "$pr" ] || continue
        [ "$draft" = false ] && [ "$fork" = false ] && [ "$base" = main ] || continue
        case "$pr" in ''|*[!0-9]*) continue ;; esac
        printf '%s' "$head" | grep -qE '^[0-9a-f]{40}$' || continue
        row=$(jq -r --arg h "$head" '
            [ .[] | select(.name == "CI" and .event == "pull_request" and .head_sha == $h) ] | sort_by(.created_at) as $r
            | if ($r | length) < 2 then empty
              else ($r[-1]) as $n
                | if $n.status == "completed" and ($n.conclusion == "cancelled" or $n.conclusion == "failure") and ([ $r[:-1][] | select(.status == "completed" and .conclusion == "success") ] | length) > 0
                  then [$n.id, $n.conclusion, ($n.run_attempt // 1)] | @tsv else empty end
              end' "$runs_file" 2>/dev/null) || continue
        [ -n "$row" ] || continue
        rid=$(printf '%s' "$row" | cut -f1); concl=$(printf '%s' "$row" | cut -f2); att=$(printf '%s' "$row" | cut -f3)
        case "$rid$att" in *[!0-9]*|'') continue ;; esac
        id="$pr@$(short "$head")"
        if [ "$concl" = failure ]; then
            add "$(printf 'DUTY ci-masked %s :: CI run %s failed at this head after an earlier green run :: next: gh run view %s --log-failed' "$id" "$rid" "$rid")"
            continue
        fi
        if [ "$att" -ge 2 ]; then
            add "$(printf 'DUTY ci-masked %s :: CI run %s cancelled x%s at this head after a green run :: next: gh run view %s --attempt %s; who cancelled: the cancel-runs pace file' "$id" "$rid" "$att" "$rid" "$att")"
            continue
        fi
        rc_line=$(awk -v r="$rid" '$1 == "result" && $2 == r { print $3 }' "$reruns" 2>/dev/null | tail -n 1)  # swallow-ok: no reruns file is no rerun
        if grep -qs "^reserve [0-9]* $pr $head $rid\$" "$reruns"; then
            if [ -z "$rc_line" ]; then
                add "$(printf 'DUTY ci-masked %s :: CI run %s cancelled at this head after a green run; a rerun is reserved with no result yet, outcome unknown :: next: gh run view %s, then gh run rerun %s -R %s if no rerun started' "$id" "$rid" "$rid" "$rid" "$slug")"
            elif [ "$rc_line" != 0 ]; then
                add "$(printf 'DUTY ci-masked %s :: CI run %s cancelled at this head after a green run; the rerun failed rc=%s :: next: gh run rerun %s -R %s' "$id" "$rid" "$rc_line" "$rid" "$slug")"
            else
                add "$(printf 'DUTY ci-masked %s :: CI run %s cancelled at this head after a green run; rerun sent :: next: gh run view %s once the rerun finishes' "$id" "$rid" "$rid")"
            fi
            continue
        fi
        hold=""
        [ "${CHIEF_DUTY_AUTORUN:-1}" != 0 ] || hold="autorun off"
        pace="${CANCEL_RUNS_PACE_STATE:-$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/cancel-runs-pace}"  # swallow-ok: no git dir means no pace file, so nothing is held back for a drain
        if [ -z "$hold" ] && [ -r "$pace" ]; then
            newest=$(awk '/^[0-9]+$/ && $1 > m { m = $1 } END { print m + 0 }' "$pace" 2>/dev/null)  # swallow-ok: an unreadable pace file holds nothing back
            if [ "${newest:-0}" -gt 0 ] && [ $(( now - newest )) -lt 3600 ]; then hold="drain $(( (now - newest) / 60 ))m ago"; fi
        fi
        [ -n "$hold" ] || [ -n "$slug" ] || hold="no repo slug"
        if [ -z "$hold" ] && [ "$rerun_count" -ge 2 ]; then hold="two reruns this sweep"; fi
        if [ -z "$hold" ]; then
            ( flock -w 5 9 || exit 3  # prim-ok: Linux-only kit, flock serialises the reserve row
              ! grep -qs "^reserve [0-9]* $pr $head $rid\$" "$reruns" || exit 6
              hour=$(awk -v n="$now" '$1 == "reserve" && $2 > n - 3600 { c++ } END { print c + 0 }' "$reruns" 2>/dev/null)  # swallow-ok: no reruns file counts zero reruns
              [ "${hour:-0}" -lt 10 ] || exit 4
              printf 'reserve %s %s %s %s\n' "$now" "$pr" "$head" "$rid" >> "$reruns" || exit 5
            ) 9> "$state/chief-duty-sweep.lock" 2>/dev/null
            lrc=$?
            case "$lrc" in
                0) ;;
                4) hold="hourly cap" ;;
                6)
                    add "$(printf 'DUTY ci-masked %s :: CI run %s cancelled at this head after a green run; a rerun is reserved by another sweep, outcome unknown :: next: gh run view %s once the rerun finishes' "$id" "$rid" "$rid")"
                    continue ;;
                *) hold="rerun lock busy" ;;
            esac
        fi
        if [ -n "$hold" ]; then
            add "$(printf 'DUTY ci-masked %s :: CI run %s cancelled at this head after a green run; held: %s :: next: gh run rerun %s --failed -R %s' "$id" "$rid" "$hold" "$rid" "$slug")"
            continue
        fi
        rerun_count=$((rerun_count + 1))
        timeout -k 1 10 "$gh_bin" run rerun "$rid" --failed -R "$slug" >/dev/null 2>&1; rrc=$?
        printf 'result %s %s\n' "$rid" "$rrc" >> "$reruns" 2>/dev/null || true
        ran="$ran$(printf 'DUTY-RAN ci-masked %s rerun %s rc=%s' "$id" "$rid" "$rrc")"$'\n'
        if [ "$rrc" = 0 ]; then
            add "$(printf 'DUTY ci-masked %s :: CI run %s cancelled at this head after a green run; rerun sent :: next: gh run view %s once the rerun finishes' "$id" "$rid" "$rid")"
        else
            add "$(printf 'DUTY ci-masked %s :: CI run %s cancelled at this head after a green run; the rerun failed rc=%s :: next: gh run rerun %s -R %s' "$id" "$rid" "$rrc" "$rid" "$slug")"
        fi
    done <<< "$prs_tsv"
fi

dispo=""
dispo_path="${CHIEF_DUTY_SWEEP_DISPOSITIONS:-}"
if [ -z "$dispo_path" ]; then
    cache_key=$(printf '%s\n%s\n' "$doc" "$from" | cksum | cut -d' ' -f1)
    cache="$state/chief-duty-sweep-dispositions-$cache_key.txt"
    if [ ! -s "$cache" ] || [ $(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) )) -gt 1800 ]; then  # gnu-ok: Linux-only kit; swallow-ok: an unreadable cache reads as old, so it is refreshed
        if mkdir "$state/chief-duty-sweep-pool-$cache_key.lock" 2>/dev/null; then  # prim-ok: Linux-only kit; one background refresh at a time, a dead one is dropped after 10 min below
            ( timeout -k 5 300 bash "$HERE/next-dispatchable.sh" --dispositions --doc "$doc" --workers-from "$from" > "$cache.tmp" 2>/dev/null && mv "$cache.tmp" "$cache"; rmdir "$state/chief-duty-sweep-pool-$cache_key.lock" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
            disown 2>/dev/null || true
        else
            [ -z "$(find "$state/chief-duty-sweep-pool-$cache_key.lock" -maxdepth 0 -mmin +10 2>/dev/null)" ] || rmdir "$state/chief-duty-sweep-pool-$cache_key.lock" 2>/dev/null  # swallow-ok: losing the race to another sweep is fine
        fi
    fi
    dispo_path="$cache"
fi
dispo=$(cat "$dispo_path" 2>/dev/null) || dispo=""  # swallow-ok: an unreadable copy reads as unread below
if [ -n "$dispo" ]; then
    dispo_age=$(( $(date +%s) - $(stat -c %Y "$dispo_path" 2>/dev/null || echo 0) ))  # gnu-ok: Linux-only kit; swallow-ok: an unreadable copy reads as old, which is unread below
    if [ "$dispo_age" -gt 1800 ] || printf '%s\n' "$dispo" | grep -qE 'open PRs unknown|core-check failed'; then dispo=""; fi
fi
[ -n "$dispo" ] || unread "pool"
if [ -n "$dispo" ]; then
    mirror="${CHIEF_DUTY_SWEEP_MIRROR:-}"
    if [ -z "$mirror" ]; then
        mirror=$( . "$REPO/scripts/lib/jira-project.sh" 2>/dev/null && jira_mirror_dir 2>/dev/null ) || mirror=""  # swallow-ok: no mirror dir reads as unread below
    fi
    if [ ! -d "$mirror" ]; then
        unread "mirror"
    else
        dispatch_lines=$(printf '%s\n' "$dispo" | sed -nE 's/^# disposition ([A-Z]+-[0-9]+) (listed (LOCAL|CLOUD|DESIGN|SERIES).*)$/\1 \2/p' | while read -r key rest; do
            mf="$mirror/$key.md"
            [ -f "$mf" ] || continue
            grep -qE '^status: "To Do"' "$mf" 2>/dev/null || continue
            grep -E '^labels:' "$mf" 2>/dev/null | grep -q '"operator-directed"' || continue
            printf 'DUTY dispatch-owed %s :: operator-directed To Do ticket, the dispatcher says %s :: next: bash %s/next-dispatchable.sh --doc %s --workers-from %s --why, then dispatch it\n' "$key" "$rest" "$(q "$kit")" "$(q "$doc")" "$(q "$from")"
        done)
        items="$items$dispatch_lines"$'\n'
    fi
fi

stale_secs="${OWED_STALE_SECS:-14400}"
case "$stale_secs" in ''|*[!0-9]*) stale_secs=14400 ;; esac
if [ -s "$bucket/owed.jsonl" ]; then
    if rows=$(bash "$owe_bin" list --bucket "$bucket" 2>/dev/null); then  # swallow-ok: a failed list is reported as unread in the else branch
        while IFS=$'\t' read -r oid okind oepoch _ _ otext; do
            [ -n "$oid" ] || continue
            case "$oepoch" in ''|*[!0-9]*) continue ;; esac
            [ $(( now - oepoch )) -ge "$stale_secs" ] || continue
            add "$(printf 'DUTY owed-stale %s :: %s row open %sh: %s :: next: bash %s/owe.sh close --bucket %s --id %s --key <the ticket, sha or decision that settles it>' "$oid" "$okind" "$(( (now - oepoch) / 3600 ))" "$otext" "$(q "$kit")" "$(q "$bucket")" "$oid")"
        done <<< "$rows"
    else
        unread "owed"
    fi
fi

out=$(printf '%s' "$items" | sed '/^$/d')
if [ -n "$out" ]; then
    printf '%s\n' "$out" | grep '^DUTY? ' | sort -u
    printf '%s\n' "$out" | grep '^DUTY ' | LC_ALL=C sort
fi
[ -z "$ran" ] || printf '%s' "$ran"
exit 0
