#!/usr/bin/env bash
# silent-go-merge.sh — merge a GO'd PR whose worker went silent.
#
#   silent-go-merge.sh --doc <chief doc> --workers-from <manifest> --state <file>
#
# Only the worker merges (merge-on-green.sh); the chief only writes the GO file.
# A worker that goes silent after its READY leaves a GO'd PR unmerged. For each
# manifest worker this checks the following, in order, and stops at the first
# that fails:
#   - the newest marker bullet is `READY <pr> <head40> GREEN`, or the last bullet
#     is a hand-off (`handoff` / `hand-off`), no HALTED, BLOCKED, PARKED-*, WRAPPED
#     or MERGED marker is newer than the newest READY, and that READY gives pr and head;
#   - the GO file <GO root>/.locks/go/<pr>.<head> exists and carries head=<head>;
#   - neither the worker doc nor the GO file has been written for
#     CHIEF_WAIT_WORKER_SILENT_MIN minutes (default 45, the waiter's worker-silent bound);
#   - no process carries the doc's stem in its argv, unless the last bullet is a
#     hand-off. Alive and only quiet: one alert, no merge.
# Then ready-check.sh <pr> <head> must PASS, and either print `TRUST-PATH: no` or,
# with `TRUST-PATH: yes`, find a trust-reviewed= line in the GO file.
# If all of that holds, it runs, from the himmel checkout root (the cwd), the bare
# relative form the merge allow rule matches (any other spelling is classifier-denied):
#   bash scripts/handover/merge-on-green.sh <pr> [--jira-transition] --worker-doc <doc> --go <GO file>
# --jira-transition is added only when the worker doc says `completes-ticket: yes`
# above its Results, and no line there says no. merge-on-green.sh and the GO
# verification it runs stay the authority; this only decides when to ask.
#
# Every merge, failed merge or refusal sends one operator alert through the
# waiter's page sender (CHIEF_WAIT_PAGE_CMD, else merge-block-alert's bridge
# send) and appends one bullet to --doc. It also prints the same line on stdout:
#   SILENT-WORKER-MERGE <label> pr=<n> head=<sha> silent=<m>m
#   SILENT-WORKER-MERGE-FAILED <label> pr=<n> head=<sha> rc=<rc>
#   SILENT-WORKER-HELD <label> pr=<n> head=<sha> reason=<alive|ready-check|trust-path|not-checkout-root>
# Each happens once per (worker, pr, head, outcome). --state keeps the keys, so a
# re-arm neither re-merges nor re-alerts. A held worker that later dies still merges.
#
# Exit 0 when it printed a line; 1 when there was nothing new; 2 on a usage error.
# Seams (tests): CHIEF_SILENT_GO_READY_CHECK (replaces ready-check.sh),
# CHIEF_SILENT_GO_PS (prints `<pid> <args>` lines instead of ps).
# CHIEF_SILENT_GO_TIMEOUT bounds the merge (seconds, default 900). On expiry the
# merge is killed and reported as rc=124.
# ponytail: the bound kills a merge-on-green.sh that hangs past it, and the kill can
# land after the merge itself; the FAILED alert then sends a human to look.
# Upgrade path: run the merge detached, and have the next sample read its audit row.
#
# PLATFORM GUARD: the chief kit is Linux-only. bash 3.2-safe.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

doc="" from="" state=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc) doc="${2:-}"; shift 2 || break ;;
        --workers-from) from="${2:-}"; shift 2 || break ;;
        --state) state="${2:-}"; shift 2 || break ;;
        *) echo "usage: silent-go-merge.sh --doc <chief doc> --workers-from <manifest> --state <file>" >&2; exit 2 ;;
    esac
done
[ -n "$doc" ] && [ -n "$from" ] && [ -n "$state" ] || { echo "usage: silent-go-merge.sh --doc <chief doc> --workers-from <manifest> --state <file>" >&2; exit 2; }
[ -f "$from" ] || exit 1

# shellcheck source=../../lib/handover-path.sh
. "$REPO/scripts/lib/handover-path.sh" || exit 2
# shellcheck source=../../lib/go-gate.sh
. "$REPO/scripts/lib/go-gate.sh" || exit 2
# shellcheck source=../../lib/git-clean.sh
. "$REPO/scripts/lib/git-clean.sh" || exit 2
git_env_scrub
go_root="$(go_resolve_root "$REPO" 2>/dev/null)" || exit 1  # swallow-ok: rc is checked, no root merges nothing

