#!/usr/bin/env bash
# scripts/t3/thread-list.sh - read-only inventory of the T3 Code threads and the processes they own, as one JSON object.
#
# Usage: thread-list.sh
# Prints {"threads":[...],"owned":[...]} (jq -c, one line):
#   threads[]: threadId, title, state (running | waiting | blocked | settled), waitingOn (thread | reply | null),
#              provider, model, createdAt, updatedAt, pullRequests, backgroundTasks, pids (the owned pids of that thread)
#   owned[]:   pid, thread (the thread id, or null when no thread, or several threads, have the process's cwd as their worktree)
# State: settled; else blockedOnThreadWait = waiting on a thread; else a run status of error/failed/blocked = blocked,
# running/starting/active = running, anything else (idle, completed, interrupted, cancelled) = waiting on a reply.
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

BOOT="$(cat "$PROC/sys/kernel/random/boot_id" 2>/dev/null || true)"
same_process() {
    local line rest st
    line="$(cat "$PROC/$1/stat" 2>/dev/null)" || return 1
    rest="${line##*) }"
    read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ st _ <<< "$rest"
    [ -n "$BOOT" ] && [ "$2" = "$BOOT:${st:-}" ]
}
ROOTS=""
for f in "$USERDATA"/provider-processes/*.json; do
    [ -f "$f" ] || continue
    owner="$(jq -r '"\(.owner.pid // "") \(.owner.startTime // "")"' "$f" 2>/dev/null)"
    case "${owner%% *}" in ""|*[!0-9]*) continue ;; esac
    same_process "${owner%% *}" "${owner#* }" || continue
    ROOTS="$ROOTS $(jq -r '.processes[]? | select(.pid != null and .startTime != null) | "\(.pid):\(.startTime)"' "$f" 2>/dev/null | tr '\n' ' ')"
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
    case "${r%%:*}" in ""|*[!0-9]*) continue ;; esac
    same_process "${r%%:*}" "${r#*:}" && OWNED="$OWNED${r%%:*} "
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
    tid=""; hits=0
    if [ -n "$cwd" ]; then
        while IFS="$(printf '\t')" read -r id path; do
            [ -n "$id" ] && [ "$path" = "$cwd" ] && { tid="$id"; hits=$((hits+1)); }
        done <<EOF
$WT
EOF
    fi
    [ "$hits" -eq 1 ] || tid=""
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
