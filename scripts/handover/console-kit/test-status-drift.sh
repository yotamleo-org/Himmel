#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check(), as in test-leg-jira-status.sh
# scripts/handover/console-kit/test-status-drift.sh - Hermetic tests for the
# WORKER comment (2a) and the status sweep (2b). A stubbed Jira
# CLI (LEG_JIRA_CLI), a stubbed gh on PATH and a stubbed queue lock
# (TICKET_STATUS_QUEUE_LOCK) read fixture files, so no real ticket, PR or lock
# is touched.
#   comment   the id is captured; edited in place, not re-posted; a 404 -> one
#             new comment; an unchanged class writes nothing
#   sweep     UI close and reopen are applied; one batched snapshot; a failed
#             read is unknown; lock-gone counting; the overrun cursor; no second
#             wake for an unchanged signature; the sweep writes no record
#
# Platform guard: POSIX bash 3.2+, no .ps1 twin by design (shell-only harness).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/leg-jira-status.sh"
SWEEP="$HERE/status-sweep.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/status-drift-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
unset GH_REPO
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]"; fails=$((fails+1)) ;; esac; }

export FX="$tmp/fx" STUB_LOG="$tmp/log"
export TICKET_STATUS_STATE_DIR="$tmp/state"
export JIRA_PROJECT_KEY=HIMMEL
mkdir -p "$tmp/bin"

cat >"$tmp/jira-stub.sh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
statusf() { if [ -e "$FX/status.$1" ]; then echo "$FX/status.$1"; else echo "$FX/status.cur"; fi; }
case "$1" in
    get)
        printf '{"fields":{"status":{"name":"%s"},"issuetype":{"name":"Task"},"labels":[]}}\n' "$(cat "$(statusf "$2")")" ;;
    transition)
        [ -e "$FX/transition.sleep" ] && sleep "$(cat "$FX/transition.sleep")"
        printf '%s\n' "$3" > "$FX/status.$2"
        exit 0 ;;
    list)
        [ -e "$FX/list.sleep" ] && sleep "$(cat "$FX/list.sleep")"
        [ -e "$FX/list.fail" ] && { echo "boom" >&2; exit 1; }
        cat "$FX/list.tsv" 2>/dev/null
        exit 0 ;;
    comment)
        file=""; edit=""
        for a in "$@"; do
            [ "$prev" = "--comment-file" ] && file="$a"
            [ "$prev" = "--edit" ] && edit="$a"
            prev="$a"
        done
        [ -n "$file" ] && cp "$file" "$FX/comment-body.last"
        if [ -n "$edit" ]; then
            [ -e "$FX/comment.404" ] && { echo "Error: HTTP 404: comment not found" >&2; exit 1; }
            [ -e "$FX/comment.err404" ] && { echo "Error: HTTP 500: upstream saw 404 in the path" >&2; exit 1; }
            echo "$edit"
            exit 0
        fi
        [ -e "$FX/comment.fail" ] && { echo "boom" >&2; exit 1; }
        n=$(( $(cat "$FX/comment.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FX/comment.n"
        [ -e "$FX/comment.noid" ] || echo "$((5000 + n))"
        exit 0 ;;
esac
EOS
cat >"$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB_LOG"
printf '%s\n' "${GH_REPO:-}" >> "$FX/gh-repo.log"
case "$1 $2" in
    "pr view")
        if [ -e "$FX/view-$3.json" ]; then jq -r .title "$FX/view-$3.json"; else echo "no pull requests found" >&2; exit 1; fi ;;
    "pr list")
        [ -e "$FX/pr-list.fail" ] && { echo "HTTP 502" >&2; exit 1; }
        cat "$FX/pr-list.json" ;;
    "pr checks")
        if [ -e "$FX/checks-$3.json" ]; then cat "$FX/checks-$3.json"; else echo "no checks reported on the 'x' branch" >&2; exit 1; fi ;;
    "api graphql")
        num=""; for a in "$@"; do case "$a" in number=*) num=${a#number=} ;; esac; done
        if [ -n "$num" ]; then
            t=$(cat "$FX/threads-$num" 2>/dev/null || echo 0)
            nodes=""; i=0; while [ "$i" -lt "$t" ]; do nodes="${nodes:+$nodes,}{\"isResolved\":false}"; i=$((i+1)); done
            printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[%s{"isResolved":true}]}}}}}\n' "${nodes:+$nodes,}"
        else
            [ -e "$FX/graphql.fail" ] && { echo "HTTP 502" >&2; exit 1; }
            more=false; [ -e "$FX/graphql.more" ] && more=true
            jq -c --arg more "$more" '{data:{repository:{pullRequests:{pageInfo:{hasNextPage:($more == "true")},
                nodes: map({number, reviewThreads:{pageInfo:{hasNextPage:false},nodes:[{isResolved:true}]},
                    commits:{nodes:[{commit:{statusCheckRollup:{contexts:{pageInfo:{hasNextPage:false},nodes:[]}}}}]}})}}}}' "$FX/pr-list.json"
        fi ;;
    "api repos/{owner}/{repo}/rules/branches/"*)
        cat "$FX/rules.json" ;;
    "api repos/{owner}/{repo}/branches/"*)
        echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
    *) echo "gh stub: unexpected $*" >&2; exit 1 ;;
