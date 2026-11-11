#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check(), as in test-worker-jira-status.sh
# scripts/handover/chief-kit/test-status-drift.sh - Hermetic tests for the
# WORKER comment (2a) and the status sweep (2b). A stubbed Jira
# CLI (WORKER_SESSION_JIRA_CLI), a stubbed gh on PATH and a stubbed queue lock
# (TICKET_STATUS_QUEUE_LOCK) read fixture files, so no real ticket, PR or lock
# is touched.
#   comment   the id is captured; edited in place, not re-posted; a 404 -> one
#             new comment; an unchanged class writes nothing
#   sweep     UI close and reopen are applied; one batched snapshot; a failed
#             read is unknown; lock-gone counting; the overrun cursor; no second
#             wake for an unchanged signature; the sweep writes no record
#
# Platform guard: POSIX bash 3.2+ (shell-only harness).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/worker-jira-status.sh"
SWEEP="$HERE/status-sweep.sh"
HOLD="$HERE/ticket-hold.sh"
DRIFT="$HERE/status-drift.sh"
# shellcheck source=../../lib/env-value.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/env-value.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/status-drift-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
# a worker shell carries the live chief doc; a move would mark its FOCUS page dirty
unset GH_REPO HIMMEL_CONSOLE_DOC
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]"; fails=$((fails+1)) ;; esac; }

export FX="$tmp/fx" STUB_LOG="$tmp/log"
export TICKET_STATUS_STATE_DIR="$tmp/state"
export JIRA_PROJECT_KEY=HIMMEL
# the merged-PR check reads ticket status from this mirror before it spends a live read: keep it off the real one
export TICK_TRACKER_MIRROR_DIR="$tmp/mirror"
mkdir -p "$tmp/bin"

cat >"$tmp/jira-stub.sh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
statusf() { if [ -e "$FX/status.$1" ]; then echo "$FX/status.$1"; else echo "$FX/status.cur"; fi; }
case "$1" in
    get)
        [ -e "$FX/get.sleep" ] && sleep "$(cat "$FX/get.sleep")"
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
        fv=$(printf '%s' "$*" | sed -n 's/.*fixVersion = "\([^"]*\)".*/\1/p')
        [ -z "$fv" ] || { [ -e "$FX/list.fv.fail" ] && { echo "boom" >&2; exit 1; }; cat "$FX/list.fv.$fv" 2>/dev/null; exit 0; }
        cat "$FX/list.tsv" 2>/dev/null
        exit 0 ;;
    versions)
        [ -e "$FX/versions.fail" ] && { echo "boom" >&2; exit 1; }
        cat "$FX/versions.tsv" 2>/dev/null
        exit 0 ;;
    comments)
        cat "$FX/comments.$2" 2>/dev/null
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
        case "$3" in http*)
            [ -e "$FX/xpr.fail" ] && { echo "HTTP 502" >&2; exit 1; }
            [ "$4 $5 $6 $7" = '--json state,title --jq .state + "\t" + .title' ] || { echo "gh stub: unexpected pr view args: $*" >&2; exit 2; }
            printf '%s\t%s\n' "$(cat "$FX/xpr.state")" "$(cat "$FX/xpr.title")"; exit 0 ;;
        esac
        if [ "$5" = headRefOid ]; then
            if [ -e "$FX/head-$3" ]; then cat "$FX/head-$3"; else jq -r --argjson n "$3" '.[] | select(.number == $n) | .headRefOid' "$FX/pr-list.json"; fi
        elif [ -e "$FX/view-$3.json" ]; then jq -r .title "$FX/view-$3.json"; else echo "no pull requests found" >&2; exit 1; fi ;;
    "pr list")
        case " $* " in *" merged "*)
            [ -e "$FX/pr-merged.fail" ] && { echo "HTTP 502" >&2; exit 1; }
            # the older 7-day slice (a bounded date range) reads its own list; the newer slice reads pr-merged.json
            case " $* " in
                *" merged:"*..*) if [ -e "$FX/pr-merged.old.json" ]; then cat "$FX/pr-merged.old.json"; else echo '[]'; fi ;;
                *) if [ -e "$FX/pr-merged.json" ]; then cat "$FX/pr-merged.json"; else echo '[]'; fi ;;
            esac
            exit 0 ;;
        esac
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
            over=$(cat "$FX/contexts.more" 2>/dev/null || echo 0)
            jq -c --arg more "$more" --argjson over "$over" '{data:{repository:{pullRequests:{pageInfo:{hasNextPage:($more == "true")},
                nodes: map({number, reviewThreads:{pageInfo:{hasNextPage:false},nodes:[{isResolved:true}]},
                    commits:{nodes:[{commit:{statusCheckRollup:{contexts:{pageInfo:{hasNextPage:(.number == $over)},nodes:[]}}}}]}})}}}}' "$FX/pr-list.json"
        fi ;;
    "api repos/{owner}/{repo}/commits/"*)
        sha=${2#repos/\{owner\}/\{repo\}/commits/}; sha=${sha%%/*}
        cat "$FX/check-runs-$sha.json" ;;
    "api repos/{owner}/{repo}/rules/branches/"*)
        cat "$FX/rules.json" ;;
    "api repos/{owner}/{repo}/branches/"*)
        echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
    *) echo "gh stub: unexpected $*" >&2; exit 1 ;;
esac
EOS
cat >"$tmp/lock-stub.sh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FX/lock.log"
rc=$(cat "$FX/lock.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] && { echo free; exit 0; }
now=$(date -u +%s)
hb=$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)
printf '{\n  "session": "s",\n  "heartbeat": "%s"\n}\nstatus: %s\n' "$hb" "$(cat "$FX/lock.status" 2>/dev/null || echo FRESH)"
exit "$rc"
EOS
chmod +x "$tmp/jira-stub.sh" "$tmp/bin/gh" "$tmp/lock-stub.sh"
export WORKER_SESSION_JIRA_CLI="$tmp/jira-stub.sh"
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
    printf '# worker\n\n## Results (newest at the bottom)\n' > "$1"
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
contains "2a: the body names the worker" "$(cat "$FX/comment-body.last")" "N1"
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

# A PR with more check runs than one GraphQL page reads its own checks, every page,
# and the sweep stays known: its red required check still moves the ticket.
reset "IN CI"; owned "$K" LIVE '{"state":"live","lock_seen":true,"lock_gone_sweeps":0,"prs":{"11":{"head":"ccc333","ci":"pending","red_latch":false,"open":true}}}'
pr 11 "[$K] many checks" ccc333; checks 11 fail
jq -c 'map(.statusCheckRollup = [])' "$FX/pr-list.json" > "$FX/p.t" && mv "$FX/p.t" "$FX/pr-list.json"
printf '11\n' > "$FX/contexts.more"
printf '%s\n%s\n' '{"check_runs":[{"id":1,"name":"shell-unit","status":"completed","conclusion":"failure","app":{"id":15368},"started_at":"2026-10-25T01:00:00Z"}]}' \
    '{"check_runs":[{"id":2,"name":"lint","status":"completed","conclusion":"success","app":{"id":15368},"started_at":"2026-10-25T01:00:00Z"}]}' > "$FX/check-runs-ccc333.json"
jl "$K" "IN CI"
sweep
contains "2b: a PR whose check runs overflow one page is no unknown sweep" "$(cat "$tmp/sout")" "status-sweep: keys="
check "2b: the snapshot reads the overflowing PR's checks with gh pr checks" "$(awk '/^gh pr checks 11 /{print "snapshot"; exit} /^get /{print "funnel"; exit}' "$STUB_LOG")" snapshot
check "2b: and its check runs with the paginated REST read" "$(grep -c '^gh api repos/{owner}/{repo}/commits/ccc333/check-runs?per_page=100 --paginate' "$STUB_LOG")" 1
check "2b: its red required check moves the ticket" "$(grep '^transition' "$STUB_LOG")" "transition $K In Progress"
# A push between the snapshot and those reads leaves the sweep unknown, never another commit's checks.
: > "$STUB_LOG"; printf 'ddd444\n' > "$FX/head-11"
sweep
contains "2b: a push during the overflow re-read is an unknown sweep" "$(cat "$tmp/sout")" "unknown (snapshot gh)"
check "2b: and moves nothing" "$(grep -c '^transition' "$STUB_LOG")" 0
rm -f "$FX/head-11" "$FX/contexts.more"

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

# A worker with no local lock seen (cloud or another station) never reaches D6.
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
check "2b: a cloud worker with no record never reaches D6" "$(ntrans)" 0

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

CLOG="$TICKET_STATUS_STATE_DIR/chain-log.jsonl"
reset "To Do"
hold "$K" --reason enforcement.md --owner chief --kind file-collision --on HIMMEL-8009; rc=$?
check "3a: a hold with a kind and the ticket it waits on exits 0" "$rc" 0
contains "3a: the HOLD comment names the kind" "$(cat "$FX/comment-body.last")" "kind: file-collision"
contains "3a: and what it waits on" "$(cat "$FX/comment-body.last")" "on: HIMMEL-8009"
check "3a: the event row carries the kind and the key" "$(rowq 'select(.event == "hold") | .kind + " " + .on')" "file-collision HIMMEL-8009"
check "3a: and one chain-log row" "$(jq -r '[.change, .key, .kind, .on, .who, .reason] | join(" ")' "$CLOG")" \
    "hold $K file-collision HIMMEL-8009 chief enforcement.md"
hold "$K" --release --owner chief
check "3a: a release appends one chain-log row" "$(jq -r 'select(.change == "release") | .key + " " + .who' "$CLOG")" "$K chief"
reset "To Do"
hold "$K" --reason r --owner o --kind date --until 2026-11-07
check "3a: a date hold's event row carries its date" "$(rowq 'select(.event == "hold") | .kind + " " + .until')" "date 2026-11-07"

reset "To Do"
hold "$K" --reason r --owner o
check "3a: a hold without --kind or --on writes the event row as before" "$(rowq 'select(.event == "hold") | has("kind") or has("on")')" false
check "3a: and no chain-log row" "$([ -e "$CLOG" ] && echo row || echo none)" none
reset "To Do"
hold "$K" --reason r --owner o --kind soon; rc=$?
check "3a: an unknown kind is a usage error" "$rc" 2
hold "$K" --reason r --owner o --kind date; rc=$?
check "3a: a date hold without --until is a usage error" "$rc" 2
hold "$K" --reason r --owner o --on not-a-key; rc=$?
check "3a: --on a non-key is a usage error" "$rc" 2
hold "$K" --reason r --owner o --on himmel-1; rc=$?
check "3a: --on a lowercase key is a usage error" "$rc" 2
hold "$K" --release --on HIMMEL-1; rc=$?
check "3a: a release takes no --on" "$rc" 2
check "3a: and these call no edit" "$(grep -c '^edit' "$STUB_LOG")" 0

reset "To Do"; owned "$K"; printf 'held\n' > "$FX/labels.$K"
fn "$K" --event live
check "3a: derive ignores a hold: a held ticket still moves" "$(grep '^transition' "$STUB_LOG")" "transition $K In Progress"

# --- 3b: the drift check ------------------------------------------------------
drift() { bash "$DRIFT" --docs-dir "$tmp/docs" >"$tmp/dout" 2>&1; }
drows() { grep -E "^$1 " "$tmp/dout"; }
dcount() { drows "$1" | wc -l | tr -d ' '; }
dlast() { tail -n 1 "$tmp/dout"; }
nwrites() { grep -cE '^(transition|comment|edit) ' "$STUB_LOG" || true; }
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

reset "In Review"; logrow merge "$K" miss 7 yes
printf '{"ts":"2026-10-21T10:00:05Z","event":"merge","key":"%s","result":"noop","rule":"D3","from":"In Review"}\n' "$K" >> "$LOG"
drift
contains "3b (HIMMEL-8522): a contract-less derive row under event merge does not hide the contract=yes row" "$(drows MERGE-MISMATCH)" "MERGE-MISMATCH $K"

