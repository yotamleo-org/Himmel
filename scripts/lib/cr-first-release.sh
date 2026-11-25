#!/usr/bin/env bash
# cr-first-release.sh — release `ci:go` once the reviewers have passed.
#
# ci.yml starts every job of a PR at once and does not read CI_GO_GATE or the `ci:go`
# label, so nothing waits for this release: keep CI_GO_GATE off or unset. With it on this
# stays harmless, because a pull_request run has a heavy job at the head moments after
# the push, which is the quiet "head already released" path below.
#
# It releases a heavy CI that waits for the `ci:go` label at the moment the
# reviewer gate passes at the PR head, from the events that change the answer (a verdict
# written, a thread resolved, a CodeRabbit read, a cheap run going red or
# settling, the chief tick) — no timer, no background process.
#
#   cr_first_release <pr> <head> [<owner/name>]
#     Quiet (no output, rc 0): switch off or unset, fork PR, PR closed or head
#       moved, head already released (a `ci:go` labeled event at or after the
#       head commit, or a heavy job of a pull_request run that actually ran at the head).
#     CR-FIRST HOLD <reason> <age>        rc 1  (one line per reason)
#     CR-FIRST HOLD degraded (<why>)      rc 3  (a read failed; never releases)
#     CR-FIRST RELEASE <reason>           rc 0  (label removed then added; the remove
#                                                only leaves an `unlabeled` event when ci:go
#                                                was on the PR, so a first release at a head
#                                                shows `labeled` alone and a re-release over
#                                                a stale label shows `unlabeled` then `labeled`)
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
# --release: no cheap job may be red (the latest check-run of each cheap name
# decides), then every hard reviewer must pass at the head; a CodeRabbit
# review still in progress relaxes with a NOTE (decision 1066: CodeRabbit is
# best effort), while a posted CodeRabbit finding or an open thread holds. A
# cheap run still in flight does not hold:
# the heavy run re-runs every cheap job at the head, so the reviewers are the
# only wait and the two runs overlap. The per-head ledger it writes is
# scripts/cr/cr-trigger-ledger.sh — NOT the CodeRabbit trigger ledger in
# scripts/lib/coderabbit-trigger-ledger.sh. Its cheap_settled_at is the last
# cheap completion when the cheap run had settled at release, null when not.
#
# A `ci:go` while the cheap run is still going cancels that run (OQ3); the go
# run's same-named check-runs then supersede the cancelled ones.
#
# Env: CR_FIRST_HEAVY_RE / CR_FIRST_CHEAP_RE (check-run name regexes),
# CR_FIRST_NOW (epoch seam for tests),
# CR_FIRST_LEDGER / CR_FIRST_ALERTS (see cr-trigger-ledger.sh),
# CR_FIRST_READONLY=1 (a passing gate prints `CR-FIRST PENDING-RELEASE ...` and
# writes no label, no ledger line and no alert: ready-check.sh is a read-only script),
# HIMMEL_CONSOLE_DOC (extra alert sink: a chief doc named *-chief.md).
#
# Sourceable (cr_first_release) and executable:
#   bash scripts/lib/cr-first-release.sh [--pr N] [--head SHA] [--repo OWNER/NAME]
#   With no --pr, the PR is the one for the branch checked out in the caller's
#   directory (the cwd a hand-off to the anchor's copy preserves).
# bash 3.2-safe; does not toggle set -e.

_CRF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CRF_LEDGER_CLI="$_CRF_DIR/../cr/cr-trigger-ledger.sh"
_CRF_APPEND="$_CRF_DIR/../handover/chief-kit/append-results.sh"
if ! { [ -r "$_CRF_DIR/review-merge-gate.sh" ] && . "$_CRF_DIR/review-merge-gate.sh"; }; then
    echo "CR-FIRST ERROR cannot load review-merge-gate.sh" >&2
    (return 0 2>/dev/null) && return 1 || exit 1
fi
if ! declare -F gh_read >/dev/null 2>&1; then
    if [ -r "$_CRF_DIR/gh-read.sh" ]; then . "$_CRF_DIR/gh-read.sh"; else gh_read() { gh "$@"; }; fi
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
    raw=$(gh_read api --paginate "$1" </dev/null 2>/dev/null) || return 1
    printf '%s' "$raw" | jq -s 'if all(.[]; type == "array") then add // [] else error("not a list") end' 2>/dev/null
}

