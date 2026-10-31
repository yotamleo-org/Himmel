#!/usr/bin/env bash
# fleet-manifest.sh — The one writer for a chief's fleet
# manifest: the JSON file `tick.sh --workers-from` (and so chief-wait.sh) reads
# on every sample, so a dispatch or a wrap edits one file instead of the chief
# restarting its waiter with a new 10-15 path --workers argv.
#
#   fleet-manifest.sh add    <manifest> <worker doc>... [--lane <lane>] [--lockless] [--arm 200k|400k]
#   fleet-manifest.sh remove <manifest> <worker doc | label>...
#   fleet-manifest.sh list   <manifest>                      one doc per line
#
# Location: next to the chief doc, named after it —
# <chief doc stem>.fleet.json.
#
# Schema 1:
#   {"schema": 1,
#    "legs": [{"doc": "<absolute worker doc>", "label": "N<k>", "added": "<ISO-8601>"}]}
# add also stores `lane` (native|claudex|deepseek|api|...; a missing
# --lane is stored `unknown`, never guessed) and, with --lockless, `lockless: true`
# (an eval/pilot row that holds no queue lock: tick reports NOLOCK and judges it by
# tail marker only). A manifest written before this carries neither key and reads
# as lane `unknown`, not lockless. A doc already listed is left alone, flags and all.
# add also stores an optional `arm` (200k|400k, the autocompact A/B
# arm the worker launched on); a worker added with no --arm carries no `arm` key.
# Only `workers[].doc` drives tick; label (worker-identity.sh's N<k>) is what remove
# matches and what a human reads. Any other key, top-level or per worker, is
# carried through every rewrite untouched, so a wider worker manifest
# (chains, lanes, write-sets) can grow in the same object.
#
# add is idempotent (a doc already listed is left alone); removing a worker that is
# not listed is not an error. A doc must be absolute: tick resolves a relative
# one against the handover root, the writer's cwd would be a different one. It
# must also carry no whitespace or glob character, which tick's word-split worker
# list cannot hold.
#
# Writes hold an exclusive flock on <manifest>.lock and replace the file with a
# temp file renamed into place in the same directory (the inbox-send.sh
# pattern), so two dispatches at once lose no entry and a reader never sees a
# torn file. An existing manifest that is not valid schema-1 JSON is refused,
# never overwritten.
#
# Exit: 0 ok; 1 missing/invalid manifest, lock or write failure; 2 usage.
#
# PLATFORM GUARD: the chief kit is Linux-only
# (util-linux flock). bash 3.2-safe; needs jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/prim.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/prim.sh" || exit 2
# shellcheck source=../../lib/worker-identity.sh
. "$HERE/../../lib/worker-identity.sh"
# shellcheck source=../../lib/legacy-names.sh
. "$HERE/../../lib/legacy-names.sh"
# the worker array is `workers`; a manifest not yet rewritten holds the pre-rename `legs`, read only while legacy names are on
if legacy_names_on; then JQ_W='def W: (.workers // .legs);'; else JQ_W='def W: .workers;'; fi

usage() {
    cat <<'USAGE'
usage: fleet-manifest.sh add    <manifest> <worker doc>... [--lane <lane>] [--lockless] [--arm 200k|400k]
       fleet-manifest.sh remove <manifest> <worker doc | label>...
       fleet-manifest.sh list   <manifest>
USAGE
}

# Every worker's doc is an absolute path with no whitespace or glob character:
# tick word-splits its worker list, so anything else would silently shrink the
# fleet it judges. Run with `jq -s`: the file must hold exactly one top-level
# value — jq reads a stream, so two concatenated objects would
# otherwise pass per value and list/add would act on a multi-object file.
VALID="$JQ_W"'length == 1 and (.[0] | type == "object" and .schema == 1 and (W | type == "array")
    and all(W[]; type == "object" and (.doc | type == "string" and test("^/[^[:space:]*?\\[]+$"))))'

[ "$#" -ge 2 ] || { usage >&2; exit 2; }
verb="$1"; manifest="$2"; shift 2

case "$verb" in
    list)
        [ "$#" -eq 0 ] || { usage >&2; exit 2; }
        if ! jq -e -s "$VALID" "$manifest" >/dev/null 2>&1; then
            echo "fleet-manifest: not a schema-1 fleet manifest: $manifest" >&2
            exit 1
        fi
        jq -r "$JQ_W"'W[].doc' "$manifest"
        exit $?
        ;;
    add|remove) [ "$#" -ge 1 ] || { usage >&2; exit 2; } ;;
    *) usage >&2; exit 2 ;;
