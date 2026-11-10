#!/usr/bin/env bash
# Exit: 0 for every handled outcome (a hold, a skip and a failed run included);
# 1 when the tick itself cannot work (no primary checkout, no main); 2 on usage.
set -u

pmr_decide() {
    local now="$1" quiet="$2" max="$3" t newest="" oldest=""
    while read -r t; do
        [ -n "$t" ] || continue
        case "$t" in *[!0-9]*) return 2 ;; esac
        if [ -z "$newest" ] || [ "$t" -gt "$newest" ]; then newest="$t"; fi
        if [ -z "$oldest" ] || [ "$t" -lt "$oldest" ]; then oldest="$t"; fi
    done
    if [ -z "$newest" ]; then echo hold; return 0; fi
    if [ $((now - newest)) -ge "$quiet" ] || [ $((now - oldest)) -ge "$max" ]; then
        echo fire
    else
        echo hold
    fi
}

pmr_usage() {
    echo "usage: post-merge-refresh.sh --halves graph|both | --decide <now> <quiet> <max> < times" >&2
    exit 2
}

HALVES=""
case "${1:-}" in
    --decide)
        [ $# -eq 4 ] || pmr_usage
        for _a in "$2" "$3" "$4"; do
            case "$_a" in '' | *[!0-9]*) pmr_usage ;; esac
        done
        pmr_decide "$2" "$3" "$4"
        exit $?
        ;;
    --halves)
        [ $# -eq 2 ] || pmr_usage
        case "$2" in graph | both) HALVES="$2" ;; *) pmr_usage ;; esac
        ;;
    *) pmr_usage ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/qmd-bin.sh
. "$HERE/../lib/qmd-bin.sh"
# shellcheck source=scripts/lib/flow-run-ledger.sh
. "$HERE/../lib/flow-run-ledger.sh"

QUIET_SECS=600
MAX_WAIT_SECS=1800
KEYWORD_DEADLINE_SECS=120
GRAPH_SLOW_SECS=300
LOAD_DEFER_MAX_SECS=1800
LOCK_ALERT_SECS=1800
SKIP_ALERT_COUNT=12
FLOW_TASK="HIMMEL-PostMergeRefresh"

PMR_STATE="${PMR_STATE:-$HOME/.himmel/state/post-merge-refresh}"
PMR_ALERT="${PMR_ALERT:-$HERE/cadence-alert.sh}"
PMR_AST="${PMR_AST:-$HERE/../graphify/ast-update.sh}"
PMR_LAG="${PMR_LAG:-$HERE/keyword-lag.py}"
PMR_REINDEX_LOCK="${PMR_REINDEX_LOCK:-$HOME/.claude/qmd-cadence/qmd-reindex.log.lock}"
PMR_LOG="${PMR_LOG:-$HOME/.claude/graphmap-cadence/post-merge-refresh.log}"
if [ -z "${PMR_PRIMARY:-}" ]; then
    _common=$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || _common=""
    PMR_PRIMARY="${_common%/.git}"
    [ -n "$PMR_PRIMARY" ] || PMR_PRIMARY="$HERE/../.."
fi

if command -v ionice >/dev/null 2>&1; then LOWPRIO=(ionice -c 3 nice -n 15); else LOWPRIO=(nice -n 15); fi

log() { printf 'post-merge-refresh: %s\n' "$*"; }
die() { printf 'post-merge-refresh: ERR %s\n' "$*" >&2; exit 1; }

pmr_now() {
    case "${PMR_NOW:-}" in
        '') date +%s ;;
        *[!0-9]*) cat "$PMR_NOW" 2>/dev/null || date +%s ;;
        *) printf '%s\n' "$PMR_NOW" ;;
    esac
}

st_get() { cat "$PMR_STATE/$1" 2>/dev/null || true; }
st_put() { printf '%s\n' "$2" > "$PMR_STATE/$1.tmp.$$" && mv -f "$PMR_STATE/$1.tmp.$$" "$PMR_STATE/$1"; }
st_rm() { rm -f "$PMR_STATE/$1"; }

alert_fail() { # <half> <reason> <cause> <do>
    "$PMR_ALERT" fail "post-merge-$1" "$2" "$PMR_LOG" "$3" "$4" >/dev/null 2>&1 || true
}
alert_clear() { "$PMR_ALERT" clear "$1" >/dev/null 2>&1 || true; }

