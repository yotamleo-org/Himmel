#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check(), as in test-append-results.sh
# scripts/handover/console-kit/test-leg-jira-status.sh - Hermetic
# tests for the derive-and-set funnel (leg-jira-status.sh, scripts/lib/ticket-status.sh)
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
# Platform guard: POSIX bash 3.2+, no .ps1 twin by design (shell-only harness).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/leg-jira-status.sh"
APPEND="$HERE/append-results.sh"
LIB="$HERE/../../lib/ticket-status.sh"
# shellcheck source=../../lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/timeout-bin.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/leg-jira-status-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
unset GH_REPO
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
        if [ -e "$FX/type" ] && [ ! -s "$FX/type" ]; then
            printf '{"fields":{"status":{"name":"%s"},"labels":[]}}\n' "$(cat "$FX/status.cur")"
        else
            printf '{"fields":{"status":{"name":"%s"},"issuetype":{"name":"%s"},"labels":[]}}\n' \
                "$(cat "$FX/status.cur")" "$(cat "$FX/type" 2>/dev/null || echo Task)"
        fi ;;
    list)
        printf '%s\tTask\t%s\ttitle\n' "$(cat "$FX/list.key" 2>/dev/null)" "$(cat "$FX/status.cur")" ;;
    transition)
        [ -e "$FX/transition.fail" ] && { echo "boom" >&2; exit 1; }
        if [ -e "$FX/workflow" ] && [ -z "$(cut -f2 "$FX/workflow" | grep -xF "$3")" ]; then
            echo "no transition to $3" >&2; exit 1
        fi
        [ -e "$FX/transition.noop" ] || printf '%s\n' "$3" > "$FX/status.cur"
        exit 0 ;;
esac
EOS
cat >"$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB_LOG"
printf '%s\n' "${GH_REPO:-}" >> "$FX/gh-repo.log"
case "$1 $2" in
    "pr list")
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
mkdoc() { # <path> [marker] - a leg doc whose newest marker is <marker>
    printf '# leg\n\n## Results (newest at the bottom)\n' > "$1"
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
row()    { tail -n 1 "$LOG" 2>/dev/null | jq -r ".$1 // \"\""; }

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

# --- D5 / D6 / D7 ------------------------------------------------------------------
reset "To Do"; owned LIVE 11 0
fn "$K" --event live --doc "$DOC"
check "D5: a live owner, no PR -> In Progress" "$(moved)" "transition $K In Progress"
reset "In Review"; owned WRAPPED 0
fn "$K" --event wrapped --doc "$DOC"
check "D6: WRAPPED, no PR and no merge row -> To Do" "$(moved)" "transition $K To Do"
check "D6: rule" "$(row rule)" D6
check "D6: direction" "$(row dir)" back
DOC2="$tmp/$K-N2-slug-2026-10-21.md"
reset "In Progress"; owned LIVE 11 0
fn "$K" --event live --doc "$DOC"
mkdoc "$DOC2" WRAPPED; echo 0 > "$FX/lock.rc.${DOC2##*/}"
fn "$K" --event wrapped --doc "$DOC2"
check "no D6: the wrapped event was derived" "$(row event)" wrapped
check "no D6: the record holds both legs" "$(jq -r '.docs | join(" ")' "$REC")" "$DOC $DOC2"
check "no D6: one leg wraps with no PR while another holds a live lock" "$(ntrans)" 0
check "no D6: the live leg keeps rule D5" "$(row rule)" D5
check "no D6: the record follows the live leg" "$(jq -r '.doc + " " + .leg + " " + .state' "$REC")" "$DOC N1 live"
reset "In Progress"; owned LIVE 11 0
fn "$K" --event live --doc "$DOC"
mkdoc "$DOC" WRAPPED; echo 0 > "$FX/lock.rc"
mkdoc "$DOC2" WRAPPED
fn "$K" --event wrapped --doc "$DOC2"
check "D6: every recorded leg ended -> one move" "$(ntrans)" 1
check "D6: every recorded leg ended -> To Do" "$(moved)" "transition $K To Do"
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
HIMMEL_RELEASE_MANAGER=0 bash "$APPEND" "$DOC" "LIVE — leg" >/dev/null 2>&1
check "RM: HIMMEL_RELEASE_MANAGER=0 is a leg, it moves" "$(moved)" "transition $K In Progress"

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

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
