#!/usr/bin/env bash
# bypass-launchd.sh — launch a worker with an allowlisted HIMMEL_*_OK flag on the operator's Telegram go code.
# Route, threat model and why the classifier refuses the flag: docs/internals/bypass-launch-route.md.
#
#   bypass-launchd.sh --bucket <handover bucket> --until <YYYY-MM-DD>
#
# The operator starts it once from their own shell, never from a Claude session (it refuses CLAUDECODE):
#   setsid nohup bash <repo>/scripts/station-ops/bypass-launchd.sh --bucket <bucket> --until <date> >/dev/null 2>&1 &
# It stops at --until 00:00Z (at most 7 days ahead) or when <bucket>/bypass-queue/stop exists.
#
# A chief requests a launch by writing <bucket>/bypass-queue/<anything>.req holding these lines:
#   brief=<absolute brief path directly in the bucket>   model=<allowlisted model id>   chief=<chief session name>
#   flags=<comma list from the allowlist below>   (optional; default HIMMEL_HOOK_INTEGRITY_BYPASS_OK)
#   effort=<low|medium|high|xhigh>                 (optional)
#   decision=<operator decision number>            (required when flags name HIMMEL_BILLED_OK)
# The daemon sends the operator a one-time code naming every flag, the decision and the brief's sha; only the
# reply "go <code>" from the operator's own chat (bridge inbound.jsonl, not forwarded) launches, "no <code>"
# denies, 6 h with no answer expires. A go launches only if the brief still has the sha the ask named. The
# launch strips every inherited flag and sets exactly the granted ones. The grant (go code, decision, sha,
# time) is appended to the request, which ends as .done, .failed, .no, .expired or .refused; daemon.log has
# a GRANT line per launch.
# The operator id is allowFrom[0] of the bridge access.json (TELEGRAM_ACCESS_PATH); the inbound journal is
# BRIDGE_ROOT/inbound.jsonl. Test seams: BYPASSD_SEND (a program given the message), BYPASSD_LAUNCHER (run in
# place of headed-arm-worker.sh with its arguments), BYPASSD_POLL, BYPASSD_SETTLE.
# Exit 0 stopped or expired; 1 already running; 2 refused to start.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
KIT="$REPO/scripts/handover/chief-kit"
LAUNCHER="${BYPASSD_LAUNCHER:-$KIT/headed-arm-worker.sh}"
INBOUND="${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}/inbound.jsonl"
ACCESS="${TELEGRAM_ACCESS_PATH:-$HOME/.claude/channels/telegram/access.json}"
POLL="${BYPASSD_POLL:-5}"
TTL=21600

die() { echo "bypass-launchd: $*" >&2; exit 2; }
[ -z "${CLAUDECODE:-}" ] || die "refusing to start from inside a Claude session; the operator starts it from their own shell"
BUCKET='' until=''
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "missing value for $1"
    case $1 in --bucket) BUCKET=$2 ;; --until) until=$2 ;; *) die "unknown argument $1" ;; esac
    shift 2