# A merge row written before the merge call is a MERGE-MISMATCH only once its PR is proven merged.
cat > "$tmp/mrgh" <<'EOF'
#!/usr/bin/env bash
# the merge-rows filter gh seam: pr view <n> --json ...
case "$3" in 8601) echo "OPEN h1" ;; 8602) echo "MERGED h2" ;; *) exit 1 ;; esac
EOF
chmod +x "$tmp/mrgh"
prerow() { # <pr> <head> - a stage=pre-merge pending contract=yes row for $K
    mkdir -p "$TICKET_STATUS_STATE_DIR"
    printf '{"ts":"2026-10-21T10:00:00Z","event":"merge","key":"%s","pr":"%s","head":"%s","contract":"yes","result":"pending","stage":"pre-merge"}\n' "$K" "$1" "$2" >> "$LOG"
}
reset "In Review"; prerow 8601 h1
MERGE_ROWS_GH="$tmp/mrgh" drift
check "3b (HIMMEL-8616): a pre-merge row whose PR is still open is not a MERGE-MISMATCH" "$(dcount MERGE-MISMATCH)" 0
reset "In Review"; prerow 8602 h2
MERGE_ROWS_GH="$tmp/mrgh" drift
contains "3b (HIMMEL-8616): a pre-merge row whose PR GitHub reports MERGED is a MERGE-MISMATCH" "$(drows MERGE-MISMATCH)" "MERGE-MISMATCH $K"
reset "In Review"; prerow 8602 h2
printf '{"ts":"2026-10-21T10:00:01Z","event":"merge","key":"%s","pr":"8602","head":"h2","result":"not-merged","stage":"merge-failed"}\n' "$K" >> "$LOG"
MERGE_ROWS_GH="$tmp/mrgh" drift
check "3b (HIMMEL-8616): a not-merged row after the pre-merge row retires it" "$(dcount MERGE-MISMATCH)" 0

