#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check(), as in test-append-results.sh
# scripts/handover/chief-kit/test-worker-jira-status.sh - Hermetic
# tests for the derive-and-set funnel (worker-jira-status.sh, scripts/lib/ticket-status.sh)
# and its append-results.sh wiring. A stubbed Jira CLI (WORKER_SESSION_JIRA_CLI), a stubbed
# gh on PATH and a stubbed queue lock (TICKET_STATUS_QUEUE_LOCK) read fixture
# files, so no real ticket, PR or lock is touched.
#   D0-D7      one row per rule, plus D4b done-pending
#   unreadable every unreadable input -> no write + a miss row
#   PRs        several PRs -> lowest wins; per-PR red latch; optional red; first [KEY] only
#   CAS        a status change between read and write re-derives; two -> deferred
#   bounds     a hung call -> miss stage=timeout; a held flock -> deferred stage=lock
#   worker     the five worker states; no D6 without end evidence
#   wiring     LIVE bullet, opt-out, bad keys, failures never block
#
# Platform guard: POSIX bash 3.2+ (shell-only harness).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/worker-jira-status.sh"
APPEND="$HERE/append-results.sh"
LIB="$HERE/../../lib/ticket-status.sh"
# shellcheck source=../../lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/timeout-bin.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/worker-jira-status-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
# a worker shell carries the live chief doc; a move would mark its FOCUS page dirty
unset GH_REPO HIMMEL_CONSOLE_DOC
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]"; fails=$((fails+1)) ;; esac; }

export FX="$tmp/fx" STUB_LOG="$tmp/log"
export TICKET_STATUS_STATE_DIR="$tmp/state"
mkdir -p "$tmp/bin"

cat >"$tmp/jira-stub.sh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1" in
    get)
        [ -e "$FX/get.fail" ] && { echo "boom" >&2; exit 1; }
        [ -e "$FX/get.sleep" ] && sleep "$(cat "$FX/get.sleep")"
        if [ -s "$FX/status.seq" ]; then
            head -n 1 "$FX/status.seq" > "$FX/status.cur"
            tail -n +2 "$FX/status.seq" > "$FX/status.seq.t"; mv "$FX/status.seq.t" "$FX/status.seq"
        fi
        gn=$(( $(cat "$FX/get.n" 2>/dev/null || echo 0) + 1 )); echo "$gn" > "$FX/get.n"
        if [ -e "$FX/get.fail.from" ] && [ "$gn" -ge "$(cat "$FX/get.fail.from")" ]; then echo "boom" >&2; exit 1; fi
        lbl=$(cat "$FX/labels" 2>/dev/null || echo '[]'); cat=$(cat "$FX/category" 2>/dev/null || echo indeterminate)
        if [ -e "$FX/type" ] && [ ! -s "$FX/type" ]; then
            printf '{"fields":{"status":{"name":"%s","statusCategory":{"key":"%s"}},"labels":%s}}\n' "$(cat "$FX/status.cur")" "$cat" "$lbl"
        else
            printf '{"fields":{"status":{"name":"%s","statusCategory":{"key":"%s"}},"issuetype":{"name":"%s"},"labels":%s,"fixVersions":%s}}\n' \
                "$(cat "$FX/status.cur")" "$cat" "$(cat "$FX/type" 2>/dev/null || echo Task)" "$lbl" "$(cat "$FX/fixversions" 2>/dev/null || echo '[]')"
        fi ;;
    edit)
        [ -e "$FX/edit.sleep" ] && sleep "$(cat "$FX/edit.sleep")"
        [ -e "$FX/edit.exit2" ] && { echo "bad phase" >&2; exit 2; }
        [ -e "$FX/edit.fail" ] && { echo "boom" >&2; exit 1; }
        ph=""; while [ "$#" -gt 0 ]; do [ "$1" = --phase ] && ph="$2"; shift; done
        if [ -n "$ph" ]; then
            lbl=$(cat "$FX/labels" 2>/dev/null || echo '[]')
            if [ "$ph" = none ]; then jq -c 'map(select(startswith("phase:") | not))' <<<"$lbl" > "$FX/labels"
            else jq -c --arg p "phase:$ph" 'map(select(startswith("phase:") | not)) + [$p]' <<<"$lbl" > "$FX/labels"; fi
        fi
        exit 0 ;;
    versions)
        cat "$FX/versions" 2>/dev/null ;;
    release)
        [ -e "$FX/request.fail" ] && { echo "boom" >&2; exit 1; }
        echo "REQ Q-9001" ;;
    list)
        printf '%s\tTask\t%s\ttitle\n' "$(cat "$FX/list.key" 2>/dev/null)" "$(cat "$FX/status.cur")" ;;
    transition)
        [ -e "$FX/transition.fail" ] && { echo "boom" >&2; exit 1; }
        if [ -e "$FX/workflow" ] && [ -z "$(cut -f2 "$FX/workflow" | grep -xF "$3")" ]; then
            echo "no transition to $3" >&2; exit 1
        fi
        [ -e "$FX/transition.noop" ] || printf '%s\n' "$3" > "$FX/status.cur"
        # a holder that takes the key's flock the moment the status child exits (fd 9 closed so it does not wait on its own parent)
        [ ! -e "$FX/hold.lock" ] || { ( flock "$TICKET_STATUS_STATE_DIR/status-locks/$2" sleep 3 ) 9>&- </dev/null >/dev/null 2>&1 & }
        exit 0 ;;
esac
EOS
cat >"$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB_LOG"
printf '%s\n' "${GH_REPO:-}" >> "$FX/gh-repo.log"
case "$1 $2" in
    "pr list")
        case " $* " in *" merged "*)
            [ -e "$FX/pr-merged.fail" ] && { echo "HTTP 502" >&2; exit 1; }
            if [ -e "$FX/pr-merged.json" ]; then cat "$FX/pr-merged.json"; else echo '[]'; fi
            exit 0 ;;
        esac
        [ ! -e "$FX/pr-list.sleep" ] || sleep "$(cat "$FX/pr-list.sleep")"
        [ -e "$FX/pr-list.fail" ] && { echo "HTTP 502" >&2; exit 1; }
        n=$(( $(cat "$FX/pr-list.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FX/pr-list.n"
        if [ -e "$FX/pr-list.$n.json" ]; then cat "$FX/pr-list.$n.json"; else cat "$FX/pr-list.json"; fi ;;
    "pr checks")
        if [ -e "$FX/checks-$3.json" ]; then cat "$FX/checks-$3.json"; else echo "no checks reported on the 'x' branch" >&2; exit 1; fi ;;
    "api graphql")
        num=""; for a in "$@"; do case "$a" in number=*) num=${a#number=} ;; esac; done
        if [ -z "$num" ] && [ -e "$FX/graphql-all.json" ]; then cat "$FX/graphql-all.json"; exit 0; fi
        t=$(cat "$FX/threads-$num" 2>/dev/null || echo 0)
        nodes=""; i=0; while [ "$i" -lt "$t" ]; do nodes="${nodes:+$nodes,}{\"isResolved\":false}"; i=$((i+1)); done
        more=false; [ -e "$FX/threads-more-$num" ] && more=true
        printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":%s},"nodes":[%s{"isResolved":true}]}}}}}\n' "$more" "${nodes:+$nodes,}" ;;
    "api repos/{owner}/{repo}/rules/branches/"*)
        cat "$FX/rules.json" ;;
    "api repos/{owner}/{repo}/branches/"*)
        if [ -e "$FX/classic.json" ]; then cat "$FX/classic.json"
        elif [ -e "$FX/classic.403" ]; then echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1
        else echo "gh: Branch not protected (HTTP 404)" >&2; exit 1; fi ;;
    "api repos/{owner}/{repo}/commits/"*)
        cat "$FX/check-runs.json" ;;
    *) echo "gh stub: unexpected $*" >&2; exit 1 ;;