esac

lane=unknown; lockless=false; lane_given=false; arm=""
if [ "$verb" = add ]; then
    # --lane/--lockless may sit anywhere among the docs; the docs are re-collected
    # one per line so a doc with whitespace is refused below, not word-split.
    docs_only=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --lane)
                [ "$#" -ge 2 ] || { usage >&2; exit 2; }
                case "$2" in
                    ''|[!a-z0-9]*|*[!a-z0-9._-]*) echo "fleet-manifest: --lane must be a lowercase word (native, claudex, deepseek, api, ...): $2" >&2; exit 2 ;;
                esac
                lane="$2"; lane_given=true; shift 2 ;;
            --lockless) lockless=true; shift ;;
            --arm)
                [ "$#" -ge 2 ] || { usage >&2; exit 2; }
                case "$2" in
                    200k|400k) arm="$2" ;;
                    *) echo "fleet-manifest: --arm must be 200k or 400k: $2" >&2; exit 2 ;;
                esac
                shift 2 ;;
            *)
                case "$1" in
                    *$'\n'*) echo "fleet-manifest: worker doc must not contain a newline: $1" >&2; exit 2 ;;
                esac
                docs_only="$docs_only$1"$'\n'; shift ;;
        esac
    done
    set --
    while IFS= read -r d; do [ -z "$d" ] || set -- "$@" "$d"; done <<EOD
$docs_only
EOD
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    for doc in "$@"; do
        case "$doc" in
            /*) ;;
            *) echo "fleet-manifest: worker doc must be an absolute path: $doc" >&2; exit 2 ;;
        esac
        case "$doc" in
            *[[:space:]]*|*'*'*|*'?'*|*'['*)
                echo "fleet-manifest: worker doc must not contain whitespace or a glob character (tick word-splits it): $doc" >&2
                exit 2 ;;
        esac
    done
fi

# prim-ok: a 30 s bounded flock held on fd 9 for the rest of the script; with_lock waits without limit and wraps one command
if ! exec 9>>"$manifest.lock" || ! flock -x -w 30 9; then  # gnu-ok: Linux-only kit (util-linux flock, PLATFORM GUARD)
    echo "fleet-manifest: cannot lock $manifest.lock" >&2
    exit 1
fi

if [ -e "$manifest" ]; then
    if ! jq -e -s "$VALID" "$manifest" >/dev/null 2>&1; then
        echo "fleet-manifest: refusing to rewrite an invalid manifest: $manifest" >&2
        exit 1
    fi
    cur="$(cat "$manifest")" || exit 1
else
    cur='{"schema":1,"legs":[]}'
fi

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for arg in "$@"; do
    if [ "$verb" = add ]; then
        label="$(worker_label "$arg")"
        # Re-adding a listed doc never rewrites its row: flags that would change the
        # stored lane or lockless are refused, not silently ignored.
        conflict="$(printf '%s\n' "$cur" | jq -r --arg d "$arg" --arg ln "$lane" --argjson lg "$lane_given" --argjson ll "$lockless" --arg ar "$arm" \
            '[.legs[] | select(.doc == $d) | select(($lg and ((.lane // "unknown") != $ln)) or ($ll and (.lockless != true)) or ($ar != "" and ((.arm // "") != $ar)))] | length')" || exit 1
        if [ "$conflict" -gt 0 ]; then
            echo "fleet-manifest: $arg is already listed with a different lane/lockless/arm; remove it first, then add it again: $arg" >&2
            exit 1
        fi
        cur="$(printf '%s\n' "$cur" | jq --arg d "$arg" --arg l "$label" --arg t "$now" --arg ln "$lane" --argjson ll "$lockless" --arg ar "$arm" \
            'if any(.legs[]; .doc == $d) then . else .legs += [{doc: $d, label: $l, added: $t, lane: $ln} + (if $ll then {lockless: true} else {} end) + (if $ar != "" then {arm: $ar} else {} end)] end')" || exit 1
    else
        cur="$(printf '%s\n' "$cur" | jq --arg a "$arg" \
            '.legs |= map(select(.doc != $a and .label != $a))')" || exit 1
    fi
done

if ! printf '%s\n' "$cur" | atomic_write "$manifest"; then
    echo "fleet-manifest: cannot write $manifest" >&2
    exit 1
fi