esac
EOS
cat >"$tmp/lock-stub.sh" <<'EOS'
#!/usr/bin/env bash
rc=$(cat "$FX/lock.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] && { echo free; exit 0; }
now=$(date -u +%s)
hb=$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)
printf '{\n  "session": "s",\n  "heartbeat": "%s"\n}\nstatus: FRESH\n' "$hb"
exit "$rc"
EOS
chmod +x "$tmp/jira-stub.sh" "$tmp/bin/gh" "$tmp/lock-stub.sh"
export LEG_JIRA_CLI="$tmp/jira-stub.sh"
export TICKET_STATUS_QUEUE_LOCK="$tmp/lock-stub.sh"
export PATH="$tmp/bin:$PATH"

K=HIMMEL-9001
LOG="$TICKET_STATUS_STATE_DIR/status-events.jsonl"
REQ='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"shell-unit"}]}}]'
rec_of() { printf '%s/workers/%s.json' "$TICKET_STATUS_STATE_DIR" "$1"; }

reset() { # fresh fixtures, no record, empty log; Jira status $1 for every key
    rm -rf "$FX" "$TICKET_STATUS_STATE_DIR"; mkdir -p "$FX"
    : > "$STUB_LOG"
    printf '%s\n' "$1" > "$FX/status.cur"
    echo '[]' > "$FX/pr-list.json"
    : > "$FX/list.tsv"
    printf '%s\n' "$REQ" > "$FX/rules.json"
    printf '11\n' > "$FX/lock.rc"
}
mkdoc() { # <path> [marker]
    printf '# leg\n\n## Results (newest at the bottom)\n' > "$1"
    [ -z "${2:-}" ] || printf -- '- 10:00 %s — x\n' "$2" >> "$1"
}
owned() { # <KEY> [marker] [record extras as a jq object] - a record owned by that key's doc
    local key=$1 doc="$tmp/$1-N1-slug-2026-10-21.md"
    mkdoc "$doc" "${2:-LIVE}"
    mkdir -p "$TICKET_STATUS_STATE_DIR/workers"
    jq -nc --arg k "$key" --arg d "$doc" --argjson x "${3:-{\}}" \
        '{key: $k, leg: "N1", doc: $d, prs: {}} + $x' > "$(rec_of "$key")"
}
jl() { printf '%s\tTask\t%s\tsummary\n' "$1" "$2" >> "$FX/list.tsv"; } # a Jira search row
pr() { # <num> <title> <head> - appended to the open-PR list
    jq -c --argjson n "$1" --arg t "$2" --arg h "$3" \
        '. + [{number: $n, title: $t, headRefOid: $h, baseRefName: "main", reviewDecision: "", statusCheckRollup: []}]' \
        "$FX/pr-list.json" > "$FX/p.t" && mv "$FX/p.t" "$FX/pr-list.json"
}
checks() { # <num> <pass|pending|fail> - the PR's one required check, in gh pr checks and in the rollup
    local st
    printf '[{"bucket":"%s","name":"shell-unit"}]\n' "$2" > "$FX/checks-$1.json"
    case "$2" in
        pass) st='{"__typename":"CheckRun","name":"shell-unit","status":"COMPLETED","conclusion":"SUCCESS"}' ;;
        fail) st='{"__typename":"CheckRun","name":"shell-unit","status":"COMPLETED","conclusion":"FAILURE"}' ;;
        *) st='{"__typename":"CheckRun","name":"shell-unit","status":"IN_PROGRESS","conclusion":null}' ;;
    esac
    jq -c --argjson n "$1" --argjson st "$st" 'map(if .number == $n then .statusCheckRollup = [$st] else . end)' \
        "$FX/pr-list.json" > "$FX/p.t" && mv "$FX/p.t" "$FX/pr-list.json"
}
fn()     { bash "$SUT" "$@" >"$tmp/out" 2>&1; }
sweep()  { bash "$SWEEP" "$@" >"$tmp/sout" 2>&1; }
ntrans() { grep -c '^transition' "$STUB_LOG" || true; }
ncomment() { grep -c '^comment' "$STUB_LOG" || true; }
rjq()    { jq -r "$2" "$(rec_of "$1")" 2>/dev/null; }