esac
EOS
cat >"$tmp/lock-stub.sh" <<'EOS'
#!/usr/bin/env bash
rc=$(cat "$FX/lock.rc.${2##*/}" 2>/dev/null || cat "$FX/lock.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] && { echo free; exit 0; }
age=$(cat "$FX/lock.age" 2>/dev/null || echo 0)
now=$(date -u +%s)
hb=$(date -u -d "@$((now - age))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$((now - age))" +%Y-%m-%dT%H:%M:%SZ)
printf '{\n  "session": "s",\n  "heartbeat": "%s"\n}\nstatus: FRESH\n' "$hb"
exit "$rc"
EOS
chmod +x "$tmp/jira-stub.sh" "$tmp/bin/gh" "$tmp/lock-stub.sh"
export WORKER_SESSION_JIRA_CLI="$tmp/jira-stub.sh"
export TICKET_STATUS_QUEUE_LOCK="$tmp/lock-stub.sh"
export PATH="$tmp/bin:$PATH"

K=HIMMEL-9001
REC="$TICKET_STATUS_STATE_DIR/workers/$K.json"
LOG="$TICKET_STATUS_STATE_DIR/status-events.jsonl"
REQ='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"shell-unit"}]}}]'

reset() { # fresh fixtures, no record, empty log; Jira status $1
    rm -rf "$FX" "$TICKET_STATUS_STATE_DIR"; mkdir -p "$FX"
    : > "$STUB_LOG"
    printf '%s\n' "$1" > "$FX/status.cur"
    echo '[]' > "$FX/pr-list.json"
    printf '%s\n' "$REQ" > "$FX/rules.json"
}
mkdoc() { # <path> [marker] - a worker doc whose newest marker is <marker>
    printf '# worker\n\n## Results (newest at the bottom)\n' > "$1"
    [ -z "${2:-}" ] || printf -- '- 10:00 %s — x\n' "$2" >> "$1"
}
DOC="$tmp/$K-N1-slug-2026-10-21.md"
owned() { # [marker] [lock rc] [lock age] - a record owned by DOC
    mkdoc "$DOC" "${1:-LIVE}"
    printf '%s\n' "${2:-11}" > "$FX/lock.rc"; printf '%s\n' "${3:-0}" > "$FX/lock.age"
    mkdir -p "${REC%/*}"; printf '{"key":"%s","doc":"%s","prs":{}}\n' "$K" "$DOC" > "$REC"
}
pr() { # <num> <title> <head> [reviewDecision] - appended to the open-PR list
    jq -c --argjson n "$1" --arg t "$2" --arg h "$3" --arg r "${4:-}" \
        '. + [{number: $n, title: $t, headRefOid: $h, baseRefName: "main", reviewDecision: $r}]' \
        "$FX/pr-list.json" > "$FX/p.t" && mv "$FX/p.t" "$FX/pr-list.json"
}
checks() { # <num> <bucket:name>... - the PR's check rows
    local num=$1 out="" bn; shift
    for bn in "$@"; do out="${out:+$out,}{\"bucket\":\"${bn%%:*}\",\"name\":\"${bn#*:}\"}"; done
    printf '[%s]\n' "$out" > "$FX/checks-$num.json"
}
fn() { bash "$SUT" "$@" >"$tmp/out" 2>&1; }
moved()  { grep '^transition' "$STUB_LOG" | tail -n 1; }
ntrans() { grep -c '^transition' "$STUB_LOG" || true; }
statusrows() { grep -v "\"event\":\"phase-label\"" "$LOG" 2>/dev/null; }  # the phase rows are the phase step's, not the run's outcome
row()    { statusrows | tail -n 1 | jq -r ".$1 // \"\""; }

# --- D0: Done / off the ladder is never touched -------------------------------
reset "Done"; owned
fn "$K" --event live
check "D0: Done is never left" "$(ntrans)" 0
check "D0: row rule" "$(row rule)" D0
stale_live() { jq -c '.state = "live"' "$REC" > "$tmp/rec.t" && mv "$tmp/rec.t" "$REC"; }
reset "Done"; owned WRAPPED; stale_live
fn "$K" --event sweep
check "D0: a Done ticket's live record is refreshed from a wrapped doc (HIMMEL-7353)" "$(jq -r .state "$REC")" wrapped
check "D0: the refresh moves no status (HIMMEL-7353)" "$(ntrans)" 0
reset "Done"; owned LIVE; stale_live
fn "$K" --event sweep
check "D0: a Done ticket's record stays live while its doc is live (HIMMEL-7353)" "$(jq -r .state "$REC")" live
reset "Done"; owned WRAPPED; stale_live
printf '%s\n' "$K" > "$FX/list.key"
printf '%s\n' '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' > "$FX/graphql-all.json"
bash "$HERE/status-sweep.sh" --repo octo/repo > "$tmp/out" 2>&1
check "sweep: a Done ticket's stale live record is cleared by the sweep (HIMMEL-7353)" "$(jq -r .state "$REC")" wrapped
reset "Done"; owned WRAPPED; jq -c '.state = "IDLE-HELD"' "$REC" > "$tmp/rec.t" && mv "$tmp/rec.t" "$REC"
printf '%s\n' "$K" > "$FX/list.key"
printf '%s\n' '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' > "$FX/graphql-all.json"
bash "$HERE/status-sweep.sh" --repo octo/repo > "$tmp/out" 2>&1
check "sweep: a Done ticket's stale IDLE-HELD record is cleared by the sweep too" "$(jq -r .state "$REC")" wrapped
reset "Done"; owned WRAPPED; jq -c '.state = "parked"' "$REC" > "$tmp/rec.t" && mv "$tmp/rec.t" "$REC"
printf '%s\n' "$K" > "$FX/list.key"
printf '%s\n' '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' > "$FX/graphql-all.json"
bash "$HERE/status-sweep.sh" --repo octo/repo > "$tmp/out" 2>&1
check "sweep: a Done ticket's stale parked record is cleared by the sweep" "$(jq -r .state "$REC")" wrapped

# Without a single-instance lock both runs take the snapshot and enter the funnel.
mkdir -p "$tmp/noflock"
for cmd in awk bash cat cksum comm cp cut date dirname git grep head jq mkdir mktemp mv rm rmdir sed sleep sort stat tail tr wc; do
    ln -s "$(command -v "$cmd")" "$tmp/noflock/$cmd"
done
ln -s "$tmp/bin/gh" "$tmp/noflock/gh"
check "sweep: isolated PATH has no flock" "$(PATH="$tmp/noflock" command -v flock >/dev/null 2>&1; printf '%s' "$?")" 1
reset "Done"; owned WRAPPED; stale_live
printf '%s\n' "$K" > "$FX/list.key"
printf '%s\n' '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' > "$FX/graphql-all.json"
echo 1 > "$FX/pr-list.sleep"
PATH="$tmp/noflock" bash "$HERE/status-sweep.sh" --repo octo/repo > "$tmp/sweep-1" 2>&1 &
p1=$!
PATH="$tmp/noflock" bash "$HERE/status-sweep.sh" --repo octo/repo > "$tmp/sweep-2" 2>&1 &
p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
check "sweep: no-flock concurrent runs exit 0" "$r1:$r2" "0:0"
check "sweep: no-flock concurrent runs admit exactly one snapshot" "$(grep -c '^gh pr list ' "$STUB_LOG")" 1
check "sweep: no-flock concurrent runs report one busy sweep" "$(grep -l 'status-sweep: busy' "$tmp/sweep-1" "$tmp/sweep-2" | wc -l | tr -d ' ')" 1
check "sweep: no-flock run releases its lock" "$([ -d "$TICKET_STATUS_STATE_DIR/sweep/lock.d" ] && printf yes || printf no)" no
for lease in "$$.$(date -u +%s)" "2147483647.$(date -u +%s)" "$$.0"; do
    : > "$STUB_LOG"
    mkdir -p "$TICKET_STATUS_STATE_DIR/sweep/lock.d"
    : > "$TICKET_STATUS_STATE_DIR/sweep/lock.d/$lease"
    PATH="$tmp/noflock" bash "$HERE/status-sweep.sh" --repo octo/repo > "$tmp/out" 2>&1
    want=1; case "$lease" in "$$."*) [ "${lease#*.}" = 0 ] || want=0 ;; esac
    check "sweep: no-flock respects live leases and takes dead/expired leases ($lease)" "$(grep -c '^gh pr list ' "$STUB_LOG")" "$want"
    rm -rf "$TICKET_STATUS_STATE_DIR/sweep/lock.d"
done
reset "Backlog"; owned
fn "$K" --event live
check "D0: an off-ladder status is never touched" "$(ntrans)" 0
for ev in live ci-start pr-open merge; do
    reset "To Do"; owned; echo Epic > "$FX/type"
    fn "$K" --event "$ev"
    check "D0e: an Epic is never touched ($ev)" "$(ntrans)" 0
    check "D0e: Epic row rule ($ev)" "$(row rule)" D0e
done
reset "To Do"; owned; : > "$FX/type"
fn "$K" --event live
check "D0e: an unreadable issue type is never moved" "$(ntrans)" 0
check "D0e: an unreadable issue type logs a get miss" "$(row result)/$(row stage)" miss/get

# --- D1: a required check red -> In Progress ----------------------------------
reset "IN CI"; owned
pr 11 "feat: [$K] x" aaa; checks 11 fail:shell-unit
fn "$K" --event ci-exit --pr 11 --head aaa
check "D1: a red required check moves back to In Progress" "$(moved)" "transition $K In Progress"
check "D1: row rule" "$(row rule)" D1
check "D1: row direction" "$(row dir)" back
check "D1: the latch is recorded" "$(jq -r '.prs["11"].red_latch' "$REC")" true

# --- D1 latch: a fix head with no verdict stays In Progress --------------------
reset "In Progress"; owned
jq -c '.prs = {"11": {"head": "aaa", "ci": "red", "red_latch": true, "open": true}}' "$REC" > "$REC.t" && mv "$REC.t" "$REC"
pr 11 "feat: [$K] x" bbb; checks 11 pending:shell-unit
fn "$K" --event ci-start --pr 11 --head bbb
check "D1 latch: a pending fix head does not leave In Progress" "$(ntrans)" 0
check "D1 latch: rule" "$(row rule)" D1
checks 11 pass:shell-unit; : > "$STUB_LOG"
fn "$K" --event ci-exit --pr 11 --head bbb
check "D1 latch: a green head clears it -> IN CI" "$(moved)" "transition $K IN CI"
check "D1 latch: cleared in the record" "$(jq -r '.prs["11"].red_latch' "$REC")" false