# A recent merged PR with no merge row whose first key is still open (report only).
mergedpr() { printf '%s\n' "$1" > "$FX/pr-merged.json"; }
reset "To Do"; mergedpr "[{\"number\":77,\"title\":\"fix: [$K] shipped by hand\"}]"
drift
contains "3b (HIMMEL-8834): a merged PR with no merge row and an open ticket is MERGED-NO-ROW" "$(drows MERGED-NO-ROW)" "MERGED-NO-ROW $K"
contains "3b (HIMMEL-8834): the row names the PR" "$(drows MERGED-NO-ROW)" "PR #77"
contains "3b (HIMMEL-8834): the row names the action" "$(drows MERGED-NO-ROW)" "close the ticket or record the remainder"
check "3b (HIMMEL-8834): the class is report-only" "$(nwrites)" 0
reset "Done"; mergedpr "[{\"number\":77,\"title\":\"fix: [$K] shipped by hand\"}]"
drift
check "3b (HIMMEL-8834): a Done ticket is not MERGED-NO-ROW" "$(dcount MERGED-NO-ROW)" 0
reset "To Do"; mergedpr "[{\"number\":77,\"title\":\"fix: [$K] shipped by hand\"}]"; logrow merge "$K" moved 77 no
drift
check "3b (HIMMEL-8834): a PR with a merge row is not MERGED-NO-ROW" "$(dcount MERGED-NO-ROW)" 0
reset "To Do"; mergedpr "[{\"number\":78,\"title\":\"fix: [HIMMEL-90019] y follows [$K]\"},{\"number\":79,\"title\":\"chore: no key\"}]"
drift
check "3b (HIMMEL-8834): only the first [KEY] of a merged title counts (a later key gets no row)" "$(drows MERGED-NO-ROW | grep -c "MERGED-NO-ROW $K ")" 0
check "3b (HIMMEL-8834): the first key gets its row, and a keyless title adds none" "$(dcount MERGED-NO-ROW)" 1
reset "To Do"; touch "$FX/pr-merged.fail"
drift
check "3b (HIMMEL-8834): an unreadable merged-PR list is a HEALTH row, never MERGED-NO-ROW" "$(dcount MERGED-NO-ROW)/$(dcount HEALTH)" 0/1
# The merged list is a 14-day window read in two 7-day slices (one 14-day read filled the 1000-PR limit), not the newest 30.
dago() { date -u -d "$1 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"$1"d +%Y-%m-%d; }
reset "To Do"; mergedpr "[{\"number\":77,\"title\":\"fix: [$K] shipped by hand\"}]"
drift
contains "3b (HIMMEL-8834): the older 7-day slice is a bounded date range from 14 to 8 days ago" "$(grep -- '--state merged' "$STUB_LOG")" "--search merged:$(dago 14)..$(dago 8)"
contains "3b (HIMMEL-8834): the newer slice starts 7 days ago" "$(grep -- '--state merged' "$STUB_LOG")" "--search merged:>=$(dago 7)"
contains "3b (HIMMEL-8834): and each slice reads up to 1000 PRs" "$(grep -- '--state merged' "$STUB_LOG")" "--limit 1000"
check "3b (HIMMEL-8834): and makes exactly two merged-PR calls" "$(grep -c -- '--state merged' "$STUB_LOG" || true)" 2
check "3b (HIMMEL-8834): slices under the limit raise no HEALTH row" "$(dcount HEALTH)" 0
reset "To Do"; mergedpr "[{\"number\":77,\"title\":\"fix: [$K] shipped by hand\"}]"; printf '%s\n' '[{"number":60,"title":"fix: [HIMMEL-9002] older slice"}]' > "$FX/pr-merged.old.json"
drift
contains "3b (HIMMEL-8834): a PR of the older slice is checked too" "$(drows MERGED-NO-ROW)" "MERGED-NO-ROW HIMMEL-9002 PR #60"
reset "To Do"; mergedpr "[{\"number\":77,\"title\":\"fix: [$K] a\"},{\"number\":78,\"title\":\"fix: [$K] b\"}]"
TICKET_STATUS_DRIFT_MNR_LIMIT=2 drift
contains "3b (HIMMEL-8834): a slice that reaches its limit is a HEALTH row, not a silent cut" "$(drows HEALTH)" "reached the 2-PR limit"
reset "To Do"; mergedpr "[{\"number\":77,\"title\":\"fix: [$K] a\"},{\"number\":78,\"title\":\"fix: [$K] b\"}]"
drift
check "3b (HIMMEL-8834): two unrecorded PRs of one key give one row, naming the newest" "$(dcount MERGED-NO-ROW)/$(drows MERGED-NO-ROW | grep -c 'PR #78')" 1/1
reset "To Do"; mergedpr "[{\"number\":77,\"title\":\"fix: [$K] a\"}]"; mkdir -p "$TICKET_STATUS_STATE_DIR"; mkdir "$LOG"
drift
check "3b (HIMMEL-8834): an unreadable merge log is a HEALTH row, never MERGED-NO-ROW for every merged PR" "$(dcount MERGED-NO-ROW)/$(drows HEALTH | grep -c 'merge rows are unreadable')" 0/1
if [ "$(id -u)" != 0 ]; then
    reset "To Do"; mergedpr "[{\"number\":77,\"title\":\"fix: [$K] a\"}]"; logrow merge HIMMEL-1 moved 1 yes; chmod 000 "$LOG"
    drift
    check "3b (HIMMEL-8834): a merge log the pass cannot read is the same HEALTH row" "$(dcount MERGED-NO-ROW)/$(drows HEALTH | grep -c 'merge rows are unreadable')" 0/1
    chmod 600 "$LOG"
fi
# A merge row is compared by PR: an older merged PR's row does not hide a later hand-merged PR of the same key.
reset "To Do"; mergedpr "[{\"number\":77,\"title\":\"fix: [$K] shipped by hand\"}]"; logrow merge "$K" moved 70 yes
drift
contains "3b (HIMMEL-8834): an older PR's merge row does not hide a later hand-merged PR" "$(drows MERGED-NO-ROW)" "MERGED-NO-ROW $K PR #77"
reset "To Do"; mergedpr "[{\"number\":77,\"title\":\"fix: [$K] shipped by hand\"},{\"number\":70,\"title\":\"fix: [$K] first\"}]"; logrow merge "$K" moved 70 yes
drift
check "3b (HIMMEL-8834): one row per ticket, naming the newest unrecorded PR" "$(dcount MERGED-NO-ROW)" 1
reset "To Do"; mergedpr "[{\"number\":77,\"title\":\"fix: [$K] shipped by hand\"}]"; logrow merge "$K" moved "" yes
drift
check "3b (HIMMEL-8834): a merge row with no PR number covers every PR of its key" "$(dcount MERGED-NO-ROW)" 0
# The Jira reads of the class are bounded by a time budget, not a count: Done tickets never use it up
# for the older open ones, and the PRs left unread are one HEALTH row.
manypr='[range(0; 42) | {number: (9100 + .), title: ("fix: [HIMMEL-" + ((9100 + .) | tostring) + "] x")}]'
reset "Done"; mergedpr "$(jq -nc "$manypr")"
drift
check "3b (HIMMEL-8834): 42 Done tickets with unrecorded PRs are all read, none reported" "$(dcount MERGED-NO-ROW)/$(dcount HEALTH)" 0/0
reset "To Do"; mergedpr "$(jq -nc "$manypr")"
TICKET_STATUS_DRIFT_MNR_BUDGET=0 drift
check "3b (HIMMEL-8834): a spent read budget reads no more keys" "$(dcount MERGED-NO-ROW)" 0
contains "3b (HIMMEL-8834): and the unread PRs are one HEALTH row" "$(drows HEALTH)" "42 merged PRs not checked"
contains "3b (HIMMEL-8834): that says open tickets may be among them" "$(drows HEALTH)" "open tickets may be among them"
contains "3b (HIMMEL-8834): and names the first keys" "$(drows HEALTH)" "first keys: HIMMEL-9141 HIMMEL-9140"
# The read budget is tied to the time left in the pass: a pass budget with less than the 25 s kept for the later classes leaves none.
reset "To Do"; mergedpr "$(jq -nc "$manypr")"
TICKET_STATUS_DRIFT_BUDGET=20 drift
check "3b (HIMMEL-8834): a pass with no time left reads no keys" "$(dcount MERGED-NO-ROW)" 0
contains "3b (HIMMEL-8834): and says so in one HEALTH row" "$(drows HEALTH)" "42 merged PRs not checked"
# The default budget (40 s) and an invalid override fit three 1-second reads.
three='[{"number":9201,"title":"fix: [HIMMEL-9201] x"},{"number":9202,"title":"fix: [HIMMEL-9202] x"},{"number":9203,"title":"fix: [HIMMEL-9203] x"}]'
reset "To Do"; mergedpr "$three"; printf '1\n' > "$FX/get.sleep"
drift
check "3b (HIMMEL-8834): the default read budget covers three 1-second reads" "$(dcount MERGED-NO-ROW)/$(dcount HEALTH)" 3/0
reset "To Do"; mergedpr "$three"; printf '1\n' > "$FX/get.sleep"
TICKET_STATUS_DRIFT_MNR_BUDGET=abc drift
check "3b (HIMMEL-8834): an invalid read budget falls back to the default" "$(dcount MERGED-NO-ROW)/$(dcount HEALTH)" 3/0

# A live read costs ~0.34 s of node start each, so one run's budget left PRs unread however often it ran.
# The status and type of a merged PR's ticket come from the local Jira mirror first (a file read, no budget); only a
# ticket the mirror lacks is read live, inside the budget, and a PR left unread stays one HEALTH row.
mirrorrow() { # <KEY> <status> [type] - one mirror file, frontmatter only
    mkdir -p "$TICK_TRACKER_MIRROR_DIR"
    printf -- '---\nkey: "%s"\ntype: "%s"\nstatus: "%s"\n---\n\n# %s: x\n' "$1" "${3:-Task}" "$2" "$1" > "$TICK_TRACKER_MIRROR_DIR/$1.md"
}
mirrorall() { # <status> [type] - a mirror file for each key of $manypr
    local i=0
    while [ "$i" -lt 42 ]; do mirrorrow "HIMMEL-$((9100 + i))" "$1" "${2:-Task}"; i=$((i + 1)); done
}
mgets() { grep -c '^get HIMMEL-91' "$STUB_LOG" || true; }
reset "To Do"; mergedpr "$(jq -nc "$manypr")"; mirrorall "To Do"
TICKET_STATUS_DRIFT_MNR_BUDGET=0 drift
check "3b (HIMMEL-9003): with a mirror, a spent read budget still checks all 42 PRs and reports none" "$(dcount MERGED-NO-ROW)/$(dcount HEALTH)" 42/0
check "3b (HIMMEL-9003): and no merged key is read live" "$(mgets)" 0
TICKET_STATUS_DRIFT_MNR_BUDGET=0 drift
check "3b (HIMMEL-9003): a repeated run gives the same 42 rows and no HEALTH row" "$(dcount MERGED-NO-ROW)/$(dcount HEALTH)" 42/0
reset "To Do"; mergedpr "$(jq -nc "$manypr")"; mirrorall "Done"
TICKET_STATUS_DRIFT_MNR_BUDGET=0 drift
check "3b (HIMMEL-9003): the mirror's status wins: Done in the mirror is no row, whatever a live read says" "$(dcount MERGED-NO-ROW)/$(dcount HEALTH)" 0/0
reset "To Do"; mergedpr "$(jq -nc "$manypr")"; mirrorall "To Do" Epic
TICKET_STATUS_DRIFT_MNR_BUDGET=0 drift
check "3b (HIMMEL-9003): an Epic in the mirror is no row" "$(dcount MERGED-NO-ROW)/$(dcount HEALTH)" 0/0
# control: a ticket the mirror lacks is read live inside the budget, and past it the PR stays in the HEALTH row
reset "To Do"; mergedpr "$(jq -nc "$manypr")"; mirrorall "To Do"; rm -f "$TICK_TRACKER_MIRROR_DIR/HIMMEL-9100.md" "$TICK_TRACKER_MIRROR_DIR/HIMMEL-9101.md"
drift
check "3b (HIMMEL-9003): a ticket missing from the mirror is read live within the budget" "$(dcount MERGED-NO-ROW)/$(dcount HEALTH)/$(mgets)" 42/0/2
reset "To Do"; mergedpr "$(jq -nc "$manypr")"; mirrorall "To Do"; rm -f "$TICK_TRACKER_MIRROR_DIR/HIMMEL-9100.md" "$TICK_TRACKER_MIRROR_DIR/HIMMEL-9101.md"
TICKET_STATUS_DRIFT_MNR_BUDGET=0 drift
check "3b (HIMMEL-9003): and past the budget it is still one HEALTH row while PRs remain unchecked" "$(dcount MERGED-NO-ROW)/$(dcount HEALTH)" 40/1
contains "3b (HIMMEL-9003): that row counts the two unread PRs and names their keys" "$(drows HEALTH)" "merged-no-row: 2 merged PRs not checked"
contains "3b (HIMMEL-9003): and the keys" "$(drows HEALTH)" "first keys: HIMMEL-9101 HIMMEL-9100"
# a mirror file that cannot be parsed falls back to the live read
reset "To Do"; mergedpr "$(jq -nc "$manypr")"; mirrorall "To Do"; printf 'garbage\n' > "$TICK_TRACKER_MIRROR_DIR/HIMMEL-9100.md"
drift
check "3b (HIMMEL-9003): a mirror file without status or type is read live" "$(dcount MERGED-NO-ROW)/$(mgets)" 42/1
rm -rf "$TICK_TRACKER_MIRROR_DIR"

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
reset "Done"; logrow merge "$K" miss 7 yes
drift
check "3b: a miss on a ticket that is Done now is not MISSED (re-derived)" "$(dcount MISSED)" 0

reset "In Progress"; owned "$K" WRAPPED '{"state":"live"}'; jl "$K" "In Progress"
drift
contains "3b: a live record whose doc is WRAPPED is WORKER-STALE" "$(drows WORKER-STALE)" "WORKER-STALE $K"
reset "In Progress"; owned "$K" WRAPPED '{"state":"parked"}'; jl "$K" "In Progress"
drift
contains "3b: a parked record whose doc is WRAPPED is WORKER-STALE" "$(drows WORKER-STALE)" "WORKER-STALE $K"
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
wipe_docs; mkdoc "$tmp/docs/$K-N2-other-2026-10-21.md" PARKED-USAGE
drift
contains "3b: a parked second doc with a held lock is TWO-OWNERS" "$(drows TWO-OWNERS)" "TWO-OWNERS $K"
wipe_docs; mkdoc "$tmp/docs/$K-N2-other-2026-10-21.md" WRAPPED
drift
check "3b: a wrapped second doc is not an owner" "$(dcount TWO-OWNERS)" 0
wipe_docs; mkdoc "$tmp/docs/HIMMEL-90019-N2-other-2026-10-21.md" LIVE
drift
check "3b: another key's doc is not an owner (exact key, not a prefix)" "$(dcount TWO-OWNERS)" 0
# a shell with no HANDOVER_DIR and no --docs-dir scans the root the repo's .env configures, not the stub folder
FXR="$tmp/fxrepo"; CFG="$tmp/cfgroot"
rm -rf "$FXR" "$CFG"
mkdir -p "$FXR/scripts/handover" "$FXR/handovers" "$CFG"
git -C "$FXR" init -q -b main
cp -R "$HERE/../../lib" "$FXR/scripts/lib"; cp -R "$HERE" "$FXR/scripts/handover/chief-kit"
printf 'HANDOVER_DIR=%s\n' "$CFG" > "$FXR/.env"
reset "In Progress"; wipe_docs; owned "$K" LIVE '{"state":"live"}'; jl "$K" "In Progress"
mkdoc "$CFG/$K-N2-other-2026-10-21.md" LIVE
mkdir -p "$tmp/fxhome"
(cd "$FXR" && env -u HANDOVER_DIR -u HIMMEL_CONFIG_DIR HOME="$tmp/fxhome" bash "$FXR/scripts/handover/chief-kit/status-drift.sh" --repo acme/fork >"$tmp/dout" 2>&1)
contains "3b: no HANDOVER_DIR: a second live doc under the configured root is TWO-OWNERS" "$(drows TWO-OWNERS)" "TWO-OWNERS $K"
wipe_docs

reset "In Progress"; jl "$K" "In Progress"
drift
contains "3b: started, no open PR and no owner is UNOWNED" "$(drows UNOWNED)" "UNOWNED $K"
# The row of a ticket a partial merge left In Progress (rule D5c) names that PR and the one action that clears it
reset "In Progress"; jl "$K" "In Progress"; logrow merge "$K" noop 4480 no
drift
contains "3b (HIMMEL-8673): the UNOWNED row of a partly merged ticket names its partial PR" "$(drows UNOWNED)" "partial merge PR #4480"
contains "3b (HIMMEL-8673): and the action: dispatch the RESUME row or close it on HANDED-OFF" "$(drows UNOWNED)" "next-dispatchable.sh"
contains "3b (HIMMEL-8673): and the third case: NEEDS-CHIEF-NOTE is cleared in the partial PR's body" "$(drows UNOWNED)" "NEEDS-CHIEF-NOTE, add the remainder to the partial PR's body"
reset "In Progress"; jl "$K" "In Progress"; logrow merge "$K" noop 4480 no; logrow merge "$K" moved 4481 yes
drift
check "3b (HIMMEL-8673): a completing merge after the partial one names no partial PR" "$(drows UNOWNED | grep -c 'partial merge PR')" 0
# the partial PR is read from the WHOLE log, not the last 500 rows: a partial merge more than 500 rows old is still named
reset "In Progress"; jl "$K" "In Progress"; logrow merge "$K" noop 4480 no
for _ in $(seq 650); do printf '{"ts":"2026-10-21T10:00:00Z","event":"derive","key":"HIMMEL-90001","result":"noop","pr":"1"}\n' >> "$LOG"; done
drift
contains "3b (HIMMEL-8673): a partial merge older than the last 500 rows is still named" "$(drows UNOWNED)" "partial merge PR #4480"
# every partial PR of the ticket is named once, oldest first
reset "In Progress"; jl "$K" "In Progress"; logrow merge "$K" noop 4480 no; logrow merge "$K" noop 4481 no; logrow merge "$K" noop 4480 no
drift
contains "3b (HIMMEL-8673): every partial PR is named, a repeated one once" "$(drows UNOWNED)" "partial merge PR #4480, #4481 |"
# another ticket's partial merge, or this ticket's non-merge row, names no PR
reset "In Progress"; jl "$K" "In Progress"; logrow merge "HIMMEL-90001" noop 4490 no; logrow derive "$K" moved 4491 no
drift
check "3b (HIMMEL-8673): another key's partial merge and a derive row name no PR" "$(drows UNOWNED | grep -c 'partial merge PR')" 0
# a later merge row with no contract field (an older funnel's) does not undo the partial
reset "In Progress"; jl "$K" "In Progress"; logrow merge "$K" noop 4480 no
printf '{"ts":"2026-10-21T10:00:01Z","event":"merge","key":"%s","result":"moved","pr":"4482"}\n' "$K" >> "$LOG"
drift
contains "3b (HIMMEL-8673): a contract-less merge row after the partial one leaves it named" "$(drows UNOWNED)" "partial merge PR #4480 |"
reset "In Progress"; jl "$K" "In Progress"; logrow merge "$K" noop 4480 no; logrow merge "$K" moved 4483
drift
contains "3b (HIMMEL-8673): a merge row with an empty contract after the partial one leaves it named" "$(drows UNOWNED)" "partial merge PR #4480 |"
# only the contract=no rows' PRs are named: an earlier completing merge's PR is not
reset "In Progress"; jl "$K" "In Progress"; logrow merge "$K" moved 4481 yes; logrow merge "$K" noop 4480 no
drift
contains "3b (HIMMEL-8673): a completing merge before the partial one is not named" "$(drows UNOWNED)" "partial merge PR #4480 |"
reset "In Progress"; owned "$K" LIVE '{"state":"live"}'; jl "$K" "In Progress"
drift
check "3b: a live owner means not UNOWNED" "$(dcount UNOWNED)" 0
reset "In Progress"; jl "$K" "In Progress"; pr 7 "[$K] feat" aaa111; checks 7 fail
drift
check "3b: an open PR means not UNOWNED" "$(dcount UNOWNED)" 0

NOW=1794139200
export TICKET_STATUS_NOW=$NOW
iso_at() { # <seconds before NOW> - an ISO time (negative = after NOW)
    local e=$((NOW - $1))
    date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ
}
lrow() { # <seconds before NOW> <event> <result> <rule or -> [extra json] - a row for $K, oldest first
    mkdir -p "$TICKET_STATUS_STATE_DIR"
    jq -nc --arg ts "$(iso_at "$1")" --arg e "$2" --arg k "$K" --arg r "$3" --arg rule "$4" --argjson x "${5:-{\}}" \
        '{ts: $ts, event: $e, key: $k, result: $r} + (if $rule == "-" then {} else {rule: $rule} end) + $x' >> "$LOG"
}
d6own() { # <yes|no> - a record owned by a WRAPPED doc whose brief says Completes ticket: <yes|no>
    local hash
    hash=$(printf '%s|%s|%s|%s' N1 wrapped '' 'In Progress' | cksum | awk '{ print $1 }')
    owned "$K" WRAPPED "$(jq -nc --arg t "$(iso_at 60)" --arg h "$hash" '{last_event_ts: $t, comment_hash: $h}')"
    printf '# worker\n\n> **Completes ticket:** %s\n\n## Results (newest at the bottom)\n- 10:00 WRAPPED — x\n' "$1" > "$tmp/$K-N1-slug-2026-10-21.md"
}
d6fx() { reset "In Progress"; jl "$K" "In Progress"; d6own no; }
driftenv() { env "$@" bash "$DRIFT" --docs-dir "$tmp/docs" >"$tmp/dout" 2>&1; }
nrelease() { cat "$FX/lock.log" 2>/dev/null | grep -c '^release' || true; }
lockfx() { printf '%s\n' "$1" > "$FX/lock.rc"; printf '%s\n' "$2" > "$FX/lock.status"; }

d6fx; lrow 3600 wrapped noop D6n; lrow 60 sweep noop D6n
drift
check "9561 S1 1: a chief-owned D6n park of 1 h is one AWAITING row" "$(dcount AWAITING)" 1
contains "9561 S1 1: it waits on the chief" "$(drows AWAITING)" "wait=chief"
contains "9561 S1 1: its source is the D6n park" "$(drows AWAITING)" "source=d6n"
contains "9561 S1 1: its since is the first D6n row" "$(drows AWAITING)" "since=$(iso_at 3600) "
contains "9561 S1 1: its due is 24 h after the first D6n row" "$(drows AWAITING)" "due=$(iso_at -82800) "
check "9561 S1 1: and the key is not UNOWNED" "$(dcount UNOWNED)" 0
contains "9561 S1 1: a wait row is no drift: sdrift=0" "$(dlast)" "sdrift=0:"
check "9561 S1 9: the pass wrote nothing" "$(nwrites)" 0
check "9561 S1 9: and released no lock" "$(nrelease)" 0

d6fx; lrow 90000 wrapped noop D6n; lrow 60 sweep noop D6n
drift
check "9561 S1 2: a D6n park of 25 h is no AWAITING row" "$(dcount AWAITING)" 0
contains "9561 S1 2: it is UNOWNED, awaiting the chief since the first D6n row" "$(drows UNOWNED)" "awaiting the chief since $(iso_at 90000)"
contains "9561 S1 2: and says overdue" "$(drows UNOWNED)" "overdue"
contains "9561 S1 2: and counts as drift: sdrift=1" "$(dlast)" "sdrift=1:"

d6fx; lrow 90000 wrapped noop D6n; lrow 7200 live skip RM; lrow 7200 live disabled -; lrow 7200 sweep deferred - '{"stage":"lock"}'; lrow 7200 sweep noop D5; lrow 60 sweep noop D6n
drift
check "9561 S1 3a: an RM skip, a disabled, a deferred and a D5 noop row inside the run do not restart it" "$(dcount AWAITING)" 0
contains "9561 S1 3a: the park is overdue since the first D6n row" "$(drows UNOWNED)" "awaiting the chief since $(iso_at 90000)"
d6fx; lrow 108000 wrapped noop D6n; lrow 7200 live noop D5; lrow 3600 wrapped noop D6n; lrow 60 sweep noop D6n
drift
contains "9561 S1 3b: an event=live row starts a new run: since is the newer run's first row" "$(drows AWAITING)" "since=$(iso_at 3600) "
d6fx; lrow 7200 wrapped noop D6n; lrow 3600 pr-open moved D5
drift
check "9561 S1 3c: a moved row of another rule after the last D6n row leaves no park start" "$(dcount AWAITING)" 0
check "9561 S1 3c: and the plain UNOWNED row stands" "$(drows UNOWNED | grep -c 'awaiting the chief')/$(dcount UNOWNED)" 0/1
d6fx; lrow 90000 wrapped noop D6n; lrow 7200 hold moved D6n; lrow 60 sweep noop D6n
drift
check "9561 S1 3d: a hold row inside the run starts nothing" "$(dcount AWAITING)" 0
contains "9561 S1 3d: the park is overdue since the first D6n row" "$(drows UNOWNED)" "awaiting the chief since $(iso_at 90000)"
d6fx; lrow 3600 wrapped moved D6n
drift
contains "9561 S1 3e (a synthetic guard of the at-or-after rule: no moved D6n row exists live): an anchor that carries the rule is the park start" "$(drows AWAITING)" "since=$(iso_at 3600) "
d6fx; lrow 90000 wrapped noop D6n; lrow 7200 merge pending - '{"pr":"8601","head":"h1","contract":"no","stage":"pre-merge"}'; lrow 60 sweep noop D6n
MERGE_ROWS_GH="$tmp/mrgh" drift
check "9561 S1 3f: a pre-merge row whose PR is open is dropped and is no anchor" "$(dcount AWAITING)" 0
contains "9561 S1 3f: the park is overdue since the first D6n row" "$(drows UNOWNED)" "awaiting the chief since $(iso_at 90000)"

reset "In Progress"; jl "$K" "In Progress"; owned "$K" LIVE '{"state":"live","lock_seen":true,"lock_gone_sweeps":2}'; logrow merge "$K" noop 4480 no; printf '0\n' > "$FX/lock.rc"
drift
check "9561 S1 4: a D5c key whose lock was gone for two sweeps is UNOWNED" "$(dcount UNOWNED)" 1
reset "In Progress"; jl "$K" "In Progress"; owned "$K" LIVE '{"state":"live","lock_seen":true,"lock_gone_sweeps":1}'; logrow merge "$K" noop 4480 no; printf '0\n' > "$FX/lock.rc"
drift
check "9561 S1 4 control: one gone sweep is not UNOWNED" "$(dcount UNOWNED)" 0

reset "To Do"
drift
contains "9561 S1 5: an empty run prints sdrift=0" "$(dlast)" "sdrift=0:"

reset "To Do"; jl "$K" "To Do"; d6own yes
drift
check "9561 S1 6 control: a brief saying yes (derives D6) prints no AWAITING and no UNOWNED" "$(dcount AWAITING)/$(dcount UNOWNED)" 0/0
reset "In Progress"; jl "$K" "In Progress"; d6own yes; lrow 3600 wrapped noop D6n
drift
check "9561 S1 6 control: a brief saying yes is no chief-owned park even over D6n rows" "$(dcount AWAITING)" 0

d6fx; lrow 3600 wrapped noop D6n; lrow 60 sweep noop D6n
for v in abc 99999999999999999999h; do
    driftenv TICKET_STATUS_AWAIT_TTL_CHIEF=$v
    check "9561 S1 7: TTL_CHIEF=$v prints one HEALTH row" "$(drows HEALTH | grep -c 'env: TICKET_STATUS_AWAIT_TTL_CHIEF')/$(dcount HEALTH)" 1/1
    check "9561 S1 7: and the row never prints the value" "$(drows HEALTH | grep -c -- "$v")" 0
    contains "9561 S1 7: TTL_CHIEF=$v keeps the 24 h due" "$(drows AWAITING)" "due=$(iso_at -82800) "
done
driftenv TICKET_STATUS_AWAIT_MAX=30d TICKET_STATUS_AWAIT_TTL_CHIEF=400d
check "9561 S1 7: MAX=30d prints the HEALTH row" "$(drows HEALTH | grep -c 'env: TICKET_STATUS_AWAIT_MAX')" 1
contains "9561 S1 7: and the due is clamped at 14 d" "$(drows AWAITING)" "due=$(iso_at $((3600 - 1209600))) "
driftenv TICKET_STATUS_AWAIT_TTL_CHIEF=2h
contains "9561 S1 7: TTL_CHIEF=2h makes the 1 h park due in 1 h" "$(drows AWAITING)" "due=$(iso_at -3600) "
check "9561 S1 7: and prints no HEALTH row" "$(dcount HEALTH)" 0

reset "In Progress"; jl "$K" "In Progress"; owned "$K" LIVE '{"state":"live"}'; lockfx 12 STALE-DEAD
drift
check "9561 S1 8: a D5 key over a STALE-DEAD lock is one UNOWNED row" "$(dcount UNOWNED)" 1
contains "9561 S1 8: its fix names the reap" "$(drows UNOWNED)" "queue-lock.sh status --sweep --reap-dead"
contains "9561 S1 8: and says the reap appends a HALTED bullet" "$(drows UNOWNED)" "the reap appends a HALTED bullet, so the next derive reads $K wrapped"
contains "9561 S1 8: and that it releases every STALE-DEAD lock under the root" "$(drows UNOWNED)" "releases every STALE-DEAD lock under the root, each re-proved under its claim and CAS"
check "9561 S1 9: the pass wrote nothing" "$(nwrites)" 0
check "9561 S1 9: and released no lock" "$(nrelease)" 0
reset "In Progress"; jl "$K" "In Progress"; owned "$K" LIVE '{"state":"live"}'; lockfx 12 STALE
drift
check "9561 S1 8 control: rc 12 STALE is still an owner" "$(dcount UNOWNED)" 0
reset "In Progress"; jl "$K" "In Progress"; owned "$K" PARKED-USAGE '{"state":"parked"}'; lockfx 12 STALE-DEAD
drift
check "9561 S1 8: a parked worker over a STALE-DEAD lock is no worker" "$(dcount UNOWNED)" 1
contains "9561 S1 8: and the fix names the reap" "$(drows UNOWNED)" "queue-lock.sh status --sweep --reap-dead"
reset "In Progress"; jl "$K" "In Progress"; owned "$K" PARKED-USAGE '{"state":"parked"}'; lockfx 12 STALE
drift
check "9561 S1 8 control: a parked worker over rc 12 STALE keeps its owner" "$(dcount UNOWNED)" 0
reset "In Progress"; jl "$K" "In Progress"; owned "$K" PARKED-USAGE '{"state":"parked"}'; lockfx 11 FRESH
drift
check "9561 S1 8 control: a parked worker over a FRESH lock keeps its owner" "$(dcount UNOWNED)" 0

epoch_of() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s; }
iso_e() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
day_e() { date -u -d "@$1" +%Y-%m-%d 2>/dev/null || date -u -r "$1" +%Y-%m-%d; }
hts() { rowq 'select(.event == "hold") | .ts' | tail -n 1; }
hnow() { export TICKET_STATUS_NOW=$(($(epoch_of "$(hts)") + $1)); }
tomorrow() { day_e $(($(date -u +%s) + 86400)); }
label() { printf 'held\n' > "$FX/labels.$K"; }
hand() {
    lrow "$1" hold moved - "$2"
    export TICKET_STATUS_NOW=$NOW
}
drift_bsd() { PATH="$bsdpath" bash "$DRIFT" --docs-dir "$tmp/docs" >"$tmp/dout" 2>&1; }
bsdhold() { PATH="$bsdpath" bash "$HOLD" "$@" >"$tmp/hout" 2>&1; }
bsdpath=$PATH
if date -u -d 2026-01-01 +%s >/dev/null 2>&1; then # gnu-ok: the probe itself, the shim below needs a GNU date
    mkdir -p "$tmp/bsd"
    cat >"$tmp/bsd/date" <<'EOS'