# --- 2a: the WORKER comment ---------------------------------------------------
reset "To Do"; owned "$K"
fn "$K" --event live
check "2a: LIVE posts exactly one WORKER comment" "$(ncomment)" 1
contains "2a: the post asks for the comment id" "$(grep '^comment' "$STUB_LOG")" "--print-id"
check "2a: comment id captured in the record" "$(rjq "$K" '.comment_id')" 5001
contains "2a: the body names the worker, its state and the status" "$(cat "$FX/comment-body.last")" "WORKER"
contains "2a: the body names the leg" "$(cat "$FX/comment-body.last")" "N1"
contains "2a: the body carries the last move" "$(cat "$FX/comment-body.last")" "To Do -> In Progress"

pr 7 "[$K] feat" aaa111; checks 7 pass
fn "$K" --event check-ci-exit --pr 7 --head aaa111
check "2a: a new class edits the comment in place" "$(grep -c '^comment.*--edit 5001' "$STUB_LOG")" 1
check "2a: edited in place, not re-posted" "$(grep '^comment' "$STUB_LOG" | grep -vc -- '--edit')" 1
contains "2a: the edited body shows the PR and head" "$(cat "$FX/comment-body.last")" "aaa111"

before=$(ncomment)
fn "$K" --event check-ci-exit --pr 7 --head aaa111
check "2a: an unchanged class writes no comment" "$(ncomment)" "$before"

reset "In Progress"; owned "$K" LIVE '{"comment_id":"5001","comment_hash":"stale"}'
touch "$FX/comment.404"
fn "$K" --event live
check "2a: a 404 on the edit posts exactly one new comment" "$(grep '^comment' "$STUB_LOG" | grep -vc -- '--edit')" 1
check "2a: the new comment id replaces the dead one" "$(rjq "$K" '.comment_id')" 5001
reset "In Progress"; owned "$K" LIVE '{"comment_id":"4242","comment_hash":"stale"}'
touch "$FX/comment.404"
fn "$K" --event live
check "2a: the 404 edit was tried once, then one new post" "$(ncomment)" 2
check "2a: the stored id is the new comment's" "$(rjq "$K" '.comment_id')" 5001
reset "In Progress"; owned "$K" LIVE '{"comment_id":"4242","comment_hash":"stale"}'
touch "$FX/comment.err404"
fn "$K" --event live
check "2a: a non-404 error mentioning 404 posts no new comment" "$(ncomment)" 1
check "2a: and keeps the stored id" "$(rjq "$K" '.comment_id')" 4242

reset "To Do"; owned "$K"
touch "$FX/comment.noid"
fn "$K" --event live
check "2a: a post that returns no id stores none" "$(rjq "$K" '.comment_id // ""')" ""
fn "$K" --event live
check "2a: and never re-posts for an unchanged class" "$(ncomment)" 1