# --- an optional red check does not pin D1 ------------------------------------
reset "In Review"; owned
pr 11 "feat: [$K] x" aaa; checks 11 pass:shell-unit fail:optional-lint
fn "$K" --event ci-exit --pr 11 --head aaa
check "optional red: required green -> IN CI" "$(moved)" "transition $K IN CI"
check "optional red: rule D3" "$(row rule)" D3

# --- D2: review open -> In Review ----------------------------------------------
reset "IN CI"; owned
pr 11 "feat: [$K] x" aaa CHANGES_REQUESTED; checks 11 pass:shell-unit
fn "$K" --event sweep
check "D2: CHANGES_REQUESTED -> In Review" "$(moved)" "transition $K In Review"
check "D2: rule" "$(row rule)" D2
reset "IN CI"; owned
pr 11 "feat: [$K] x" aaa; checks 11 pass:shell-unit; echo 2 > "$FX/threads-11"
fn "$K" --event sweep
check "D2: unresolved threads -> In Review" "$(moved)" "transition $K In Review"
reset "IN CI"; owned
pr 11 "feat: [$K] x" aaa; checks 11 pass:shell-unit; touch "$FX/threads-more-11"
fn "$K" --event sweep
check "threads: a further page is unreadable, never a count -> miss stage=gh" "$(row result)/$(row stage)" miss/gh

# --- --repo: the derive reads the caller's PR repository ------------------------
reset "In Review"; owned
pr 11 "feat: [$K] x" aaa; checks 11 pending:shell-unit
fn "$K" --event ci-start --pr 11 --head aaa --repo octo/fork
check "--repo: every gh read targets that repository" "$(sort -u "$FX/gh-repo.log" 2>/dev/null)" octo/fork
check "--repo: the derive still writes" "$(moved)" "transition $K IN CI"
reset "In Review"; owned
fn "$K" --event sweep --repo 'octo/fork;x'
check "--repo: a malformed repository writes nothing" "$(ntrans)" 0

# --- D3: checks running -> IN CI -----------------------------------------------
reset "In Review"; owned
pr 11 "feat: [$K] x" aaa; checks 11 pending:shell-unit
fn "$K" --event ci-start --pr 11 --head aaa
check "D3: running required checks -> IN CI" "$(moved)" "transition $K IN CI"
check "D3: row direction" "$(row dir)" fwd

# --- D4: a fresh push with no checks yet -> In Review ---------------------------
reset "IN CI"; owned
pr 11 "feat: [$K] x" ccc
fn "$K" --event ci-start --pr 11 --head ccc
check "D4: a push after IN CI with no checks -> In Review" "$(moved)" "transition $K In Review"
check "D4: rule" "$(row rule)" D4

# --- several PRs: the least advanced wins ----------------------------------------
reset "IN CI"; owned
pr 11 "feat: [$K] a" aaa; checks 11 pass:shell-unit
pr 12 "fix: [$K] b" bbb; checks 12 fail:shell-unit
fn "$K" --event sweep
check "several PRs: one red -> In Progress" "$(moved)" "transition $K In Progress"

# --- association: the first [KEY] only, exact ------------------------------------
reset "To Do"; owned
pr 21 "fix: [HIMMEL-9002] follows [$K]" ddd; checks 21 pass:shell-unit
pr 22 "fix: [HIMMEL-90011] y" eee; checks 22 pass:shell-unit
fn "$K" --event live
check "first [KEY]: a second key or a longer key moves nothing -> D5" "$(moved)" "transition $K In Progress"
check "first [KEY]: rule D5, not D3" "$(row rule)" D5

# --- D4b: a completes=yes merge with Jira not Done -> done-pending ---------------
reset "IN CI"; owned WRAPPED
printf '{"ts":"t","event":"merge","key":"%s","pr":"11","contract":"yes","result":"miss","stage":"transition"}\n' "$K" >> "$LOG"
fn "$K" --event wrapped --doc "$DOC"
check "D4b: a failed Done then WRAPPED is never To Do" "$(ntrans)" 0
check "D4b: miss stage" "$(row stage)" done-pending
reset "In Progress"; owned WRAPPED 0
printf '{"ts":"t","event":"merge","key":"%s","pr":"11","contract":"yes","result":"miss","stage":"transition"}\n' "$K" >> "$LOG"
printf '{"ts":"t","event":"merge","key":"%s","pr":"11","contract":"yes","result":"moved"}\n' "$K" >> "$LOG"
fn "$K" --event wrapped --doc "$DOC"
check "D4b: a Done that landed, then a reopen, is not pending -> D6" "$(row rule)" D6
reset "In Progress"; owned WRAPPED 0
printf '{"ts":"t","event":"merge","key":"%s","pr":"11","contract":"yes","result":"miss","stage":"transition"}\n' "$K" >> "$LOG"
printf '{"ts":"t","event":"merge","key":"%s","pr":"12","contract":"no","result":"noop"}\n' "$K" >> "$LOG"
fn "$K" --event wrapped --doc "$DOC"
check "D4b: only the latest merge row counts -> D5c" "$(row rule)" D5c

# --- D5c: a contract=no last merge keeps a wrapped ticket In Progress ---------------
reset "In Progress"; owned WRAPPED 0
printf '{"ts":"t","event":"merge","key":"%s","pr":"11","contract":"no","result":"noop"}\n' "$K" >> "$LOG"
fn "$K" --event wrapped --doc "$DOC"
check "D5c: a partial merge then WRAPPED is never To Do" "$(ntrans)" 0
check "D5c: rule" "$(row rule)" D5c
fn "$K" --event sweep
check "D5c: nor does the next sweep demote it" "$(ntrans)" 0
reset "To Do"; owned WRAPPED 0
printf '{"ts":"t","event":"merge","key":"%s","pr":"11","contract":"no","result":"moved"}\n' "$K" >> "$LOG"
fn "$K" --event sweep
check "D5c: a partial left in To Do goes back to In Progress" "$(moved)" "transition $K In Progress"
reset "In Progress"; owned WRAPPED 0
printf '{"ts":"t","event":"merge","key":"%s","pr":"11","contract":"no","result":"noop"}\n' "$K" >> "$LOG"
printf '{"ts":"t","event":"merge","key":"%s","pr":"12","contract":"yes","result":"moved"}\n' "$K" >> "$LOG"
fn "$K" --event wrapped --doc "$DOC"
check "D5c: a later completes=yes merge row wins -> D6" "$(row rule)" D6
# The funnel's own row under event merge carries no contract; it must not hide the contract row.
reset "In Progress"; owned WRAPPED 0
printf '{"ts":"t","event":"merge","key":"%s","pr":"11","contract":"no","result":"noop"}\n' "$K" >> "$LOG"
printf '{"ts":"t","event":"merge","key":"%s","pr":"11","result":"moved","rule":"D3","from":"IN CI","to":"In Progress","dir":"back"}\n' "$K" >> "$LOG"
fn "$K" --event wrapped --doc "$DOC"
check "D5c (HIMMEL-8522): a derive row under event merge after a contract=no row -> D5c" "$(row rule)" D5c
check "D5c (HIMMEL-8522): the replay is never demoted to To Do" "$(ntrans)" 0
reset "IN CI"; owned WRAPPED
printf '{"ts":"t","event":"merge","key":"%s","pr":"11","contract":"yes","result":"miss","stage":"transition"}\n' "$K" >> "$LOG"
printf '{"ts":"t","event":"merge","key":"%s","pr":"11","result":"noop","rule":"D3","from":"IN CI"}\n' "$K" >> "$LOG"
fn "$K" --event wrapped --doc "$DOC"
check "D4b (HIMMEL-8522): a derive row under event merge after a contract=yes miss row stays pending" "$(row stage)" done-pending
reset "In Progress"; owned LIVE 11 0
fn "$K" --event merge --pr 11 --head abc
check "HIMMEL-8522: a funnel row for the merge event is not written under event merge" "$(row event)" derive

