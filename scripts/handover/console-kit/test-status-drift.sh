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
HOLD="$HERE/ticket-hold.sh"
DRIFT="$HERE/status-drift.sh"
# shellcheck source=../../lib/env-value.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/env-value.sh"

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
        [ -e "$FX/get.nolabels" ] && { printf '{"fields":{"status":{"name":"To Do"}}}\n'; exit 0; }
        printf '{"fields":{"status":{"name":"%s"},"issuetype":{"name":"Task"},"labels":%s}}\n' "$(cat "$(statusf "$2")")" \
            "$(cat "$FX/labels.$2" 2>/dev/null | jq -Rsc 'split("\n") | map(select(length > 0))')" ;;
    edit)
        [ -e "$FX/edit.fail" ] && { echo "boom" >&2; exit 1; }
        prev=""
        for a in "$@"; do
            case "$prev" in
                --add-labels) [ -e "$FX/edit.noop" ] || printf '%s\n' "$a" >> "$FX/labels.$2" ;;
                --remove-labels)
                    [ -e "$FX/edit.noop" ] || { grep -vx "$a" "$FX/labels.$2" > "$FX/labels.t" 2>/dev/null; mv "$FX/labels.t" "$FX/labels.$2"; } ;;
            esac
            prev="$a"
        done
        echo "$2 edited"
        exit 0 ;;
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
expected_repo=$(env_value HIMMEL_REPO git -C "$HERE" remote get-url origin | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##')
check "2b: every gh call defaults to the himmel repo" "$(sort -u "$FX/gh-repo.log")" "$expected_repo"
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

# --- 3a: holds ----------------------------------------------------------------
hold()  { bash "$HOLD" "$@" >"$tmp/hout" 2>&1; }
rowq()  { jq -r "$1" "$LOG" 2>/dev/null; }

reset "To Do"
hold "$K" --reason "waiting on legal" --owner chief --until 2026-11-01; rc=$?
check "3a: hold exits 0" "$rc" 0
check "3a: hold adds the held label with one edit" "$(grep -c "^edit $K --add-labels held" "$STUB_LOG")" 1
check "3a: the label reads back on the ticket" "$(cat "$FX/labels.$K")" held
contains "3a: the HOLD comment names the reason" "$(cat "$FX/comment-body.last")" "waiting on legal"
contains "3a: the HOLD comment names the owner" "$(cat "$FX/comment-body.last")" "chief"
contains "3a: the HOLD comment carries the advisory date" "$(cat "$FX/comment-body.last")" "2026-11-01"
check "3a: hold writes one outcome row" "$(rowq 'select(.event == "hold") | .result')" moved
check "3a: and no status transition" "$(ntrans)" 0

hold "$K" --release --owner chief; rc=$?
check "3a: release exits 0" "$rc" 0
check "3a: release drops the label with one edit" "$(grep -c "^edit $K --remove-labels held" "$STUB_LOG")" 1
check "3a: the label is gone on read-back" "$(cat "$FX/labels.$K")" ""
check "3a: release writes its own outcome row" "$(rowq 'select(.event == "hold-release") | .result')" moved

reset "To Do"; touch "$FX/edit.noop"
hold "$K" --reason r --owner o; rc=$?
check "3a: a label that does not read back exits 1" "$rc" 1
check "3a: and logs miss at the readback stage" "$(rowq 'select(.event == "hold") | .result + ":" + .stage')" "miss:readback"
check "3a: and posts no HOLD comment" "$(ncomment)" 0

reset "To Do"; touch "$FX/get.nolabels"
hold "$K" --release --owner o; rc=$?
check "3a: a read-back with no labels field is not proof of a release" "$rc" 1
check "3a: and logs miss at the readback stage" "$(rowq 'select(.event == "hold-release") | .result + ":" + .stage')" "miss:readback"

reset "To Do"; touch "$FX/edit.fail"
hold "$K" --reason r --owner o; rc=$?
check "3a: a failed edit exits 1" "$rc" 1
check "3a: and logs miss at the edit stage" "$(rowq 'select(.event == "hold") | .result + ":" + .stage')" "miss:edit"

reset "To Do"; touch "$FX/comment.fail"
hold "$K" --reason r --owner o; rc=$?
check "3a: a failed HOLD comment still holds" "$rc" 0
check "3a: the label stands" "$(cat "$FX/labels.$K")" held
check "3a: the failed comment is an audit-gap row" "$(rowq 'select(.event == "audit-gap") | .key + ":" + .stage')" "$K:comment"
contains "3a: and warns on stderr" "$(cat "$tmp/hout")" "audit-gap"

reset "To Do"
TMPDIR="$tmp/no-such-dir" hold "$K" --reason r --owner o; rc=$?
check "3a: no temp file for the HOLD comment still holds" "$rc" 0
check "3a: and the label stands" "$(cat "$FX/labels.$K")" held
check "3a: and no comment is posted" "$(ncomment)" 0
check "3a: and the lost comment is an audit-gap row" "$(rowq 'select(.event == "audit-gap") | .key + ":" + .stage')" "$K:comment"
contains "3a: and warns on stderr" "$(cat "$tmp/hout")" "audit-gap"

reset "To Do"
hold "$K" --owner o; rc=$?
check "3a: a hold without --reason is a usage error" "$rc" 2
hold "$K" --reason r; rc=$?
check "3a: a hold without --owner is a usage error" "$rc" 2
hold not-a-key --reason r --owner o; rc=$?
check "3a: a non-key is a usage error" "$rc" 2
check "3a: usage errors call no edit" "$(grep -c '^edit' "$STUB_LOG")" 0

reset "To Do"; owned "$K"; printf 'held\n' > "$FX/labels.$K"
fn "$K" --event live
check "3a: derive ignores a hold: a held ticket still moves" "$(grep '^transition' "$STUB_LOG")" "transition $K In Progress"

# --- 3b: the drift check ------------------------------------------------------
drift() { bash "$DRIFT" --docs-dir "$tmp/docs" >"$tmp/dout" 2>&1; }
drows() { grep -E "^$1 " "$tmp/dout"; }
dcount() { drows "$1" | wc -l | tr -d ' '; }
dlast() { tail -n 1 "$tmp/dout"; }
nwrites() { grep -cE '^(transition|comment|edit)' "$STUB_LOG" || true; }
wipe_docs() { rm -rf "$tmp/docs"; mkdir -p "$tmp/docs"; }
logrow() { # <event> <key> <result> <pr> [contract] - a row appended to the outcome log
    mkdir -p "$TICKET_STATUS_STATE_DIR"
    jq -nc --arg e "$1" --arg k "$2" --arg r "$3" --arg p "$4" --arg c "${5:-}" \
        '{ts: "2026-10-21T10:00:00Z", event: $e, key: $k, result: $r, pr: $p, contract: $c}' >> "$LOG"
}

wipe_docs
reset "To Do"
drift; rc=$?
check "3b: a clean pass exits 0" "$rc" 0
contains "3b: a clean pass reports no drift" "$(dlast)" "sdrift=0:"
check "3b: a clean pass lists no class row" "$(grep -cE '^[A-Z]+(-[A-Z]+)* ' "$tmp/dout")" 0
bash "$DRIFT" --bogus >/dev/null 2>&1; rc=$?
check "3b: an unknown option is a usage error" "$rc" 2

reset "In Progress"; owned "$K"; jl "$K" "In Progress"; pr 7 "[$K] feat" aaa111; checks 7 pass
before=$(cksum < "$(rec_of "$K")")
drift
contains "3b: a Jira status behind the derive is a DERIVE-MISMATCH" "$(drows DERIVE-MISMATCH)" "DERIVE-MISMATCH $K"
contains "3b: the row names the D rule" "$(drows DERIVE-MISMATCH)" "rule=D3"
contains "3b: the row names the forward direction" "$(drows DERIVE-MISMATCH)" "dir=forward"
contains "3b: the row names both statuses" "$(drows DERIVE-MISMATCH)" "jira=In Progress derived=IN CI"
contains "3b: the row names its writer and its recovery command" "$(drows DERIVE-MISMATCH)" "status-sweep.sh"
sig1=$(dlast)
drift
check "3b: the same drift twice gives the same signature" "$(dlast)" "$sig1"
check "3b: the drift check writes no Jira field, status or comment" "$(nwrites)" 0
check "3b: and leaves the worker record as it was" "$(cksum < "$(rec_of "$K")")" "$before"

reset "IN CI"; owned "$K"; jl "$K" "IN CI"; pr 7 "[$K] feat" aaa111; checks 7 fail
drift
contains "3b: a Jira status ahead of the derive is a DERIVE-MISMATCH" "$(drows DERIVE-MISMATCH)" "DERIVE-MISMATCH $K"
contains "3b: the backward row names its rule" "$(drows DERIVE-MISMATCH)" "rule=D1"
contains "3b: the backward row names its direction" "$(drows DERIVE-MISMATCH)" "dir=backward"
check "3b: a flipped direction changes the signature" "$([ "$(dlast)" != "$sig1" ] && echo differs)" differs

reset "In Progress"; owned "$K"; jl "$K" "In Progress"; pr 7 "[$K] feat" aaa111; checks 7 fail
drift
check "3b: a status equal to the derive is not drift" "$(dcount DERIVE-MISMATCH)" 0

reset "Done"; pr 7 "[$K] feat" aaa111
drift
contains "3b: a Done ticket with an open PR is DONE-WITH-OPEN-PR" "$(drows DONE-WITH-OPEN-PR)" "DONE-WITH-OPEN-PR $K"
contains "3b: the row names the PR" "$(drows DONE-WITH-OPEN-PR)" "#7"
check "3b: and is not also a DERIVE-MISMATCH" "$(dcount DERIVE-MISMATCH)" 0

reset "Done"; pr 7 "[HIMMEL-90019] feat" aaa111
drift
check "3b: a PR of another key (first [KEY] only) is not this ticket's" "$(drows DONE-WITH-OPEN-PR | grep -c "OPEN-PR $K ")" 0

reset "In Review"; logrow merge "$K" miss 7 yes
drift
contains "3b: a contract-yes merge with the ticket not Done is a MERGE-MISMATCH" "$(drows MERGE-MISMATCH)" "MERGE-MISMATCH $K"
reset "Done"; logrow merge "$K" miss 7 yes
drift
check "3b: a Done ticket after its merge row is not a MERGE-MISMATCH" "$(dcount MERGE-MISMATCH)" 0
reset "In Review"; logrow merge "$K" moved 7 no
drift
check "3b: a contract-no merge row is not a MERGE-MISMATCH" "$(dcount MERGE-MISMATCH)" 0

reset "Done"; i=0; while [ "$i" -lt 21 ]; do logrow merge "HIMMEL-$((7000 + i))" moved 7 yes; i=$((i + 1)); done
drift
contains "3b: more merge keys than the check budget is reported, not dropped" "$(drows HEALTH)" "checked 20 of 21"

reset "To Do"; logrow check-ci-exit "$K" miss 7
drift
contains "3b: a miss with no later moved or noop row is MISSED" "$(drows MISSED)" "MISSED $K"
logrow check-ci-exit "$K" noop 7
drift
check "3b: a later noop row for the same key and PR clears it" "$(dcount MISSED)" 0
reset "To Do"; logrow check-ci-exit "$K" miss 7; logrow check-ci-exit "$K" moved 8
drift
contains "3b: a later moved row for another PR does not clear it" "$(drows MISSED)" "MISSED $K"

reset "In Progress"; owned "$K" WRAPPED '{"state":"live"}'; jl "$K" "In Progress"
drift
contains "3b: a live record whose doc is WRAPPED is WORKER-STALE" "$(drows WORKER-STALE)" "WORKER-STALE $K"
reset "In Progress"; owned "$K" LIVE '{"state":"idle"}'; jl "$K" "In Progress"; printf '0\n' > "$FX/lock.rc"
drift
contains "3b: an idle record whose lock is released is WORKER-STALE" "$(drows WORKER-STALE)" "WORKER-STALE $K"
reset "In Progress"; owned "$K" LIVE '{"state":"live"}'; jl "$K" "In Progress"
drift
check "3b: a live record with a held lock is not stale" "$(dcount WORKER-STALE)" 0

reset "In Progress"; owned "$K" LIVE '{"state":"live","comment_id":"5001","comment_hash":"1"}'; jl "$K" "In Progress"
drift
contains "3b: a WORKER comment hash that differs from the class is WORKER-COMMENT" "$(drows WORKER-COMMENT)" "WORKER-COMMENT $K"
reset "To Do"; owned "$K"
fn "$K" --event live
jl "$K" "In Progress"
drift
check "3b: the hash the funnel stored is the hash drift expects" "$(dcount WORKER-COMMENT)" 0
check "3b: and the ticket the funnel moved is not drift" "$(dlast | cut -d: -f1)" "sdrift=0"

reset "In Progress"; wipe_docs; owned "$K" LIVE '{"state":"live"}'; jl "$K" "In Progress"
mkdoc "$tmp/docs/$K-N2-other-2026-10-21.md" LIVE
drift
contains "3b: two live docs for one key are TWO-OWNERS" "$(drows TWO-OWNERS)" "TWO-OWNERS $K"
wipe_docs; mkdoc "$tmp/docs/$K-N2-other-2026-10-21.md" WRAPPED
drift
check "3b: a wrapped second doc is not an owner" "$(dcount TWO-OWNERS)" 0
wipe_docs; mkdoc "$tmp/docs/HIMMEL-90019-N2-other-2026-10-21.md" LIVE
drift
check "3b: another key's doc is not an owner (exact key, not a prefix)" "$(dcount TWO-OWNERS)" 0
wipe_docs

reset "In Progress"; jl "$K" "In Progress"
drift
contains "3b: started, no open PR and no owner is UNOWNED" "$(drows UNOWNED)" "UNOWNED $K"
reset "In Progress"; owned "$K" LIVE '{"state":"live"}'; jl "$K" "In Progress"
drift
check "3b: a live owner means not UNOWNED" "$(dcount UNOWNED)" 0
reset "In Progress"; jl "$K" "In Progress"; pr 7 "[$K] feat" aaa111; checks 7 fail
drift
check "3b: an open PR means not UNOWNED" "$(dcount UNOWNED)" 0

reset "In Progress"; owned "$K" LIVE '{"state":"live"}'; jl "$K" "In Progress"; printf 'held\n' > "$FX/labels.$K"
drift
contains "3b: a held ticket with a live owner is HELD-IN-WORK" "$(drows HELD-IN-WORK)" "HELD-IN-WORK $K"
reset "In Progress"; jl "$K" "In Progress"; pr 7 "[$K] feat" aaa111; checks 7 fail; printf 'held\n' > "$FX/labels.$K"
drift
contains "3b: a held ticket with an open PR is HELD-IN-WORK" "$(drows HELD-IN-WORK)" "HELD-IN-WORK $K"
reset "In Progress"; owned "$K" LIVE '{"state":"live"}'; jl "$K" "In Progress"
drift
check "3b: an unheld ticket is not HELD-IN-WORK" "$(dcount HELD-IN-WORK)" 0

reset "To Do"; touch "$FX/pr-list.fail"
drift
contains "3b: an unreadable PR list is sdrift=unknown" "$(dlast)" "sdrift=unknown"
contains "3b: and a HEALTH row names the PR list" "$(drows HEALTH)" "gh"
reset "To Do"; touch "$FX/list.fail"
drift
contains "3b: an unreadable Jira search is sdrift=unknown" "$(dlast)" "sdrift=unknown"
contains "3b: and a HEALTH row names Jira" "$(drows HEALTH)" "jira"
reset "To Do"; i=0; while [ "$i" -lt 300 ]; do jl "HIMMEL-$((1000 + i))" "In Progress"; i=$((i + 1)); done
drift
contains "3b: a saturated Jira search is sdrift=unknown" "$(dlast)" "sdrift=unknown"
contains "3b: and a HEALTH row names the limit" "$(drows HEALTH)" "limit"
reset "In Progress"; jl "$K" "In Progress"; mkdir -p "$TICKET_STATUS_STATE_DIR/workers"; printf '{bad\n' > "$(rec_of "$K")"
drift
contains "3b: an unreadable worker record is a HEALTH row naming the key" "$(drows HEALTH)" "$K"
check "3b: and the pass is not unknown" "$(dlast | grep -c unknown)" 0
reset "To Do"; mkdir -p "$LOG"
drift
contains "3b: an unwritable outcome log is a HEALTH row" "$(drows HEALTH)" "unwritable"
reset "To Do"; logrow leg-jira-status "$K" disabled ""
drift
contains "3b: a disabled row is a HEALTH row, never clean" "$(drows HEALTH)" "disabled"

reset "Done"
for n in 1 2 3 4 5 6; do owned "HIMMEL-90$n"; jl "HIMMEL-90$n" Done; done
drift; rc=$?
check "3b: a batched pass exits 0" "$rc" 0
check "3b: the statuses of all active keys are read in one search, no per-key get" "$(grep -c '^get ' "$STUB_LOG")" 0
check "3b: and one extra search covers the key set" "$(grep -c '^list ' "$STUB_LOG")" 2
contains "3b: a pass over Done tickets is clean" "$(dlast)" "sdrift=0:"
reset "Done"
owned "HIMMEL-901"; owned "HIMMEL-902"; jl "HIMMEL-901" Done
drift; rc=$?
check "3b: a fallback pass exits 0" "$rc" 0
check "3b: a key the search does not return is read by its own get" "$(grep -c '^get HIMMEL-902' "$STUB_LOG")" 1
contains "3b: and the status that get returned is used, so the pass is clean" "$(dlast)" "sdrift=0:"

# --- 3c: the FOCUS refresh (focus-refresh.sh) ----------------------------------------
FOCUS="$HERE/focus-refresh.sh"
FR="$tmp/fr"
mkdir -p "$tmp/frbin"
cat >"$tmp/frbin/jira" <<'EOS'
#!/usr/bin/env bash
echo "jira $1" >> "$FX/fr.log"
[ "$(cat "$FX/fr.fail" 2>/dev/null)" = "$1" ] && exit 1
[ "$1" = versions ] && printf 'v1.1.3\tfalse\t-\n'
exit 0
EOS
cat >"$tmp/frbin/sweep" <<'EOS'
#!/usr/bin/env bash
echo "sweep" >> "$FX/fr.log"
case "$(cat "$FX/fr.fail" 2>/dev/null)" in
    sweep) exit 1 ;;
    sweep-unknown) echo "status-sweep: unknown (gh unreadable) keys=0 sig=x wake=1"; exit 0 ;;
