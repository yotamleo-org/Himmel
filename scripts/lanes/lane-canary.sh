#!/usr/bin/env bash
# scripts/lanes/lane-canary.sh - lane canary.
#
# Launches ONE tiny no-op leg per lane through headed-arm-leg.sh (the real
# launch path: profile, proxy, permission config) and reports PASS / FAIL /
# SKIP plus time-to-first-bullet per lane. The unit suites check the generated
# command; this checks that a leg on the lane actually starts, registers,
# receives its brief and writes a Results bullet.
#
# Usage: lane-canary.sh [--lanes native,claudex,openrouter,deepseek]
#                       [--timeout <sec>] [--out <report.json>] [--dry-run]
# Defaults: every lane the launcher supports, 300 s per lane, report at
# <handover root>/.canary/latest.json (the file the board reads).
#
# Per lane: render docs/handover/lane-canary-brief-template.md into
# <root>/.canary/, launch it detached, poll the doc every CANARY_POLL_SEC for a
# LIVE bullet (first bullet) and a WRAPPED bullet, then close the window with
# close-wrapped-leg.sh. A leg that never wraps gets a runner-written WRAPPED
# bullet and a forced lock release first, so no window or lock outlives the
# run. Lanes run one at a time: the canary never adds more than one leg.
#
# Cheapest model per lane: native pins claude-haiku-5-5; the other lanes take
# the launcher's own default (gpt-6.1-sol on claudex, the lane's pinned slug).
# A lane whose backend is not configured here (no key, no launcher) is SKIP,
# never FAIL. Exit 0 when nothing FAILed, 1 otherwise, 2 usage.
#
# Seams (the suite drives all of them): CANARY_LAUNCHER, CANARY_CLOSER,
# CANARY_LOCK, CANARY_APPEND, CANARY_ROOT, CANARY_REPO, CANARY_DOTENV,
# CANARY_POLL_SEC, CANARY_TIMEOUT, CANARY_LOCK_WAIT.
# Platform: POSIX bash 3.2+ (the launcher itself needs konsole: Linux/KDE).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_REPO="$(cd "$HERE/../.." && pwd)"
KIT="$SELF_REPO/scripts/handover/console-kit"

LANES="native,claudex,openrouter,deepseek"
TIMEOUT="${CANARY_TIMEOUT:-300}"
POLL="${CANARY_POLL_SEC:-2}"
LOCK_WAIT="${CANARY_LOCK_WAIT:-60}"
OUT=""
DRY=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --lanes|--timeout|--out) [ "$#" -ge 2 ] || { echo "lane-canary: $1 needs a value" >&2; exit 2; } ;;
    esac
    case "$1" in
        --lanes) LANES="${2:-}"; shift 2 ;;
        --timeout) TIMEOUT="${2:-}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) echo "usage: lane-canary.sh [--lanes a,b] [--timeout sec] [--out file] [--dry-run]" >&2; exit 2 ;;
    esac