# --- D5 / D6 / D7 ------------------------------------------------------------------
reset "To Do"; owned LIVE 11 0
fn "$K" --event live --doc "$DOC"
check "D5: a live owner, no PR -> In Progress" "$(moved)" "transition $K In Progress"
reset "In Review"; owned WRAPPED 0
fn "$K" --event wrapped --doc "$DOC"
check "D6: WRAPPED, no PR and no merge row -> To Do" "$(moved)" "transition $K To Do"
check "D6: rule" "$(row rule)" D6
check "D6: direction" "$(row dir)" back
# --- D6n: a wrapped worker on a completes-no brief leaves an In Progress ticket In Progress ---
flagdoc() { # <yes|no|-> - DOC carries the brief's Completes ticket line above ## Results ("-" = no such line)
    { printf '# worker\n\n'; [ "$1" = - ] || printf '> **Completes ticket:** %s\n\n' "$1"
      printf '## Results (newest at the bottom)\n- 10:00 WRAPPED — x\n'; } > "$DOC"
}
reset "In Progress"; owned WRAPPED 0; flagdoc no
fn "$K" --event wrapped --doc "$DOC"
check "D6n: WRAPPED on a completes-no brief, In Progress, no PR, no merge row -> no transition" "$(ntrans)" 0
check "D6n: rule" "$(row rule)" D6n
check "D6n: the row is a noop" "$(row result)" noop
reset "In Progress"; owned WRAPPED 0; flagdoc yes
fn "$K" --event wrapped --doc "$DOC"
check "D6n guard: completes yes still moves In Progress to To Do" "$(moved)" "transition $K To Do"
check "D6n guard: completes yes rule D6" "$(row rule)" D6
reset "In Progress"; owned WRAPPED 0; flagdoc -
fn "$K" --event wrapped --doc "$DOC"
check "D6n guard: a brief with no flag line still moves to To Do" "$(moved)" "transition $K To Do"
check "D6n guard: no flag line rule D6" "$(row rule)" D6
reset "In Review"; owned WRAPPED 0; flagdoc no
fn "$K" --event wrapped --doc "$DOC"
check "D6n guard: completes no with Jira In Review keeps today's move to To Do" "$(moved)" "transition $K To Do"
check "D6n guard: Jira In Review rule D6" "$(row rule)" D6
reset "To Do"; owned WRAPPED 0; flagdoc no
fn "$K" --event wrapped --doc "$DOC"
check "D6n guard: completes no with Jira To Do changes nothing" "$(ntrans)" 0
reset "In Progress"; owned WRAPPED 0
printf '# worker\n\n## Results (newest at the bottom)\n- 10:00 WRAPPED — x\n\n> **Completes ticket:** no\n' > "$DOC"
fn "$K" --event wrapped --doc "$DOC"
check "D6n guard: a flag line below ## Results is not the brief's flag" "$(moved)" "transition $K To Do"
# --- D5c: a merged PR with no merge row keeps a wrapped ticket In Progress ---
merged() { printf '%s\n' "$1" > "$FX/pr-merged.json"; } # the merged-PR list the stub gh returns
reset "In Review"; owned WRAPPED 0
merged "[{\"number\":77,\"title\":\"fix: [$K] shipped by hand\"}]"
fn "$K" --event wrapped --doc "$DOC"
check "D5c merged-no-row: a merged PR, no merge row, WRAPPED -> rule D5c, not D6" "$(row rule)" D5c
check "D5c merged-no-row: the ticket moves to In Progress" "$(moved)" "transition $K In Progress"
check "D5c merged-no-row: the row carries stage=merged-no-row" "$(row stage)" merged-no-row
check "D5c merged-no-row: the row names the merged PR" "$(row merged_pr)" 77
# The row the first run wrote (a real funnel launch, not a seeded fixture) answers every later derive:
# the merged-PR list now fails, so a gh call would turn D5c into D6; none may be made.
rm -f "$FX/pr-merged.json"; touch "$FX/pr-merged.fail"
: > "$STUB_LOG"
fn "$K" --event sweep
check "D5c merged-no-row: a later derive answers D5c from the logged row" "$(row rule)/$(row result)" D5c/noop
check "D5c merged-no-row: with no merged-PR gh call" "$(grep -c -- '--state merged' "$STUB_LOG" || true)" 0
check "D5c merged-no-row: and no move" "$(ntrans)" 0
printf '%s\n' "$K" > "$FX/list.key"
printf '%s\n' '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' > "$FX/graphql-all.json"
: > "$STUB_LOG"
bash "$HERE/status-sweep.sh" --repo octo/repo > "$tmp/out" 2>&1
check "D5c merged-no-row: the real sweep (open-PR snapshot) keeps the ticket In Progress" "$(ntrans)" 0
check "D5c merged-no-row: and makes no merged-PR gh call" "$(grep -c -- '--state merged' "$STUB_LOG" || true)" 0
rm -f "$FX/pr-merged.fail"
# A first sweep over a ticket no funnel run has logged: its snapshot derive reads D6, which only
# routes the key to the funnel; the funnel derives live and finds the merged PR, never To Do.
reset "IN CI"; owned WRAPPED 0
merged "[{\"number\":81,\"title\":\"fix: [$K] shipped by hand\"}]"
printf '%s\n' "$K" > "$FX/list.key"
printf '%s\n' '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' > "$FX/graphql-all.json"
bash "$HERE/status-sweep.sh" --repo octo/repo > "$tmp/out" 2>&1
check "D5c merged-no-row: a first sweep moves the ticket to In Progress, never To Do" "$(moved)" "transition $K In Progress"
check "D5c merged-no-row: and logs the stage for the next derive" "$(row stage)/$(row merged_pr)" merged-no-row/81
# The sweep's snapshot derive never reads the merged list: only the funnel's live derive does (one call).
check "D5c merged-no-row: a snapshot derive makes no merged-PR gh call (the funnel makes the only one)" "$(grep -c -- '--state merged' "$STUB_LOG" || true)" 1
# No other rule's row changes: a D5 noop row carries no stage or merged_pr.
reset "In Progress"; owned LIVE 11 0
fn "$K" --event live --doc "$DOC"
check "D5c merged-no-row: a non-D5c noop row is unchanged" "$(statusrows | tail -n 1 | jq -c 'del(.ts)')" "{\"event\":\"live\",\"key\":\"$K\",\"result\":\"noop\",\"rule\":\"D5\",\"from\":\"In Progress\"}"
reset "In Progress"; owned WRAPPED 0
printf '{"ts":"t","event":"merge","key":"%s","pr":"11","contract":"no","result":"noop"}\n' "$K" >> "$LOG"
fn "$K" --event wrapped --doc "$DOC"
check "D5c merged-no-row: a partial-merge D5c noop row is unchanged (no stage, no merged_pr)" "$(statusrows | tail -n 1 | jq -c 'del(.ts)')" "{\"event\":\"wrapped\",\"key\":\"$K\",\"result\":\"noop\",\"rule\":\"D5c\",\"from\":\"In Progress\"}"
reset "In Progress"; owned WRAPPED 0
merged "[{\"number\":77,\"title\":\"fix: [$K] shipped by hand\"}]"
fn "$K" --event wrapped --doc "$DOC"
check "D5c merged-no-row: a ticket already In Progress is not moved" "$(ntrans)" 0
check "D5c merged-no-row: and its noop row still carries the stage" "$(row stage)" merged-no-row
reset "In Review"; owned WRAPPED 0
merged "[{\"number\":78,\"title\":\"fix: [HIMMEL-90019] y follows [$K]\"}]"
fn "$K" --event wrapped --doc "$DOC"
check "D6 merged-no-row: a merged PR whose FIRST key is another ticket is not this ticket's" "$(row rule)" D6
reset "In Review"; owned WRAPPED 0
touch "$FX/pr-merged.fail"
fn "$K" --event wrapped --doc "$DOC"
check "merged-no-row: an unreadable merged-PR list is no-write + miss stage=gh, never a move to To Do" "$(row result)/$(row stage)" miss/gh
check "merged-no-row: and no transition is made" "$(ntrans)" 0
reset "In Review"; owned WRAPPED 0
rm -f "$FX/pr-merged.fail"; merged 'not json'
fn "$K" --event wrapped --doc "$DOC"
check "merged-no-row: a merged-PR list that is not JSON is no-write + miss stage=gh too" "$(row result)/$(row stage)/$(ntrans)" miss/gh/0
reset "In Review"; owned WRAPPED 0
merged "[{\"number\":79,\"title\":\"fix: [$K] shipped\"}]"
printf '{"ts":"t","event":"merge","key":"%s","pr":"79","contract":"yes","result":"moved"}\n' "$K" >> "$LOG"
fn "$K" --event wrapped --doc "$DOC"
check "D6 merged-no-row: a PR that HAS a merge row (completes=yes, then reopened) stays D6" "$(row rule)" D6
reset "In Review"; owned LIVE 11 0
merged "[{\"number\":80,\"title\":\"fix: [$K] shipped\"}]"
fn "$K" --event live --doc "$DOC"
check "D5 merged-no-row: no merged-PR read when the owner is not wrapped" "$(grep -c -- '--state merged' "$STUB_LOG" || true)" 0

DOC2="$tmp/$K-N2-slug-2026-10-21.md"
reset "In Progress"; owned LIVE 11 0
fn "$K" --event live --doc "$DOC"
mkdoc "$DOC2" WRAPPED; echo 0 > "$FX/lock.rc.${DOC2##*/}"
fn "$K" --event wrapped --doc "$DOC2"
check "no D6: the wrapped event was derived" "$(row event)" wrapped
check "no D6: the record holds both workers" "$(jq -r '.docs | join(" ")' "$REC")" "$DOC $DOC2"
check "no D6: one worker wraps with no PR while another holds a live lock" "$(ntrans)" 0
check "no D6: the live worker keeps rule D5" "$(row rule)" D5
check "no D6: the record follows the live worker" "$(jq -r '.doc + " " + .leg + " " + .state' "$REC")" "$DOC N1 live"
reset "In Progress"; owned LIVE 11 0
fn "$K" --event live --doc "$DOC"
mkdoc "$DOC" WRAPPED; echo 0 > "$FX/lock.rc"
mkdoc "$DOC2" WRAPPED
fn "$K" --event wrapped --doc "$DOC2"
check "D6: every recorded worker ended -> one move" "$(ntrans)" 1
check "D6: every recorded worker ended -> To Do" "$(moved)" "transition $K To Do"
check "D6: the move is the wrapped event's" "$(row event)/$(row rule)" wrapped/D6
reset "In Progress"
fn "$K" --event sweep
check "D7: never owned -> no write" "$(ntrans)" 0
check "D7: rule" "$(row rule)" D7
check "D7: no record is created" "$([ -e "$REC" ] && echo yes || echo no)" no