pmr_skip() {
    local half="$1" reason="$2" prev prev_reason prev_count count
    log "$half skip=$reason"
    prev=$(st_get "$half.skips")
    prev_reason="${prev%% *}"
    prev_count="${prev##* }"
    if [ "$prev_reason" = "$reason" ] && [ -n "$prev_count" ]; then count=$((prev_count + 1)); else count=1; fi
    st_put "$half.skips" "$reason $count"
    if [ "$count" -ge "$SKIP_ALERT_COUNT" ]; then
        alert_fail "$half" "$count skips in a row: $reason" "the $half refresh has skipped for $reason $count ticks running" "read $PMR_LOG and clear the cause"
    fi
}

LOCK_TAKEN=0
LOCK_LIVE=1
LOCK_DEAD=2
LOCK_HELD=""
LOCK_TOKEN="$$-$(date +%s)"
lock_release() {
    if [ -n "$LOCK_HELD" ] && [ "$(cat "$LOCK_HELD/owner" 2>/dev/null)" = "$LOCK_TOKEN" ]; then
        rm -f "$LOCK_HELD/pid" "$LOCK_HELD/owner" "$LOCK_HELD/acquired"
        rmdir "$LOCK_HELD" 2>/dev/null || true
    fi
    LOCK_HELD=""
}
trap 'lock_release' EXIT
trap 'lock_release; exit 143' INT TERM

lock_acquire() {
    local dir="$1" now="$2" pid
    if mkdir "$dir" 2>/dev/null; then
        LOCK_HELD="$dir"
        if printf '%s\n' "$$" > "$dir/pid" && printf '%s\n' "$LOCK_TOKEN" > "$dir/owner" \
            && printf '%s\n' "$now" > "$dir/acquired"; then
            return "$LOCK_TAKEN"
        fi
        lock_release
        die "could not stamp lock $dir"
    fi
    pid=$(cat "$dir/pid" 2>/dev/null || true)
    if [ -z "$pid" ]; then sleep 1; pid=$(cat "$dir/pid" 2>/dev/null || true); fi
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return "$LOCK_LIVE"; fi
    return "$LOCK_DEAD"
}

load_is_high() {
    local load="${PMR_LOAD:-}" cores
    if [ -z "$load" ]; then
        load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null) || load=""
        [ -n "$load" ] || load=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')
        [ -n "$load" ] || load=0
    fi
    cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
    awk -v l="$load" -v c="$cores" 'BEGIN { exit !(l + 0 >= c + 0) }'
}