#!/usr/bin/env bash
real=$BSD_SHIM_REAL_DATE
orig=("$@")
j=0 r="" v="" out="" fmt="" str=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -d) echo "date: illegal option -- d" >&2; exit 1 ;;
        -j) j=1; shift ;;
        -f) fmt=${2:-}; str=${3:-}; shift 3 ;;
        -r) r=${2:-}; shift 2 ;;
        -v*) v=${1#-v-}; v=${v%d}; shift ;;
        +*) out=$1; shift ;;
        *) shift ;;
    esac
done
if [ "$j" = 1 ]; then
    case "$fmt" in
        %Y-%m-%d)
            base=$("$real" -u -d "${str:0:7}-01" +%s) || exit 1
            e=$((base + (10#${str:8:2} - 1) * 86400)) ;;
        *) e=$("$real" -u -d "$str" +%s) || exit 1 ;;
    esac
    exec "$real" -u -d "@$e" "$out"
fi
[ -z "$r" ] || exec "$real" -u -d "@$r" "$out"
[ -z "$v" ] || exec "$real" -u -d "$v days ago" "$out"
exec "$real" "${orig[@]}"
EOS
    chmod +x "$tmp/bsd/date"
    BSD_SHIM_REAL_DATE=$(command -v date)
    export BSD_SHIM_REAL_DATE
    bsdpath="$tmp/bsd:$PATH"
fi

d6fx
u1=$(tomorrow)
hold "$K" --reason "waiting on legal" --owner operator --until "$u1"; rc=$?
check "9561 S2 1: the hold exits 0" "$rc" 0
check "9561 S2 1: the hold row records the owner" "$(rowq 'select(.event == "hold") | .owner')" operator
check "9561 S2 1: and the until, with no --kind" "$(rowq 'select(.event == "hold") | .until')" "$u1"
hnow 0
drift
check "9561 S2 1: a held, wrapped, no-PR key is one AWAITING row" "$(dcount AWAITING)" 1
contains "9561 S2 1: it waits on the operator" "$(drows AWAITING)" "wait=operator"
contains "9561 S2 1: its source is the hold" "$(drows AWAITING)" "source=hold"
contains "9561 S2 1: its since is the hold row's ts" "$(drows AWAITING)" "since=$(hts) "
contains "9561 S2 1: its due is the end of the until day" "$(drows AWAITING)" "due=${u1}T23:59:59Z "
contains "9561 S2 1: its what is the reason" "$(drows AWAITING)" "what=waiting on legal "
contains "9561 S2 1: it names the owner as the class's first word" "$(drows AWAITING)" "AWAITING $K operator since="
check "9561 S2 1: and the key is not UNOWNED" "$(dcount UNOWNED)" 0
contains "9561 S2 1: a wait row is no drift: sdrift=0" "$(dlast)" "sdrift=0:"

hnow 172800
drift
check "9561 S2 2: at the hold day + 2 the key is no AWAITING row" "$(dcount AWAITING)" 0
contains "9561 S2 2: it is UNOWNED and overdue" "$(drows UNOWNED)" "overdue"
d6fx
hold "$K" --reason r --owner operator --until "$(day_e $(($(date -u +%s) + 2592000)))"
hnow 0
drift
contains "9561 S2 2: an until 30 days out is clamped to the hold ts + 14 d" "$(drows AWAITING)" "due=$(iso_e $(($(epoch_of "$(hts)") + 1209600))) "

d6fx
hold "$K" --reason r --owner operator --until "$(tomorrow)"
hold "$K" --release --owner operator
hnow 0
drift
check "9561 S2 3: after a release the key is plain UNOWNED" "$(dcount UNOWNED)/$(dcount AWAITING)" 1/0
check "9561 S2 3: and says nothing of a label" "$(drows UNOWNED | grep -c 'held with no owner')" 0

d6fx
touch "$FX/edit.fail"
hold "$K" --reason r --owner operator --until "$(tomorrow)"
hnow 0
drift
check "9561 S2 4: a hold whose Jira edit failed (result=miss) is plain UNOWNED" "$(dcount UNOWNED)/$(dcount AWAITING)" 1/0

d6fx
mkdir -p "$tmp/mirror"
printf -- '---\nlabels: ["held"]\n---\n' > "$tmp/mirror/$K.md"
export TICKET_STATUS_NOW=$NOW
drift
check "9561 S2 5a: a mirror label and no hold row is one UNOWNED row" "$(dcount UNOWNED)/$(dcount AWAITING)" 1/0
contains "9561 S2 5a: saying held with no owner on record" "$(drows UNOWNED)" "held with no owner on record"
rm -rf "$tmp/mirror"
d6fx; label
hand 3600 '{"reason":"r"}'
drift
check "9561 S2 5b: a hold row with no owner is one UNOWNED row" "$(dcount UNOWNED)/$(dcount AWAITING)" 1/0
contains "9561 S2 5b: saying held with no owner on record" "$(drows UNOWNED)" "held with no owner on record"
d6fx; label
hand 3600 '{"owner":"Bad Who","reason":"r"}'
drift
check "9561 S2 5c: an owner that fails the pattern is one UNOWNED row" "$(dcount UNOWNED)/$(dcount AWAITING)" 1/0
contains "9561 S2 5c: saying held with no owner on record" "$(drows UNOWNED)" "held with no owner on record"
d6fx; label
hand 3600 '{"owner":"operator\nAWAITING forged operator x | wait=operator","reason":"r"}'
drift
check "9561 S2 5d: an owner holding a newline is still one UNOWNED row" "$(dcount UNOWNED)/$(dcount AWAITING)" 1/0
check "9561 S2 5d: and the forged line is never printed" "$(grep -c forged "$tmp/dout")" 0
contains "9561 S2 5d: saying held with no owner on record" "$(drows UNOWNED)" "held with no owner on record"

d6fx
hold "$K" --reason r --owner chief
hnow 0
drift
contains "9561 S2 6: owner chief with no until is due 24 h after the hold" "$(drows AWAITING)" "due=$(iso_e $(($(epoch_of "$(hts)") + 86400))) "
d6fx
hold "$K" --reason r --owner release-manager
hnow 0
drift
contains "9561 S2 6: owner release-manager with no until is due 72 h after the hold" "$(drows AWAITING)" "due=$(iso_e $(($(epoch_of "$(hts)") + 259200))) "
contains "9561 S2 6: and waits on release-manager" "$(drows AWAITING)" "wait=release-manager"
d6fx
hold "$K" --reason r --owner operator
hnow 0
driftenv TICKET_STATUS_AWAIT_TTL_OPERATOR=2h
contains "9561 S2 6: TTL_OPERATOR=2h makes an operator hold due in 2 h" "$(drows AWAITING)" "due=$(iso_e $(($(epoch_of "$(hts)") + 7200))) "

d6fx
hold "$K" --reason r --owner operator --until "$(tomorrow)"
for _ in $(seq 600); do printf '{"ts":"2026-10-21T10:00:00Z","event":"derive","key":"HIMMEL-90001","result":"noop","pr":"1"}\n' >> "$LOG"; done
hnow 0
drift
check "9561 S2 7: a hold with 600 rows after it still makes the key AWAITING" "$(dcount AWAITING)" 1

reset "In Progress"
hold "$K" --reason r --owner 'x | wait=y'; rc=$?
check "9561 S2 8: an owner with a pipe exits 2" "$rc" 2
check "9561 S2 8: and writes no row" "$([ -e "$LOG" ] && echo row || echo none)" none
hold "$K" --reason r --owner Operator; rc=$?
check "9561 S2 8: an upper-case owner exits 2" "$rc" 2
hold "$K" --reason r --owner operator --until 2026-02-30; rc=$?
check "9561 S2 8: an until that is no date exits 2" "$rc" 2
bsdhold "$K" --reason r --owner operator --until 2026-02-30; rc=$?
check "9561 S2 8: and so does 2026-02-30 under a BSD date" "$rc" 2
check "9561 S2 8: and these write no row and call no edit" "$([ -e "$LOG" ] && echo row || echo none)/$(grep -c '^edit' "$STUB_LOG")" none/0
bsdhold "$K" --reason r --owner operator --until 2030-03-02; rc=$?
check "9561 S2 8 control: a real date passes under the BSD date" "$rc" 0

d6fx
hold "$K" --reason $'a|b\nc' --owner operator
check "9561 S2 9: the hold row's reason has no pipe or newline" "$(rowq 'select(.event == "hold") | .reason')" abc
hnow 0
drift
contains "9561 S2 9: what= is the stripped reason" "$(drows AWAITING)" "what=abc "
check "9561 S2 9: and the row is a wait row" "$(drows AWAITING | grep -c ' | wait=operator$')" 1
d6fx; label
hand 3600 '{"owner":"operator","reason":"x | wait=x\ny"}'
drift
check "9561 S2 9: a hand-written reason with a pipe and a newline is one row" "$(dcount AWAITING)" 1
contains "9561 S2 9: whose what= has neither" "$(drows AWAITING)" "what=x  wait=xy source=hold"
check "9561 S2 9: and no forged wait mark" "$(drows AWAITING | grep -c '| wait=x')" 0

d6fx; label
hand 3600 '{"owner":"operator","reason":"r","until":"2026-13-40"}'
drift
contains "9561 S2 10: an until of 2026-13-40 is dropped: due = since + 72 h" "$(drows AWAITING)" "due=$(iso_at $((3600 - 259200))) "
d6fx; label
hand 3600 '{"owner":"operator","reason":"r","until":"2026-02-30"}'
drift_bsd
contains "9561 S2 10: an until of 2026-02-30 is dropped under a BSD date too" "$(drows AWAITING)" "due=$(iso_at $((3600 - 259200))) "
d6fx; label
u10=$(day_e $((NOW + 86400)))
hand 3600 "{\"owner\":\"operator\",\"reason\":\"r\",\"until\":\"$u10\"}"
drift_bsd
contains "9561 S2 10 control: a real until is kept under a BSD date" "$(drows AWAITING)" "due=${u10}T23:59:59Z "

d6fx
u11=$(day_e $((NOW + 86400)))
hand 3600 "{\"owner\":\"operator\",\"reason\":\"r\",\"until\":\"$u11\"}"
drift
check "9561 S2 11: a forged hold row on a key with no held label is plain UNOWNED" "$(dcount UNOWNED)/$(dcount AWAITING)" 1/0
check "9561 S2 11: and says nothing of a label" "$(drows UNOWNED | grep -c 'held with no owner')" 0
label
drift
check "9561 S2 11: the same row with the label is AWAITING" "$(dcount AWAITING)/$(dcount UNOWNED)" 1/0
contains "9561 S2 11: operator" "$(drows AWAITING)" "wait=operator"

d6fx; label
lrow 7200 wrapped noop D6n; lrow 60 sweep noop D6n
hand 3600 '{"owner":"operator","reason":"r"}'
drift
contains "9561 S2 12: a hold newer than the D6n park start wins" "$(drows AWAITING)" "source=hold"
d6fx; label
hand 7200 '{"owner":"operator","reason":"r"}'
lrow 3600 wrapped noop D6n; lrow 60 sweep noop D6n
drift
contains "9561 S2 12: a D6n park start newer than the hold wins" "$(drows AWAITING)" "source=d6n"
unset TICKET_STATUS_NOW

# a `standing` ticket is started on purpose with no single PR; a ticket whose PR is open in
# another repo is owned by that PR (the open-PR list only sees this repo)
XPR=https://github.com/yotamleo-org/himmel-voice/pull/13
xpr() { # <state> [title key, default the ticket] - the comment cites $XPR; gh reports its state and title
    printf 'PR %s is open and parked\n' "$XPR" > "$FX/comments.$K"; printf '%s\n' "$1" > "$FX/xpr.state"
    printf '[%s] feat: the work\n' "${2:-$K}" > "$FX/xpr.title"
}
reset "In Progress"; jl "$K" "In Progress"; printf 'standing\n' > "$FX/labels.$K"
drift
check "3b: a standing ticket with no PR and no owner is not UNOWNED" "$(dcount UNOWNED)" 0
check "3b: and a standing ticket is not drift at all" "$(dlast | cut -d: -f1)" "sdrift=0"
reset "In Progress"; jl "$K" "In Progress"; printf 'other\n' > "$FX/labels.$K"
drift
contains "3b: a ticket with another label is still UNOWNED" "$(drows UNOWNED)" "UNOWNED $K"

reset "In Review"; owned "$K" WRAPPED '{"state":"wrapped"}'; jl "$K" "In Review"; xpr OPEN
drift
check "3b: an open cross-repo PR means not UNOWNED" "$(dcount UNOWNED)" 0
check "3b: an open cross-repo PR means not DERIVE-MISMATCH" "$(dcount DERIVE-MISMATCH)" 0
check "3b: an open cross-repo PR means not WORKER-COMMENT" "$(dcount WORKER-COMMENT)" 0
check "3b: the cross-repo PR is read by its URL, once" "$(grep -c "^gh pr view $XPR --json state" "$STUB_LOG")" 1
check "3b: and the cross-repo read writes no Jira field" "$(nwrites)" 0
reset "In Review"; owned "$K" WRAPPED '{"state":"wrapped"}'; jl "$K" "In Review"; xpr CLOSED
drift
contains "3b: a closed cross-repo PR does not exempt: UNOWNED" "$(drows UNOWNED)" "UNOWNED $K"
contains "3b: a closed cross-repo PR does not exempt: DERIVE-MISMATCH" "$(drows DERIVE-MISMATCH)" "DERIVE-MISMATCH $K"
contains "3b: a closed cross-repo PR does not exempt: WORKER-COMMENT" "$(drows WORKER-COMMENT)" "WORKER-COMMENT $K"
reset "In Review"; owned "$K" WRAPPED '{"state":"wrapped"}'; jl "$K" "In Review"; xpr MERGED
drift
contains "3b: a merged cross-repo PR does not exempt" "$(drows UNOWNED)" "UNOWNED $K"
reset "In Review"; owned "$K" WRAPPED '{"state":"wrapped"}'; jl "$K" "In Review"; xpr OPEN; touch "$FX/xpr.fail"
drift
contains "3b: a failed cross-repo read keeps the rows (never a silent green)" "$(drows UNOWNED)" "UNOWNED $K"
check "3b: and the failed read still ends in a counted sdrift" "$(dlast | grep -cE '^sdrift=[1-9][0-9]*:[0-9a-f]{8}$')" 1
# an open PR a comment merely cites is not the ticket's PR: only a title naming the ticket binds it
reset "In Review"; owned "$K" WRAPPED '{"state":"wrapped"}'; jl "$K" "In Review"; xpr OPEN HIMMEL-1
drift
contains "3b: an open cross-repo PR titled for another ticket keeps UNOWNED" "$(drows UNOWNED)" "UNOWNED $K"
contains "3b: an open cross-repo PR titled for another ticket keeps DERIVE-MISMATCH" "$(drows DERIVE-MISMATCH)" "DERIVE-MISMATCH $K"
contains "3b: an open cross-repo PR titled for another ticket keeps WORKER-COMMENT" "$(drows WORKER-COMMENT)" "WORKER-COMMENT $K"
reset "In Review"; owned "$K" WRAPPED '{"state":"wrapped"}'; jl "$K" "In Review"; xpr OPEN; printf 'feat: no ticket key\n' > "$FX/xpr.title"
drift
contains "3b: an open cross-repo PR whose title names no ticket keeps UNOWNED" "$(drows UNOWNED)" "UNOWNED $K"
# a URL spelled in another case or under the old slug is just another PR: the title decides, not the slug
XPR_KEEP=$XPR
for XPR in https://github.com/YotamLeo-Org/Himmel/pull/13 https://github.com/yotamleo/himmel/pull/13; do
    reset "In Review"; owned "$K" WRAPPED '{"state":"wrapped"}'; jl "$K" "In Review"; xpr OPEN HIMMEL-1
    drift
    contains "3b: $XPR to another ticket's open PR keeps UNOWNED" "$(drows UNOWNED)" "UNOWNED $K"
    reset "In Review"; owned "$K" WRAPPED '{"state":"wrapped"}'; jl "$K" "In Review"; xpr OPEN
    drift
    check "3b: $XPR to this ticket's open PR is not UNOWNED" "$(dcount UNOWNED)" 0
done
XPR=$XPR_KEEP

reset "In Progress"; owned "$K" LIVE '{"state":"live"}'; jl "$K" "In Progress"; printf 'held\n' > "$FX/labels.$K"
drift
contains "3b: a held ticket with a live owner is HELD-IN-WORK" "$(drows HELD-IN-WORK)" "HELD-IN-WORK $K"
reset "In Progress"; jl "$K" "In Progress"; pr 7 "[$K] feat" aaa111; checks 7 fail; printf 'held\n' > "$FX/labels.$K"
drift
contains "3b: a held ticket with an open PR is HELD-IN-WORK" "$(drows HELD-IN-WORK)" "HELD-IN-WORK $K"
reset "In Progress"; owned "$K" LIVE '{"state":"live"}'; jl "$K" "In Progress"
drift
check "3b: an unheld ticket is not HELD-IN-WORK" "$(dcount HELD-IN-WORK)" 0

# A ticket's labels and comments come from the local Jira mirror, not one live read per ticket
# (the traced pass spent 37 s on them). A ticket the mirror lacks is still read live.
mirrorfull() { # <KEY> <status> <labels json> [comment text] - a mirror file with labels and a Comments section
    mkdir -p "$TICK_TRACKER_MIRROR_DIR"
    printf -- '---\nkey: "%s"\ntype: "Task"\nstatus: "%s"\nlabels: %s\n---\n\n# %s: x\n\n## Description\n\nd\n\n## Comments\n\n### Someone — 2026-11-06T10:00:00.000+0100\n\n%s\n' \
        "$1" "$2" "$3" "$1" "${4:-nothing}" > "$TICK_TRACKER_MIRROR_DIR/$1.md"
}
livereads() { grep -cE "^(get $K |comments $K)" "$STUB_LOG" || true; }
rm -rf "$TICK_TRACKER_MIRROR_DIR"
reset "In Progress"; jl "$K" "In Progress"; mirrorfull "$K" "In Progress" '["standing"]'
drift
check "9436: a standing label in the mirror means not UNOWNED" "$(dcount UNOWNED)" 0
check "9436: and the standing label costs no live read" "$(livereads)" 0
reset "In Progress"; jl "$K" "In Progress"; mirrorfull "$K" "In Progress" '["other"]'; printf 'standing\n' > "$FX/labels.$K"
drift
contains "9436: the mirror's labels decide, not a live read: another label is still UNOWNED" "$(drows UNOWNED)" "UNOWNED $K"
reset "In Review"; owned "$K" WRAPPED '{"state":"wrapped"}'; jl "$K" "In Review"; xpr OPEN
mirrorfull "$K" "In Review" '[]' "PR $XPR is open and parked"
drift
check "9436: an open cross-repo PR cited in the mirror's comments means not UNOWNED" "$(dcount UNOWNED)" 0
check "9436: and the comments cost no live read" "$(livereads)" 0
check "9436: the cross-repo PR is still read by its URL" "$(grep -c "^gh pr view $XPR --json state" "$STUB_LOG")" 1
reset "In Review"; owned "$K" WRAPPED '{"state":"wrapped"}'; jl "$K" "In Review"; xpr OPEN
mirrorfull "$K" "In Review" '[]' "no PR is cited here"
drift
contains "9436: a mirror whose comments cite no PR keeps UNOWNED" "$(drows UNOWNED)" "UNOWNED $K"
reset "In Progress"; owned "$K" LIVE '{"state":"live"}'; jl "$K" "In Progress"; mirrorfull "$K" "In Progress" '["held"]'
drift
contains "9436: a held label in the mirror is HELD-IN-WORK" "$(drows HELD-IN-WORK)" "HELD-IN-WORK $K"
check "9436: and the held label costs no live read" "$(livereads)" 0
reset "In Progress"; owned "$K" LIVE '{"state":"live"}'; jl "$K" "In Progress"; printf 'held\n' > "$FX/labels.$K"
drift
contains "9436: a ticket the mirror lacks is still read live: HELD-IN-WORK" "$(drows HELD-IN-WORK)" "HELD-IN-WORK $K"
rm -rf "$TICK_TRACKER_MIRROR_DIR"

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
reset "To Do"; logrow worker-jira-status "$K" disabled ""
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

# the drift pass reads the sweep's snapshot instead of gh per key, and falls back to gh without one
reset "In Progress"; owned "$K"; jl "$K" "In Progress"; pr 7 "[$K] feat" aaa111; checks 7 pass
rm -rf "$tmp/snap"
bash "$SWEEP" --snapshot-out "$tmp/snap" >/dev/null 2>&1
check "3b: the sweep keeps its snapshot where it is asked to" "$([ -f "$tmp/snap/prs.json" ] && [ -f "$tmp/snap/threads.tsv" ] && echo kept || echo none)" kept
printf '%s\n' "In Progress" > "$FX/status.$K"
drift
live=$(grep -v '^sdrift=' "$tmp/dout")
: > "$STUB_LOG"
bash "$DRIFT" --docs-dir "$tmp/docs" --snapshot "$tmp/snap" >"$tmp/dout" 2>&1
check "3b: a drift pass over the snapshot finds what the live pass finds" "$(grep -v '^sdrift=' "$tmp/dout")" "$live"
check "3b: and reads no PR checks or per-key PR search from gh" "$(grep -cE '^gh pr (checks|list --state open --search)' "$STUB_LOG")" 0
: > "$STUB_LOG"
bash "$DRIFT" --docs-dir "$tmp/docs" --snapshot "$tmp/nosnap" >"$tmp/dout" 2>&1
check "3b: a missing snapshot falls back to the live reads" "$(grep -c '^gh pr checks' "$STUB_LOG")" 1
check "3b: and finds the same rows" "$(grep -v '^sdrift=' "$tmp/dout")" "$live"
reset "To Do"; touch "$FX/pr-list.fail"; rm -rf "$tmp/snap"
bash "$SWEEP" --snapshot-out "$tmp/snap" >/dev/null 2>&1
check "3b: an unknown sweep keeps no snapshot" "$([ -e "$tmp/snap/prs.json" ] && echo kept || echo none)" none

# a worked or Done ticket held in a later unreleased version than the current one is VERSION-DRIFT
vd_versions() {
    printf 'v1.1.2\ttrue\t2026-10-10\tfalse\nv1.1.3\tfalse\t2026-10-20\tfalse\nv1.1.4\tfalse\t2026-10-27\tfalse\nv1.0.9\tfalse\t2026-09-01\ttrue\n' > "$FX/versions.tsv"
}
reset "To Do"; vd_versions
printf 'HIMMEL-90021\tTask\tDone\tsummary\nHIMMEL-90022\tTask\tIn Progress\tsummary\n' > "$FX/list.fv.v1.1.4"
drift
contains "3b: a Done ticket in a later unreleased version is VERSION-DRIFT" "$(drows VERSION-DRIFT)" "VERSION-DRIFT HIMMEL-90021 status=Done in=v1.1.4 current=v1.1.3"
contains "3b: an In Progress ticket in a later version is VERSION-DRIFT" "$(drows VERSION-DRIFT)" "VERSION-DRIFT HIMMEL-90022 status=In Progress in=v1.1.4 current=v1.1.3"
contains "3b: the row names the INTAKE that fixes it" "$(drows VERSION-DRIFT)" "release request v1.1.3 --verb INTAKE --key HIMMEL-90021 --from v1.1.4 --to v1.1.3"
check "3b: the later-version search skips tickets that also carry the current version" "$(grep -c 'fixVersion != "v1.1.3"' "$STUB_LOG")" 1
check "3b: only the one later unreleased version is searched (not released, archived or current)" "$(grep -c 'fixVersion = ' "$STUB_LOG")" 1
check "3b: the version drift check writes nothing" "$(nwrites)" 0
reset "To Do"
printf 'v1.1.3\tfalse\t2026-10-20\tfalse\nv1.2 beta\tfalse\t2026-11-01\tfalse\n' > "$FX/versions.tsv"
printf 'HIMMEL-90023\tTask\tDone\tsummary\n' > "$FX/list.fv.v1.2 beta"
drift
contains "3b: a version name with a space is shell-quoted in the INTAKE command" "$(drows VERSION-DRIFT)" "--from v1.2\\ beta --to v1.1.3"
reset "To Do"
printf 'v1.1.3\tfalse\t2026-10-20\tfalse\nv1.3"x\tfalse\t2026-11-01\tfalse\n' > "$FX/versions.tsv"
drift
contains "3b: a quote in a version name is escaped in the JQL" "$(cat "$STUB_LOG")" 'fixVersion = "v1.3\"x"'
reset "To Do"
printf 'v1.1.9\tfalse\t\tfalse\nv1.1.10\tfalse\t\tfalse\n' > "$FX/versions.tsv"
printf 'HIMMEL-90024\tTask\tDone\tsummary\n' > "$FX/list.fv.v1.1.9"
drift
check "3b: undated versions keep the project's version order (v1.1.9 is current, not later)" "$(dcount VERSION-DRIFT)" 0
reset "To Do"; vd_versions
drift
check "3b: no ticket in a later version is no VERSION-DRIFT" "$(dcount VERSION-DRIFT)" 0
reset "To Do"; vd_versions; touch "$FX/list.fv.fail"
drift
contains "3b: an unreadable later-version search is a HEALTH row" "$(drows HEALTH)" "HEALTH - jira: the later-version search is unreadable"
check "3b: and the signature is unknown" "$(dlast)" "sdrift=unknown"
reset "To Do"; touch "$FX/versions.fail"
drift
contains "3b: an unreadable version list is a HEALTH row" "$(drows HEALTH)" "HEALTH - jira: the version list is unreadable"

# --- 3c: the FOCUS refresh (focus-refresh.sh) ----------------------------------------
FOCUS="$HERE/focus-refresh.sh"
FR="$tmp/fr"
mkdir -p "$tmp/frbin"
cat >"$tmp/frbin/jira" <<'EOS'
#!/usr/bin/env bash
echo "jira $1" >> "$FX/fr.log"
[ "$(cat "$FX/fr.fail" 2>/dev/null)" = "$1" ] && exit 1
[ "$1" = versions ] && printf 'v1.1.3\tfalse\t-\n'
if [ "$1" = release ]; then
    echo "release $* pk=${JIRA_PROJECT_KEY:-}" >> "$FX/fr.rel.log"
    cat "$FX/fr.release" 2>/dev/null
    exit "$(cat "$FX/fr.release.rc" 2>/dev/null || echo 0)"
fi
exit 0
EOS
cat >"$tmp/frbin/sweep" <<'EOS'
#!/usr/bin/env bash
echo "sweep $*" >> "$FX/fr.log"
echo "budget=${TICKET_STATUS_SWEEP_BUDGET:-} grace=${TICKET_STATUS_SWEEP_GRACE:-}" > "$FX/fr.sweep.env"
case "$(cat "$FX/fr.fail" 2>/dev/null)" in
    sweep) exit 1 ;;
    sweep-unknown) echo "status-sweep: unknown (snapshot gh) keys=0 sig=x wake=1"; exit 0 ;;
    sweep-timeout) echo "status-sweep: unknown (timeout after 80s) keys=0 sig=timeout wake=1"; exit 0 ;;
    sweep-odd) echo "status-sweep: unknown (snapshot Gh/x) keys=0 sig=x wake=1"; exit 0 ;;