# --- no D6 without positive end evidence ------------------------------------------
reset "In Progress"; owned LIVE 11 99999
fn "$K" --event sweep
check "no D6: a late heartbeat (IDLE-HELD) stays In Progress" "$(ntrans)" 0
check "no D6: rule D5" "$(row rule)" D5
reset "In Progress"; owned LIVE 0
fn "$K" --event sweep
check "no D6: a free lock with no end marker (hand-off / other station)" "$(ntrans)" 0
check "no D6: rule D5 (unknown owner)" "$(row rule)" D5

# --- unreadable input -> no write + miss --------------------------------------------
reset "To Do"; owned; touch "$FX/get.fail"
fn "$K" --event live
check "unreadable: jira get -> no write" "$(ntrans)" 0
check "unreadable: jira get -> miss stage=get" "$(row result)/$(row stage)" miss/get
reset "In Review"; owned WRAPPED 0; touch "$FX/pr-list.fail"
fn "$K" --event sweep
check "unreadable: a failed PR read is never 'no open PR' (no D6)" "$(ntrans)" 0
check "unreadable: gh -> miss stage=gh" "$(row result)/$(row stage)" miss/gh
reset "In Review"; owned WRAPPED 0
pr 31 "chore: [HIMMEL-1] a" a; pr 32 "chore: [HIMMEL-2] b" b
TICKET_STATUS_PR_LIMIT=2 fn "$K" --event sweep
check "unreadable: a saturated PR list -> no write" "$(ntrans)" 0
check "unreadable: saturated -> miss stage=pr-limit" "$(row stage)" pr-limit
reset "In Review"; owned WRAPPED 0
echo '[{"number":11,"title":{"x":1},"headRefOid":"a","baseRefName":"main","reviewDecision":""}]' > "$FX/pr-list.json"
fn "$K" --event sweep
check "unreadable: a PR row jq cannot decode is never 'no open PR' (no D6)" "$(ntrans)" 0
check "unreadable: undecodable PR row -> miss stage=gh" "$(row result)/$(row stage)" miss/gh
reset "IN CI"; owned; pr 11 "feat: [$K] x" aaa; checks 11 fail:shell-unit; touch "$FX/classic.403"
fn "$K" --event ci-exit --pr 11 --head aaa
check "unreadable: a 403 on branch protection -> no write" "$(ntrans)" 0
check "unreadable: 403 -> miss stage=required-set" "$(row stage)" required-set
reset "To Do"; owned; echo 'not json' > "$REC"
fn "$K" --event live
check "unreadable: a record that does not parse -> no write" "$(ntrans)" 0
check "unreadable: record -> miss stage=record" "$(row stage)" record

# --- CAS: re-read before the write ------------------------------------------------
reset "To Do"; owned
printf 'To Do\nIn Progress\n' > "$FX/status.seq"
fn "$K" --event live
check "CAS: a status change before the write re-derives (no blind write)" "$(ntrans)" 0
check "CAS: the re-derive is a noop" "$(row result)" noop
reset "To Do"; owned
printf 'To Do\nIn Review\nTo Do\nIN CI\n' > "$FX/status.seq"
fn "$K" --event live
check "CAS: changed twice -> no write" "$(ntrans)" 0
check "CAS: changed twice -> deferred" "$(row result)/$(row stage)" deferred/cas
reset "In Review"; owned
pr 11 "feat: [$K] x" aaa; checks 11 pass:shell-unit
for n in 2 3 4; do echo '[]' > "$FX/pr-list.$n.json"; done
fn "$K" --event sweep
check "CAS: a PR that closed between read and write -> re-derived (D5, not IN CI)" "$(moved)" "transition $K In Progress"

# --- late / legacy event: the target is a hint, the present is written ---------------
reset "To Do"; owned
fn "$K" "IN CI"
check "legacy: the target is never written; the derive is" "$(moved)" "transition $K In Progress"
check "legacy: the event names the hint" "$(row event)" "legacy:IN CI"

# --- bounds: a hung call and a held flock ----------------------------------------------
if [ -n "$_TIMEOUT_BIN" ] && command -v flock >/dev/null 2>&1; then
    reset "To Do"; owned; echo 30 > "$FX/get.sleep"
    rc=0; TICKET_STATUS_BUDGET=1 "$_TIMEOUT_BIN" -k 2 15 bash "$SUT" "$K" --event live >"$tmp/out" 2>&1 || rc=$?
    check "timeout: rc 0" "$rc" 0
    check "timeout: miss stage=timeout" "$(row result)/$(row stage)" miss/timeout
    reset "To Do"; owned
    mkdir -p "$TICKET_STATUS_STATE_DIR/status-locks"
    flock "$TICKET_STATUS_STATE_DIR/status-locks/$K" sleep 6 &
    holder=$!
    sleep 1
    TICKET_STATUS_LOCK_WAIT=1 "$_TIMEOUT_BIN" -k 2 15 bash "$SUT" "$K" --event live >"$tmp/out" 2>&1
    check "flock: a held lock -> no write" "$(ntrans)" 0
    check "flock: deferred stage=lock" "$(row result)/$(row stage)" deferred/lock
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
else
    echo "skip - timeout/flock rows: no timeout or flock binary"
fi

# --- no flock: two events for one key move the status once --------------------------
# Both runs reach the Jira read together (get.sleep), so an unlocked run moves twice.
reset "To Do"; owned; echo 1 > "$FX/get.sleep"
PATH="$tmp/noflock" bash "$SUT" "$K" --event live >"$tmp/out-1" 2>&1 & p1=$!
PATH="$tmp/noflock" bash "$SUT" "$K" --event live >"$tmp/out-2" 2>&1 & p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
check "no-flock: both concurrent events exit 0" "$r1:$r2" "0:0"
check "no-flock: two concurrent events move the status exactly once" "$(ntrans)" 1

# One event releases its lease when it exits, and it moved the status.
reset "To Do"; owned
rc=0; PATH="$tmp/noflock" bash "$SUT" "$K" --event live >"$tmp/out-1" 2>&1 || rc=$?
check "no-flock: a single event exits 0 and moves the status once" "$rc:$(ntrans)" "0:1"
check "no-flock: a finished event releases its lease" "$([ -d "$TICKET_STATUS_STATE_DIR/status-locks/$K.lease.d" ] && printf held || printf free)" free

# A lease left by a dead run (older than 300s) is reclaimed once, so one event moves the status.
reset "To Do"; owned; echo 1 > "$FX/get.sleep"
mkdir -p "$TICKET_STATUS_STATE_DIR/status-locks/$K.lease.d"
old=$(date -d '10 minutes ago' +%Y%m%d%H%M.%S 2>/dev/null || date -v-10M +%Y%m%d%H%M.%S)
check "no-flock: the stale lease is backdated" "$(touch -t "$old" "$TICKET_STATUS_STATE_DIR/status-locks/$K.lease.d" && printf ok)" ok
PATH="$tmp/noflock" bash "$SUT" "$K" --event live >"$tmp/out-1" 2>&1 & p1=$!
PATH="$tmp/noflock" bash "$SUT" "$K" --event live >"$tmp/out-2" 2>&1 & p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
check "no-flock: concurrent events reclaim a stale lease, exit 0" "$r1:$r2" "0:0"
check "no-flock: a stale lease is reclaimed once, the status moves once" "$(ntrans)" 1

# A lock dir the user cannot write makes mkdir fail and the lease stat fail, so the
# lease must defer within the wait bound, not spin. Root writes anywhere: skip there.
if [ -n "$_TIMEOUT_BIN" ] && [ "$(id -u)" != 0 ]; then
    reset "To Do"; owned
    mkdir -p "$TICKET_STATUS_STATE_DIR/status-locks"; chmod 500 "$TICKET_STATUS_STATE_DIR/status-locks"
    rc=0; TICKET_STATUS_LOCK_WAIT=1 "$_TIMEOUT_BIN" -k 2 15 env PATH="$tmp/noflock" bash "$SUT" "$K" --event live >"$tmp/out" 2>&1 || rc=$?
    chmod 700 "$TICKET_STATUS_STATE_DIR/status-locks"
    check "no-flock: an unwritable lock dir defers within the wait bound (rc 0, not a hang)" "$rc" 0
    check "no-flock: an unwritable lock dir logs deferred stage=lock" "$(row result)/$(row stage)" deferred/lock
else
    echo "skip - unwritable-lock row: no timeout binary, or running as root"
fi

# --- worker states ------------------------------------------------------------------------
ws() { # <marker> <lock rc> <lock age> -> state
    mkdoc "$DOC" "$1"; printf '%s\n' "$2" > "$FX/lock.rc"; printf '%s\n' "$3" > "$FX/lock.age"
    bash -c '. "$1"; ts_worker_state "$2"' _ "$LIB" "$DOC"
}
reset "To Do"
check "worker: live" "$(ws LIVE 11 10)" live
check "worker: idle (READY)" "$(ws READY 11 10)" idle
check "worker: IDLE-HELD (heartbeat past the idle warn)" "$(ws LIVE 11 99999)" IDLE-HELD
check "worker: wrapped" "$(ws WRAPPED 0 0)" wrapped
check "worker: unknown (no local lock, no end marker)" "$(ws LIVE 0 0)" unknown