reindex_lock_is_live() {
    local pid
    [ -d "$PMR_REINDEX_LOCK" ] || return 1
    pid=$(cat "$PMR_REINDEX_LOCK/pid" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

collect_times() {
    local half="$1" from="$2" to="$3" line cur="" got acc=""
    if [ "$half" = graph ]; then
        git -C "$PMR_PRIMARY" log --first-parent --format=%ct "$from..$to"
        return 0
    fi
    local paths=()
    while IFS= read -r line; do
        case "$line" in
            @*)
                if [ -n "$cur" ] && [ ${#paths[@]} -gt 0 ]; then
                    got=$(qmd_collection_indexes himmel "${paths[@]}") || return 1
                    [ -z "$got" ] || acc="$acc$cur"$'\n'
                fi
                cur="${line#@}"
                paths=()
                ;;
            '') ;;
            *) paths=("${paths[@]+"${paths[@]}"}" "$line") ;;
        esac
    done < <(git -C "$PMR_PRIMARY" -c core.quotepath=off log --first-parent -m --name-only --format=@%ct "$from..$to")
    if [ -n "$cur" ] && [ ${#paths[@]} -gt 0 ]; then
        got=$(qmd_collection_indexes himmel "${paths[@]}") || return 1
        [ -z "$got" ] || acc="$acc$cur"$'\n'
    fi
    printf '%s' "${acc%$'\n'}"
}

run_keyword() {
    if [ -n "${PMR_QMD:-}" ]; then
        qmd_bounded "$KEYWORD_DEADLINE_SECS" env QMD_SQLITE_BUSY_TIMEOUT=30000 "${LOWPRIO[@]}" "$PMR_QMD" update -c himmel
        return $?
    fi
    local js; js="$(_qmd_bun_js)"
    if [ -f "$js" ] && command -v bun >/dev/null 2>&1; then
        qmd_bounded "$KEYWORD_DEADLINE_SECS" env QMD_SQLITE_BUSY_TIMEOUT=30000 "${LOWPRIO[@]}" bun "$js" update -c himmel
    else
        qmd_bounded "$KEYWORD_DEADLINE_SECS" env QMD_SQLITE_BUSY_TIMEOUT=30000 "${LOWPRIO[@]}" qmd update -c himmel
    fi
}

run_graph() {
    "${LOWPRIO[@]}" bash "$PMR_AST" "$PMR_PRIMARY"
}

flow_rows() { # <flow> <started> <ended> <rc> <from> <to>
    local flow="$1" started="$2" ended="$3" rc="$4" from="$5" to="$6" fired_at ended_at run_id outcome
    fired_at=$(date -u -d "@$started" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$started" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || _fr_now_utc)
    ended_at=$(date -u -d "@$ended" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$ended" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || _fr_now_utc)
    run_id=$(flow_run_id "$flow" "$fired_at" "$$")
    outcome=$(flow_run_classify "$rc")
    flow_run_append "$(flow_run_row_start "$flow" "$run_id" "$fired_at" "$(hostname 2>/dev/null || echo unknown)" "" "" "$FLOW_TASK" "$PMR_LOG" "$$")"
    flow_run_append "$(flow_run_row_end "$flow" "$run_id" "$ended_at" "$rc" "$outcome" "" "$from..$to")"
}

wait_gate_holds() {
    local half="$1" now="$2" retry floor
    retry=$(st_get "$half.retry")
    if [ -n "$retry" ] && [ "$now" -lt "$retry" ]; then log "$half hold=backoff until=$retry"; return 0; fi
    if [ "$half" = graph ]; then
        floor=$(st_get graph.floor)
        if [ -n "$floor" ] && [ "$now" -lt $((floor + 3600)) ]; then log "$half hold=slow-floor since=$floor"; return 0; fi
    fi
    return 1
}

pmr_half() {
    pmr_half_step "$1"
    lock_release
    return 0
}

pmr_half_step() { # keyword|graph
    local half="$1" pfx now branch main w force=0 times newest oldest t first retry floor
    local lock rc out start end flow
    if [ "$half" = keyword ]; then pfx="qmd"; flow="post-merge-keyword"; else pfx="graph"; flow="post-merge-graph"; fi
    now=$(pmr_now)
    branch=$(git -C "$PMR_PRIMARY" symbolic-ref -q --short HEAD 2>/dev/null || true)
    if [ "$branch" != main ]; then pmr_skip "$half" primary-off-main; return 0; fi
    main=$(git -C "$PMR_PRIMARY" rev-parse --verify -q refs/heads/main) || die "no refs/heads/main in $PMR_PRIMARY"
    w=$(st_get "$pfx.sha")
    if [ -z "$w" ]; then
        st_put "$pfx.sha" "$main"
        log "$half seeded main=$main"
        return 0
    fi
    [ "$w" = "$main" ] && return 0
    git -C "$PMR_PRIMARY" merge-base --is-ancestor "$w" "$main" 2>/dev/null || force=1

    if [ "$force" = 0 ]; then
        if ! times=$(collect_times "$half" "$w" "$main"); then pmr_skip "$half" filter-error; return 0; fi
        if [ -z "$times" ]; then
            st_put "$pfx.sha" "$main"
            log "$half nothing from=$w to=$main"
            return 0
        fi
        if [ "$(printf '%s\n' "$times" | pmr_decide "$now" "$QUIET_SECS" "$MAX_WAIT_SECS")" != fire ]; then
            newest=""; oldest=""
            for t in $times; do
                if [ -z "$newest" ] || [ "$t" -gt "$newest" ]; then newest="$t"; fi
                if [ -z "$oldest" ] || [ "$t" -lt "$oldest" ]; then oldest="$t"; fi
            done
            log "$half hold=window newest=$((now - newest))s oldest=$((now - oldest))s"
            return 0
        fi
    else
        log "$half watermark $w is not an ancestor of main; running once"
    fi

    if wait_gate_holds "$half" "$now"; then return 0; fi
    if [ "$half" = keyword ] && reindex_lock_is_live; then pmr_skip "$half" reindex-lock; return 0; fi
    if load_is_high; then
        first=$(st_get "$half.defer")
        if [ -z "$first" ]; then first="$now"; st_put "$half.defer" "$now"; fi
        if [ $((now - first)) -lt "$LOAD_DEFER_MAX_SECS" ]; then pmr_skip "$half" load; return 0; fi
    else
        st_rm "$half.defer"
    fi

    lock="$PMR_STATE/$pfx.lock"
    lock_acquire "$lock" "$now"
    rc=$?
    if [ "$rc" = "$LOCK_LIVE" ]; then
        local acquired; acquired=$(cat "$lock/acquired" 2>/dev/null || echo "$now")
        case "$acquired" in '' | *[!0-9]*) acquired="$now" ;; esac
        if [ $((now - acquired)) -ge "$LOCK_ALERT_SECS" ] && [ "$(st_get "$half.lockalert")" != "$acquired" ]; then
            st_put "$half.lockalert" "$acquired"
            alert_fail "$half" "lock held over 30 minutes" "the $half refresh lock $lock has been held since $acquired by a live process" "wait, or stop that process"
        fi
        pmr_skip "$half" live-lock
        return 0
    elif [ "$rc" = "$LOCK_DEAD" ]; then
        log "$half ERR dead lock holder: $lock is left in place; remove that directory to resume"
        alert_fail "$half" "dead lock holder" "lock $lock names a process that is gone" "remove the directory $lock"
        pmr_skip "$half" dead-lock
        return 0
    fi
    st_rm "$half.lockalert"
    st_rm "$half.defer"
    if [ "$(st_get "$pfx.sha")" != "$w" ]; then log "$half hold=raced"; return 0; fi
    if wait_gate_holds "$half" "$now"; then return 0; fi

    start=$(pmr_now)
    if [ "$half" = keyword ]; then out=$(run_keyword 2>&1); rc=$?; else out=$(run_graph 2>&1); rc=$?; fi
    end=$(pmr_now)
    [ -z "$out" ] || printf '%s\n' "$out" | sed "s/^/post-merge-refresh: $half | /"

    if [ "$rc" = 0 ]; then
        st_put "$pfx.sha" "$main"
        st_rm "$half.fails"; st_rm "$half.skips"; st_rm "$half.retry"
        alert_clear "post-merge-$half"
        flow_rows "$flow" "$start" "$end" 0 "$w" "$main"
        if [ "$half" = graph ]; then
            if [ $((end - start)) -gt "$GRAPH_SLOW_SECS" ]; then st_put graph.floor "$start"; else st_rm graph.floor; fi
        fi
        log "$half ok from=$w to=$main secs=$((end - start))"
        return 0
    fi
    if { [ "$half" = keyword ] && qmd_output_is_busy "$out"; }; then pmr_skip "$half" db-busy; return 0; fi
    if [ "$half" = graph ] && [ "$rc" = 4 ]; then pmr_skip "$half" promote-lock; return 0; fi

    local fails delay
    fails=$(st_get "$half.fails"); fails=$(( ${fails:-0} + 1 ))
    st_put "$half.fails" "$fails"
    st_rm "$half.skips"
    delay=3600
    if [ "$fails" -le 4 ]; then delay=$((300 << (fails - 1))); fi
    st_put "$half.retry" $((end + delay))
    flow_rows "$flow" "$start" "$end" "$rc" "$w" "$main"
    log "$half fail rc=$rc from=$w to=$main failures=$fails retry_in=${delay}s"
    if [ "$fails" -ge 3 ]; then
        alert_fail "$half" "$fails failed refreshes in a row" "the $half refresh exited $rc for $w..$main" "read $PMR_LOG"
    fi
    return 0
}

pmr_sample() {
    local idx="${INDEX_PATH:-${QMD_INDEX_PATH:-${XDG_CACHE_HOME:-$HOME/.cache}/qmd/index.sqlite}}" rc
    if [ ! -f "$idx" ]; then log "no index at $idx, sampler not run"; return 0; fi
    if [ ! -f "$PMR_LAG" ]; then log "keyword-lag.py absent at $PMR_LAG, sampler skipped"; return 0; fi
    python3 -I "$PMR_LAG" tick --index "$idx" --state "$PMR_STATE"
    rc=$?
    [ "$rc" = 0 ] || log "sampler failed rc=$rc"
    return 0
}

git -C "$PMR_PRIMARY" rev-parse --git-dir >/dev/null 2>&1 || die "$PMR_PRIMARY is not a git checkout"
mkdir -p "$PMR_STATE" || die "cannot create $PMR_STATE"

[ "$HALVES" = both ] && pmr_half keyword
pmr_sample
pmr_half graph
alert_clear post-merge-tick
exit 0