esac
echo "status-sweep: keys=2 served=2 moved=$(cat "$FX/sweep.moved" 2>/dev/null || echo 0) miss=0 funnel=1 sig=abc wake=1"
EOS
cat >"$tmp/frbin/tracker" <<'EOS'
#!/usr/bin/env bash
echo "tracker $*" >> "$FX/fr.log"
[ "$(cat "$FX/fr.fail" 2>/dev/null)" = render ] && exit 1
[ -e "$FX/fr.sleep" ] && sleep "$(cat "$FX/fr.sleep")"
[ -e "$FX/fr.again" ] && date +%s > "$(cat "$FX/fr.again")"
out=""; ver=""; prev=""
for a in "$@"; do [ "$prev" = --out ] && out="$a"; [ "$prev" = --version ] && ver="$a"; prev="$a"; done
n=$(( $(cat "$FX/render.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FX/render.n"
v=$(cat "$FX/vfp" 2>/dev/null || echo vfp1)
printf 'render %s\n<meta name="himmel-focus" content="%s %s">\n' "$n" "$ver" "$v" > "$out"
echo "$v" > "$out.vfp"
EOS
cat >"$tmp/frbin/drift" <<'EOS'
#!/usr/bin/env bash
echo "drift $*" >> "$FX/fr.log"
case "$(cat "$FX/fr.fail" 2>/dev/null)" in
    drift) exit 1 ;;
    drift-unknown) echo "sdrift=unknown"; exit 0 ;;
    drift-budget) echo "HEALTH - drift: the pass was cut off after 90s | writer=- | fix=x"; echo "sdrift=unknown"; exit 0 ;;
    drift-gh) echo "HEALTH - gh: the open-PR list is unreadable | writer=gh | fix=x"; echo "sdrift=unknown"; exit 0 ;;
    drift-none) echo "UNOWNED HIMMEL-1 x | writer=- | fix=y"; exit 0 ;;