# --- failures never block ---------------------------------------------------------------------
reset "To Do"; owned; touch "$FX/transition.fail"
rc=0; fn "$K" --event live || rc=$?
check "transition failure: rc 0" "$rc" 0
contains "transition failure: warns" "$(cat "$tmp/out")" "WARN"
check "transition failure: miss stage=transition" "$(row result)/$(row stage)" miss/transition
reset "To Do"; owned; touch "$FX/transition.noop"
fn "$K" --event live
check "readback: a transition that did not land -> miss stage=readback" "$(row result)/$(row stage)" miss/readback

# --- workflow edges: the live `jira transitions` listing, the same from all four statuses -------
live_edges() { printf '11\tTo Do\n4\tBacklog\n21\tIn Progress\n2\tIn Review\n3\tIN CI\n31\tDone\n5\tClosed\n6\tIn Public\n7\twont do\n8\twont fix\n41\tPlanning\n'; }
reset "IN CI"; owned; live_edges > "$FX/workflow"
pr 11 "feat: [$K] x" aaa; checks 11 fail:shell-unit
fn "$K" --event ci-exit --pr 11 --head aaa
check "edge IN CI to In Progress (D1) is in the live workflow" "$(moved)" "transition $K In Progress"
reset "IN CI"; owned; live_edges > "$FX/workflow"
pr 11 "feat: [$K] x" ccc
fn "$K" --event ci-start --pr 11 --head ccc
check "edge IN CI to In Review (D4) is in the live workflow" "$(moved)" "transition $K In Review"
reset "In Review"; owned WRAPPED 0; live_edges > "$FX/workflow"
fn "$K" --event wrapped --doc "$DOC"
check "edge In Review to To Do (D6) is in the live workflow" "$(moved)" "transition $K To Do"
check "edge D6: the move landed" "$(row result)" moved
reset "In Review"; owned WRAPPED 0; live_edges | grep -v 'To Do' > "$FX/workflow"
fn "$K" --event wrapped --doc "$DOC"
check "a missing edge is reported: miss stage=transition" "$(row result)/$(row stage)" miss/transition

# --- wiring: the LIVE bullet ------------------------------------------------------------------
reset "To Do"; mkdoc "$DOC"
bash "$APPEND" "$DOC" "LIVE — starting" >/dev/null 2>&1
check "LIVE: a To Do ticket moves" "$(moved)" "transition $K In Progress"
check "LIVE: the record names the doc" "$(jq -r .doc "$REC")" "$DOC"
contains "LIVE: bullet landed" "$(tail -n 1 "$DOC")" "LIVE — starting"
: > "$STUB_LOG"
bash "$APPEND" "$DOC" "FINDING — x" >/dev/null 2>&1
check "FINDING makes no Jira call" "$(grep -c '^get' "$STUB_LOG" || true)" 0
bash "$APPEND" "$DOC" "LIVELY prose" >/dev/null 2>&1
check "LIVELY (not the LIVE token) makes no Jira call" "$(grep -c '^get' "$STUB_LOG" || true)" 0
reset "To Do"; mkdoc "$DOC"; touch "$FX/get.fail"
rc=0; bash "$APPEND" "$DOC" "LIVE — again" >"$tmp/out" 2>&1 || rc=$?
check "LIVE: a Jira failure -> append rc 0" "$rc" 0
contains "LIVE: bullet still landed" "$(tail -n 1 "$DOC")" "LIVE — again"
d7="$tmp/plain.md"; mkdoc "$d7"; : > "$STUB_LOG"
bash "$APPEND" "$d7" "LIVE — x" >/dev/null 2>&1
# read-sink-ok: STUB_LOG is this suite's own mktemp stub log
check "no ticket in the doc name -> no Jira call" "$(wc -c < "$STUB_LOG" | tr -d ' ')" 0
d8="$tmp/AB2-7-N1-slug-2026-10-21.md"; mkdoc "$d8"; : > "$STUB_LOG"
bash "$APPEND" "$d8" "LIVE — x" >/dev/null 2>&1
# read-sink-ok: STUB_LOG is this suite's own mktemp stub log
contains "a key with a digit in the project part is extracted" "$(head -n 1 "$STUB_LOG")" "AB2-7"

# --- wiring: a release manager's doc never moves its ticket -------------------------------------
reset "To Do"; mkdoc "$DOC"
HIMMEL_RELEASE_MANAGER=1 bash "$APPEND" "$DOC" "LIVE — rm" >/dev/null 2>&1
check "RM: a LIVE bullet makes no transition" "$(ntrans)" 0
check "RM: the ticket stays To Do" "$(cat "$FX/status.cur")" "To Do"
check "RM: the skip is logged" "$(row result)/$(row rule)" skip/RM
check "RM: no owner record is written" "$([ -e "$REC" ] && echo yes || echo no)" no
reset "In Progress"; mkdoc "$DOC" WRAPPED
HIMMEL_RELEASE_MANAGER=1 bash "$APPEND" "$DOC" "WRAPPED — rm" >/dev/null 2>&1
check "RM: the WRAPPED append succeeds" "$?" 0
check "RM: a WRAPPED bullet makes no transition" "$(ntrans)" 0
check "RM: the WRAPPED skip is logged" "$(row result)/$(row rule)" skip/RM
reset "To Do"; mkdoc "$DOC"
HIMMEL_RELEASE_MANAGER=0 bash "$APPEND" "$DOC" "LIVE — worker" >/dev/null 2>&1
check "RM: HIMMEL_RELEASE_MANAGER=0 is a worker, it moves" "$(moved)" "transition $K In Progress"

# --- wiring: the WRAPPED bullet ---------------------------------------------------------------
reset "In Review"; owned LIVE 0
bash "$APPEND" "$DOC" "WRAPPED — done" >/dev/null 2>&1
check "WRAPPED: an owned ticket with no PR moves back" "$(moved)" "transition $K To Do"
check "WRAPPED: row event" "$(row event)" wrapped

# --- opt-out and bad keys ----------------------------------------------------------------------
reset "To Do"; owned
WORKER_SESSION_JIRA_STATUS=0 bash "$APPEND" "$DOC" "LIVE — y" >/dev/null 2>&1
# read-sink-ok: STUB_LOG is this suite's own mktemp stub log
check "opt-out via append: no Jira call" "$(wc -c < "$STUB_LOG" | tr -d ' ')" 0
WORKER_SESSION_JIRA_STATUS=0 fn "$K" --event live
# read-sink-ok: STUB_LOG is this suite's own mktemp stub log
check "opt-out direct: no Jira call" "$(wc -c < "$STUB_LOG" | tr -d ' ')" 0
check "opt-out direct: a disabled row" "$(row result)" disabled
for bad in HIMMEL-123junk HIMMEL-x-1 "HIMMEL-1 2"; do
    reset "To Do"
    fn "$bad" --event live
    # read-sink-ok: STUB_LOG is this suite's own mktemp stub log
    check "bad key '$bad': no Jira call" "$(wc -c < "$STUB_LOG" | tr -d ' ')" 0
done