done
case "$TIMEOUT" in ''|*[!0-9]*) echo "lane-canary: --timeout must be whole seconds" >&2; exit 2 ;; esac
case "$LANES" in ''|,*|*,|*,,*|*[!a-z,]*) echo "lane-canary: --lanes must be a comma list of lane names" >&2; exit 2 ;; esac
case "$POLL" in ''|*[!0-9]*) echo "lane-canary: CANARY_POLL_SEC must be a positive whole number" >&2; exit 2 ;; esac
POLL=$((10#$POLL))
[ "$POLL" -gt 0 ] || { echo "lane-canary: CANARY_POLL_SEC must be a positive whole number" >&2; exit 2; }

LAUNCHER="${CANARY_LAUNCHER:-$KIT/headed-arm-leg.sh}"
CLOSER="${CANARY_CLOSER:-$KIT/close-wrapped-leg.sh}"
LOCK="${CANARY_LOCK:-$SELF_REPO/scripts/handover/queue-lock.sh}"
APPEND="${CANARY_APPEND:-$KIT/append-results.sh}"
TEMPLATE="$SELF_REPO/docs/handover/lane-canary-brief-template.md"

# The leg runs from the PRIMARY checkout: close-wrapped-leg.sh prunes any
# .claude/worktrees path the doc names, so a worktree cwd would be pruned.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
if [ -n "${CANARY_REPO:-}" ]; then
    REPO="$CANARY_REPO"
else
    common="$(git -C "$SELF_REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    REPO="${common%/.git}"
    [ -n "$REPO" ] && [ -d "$REPO" ] || REPO="$SELF_REPO"
fi
DOTENV="${CANARY_DOTENV:-$REPO/.env}"

if [ -n "${CANARY_ROOT:-}" ]; then
    ROOT="$CANARY_ROOT"
else
    # shellcheck source=../lib/handover-path.sh
    . "$SELF_REPO/scripts/lib/handover-path.sh"
    ROOT="$(handover_root)/.canary"
fi
[ -n "$OUT" ] || OUT="$ROOT/latest.json"
mkdir -p "$ROOT" || { echo "lane-canary: cannot create $ROOT" >&2; exit 2; }
STAMP="$(date +%Y%m%d-%H%M%S)-$$"

# lane_unconfigured <lane>: prints why the lane cannot run here, empty if it can.
lane_unconfigured() {
    case "$1" in
        native) ;;
        claudex) [ -f "$REPO/scripts/claude-codex" ] || echo "no scripts/claude-codex" ;;
        openrouter) _key_present OPENROUTER_API_KEY || echo "OPENROUTER_API_KEY not set" ;;
        deepseek) _key_present DEEPSEEK_API_KEY || echo "DEEPSEEK_API_KEY not set" ;;
        *) echo "unknown lane" ;;
    esac
}
# _key_present NAME: set non-empty in the env or defined in the repo .env
# (the name is tested, the value is never read out).
_key_present() {
    eval "[ -n \"\${$1:-}\" ]" && return 0
    [ -f "$DOTENV" ] && grep -Eq "^(export )?$1=.+" "$DOTENV"
}

# lane_model <lane>: the cheapest model the lane offers ('' = launcher default).
lane_model() {
    case "$1" in native) echo claude-haiku-5-5 ;; *) echo "" ;; esac
}

# doc_has <doc> <MARKER>: a Results bullet that STARTS with the marker (the
# brief text itself names WRAPPED, so a bare grep would match the instructions).
doc_has() { grep -Eq "^- [0-9]{2}:[0-9]{2} $2( |$)" "$1" 2>/dev/null; }

lock_free() { [ "$(bash "$LOCK" status "$1" 2>/dev/null | tail -1)" = "free" ]; }

now() { date +%s; }

