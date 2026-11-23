#!/usr/bin/env bash
# bypass-launchd.sh — launch a worker with the hook guard flags the operator approves, on the operator's Telegram go code.
# Route, threat model and why the classifier refuses the flag: docs/internals/bypass-launch-route.md.
#
#   bypass-launchd.sh --bucket <handover bucket> --until <YYYY-MM-DD>
#   bypass-launchd.sh --check --bucket <handover bucket> [--request <file>]
#
# The operator starts it once from their own shell, never from a Claude session (it refuses CLAUDECODE):
#   nohup bash <repo>/scripts/station-ops/bypass-launchd.sh --bucket <bucket> --until <date> >/dev/null 2>&1 &
# (on Linux, put setsid before nohup; on macOS a LaunchAgent starts it.)
# It stops at --until 00:00Z (at most 7 days ahead) or when <bucket>/bypass-queue/stop exists.
#
# A chief requests a launch by writing <bucket>/bypass-queue/<anything>.req holding these lines:
#   brief=<absolute brief path directly in the bucket>   model=<allowlisted model id>   chief=<chief session name>
#   flags=<comma list, at most 5, each in the flag registry>   (optional; default HIMMEL_HOOK_INTEGRITY_BYPASS_OK)
#   effort=<low|medium|high|xhigh>                 (optional)
#   decision=<operator decision number>            (required when a flag is decision tier, HIMMEL_BILLED_OK included)
#   api_account=<A, B, C, D or auto>               (optional, absent by default; launches with WORKER_SESSION_API_LANE=on and
#                                                   WORKER_SESSION_API_ACCOUNT=<name>, named in the ask and the GRANT log line)
#   blocks=<#n tokens, single spaces>              (optional; the pull requests the work blocks, named in the ask)
#   recommend=<go | no | no:<reason, at most 60 characters>>   (required; the chief's word, shown in the ask)
# Which flag a go code may grant: the registry scripts/himmelctl/lib/bypass-flags.json is the list of hook flags and
# scripts/station-ops/bypass-flag-tiers.tsv gives each a tier: grant, decision (needs decision=), floor (never granted;
# launch it from your own shell) or none (not a switch). Both are read once at start from HEAD of this checkout with the
# inherited git location variables unset; the daemon refuses to start (exit 2) when this script, the tier file or the
# registry has uncommitted changes, so a new flag needs a commit, an update and a restart. Every git call in it ignores
# refs/replace and a configured fsmonitor, so neither can change what is read or run.
# A launch clears every name the registry or the tier file holds and every inherited *_OK or *_BYPASS* name, then sets only
# the granted flags. The ask names each granted flag and the hook its registry text says it skips.
# The operator id is allowFrom[0] of the bridge access.json (TELEGRAM_ACCESS_PATH); the inbound journal is
# BRIDGE_ROOT/inbound.jsonl. Test seams: BYPASSD_SEND (a program given the message), BYPASSD_LAUNCHER (run in
# place of headed-arm-worker.sh with its arguments), BYPASSD_POLL, BYPASSD_SETTLE.
# --check runs the start checks (not the Claude-session refusal, the lock, --until or the operator id) and, with
# --request, the request check the loop runs. It prints accepted or refused: <reason>, then daemon: none, daemon: live
# pid=<p> or daemon: live pid=<p>, holding (<cause>). It takes no lock and sends nothing. Exit 0 accepted, 1 refused,
# 2 a start check failed.
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
BUCKET='' until='' CHECK='' REQ_FILE=''
while [ $# -gt 0 ]; do
    [ "$1" = --check ] && { CHECK=1; shift; continue; }
    [ $# -ge 2 ] || die "missing value for $1"
    case $1 in --bucket) BUCKET=$2 ;; --until) until=$2 ;; --request) REQ_FILE=$2 ;; *) die "unknown argument $1" ;; esac
    shift 2
