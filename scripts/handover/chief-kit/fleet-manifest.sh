#!/usr/bin/env bash
# fleet-manifest.sh — The one writer for a chief's fleet
# manifest: the JSON file `tick.sh --workers-from` (and so chief-wait.sh) reads
# on every sample, so a dispatch or a wrap edits one file instead of the chief
# restarting its waiter with a new 10-15 path --workers argv.
#
#   fleet-manifest.sh add    <manifest> <worker doc>... --lane <lane> [--lockless] [--arm 200k|400k]
#   fleet-manifest.sh remove <manifest> <worker doc | label>...
#   fleet-manifest.sh list   <manifest>                      one doc per line
#   fleet-manifest.sh watch  <manifest> add    <pr> [--repo <owner/name>] [--head <sha>] [--comments <n>] [--reviews <n>] [--state open|closed|merged]
#   fleet-manifest.sh watch  <manifest> set    <pr> [--repo <owner/name>] [same seen-values]   (an existing row only)
#   fleet-manifest.sh watch  <manifest> remove <pr> [--repo <owner/name>]
#   fleet-manifest.sh watch  <manifest> list                 pr<TAB>head<TAB>comments<TAB>reviews<TAB>repo<TAB>state, `-` for unset
#
# watch: one row per outside PR a worker no longer waits on, keyed by PR number and repo (no --repo =
# the waiter's own repository) -- the head sha, the comment count (issue + review comments), the
# review count and the state (open, closed or merged) last seen. chief-wait.sh
# polls each row over REST and wakes `WAKE pr-watch <pr> ...` when one differs, then `watch set`s the
# row so the same change never wakes twice. The rows live in the top-level `watch` array, a key the
# writer carries through every rewrite untouched, so schema 1 stays valid, every reader of `workers`
# is unchanged, and a successor chief that inherits the manifest inherits the rows with no re-arm.
# A count or head left off a row is a silent baseline on the first poll.
#
# Location: next to the chief doc, named after it —
# <chief doc stem>.fleet.json.
#
# Schema 1:
#   {"schema": 1,
#    "workers": [{"doc": "<absolute worker doc>", "label": "N<k>", "added": "<ISO-8601>"}]}
# Every write emits `workers` and drops the pre-rename `legs` array, so an old manifest is
# rewritten on its next add/remove with the same entries in the same order. The readers still
# take `legs` while legacy names are on (scripts/lib/legacy-names.sh).
# add requires --lane (native|claudex|openrouter|deepseek; a missing one is a usage error,
# rc 2, before any lock or write) and stores it, and with --lockless stores `lockless: true`
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
usage: fleet-manifest.sh add    <manifest> <worker doc>... --lane <lane> [--lockless] [--arm 200k|400k]
       fleet-manifest.sh remove <manifest> <worker doc | label>...
       fleet-manifest.sh list   <manifest>
       fleet-manifest.sh watch  <manifest> add|set <pr> [--repo <owner/name>] [--head <sha>] [--comments <n>] [--reviews <n>] [--state open|closed|merged]
       fleet-manifest.sh watch  <manifest> remove <pr> [--repo <owner/name>]
       fleet-manifest.sh watch  <manifest> list
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

