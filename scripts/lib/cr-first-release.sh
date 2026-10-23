#!/usr/bin/env bash
# cr-first-release.sh — release `ci:go` once the reviewers have passed.
#
# With the repository variable CI_GO_GATE=on, a pull request's heavy CI waits
# for the `ci:go` label; this releases it at the moment the reviewer gate
# passes at the PR head, from the events that change the answer (a verdict
# written, a thread resolved, a CodeRabbit read, the cheap run settling, the
# console tick) — no timer, no background process.
#
#   cr_first_release <pr> <head> [<owner/name>]
#     Quiet (no output, rc 0): switch off or unset, fork PR, PR closed or head
#       moved, head already released (a `ci:go` labeled event at or after the
#       head commit, or a heavy job that actually ran at the head).
#     CR-FIRST HOLD <reason> <age>        rc 1  (one line per reason)
#     CR-FIRST HOLD degraded (<why>)      rc 3  (a read failed; never releases)
#     CR-FIRST RELEASE <reason>           rc 0  (label removed then added)
#     CR-FIRST ERROR <what>               rc 2  (config error, label missing,
#                                                label write failed)
#     CR-FIRST ALERT <text>               once per (hard reviewer, reason)
#     CR-FIRST MANUAL-RELEASE <pr> <head> once per head: a `ci:go` event with
#                                         no line in the release ledger
#   Callers invoke it best-effort (`|| true`): it never fails a caller.
#   cr_first_switch_on <owner/name>   rc 0 only when CI_GO_GATE reads `on`; the
#     check-ci / ready-check / tick callers read it before anything else.
#
# The release is `scripts/lib/review-merge-gate.sh` cr_reviewer_gate with
# --release: the cheap run must be green first (ci-quick reported, no cheap
# job red), then every hard reviewer must pass at the head and a CodeRabbit
# review still in progress holds. The per-head ledger it writes is
# scripts/cr/cr-trigger-ledger.sh — NOT the CodeRabbit trigger ledger in
# scripts/lib/coderabbit-trigger-ledger.sh.
#
# A CodeRabbit status stuck in `pending` is probed once it is older than
# CR_FIRST_STUCK_AFTER_S (1800): a rate-limit reply, a CodeRabbit error
# comment, a status-page incident, or no CodeRabbit activity for
# CR_FIRST_PROGRESS_S (600) releases loudly, but only when that in-progress
# review is the one thing holding; a probe that cannot read holds.
# A manual `ci:go` while the cheap run is still going cancels that run
# (OQ3): label by hand only after the cheap side settled.
#
# Env: CR_FIRST_HEAVY_RE / CR_FIRST_CHEAP_RE (check-run name regexes),
# CR_FIRST_STATUS_URL (statuspage JSON), CR_FIRST_NOW (epoch seam for tests),
# CR_FIRST_LEDGER / CR_FIRST_ALERTS (see cr-trigger-ledger.sh),
# CR_FIRST_READONLY=1 (a passing gate prints `CR-FIRST PENDING-RELEASE ...` and
# writes no label and no ledger line: ready-check.sh is a read-only script),
# HIMMEL_CONSOLE_DOC (extra alert sink: a console doc named *-console.md).
#
# Sourceable (cr_first_release) and executable:
#   bash scripts/lib/cr-first-release.sh [--pr N] [--head SHA] [--repo OWNER/NAME]
# bash 3.2-safe; does not toggle set -e.

_CRF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CRF_LEDGER_CLI="$_CRF_DIR/../cr/cr-trigger-ledger.sh"
_CRF_APPEND="$_CRF_DIR/../handover/console-kit/append-results.sh"
if ! { [ -r "$_CRF_DIR/review-merge-gate.sh" ] && . "$_CRF_DIR/review-merge-gate.sh"; }; then
    echo "CR-FIRST ERROR cannot load review-merge-gate.sh" >&2
    (return 0 2>/dev/null) && return 1 || exit 1
fi

