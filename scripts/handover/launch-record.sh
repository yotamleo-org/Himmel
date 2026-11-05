#!/usr/bin/env bash
# launch-record.sh <name> <profile> <lane> <role> [session_id] [model]
#
# The launch record for a session whose launcher is not headed-arm-worker.sh. Appends the
# one line scripts/eval/worker-digest/worker_ledger.py (_launch_lines) reads to
# ${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}/launch-logs/<name>.log, in headed-arm-worker.sh's own format:
#   headed-arm-worker: profile= lane= model= role= session= [session_id=] launched=
# The lane is what the launcher knows at launch (native|claudex|codex|openrouter|cloud); the digest and the
# rollup never infer one. A headless run has no session title, so pass the session id the launcher gives claude
# as --session-id: the reader finds the line by it.
#
# Best-effort: a record that cannot be written is said on stderr and the exit is still 0, so the launch goes on
# (the session then reads as unknown, never a guess). A bad argument exits 2 and writes nothing.
# ponytail: with no HIMMELCTL_CACHE_DIR and no HOME nothing is written (same as headed-arm-worker.sh).
set -u

if [ "$#" -lt 4 ] || [ "$#" -gt 6 ]; then
    echo "launch-record: usage: launch-record.sh <name> <profile> <lane> <role> [session_id] [model]" >&2
    exit 2
fi
name="$1" profile="$2" lane="$3" role="$4" sid="${5:-}" model="${6:-default}"

bad=""
[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$ ]] || bad="name"
[[ "$profile" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || bad="profile"
case "$lane" in native|claudex|codex|openrouter|cloud) ;; *) bad="lane" ;; esac
[[ "$role" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || bad="role"
[[ -z "$sid" || "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || bad="session_id"
[[ "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{0,100}$ ]] || bad="model"
if [ -n "$bad" ]; then
    echo "launch-record: refused, $bad is not a valid value" >&2
    exit 2
fi

cache="${HIMMELCTL_CACHE_DIR:-}"
[ -z "$cache" ] && [ -n "${HOME:-}" ] && cache="$HOME/.claude/himmel"
if [ -z "$cache" ]; then
    echo "launch-record: WARN no cache dir, launch record for $name NOT written (this session will read as unknown)" >&2
    exit 0
fi
sid_part=""
[ -z "$sid" ] || sid_part=" session_id=$sid"
if ! ( umask 077 && mkdir -p "$cache/launch-logs" && \
    printf 'headed-arm-worker: profile=%s lane=%s model=%s role=%s session=%s%s launched=%s\n' \
        "$profile" "$lane" "$model" "$role" "$name" "$sid_part" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >> "$cache/launch-logs/$name.log" ) 2>/dev/null; then
    echo "launch-record: WARN launch record for $name NOT written under $cache/launch-logs (this session will read as unknown)" >&2
fi
exit 0