# --- a move marks the chief's FOCUS page dirty --------------------------------
FDOC="$tmp/chief/chief.md"; mkdir -p "${FDOC%/*}"
printf '# chief\nfocus-version: v1.1.3\n' > "$FDOC"
fstat() { bash "$HERE/focus-refresh.sh" --doc "$FDOC" --status | cut -d: -f1; }
fok() { printf 'status=ok\ngen=1\ndirty=\n' > "${FDOC%/*}/focus-state"; rm -f "${FDOC%/*}/focus-state.again"; }
reset "To Do"; owned; fok
HIMMEL_CONSOLE_DOC="$FDOC" fn "$K" --event live
check "focus: the move lands" "$(moved)" "transition $K In Progress"
check "focus: and marks the FOCUS page dirty, so the next tick rebuilds it" "$(fstat)" "focus=DIRTY"
check "focus: and leaves the again marker for a running refresh" "$([ -s "${FDOC%/*}/focus-state.again" ] && echo yes)" yes
reset "In Progress"; owned; fok
HIMMEL_CONSOLE_DOC="$FDOC" fn "$K" --event live
check "focus: no move leaves the page clean" "$(fstat)" "focus=ok"
reset "To Do"; owned
rc=0; HIMMEL_CONSOLE_DOC="$tmp/chief/missing.md" bash "$SUT" "$K" --event live >"$tmp/out" 2>&1 || rc=$?
check "focus: a failing mark-dirty never fails the move (exit)" "$rc" 0
check "focus: the move still lands" "$(moved)" "transition $K In Progress"
check "focus: and is logged moved" "$(row result)" moved
contains "focus: the failed mark is a WARN" "$(cat "$tmp/out")" "cannot mark the FOCUS page dirty"

# --- INTAKE: a worked ticket held in a later version folds into the current one ----------
VERS=$(printf 'v1.1.3\tfalse\t2026-10-28\tfalse\nv1.1.4\tfalse\t2026-11-04\tfalse\nv1.1.2\ttrue\t2026-10-20\tfalse\n')
intakes() { grep -c '^release request' "$STUB_LOG" || true; }
vset() { printf '%s\n' "$VERS" > "$FX/versions"; printf '%s\n' "$1" > "$FX/fixversions"; }
reset "To Do"; owned; vset '[{"name":"v1.1.4"}]'
fn "$K" --event live
contains "7641: a LIVE bullet files an INTAKE into the current version from the held one" "$(grep '^release request' "$STUB_LOG")" "release request v1.1.3 --verb INTAKE --key $K --from v1.1.4 --to v1.1.3"
check "7641: and the status still moves" "$(moved)" "transition $K In Progress"
fn "$K" --event live
check "7641: a second LIVE bullet files no second request" "$(intakes)" 1
reset "To Do"; owned; vset '[{"name":"v1.1.3"}]'
fn "$K" --event live
check "7641: a key already in the current version files nothing" "$(intakes)" 0
reset "To Do"; owned; vset '[]'
fn "$K" --event live
check "7641: an unversioned key files nothing" "$(intakes)" 0
reset "To Do"; owned; vset '[{"name":"v1.1.2"}]'
fn "$K" --event live
check "7641: a released version is not a later one" "$(intakes)" 0
reset "To Do"; owned; vset '[{"name":"v1.1.4"},{"name":"v1.1.3"}]'
fn "$K" --event live
check "7641: a key holding the current version as well files nothing" "$(intakes)" 0
VERS=$(printf 'v1.1.3\tfalse\t2026-10-28\tfalse\nv1.1.0\tfalse\t2026-10-01\ttrue\n')
reset "To Do"; owned; vset '[{"name":"v1.1.0"}]'
fn "$K" --event live
check "7641: an archived version older than the current one is not a later one" "$(intakes)" 0
VERS=$(printf 'v1.1.3\tfalse\t2026-10-28\tfalse\nv1.1.4\tfalse\t2026-11-04\tfalse\nv1.1.2\ttrue\t2026-10-20\tfalse\n')
reset "To Do"; owned LIVE; vset '[{"name":"v1.1.4"}]'
fn "$K" --event wrapped
check "7641: only a LIVE event files the request" "$(intakes)" 0
reset "To Do"; owned; vset '[{"name":"v1.1.4"}]'; touch "$FX/request.fail"
rc=0; bash "$SUT" "$K" --event live >"$tmp/out" 2>&1 || rc=$?
check "7641: a failed request never fails the worker (exit)" "$rc" 0
check "7641: and the status still moves" "$(moved)" "transition $K In Progress"
contains "7641: and the failure is a WARN" "$(cat "$tmp/out")" "INTAKE request was NOT filed"
reset "To Do"; owned; vset '[{"name":"v1.1.4"}]'
HIMMEL_RELEASE_MANAGER=1 fn "$K" --event live
check "7641: a release manager files no request" "$(intakes)" 0

# --- the funnel's phase step: one phase label per worker event ---
FIXT="$HERE/fixtures/leg-kind-lines.txt"
mkbrief() { # <path> <kind|-> [marker] - a brief stub whose Leg kind line comes from the shared fixture
    { printf '# worker\n\n'
      case "$2" in -) ;; spec) printf '> **Leg kind:** spec\n\n' ;; *) grep -F "Leg kind:** $2" "$FIXT"; printf '\n' ;; esac
      printf '## Results (newest at the bottom)\n'
      [ -z "${3:-}" ] || printf -- '- 10:00 %s — x\n' "$3"; } > "$1"
}
mergerow() { # <pr> <contract|-> [remainder] - a merge-on-green row for $K
    jq -nc --arg k "$K" --arg p "$1" --arg c "$2" --arg r "${3:-}" \
        '{ts:"t",event:"merge",key:$k,pr:$p,result:"noop"} + (if $c != "-" then {contract:$c} else {} end) + (if $r != "" then {remainder:$r} else {} end)' >> "$LOG"
}
labels() { printf '%s\n' "$1" > "$FX/labels"; }
edits()  { grep -c '^edit ' "$STUB_LOG" || true; }
lastedit() { grep '^edit ' "$STUB_LOG" | tail -n 1; }
prows()  { [ -e "$LOG" ] && { jq -c 'select(.event == "phase-label")' "$LOG" | grep -c . || true; } || echo 0; }
plast()  { jq -r 'select(.event == "phase-label") | [.result, (.from // "-"), (.to // "-"), (.cause // "-"), (.stage // "-")] | join("|")' "$LOG" | tail -n 1; }
nlog()   { [ -e "$LOG" ] && wc -l < "$LOG" || echo 0; }
seq_of() { jq -r '[.event + ":" + .result + (if .stage then ":" + .stage else "" end)] | .[]' "$LOG" | paste -sd, -; }
brief_live() { # <labels> <kind> [Jira status] - a LIVE bullet with a brief of <kind>
    reset "${3:-In Progress}"; owned; mkbrief "$DOC" "$2" LIVE; labels "$1"
    fn "$K" --event live --doc "$DOC"
}

if [ -n "$_TIMEOUT_BIN" ]; then
    # a. a design leg sets design
    brief_live '[]' design
    check "phase a: a design LIVE on an unlabelled ticket makes one edit" "$(lastedit)" "edit $K --phase design"
    check "phase a: and logs phase-set from empty to design, cause design-leg" "$(plast)" "phase-set||design|design-leg|-"
    # b. a design leg never moves a phase backwards
    for l in sliced build ready; do
        brief_live "[\"phase:$l\"]" design
        check "phase b: a design LIVE on phase:$l makes no edit" "$(edits)" 0
    done
    # c. a build leg
    brief_live '[]' build
    check "phase c: a build LIVE on an unlabelled ticket sets build" "$(lastedit)" "edit $K --phase build"
    brief_live '["phase:design"]' build
    check "phase c: a build LIVE on phase:design sets build" "$(lastedit)" "edit $K --phase build"
    brief_live '["phase:last-step"]' build
    check "phase c: a build LIVE on phase:last-step makes no edit" "$(edits)" 0
    brief_live '["phase:waiting"]' build
    check "phase c: a build LIVE on the retired phase:waiting sets build" "$(lastedit)" "edit $K --phase build"
    # d. a partial merge
    d_case() { # <pr> <contract|-> <remainder> <expected edit or none> [pr of the funnel event]
        reset "In Progress"; owned; labels '[]'; mergerow "$1" "$2" "$3"
        fn "$K" --event merge --pr "${5:-7}"
        check "phase d: merge row pr=$1 contract=$2 remainder=${3:-}" "$(lastedit | grep . || echo none)" "$4"
    }
    d_case 7 no owed "edit $K --phase last-step"
    d_case 7 no handed-off "edit $K --phase last-step"
    d_case 7 no remaining "edit $K --phase sliced"
    d_case 7 no none "edit $K --phase sliced"
    d_case 7 no "" "edit $K --phase sliced"
    d_case 8 no owed none
    d_case 7 - owed none
    d_case 7 yes owed none
    reset "In Progress"; owned WRAPPED 0; labels '[]'; mergerow 7 no owed
    fn "$K" --event merge --pr 7
    check "phase d: a contract=no row beats the D5c derive on the same event (merge-partial, last-step)" "$(plast)" "phase-set||last-step|merge-partial|-"
    # e. the chief's form
    reset "In Progress"; owned; labels '["phase:design"]'
    fn "$K" --event phase-label --phase ready
    check "phase e: --event phase-label --phase ready edits once" "$(lastedit)" "edit $K --phase ready"
    check "phase e: and writes exactly one row, the phase row" "$(nlog)/$(prows)" 1/1
    # f. a Done ticket loses its label
    reset "Done"; owned WRAPPED; labels '["phase:sliced"]'; echo "done" > "$FX/category"
    fn "$K" --event sweep
    check "phase f: a Done ticket's phase label is cleared" "$(lastedit)" "edit $K --phase none"
    # g. D5c holding build
    reset "In Progress"; owned WRAPPED 0; labels '["phase:build"]'; mergerow 11 no
    fn "$K" --event wrapped --doc "$DOC"
    check "phase g: a D5c derive moves phase:build to sliced" "$(lastedit)" "edit $K --phase sliced"
    # h. two labels
    brief_live '["phase:design","phase:sliced"]' build
    check "phase h: furthest wins and one label is left" "$(lastedit)|$(cat "$FX/labels")" "edit $K --phase sliced|[\"phase:sliced\"]"
    # i, j. no anchor
    reset "In Progress"; owned; labels '[]'
    fn "$K" --event ci
    check "phase i: an event with no anchor makes no edit and no phase row" "$(edits)/$(prows)" 0/0
    check "phase i: and reads Jira only for the derive" "$(grep -c '^get' "$STUB_LOG")" 1
    brief_live '[]' spec
    check "phase j: a spec brief is no anchor" "$(edits)/$(prows)" 0/0
    # self-rows (S1, P4)
    reset "In Progress"; owned; mkbrief "$DOC" design LIVE; labels '[]'
    fn "$K" --event live --doc "$DOC"
    fn "$K" --event live --doc "$DOC"
    printf '{"ts":"t","event":"live","key":"%s","result":"miss","stage":"timeout"}\n' "$K" >> "$LOG"
    fn "$K" --event sweep
    check "phase self-row: the label stays design" "$(cat "$FX/labels")" '["phase:design"]'
    check "phase self-row: one edit call in all" "$(edits)" 1
    # I7, S2: the chief's form moves no status and writes no record
    reset "To Do"; owned WRAPPED 0; labels '[]'; mergerow 11 no
    before=$(cksum < "$REC")
    fn "$K" --event phase-label --phase sliced
    check "phase I7: no transition" "$(ntrans)" 0
    check "phase I7: the edit is made" "$(lastedit)" "edit $K --phase sliced"
    check "phase I7: no row but the phase row (one merge row was there)" "$(nlog)/$(prows)" 2/1
    check "phase I7: the record is unchanged byte for byte" "$(cksum < "$REC")" "$before"
    # usage refusals: exit 2, no row
    reset "In Progress"; owned
    for argv in "--event phase-label" "--event live --phase design" "--event phase-label --after live" "--event live --after live --rule D3" "--event phase-label --phase design --after live --rule D5c" "--event phase-label --phase"; do
        rc=0
        # shellcheck disable=SC2086  # the argv string is split on purpose
        bash "$SUT" "$K" $argv >"$tmp/out" 2>&1 || rc=$?
        check "phase usage: '$argv' exits 2 with no row" "$rc/$(nlog)" 2/0
    done
    rc=0; touch "$FX/edit.exit2"; bash "$SUT" "$K" --event phase-label --phase bogus >"$tmp/out" 2>&1 || rc=$?
    check "phase usage: a refused --phase value is one phase-miss stage=edit row, exit 0" "$rc/$(prows)/$(plast)" "0/1/phase-miss|-|bogus|-|edit"
    # I5 a. a failed edit never fails the funnel
    reset "To Do"; owned; mkbrief "$DOC" design LIVE; labels '[]'; touch "$FX/edit.fail"
    rc=0; bash "$SUT" "$K" --event live --doc "$DOC" >"$tmp/out" 2>&1 || rc=$?
    check "phase I5a: exit 0" "$rc" 0
    check "phase I5a: the move still happens" "$(moved)" "transition $K In Progress"
    check "phase I5a: moved row, then one phase-miss stage=edit row" "$(seq_of)" "live:moved,phase-label:phase-miss:edit"
    contains "phase I5a: and a WARN is printed" "$(cat "$tmp/out")" "WARN"
    # I5 c. the phase step's own read fails
    brief_live '[]' design
    T=$(cat "$FX/get.n")
    reset "In Progress"; owned; mkbrief "$DOC" design LIVE; echo "$T" > "$FX/get.fail.from"
    rc=0; bash "$SUT" "$K" --event live --doc "$DOC" >"$tmp/out" 2>&1 || rc=$?
    check "phase I5c: a failed phase read is one phase-miss stage=get row, exit 0" "$rc/$(prows)/$(plast)" "0/1/phase-miss|-|-|-|get"
    # I5 e. too little budget left
    reset "To Do"; owned; mkbrief "$DOC" design LIVE; labels '[]'
    TICKET_STATUS_PHASE_MIN=100 fn "$K" --event live --doc "$DOC"
    check "phase I5e: moved row, then one phase-miss stage=budget row" "$(seq_of)" "live:moved,phase-label:phase-miss:budget"
    check "phase I5e: and no edit" "$(edits)" 0
    # I5 g. no wrapper: the step runs in-process after the INTAKE request
    VERS=$(printf 'v1.1.3\tfalse\t2026-10-28\tfalse\nv1.1.4\tfalse\t2026-11-04\tfalse\nv1.1.2\ttrue\t2026-10-20\tfalse\n')
    reset "To Do"; owned; mkbrief "$DOC" design LIVE; labels '[]'; vset '[{"name":"v1.1.4"}]'
    TICKET_STATUS_IN_BUDGET=1 fn "$K" --event live --doc "$DOC"
    check "phase I5g: with no wrapper the rows are moved, intake, phase-set" "$(seq_of)" "live:moved,live:intake,phase-label:phase-set"
    if command -v flock >/dev/null 2>&1; then
        # I5 b. the phase edit is cut off after a move and an INTAKE request
        reset "To Do"; owned; mkbrief "$DOC" design LIVE; labels '[]'; vset '[{"name":"v1.1.4"}]'; echo 20 > "$FX/edit.sleep"
        rc=0; TICKET_STATUS_BUDGET=8 bash "$SUT" "$K" --event live --doc "$DOC" >"$tmp/out" 2>&1 || rc=$?
        check "phase I5b: exit 0" "$rc" 0
        check "phase I5b: moved, intake, then one phase-miss stage=timeout, and no miss row" "$(seq_of)" "live:moved,live:intake,phase-label:phase-miss:timeout"
        check "phase I5b: the INTAKE request came before the edit" "$(grep -nE '^(release request|edit )' "$STUB_LOG" | sed -E 's/^[0-9]+://' | cut -d' ' -f1-2 | paste -sd, -)" "release request,edit $K"
        missed=$(jq -rs --arg k "$K" '[.[] | select(.key == $k)] as $g | ([range(0; ($g|length))] | map(select($g[.].result == "miss")) | last) as $m | select($m != null) | $g[$m].event' "$LOG")
        check "phase I5b: the MISSED query names nothing for the key" "$missed" ""
        # I5 d. the status child cut off: no phase row, no edit
        reset "To Do"; owned; mkbrief "$DOC" design LIVE; labels '[]'; echo 30 > "$FX/get.sleep"
        TICKET_STATUS_BUDGET=1 "$_TIMEOUT_BIN" -k 2 15 bash "$SUT" "$K" --event live --doc "$DOC" >"$tmp/out" 2>&1
        check "phase I5d: a cut-off status child is one live miss stage=timeout row" "$(seq_of)" "live:miss:timeout"
        check "phase I5d: and no edit" "$(edits)" 0
        # I5 f. the phase child cannot take the lock
        reset "To Do"; owned; mkbrief "$DOC" design LIVE; labels '[]'; touch "$FX/hold.lock"
        TICKET_STATUS_LOCK_WAIT=1 fn "$K" --event live --doc "$DOC"
        check "phase I5f: a held lock is one phase-miss stage=lock row and no deferred row" "$(seq_of)" "live:moved,phase-label:phase-miss:lock"
        flock -w 10 "$TICKET_STATUS_STATE_DIR/status-locks/$K" true
    else
        echo "skip - phase I5 b, d, f: no flock binary"
    fi
    # P6. the sweep still counts a move that also wrote a phase
    reset "To Do"; owned WRAPPED 0; labels '[]'; mergerow 11 no
    printf '%s\n' "$K" > "$FX/list.key"
    printf '%s\n' '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' > "$FX/graphql-all.json"
    bash "$HERE/status-sweep.sh" --repo octo/repo > "$tmp/out" 2>&1
    check "phase P6: the sweep run wrote the phase" "$(cat "$FX/labels")" '["phase:sliced"]'
    contains "phase P6: and still counts moved=1" "$(cat "$tmp/out")" "moved=1"
    contains "phase P6: and miss=0" "$(cat "$tmp/out")" "miss=0"
else
    echo "skip - phase step rows: no timeout binary"
fi

# I3 fence: only the funnel calls the Jira CLI's edit --phase
root=$(git -C "$HERE" rev-parse --show-toplevel)
FENCE='(jira|index\.js)[}"]?[[:space:]]+edit[[:space:]]+[^[:space:]-][^[:space:]]*[[:space:]]+.*--phase'
hits=$(git -C "$root" grep -nE "$FENCE" -- scripts marketplace ':!scripts/jira' ':!*test*' ':!*.md')
check "fence: the one call site is worker-jira-status.sh" "$(printf '%s\n' "$hits" | cut -d: -f1 | sort -u)" "scripts/handover/chief-kit/worker-jira-status.sh"
check "fence: on one line" "$(printf '%s\n' "$hits" | grep -c .)" 1
# shellcheck disable=SC2016  # the control lines are literal source text
printf '%s\n' 'ts_jira edit "$KEY" --phase "$next"' 'node scripts/jira/dist/index.js edit K --phase none' '$wv_jira edit "$k" --phase build' \
    'usage-read.sh --phase-cost x' 'ts_jira edit "$KEY" "$FLAG" held' 'run.sh --phase pilot' > "$tmp/fence-control"
check "fence: the pattern matches the three Jira calls and not the three look-alikes" "$(grep -cE "$FENCE" "$tmp/fence-control")" 3
# parity: every phase the funnel's table writes is in PHASES
phases=$(node --input-type=module -e "import('$root/marketplace/plugins/himmel-ops/scripts/ticket-policy.mjs').then(m => console.log(m.PHASES.join(' ')))" 2>/dev/null)
targets=$(sed -n '/^phase_next()/,/^}/p' "$SUT" | grep -oE 'PH_NEXT=[a-z][a-z-]*' | cut -d= -f2 | sort -u | grep -vx none)
check "parity: phase_next names at least one target" "$([ -n "$targets" ] && echo yes || echo no)" yes
missing=""
for t in $targets; do case " $phases " in *" $t "*) ;; *) missing="$missing $t" ;; esac; done
check "parity: every target phase_next writes is in PHASES" "${missing# }" ""

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
