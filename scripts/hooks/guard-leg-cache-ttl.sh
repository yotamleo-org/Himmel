#!/usr/bin/env bash
# guard-leg-cache-ttl.sh — Stop hook, wired by headed-arm-leg.sh into the
# native leg profile's settings: refuses, once per stop, the stop of a
# console-spawned leg that still holds its queue lock while nothing is armed to
# wake it before the 1 h prompt-cache TTL.
#
# WHY: a leg that ends its turn with no wait armed sleeps until something else
# wakes it, usually the next console succession relay about an hour later.
# Past the TTL that wake re-pays the whole prefix as a cold write: 17 such
# wakes in 7 legs, 1.85 M tokens written over 24 h on 2026-10-19, each about
# 20x the warm turn it replaced. The refusal tells the leg to arm a bounded
# background wait (it then wakes warm) or to wrap with a resume brief when the
# wait is open-ended. The cost rule behind the choice:
# docs/internals/prompt-cache.md "Leg keepalive or wrap".
#
# Blocks only when ALL hold, otherwise allows with no output:
#   1. HIMMEL_CONSOLE_LEG=1 (exported by headed-arm-leg.sh).
#   2. stop_hook_active is not true (the loop guard: one refusal per stop).
#   3. This session holds a non-console queue lock: the persisted token file
#      queue-lock.sh writes per acquire, keyed on
#      sha256("<session_id>|<handover doc>"), exists for a held lock — the
#      same signal stop-console-idle-guard.sh reads. A wrapped leg released
#      its lock, so it is allowed.
#   4. The transcript shows no background task still running: every
#      background Bash (toolUseResult.backgroundTaskId) and Monitor
#      (toolUseResult.taskId) started has a terminal <task-notification>
#      (one carrying a <status>) or a TaskStop result (toolUseResult.task_id).
#
# The keepalive bound is HIMMEL_LEG_CACHE_KEEPALIVE_SECS (launch env, default
# 3000 = 50 min, 60-3300 accepted, anything else = the default); the refusal
# names it so the wait the leg arms returns before the TTL.
#
# ponytail: the hook sees that a background task is running, not when it will
# return, so an armed but unbounded wait still passes (N2741's watch on
# origin/main ran past the TTL); upgrade path: read the armed command's
# timeout/--max-wait from the transcript if unbounded waits show up in
# cache-probe.sh idle-gap after this ships.
# ponytail: a leg that stops a second time in a row passes the loop guard;
# upgrade path: a per-session refusal counter if legs are seen doing that.
#
# Workflow nudge (scripts/hooks/CLAUDE.md "Fail-open vs fail-closed"): fails
# OPEN on every gap — no jq, no sha256 tool, junk payload, no transcript, no
# handover root or lock dir. Bypass: unset HIMMEL_CONSOLE_LEG in the launching
# shell. bash 3.2-safe.
set -u

[ "${HIMMEL_CONSOLE_LEG:-0}" = "1" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

payload=""
IFS= read -r -t 5 -d '' payload
[ -n "$payload" ] || exit 0

fields="$(printf '%s' "$payload" | jq -r '[(.stop_hook_active == true | tostring), (.session_id // ""), (.transcript_path // "")] | @tsv' 2>/dev/null)" || exit 0  # swallow-ok: junk payload fails open (allow)
IFS='	' read -r stop_active session_id transcript <<EOF
$fields
EOF
[ "$stop_active" = "false" ] || exit 0
[ -n "$session_id" ] || exit 0
[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0

# shellcheck disable=SC1091
if . "$HERE/../lib/load-dotenv.sh" 2>/dev/null; then load_dotenv HANDOVER_DIR 2>/dev/null || true; fi
# shellcheck source=../lib/handover-path.sh
. "$HERE/../lib/handover-path.sh" 2>/dev/null || exit 0
root="$(handover_root 2>/dev/null)" || exit 0  # swallow-ok: no handover root fails open (allow)
[ -n "$root" ] && [ -d "$root/.locks/queue" ] || exit 0

digest_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
    fi
}

token_dir="${XDG_RUNTIME_DIR:-/tmp}/himmel-queue-lock"
leg_doc=""
for lockdir in "$root"/.locks/queue/*.lock; do
    case "$lockdir" in *-console.lock) continue ;; esac
    [ -f "$lockdir/owner.json" ] || continue
    doc="$(jq -r '.handover // empty' "$lockdir/owner.json" 2>/dev/null)" || continue  # swallow-ok: an unreadable lock is not ours
    [ -n "$doc" ] || continue
    # queue-lock.sh's _ql_token_digest hashes the slash-normalized path.
    doc="${doc//\\//}"
    digest="$(digest_of "$session_id|$doc")"
    [ -n "$digest" ] || exit 0
    for tokfile in "$token_dir/$digest".*; do
        [ -f "$tokfile" ] && leg_doc="$doc"
    done
    [ -z "$leg_doc" ] || break
done
[ -n "$leg_doc" ] || exit 0

# Running = started and never ended. A malformed transcript line is skipped
# (fromjson?), so one bad row cannot hide the rest.
running="$(jq -R -r '
    fromjson? // empty
    | ( (.toolUseResult? | objects | (.backgroundTaskId // .taskId) | strings | "S " + .),
        (.toolUseResult? | objects | .task_id | strings | "E " + .),
        ( ( if .type == "user" then (.message.content | strings)
            elif .type == "queue-operation" then (.content | strings)
            elif .type == "attachment" then (.attachment.prompt? | strings)
            else empty end )
          | split("<task-notification>")[1:][]
          | select(contains("<status>"))
          | capture("<task-id>(?<id>[^<]+)</task-id>").id
          | "E " + . ) )
' "$transcript" 2>/dev/null | awk '
    $1 == "S" { s[$2] = 1 }
    $1 == "E" { e[$2] = 1 }
    END { n = 0; for (k in s) if (!(k in e)) n++; print n }
')" || exit 0
case "$running" in ''|*[!0-9]*) exit 0 ;; esac
[ "$running" -eq 0 ] || exit 0

bound="${HIMMEL_LEG_CACHE_KEEPALIVE_SECS:-3000}"
case "$bound" in ''|*[!0-9]*) bound=3000 ;; esac
if [ "${#bound}" -gt 5 ] || [ "$bound" -lt 60 ] || [ "$bound" -gt 3300 ]; then bound=3000; fi

reason="Leg cache guard (HIMMEL-6527): you hold the queue lock on ${leg_doc##*/} and no background task or Monitor is running, so nothing wakes you before the 1 h prompt-cache TTL. A wake past it re-pays the whole prefix as a cold write, about 20x a warm turn. Before ending the turn do ONE of: (a) a wait that returns within ${bound}s, armed with Bash run_in_background — \`bash scripts/check-ci.sh <pr> --max-wait ${bound}\` for CI, \`timeout ${bound} bash -c 'until <condition>; do sleep 60; done'\` for a condition, or \`sleep ${bound}\` while holding for GO or a console ruling (a SendMessage still wakes you sooner); re-arm it on each wake; or (b) when the wait is open-ended (the operator, another PR, a hold with no end in sight), WRAP with a resume brief so the console relaunches you when it clears. Rule: docs/handover/leg-sections/cache-keepalive.md."

_hp_json_escape "$reason"
printf '{"decision":"block","reason":"%s"}\n' "$_HP_ESC"
exit 0