wsub=""; wpr=""; whead=""; wcom=""; wrev=""; wrepo=""; wstate=""
if [ "$verb" = watch ]; then
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    wsub="$1"; shift
    case "$wsub" in
        list) [ "$#" -eq 0 ] || { usage >&2; exit 2; } ;;
        add|set|remove)
            [ "$#" -ge 1 ] || { usage >&2; exit 2; }
            wpr="$1"; shift
            case "$wpr" in ''|*[!0-9]*|0*) echo "fleet-manifest: watch needs a PR number: $wpr" >&2; exit 2 ;; esac
            while [ "$#" -gt 0 ]; do
                [ "$#" -ge 2 ] || { usage >&2; exit 2; }
                [ "$wsub" != remove ] || [ "$1" = --repo ] || { usage >&2; exit 2; }
                case "$1" in
                    --state) case "$2" in open|closed|merged) wstate="$2" ;; *) echo "fleet-manifest: --state must be open, closed or merged: $2" >&2; exit 2 ;; esac ;;
                    --head) case "$2" in ''|*[!0-9a-f]*) echo "fleet-manifest: --head must be a lowercase hex sha: $2" >&2; exit 2 ;; esac; whead="$2" ;;
                    --comments) case "$2" in ''|*[!0-9]*) echo "fleet-manifest: --comments must be a count: $2" >&2; exit 2 ;; esac; wcom="$2" ;;
                    --reviews) case "$2" in ''|*[!0-9]*) echo "fleet-manifest: --reviews must be a count: $2" >&2; exit 2 ;; esac; wrev="$2" ;;
                    --repo) case "$2" in
                                */*/*|*[!A-Za-z0-9_./-]*) echo "fleet-manifest: --repo must be owner/name: $2" >&2; exit 2 ;;
                                [A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*) wrepo="$2" ;;
                                *) echo "fleet-manifest: --repo must be owner/name: $2" >&2; exit 2 ;;
                            esac ;;
                    *) usage >&2; exit 2 ;;
                esac
                shift 2
            done ;;
        *) usage >&2; exit 2 ;;
    esac
    if [ "$wsub" = list ]; then
        if ! jq -e -s "$VALID" "$manifest" >/dev/null 2>&1; then
            echo "fleet-manifest: not a schema-1 fleet manifest: $manifest" >&2
            exit 1
        fi
        jq -r '(.watch // [])[] | [.pr, (.head // "-"), (.comments // "-"), (.reviews // "-"), (.repo // "-"), (.state // "-")] | @tsv' "$manifest"
        exit $?
    fi
    set -- watch
fi

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
    watch) ;;
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
    if [ "$lane_given" != true ]; then
        echo "fleet-manifest: add requires --lane <lane> (the lane the worker was launched on: native, claudex, openrouter or deepseek); a row with no lane reads unknown and the handover refuses to relay it" >&2
        exit 2
    fi
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

wk=workers
if [ -e "$manifest" ]; then
    if ! jq -e -s "$VALID" "$manifest" >/dev/null 2>&1; then
        echo "fleet-manifest: refusing to rewrite an invalid manifest: $manifest" >&2
        exit 1
    fi
    # every write says `workers` and drops the pre-rename `legs`: an old manifest keeps its entries and order
    # (`workers` wins when a manifest holds both, as it does for the readers)
    cur="$(jq 'if has("legs") then .workers = (.workers // .legs) | del(.legs) else . end' "$manifest")" || exit 1
else
    cur="{\"schema\":1,\"$wk\":[]}"
fi

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for arg in "$@"; do
    if [ "$verb" = watch ]; then
        case "$wsub" in
            remove)
                cur="$(printf '%s\n' "$cur" | jq --argjson p "$wpr" --arg rp "$wrepo" \
                    'if has("watch") then .watch |= map(select((.pr == $p and ((.repo // "") == $rp)) | not)) else . end')" || exit 1 ;;
            add|set)
                cur="$(printf '%s\n' "$cur" | jq --argjson p "$wpr" --arg sub "$wsub" --arg t "$now" --arg h "$whead" --arg c "$wcom" --arg r "$wrev" --arg rp "$wrepo" --arg st "$wstate" \
                    '({} + (if $h != "" then {head: $h} else {} end) + (if $c != "" then {comments: ($c | tonumber)} else {} end)
                        + (if $r != "" then {reviews: ($r | tonumber)} else {} end) + (if $st != "" then {state: $st} else {} end)
                        + (if $rp != "" then {repo: $rp} else {} end)) as $f
                    | def mine: .pr == $p and ((.repo // "") == $rp);
                    (.watch // []) as $w
                    | .watch = (if any($w[]; mine) then ($w | map(if mine then . + $f else . end))
                                elif $sub == "add" then $w + [{pr: $p, added: $t} + $f]
                                else $w end)')" || exit 1 ;;
        esac
    elif [ "$verb" = add ]; then
        label="$(worker_label "$arg")"
        # Re-adding a listed doc never rewrites its row: flags that would change the
        # stored lane or lockless are refused, not silently ignored.
        conflict="$(printf '%s\n' "$cur" | jq -r --arg wk "$wk" --arg d "$arg" --arg ln "$lane" --argjson lg "$lane_given" --argjson ll "$lockless" --arg ar "$arm" \
            '[.[$wk][] | select(.doc == $d) | select(($lg and ((.lane // "unknown") != $ln)) or ($ll and (.lockless != true)) or ($ar != "" and ((.arm // "") != $ar)))] | length')" || exit 1
        if [ "$conflict" -gt 0 ]; then
            echo "fleet-manifest: $arg is already listed with a different lane/lockless/arm; remove it first, then add it again: $arg" >&2
            exit 1
        fi
        cur="$(printf '%s\n' "$cur" | jq --arg wk "$wk" --arg d "$arg" --arg l "$label" --arg t "$now" --arg ln "$lane" --argjson ll "$lockless" --arg ar "$arm" \
            'if any(.[$wk][]; .doc == $d) then . else .[$wk] += [{doc: $d, label: $l, added: $t, lane: $ln} + (if $ll then {lockless: true} else {} end) + (if $ar != "" then {arm: $ar} else {} end)] end')" || exit 1
    else
        cur="$(printf '%s\n' "$cur" | jq --arg wk "$wk" --arg a "$arg" \
            '.[$wk] |= map(select(.doc != $a and .label != $a))')" || exit 1
    fi
done

if ! printf '%s\n' "$cur" | atomic_write "$manifest"; then
    echo "fleet-manifest: cannot write $manifest" >&2
    exit 1
fi