bound_min="${CHIEF_WAIT_WORKER_SILENT_MIN:-45}"
case "$bound_min" in ''|*[!0-9]*|???????*) bound_min=45 ;; *) bound_min=$((10#$bound_min)) ;; esac
merge_tmo="${CHIEF_SILENT_GO_TIMEOUT:-900}"
case "$merge_tmo" in ''|*[!0-9]*) merge_tmo=900 ;; esac

alert() { # <line>: one operator page, one chief-doc bullet, one stdout line
    if [ -n "${CHIEF_WAIT_PAGE_CMD:-}" ]; then
        timeout -k 2 45 "$CHIEF_WAIT_PAGE_CMD" "$1" </dev/null >/dev/null 2>&1  # gnu-ok: Linux-only kit
    else
        # shellcheck disable=SC2016  # $1/$2 expand in the child bash
        send='. "$1" && chat="$(_mba_operator_chat)" && [ -n "$chat" ] && _mba_send "$chat" "$2"'
        timeout -k 2 45 bash -c "$send" _ "$REPO/scripts/lib/merge-block-alert.sh" "$1" </dev/null >/dev/null 2>&1  # gnu-ok: Linux-only kit
    fi
    bash "$HERE/append-results.sh" "$doc" "$1" >/dev/null 2>&1 || true  # swallow-ok: the page and stdout line still carry it
    printf '%s\n' "$1"
}
once() { # <key>: succeeds the first time a key is seen, and records it
    grep -qxF -- "$1" "$state" 2>/dev/null && return 1  # swallow-ok: no state file yet reads as unseen
    printf '%s\n' "$1" >> "$state"
}
mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }  # gnu-ok: Linux-only kit  # swallow-ok: both files were just tested to exist; 0 only lengthens silence of a vanished file, and merge-on-green re-verifies the GO
alive() { # <doc>: a process carries the doc's stem in its argv; an unreadable table counts as alive
    local stem="${1##*/}" table
    stem="${stem%.md}"; stem="${stem%-RESUME}"
    if [ -n "${CHIEF_SILENT_GO_PS:-}" ]; then
        table="$(bash "$CHIEF_SILENT_GO_PS")" || return 0
    else
        table="$(ps -ww -eo pid=,args=)" || return 0
    fi
    [ -n "$table" ] || return 0
    printf '%s\n' "$table" | awk -v me="$$" -v s="$stem" '$1 != me && index($0, s) { f = 1 } END { exit !f }'
}