# --- 2b: the status sweep -----------------------------------------------------
# UI close: the record has an open PR, GitHub has none, the owner is live.
reset "In Review"; owned "$K" LIVE '{"state":"live","lock_seen":true,"lock_gone_sweeps":0,"prs":{"7":{"head":"aaa111","ci":"pending","red_latch":false,"open":true}}}'
jl "$K" "In Review"
printf '{"title":"[%s] feat","state":"CLOSED"}\n' "$K" > "$FX/view-7.json"
sweep
check "2b: a UI close with a live owner is applied (D5)" "$(grep '^transition' "$STUB_LOG")" "transition $K In Progress"

# A record whose open PR is not in the swept repo (a fork PR) is left alone, not moved back.
reset "In Review"; owned "$K" LIVE '{"state":"live","lock_seen":true,"lock_gone_sweeps":0,"prs":{"7":{"head":"aaa111","ci":"pending","red_latch":false,"open":true}}}'
jl "$K" "In Review"
sweep
check "2b: a record PR outside the swept repo is not moved back" "$(ntrans)" 0
check "2b: and its PR stays open in the record" "$(rjq "$K" '.prs["7"].open')" true

# The sweep reads the named repo, the himmel repo by default, and hands it to the funnel.
reset "In Review"; owned "$K" LIVE '{"state":"live","lock_seen":true,"lock_gone_sweeps":0,"prs":{"7":{"head":"aaa111","ci":"pending","red_latch":false,"open":true}}}'
jl "$K" "In Review"
printf '{"title":"[%s] feat","state":"CLOSED"}\n' "$K" > "$FX/view-7.json"
sweep
check "2b: every gh call defaults to the himmel repo" "$(sort -u "$FX/gh-repo.log")" "yotamleo-org/Himmel"
reset "In Review"; owned "$K" LIVE '{"state":"live","lock_seen":true,"lock_gone_sweeps":0,"prs":{"7":{"head":"aaa111","ci":"pending","red_latch":false,"open":true}}}'
jl "$K" "In Review"
printf '{"title":"[%s] feat","state":"CLOSED"}\n' "$K" > "$FX/view-7.json"
sweep --repo acme/fork
check "2b: --repo names the repo for the snapshot and the funnel" "$(sort -u "$FX/gh-repo.log")" "acme/fork"
sweep --repo nonsense
contains "2b: a malformed --repo is refused" "$(cat "$tmp/sout")" "not an owner/repo"

# Reopen: an open PR is back, the old red latch resets, the status goes to In Review.
reset "In Progress"; owned "$K" LIVE '{"state":"live","lock_seen":true,"lock_gone_sweeps":0,"prs":{"7":{"head":"aaa111","ci":"red","red_latch":true,"open":false}}}'
pr 7 "[$K] feat" aaa111
jl "$K" "In Progress"
sweep
check "2b: a reopen moves to In Review" "$(grep '^transition' "$STUB_LOG")" "transition $K In Review"
check "2b: the record flips the PR back to open" "$(rjq "$K" '.prs["7"].open')" true
check "2b: the reopen clears the red latch" "$(rjq "$K" '.prs["7"].red_latch')" false

# One batched snapshot: three keys already in step with Jira, no funnel call.
reset "In Progress"
K1=HIMMEL-9101 K2=HIMMEL-9102 K3=HIMMEL-9103
live='{"state":"live","lock_seen":true,"lock_gone_sweeps":0}'
owned "$K1" LIVE "$live"; owned "$K2" LIVE "$live"; owned "$K3" LIVE "$live"
pr 11 "[$K1] a" 1111111; checks 11 pending
pr 12 "[$K2] b" 2222222; checks 12 pass
jl "$K1" "IN CI"; jl "$K2" "IN CI"; jl "$K3" "In Progress"
rm -f "$LOG"
before=$(cat "$(rec_of "$K1")" "$(rec_of "$K2")" "$(rec_of "$K3")" | cksum)
sweep
check "2b: one gh pr list for the whole snapshot" "$(grep -c '^gh pr list --state open --limit 300' "$STUB_LOG")" 1
check "2b: one batched GraphQL read (threads and app ids)" "$(grep '^gh api graphql' "$STUB_LOG" | grep -vc 'number=')" 1
check "2b: one JQL search for the statuses" "$(grep -c '^list ' "$STUB_LOG")" 1
check "2b: no per-key gh pr checks" "$(grep -c '^gh pr checks' "$STUB_LOG")" 0
check "2b: no per-key PR search" "$(grep -c -- '--search' "$STUB_LOG")" 0
check "2b: keys in step with Jira cost no funnel call" "$(grep -c '^get ' "$STUB_LOG")" 0
check "2b: no status written" "$(ntrans)" 0
check "2b: the sweep wrote no worker record" "$(cat "$(rec_of "$K1")" "$(rec_of "$K2")" "$(rec_of "$K3")" | cksum)" "$before"
check "2b: status-sweep.sh never calls the record writer" "$(grep -c 'ts_record_write\|atomic_write' "$SWEEP")" 0