esac
echo "UNOWNED HIMMEL-1 x | writer=- | fix=y"
echo "sdrift=1:0a1b2c3d"
EOS
cat >"$tmp/frbin/ksync" <<'EOS'
#!/usr/bin/env bash
echo "ksync $* jira=${KBS_JIRA:-}" >> "$FX/ksync.log"
echo "ksync" >> "$FX/fr.log"
# the real sync takes --checker/--tsv/--log pairs and nothing else
a=("$@")
[ $(( ${#a[@]} % 2 )) -eq 0 ] || exit 64
for ((i = 0; i < ${#a[@]}; i += 2)); do
    case "${a[i]}" in --checker | --tsv | --log) ;; *) exit 64 ;; esac
    [ -n "${a[i + 1]}" ] || exit 64
done
[ "$(cat "$FX/fr.fail" 2>/dev/null)" = ksync ] && exit 1
[ "$(cat "$FX/fr.fail" 2>/dev/null)" = ksync-hang ] && sleep 30
exit 0
EOS
chmod +x "$tmp/frbin/jira" "$tmp/frbin/sweep" "$tmp/frbin/tracker" "$tmp/frbin/drift" "$tmp/frbin/ksync"
export FR_JIRA="$tmp/frbin/jira" FR_SWEEP="$tmp/frbin/sweep" FR_TRACKER="$tmp/frbin/tracker" FR_DRIFT="$tmp/frbin/drift" FR_KNOWN_SYNC="$tmp/frbin/ksync"
export TICK_TRACKER_MIRROR_DIR="$FR/mir/HIMMEL"
export HANDOVER_DIR="$tmp/no-handover-root" # the chains stage reads <root>/<user>/himmel/chains.json; none here, so it is skipped (test-focus-refresh-chains.sh covers it)
fr_reset() { # fresh fixtures plus a chief doc with a focus-version line
    reset "To Do"
    rm -rf "$FR"; mkdir -p "$FR/doc" "$FR/mir"
    printf '# chief\n\n## Live state\ntracker: https://example.invalid/t\nfocus-version: v1.1.3\n' > "$FR/doc/chief.md"
}
fr() { bash "$FOCUS" --doc "$FR/doc/chief.md" "$@" >"$tmp/frout" 2>"$tmp/frerr"; echo $? >"$tmp/frrc"; }
frrc() { cat "$tmp/frrc"; }
frout() { cat "$tmp/frout"; }
fst() { sed -n "s/^$1=//p" "$FR/doc/focus-state" | head -n 1; }
frseq() { awk '{ print $1 }' "$FX/fr.log" 2>/dev/null | paste -sd, -; }
PAGE="$FR/doc/roadmap-tracker.html"

fr_reset; sed -i '/^focus-version:/d' "$FR/doc/chief.md"  # gnu-ok: Linux-only kit
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
check "3c: the steps run in order: mirror, versions, sweep, render, drift, known-bugs sync" "$(frseq)" "jira,jira,sweep,tracker,drift,ksync"
check "3c: the page is written" "$(head -n 1 "$PAGE")" "render 1"
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
contains "3c: the known-bugs sync runs after the drift stage with the Jira CLI" "$(cat "$FX/ksync.log")" "--checker HIMMEL-7980 --log $FR/doc/known-bugs-sync.log jira=$tmp/frbin/jira"
check "3c: and a successful sync leaves no sync warning" "$(grep -c 'known-bugs-sync' "$tmp/frerr")" 0
fr
check "3c: a second refresh is generation 2" "$(fst gen)" 2
check "3c: an unchanged fingerprint leaves the page alone" "$(head -n 1 "$PAGE")" "render 1"
echo vfp2 > "$FX/vfp"
fr
check "3c: a changed fingerprint replaces the page" "$(head -n 1 "$PAGE")" "render 3"
check "3c: and the stored fingerprint follows" "$(cat "$PAGE.vfp")" vfp2
printf '<title>Himmel Roadmap</title>\n' > "$PAGE"
fr
check "3c: a page another writer overwrote under an unchanged .vfp is restored" "$(head -n 1 "$PAGE")" "render 4"
printf 'render 4\n<meta name="himmel-focus" content="v1.1.2 vfp2">\n' > "$PAGE"
fr
check "3c: a page of another version under an unchanged .vfp is restored" "$(head -n 1 "$PAGE")" "render 5"
contains "3c: the sweep keeps its snapshot in the stage" "$(grep '^sweep ' "$FX/fr.log" | tail -n 1)" "--snapshot-out $FR/doc/.focus-stage."
contains "3c: the drift pass reads that snapshot" "$(grep '^drift ' "$FX/fr.log" | tail -n 1)" "--snapshot $FR/doc/.focus-stage."
echo ksync > "$FX/fr.fail"
fr
check "3c: a failed known-bugs sync does not fail the refresh" "$(frout)" "focus=ok"
contains "3c: and warns on stderr" "$(cat "$tmp/frerr")" "known-bugs-sync failed"
fr_reset; rm -f "$FX/fr.fail"
FOCUS_REFRESH_BUDGET=08 fr
check "3c: a zero-led budget is read as decimal, not octal" "$(frout)" "focus=ok"
if [ -n "$_TIMEOUT_BIN" ]; then
    fr_reset; echo ksync-hang > "$FX/fr.fail"; : > "$FX/fr.log"
    FOCUS_REFRESH_BUDGET=12 fr
    check "3c: a hung known-bugs sync cannot turn a published refresh into a timeout" "$(frout)" "focus=ok"
    check "3c: and the state records status ok" "$(fst status)" ok
    check "3c: and the drift rows were published" "$(sed -n 1p "$FR/doc/focus-drift.txt")" "UNOWNED HIMMEL-1 x | writer=- | fix=y"
    check "3c: and the hung sync was started" "$(grep -c '^ksync' "$FX/fr.log")" 1
    contains "3c: and its cut-off is reported as a failed sync" "$(cat "$tmp/frerr")" "known-bugs-sync failed"
    rm -f "$FX/fr.fail"
else
    echo "skip - 3c: hung known-bugs sync (no timeout binary)"
fi

# focus-version: auto (or no line beside a release: line) follows the declared release's current version.
fr_auto() { # <focus-version line or ''> <release line or ''> [versions json]
    fr_reset
    sed -i '/^focus-version:/d' "$FR/doc/chief.md"  # gnu-ok: Linux-only kit
    [ -z "$1" ] || printf '%s\n' "$1" >> "$FR/doc/chief.md"
    [ -z "$2" ] || printf '%s\n' "$2" >> "$FR/doc/chief.md"
    printf '{"release":"R","status":"OK","versions":%s}\n' "${3:-[\"v1.1.4\",\"v1.1.5\"]}" > "$FX/fr.release"
    rm -f "$FX/fr.rel.log" "$FX/fr.release.rc"
    fr
}
fr_auto "focus-version: auto" "release: R"
check "3d: focus-version: auto prints ok" "$(frout)" "focus=ok"
contains "3d: auto renders the release's first version" "$(grep '^tracker ' "$FX/fr.log")" "--version v1.1.4 "
check "3d: auto asks one release state call" "$(cat "$FX/fr.rel.log" 2>/dev/null)" "release release state R --json pk=HIMMEL"
fr_auto "" "release: R"
contains "3d: no focus-version line beside a release: line renders the first version" "$(grep '^tracker ' "$FX/fr.log")" "--version v1.1.4 "
fr_auto "focus-version: v1.1.3" "release: R"
contains "3d: a pinned version still renders itself" "$(grep '^tracker ' "$FX/fr.log")" "--version v1.1.3 "
check "3d: and a pin asks no release state" "$([ -e "$FX/fr.rel.log" ] && echo asked || echo none)" none
fr_auto "focus-version: none" "release: R"
check "3d: none still skips beside a release: line" "$(frout)" "focus=skip"
fr_auto "" ""
check "3d: no focus-version and no release: line still skips" "$(frout)" "focus=skip"
fr_auto "focus-version: auto" "release: R" '["v1.1.4"]'
printf '{"release":"R","status":"UNKNOWN","versions":[]}\n' > "$FX/fr.release"; echo 3 > "$FX/fr.release.rc"
fr
check "3d: a not-OK release state (exit 3) with no version is loud, FAILED:release" "$(frout)" "focus=FAILED:release"
fr_reset; sed -i '/^focus-version:/d' "$FR/doc/chief.md"; printf 'focus-version: auto\nrelease: ACME-R\n' >> "$FR/doc/chief.md"  # gnu-ok: Linux-only kit
printf '{"release":"ACME-R","versions":["a1.0"]}\n' > "$FX/fr.release"; rm -f "$FX/fr.rel.log"
JIRA_PROJECT_KEY=ACME fr
contains "3d: an adopted project renders its own current version" "$(grep '^tracker ' "$FX/fr.log" | tail -n 1)" "--version a1.0 "
check "3d: and reads its own release under its own project key" "$(cat "$FX/fr.rel.log" 2>/dev/null)" "release release state ACME-R --json pk=ACME"
# the mirror dir follows the project key; TICK_TRACKER_MIRROR_DIR still wins
fr_mir() { # <project key or empty> - one refresh with no mirror override, HOME under the sandbox
    fr_reset; rm -f "$FX/fr.log"
    HOME="$tmp/frhome" JIRA_PROJECT_KEY="$1" env -u TICK_TRACKER_MIRROR_DIR bash "$FOCUS" --doc "$FR/doc/chief.md" >"$tmp/frout" 2>"$tmp/frerr"
    grep '^tracker ' "$FX/fr.log" | tail -n 1
}
contains "3d: an adopted project mirrors into its own dir" "$(fr_mir ACME)" "--mirror-dir $tmp/frhome/.himmel/state/jira-mirror/ACME "
contains "3d: an unset project key keeps the HIMMEL mirror dir" "$(fr_mir "")" "--mirror-dir $tmp/frhome/.himmel/state/jira-mirror/HIMMEL "
contains "3d: TICK_TRACKER_MIRROR_DIR still wins over the project key" "$(fr_reset; rm -f "$FX/fr.log"; JIRA_PROJECT_KEY=ACME bash "$FOCUS" --doc "$FR/doc/chief.md" >/dev/null 2>&1; grep '^tracker ' "$FX/fr.log" | tail -n 1)" "--mirror-dir $FR/mir/HIMMEL "
fr_auto "focus-version: auto" "release: R"
rm -f "$FR/doc/focus-state"
fr --status
check "3d: --status of an auto doc is not skip" "$(frout)" "focus=DIRTY:unknown"
for bad in read-fail empty null-version semi-version no-release; do
    fr_auto "focus-version: auto" "release: R"
    case "$bad" in
        read-fail) echo 1 > "$FX/fr.release.rc" ;;
        empty) printf '{"release":"R","versions":[]}\n' > "$FX/fr.release" ;;
        null-version) printf '{"release":"R","versions":[null]}\n' > "$FX/fr.release" ;;
        semi-version) printf '{"release":"R","versions":["v1;x"]}\n' > "$FX/fr.release" ;;
        no-release) sed -i '/^release:/d' "$FR/doc/chief.md" ;;  # gnu-ok: Linux-only kit
    esac
    echo "page-before" > "$PAGE"; : > "$FX/fr.log"
    fr
    check "3d: $bad is loud, FAILED:release" "$(frout)" "focus=FAILED:release"
    contains "3d: $bad warns on stderr" "$(cat "$tmp/frerr")" "WARN"
    check "3d: $bad renders nothing" "$(grep -c '^tracker ' "$FX/fr.log")" 0
    check "3d: $bad leaves the published page alone" "$(head -n 1 "$PAGE")" "page-before"
