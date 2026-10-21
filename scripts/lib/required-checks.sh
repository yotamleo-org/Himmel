#!/usr/bin/env bash
# scripts/lib/required-checks.sh — SOURCED. The pure required-check classifier:
# no gh call and no global state; input comes in arguments or on stdin.
# check-ci.sh and the ticket-status derive (scripts/lib/ticket-status.sh) both
# source it, so red and green mean the same thing to the merge gate and to the
# Jira status sync. The readers (required_set, _required_rows, _producer_rows)
# stay with each caller.
#
# bash 3.2-safe.

# _required_normalize — "<name>\t<producer id>" in, the same out. An id of -1 is
# classic protection's "any source", so it is no id. When a name
# carries an id anywhere, its id-less rows drop: a producer-pinned requirement is
# stricter, and the deprecated classic `contexts` list repeats every name id-less,
# which must not weaken the pinned one back to a name-only match.
_required_normalize() {
    awk -F'\t' '
        { n[NR] = $1; i[NR] = ($2 == "-1" ? "" : $2); if (i[NR] != "") pinned[$1] = 1 }
        END { for (j = 1; j <= NR; j++) if (i[j] != "" || !(n[j] in pinned)) print n[j] "\t" i[j] }' | sort -u
}

# _has_producer_ids <reqs> — true when any required entry names a producer.
_has_producer_ids() {
    printf '%s\n' "$1" | awk -F'\t' '$2 != "" { f = 1 } END { exit !f }'
}

# _required_status <reqs> <rows> <producer rows> — "<fail|pending|seen|missing>\t<label>"
# per required check. A cancelled required check blocks a merge exactly as a
# failed one does. An entry with no id matches by name over <rows> — already
# latest-only, since `gh pr checks` reflects GitHub's own rollup, which judges
# only the latest check suite per name. One with an id matches name AND app id
# over <producer rows> — the raw check-runs API, which lists every run ever
# created for the sha — so only the LATEST matching run is judged, not any run
# that ever failed: a re-run or a close/reopen on an unchanged
# head must be able to clear an earlier red, the same as GitHub's own merge
# gate does. "Latest" is decided by `id` alone (always present, assigned
# strictly in creation order by GitHub), not `started_at`: a queued run can
# have a null started_at, and comparing timestamps with an id-only fallback
# per pair is non-transitive — a null-started_at row sitting between two
# timestamped rows in the API's (unordered) response array could make an
# older real timestamp beat a newer one, depending on row order. `id` alone
# is a single total order with no such gap. On an exact id tie (the same run
# read twice across a --paginate page boundary), the completed row wins over
# a pending duplicate, in either array order. If the latest matching run is
# itself still pending, the label is "pending", never folded into "seen" —
# a required check that has not settled yet must not read as satisfied.
_required_status() {
    local name id
    while IFS=$'\t' read -r name id; do
        [ -n "$name" ] || continue
        if [ -z "$id" ]; then
            printf '%s\t%s\n' "$(printf '%s\n' "$2" | awk -F'\t' -v n="$name" \
                '$2 == n { f = 1; if ($1 == "fail" || $1 == "cancel") bad = 1 } END { print (bad ? "fail" : (f ? "seen" : "missing")) }')" "$name"
        else
            printf '%s\t%s\n' "$(printf '%s\n' "$3" | awk -F'\t' -v n="$name" -v a="$id" '
                $2 == n && $3 == a {
                    f = 1
                    if (best_id == "" || $5 + 0 > best_id + 0 || ($5 + 0 == best_id + 0 && best_bucket == "pending" && $1 != "pending")) { best_id = $5; best_bucket = $1 }
                }
                END { print (f ? ((best_bucket == "fail" || best_bucket == "cancel") ? "fail" : (best_bucket == "pending" ? "pending" : "seen")) : "missing") }')" "$name (app $id)"
        fi
    done <<<"$1"
}

# _join_by_status <status> <required status rows> — the labels with <status>, comma-joined.
_join_by_status() { printf '%s\n' "$2" | awk -F'\t' -v s="$1" '$1 == s { print $2 }' | paste -sd, - | sed 's/,/, /g'; }