esac
echo "status-sweep: keys=2 served=2 moved=$(cat "$FX/sweep.moved" 2>/dev/null || echo 0) miss=0 funnel=1 sig=abc wake=1"
EOS
cat >"$tmp/frbin/tracker" <<'EOS'
#!/usr/bin/env bash
echo "tracker $*" >> "$FX/fr.log"
[ "$(cat "$FX/fr.fail" 2>/dev/null)" = render ] && exit 1
[ -e "$FX/fr.sleep" ] && sleep "$(cat "$FX/fr.sleep")"
[ -e "$FX/fr.again" ] && date +%s > "$(cat "$FX/fr.again")"
out=""; prev=""
for a in "$@"; do [ "$prev" = --out ] && out="$a"; prev="$a"; done
n=$(( $(cat "$FX/render.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FX/render.n"
echo "render $n" > "$out"
cat "$FX/vfp" 2>/dev/null > "$out.vfp" || echo vfp1 > "$out.vfp"
EOS
cat >"$tmp/frbin/drift" <<'EOS'
#!/usr/bin/env bash
echo "drift" >> "$FX/fr.log"
[ "$(cat "$FX/fr.fail" 2>/dev/null)" = drift ] && exit 1
if [ "$(cat "$FX/fr.fail" 2>/dev/null)" = drift-unknown ]; then
    echo "sdrift=unknown"
    exit 0
fi
echo "UNOWNED HIMMEL-1 x | writer=- | fix=y"
echo "sdrift=1:0a1b2c3d"
EOS
chmod +x "$tmp/frbin/jira" "$tmp/frbin/sweep" "$tmp/frbin/tracker" "$tmp/frbin/drift"
export FR_JIRA="$tmp/frbin/jira" FR_SWEEP="$tmp/frbin/sweep" FR_TRACKER="$tmp/frbin/tracker" FR_DRIFT="$tmp/frbin/drift"
export TICK_TRACKER_MIRROR_DIR="$FR/mir/HIMMEL"
fr_reset() { # fresh fixtures plus a console doc with a focus-version line
    reset "To Do"
    rm -rf "$FR"; mkdir -p "$FR/doc" "$FR/mir"
    printf '# console\n\n## Live state\ntracker: https://example.invalid/t\nfocus-version: v1.1.3\n' > "$FR/doc/console.md"
}
fr() { bash "$FOCUS" --doc "$FR/doc/console.md" "$@" >"$tmp/frout" 2>"$tmp/frerr"; echo $? >"$tmp/frrc"; }
frrc() { cat "$tmp/frrc"; }
frout() { cat "$tmp/frout"; }
fst() { sed -n "s/^$1=//p" "$FR/doc/focus-state" | head -n 1; }
frseq() { awk '{ print $1 }' "$FX/fr.log" 2>/dev/null | paste -sd, -; }
PAGE="$FR/doc/roadmap-tracker.html"

fr_reset; sed -i '/^focus-version:/d' "$FR/doc/console.md"  # gnu-ok: Linux-only kit
fr
check "3c: no focus-version line prints skip" "$(frout)" "focus=skip"
check "3c: and exits 0" "$(frrc)" 0
check "3c: and runs nothing" "$([ -e "$FX/fr.log" ] && echo ran || echo none)" none
fr --status
check "3c: --status without a focus-version line is skip" "$(frout)" "focus=skip"
bash "$FOCUS" --bogus >/dev/null 2>&1
check "3c: a usage error exits 2" "$?" 2

fr_reset
fr
check "3c: a full refresh prints ok" "$(frout)" "focus=ok"
check "3c: and exits 0" "$(frrc)" 0
check "3c: the steps run in order: mirror, versions, sweep, render, drift" "$(frseq)" "jira,jira,sweep,tracker,drift"
check "3c: the page is written" "$(cat "$PAGE")" "render 1"
check "3c: the state records status ok" "$(fst status)" ok
check "3c: the state records generation 1" "$(fst gen)" 1
contains "3c: the state records the drift line" "$(fst sdrift)" "1:0a1b2c3d"
check "3c: the state records the page fingerprint" "$(fst sha8)" vfp1
check "3c: the versions snapshot sits next to the mirror" "$(cat "$FR/mir/HIMMEL.versions.tsv")" "$(printf 'v1.1.3\tfalse\t-')"
trk=$(grep '^tracker ' "$FX/fr.log")
contains "3c: the render names the version" "$trk" "--version v1.1.3"
contains "3c: the render reads the worker records" "$trk" "--workers-dir $TICKET_STATUS_STATE_DIR/workers"
contains "3c: the render reads the staged PR snapshot" "$trk" "--prs-file"
contains "3c: the render reads the mirror it was given" "$trk" "--mirror-dir $FR/mir/HIMMEL"
check "3c: the drift rows are kept beside the page" "$(sed -n 1p "$FR/doc/focus-drift.txt")" "UNOWNED HIMMEL-1 x | writer=- | fix=y"
fr
check "3c: a second refresh is generation 2" "$(fst gen)" 2
check "3c: an unchanged fingerprint leaves the page alone" "$(cat "$PAGE")" "render 1"
echo vfp2 > "$FX/vfp"
fr
check "3c: a changed fingerprint replaces the page" "$(cat "$PAGE")" "render 3"
check "3c: and the stored fingerprint follows" "$(cat "$PAGE.vfp")" vfp2

fr_reset
mkdir -p "$FR/m2"
fr --mirror-fresh "$FR/m2"
check "3c: a fresh mirror from the caller skips the mirror and versions steps" "$(frseq)" "sweep,tracker,drift"
contains "3c: the render reads that mirror" "$(grep '^tracker ' "$FX/fr.log")" "--mirror-dir $FR/m2"

for stage in mirror versions sweep render drift; do
    fr_reset
    fr
    echo "page-before" > "$PAGE"
    printf '%s\n' "$stage" > "$FX/fr.fail"
    : > "$FX/fr.log"
    fr
    check "3c: a failed $stage step prints FAILED:$stage" "$(frout)" "focus=FAILED:$stage"
    check "3c: and exits 1" "$(frrc)" 1
    check "3c: the state records the stage" "$(fst stage)" "$stage"
    check "3c: the state records FAILED" "$(fst status)" FAILED
    check "3c: the generation is not advanced" "$(fst gen)" 1
    check "3c: the published page is untouched" "$(cat "$PAGE")" "page-before"
done
fr_reset; echo sweep-unknown > "$FX/fr.fail"
fr
check "3c: an unknown sweep is FAILED:sweep" "$(frout)" "focus=FAILED:sweep"
fr_reset; echo drift-unknown > "$FX/fr.fail"
fr
check "3c: an unknown drift pass is FAILED:drift" "$(frout)" "focus=FAILED:drift"
check "3c: and the page is not published" "$([ -e "$PAGE" ] && echo set || echo none)" none
fr_reset; echo 2 > "$FX/sweep.moved"
fr
check "3c: a sweep that moved a ticket re-reads the mirror before the render" "$(frseq)" "jira,jira,sweep,jira,tracker,drift"
check "3c: and the refresh is ok" "$(frout)" "focus=ok"
fr_reset; echo 2 > "$FX/sweep.moved"; echo mirror > "$FX/fr.fail"
fr
check "3c: a failed re-read after a move is FAILED:mirror" "$(frout)" "focus=FAILED:mirror"
fr_reset
( cd "$FR/doc" && bash "$FOCUS" --doc console.md >"$tmp/frout" 2>"$tmp/frerr"; echo $? >"$tmp/frrc" )
check "3c: a bare doc filename resolves beside the doc" "$(frout)" "focus=ok"
check "3c: and the page lands beside the doc" "$(cat "$PAGE")" "render 1"
fr_reset; touch "$FX/pr-list.fail"
fr
check "3c: an unreadable PR snapshot is FAILED:prs" "$(frout)" "focus=FAILED:prs"
check "3c: and the render does not run" "$(grep -c '^tracker' "$FX/fr.log")" 0

fr_reset; echo render > "$FX/fr.fail"; fr
fr --status
check "3c: --status after a failed render is FAILED:render" "$(frout)" "focus=FAILED:render"
rm -f "$FX/fr.fail"; fr
fr --status
check "3c: --status after the next good refresh is ok" "$(frout)" "focus=ok"
fr --mark-dirty
check "3c: --mark-dirty leaves a request marker for a running refresh" "$([ -s "$FR/doc/focus-state.again" ] && echo set || echo none)" set
fr --status
contains "3c: --mark-dirty makes the state DIRTY" "$(frout)" "focus=DIRTY:0m"
printf 'status=ok\ngen=3\ndirty=%s\n' "$(( $(date +%s) - 1500 ))" > "$FR/doc/focus-state"
fr --status
check "3c: a dirty mark reads its age in minutes" "$(frout)" "focus=DIRTY:25m"
rm -f "$FR/doc/focus-state"
fr --status
check "3c: no state at all is DIRTY, never ok" "$(frout | cut -d: -f1)" "focus=DIRTY"

fr_reset; echo 5 > "$FX/fr.sleep"
FOCUS_REFRESH_BUDGET=1 fr
check "3c: a hung render is cut off as FAILED:timeout" "$(frout)" "focus=FAILED:timeout"
check "3c: and exits 1" "$(frrc)" 1
check "3c: the state records the timeout" "$(fst stage)" timeout
rm -f "$FX/fr.sleep"
fr_reset; echo 5 > "$FX/fr.sleep"
( sleep 1; printf 'status=ok\nstage=\ngen=7\ndirty=\nsha8=zz\nsdrift=\n' > "$FR/doc/focus-state" ) &
FOCUS_REFRESH_BUDGET=2 fr
wait
check "3c: a timeout keeps the generation a concurrent writer stored" "$(fst gen)" 7
check "3c: and still records the timeout" "$(fst stage)" timeout
rm -f "$FX/fr.sleep"

if command -v flock >/dev/null 2>&1; then
    fr_reset
    ( exec 9>"$FR/mir/HIMMEL.lock"; flock 9; sleep 3 ) &
    holder=$!
    n=0
    while [ "$n" -lt 50 ] && ( exec 8>"$FR/mir/HIMMEL.lock"; flock -n 8 ); do sleep 0.1; n=$((n + 1)); done
    fr
    check "3c: a refresh that finds the lock held prints busy" "$(frout)" "focus=busy"
    check "3c: and exits 0 without running a step" "$(frrc)$([ -e "$FX/fr.log" ] && echo ran)" 0
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    check "3c: a busy refresh leaves a request marker" "$([ -s "$FR/doc/focus-state.again" ] && echo set || echo none)" set
    fr
    check "3c: the next refresh with no new request clears the marker" "$([ -e "$FR/doc/focus-state.again" ] && echo set || echo none)" none
    check "3c: and is clean" "$(fst dirty)" ""
    echo "$FR/doc/focus-state.again" > "$FX/fr.again"
    fr
    rm -f "$FX/fr.again"
    check "3c: a request that lands during a run leaves the state DIRTY" "$(fst dirty | grep -c '^[0-9][0-9]*$')" 1
    fr --status
    contains "3c: and --status reads DIRTY" "$(frout)" "focus=DIRTY:0m"
    fr
    check "3c: the next refresh clears the dirty mark" "$(fst dirty)" ""
fi

echo "---"
[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