done

fr_reset
mkdir -p "$FR/m2"
fr --mirror-fresh "$FR/m2"
check "3c: a fresh mirror from the caller skips the mirror and versions steps" "$(frseq)" "sweep,tracker,drift,ksync"
contains "3c: the render reads that mirror" "$(grep '^tracker ' "$FX/fr.log")" "--mirror-dir $FR/m2"

for stage in mirror versions sweep:rc1 render; do
    fr_reset
    fr
    echo "page-before" > "$PAGE"
    printf '%s\n' "${stage%%:*}" > "$FX/fr.fail"
    : > "$FX/fr.log"
    fr
    check "3c: a failed $stage step prints FAILED:$stage" "$(frout)" "focus=FAILED:$stage"
    check "3c: and exits 1" "$(frrc)" 1
    check "3c: the state records the stage" "$(fst stage)" "$stage"
    check "3c: the state records FAILED" "$(fst status)" FAILED
    check "3c: the generation is not advanced" "$(fst gen)" 1
    check "3c: the published page is untouched" "$(head -n 1 "$PAGE")" "page-before"
done
fr_reset; echo sweep-unknown > "$FX/fr.fail"
fr
check "3c: an unknown sweep names its snapshot read: FAILED:sweep:gh" "$(frout)" "focus=FAILED:sweep:gh"
contains "3c: and the sweep's last line reaches stderr" "$(cat "$tmp/frerr")" "status-sweep: unknown (snapshot gh)"
check "3c: the sweep runs with budget 60 and grace 20, inside its 90 s bound" "$(cat "$FX/fr.sweep.env")" "budget=60 grace=20"
fr_reset; echo sweep-timeout > "$FX/fr.fail"
fr
check "3c: a sweep cut off by its own budget is FAILED:sweep:timeout" "$(frout)" "focus=FAILED:sweep:timeout"
fr --status
check "3c: and --status names the cause" "$(frout)" "focus=FAILED:sweep:timeout"
fr_reset; echo sweep-odd > "$FX/fr.fail"
fr
check "3c: an unparseable snapshot cause is FAILED:sweep:unknown" "$(frout)" "focus=FAILED:sweep:unknown"
fr_reset; echo drift-unknown > "$FX/fr.fail"
fr
contains "3c: an unknown drift pass with no reason is WARN:drift unknown" "$(frout)" "drift unknown"
check "3c: and the page is still published" "$([ -e "$PAGE" ] && echo set || echo none)" set
check "3c: and the state is ok, not FAILED" "$(fst status)" ok
fr_reset; echo drift-budget > "$FX/fr.fail"
fr
contains "3c: a drift pass cut off by its budget is WARN:drift budget" "$(frout)" "drift budget"
check "3c: and the run exits 0" "$(frrc)" 0
fr --status
contains "3c: and --status names the reason" "$(frout)" "drift budget"
fr_reset; echo drift-gh > "$FX/fr.fail"
fr
contains "3c: a drift pass that could not read the PRs is WARN:drift gh" "$(frout)" "drift gh"
fr_reset; echo drift-none > "$FX/fr.fail"
fr
contains "3c: a drift pass with no sdrift line is WARN:drift no-sdrift" "$(frout)" "drift no-sdrift"
fr_reset; echo drift > "$FX/fr.fail"
fr
contains "3c: a drift pass that exits 1 is WARN:drift rc1" "$(frout)" "drift rc1"
check "3c: and the page is still published" "$([ -e "$PAGE" ] && echo set || echo none)" set
fr_reset; echo 2 > "$FX/sweep.moved"
fr
check "3c: a sweep that moved a ticket re-reads the mirror before the render" "$(frseq)" "jira,jira,sweep,jira,tracker,drift,ksync"
check "3c: and the refresh is ok" "$(frout)" "focus=ok"
fr_reset; echo 2 > "$FX/sweep.moved"; echo mirror > "$FX/fr.fail"
fr
check "3c: a failed re-read after a move is FAILED:mirror" "$(frout)" "focus=FAILED:mirror"
fr_reset
( cd "$FR/doc" && bash "$FOCUS" --doc chief.md >"$tmp/frout" 2>"$tmp/frerr"; echo $? >"$tmp/frrc" )
check "3c: a bare doc filename resolves beside the doc" "$(frout)" "focus=ok"
check "3c: and the page lands beside the doc" "$(head -n 1 "$PAGE")" "render 1"
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
date +%s > "$FR/doc/focus-state.again"
fr --status
check "3c: a request that lands after a run's final save still reads DIRTY" "$(frout)" "focus=DIRTY:unknown"
rm -f "$FR/doc/focus-state.again"
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