# _crf_reviewers_json <gate state line> <head> — the ledger's reviewers array.
_crf_reviewers_json() {
    local line="$1" head="$2" common scores
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git rev-parse --git-common-dir 2>/dev/null || true)
    scores="$common/cr-critic-scores.jsonl"
    [ -f "$scores" ] || scores=/dev/null
    [ -n "$line" ] || { echo '[]'; return 0; }
    line=$(printf '%s' "$line" | sed -E 's/^cr-reviewer-gate: PR #[0-9]+ head [^:]+: //')
    jq -nc --arg line "$line" --rawfile scores "$scores" --arg head "$head" '
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

# _crf_alert <slug> <reason> <head> — one chief alert per (slug, reason).
_crf_alert() {
    local slug="$1" reason="$2" text
    [ "${CR_FIRST_READONLY:-0}" = 1 ] && return 0
    text="CR-FIRST ALERT hard reviewer $slug is unavailable ($reason): ci:go is held fleet-wide until it can review. Levers in order: restore the $slug lane; if the operator approves, a critics.local.json overlay {\"slug\":\"$slug\",\"mode\":\"best-effort\"} or {\"slug\":\"$slug\",\"drop\":true}; a manual ci:go only if the head will be reviewed before merge."
    bash "$_CRF_LEDGER_CLI" alert-once "$slug|$reason" "$text" || return 0
    if [ -n "${HIMMEL_CONSOLE_DOC:-}" ] && [ -f "$HIMMEL_CONSOLE_DOC" ]; then
        bash "$_CRF_APPEND" "$HIMMEL_CONSOLE_DOC" "$text" >/dev/null 2>&1 || true
    fi
    return 0
}

# _crf_map_hold <gate HOLD line> — the short reason of one gate HOLD line.
_crf_map_hold() {
    local l="${1#HOLD: }" re
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
        _crf_release_locked "$repo" "$pr" "$head" "$reason" "$state" "$settled" || rc=$?
    fi
    return "$rc"
}

_crf_release_locked() {
    local repo="$1" pr="$2" head="$3" reason="$4" state="$5" settled="$6" cdate="${_CRF_FLOOR:-}" events reviewers cur labels
    # The gate took a while to evaluate: a push since then means this approval is for a head that is gone.
    cur=$(gh_read api "repos/$repo/pulls/$pr" </dev/null 2>/dev/null | jq -r '[.state // "", .head.sha // ""] | @tsv' 2>/dev/null) \
        || { echo "CR-FIRST HOLD degraded (cannot re-read PR #$pr)"; return 3; }
    [ "$cur" = "$(printf 'open\t%s' "$head")" ] || return 0
    events=$(_crf_list "repos/$repo/issues/$pr/events?per_page=100") || { echo "CR-FIRST HOLD degraded (cannot re-read PR #$pr events)"; return 3; }
    if [ -n "$cdate" ] && printf '%s' "$events" | jq -e --arg d "$cdate" \
        '[.[] | select(.event == "labeled" and .label.name == "ci:go" and .created_at >= $d)] | length > 0' >/dev/null 2>&1; then
        return 0
    fi
    if ! gh_read api "repos/$repo/labels/ci:go" </dev/null >/dev/null 2>&1; then
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
    if ! gh api -X POST "repos/$repo/issues/$pr/labels" -f 'labels[]=ci:go' </dev/null >/dev/null 2>&1 \
        && ! gh api -X POST "repos/$repo/issues/$pr/labels" -f 'labels[]=ci:go' </dev/null >/dev/null 2>&1; then
        echo "CR-FIRST ERROR could not add label ci:go to PR #$pr — head $head stays unreleased; the next call retries"
        return 2
    fi
    reviewers=$(_crf_reviewers_json "$state" "$head")
    jq -nc --argjson pr "$pr" --arg head "$head" --arg ts "$(_crf_iso_now)" --argjson rv "$reviewers" --arg cs "$settled" \
        '{pr: $pr, head: $head, ts: $ts, reviewers: $rv, cheap_settled_at: (if $cs == "" then null else $cs end)}' \
        | bash "$_CRF_LEDGER_CLI" append 2>/dev/null \
        || echo "CR-FIRST ERROR label added but the release ledger line was not written (PR #$pr head $head)"
    echo "CR-FIRST RELEASE $reason"
    return 0
}