_crf_now() { printf '%s' "${CR_FIRST_NOW:-$(date +%s)}"; }
_crf_epoch() { jq -rn --arg t "$1" '$t | fromdateiso8601' 2>/dev/null; }
_crf_iso_now() { jq -rn --argjson t "$(_crf_now)" '$t | todate' 2>/dev/null; }
_crf_age() {
    local d=$(( $(_crf_now) - $1 ))
    [ "$d" -lt 0 ] && d=0
    if [ "$d" -lt 90 ]; then echo "${d}s"
    elif [ "$d" -lt 5400 ]; then echo "$((d / 60))m"
    elif [ "$d" -lt 129600 ]; then echo "$((d / 3600))h"
    else echo "$((d / 86400))d"; fi
}

# _crf_list <gh api path> — every page of a list endpoint as ONE json array.
_crf_list() {
    local raw
    raw=$(gh api --paginate "$1" </dev/null 2>/dev/null) || return 1
    printf '%s' "$raw" | jq -s 'if all(.[]; type == "array") then add // [] else error("not a list") end' 2>/dev/null
}

# _crf_reviewers_json <gate state line> <head> — the ledger's reviewers array.
_crf_reviewers_json() {
    local line="$1" head="$2" common scores
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git rev-parse --git-common-dir 2>/dev/null || true)
    scores=$(cat "$common/cr-critic-scores.jsonl" 2>/dev/null || true)
    [ -n "$line" ] || { echo '[]'; return 0; }
    line=$(printf '%s' "$line" | sed -E 's/^cr-reviewer-gate: PR #[0-9]+ head [^:]+: //')
    jq -nc --arg line "$line" --arg scores "$scores" --arg head "$head" '
      ($scores | split("\n") | map(fromjson? // empty)
        | map(. as $o | select($o.head != null and (($o.head | tostring | length) >= 7)
                              and ($head | startswith($o.head | tostring))))) as $rows
      | $line | split(" · ")
      | map(capture("^(?<slug>[^ ]+) (?<mode>[^ ]+) (?<disp>.*)$")?)
      | map(. as $r
            | ($rows | map(select(.model == $r.slug))) as $mine
            | { slug: $r.slug, mode: $r.mode, state: $r.disp,
                verdict: ($r.disp | sub("\\(.*$"; "")),
                findings: (if $r.slug == "coderabbit" then null
                           else ($mine | map(select(.kind == "finding")) | length) end),
                latency_s: (if $r.slug == "coderabbit" then null
                            else ($mine | map(select(.kind == "attempt" and .duration_secs != null)) | last | .duration_secs // null) end),
                cost_usd: null })' 2>/dev/null || echo '[]'
}

# _crf_alert <slug> <reason> <head> — one console alert per (slug, reason).
_crf_alert() {
    local slug="$1" reason="$2" text
    text="CR-FIRST ALERT hard reviewer $slug is unavailable ($reason): ci:go is held fleet-wide until it can review. Levers in order: restore the $slug lane; with operator ruling a critics.local.json overlay {\"slug\":\"$slug\",\"mode\":\"best-effort\"} or {\"slug\":\"$slug\",\"drop\":true}; a manual ci:go only if the head will be reviewed before merge."
    bash "$_CRF_LEDGER_CLI" alert-once "$slug|$reason" "$text" || return 0
    if [ -n "${HIMMEL_CONSOLE_DOC:-}" ] && [ -f "$HIMMEL_CONSOLE_DOC" ]; then
        bash "$_CRF_APPEND" "$HIMMEL_CONSOLE_DOC" "$text" >/dev/null 2>&1 || true
    fi
    return 0
}

# _crf_map_hold <gate HOLD line> — the short reason of one gate HOLD line.
_crf_map_hold() {
    local l="${1#HOLD: }" re
    case "$l" in
        "CodeRabbit review is in progress"*) echo "coderabbit in-progress"; return 0 ;;
    esac
    re='^([0-9]+) unresolved CodeRabbit review thread\(s\) on PR #[0-9]+ \[(.*)\]\. '
    if [[ "$l" =~ $re ]]; then echo "${BASH_REMATCH[1]} unresolved CodeRabbit thread(s) [${BASH_REMATCH[2]}]"; return 0; fi
    re='^([^ ]+) \(hard\) is not-yet-run at head '
    if [[ "$l" =~ $re ]]; then echo "${BASH_REMATCH[1]} not-yet-run"; return 0; fi
    re='^([^ ]+) \(hard\) is unavailable(\((.*)\))? at head '
    if [[ "$l" =~ $re ]]; then echo "hard-unavailable ${BASH_REMATCH[1]} ${BASH_REMATCH[3]:-unknown}"; return 0; fi
    re='^([^ ]+) has open finding\(s\) at head [^ ]+ of PR #[0-9]+: ([^ ]+) '
    if [[ "$l" =~ $re ]]; then echo "${BASH_REMATCH[1]} findings-open ${BASH_REMATCH[2]}"; return 0; fi
    re='^([^ ]+) \([a-z-]+\) cannot be read at head '
    if [[ "$l" =~ $re ]]; then echo "${BASH_REMATCH[1]} unreadable"; return 0; fi
    printf '%s\n' "${l:0:100}"
}

# _crf_stuck_probe <owner/name> <pr> <head> — OQ2 / decision 209. rc 0 and the
# cause in _CRF_STUCK when the pending CodeRabbit status is provably stuck;
# rc 1 for anything else, including a read that failed (hold, never release).
_crf_stuck_probe() {
    local repo="$1" pr="$2" head="$3" owner name probe pst pcreated pepoch now bound prog rl uid
    local comments reviews n page ind last lepoch url
    owner=${repo%%/*}; name=${repo#*/}
    bound=${CR_FIRST_STUCK_AFTER_S:-1800}; prog=${CR_FIRST_PROGRESS_S:-600}
    probe=$(cr_signal_probe "$owner" "$name" "$head" </dev/null) || return 1
    pst=${probe%% *}; pcreated=${probe#* }
    { [ "$pst" = pending ] && [ -n "$pcreated" ]; } || return 1
    pepoch=$(_crf_epoch "$pcreated"); [ -n "$pepoch" ] || return 1
    now=$(_crf_now)
    [ $((now - pepoch)) -ge "$bound" ] || return 1
    uid=$(cr_signal_bot_id)
    rl=$(cr_signal_rate_limit "$owner" "$name" "$pr" "$head" </dev/null) || return 1
    if [ "$rl" = rate_limited ]; then _CRF_STUCK="rate-limited"; return 0; fi
    comments=$(_crf_list "repos/$repo/issues/$pr/comments?per_page=100") || return 1
    reviews=$(_crf_list "repos/$repo/pulls/$pr/reviews?per_page=100") || return 1
    n=$(printf '%s' "$comments" | jq -r --argjson uid "$uid" --arg since "$pcreated" \
        '[.[] | select(.user.id == $uid and .created_at >= $since
                       and ((.body // "") | test("review failed|unable to complete|an error occurred|something went wrong"; "i")))] | length' 2>/dev/null) || return 1
    if [ "${n:-0}" -gt 0 ] 2>/dev/null; then _CRF_STUCK="coderabbit error comment"; return 0; fi
    url=${CR_FIRST_STATUS_URL:-https://status.coderabbit.ai/api/v2/status.json}
    if page=$(curl -fsS --max-time 10 "$url" 2>/dev/null </dev/null); then
        ind=$(printf '%s' "$page" | jq -r '.status.indicator // empty' 2>/dev/null || true)
        if [ -n "$ind" ] && [ "$ind" != none ]; then _CRF_STUCK="status page $ind"; return 0; fi
    fi
    last=$(jq -nr --argjson c "$comments" --argjson r "$reviews" --argjson uid "$uid" --arg ps "$pcreated" \
        '([$ps] + [$c[] | select(.user.id == $uid) | (.created_at, (.updated_at // empty))]
                + [$r[] | select(.user.id == $uid) | (.submitted_at // empty)]) | max' 2>/dev/null) || return 1
    lepoch=$(_crf_epoch "$last"); [ -n "$lepoch" ] || return 1
    if [ $((now - lepoch)) -ge "$prog" ]; then _CRF_STUCK="no activity for $((now - lepoch))s"; return 0; fi
    return 1
}

# _crf_do_release <owner/name> <pr> <head> <reason> <gate state line> <cheap_settled_at>
# One per-PR flock covers re-check, label write and ledger line. Remove then add,
# so GitHub sees a fresh `labeled` event whatever the label state was.
_crf_do_release() {
    local repo="$1" pr="$2" head="$3" reason="$4" state="$5" settled="$6" common lock rc=0
    if [ "${CR_FIRST_READONLY:-0}" = 1 ]; then
        echo "CR-FIRST PENDING-RELEASE $reason (read-only: no label written)"
        return 0
    fi
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git rev-parse --git-common-dir 2>/dev/null || true)
    if command -v flock >/dev/null 2>&1 && [ -n "$common" ]; then
        lock="$common/cr-first-release.$pr.lock"
        ( flock -w 60 9 || exit 4; _crf_release_locked "$repo" "$pr" "$head" "$reason" "$state" "$settled" ) 9>"$lock" || rc=$?  # prim-ok: guarded by command -v flock with an unlocked fallback below
    else
        # ponytail: no flock here, so two releasers racing on one head can both
        # write the pair; the per-head events re-check narrows it, flock closes it.
        _crf_release_locked "$repo" "$pr" "$head" "$reason" "$state" "$settled" || rc=$?
    fi
    return "$rc"
}

_crf_release_locked() {
    local repo="$1" pr="$2" head="$3" reason="$4" state="$5" settled="$6" cdate="${_CRF_FLOOR:-}" events reviewers cur labels
    # The gate took a while to evaluate: a push since then means this approval is for a head that is gone.
    cur=$(gh api "repos/$repo/pulls/$pr" </dev/null 2>/dev/null | jq -r '[.state // "", .head.sha // ""] | @tsv' 2>/dev/null) \
        || { echo "CR-FIRST HOLD degraded (cannot re-read PR #$pr)"; return 3; }
    [ "$cur" = "$(printf 'open\t%s' "$head")" ] || return 0
    events=$(_crf_list "repos/$repo/issues/$pr/events?per_page=100") || { echo "CR-FIRST HOLD degraded (cannot re-read PR #$pr events)"; return 3; }
    if [ -n "$cdate" ] && printf '%s' "$events" | jq -e --arg d "$cdate" \
        '[.[] | select(.event == "labeled" and .label.name == "ci:go" and .created_at >= $d)] | length > 0' >/dev/null 2>&1; then
        return 0
    fi
    if ! gh api "repos/$repo/labels/ci:go" </dev/null >/dev/null 2>&1; then
        echo "CR-FIRST ERROR label ci:go does not exist in $repo — create it once (a label write would auto-create it with no colour or description); nothing written"
        return 2
    fi
    if ! gh api -X DELETE "repos/$repo/issues/$pr/labels/ci:go" </dev/null >/dev/null 2>&1; then
        # A failed remove is fine only when the label was never on the PR: an add over a label
        # that stays on gives no fresh `labeled` event, so the head would read released and never run.
        labels=$(_crf_list "repos/$repo/issues/$pr/labels?per_page=100") || labels=""
        if [ -z "$labels" ] || printf '%s' "$labels" | jq -e 'any(.[]; .name == "ci:go")' >/dev/null 2>&1; then
            echo "CR-FIRST ERROR could not remove label ci:go from PR #$pr — head $head stays unreleased; the next call retries"
            return 2
        fi
    fi
    if ! gh api -X POST "repos/$repo/issues/$pr/labels" -f 'labels[]=ci:go' </dev/null >/dev/null 2>&1; then
        echo "CR-FIRST ERROR could not add label ci:go to PR #$pr — head $head stays unreleased; the next call retries"
        return 2
    fi
    reviewers=$(_crf_reviewers_json "$state" "$head")
    jq -nc --argjson pr "$pr" --arg head "$head" --arg ts "$(_crf_iso_now)" --argjson rv "$reviewers" --arg cs "$settled" \
        '{pr: $pr, head: $head, ts: $ts, reviewers: $rv, cheap_settled_at: $cs}' \
        | bash "$_CRF_LEDGER_CLI" append 2>/dev/null \
        || echo "CR-FIRST ERROR label added but the release ledger line was not written (PR #$pr head $head)"
    echo "CR-FIRST RELEASE $reason"
    return 0
}

# cr_first_switch_on <owner/name> — rc 0 only when the repository variable
# CI_GO_GATE reads `on`; unset, off, or unreadable is rc 1 (no label write, no HOLD).
cr_first_switch_on() {
    local sw
    sw=$(gh variable get CI_GO_GATE --repo "$1" </dev/null 2>/dev/null) || return 1
    [ "$(printf '%s' "$sw" | tr -d '[:space:]')" = on ]
}

cr_first_release() {
    local pr="${1:-}" head="${2:-}" repo="${3:-}" sw pull pinfo pstate psha pfork commit cdate cepoch age
    local checks_raw checks events cheap cstate csettled out grc holds="" line mapped state_line n_hold=0
    local only_cr=0 slug reason
    case "$pr" in ''|*[!0-9]*) echo "CR-FIRST ERROR usage: cr_first_release <pr> <head> [<owner/name>]"; return 2 ;; esac
    [ -n "$head" ] || { echo "CR-FIRST ERROR usage: cr_first_release <pr> <head> [<owner/name>]"; return 2; }
    command -v jq >/dev/null 2>&1 || return 0
    [ -n "$repo" ] || repo=$(_cmg_local_nwo 2>/dev/null || true)
    case "$repo" in */*/*) repo=${repo#*/} ;; esac
    case "$repo" in */*) ;; *) return 0 ;; esac

    cr_first_switch_on "$repo" || return 0

    pull=$(gh api "repos/$repo/pulls/$pr" </dev/null 2>/dev/null) || { echo "CR-FIRST HOLD degraded (cannot read PR #$pr)"; return 3; }
    pinfo=$(printf '%s' "$pull" | jq -r '[.state // "", .head.sha // "",
        (if (.head.repo == null) or (.head.repo.fork == true)
            or (((.base.repo.full_name // "") != "") and ((.head.repo.full_name // "") != "") and (.head.repo.full_name != .base.repo.full_name))
         then "fork" else "same" end)] | @tsv' 2>/dev/null) || pinfo=""
    [ -n "$pinfo" ] || { echo "CR-FIRST HOLD degraded (cannot parse PR #$pr)"; return 3; }
    IFS=$'\t' read -r pstate psha pfork <<<"$pinfo"
    [ "$pfork" = fork ] && return 0
    [ "$pstate" = open ] || return 0
    [ "$psha" = "$head" ] || return 0

    commit=$(gh api "repos/$repo/commits/$head" </dev/null 2>/dev/null) || { echo "CR-FIRST HOLD degraded (cannot read commit $head)"; return 3; }
    cdate=$(printf '%s' "$commit" | jq -r '.commit.committer.date // empty' 2>/dev/null || true)
    cepoch=$(_crf_epoch "$cdate")
    [ -n "$cepoch" ] || { echo "CR-FIRST HOLD degraded (no commit date for $head)"; return 3; }
    age=$(_crf_age "$cepoch")

    checks_raw=$(gh api --paginate "repos/$repo/commits/$head/check-runs?per_page=100" </dev/null 2>/dev/null) \
        || { echo "CR-FIRST HOLD degraded (cannot read check-runs at $head) $age"; return 3; }
    checks=$(printf '%s' "$checks_raw" | jq -s 'if all(.[]; type == "object") then {check_runs: [.[] | .check_runs[]?]} else error("bad") end' 2>/dev/null) \
        || { echo "CR-FIRST HOLD degraded (cannot parse check-runs at $head) $age"; return 3; }
    # A heavy job that really ran at this head is a release already (a pull_request
    # run before ci:go gating, or a hand label picked up by CI).
    if printf '%s' "$checks" | jq -e --arg re "${CR_FIRST_HEAVY_RE:-^(bun-suites|node-suites|shell-unit-shard|shell-unit|lanes-and-trust-suites)}" \
        '[.check_runs[] | select(.name | test($re))
          | select(.status == "in_progress" or (.status == "completed" and (.conclusion // "") != "skipped"))] | length > 0' >/dev/null 2>&1; then
        return 0
    fi
    # A `ci:go` event only belongs to this head if it is newer than the head's own
    # first check: the committer date alone misses an old commit pushed after a release.
    _CRF_FLOOR=$(printf '%s' "$checks" | jq -r --arg d "$cdate" \
        '([.check_runs[] | .started_at // empty] | min // "") as $s | if $s > $d then $s else $d end' 2>/dev/null) || _CRF_FLOOR=""
    [ -n "$_CRF_FLOOR" ] || _CRF_FLOOR=$cdate
    events=$(_crf_list "repos/$repo/issues/$pr/events?per_page=100") \
        || { echo "CR-FIRST HOLD degraded (cannot read PR #$pr events) $age"; return 3; }
    if printf '%s' "$events" | jq -e --arg d "$_CRF_FLOOR" \
        '[.[] | select(.event == "labeled" and .label.name == "ci:go" and .created_at >= $d)] | length > 0' >/dev/null 2>&1; then
        if ! bash "$_CRF_LEDGER_CLI" has "$pr" "$head" 2>/dev/null; then
            bash "$_CRF_LEDGER_CLI" alert-once "manual|$repo#$pr|$head" "CR-FIRST MANUAL-RELEASE PR #$pr head $head: ci:go set with no release-ledger line" || true
        fi
        return 0
    fi

    cheap=$(printf '%s' "$checks" | jq -r --arg re "${CR_FIRST_CHEAP_RE:-^(ci-quick|secret-scan|bwk-awk-mktemp-gate|unchecked-mktemp-range|leak-classes|git-env-scrub|commit-lint|plugin-version-bump|lint)\$}" '
        [.check_runs[] | select(.name | test($re))] as $c
        | (if any($c[]; .status == "completed" and ((.conclusion // "") | IN("failure", "cancelled", "timed_out", "action_required", "startup_failure"))) then "red"
           elif (any($c[]; .name == "ci-quick") | not) or any($c[]; .status != "completed") then "pending"
           else "green" end),
          ([$c[] | .completed_at // empty] | max // "")' 2>/dev/null) \
        || { echo "CR-FIRST HOLD degraded (cannot classify check-runs at $head) $age"; return 3; }
    { IFS= read -r cstate; IFS= read -r csettled; } <<<"$cheap"
    case "$cstate" in
        red) echo "CR-FIRST HOLD cheap-red $age"; return 1 ;;
        pending) echo "CR-FIRST HOLD cheap-pending $age"; return 1 ;;
        green) ;;
        *) echo "CR-FIRST HOLD degraded (cannot classify check-runs at $head) $age"; return 3 ;;
    esac

    grc=0
    out=$(cr_reviewer_gate "$pr" "$head" "$repo" --release 2>&1 </dev/null) || grc=$?
    state_line=$(printf '%s\n' "$out" | grep -m1 '^cr-reviewer-gate: PR #' || true)
    # A hard reviewer that passes again ends its outage alert.
    if [ -n "$state_line" ]; then
        while IFS= read -r slug; do
            [ -n "$slug" ] && bash "$_CRF_LEDGER_CLI" alert-clear "$slug" >/dev/null 2>&1
        done < <(printf '%s' "${state_line#*head *: }" | jq -Rr 'split(" · ")[] | capture("^(?<s>[^ ]+) hard pass")? | .s')
    fi
    case "$grc" in
        2)
            line=$(printf '%s\n' "$out" | grep -m1 'config error' || printf '%s' "$out")
            echo "CR-FIRST ERROR ${line#cr-reviewer-gate: }"
            return 2 ;;
        3)
            line=$(printf '%s\n' "$out" | grep 'degraded' | tail -n 1)
            echo "CR-FIRST HOLD degraded (${line:-unknown}) $age"
            return 3 ;;
        1)
            while IFS= read -r line; do
                case "$line" in HOLD:\ *) ;; *) continue ;; esac
                mapped=$(_crf_map_hold "$line")
                holds="${holds}${mapped}"$'\n'
                n_hold=$((n_hold + 1))
                case "$line" in "HOLD: CodeRabbit review is in progress"*) only_cr=1 ;; esac
            done <<<"$out"
            if [ "$n_hold" -eq 1 ] && [ "$only_cr" -eq 1 ] && _crf_stuck_probe "$repo" "$pr" "$head"; then
                grc=0
                out=$(cr_reviewer_gate "$pr" "$head" "$repo" 2>&1 </dev/null) || grc=$?
                if [ "$grc" -eq 0 ]; then
                    state_line=$(printf '%s\n' "$out" | grep -m1 '^cr-reviewer-gate: PR #' || true)
                    _crf_do_release "$repo" "$pr" "$head" "coderabbit-stuck $_CRF_STUCK" "$state_line" "$csettled"
                    return $?
                fi
            fi
            while IFS= read -r mapped; do
                [ -n "$mapped" ] || continue
                echo "CR-FIRST HOLD $mapped $age"
                case "$mapped" in
                    hard-unavailable\ *)
                        slug=${mapped#hard-unavailable }; reason=${slug#* }; slug=${slug%% *}
                        _crf_alert "$slug" "$reason" ;;
                esac
            done <<<"$holds"
            return 1 ;;
        0) ;;
        *) echo "CR-FIRST HOLD degraded (reviewer gate rc=$grc) $age"; return 3 ;;
    esac
    # rc 0: the reviewer gate passed.
    case "$out" in
        *"review is no_code_review"*)
            _crf_do_release "$repo" "$pr" "$head" "no_code_review: CI alone decides" "" "$csettled"
            return $? ;;
    esac
    _crf_do_release "$repo" "$pr" "$head" "reviewer gate passed at $head" "$state_line" "$csettled"
}

# cr_first_sweep <owner/name> — the console tick's event (point 5). Reads
# `<pr><TAB><head><TAB><labels csv>` rows on stdin (the tick's one `gh pr list`
# pass: non-fork, non-draft PRs), reads the switch once, calls cr_first_release
# for every head not already released by this station (a `ci:go` label plus a
# release-ledger line for that head), and prints
#   crfirst=#<pr>:<reason>:<age>[,...]   the held heads (+ #<pr>:manual-release)
#   ALERT <text>                         each CR-FIRST ALERT line, once per outage
# Nothing at all when the switch is off or unset, or no head is held.
cr_first_sweep() {
    local repo="$1" pr head labels out line held="" tok sep=""
    cr_first_switch_on "$repo" || return 0
    while IFS=$'\t' read -r pr head labels; do
        case "$pr" in ''|*[!0-9]*) continue ;; esac
        [ -n "$head" ] || continue
        # A label alone proves nothing: it survives a push. Skip only a head this station released.
        case ",$labels," in *,ci:go,*) bash "$_CRF_LEDGER_CLI" has "$pr" "$head" 2>/dev/null && continue ;; esac
        out=$(cr_first_release "$pr" "$head" "$repo" </dev/null 2>/dev/null) || true
        tok=""
        while IFS= read -r line; do
            case "$line" in
                "CR-FIRST ALERT "*) printf 'ALERT %s\n' "${line#CR-FIRST ALERT }" ;;
                "CR-FIRST MANUAL-RELEASE "*) held="$held$sep#$pr:manual-release"; sep="," ;;
                "CR-FIRST HOLD "*)
                    [ -z "$tok" ] || continue
                    line=${line#CR-FIRST HOLD }
                    tok="#$pr:$(printf '%s' "${line% *}" | tr -c 'A-Za-z0-9._-' '_'):${line##* }" ;;
            esac
        done <<<"$out"
        [ -z "$tok" ] || { held="$held$sep$tok"; sep=","; }
    done
    [ -z "$held" ] || printf 'crfirst=%s\n' "$held"
    return 0
}

_crf_main() {
    local pr="" head="" nwo="" info
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --pr|--head|--repo)
                [ "$#" -ge 2 ] || { echo "usage: cr-first-release.sh [--pr N] [--head SHA] [--repo OWNER/NAME]" >&2; return 2; }
                case "$1" in --pr) pr="$2" ;; --head) head="$2" ;; *) nwo="$2" ;; esac
                shift 2 ;;
            *) echo "usage: cr-first-release.sh [--pr N] [--head SHA] [--repo OWNER/NAME]" >&2; return 2 ;;
        esac
    done
    if [ -z "$pr" ] || [ -z "$head" ]; then
        # Switch first: with the gate off, a caller that names no PR gets no read and no output.
        [ -n "$nwo" ] || nwo=$(_cmg_local_nwo 2>/dev/null || true)
        case "$nwo" in */*/*) nwo=${nwo#*/} ;; esac
        cr_first_switch_on "$nwo" || return 0
        info=$(gh pr view ${nwo:+--repo "$nwo"} --json number,headRefOid -q '"\(.number) \(.headRefOid)"' 2>/dev/null) \
            || { echo "CR-FIRST ERROR no pull request for the current branch (pass --pr and --head)"; return 2; }
        [ -n "$pr" ] || pr=${info%% *}
        [ -n "$head" ] || head=${info#* }
    fi
    cr_first_release "$pr" "$head" "$nwo"
}

if ! (return 0 2>/dev/null); then
    _crf_main "$@"
    exit $?
fi