done
[ -n "$BUCKET" ] && [ -d "$BUCKET" ] && [ -d "$BUCKET/bypass-queue" ] || die "usage: bypass-launchd.sh --bucket <dir holding bypass-queue/> --until <YYYY-MM-DD>"
BUCKET="$(cd "$BUCKET" && pwd -P)"
Q="$BUCKET/bypass-queue"
[[ "$until" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--until wants YYYY-MM-DD"
EXPIRES="$(date -u -d "$until" +%s 2>/dev/null)" || die "--until $until is not a date"
now="$(date +%s)"
[ "$EXPIRES" -gt "$now" ] && [ "$EXPIRES" -le $((now + 7 * 86400)) ] || die "--until must be after now and at most 7 days ahead"
OP="$(jq -r '.allowFrom[0] // empty' "$ACCESS" 2>/dev/null)" # swallow-ok: an unreadable access.json leaves OP empty, refused below
[[ "$OP" =~ ^[1-9][0-9]*$ ]] || die "no operator id (allowFrom[0]) in $ACCESS"
LOG="$Q/daemon.log"
W="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/himmel-chief/gen-briefs"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }
send() {
    if [ -n "${BYPASSD_SEND:-}" ]; then "$BYPASSD_SEND" "$1" || log "send failed"; return 0; fi
    bun "$REPO/scripts/telegram/chief-route.ts" reply operator "$1" >/dev/null 2>&1 || log "send failed"
}
field() { sed -n "s/^$1=//p" "$2" | head -n 1; }
refuse() { log "REFUSED $2 $1"; mv "$1" "$1.refused"; send "bypass-launchd refused $(basename "$1"): $2"; }
live() { [ ! -e "$Q/stop" ] && [ "$(date +%s)" -lt "$EXPIRES" ]; }

exec 9>"$Q/.lock"
flock -n 9 || { echo "bypass-launchd: already running"; exit 1; } # prim-ok: the lock is held for the daemon's whole life on fd 9; Linux-only
log "start pid=$$ until=$until"

while :; do
    [ -e "$Q/stop" ] && { log "stop file"; exit 0; }
    [ "$(date +%s)" -ge "$EXPIRES" ] && { log "expired $until"; exit 0; }
    for req in "$Q"/*.req; do
        [ -e "$req" ] || continue
        brief=$(field brief "$req"); model=$(field model "$req"); chief=$(field chief "$req")
        flags=$(field flags "$req"); effort=$(field effort "$req"); decision=$(field decision "$req")
        [ -n "$flags" ] || flags=HIMMEL_HOOK_INTEGRITY_BYPASS_OK
        base=$(basename "$brief" .md)
        if ! [[ "$brief" == "$BUCKET/$base.md" && ! -L "$brief" && -f "$brief" ]] ||
           ! [[ "$base" =~ ^[A-Z][A-Z0-9]+-[0-9]+-N[0-9]+[a-z]?-[A-Za-z0-9.-]+$ ]] ||
           ! [[ "$model" =~ ^claude-(opus|sonnet|haiku)-5-5$ ]] || ! [[ "$chief" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{2,119}$ ]] ||
           ! [[ -z "$effort" || "$effort" =~ ^(low|medium|high|xhigh)$ ]]; then
            refuse "$req" malformed; continue
        fi
        envs=(); bad=""
        IFS=, read -ra fl <<<"$flags"
        for f in "${fl[@]}"; do
            case "$f" in HIMMEL_HOOK_INTEGRITY_BYPASS_OK|HIMMEL_BILLED_OK) envs+=("$f=1") ;; *) bad="flag $f not allowlisted"; break ;; esac
        done
        [ -n "$bad" ] && { refuse "$req" "$bad"; continue; }
        billed=""
        if [[ ",$flags," == *",HIMMEL_BILLED_OK,"* ]]; then
            [[ "$decision" =~ ^[0-9]+$ ]] || { refuse "$req" "HIMMEL_BILLED_OK needs decision=<operator decision number>"; continue; }
            billed=" PAID RUN (decision $decision)."
        fi
        [ -n "$effort" ] && envs+=("WORKER_SESSION_EFFORT=$effort")
        code=$(LC_ALL=C tr -dc 'A-Z2-9' </dev/urandom | head -c 6)
        off=$(stat -c %s "$INBOUND" 2>/dev/null || echo 0) # gnu-ok: a Linux-only station daemon (setsid, /run/user, the Telegram bridge)
        desc=$(sed -n 's/^description: *//p' "$brief" | head -n 1)
        sha=$(sha256sum "$brief" | cut -d" " -f1); [ ${#sha} -eq 64 ] || { refuse "$req" "brief unreadable"; continue; }
        mv "$req" "$req.pending"
        log "ASK $base model=$model chief=$chief flags=$flags effort=${effort:-default} decision=${decision:-none} sha=${sha:0:12}"
        send "Bypass worker launch asked by $chief: $base on $model, effort ${effort:-default}, grants ${envs[*]}.$billed What it does: $desc (brief sha ${sha:0:12}). Reply: go $code to launch, or no $code to refuse. Expires in 6 h."
        t0=$(date +%s); verdict=expired
        while [ $(( $(date +%s) - t0 )) -lt "$TTL" ] && live; do
            hit=$(tail -c +"$((off + 1))" "$INBOUND" 2>/dev/null | jq -r --argjson op "$OP" --arg c "$code" \
                'select(.from == $op and .chat_id == $op and .forwarded != true) | (.text // "") | ascii_downcase | gsub("^\\s+|\\s+$"; "") |
                 select(. == ("go " + ($c|ascii_downcase)) or . == ("no " + ($c|ascii_downcase)))' 2>/dev/null | tail -n 1)
            case "$hit" in go\ *) verdict=go; break ;; no\ *) verdict=no; break ;; esac
            sleep "$POLL"
        done
        if [ "$verdict" != go ]; then
            log "$verdict $base"; mv "$req.pending" "$req.$verdict"; send "bypass launch $base: $verdict, nothing ran."; continue
        fi
        if ! live || [ -L "$brief" ] || [ "$(sha256sum "$brief" 2>/dev/null | cut -d" " -f1)" != "$sha" ]; then
            log "REFUSED after go $base (stop, expiry, or brief changed since the ask)"; mv "$req.pending" "$req.refused"
            send "bypass launch $base: refused after your go, the brief changed or the daemon stopped. Nothing ran."; continue
        fi
        printf 'granted_at=%s\ngo=%s\nsha=%s\n' "$(date -u +%FT%TZ)" "$code" "$sha" >>"$req.pending"
        log "GRANT $base env=${envs[*]} decision=${decision:-none} go=$code"
        mkdir -p "$W"
        [ -f "$BUCKET/$chief.fleet.json" ] && bash "$KIT/fleet-manifest.sh" add "$BUCKET/$chief.fleet.json" "$brief" --lane native >>"$LOG" 2>&1
        env -u HIMMEL_HOOK_INTEGRITY_BYPASS_OK -u HIMMEL_BILLED_OK -u WORKER_SESSION_EFFORT -u CLAUDE_CODE_EFFORT_LEVEL \
            -u HEADED_ARM_LAUNCHER_ENV -u HEADED_ARM_LAUNCHER_ENV_LINES "${envs[@]}" setsid nohup bash "$LAUNCHER" \
            --profile worker-impl --chief "$chief" "$base" "$brief" "$W/sig-$base" "$EXPIRES" "$W/$base.log" "$model" \
            >"$W/$base.launch.out" 2>&1 9>&- &
        lp=$!; sleep "${BYPASSD_SETTLE:-12}"; touch "$W/sig-$base"
        if ! kill -0 "$lp" 2>/dev/null; then
            wait "$lp"; lrc=$?
            if [ "$lrc" -ne 0 ]; then
                log "LAUNCH-FAILED $base rc=$lrc"; mv "$req.pending" "$req.failed"
                send "bypass launch $base: FAILED (rc $lrc), see $W/$base.launch.out"; continue
            fi
        fi
        log "LAUNCHED $base"; mv "$req.pending" "$req.done"
        send "bypass launch $base: launched with ${envs[*]} (approved by your go code). Launch log $W/$base.launch.out"
    done
    sleep "$POLL"
done