# cr_first_switch_on <owner/name> — rc 0 only when the repository variable
# CI_GO_GATE reads `on`; unset, off, or unreadable is rc 1 (no label write, no HOLD).
_CRF_SW_REPO=""; _CRF_SW_AT=0; _CRF_SW_VAL=""
cr_first_switch_on() {
    local sw ttl="${CR_FIRST_SWITCH_TTL:-60}" now
    case "$ttl" in ''|*[!0-9]*) ttl=60 ;; esac
    now=$(date +%s)
    if [ "$ttl" -gt 0 ] && [ "$_CRF_SW_REPO" = "$1" ] && [ $((now - _CRF_SW_AT)) -ge 0 ] && [ $((now - _CRF_SW_AT)) -lt "$ttl" ]; then
        sw="$_CRF_SW_VAL"
    else
        sw=$(gh variable get CI_GO_GATE --repo "$1" </dev/null 2>/dev/null) || { _CRF_SW_REPO=""; return 1; }
        _CRF_SW_REPO="$1"; _CRF_SW_AT="$now"; _CRF_SW_VAL="$sw"
    fi
    [ "$(printf '%s' "$sw" | tr -d '[:space:]')" = on ]
}

cr_first_release() {
    local pr="${1:-}" head="${2:-}" repo="${3:-}" sw pull pinfo pstate psha pfork commit cdate cepoch age
    local checks_raw checks events cheap cstate csettled out grc holds="" line mapped state_line
    local slug reason heavy_suites runs_raw runs_rc
    case "$pr" in ''|*[!0-9]*) echo "CR-FIRST ERROR usage: cr_first_release <pr> <head> [<owner/name>]"; return 2 ;; esac
    [ -n "$head" ] || { echo "CR-FIRST ERROR usage: cr_first_release <pr> <head> [<owner/name>]"; return 2; }
    command -v jq >/dev/null 2>&1 || return 0
    [ -n "$repo" ] || repo=$(_cmg_local_nwo 2>/dev/null || true)
    case "$repo" in */*/*) repo=${repo#*/} ;; esac
    case "$repo" in */*) ;; *) return 0 ;; esac

    cr_first_switch_on "$repo" || return 0

    pull=$(gh_read api "repos/$repo/pulls/$pr" </dev/null 2>/dev/null) || { echo "CR-FIRST HOLD degraded (cannot read PR #$pr)"; return 3; }
    pinfo=$(printf '%s' "$pull" | jq -r '[.state // "", .head.sha // "",
        (if (.head.repo == null) or (.head.repo.fork == true)
            or (((.base.repo.full_name // "") != "") and ((.head.repo.full_name // "") != "") and (.head.repo.full_name != .base.repo.full_name))
         then "fork" else "same" end)] | @tsv' 2>/dev/null) || pinfo=""
    [ -n "$pinfo" ] || { echo "CR-FIRST HOLD degraded (cannot parse PR #$pr)"; return 3; }
    IFS=$'\t' read -r pstate psha pfork <<<"$pinfo"
    [ "$pfork" = fork ] && return 0
    [ "$pstate" = open ] || return 0
    [ "$psha" = "$head" ] || return 0

    commit=$(gh_read api "repos/$repo/commits/$head" </dev/null 2>/dev/null) || { echo "CR-FIRST HOLD degraded (cannot read commit $head)"; return 3; }
    cdate=$(printf '%s' "$commit" | jq -r '.commit.committer.date // empty' 2>/dev/null || true)
    cepoch=$(_crf_epoch "$cdate")
    [ -n "$cepoch" ] || { echo "CR-FIRST HOLD degraded (no commit date for $head)"; return 3; }
    age=$(_crf_age "$cepoch")

    checks_raw=$(gh_read api --paginate "repos/$repo/commits/$head/check-runs?per_page=100" </dev/null 2>/dev/null) \
        || { echo "CR-FIRST HOLD degraded (cannot read check-runs at $head) $age"; return 3; }
    checks=$(printf '%s' "$checks_raw" | jq -s 'if all(.[]; type == "object") then {check_runs: [.[] | .check_runs[]?]} else error("bad") end' 2>/dev/null) \
        || { echo "CR-FIRST HOLD degraded (cannot parse check-runs at $head) $age"; return 3; }
    heavy_suites=$(printf '%s' "$checks" | jq -c --arg re "${CR_FIRST_HEAVY_RE:-^(bun-suites|node-suites|shell-unit-shard|shell-unit|lanes-and-trust-suites)}" \
        '[.check_runs[] | select(.name | test($re))
          | select(.status == "in_progress" or (.status == "completed" and (.conclusion // "") != "skipped"))
          | .check_suite.id // empty] | unique' 2>/dev/null) || heavy_suites="[]"
    if [ "$heavy_suites" != "[]" ]; then
        runs_raw=$(gh_read api --paginate "repos/$repo/actions/runs?head_sha=$head&event=pull_request&per_page=100" </dev/null 2>/dev/null) \
            || { echo "CR-FIRST HOLD degraded (cannot read workflow runs at $head) $age"; return 3; }
        runs_rc=0
        printf '%s' "$runs_raw" | jq -se --argjson ids "$heavy_suites" \
            'if length > 0 and all(.[]; type == "object" and (.workflow_runs | type == "array")) then . else error("bad") end
             | [.[] | .workflow_runs[] | select(.event == "pull_request") | .check_suite_id] as $pr
             | any($ids[]; . as $i | $pr | index($i) != null)' >/dev/null 2>&1 || runs_rc=$?
        case "$runs_rc" in
            0) return 0 ;;
            1) ;;
            *) echo "CR-FIRST HOLD degraded (cannot parse workflow runs at $head) $age"; return 3 ;;
        esac
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
        if [ "${CR_FIRST_READONLY:-0}" != 1 ] && ! bash "$_CRF_LEDGER_CLI" has "$pr" "$head" 2>/dev/null; then
            bash "$_CRF_LEDGER_CLI" alert-once "manual|$repo#$pr|$head" "CR-FIRST MANUAL-RELEASE PR #$pr head $head: ci:go set with no release-ledger line" || true
        fi
        return 0
    fi

    # The REST list holds every check-run ever created for the sha: the highest id per name decides.
    cheap=$(printf '%s' "$checks" | jq -r --arg re "${CR_FIRST_CHEAP_RE:-^(ci-quick|secret-scan|bwk-awk-mktemp-gate|unchecked-mktemp-range|leak-classes|git-env-scrub|commit-lint|plugin-version-bump|lint)\$}" '
        ([.check_runs[] | select(.name | test($re))] | group_by(.name) | map(max_by(.id // 0))) as $c
        | (if any($c[]; .status == "completed" and ((.conclusion // "") | IN("failure", "cancelled", "timed_out", "action_required", "startup_failure"))) then "red"
           elif (any($c[]; .name == "ci-quick" and .status == "completed" and .conclusion == "success") | not) or any($c[]; .status != "completed") then "pending"
           else "green" end) as $s
        | $s, (if $s == "green" then ([$c[] | .completed_at // empty] | max // "") else "" end)' 2>/dev/null) \
        || { echo "CR-FIRST HOLD degraded (cannot classify check-runs at $head) $age"; return 3; }
    { IFS= read -r cstate; IFS= read -r csettled; } <<<"$cheap"
    case "$cstate" in
        red) echo "CR-FIRST HOLD cheap-red $age"; return 1 ;;
        pending|green) ;;
        *) echo "CR-FIRST HOLD degraded (cannot classify check-runs at $head) $age"; return 3 ;;
    esac

    grc=0
    out=$(GH_CMD="${GH_CMD:-$_CRF_DIR/gh-read.sh}" cr_reviewer_gate "$pr" "$head" "$repo" --release 2>&1 </dev/null) || grc=$?
    state_line=$(printf '%s\n' "$out" | grep -m1 '^cr-reviewer-gate: PR #' || true)
    # A hard reviewer that passes again ends its outage alert.
    if [ -n "$state_line" ] && [ "${CR_FIRST_READONLY:-0}" != 1 ]; then
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
            done <<<"$out"
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

# cr_first_sweep <owner/name> — the chief tick's event (point 5). Reads
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
    local pr="" head="" nwo="" info sel
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
        # `gh pr view --repo X` with no selector is an error from any directory, and `gh pr view <name>`
        # reads a numeric name as a PR number, so the caller's branch goes through a head-branch list.
        if [ -n "$pr" ]; then
            info=$(gh_read pr view "$pr" ${nwo:+--repo "$nwo"} --json number,headRefOid -q '"\(.number) \(.headRefOid)"' 2>/dev/null) || info=""
        else
            sel=$(git symbolic-ref --short -q HEAD 2>/dev/null || true)
            info=""
            [ -z "$sel" ] || info=$(gh_read pr list --head "$sel" --state open ${nwo:+--repo "$nwo"} --json number,headRefOid,isCrossRepository \
                -q '[.[] | select(.isCrossRepository | not)] | .[0] | select(. != null) | "\(.number) \(.headRefOid)"' 2>/dev/null) || info=""
        fi
        [ -n "$info" ] || { echo "CR-FIRST ERROR no pull request for the current branch (pass --pr and --head)"; return 2; }
        [ -n "$pr" ] || pr=${info%% *}
        [ -n "$head" ] || head=${info#* }
    fi
    cr_first_release "$pr" "$head" "$nwo"
}

if ! (return 0 2>/dev/null); then
    _crf_main "$@"
    exit $?
fi