# A failed GraphQL read makes the snapshot unknown: nothing moves, one miss row.
touch "$FX/graphql.fail"
: > "$STUB_LOG"
sweep
check "2b: a failed GraphQL read makes no funnel call" "$(grep -c '^get \|^transition' "$STUB_LOG")" 0
check "2b: the miss row names the stage" "$(tail -n 1 "$LOG" | jq -r '[.event, .result, .stage] | join(" ")')" "sweep miss gh"
contains "2b: the sweep reports unknown" "$(cat "$tmp/sout")" "unknown"
rm -f "$FX/graphql.fail"
touch "$FX/graphql.more"
: > "$STUB_LOG"
sweep
check "2b: a saturated GraphQL read is unknown too" "$(grep -c '^get \|^transition' "$STUB_LOG")" 0
contains "2b: a saturated read reports unknown" "$(cat "$tmp/sout")" "unknown (snapshot gh)"
check "2b: the saturated miss row names the stage" "$(tail -n 1 "$LOG" | jq -r '[.event, .result, .stage] | join(" ")')" "sweep miss gh"
rm -f "$FX/graphql.more"

# A hung Jira search is cut off at the hard cap: a timeout row, one wake, then silence.
# shellcheck source=../../lib/timeout-bin.sh
. "$HERE/../../lib/timeout-bin.sh"
if [ -n "${_TIMEOUT_BIN:-}" ]; then
    printf '5\n' > "$FX/list.sleep"
    : > "$STUB_LOG"
    TICKET_STATUS_SWEEP_BUDGET=1 TICKET_STATUS_SWEEP_GRACE=0 sweep
    check "2b: a hung Jira search logs a timeout miss" "$(tail -n 1 "$LOG" | jq -r '[.event, .result, .stage] | join(" ")')" "sweep miss timeout"
    contains "2b: the timeout wakes once" "$(cat "$tmp/sout")" "wake=1"
    TICKET_STATUS_SWEEP_BUDGET=1 TICKET_STATUS_SWEEP_GRACE=0 sweep
    contains "2b: the same timeout does not wake twice" "$(cat "$tmp/sout")" "wake=0"
    rm -f "$FX/list.sleep" "$TICKET_STATUS_STATE_DIR/sweep/wake-sig"
else
    echo "ok - 2b: timeout case skipped (no timeout binary)"
fi

# Lock-gone counting: D6 only after lock_seen plus two sweeps; a held lock resets.
reset "In Progress"; owned "$K" LIVE '{"state":"live","lock_seen":false,"lock_gone_sweeps":0}'
jl "$K" "In Progress"
sweep
check "2b: a held lock marks lock_seen" "$(rjq "$K" '.lock_seen')" true
printf '0\n' > "$FX/lock.rc"
sweep
check "2b: one sweep with the lock gone counts 1" "$(rjq "$K" '.lock_gone_sweeps')" 1
check "2b: one lock-gone sweep does not reach D6" "$(ntrans)" 0
printf '11\n' > "$FX/lock.rc"
sweep
check "2b: a held lock resets the count" "$(rjq "$K" '.lock_gone_sweeps')" 0
printf '0\n' > "$FX/lock.rc"
sweep
check "2b: the count restarts at 1" "$(rjq "$K" '.lock_gone_sweeps')" 1
check "2b: still no D6 after the reset" "$(ntrans)" 0
sweep
check "2b: two consecutive lock-gone sweeps reach D6 (To Do)" "$(grep '^transition' "$STUB_LOG")" "transition $K To Do"