# --- 9479 T8: GitHub out pauses the sweep, the funnel and the drift pass before any gh read -------------
qplant() { # <dir> <main graphql remaining> <state>
    local now; now=$(date +%s)
    mkdir -p "$1"
    printf 'main\tgraphql\t%s\t5000\t%s\t%s\t%s\nmain\tcore\t4000\t5000\t%s\t%s\tok\n' "$2" "$((now + 1800))" "$now" "$3" "$((now + 1800))" "$now" > "$1/quota.tsv"
}
ngh() { grep -c '^gh ' "$STUB_LOG" || true; }
uiclose() { # the 2b UI close: the record holds PR 7 open, GitHub lists none, the owner is live
    reset "In Review"; owned "$K" LIVE '{"state":"live","lock_seen":true,"lock_gone_sweeps":0,"prs":{"7":{"head":"aaa111","ci":"pending","red_latch":false,"open":true}}}'
    jl "$K" "In Review"
    printf '{"title":"[%s] feat","state":"CLOSED"}\n' "$K" > "$FX/view-7.json"
}
qplant "$tmp/q-out" 0 refused
qplant "$tmp/q-ok" 4000 ok
uiclose
HIMMEL_QUOTA_DIR="$tmp/q-out" sweep
contains "T8: a paused sweep reads as unknown (snapshot gh)" "$(cat "$tmp/sout")" "status-sweep: unknown (snapshot gh) keys=0"
contains "T8: a paused sweep names the pause" "$(cat "$tmp/sout")" "QUOTA-PAUSE github graphql token=main remaining=0"
check "T8: a paused sweep makes no gh call" "$(ngh)" 0
check "T8: a paused sweep moves nothing" "$(ntrans)" 0
HIMMEL_QUOTA_DIR="$tmp/q-ok" sweep
check "T8: the next healthy sweep repairs the missed close" "$(grep '^transition' "$STUB_LOG")" "transition $K In Progress"

uiclose
HIMMEL_QUOTA_DIR="$tmp/q-out" fn "$K" --event live; rc=$?
check "T8: a paused funnel exits 0" "$rc" 0
check "T8: a paused funnel makes no Jira transition" "$(ntrans)" 0
check "T8: a paused funnel makes no gh call" "$(ngh)" 0
contains "T8: a paused funnel warns that the key is not synced" "$(cat "$tmp/out")" "WARN worker-jira-status: $K not synced (stage gh)"
contains "T8: a paused funnel names the pause" "$(cat "$tmp/out")" "caller=ticket-status nothing-was-judged"
uiclose
HIMMEL_QUOTA_DIR="$tmp/q-ok" fn "$K" --event live
check "T8 RED control: a healthy funnel moves the key" "$(grep '^transition' "$STUB_LOG")" "transition $K In Progress"
check "T8 RED control: a healthy funnel prints no pause line" "$(grep -c 'QUOTA-PAUSE' "$tmp/out")" 0

wipe_docs
reset "To Do"
HIMMEL_QUOTA_DIR="$tmp/q-out" drift
check "T8: a paused drift pass ends sdrift=unknown" "$(dlast)" "sdrift=unknown"
contains "T8: a paused drift pass keeps the unreadable-list row" "$(cat "$tmp/dout")" "HEALTH - gh: the open-PR list is unreadable"
contains "T8: a paused drift pass names the pause" "$(cat "$tmp/dout")" "caller=status-drift nothing-was-judged"
check "T8: a paused drift pass makes no gh call" "$(ngh)" 0
HIMMEL_QUOTA_DIR="$tmp/q-ok" drift
contains "T8 RED control: a healthy drift pass reports drift" "$(dlast)" "sdrift=0:"
check "T8 RED control: a healthy drift pass prints no pause line" "$(grep -c 'QUOTA-PAUSE' "$tmp/dout")" 0

echo "---"
[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
