#!/usr/bin/env bash
# scripts/t3/thread-list.sh - read-only inventory of the T3 Code threads and the processes they own, as one JSON object.
#
# Usage: thread-list.sh
# Prints {"threads":[...],"owned":[...]} (jq -c, one line):
#   threads[]: threadId, title, state (running | waiting | blocked | settled), waitingOn (thread | reply | null),
#              provider, model, createdAt, updatedAt, pullRequests, backgroundTasks, pids (the owned pids of that thread)
#   owned[]:   pid, thread (the thread id, or null when no thread's worktree matches the process's cwd)
# State: settled; else blockedOnThreadWait = waiting on a thread; else a run status of error/failed/blocked = blocked,
# running/starting/active = running, anything else (idle, completed, interrupted, cancelled) = waiting on a reply.
# Owned processes: the pids the T3 server registered as its providers (<userdata>/provider-processes/*.json whose owner is
# alive) and every descendant of them. A process is matched to a thread when its cwd is the thread's worktreePath
# (`t3 thread show`, read only for an unsettled thread); a thread sharing the project checkout cannot be told apart, so
# its processes stay owned with thread null.
# Never settles, sends to or starts a thread: it only runs `thread list` and `thread show`.
# rc 0 printed; rc 2 the thread list could not be read (the CLI is missing or failed, or it printed no JSON array).
# Env seams: T3_SEND_BIN, T3_SEND_PROJECT (as t3-send.sh), T3_USERDATA (default $HOME/.t3/userdata), T3_PROC (default /proc).
# Platform: bash 3.2+, jq; the process half reads /proc (Linux) and is empty elsewhere.
set -u
BIN="${T3_SEND_BIN:-$HOME/.t3/bin/t3}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT="${T3_SEND_PROJECT:-$(cd "$HERE/../.." && pwd -P)}"
USERDATA="${T3_USERDATA:-$HOME/.t3/userdata}"
PROC="${T3_PROC:-/proc}"
die() { echo "thread-list: $2" >&2; exit "$1"; }

command -v jq >/dev/null 2>&1 || die 2 "jq is required"
LIST="$("$BIN" thread list --json --project "$PROJECT" 2>&1)" || die 2 "thread list failed: $LIST"
printf '%s' "$LIST" | jq -e 'type == "array"' >/dev/null 2>&1 || die 2 "thread list did not print a JSON array"

ROOTS=""
for f in "$USERDATA"/provider-processes/*.json; do
    [ -f "$f" ] || continue
    owner="$(jq -r '.owner.pid // empty' "$f" 2>/dev/null)"
    case "$owner" in ""|*[!0-9]*) continue ;; esac
    [ -d "$PROC/$owner" ] || continue
    ROOTS="$ROOTS $(jq -r '.processes[]?.pid // empty' "$f" 2>/dev/null | tr '\n' ' ')"
done
PAIRS=""
for d in "$PROC"/[0-9]*; do
    [ -r "$d/stat" ] || continue
    line="$(cat "$d/stat" 2>/dev/null)" || continue
    rest="${line##*) }"
    read -r _ ppid _ <<< "$rest"
    PAIRS="$PAIRS ${d##*/}:${ppid:-}"
done
OWNED=" "
for r in $ROOTS; do
    case "$r" in ""|*[!0-9]*) continue ;; esac
    [ -d "$PROC/$r" ] && OWNED="$OWNED$r "
done
grew=1
while [ "$grew" = 1 ]; do
    grew=0
    for p in $PAIRS; do
        pid="${p%%:*}"; ppid="${p##*:}"
        case "$OWNED" in *" $pid "*) continue ;; esac
        case "$OWNED" in *" $ppid "*) OWNED="$OWNED$pid "; grew=1 ;; esac
    done
done

WT=""
for id in $(printf '%s' "$LIST" | jq -r '.[] | select(.settled != true) | .threadId'); do
    p="$("$BIN" thread show "$id" --json 2>/dev/null | jq -r '.thread.worktreePath // empty' 2>/dev/null)"
    [ -n "$p" ] && WT="$WT$id	$p
"
done

OWNJ="[]"
for pid in $OWNED; do
    cwd="$(readlink "$PROC/$pid/cwd" 2>/dev/null || true)"
    tid=""
    if [ -n "$cwd" ]; then
        while IFS="$(printf '\t')" read -r id path; do
            [ -n "$id" ] && [ "$path" = "$cwd" ] && { tid="$id"; break; }
        done <<EOF
$WT
EOF
    fi
    OWNJ="$(printf '%s' "$OWNJ" | jq -c --argjson p "$pid" --arg t "$tid" '. + [{pid: $p, thread: (if $t == "" then null else $t end)}]')"
done

printf '%s' "$LIST" | jq -c --argjson owned "$OWNJ" '
    {threads: [.[] | . as $t
        | (if .settled == true then "settled"
           elif .blockedOnThreadWait == true then "waiting"
           elif ((.status // "") | test("^(error|failed|blocked)$")) then "blocked"
           elif ((.status // "") | test("^(running|starting|active)$")) then "running"
           else "waiting" end) as $state
        | {threadId, title: (.title // ""), state: $state,
           waitingOn: (if $state != "waiting" then null elif .blockedOnThreadWait == true then "thread" else "reply" end),
           provider: (.providerInstanceId // null), model: (.model // null),
           createdAt: (.createdAt // null), updatedAt: (.updatedAt // null),
           pullRequests: (.openPullRequestCount // 0), backgroundTasks: ((.pendingBackgroundTasks // []) | length),
           pids: [$owned[] | select(.thread == $t.threadId) | .pid]}],
     owned: $owned}'