workers="$(jq -r '(.workers // [])[]? | [.label, .doc] | @tsv' "$from" 2>/dev/null)" || exit 1  # swallow-ok: rc is checked, an unreadable manifest merges nothing
acted=0
now="$(date +%s)"
while IFS=$'\t' read -r label wdoc; do
    [ -n "$label" ] && [ -f "$wdoc" ] || continue
    marker="$(grep -E '^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?(LIVE|FINDING|RESOLVED|READY|BLOCKED|HALTED|WRAPPED|PARKED-BANK|PARKED-USAGE|RESUMED|MERGED)([^A-Za-z0-9_]|$)' "$wdoc" | tail -n 1)"
    last="$(grep -E '^- ' "$wdoc" | tail -n 1)"
    handoff=0
    printf '%s\n' "$last" | grep -qiE 'hand-?off' \
        && ! printf '%s\n' "$last" | grep -qiE "(no|not|never|without|cannot|can't)[[:space:]]+(a[[:space:]]+|the[[:space:]]+)?hand-?off" \
        && handoff=1
    if [ "$handoff" -eq 1 ]; then
        # The waiver holds only when no stop marker is newer than the newest READY.
        ready_ln="$(grep -nE '^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?READY[[:space:]]' "$wdoc" | tail -n 1 | cut -d: -f1)"
        stop_ln="$(grep -nE '^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?(HALTED|BLOCKED|PARKED-[A-Z]+|WRAPPED|MERGED)([^A-Za-z0-9_]|$)' "$wdoc" | tail -n 1 | cut -d: -f1)"
        if [ -n "$ready_ln" ] && [ "${stop_ln:-0}" -lt "$ready_ln" ]; then
            marker="$(sed -n "${ready_ln}p" "$wdoc")"
        else
            handoff=0
        fi
    fi
    rest="$(printf '%s\n' "$marker" | sed -E 's/^- ([0-9]{1,2}:[0-9]{2} )?(\*\*)?//')"
    [[ $rest =~ ^READY[[:space:]]+#?([0-9]+)[[:space:]]+([0-9a-f]{40})[[:space:]]+GREEN([^A-Za-z0-9_]|$) ]] || continue
    pr="${BASH_REMATCH[1]}"; head="${BASH_REMATCH[2]}"
    gofile="$go_root/.locks/go/$pr.$head"
    if [ ! -f "$gofile" ] || ! grep -qxF "head=$head" "$gofile"; then continue; fi
    dm="$(mtime "$wdoc")"; gm="$(mtime "$gofile")"
    [ "$gm" -gt "$dm" ] && dm="$gm"
    silent=$(( (now - dm) / 60 ))
    [ "$silent" -ge "$bound_min" ] || continue
    id="SILENT-WORKER-HELD $label pr=$pr head=$head"
    if [ "$handoff" -eq 0 ] && alive "$wdoc"; then
        once "$label $pr $head alive" && { alert "$id reason=alive: silent ${silent}m after its GO but its process is alive, not merged"; acted=1; }
        continue
    fi
    rc_out="$(timeout -k 5 150 bash "${CHIEF_SILENT_GO_READY_CHECK:-$HERE/ready-check.sh}" --observe "$pr" "$head" </dev/null 2>&1)"; rcc=$?  # gnu-ok: Linux-only kit
    if [ "$rcc" -ne 0 ]; then
        once "$label $pr $head ready-check" && { alert "$id reason=ready-check: ready-check rc=$rcc at the GO head, not merged"; acted=1; }
        continue
    fi
    trust="$(printf '%s\n' "$rc_out" | sed -n 's/^TRUST-PATH: //p' | tail -n 1)"
    if [ "$trust" != no ] && ! { [ "$trust" = yes ] && grep -qE '^trust-reviewed=.' "$gofile"; }; then
        once "$label $pr $head trust-path" && { alert "$id reason=trust-path: TRUST-PATH=${trust:-unknown} and the GO is not trust-reviewed, not merged"; acted=1; }
        continue
    fi
    top="$(git rev-parse --show-toplevel 2>/dev/null)"  # swallow-ok: outside a checkout reads as empty, which refuses
    if [ "$top" != "$(pwd -P)" ] || [ ! -f scripts/handover/merge-on-green.sh ]; then
        once "$label $pr $head not-checkout-root" && { alert "$id reason=not-checkout-root: the waiter does not run from a himmel checkout root, not merged"; acted=1; }
        continue
    fi
    once "$label $pr $head merge" || continue
    jt=""
    comp="$(sed '/^## Results/q' "$wdoc" | grep -ioE 'completes[- ]ticket:?[*[:space:]]*:?[[:space:]]*(yes|no)' | grep -ioE '(yes|no)$')"
    printf '%s\n' "$comp" | grep -qix yes && ! printf '%s\n' "$comp" | grep -qix no && jt="--jira-transition"
    # The bare relative form, bounded here rather than by a timeout prefix.
    # shellcheck disable=SC2086  # $jt is empty or one flag
    bash scripts/handover/merge-on-green.sh "$pr" $jt --worker-doc "$wdoc" --go "$gofile" </dev/null >/dev/null 2>&1 &
    mpid=$!
    end=$(( $(date +%s) + merge_tmo ))
    while kill -0 "$mpid" 2>/dev/null && [ "$(date +%s)" -lt "$end" ]; do sleep 1; done
    if kill -0 "$mpid" 2>/dev/null; then kill "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null; mrc=124; else wait "$mpid"; mrc=$?; fi
    if [ "$mrc" -eq 0 ]; then
        alert "SILENT-WORKER-MERGE $label pr=$pr head=$head silent=${silent}m: the worker went silent after its GO; the chief's waiter merged it through merge-on-green.sh --go"
    else
        alert "SILENT-WORKER-MERGE-FAILED $label pr=$pr head=$head rc=$mrc: the worker went silent after its GO; merge-on-green.sh refused or failed, merge it by hand"
    fi
    acted=1
done <<EOF
$workers
EOF
[ "$acted" -eq 1 ]
