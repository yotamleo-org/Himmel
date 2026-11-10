#!/usr/bin/env bash
# scripts/handover/chief-kit/close-sweep.sh - the one batched sweep that does a closed
# worker's housekeeping (session note, cost row, failure digest, /tmp reap, worktree
# prune) for every queued close record, with at most ONE PR list call per repo.
#
# Usage:
#   close-sweep.sh --drain    take sweep.lock (flock -n; held: exit 0, the holder will
#                             see any new record), then process every pending record
#                             not yet seen in this run, oldest first, in two phases.
#   close-sweep.sh --status   print `close-sweep: pending=<n> failed=<n> last=<epoch>`;
#                             reads the state dir, writes nothing, makes no call.
#
# A close record is <state>/pending/<epoch>-<label>.json: doc, label, pid, proc_start,
# sid, transcript, names, config_dir, projects_dir, worktrees, repo, predecessor,
# named_successor, closed_at, sweeps_seen. This script is the only owner of sweep.lock.
#
# Seams, set by suites only: CLOSE_SWEEP_STATE_DIR, CLOSE_SWEEP_PID_WAIT,
# CLOSE_SWEEP_TEST_PAUSE_FILE (the drain blocks on it, when set and present, between its
# last scan and its lock release), CLAUDE_SESSIONS_PROC (/proc), and the helper seams
# CLEAN_SH_BIN, TMP_REAP_BIN, WORKER_SESSION_DIGEST_STEP_BIN, END_SESSION_WIKI_BIN,
# WORKTREE_SH_BIN (the `pr-cache` verb) and CLOSE_SWEEP_PRUNE_RETRIES / _PRUNE_WAIT.
#
# Platform guard: Linux bash 3.2+ (flock, /proc; git 2.38+ for the merged proof).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${CLOSE_SWEEP_STATE_DIR:-$HOME/.himmel/state/close-sweep}"
PID_WAIT="${CLOSE_SWEEP_PID_WAIT:-60}"
case "$PID_WAIT" in ''|*[!0-9]*) PID_WAIT=60 ;; esac
PID_WAIT=$((10#$PID_WAIT))
PROC_ROOT="${CLAUDE_SESSIONS_PROC:-/proc}"
KEPT_ALIVE_MAX_SWEEPS=3
KEPT_ALIVE_MAX_SECONDS=600
CLEAN_SH="${CLEAN_SH_BIN:-$HERE/../../clean.sh}"
TMP_REAP="${TMP_REAP_BIN:-$HERE/../../tmp-reap.sh}"
WORKTREE_SH="${WORKTREE_SH_BIN:-$HERE/../../worktree.sh}"
DIGEST_STEP="${WORKER_SESSION_DIGEST_STEP_BIN:-$HERE/worker-digest-step.sh}"
END_SESSION_WIKI="${END_SESSION_WIKI_BIN:-$HERE/../../hooks/end-session-wiki.sh}"

now() { date +%s; }
log() { printf 'close-sweep: %s\n' "$*"; }

count_json() {
    local f n=0
    for f in "$1"/*.json; do [ -f "$f" ] && n=$((n + 1)); done
    printf '%s' "$n"
}

status() {
    local pending failed last
    pending=$(count_json "$STATE/pending")
    failed=$(count_json "$STATE/failed")
    last=""
    if [ -r "$STATE/last" ]; then last=$(cat "$STATE/last"); fi
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    printf 'close-sweep: pending=%s failed=%s last=%s\n' "$pending" "$failed" "$last"
}

case "${1:-}" in
    --status) status; exit 0 ;;
    --drain) ;;
    *) echo "usage: close-sweep.sh --drain | --status" >&2; exit 2 ;;
esac

# shellcheck source=scripts/handover/chief-kit/close-facts.sh
. "$HERE/close-facts.sh" || { echo "close-sweep: cannot load close-facts.sh" >&2; exit 1; }
# shellcheck source=scripts/handover/chief-kit/worker-transcripts.sh
. "$HERE/worker-transcripts.sh" || { echo "close-sweep: cannot load worker-transcripts.sh" >&2; exit 1; }
# shellcheck source=scripts/lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh" || { echo "close-sweep: cannot load git-clean.sh" >&2; exit 1; }
git_env_scrub
COST_LIB_OK=1
# shellcheck source=scripts/lanes/lib/worker-cost-row.sh
. "$HERE/../../lanes/lib/worker-cost-row.sh" 2>/dev/null || COST_LIB_OK=0

mkdir -p "$STATE/pending" "$STATE/done" "$STATE/failed" || { echo "close-sweep: cannot create $STATE" >&2; exit 1; }
exec 9>"$STATE/sweep.lock"
flock -n 9 || exit 0 # prim-ok: the sweep holds this lock on fd 9 across its whole drain and releases it between scans; with_lock cannot hold a lock across a loop

for stale in "$STATE"/run.*; do
    [ -d "$stale" ] || continue
    kill -0 "${stale##*run.}" 2>/dev/null || rm -rf "$stale"
done
RUN_DIR="$STATE/run.$$"
rm -rf "$RUN_DIR"
mkdir "$RUN_DIR" || { echo "close-sweep: cannot create a run directory" >&2; exit 1; }
trap 'rm -rf "$RUN_DIR"' EXIT
SEEN=""

rf() { jq -r --arg f "$2" '.[$f] // "" | if type == "array" then join("\n") else tostring end' "$1" 2>/dev/null; }
rec_set() {
    local f="$1" tmp="$RUN_DIR/rec.tmp" k v filter='.' args=() n=0
    shift
    while [ "$#" -ge 2 ]; do
        k="$1"; v="$2"; shift 2
        args+=(--arg "k$n" "$k" --arg "v$n" "$v")
        filter="$filter | .[\$k$n] = \$v$n"
        n=$((n + 1))
    done
    jq "${args[@]}" "$filter" "$f" > "$tmp" && mv "$tmp" "$f" # prim-ok: tmp is in the per-run dir on the state filesystem, the mv is atomic
}
rec_set_num() {
    jq --arg k "$2" --argjson v "$3" '.[$k] = $v' "$1" > "$RUN_DIR/rec.tmp" && mv "$RUN_DIR/rec.tmp" "$1"
}
record_successor_live() {
    local pred
    case "$(rf "$1" predecessor)" in 1|true) pred=1 ;; *) pred=0 ;; esac
    successor_live "$(rf "$1" doc)" "$pred" "$(rf "$1" named_successor)"
}
finish() {
    local f="$1" dir="$2"
    shift 2
    if [ "$#" -gt 0 ] && ! rec_set "$f" "$@"; then
        log "$(basename "$f" .json): cannot save its results - left in pending/ for the next sweep"
        return 1
    fi
    if ! mv "$f" "$STATE/$dir/$(basename "$f")"; then
        log "$(basename "$f" .json): cannot move it to $dir/ - left in pending/ for the next sweep"
        return 1
    fi
    log "$(basename "$f" .json) -> $dir capture=$(rf "$STATE/$dir/$(basename "$f")" capture) digest=$(rf "$STATE/$dir/$(basename "$f")" digest | cut -c1-40) reap=$(rf "$STATE/$dir/$(basename "$f")" reap) prune=$(rf "$STATE/$dir/$(basename "$f")" prune)"
}

proc_start_time() { sed -E 's/^.*\) //' "$1" | awk '{print $20}'; }
pid_gone() {
    local cur
    case "$1" in ''|0|null|*[!0-9]*) return 0 ;; esac
    [ -d "$PROC_ROOT/$1" ] || return 0
    [ -n "$2" ] && [ -r "$PROC_ROOT/$1/stat" ] || return 1
    cur=$(proc_start_time "$PROC_ROOT/$1/stat")
    [ -n "$cur" ] && [ "$cur" != "$2" ]
}

capture_slot() {
    printf '%s/.claude/logs/end-session-wiki/captured/%s-%s' "$HOME" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_')" "$(printf '%s' "$1" | cksum | awk '{print $1}')"
}
capture_note() {
    local t="$1" csid cwd payload
    [ -n "$t" ] || { echo "skipped:no-transcript"; return; }
    [ -r "$END_SESSION_WIKI" ] || { echo "skipped:no-hook"; return; }
    csid=$(transcript_sid "$t")
    if [ -e "$(capture_slot "$csid")" ]; then echo "claimed-elsewhere"; return; fi
    cwd=$(jq -r 'select(.cwd != null) | .cwd' "$t" 2>/dev/null | head -1) # swallow-ok: a transcript with no readable cwd skips the capture, recorded as skipped:no-cwd, never guessed
    [ -n "$cwd" ] || { echo "skipped:no-cwd"; return; }
    payload=$(jq -n --arg t "$t" --arg s "$csid" --arg c "$cwd" --arg r "worker-close" '{transcript_path:$t, session_id:$s, cwd:$c, reason:$r}')
    if printf '%s' "$payload" | timeout -k 5 "${CLOSE_SWEEP_CAPTURE_TIMEOUT:-60}" bash "$END_SESSION_WIKI" >/dev/null 2>&1 9>&-; then echo "ok"; else echo "failed"; fi
}
cost_row() {
    local t="$1" doc="$2" ledger row sid
    [ -n "$t" ] || { echo "skipped:no-transcript"; return; }
    [ "$COST_LIB_OK" -eq 1 ] || { echo "failed:no-lib"; return; }
    ledger=$(worker_cost_ledger_path "$doc") || { echo "failed:no-ledger"; return; }
    sid=$(transcript_sid "$t")
    if [ -f "$ledger" ] && grep -qF "\"session\":\"$sid\"" "$ledger"; then echo "dedup"; return; fi
    row=$(worker_cost_row "$t" "$doc" 2>/dev/null) || { echo "failed:burn"; return; } # swallow-ok: a meter failure is the recorded result failed:burn
    if mkdir -p "$(dirname "$ledger")" 2>/dev/null && printf '%s\n' "$row" >> "$ledger" 2>/dev/null; then echo "ok"; else echo "failed:write"; fi
}
reap_scratch() {
    local doc="$1" t="$2" pr sid args=()
    pr=$(doc_pr "$doc")
    [ -z "$pr" ] || args+=(--judge "$pr")
    if [ -n "$t" ]; then
        sid=$(transcript_sid "$t")
        case "$sid" in ????????-????-????-????-????????????) args+=(--session "$sid") ;; esac
    fi
    [ "${#args[@]}" -gt 0 ] || { echo "skipped:no-scope"; return; }
    bash "$TMP_REAP" "${args[@]}" >/dev/null 2>&1 9>&- || { echo "failed:dry-run"; return; }
    bash "$TMP_REAP" --apply "${args[@]}" >/dev/null 2>&1 9>&- || { echo "failed:apply"; return; }
    echo "ok"
}

READY="$RUN_DIR/ready"; : > "$READY"

phase_a() {
    local rec="$1" tf pid ps closed doc sid tr names pdir deadline t cands tm tcount dsid pidarg dline cap cost reap seen
    if ! jq -e . "$rec" >/dev/null 2>&1; then
        log "$(basename "$rec") is not a JSON record - moved to failed/"
        mv "$rec" "$STATE/failed/$(basename "$rec")"
        return
    fi
    pid=$(rf "$rec" pid); ps=$(rf "$rec" proc_start); closed=$(rf "$rec" closed_at); doc=$(rf "$rec" doc)
    sid=$(rf "$rec" sid); tr=$(rf "$rec" transcript); names=$(rf "$rec" names); pdir=$(rf "$rec" projects_dir)
    case "$closed" in ''|*[!0-9]*) closed=$(now) ;; esac

    closed=$((10#$closed))
    deadline=$((closed + PID_WAIT))
    while ! pid_gone "$pid" "$ps"; do
        [ "$(now)" -lt "$deadline" ] || break
        sleep 1
    done

    t=""
    [ -z "$tr" ] || [ ! -f "$tr" ] || t="$tr"
    if [ -z "$t" ] && [ -n "$sid" ] && [ -n "$pdir" ] && [ -d "$pdir" ]; then
        tm=""
        for tf in "$pdir"/*/"$sid.jsonl"; do
            [ -f "$tf" ] || continue
            tm="${tm:+$tm
}$tf"
        done
        tcount=$(printf '%s\n' "$tm" | awk 'NF { n++ } END { print n + 0 }')
        [ "$tcount" -ne 1 ] || t="$tm"
    fi
    if [ -z "$t" ] && [ -n "$names" ] && [ -n "$pdir" ] && [ -d "$pdir" ]; then
        cands=$(printf '%s\n' "$names" | tr ',' '\n' | sed '/^$/d')
        tm=$(resolve_worker_transcripts "$pdir" "$cands" "${CLOSE_SWEEP_MTIME_DAYS:-1}" "${CLOSE_SWEEP_CUSTOMTITLE_HEAD:-40}")
        tcount=$(printf '%s\n' "$tm" | awk 'NF { n++ } END { print n + 0 }')
        [ "$tcount" -ne 1 ] || t="$tm"
    fi
    dsid="$sid"
    case "$dsid" in ????????-????-????-????-????????????) ;; *) [ -z "$t" ] || dsid=$(transcript_sid "$t") ;; esac

    cap=$(rf "$rec" capture)
    if [ -z "$cap" ]; then cap=$(capture_note "$t"); rec_set "$rec" capture "$cap" || { log "$(basename "$rec" .json): cannot save its capture result - left in pending/"; return; }; fi
    cost=$(rf "$rec" cost)
    if [ -z "$cost" ]; then cost=$(cost_row "$t" "$doc" 9>&-); rec_set "$rec" cost "$cost" || { log "$(basename "$rec" .json): cannot save its cost result - left in pending/"; return; }; fi
    dline=$(rf "$rec" digest)
    if [ -z "$dline" ]; then
        pidarg=""
        pid_gone "$pid" "$ps" || pidarg="$pid"
        dline=$(timeout -k 5 "${CLOSE_SWEEP_DIGEST_TIMEOUT:-120}" bash "$DIGEST_STEP" \
            --session "$dsid" --transcript "$t" --doc "$doc" --pid "$pidarg" --projects "$pdir" 2>/dev/null </dev/null 9>&- \
            | grep -m 1 '^digest=' 9>&-)
        dline="${dline:-digest=failed:step}"
        rec_set "$rec" digest "$dline" || { log "$(basename "$rec" .json): cannot save its digest result - left in pending/"; return; }
    fi
    rec_set "$rec" transcript_resolved "$t" || { log "$(basename "$rec" .json): cannot save its transcript - left in pending/"; return; }

    if pid_gone "$pid" "$ps"; then
        if record_successor_live "$rec"; then
            finish "$rec" "done" reap kept-successor prune kept-successor
            return
        fi
        reap=$(reap_scratch "$doc" "$t")
        rec_set "$rec" reap "$reap" || { log "$(basename "$rec" .json): cannot save its reap result - left in pending/"; return; }
        printf '%s\n' "$rec" >> "$READY"
        return
    fi
    seen=$(rf "$rec" sweeps_seen); case "$seen" in ''|*[!0-9]*) seen=0 ;; esac
    seen=$((10#$seen + 1))
    rec_set_num "$rec" sweeps_seen "$seen" || { log "$(basename "$rec" .json): cannot save sweeps_seen - left in pending/"; return; }
    if [ "$seen" -ge "$KEPT_ALIVE_MAX_SWEEPS" ] || [ $(( $(now) - closed )) -ge "$KEPT_ALIVE_MAX_SECONDS" ]; then
        finish "$rec" "done" reap kept-alive prune kept-alive
    fi
}

fetch_repo() {
    GIT_TERMINAL_PROMPT=0 timeout -k 5 "${CLOSE_SWEEP_FETCH_TIMEOUT:-60}" \
        git -c core.hooksPath=/dev/null -C "$1" fetch --prune --quiet --no-write-fetch-head origin </dev/null >/dev/null 2>&1 9>&- \
        || log "fetch of $1 failed - using the refs it has (a stale ref can only withhold a proof)"
}

prune_one() {
    local repo="$1" wt="$2" cache="$3" tries="${CLOSE_SWEEP_PRUNE_RETRIES:-3}" try=0 rc out summary partial failed benign
    while :; do
        out=$(unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE; cd "$repo" && bash "$CLEAN_SH" --only "$wt" --only-allow-unmerged --pr-cache "$cache" 2>&1 </dev/null 9>&-)
        rc=$?
        case "$out" in *'in use'*) ;; *) break ;; esac
        [ "$rc" -ne 0 ] || break
        [ "$try" -lt "$tries" ] || break
        try=$((try + 1))
        sleep "${CLOSE_SWEEP_PRUNE_WAIT:-1}"
    done
    printf '%s\n' "$out" > "$RUN_DIR/prune.out"
    if [ "$rc" -eq 0 ]; then PRUNE_RESULT=pruned; return; fi
    case "$out" in
        *'ERR worktree: --pr-cache:'*) PRUNE_RESULT=kept:pr-cache-refused; return ;;
    esac
    summary=$(printf '%s\n' "$out" | grep -F 'clean-garden: prune summary' | tail -n 1)
    partial=$(printf '%s' "$summary" | sed -nE 's/.*, ([0-9]+) partial,.*/\1/p')
    failed=$(printf '%s' "$summary" | sed -nE 's/.* ([0-9]+) failed$/\1/p')
    benign=0
    if [ "$partial" = "0" ] && [ "$failed" = "0" ]; then
        case "$out" in *'in use'*|*'not a prune candidate'*) benign=1 ;; esac
    fi
    case "$out" in
        *'is not a registered worktree'*) if [ ! -e "$wt" ]; then PRUNE_RESULT=gone; return; fi ;;
    esac
    if [ "$benign" -eq 1 ]; then PRUNE_RESULT=kept; return; fi
    PRUNE_RESULT=failed
}