# run_lane <lane>: prints "<result>|<first-bullet-s>|<wrapped-s>|<detail>".
run_lane() {
    lane="$1"
    why="$(lane_unconfigured "$lane")"
    if [ -n "$why" ]; then echo "SKIP|||not configured: $why"; return; fi
    if [ "$DRY" -eq 1 ]; then echo "SKIP|||dry-run: would launch $lane model=$(lane_model "$lane")"; return; fi

    name="lane-canary-$lane-$STAMP"
    doc="$ROOT/$name.md"
    repo_e="$(printf '%s' "$REPO" | sed -e 's/[\\&|]/\\&/g')"
    doc_e="$(printf '%s' "$doc" | sed -e 's/[\\&|]/\\&/g')"
    sed -e "s|@REPO@|$repo_e|g" -e "s|@LANE@|$lane|g" -e "s|@STAMP@|$STAMP|g" -e "s|@DOC@|$doc_e|g" \
        "$TEMPLATE" > "$doc" || { echo "FAIL|||cannot render brief"; return; }

    model="$(lane_model "$lane")"
    start="$(now)"
    # The window inherits the launcher's cwd, so launch from $REPO (the
    # primary checkout, whose trust the operator already granted).
    # shellcheck disable=SC2086  # $model is one word or empty by construction
    (cd "$REPO" && exec setsid nohup bash "$LAUNCHER" --profile leg-impl --lane "$lane" "$name" "$doc" \
        "$ROOT/$name.signal" "$((start + 5))" "$ROOT/$name.log" $model >/dev/null 2>&1) &
    lpid=$!

    first=""; wrapped=""; lrc=""
    while :; do
        t=$(( $(now) - start ))
        [ -z "$first" ] && doc_has "$doc" LIVE && first="$t"
        if doc_has "$doc" WRAPPED; then
            wrapped="$t"
            # LIVE may have landed between the two reads above
            [ -z "$first" ] && doc_has "$doc" LIVE && first="$t"
            break
        fi
        if [ -z "$lrc" ] && ! kill -0 "$lpid" 2>/dev/null; then
            wait "$lpid"; lrc=$?
            if [ "$lrc" -ne 0 ] && [ -z "$first" ]; then break; fi
        fi
        [ "$t" -ge "$TIMEOUT" ] && break
        sleep "$POLL"
    done

    result=PASS; detail=""
    if [ -z "$wrapped" ]; then
        result=FAIL
        if [ -n "$lrc" ] && [ "$lrc" -ne 0 ] && [ -z "$first" ]; then detail="launcher exit $lrc before any bullet"
        elif [ -z "$first" ]; then detail="no first bullet within ${TIMEOUT}s"
        else detail="first bullet but no WRAPPED within ${TIMEOUT}s"; fi
        # nothing may outlive the run: stop a launcher still starting (it would
        # open its window after the closer ran), write the wrap, drop the lock.
        if kill -0 "$lpid" 2>/dev/null; then
            kill "$lpid" 2>/dev/null; sleep 1
            kill -KILL "$lpid" 2>/dev/null
        fi
        wait "$lpid" 2>/dev/null
        bash "$APPEND" "$doc" "WRAPPED — canary runner closed a leg that did not wrap ($detail)" >/dev/null 2>&1
        QUEUE_LOCK_FORCE_RELEASE=1 bash "$LOCK" release "$doc" >/dev/null 2>&1
    else
        if [ -z "$first" ]; then
            result=FAIL; detail="WRAPPED bullet but no LIVE first bullet"
        fi
        waited=0
        while ! lock_free "$doc" && [ "$waited" -lt "$LOCK_WAIT" ]; do sleep "$POLL"; waited=$((waited + 10#$POLL)); done
        if ! lock_free "$doc"; then
            result=FAIL
            detail="${detail:+$detail; }wrapped but queue lock still held after ${LOCK_WAIT}s"
            QUEUE_LOCK_FORCE_RELEASE=1 bash "$LOCK" release "$doc" >/dev/null 2>&1
        fi
    fi
    if ! bash "$CLOSER" "$doc" >/dev/null 2>&1; then
        result=FAIL
        detail="${detail:+$detail; }window not closed (close-wrapped-leg refused)"
    fi
    # a PASS leaves nothing to diagnose; a FAIL keeps its doc and launch log.
    [ "$result" = PASS ] && [ -z "$detail" ] && rm -f "$ROOT/$name".*
    echo "$result|$first|$wrapped|$detail"
}

json_str() { printf '%s' "$1" | tr -c 'A-Za-z0-9 _.:=,;()/+-' '?' ; }

rows=""; any_fail=0
printf '%-10s %-5s %-10s %-10s %s\n' LANE RESULT FIRST-S WRAPPED-S DETAIL
OLDIFS="$IFS"; IFS=','
for lane in $LANES; do
    IFS="$OLDIFS"
    line="$(run_lane "$lane")"
    result="${line%%|*}"; rest="${line#*|}"
    first="${rest%%|*}"; rest="${rest#*|}"
    wrapped="${rest%%|*}"; detail="${rest#*|}"
    [ "$result" = FAIL ] && any_fail=1
    printf '%-10s %-5s %-10s %-10s %s\n' "$lane" "$result" "${first:--}" "${wrapped:--}" "$detail"
    row="\"$lane\":{\"result\":\"$result\",\"first_bullet_s\":${first:-null},\"wrapped_s\":${wrapped:-null},\"detail\":\"$(json_str "$detail")\"}"
    rows="${rows:+$rows,}$row"
    IFS=','
done
IFS="$OLDIFS"

if [ "$DRY" -eq 0 ]; then
    tmp="$OUT.tmp.$$"
    if printf '{"ts":"%s","host":"%s","lanes":{%s}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_str "$(hostname)")" "$rows" > "$tmp" \
        && mv "$tmp" "$OUT"; then  # prim-ok: the temp is named by PID and takes the umask mode; atomic_write would reset it to 0600
        echo "lane-canary: report $OUT"
    else
        echo "lane-canary: cannot write report $OUT" >&2; any_fail=1
    fi
fi
exit "$any_fail"