# A non-numeric lock_gone_sweeps is read as 0, never evaluated.
reset "In Progress"; owned "$K" LIVE '{"state":"live","lock_seen":true,"lock_gone_sweeps":"1+1"}'
printf '0\n' > "$FX/lock.rc"
jl "$K" "In Progress"
sweep
check "2b: a non-numeric count does not reach D6" "$(ntrans)" 0
check "2b: and is rewritten as a count of 1" "$(rjq "$K" '.lock_gone_sweeps')" 1

# A leg with no local lock seen (cloud or another station) never reaches D6.
reset "In Progress"; owned "$K" LIVE '{"state":"unknown","lock_seen":false,"lock_gone_sweeps":0}'
printf '0\n' > "$FX/lock.rc"
jl "$K" "In Progress"
sweep; sweep; sweep
check "2b: lock_seen false never counts toward D6" "$(ntrans)" 0
check "2b: and the count stays 0" "$(rjq "$K" '.lock_gone_sweeps')" 0
reset "In Progress"
printf '0\n' > "$FX/lock.rc"
jl "$K" "In Progress"
status_row="$TICKET_STATUS_STATE_DIR"; mkdir -p "$status_row"
printf '{"ts":"2026-10-21T10:00:00Z","event":"pr-open","key":"%s","result":"moved"}\n' "$K" > "$LOG"
sweep; sweep; sweep
check "2b: a cloud leg with no record never reaches D6" "$(ntrans)" 0

# Overrun: the 60 s budget runs out, the cursor is saved, the next sweep starts at the first unserved key.
reset "To Do"
owned "$K1" LIVE; owned "$K2" LIVE; owned "$K3" LIVE
jl "$K1" "To Do"; jl "$K2" "To Do"; jl "$K3" "To Do"
printf '2\n' > "$FX/transition.sleep"
export TICKET_STATUS_SWEEP_BUDGET=1
sweep
check "2b: an overrun sweep serves only the first key" "$(grep '^transition' "$STUB_LOG")" "transition $K1 In Progress"
check "2b: the cursor names the first unserved key" "$(cat "$TICKET_STATUS_STATE_DIR/sweep/cursor" 2>/dev/null)" "$K2"
sweep
check "2b: the next sweep starts at the cursor" "$(grep '^transition' "$STUB_LOG" | tail -n 1)" "transition $K2 In Progress"
sweep
check "2b: and the one after serves the tail" "$(grep '^transition' "$STUB_LOG" | tail -n 1)" "transition $K3 In Progress"
check "2b: a fully served sweep clears the cursor" "$([ -e "$TICKET_STATUS_STATE_DIR/sweep/cursor" ] && echo set || echo clear)" clear
unset TICKET_STATUS_SWEEP_BUDGET

# A comment-write miss followed by the funnel's noop row still counts as a miss.
reset "In Progress"; owned "$K" LIVE '{"lock_seen":false}'
jl "$K" "In Progress"
touch "$FX/comment.fail"
sweep
rm -f "$FX/comment.fail"
contains "2b: a failed comment write counts as a miss" "$(cat "$tmp/sout")" "miss=1"
contains "2b: and the failed comment wakes the caller" "$(cat "$tmp/sout")" "wake=1"

# The wake is deduped on the (result, stage, class) signature.
reset "In Progress"; owned "$K" LIVE '{"state":"live","lock_seen":true,"lock_gone_sweeps":0}'
jl "$K" "In Progress"
touch "$FX/graphql.fail"
sweep
contains "2b: the first miss wakes" "$(cat "$tmp/sout")" "wake=1"
sweep
contains "2b: the same miss signature does not wake again" "$(cat "$tmp/sout")" "wake=0"
rm -f "$FX/graphql.fail"
sweep
contains "2b: a clean sweep does not wake" "$(cat "$tmp/sout")" "wake=0"
touch "$FX/graphql.fail"
sweep
contains "2b: the miss after a clean sweep wakes again" "$(cat "$tmp/sout")" "wake=1"

echo "---"
[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