done
[ -n "$CHECK" ] || [ -z "$REQ_FILE" ] || die "--request needs --check"
[ -n "$CHECK" ] || [ -z "${CLAUDECODE:-}" ] || die "refusing to start from inside a Claude session; the operator starts it from their own shell"
[ -n "$BUCKET" ] && [ -d "$BUCKET" ] && [ -d "$BUCKET/bypass-queue" ] || die "usage: bypass-launchd.sh --bucket <dir holding bypass-queue/> --until <YYYY-MM-DD>"
BUCKET="$(cd "$BUCKET" && pwd -P)"
Q="$BUCKET/bypass-queue"
if [ -z "$CHECK" ]; then
[[ "$until" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--until wants YYYY-MM-DD"
# BSD date (macOS) has no -d; probe for its -j -f form once, so GNU date keeps the form it always used.
if date -j -f %Y-%m-%d 2000-01-01 +%s >/dev/null 2>&1; then
    EXPIRES="$(date -u -j -f '%Y-%m-%d %H:%M:%S' "$until 00:00:00" +%s 2>/dev/null)" || die "--until $until is not a date"
else
    EXPIRES="$(date -u -d "$until" +%s 2>/dev/null)" || die "--until $until is not a date"
fi
now="$(date +%s)"
[ "$EXPIRES" -gt "$now" ] && [ "$EXPIRES" -le $((now + 7 * 86400)) ] || die "--until must be after now and at most 7 days ahead"
OP="$(jq -r '.allowFrom[0] // empty' "$ACCESS" 2>/dev/null)" && [[ "$OP" =~ ^[1-9][0-9]*$ ]] || die "no operator id (allowFrom[0]) in $ACCESS"
fi
LOG="$Q/daemon.log" # t13b-ok: the queue log file name the bucket and chief docs already read; operator-started, bounded by --until

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
SELF_REL=scripts/station-ops/bypass-launchd.sh TIER_REL=scripts/station-ops/bypass-flag-tiers.tsv REG_REL=scripts/himmelctl/lib/bypass-flags.json
gitd() { git --no-replace-objects -c core.fsmonitor=false -C "$REPO" "$@"; }
for p in "$SELF_REL" "$TIER_REL" "$REG_REL"; do
    gitd diff --quiet --no-ext-diff --no-textconv HEAD -- "$p" || die "$p has uncommitted changes in $REPO: commit or restore it, then start again"
done
HEAD_SHA=$(gitd rev-parse HEAD 2>/dev/null) || die "cannot read HEAD of $REPO"
L_SELF=$(gitd rev-parse --verify -q "$HEAD_SHA:$SELF_REL" 2>/dev/null) || die "cannot read $SELF_REL at HEAD"
L_TIERS=$(gitd rev-parse --verify -q "$HEAD_SHA:$TIER_REL" 2>/dev/null) || die "cannot read $TIER_REL at HEAD"
L_REG=$(gitd rev-parse --verify -q "$HEAD_SHA:$REG_REL" 2>/dev/null) || die "cannot read $REG_REL at HEAD"
LOADED="${L_SELF:0:12}/${L_TIERS:0:12}/${L_REG:0:12}"
REG_JSON=$(gitd cat-file blob "$L_REG" 2>/dev/null) || die "cannot read $REG_REL at HEAD"
REG_NAMES=$(jq -r '.flags[].name' <<<"$REG_JSON" 2>/dev/null)
[ -n "$REG_NAMES" ] || die "cannot read $REG_REL at HEAD: no flags"
TIER_ROWS=$(gitd cat-file blob "$L_TIERS" 2>/dev/null | grep -v -e '^#' -e '^$')
[ -n "$TIER_ROWS" ] || die "cannot read $TIER_REL at HEAD: no rows"
while IFS=$'\t' read -r n t s _; do
    [[ "$n" =~ ^[A-Z][A-Z0-9_]*$ && "$t" =~ ^(grant|decision|floor|none)$ && -n "$s" ]] || die "cannot read $TIER_REL at HEAD: bad row for '$n'"
done <<<"$TIER_ROWS"
GRANTABLE=$(awk -F'\t' 'NR == FNR { r[$1] = 1; next } ($2 == "grant" || $2 == "decision") && (r[$1] || $3 == "eval") { print $1 }' <(printf '%s\n' "$REG_NAMES") <(printf '%s\n' "$TIER_ROWS"))
grantable=$(printf '%s\n' "$GRANTABLE" | grep -c .)
strip=()
while IFS= read -r n; do strip+=(-u "$n"); done < <({ printf '%s\n' "$REG_NAMES"; printf '%s\n' "$TIER_ROWS" | cut -f1; compgen -e | grep -E '_OK$|_BYPASS'; } | sort -u)
# macOS has no /run/user (and a read-only /run): its default is the per-user TMPDIR.
if [ "$(uname -s)" = Darwin ]; then run_dir_default="${TMPDIR:-/tmp}"; run_dir_default="${run_dir_default%/}"; else run_dir_default="/run/user/$(id -u)"; fi
W="${XDG_RUNTIME_DIR:-$run_dir_default}/himmel-chief/gen-briefs"
sha256_of() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1" 2>/dev/null; } | cut -d" " -f1; }
# setsid is util-linux; stock macOS has perl, whose POSIX::setsid does the same before exec.
if command -v setsid >/dev/null 2>&1; then DETACH=(setsid nohup)
elif command -v perl >/dev/null 2>&1; then DETACH=(perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' nohup)
else DETACH=(nohup); fi

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }
send() {
    if [ -n "${BYPASSD_SEND:-}" ]; then "$BYPASSD_SEND" "$2" "$1" || log "send failed"; return 0; fi
    bun "$REPO/scripts/telegram/chief-route.ts" reply --kind "$1" operator "$2" >/dev/null 2>&1 || log "send failed"
}
field() { sed -n "s/^$1=//p" "$2" | head -n 1; }
refuse() { mv "$1" "$1.refused"; log "REFUSED $2 $1"; send bypass-result "bypass-launchd refused $(basename "$1"): $2"; }
live() { [ ! -e "$Q/stop" ] && [ "$(date +%s)" -lt "$EXPIRES" ]; }

check_request() {
    local f row in_reg text tier src why="" fl=()
    REASON=""
    brief=$(field brief "$1"); model=$(field model "$1"); chief=$(field chief "$1")
    flags=$(field flags "$1"); effort=$(field effort "$1"); decision=$(field decision "$1")
    api_account=$(field api_account "$1"); blocks=$(field blocks "$1"); recommend=$(field recommend "$1")
    [ -n "$flags" ] || flags=HIMMEL_HOOK_INTEGRITY_BYPASS_OK
    base=$(basename "$brief" .md)
    [[ "$brief" == "$BUCKET/$base.md" && ! -L "$brief" && -f "$brief" ]] || why+="${why:+, }brief-path"
    [[ "$base" =~ ^[A-Z][A-Z0-9]+-[0-9]+-[A-Z][0-9]+[a-z]?-[A-Za-z0-9.-]+$ ]] || why+="${why:+, }brief-name"
    [[ "$model" =~ ^claude-(opus|sonnet|haiku)-5-5$ ]] || why+="${why:+, }model"
    [[ "$chief" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{2,119}$ ]] || why+="${why:+, }chief"
    [[ -z "$effort" || "$effort" =~ ^(low|medium|high|xhigh)$ ]] || why+="${why:+, }effort"
    [[ -z "$api_account" || "$api_account" =~ ^([ABCD]|auto)$ ]] || why+="${why:+, }api_account"
    [[ -z "$blocks" || "$blocks" =~ ^#[0-9]+([ ]#[0-9]+)*$ ]] || why+="${why:+, }blocks"
    [[ "$recommend" =~ ^(go|no)$ || "$recommend" =~ ^no:[[:print:]]{1,60}$ ]] || why+="${why:+, }recommend"
    if [ -n "$why" ]; then REASON="malformed: $why"; return 1; fi
    envs=(); bad=""; names=""; skips=""; paid=""; undecided=""
    IFS=, read -ra fl <<<"$flags"
    [ "${#fl[@]}" -le 5 ] || bad="more than 5 flags"
    for f in "${fl[@]}"; do
        [ -z "$bad" ] || break
        row=""; in_reg=0; text=""
        if [[ "$f" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            row=$(printf '%s\n' "$TIER_ROWS" | awk -F'\t' -v n="$f" '$1 == n { print; exit }')
            grep -qxF -- "$f" <<<"$REG_NAMES" && in_reg=1
            text=$(jq -r --arg n "$f" '[.flags[] | select(.name == $n) | .bypasses][0] // empty' <<<"$REG_JSON")
        fi
        tier=$(printf '%s' "$row" | cut -f2); src=$(printf '%s' "$row" | cut -f3)
        if [ "$in_reg" = 0 ] && [ "$src" != eval ]; then bad="flag $f is not in bypass-flags.json"
        elif [ -z "$tier" ]; then bad="flag $f has no tier row"
        elif [ "$tier" = none ]; then bad="flag $f is not a switch"
        elif [ "$tier" = floor ]; then bad="flag $f is floor: launch it from your own shell"
        else
            envs+=("$f=1"); names+="${names:+, }$f"; skips+="${skips:+, }$f"
            [[ "$text" =~ hooks/([A-Za-z0-9_-]+)\.sh ]] && skips+=" (skips ${BASH_REMATCH[1]})"
            if [ "$tier" = decision ]; then
                [ -n "$undecided" ] || undecided=$f
                [ "$f" != HIMMEL_BILLED_OK ] || paid=1
            fi
        fi
    done
    [ -z "$bad" ] || { REASON=$bad; return 1; }
    tags=""
    if [ -n "$undecided" ]; then
        [[ "$decision" =~ ^[0-9]+$ ]] || { REASON="$undecided needs decision=<operator decision number>"; return 1; }
        tags="DECISION $decision"
        [ -z "$paid" ] || tags+=" · PAID RUN"
    fi
    [ -z "$effort" ] || envs+=("WORKER_SESSION_EFFORT=$effort")
    [ -z "$api_account" ] || { envs+=("WORKER_SESSION_API_LANE=on" "WORKER_SESSION_API_ACCOUNT=$api_account"); tags+="${tags:+ · }API account $api_account"; }
    [ -z "$blocks" ] || tags+="${tags:+ · }Blocks PRs: $blocks"
    flag_line="flag"; [ "${#fl[@]}" -eq 1 ] || flag_line="flags"
    if [ "${#skips}" -le $(( 199 - ${#flag_line} )) ]; then flag_line+=" $skips"; else flag_line+=" $names"; fi
    case $recommend in go) word="Chief: GO" ;; no) word="Chief: NO" ;; *) word="Chief: NO — ${recommend#no:}" ;; esac
    return 0
}

stale_now() {
    local h s t r c=""
    STALE_CAUSE="" CURRENT=unreadable
    if ! h=$(gitd rev-parse --verify -q HEAD 2>/dev/null) || ! s=$(gitd rev-parse --verify -q "$h:$SELF_REL" 2>/dev/null) \
        || ! t=$(gitd rev-parse --verify -q "$h:$TIER_REL" 2>/dev/null) || ! r=$(gitd rev-parse --verify -q "$h:$REG_REL" 2>/dev/null); then
        STALE_CAUSE="cannot read HEAD"; return 0
    fi
    CURRENT="${s:0:12}/${t:0:12}/${r:0:12}"
    [ "$s" = "$L_SELF" ] || c+="${c:+, }bypass-launchd.sh"
    [ "$t" = "$L_TIERS" ] || c+="${c:+, }bypass-flag-tiers.tsv"
    [ "$r" = "$L_REG" ] || c+="${c:+, }bypass-flags.json"
    [ -n "$c" ] || return 1
    STALE_CAUSE="$c changed"
}
HOLDING='' TOLD=''
hold() {
    HOLDING=1
    printf 'cause=%s\nsince=%s\nloaded=%s\ncheckout=%s\n' "$STALE_CAUSE" "$(date -u +%FT%TZ)" "$LOADED" "$CURRENT" >"$Q/.hold"
    log "STALE hold loaded=$LOADED checkout=$CURRENT ($STALE_CAUSE)"
    send bypass-failed "bypass-launchd runs older code than its checkout ($STALE_CAUSE). It reads no request until you restart it: touch $Q/stop, wait for \`stop file\` in daemon.log, remove stop, start it again." # t13b-ok: operator-facing text naming the existing bypass daemon, no process is started
}
tell_held() {
    local req n
    for req in "$Q"/*.req; do
        [ -e "$req" ] || continue
        n=$(basename "$req")
        ! grep -qxF -- "$n" <<<"$TOLD" || continue
        TOLD+="$n"$'\n'
        send bypass-failed "bypass request $n waits: the daemon needs a restart" # t13b-ok: operator-facing text naming the existing bypass daemon, no process is started
    done
}

LOCK="$Q/.lock.pid"
lock_owner_alive() {
    local args re='(^|[ /])bypass-launchd\.sh'
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null && args=$(ps -p "$1" -o args= 2>/dev/null) && [[ $args =~ $re ]]
}
take_lock() {
    local seen cur rc=1 rl="$LOCK.reclaim"
    ln -s "$$" "$LOCK" 2>/dev/null && return 0
    seen=$(readlink "$LOCK" 2>/dev/null)
    ! lock_owner_alive "$seen" || return 1
    # Only the holder of the reclaim link may remove the stale lock, so a live lock is never moved aside. A
    # reclaim link left by a starter that died is never removed here (that would be a second check-then-unlink):
    # the operator removes it, and the start is refused with its path.
    if ! ln -s "$$" "$rl" 2>/dev/null; then
        lock_owner_alive "$(readlink "$rl" 2>/dev/null)" && return 1
        echo "bypass-launchd: $rl was left by a starter that died; remove it and start again" >&2
        return 2
    fi
    cur=$(readlink "$LOCK" 2>/dev/null)
    if [ "$cur" = "$seen" ] || [ -z "$cur" ]; then
        [ -z "$cur" ] || rm -f "$LOCK"
        ln -s "$$" "$LOCK" 2>/dev/null && rc=0
    fi
    rm -f "$rl"
    return $rc
}
release_lock() { [ "$(readlink "$LOCK" 2>/dev/null)" = "$$" ] && rm -f "$LOCK"; }

if [ -n "$CHECK" ]; then
    rc=0
    if [ -n "$REQ_FILE" ]; then
        [ -f "$REQ_FILE" ] || die "--request $REQ_FILE is not a file"
        if check_request "$REQ_FILE"; then echo accepted; else echo "refused: $REASON"; rc=1; fi
    fi
    owner=$(readlink "$LOCK" 2>/dev/null)
    if lock_owner_alive "$owner"; then
        cause=""; [ -f "$Q/.hold" ] && cause=$(sed -n 's/^cause=//p' "$Q/.hold" | head -n 1)
        echo "daemon: live pid=$owner${cause:+, holding ($cause)}" # t13b-ok: operator-facing text naming the existing bypass daemon, no process is started
    else
        echo "daemon: none" # t13b-ok: operator-facing text naming the existing bypass daemon, no process is started
    fi
    exit "$rc"
fi

take_lock; lock_rc=$?
[ "$lock_rc" -ne 2 ] || exit 2
[ "$lock_rc" -eq 0 ] || { echo "bypass-launchd: already running"; exit 1; }
trap release_lock EXIT
rm -f "$Q/.hold"
log "start pid=$$ until=$until head=${HEAD_SHA:0:12} self=${L_SELF:0:12} registry=${L_REG:0:12} tiers=${L_TIERS:0:12} grantable=$grantable"

while :; do
    [ -e "$Q/stop" ] && { log "stop file"; exit 0; }
    [ "$(date +%s)" -ge "$EXPIRES" ] && { log "expired $until"; exit 0; }
    [ -n "$HOLDING" ] || ! stale_now || hold
    if [ -n "$HOLDING" ]; then tell_held; sleep "$POLL"; continue; fi
    for req in "$Q"/*.req; do
        [ -e "$req" ] || continue
        if stale_now; then hold; break; fi
        check_request "$req" || { refuse "$req" "$REASON"; continue; }
        code=$(LC_ALL=C tr -dc 'A-Z2-9' </dev/urandom | head -c 6)
        off=$(wc -c 2>/dev/null <"$INBOUND") || off=0; off=${off//[[:space:]]/}
        sha=$(sha256_of "$brief"); [ ${#sha} -eq 64 ] || { refuse "$req" "brief unreadable"; continue; }
        mv "$req" "$req.pending"
        log "ASK $base model=$model chief=$chief flags=$flags effort=${effort:-default} decision=${decision:-none} sha=${sha:0:12}"
        IFS=- read -r k1 k2 worker _ <<<"$base"
        send bypass-ask "go $code → launch · no $code → refuse
$k1-$k2 $worker on ${model#claude-}${effort:+ $effort}
$flag_line
${tags:+$tags
}$word
Expires 6 h · brief sha ${sha:0:12}"
        t0=$(date +%s); verdict=expired
        while [ $(( $(date +%s) - t0 )) -lt "$TTL" ] && live; do
            hit=$(tail -c +"$((off + 1))" "$INBOUND" 2>/dev/null | jq -r --argjson op "$OP" --arg c "$code" \
                'select(.from == $op and .chat_id == $op and .forwarded != true) | (.text // "") | ascii_downcase | gsub("^\\s+|\\s+$"; "") | gsub("\\s+"; " ") |
                 select(. == ("go " + ($c|ascii_downcase)) or . == ("no " + ($c|ascii_downcase)))' 2>/dev/null | tail -n 1)
            case "$hit" in go\ *) verdict=go; break ;; no\ *) verdict=no; break ;; esac
            sleep "$POLL"
        done
        if [ "$verdict" != go ]; then
            mv "$req.pending" "$req.$verdict"; log "$verdict $base"; send bypass-result "bypass launch $base: $verdict, nothing ran."; continue
        fi
        if ! live || [ -L "$brief" ] || [ "$(sha256_of "$brief")" != "$sha" ]; then
            mv "$req.pending" "$req.refused"; log "REFUSED after go $base (stop, expiry, or brief changed since the ask)"
            send bypass-result "bypass launch $base: refused after your go, the brief changed or the queue stopped. Nothing ran."; continue
        fi
        if stale_now; then
            mv "$req.pending" "$req"; log "STALE after go $base: go not used, re-queued"
            send bypass-result "bypass launch $base: your go was not used, the daemon runs older code than its checkout ($STALE_CAUSE). Nothing ran; the request waits for a restart and will be asked again." # t13b-ok: operator-facing text naming the existing bypass daemon, no process is started
            hold; break
        fi
        printf 'granted_at=%s\ngo=%s\nsha=%s\n' "$(date -u +%FT%TZ)" "$code" "$sha" >>"$req.pending"
        log "GRANT $base env=${envs[*]} decision=${decision:-none} go=$code"
        mkdir -p "$W"
        fleet=()
        [ -f "$BUCKET/$chief.fleet.json" ] && bash "$KIT/fleet-manifest.sh" add "$BUCKET/$chief.fleet.json" "$brief" --lane native --pending >>"$LOG" 2>&1 \
            && fleet=(--fleet "$BUCKET/$chief.fleet.json")
        env "${strip[@]}" -u WORKER_SESSION_EFFORT -u CLAUDE_CODE_EFFORT_LEVEL -u WORKER_SESSION_API_LANE -u WORKER_SESSION_API_ACCOUNT \
            -u HEADED_ARM_LAUNCHER_ENV -u HEADED_ARM_LAUNCHER_ENV_LINES "${envs[@]}" "${DETACH[@]}" bash "$LAUNCHER" \
            --profile worker-impl ${fleet[@]+"${fleet[@]}"} --chief "$chief" "$base" "$brief" "$W/sig-$base" "$EXPIRES" "$W/$base.log" "$model" \
            >"$W/$base.launch.out" 2>&1 &
        lp=$!; sleep "${BYPASSD_SETTLE:-12}"; touch "$W/sig-$base"
        if ! kill -0 "$lp" 2>/dev/null; then
            wait "$lp"; lrc=$?
            if [ "$lrc" -ne 0 ]; then
                mv "$req.pending" "$req.failed"; log "LAUNCH-FAILED $base rc=$lrc"
                send bypass-failed "bypass launch $base: FAILED (rc $lrc), see $W/$base.launch.out"; continue
            fi
        fi
        mv "$req.pending" "$req.done"; log "LAUNCHED $base"
        send bypass-result "bypass launch $base: launched with ${envs[*]} (approved by your go code). Launch log $W/$base.launch.out"
    done
    sleep "$POLL"
done