phase_b() {
    local repos repo rec n plan wt branch tip doc row cache res_count all wts wt_count idx=0 pr_rc kind
    while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        if [ -z "$(rf "$rec" repo)" ]; then
            log "$(basename "$rec" .json): the record names no repo - prune skipped"
            finish "$rec" "done" prune skipped-no-repo
        fi
    done < "$1"
    repos=$(while IFS= read -r rec; do [ -f "$rec" ] && rf "$rec" repo; done < "$1" | sort -u)
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        idx=$((idx + 1))
        plan="$RUN_DIR/plan.$idx"; : > "$plan"
        fetch_repo "$repo"
        res_count=0; n=0
        while IFS= read -r rec; do
            [ -f "$rec" ] && [ "$(rf "$rec" repo)" = "$repo" ] || continue
            n=$((n + 1))
            doc=$(rf "$rec" doc); wts=$(rf "$rec" worktrees)
            wt_count=$(printf '%s\n' "$wts" | awk 'NF { n++ } END { print n + 0 }')
            if [ "$wt_count" -ne 1 ]; then
                log "$(basename "$rec" .json): the doc names $wt_count worktree path(s) - prune skipped, never guessing"
                finish "$rec" "done" prune "skipped:worktrees=$wt_count"
                continue
            fi
            wt="$wts"
            if [ ! -d "$wt" ]; then finish "$rec" "done" prune gone; continue; fi
            branch=$(cf_git "$wt" symbolic-ref --short -q HEAD)
            tip=$(cf_git "$wt" rev-parse HEAD)
            cache="$RUN_DIR/cache.$idx.$n"
            kind=residue
            if [ -n "$branch" ] && [ -n "$tip" ]; then
                row=$(merged_proof "$repo" "$doc" "$branch" "$tip")
                if [ -n "$row" ] && write_branch_cache "$repo" "$branch" "$row" > "$cache"; then
                    kind=proof
                elif no_work_proof "$repo" "$doc" "$branch" "$tip" > "$cache" && [ -s "$cache" ]; then
                    kind=proof
                fi
            fi
            [ "$kind" = proof ] || res_count=$((res_count + 1))
            printf '%s|%s|%s|%s\n' "$rec" "$wt" "$kind" "$cache" >> "$plan"
        done < "$1"
        all=""
        if [ "$res_count" -gt 0 ]; then
            all="$RUN_DIR/all.$idx"
            pr_rc=0
            (unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE; cd "$repo" && timeout -k 5 "${CLOSE_SWEEP_LIST_TIMEOUT:-300}" bash "$WORKTREE_SH" pr-cache > "$all" 2> "$all.err" </dev/null 9>&-) || pr_rc=$?
            if [ "$pr_rc" -ne 0 ]; then
                log "the PR list for $repo failed (rc $pr_rc) - its unproven worktrees stay"
                all=""
            fi
        fi
        while IFS='|' read -r rec wt kind cache <&4; do
            [ -n "$rec" ] || continue
            if [ "$kind" = residue ]; then
                if [ -z "$all" ]; then finish "$rec" "done" prune kept-unknown; continue; fi
                cache="$all"
            fi
            if record_successor_live "$rec"; then
                finish "$rec" "done" prune kept-successor
                continue
            fi
            prune_one "$repo" "$wt" "$cache"
            case "$PRUNE_RESULT" in
                failed)
                    log "PRUNE-FAILED $wt"
                    sed 's/^/close-sweep:   /' "$RUN_DIR/prune.out"
                    finish "$rec" failed prune failed ;;
                kept:pr-cache-refused)
                    log "kept $wt: $(grep -F 'ERR worktree: --pr-cache:' "$RUN_DIR/prune.out" | head -n 1)"
                    finish "$rec" "done" prune "$PRUNE_RESULT" ;;
                *) finish "$rec" "done" prune "$PRUNE_RESULT" ;;
            esac
        done 4< "$plan"
    done <<EOF
$repos
EOF
}

unseen() {
    local f
    for f in "$STATE/pending"/*.json; do
        [ -f "$f" ] || continue
        grep -qxF -- "$f" <<< "$SEEN" || printf '%s\n' "$f"
    done | sort
}

process_batch() {
    local f
    : > "$READY"
    for f in $1; do
        SEEN="$SEEN$f"$'\n'
        phase_a "$f"
        [ -f "$f" ] || true
    done
    phase_b "$READY"
}

while :; do
    while :; do
        batch=$(unseen)
        [ -n "$batch" ] || break
        process_batch "$batch"
    done
    if [ -n "${CLOSE_SWEEP_TEST_PAUSE_FILE:-}" ] && [ -e "$CLOSE_SWEEP_TEST_PAUSE_FILE" ]; then
        : > "$CLOSE_SWEEP_TEST_PAUSE_FILE.blocked"
        while [ -e "$CLOSE_SWEEP_TEST_PAUSE_FILE" ]; do sleep 0.2; done
    fi
    flock -u 9 # prim-ok: release between scans, see the lock above
    [ -n "$(unseen)" ] || break
    flock -n 9 || exit 0 # prim-ok: retake after the release, see the lock above
done
now > "$STATE/last"
exit 0
