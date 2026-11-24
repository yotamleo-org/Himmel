#!/usr/bin/env bash
# fleet-manifest.sh — The one writer for a chief's fleet
# manifest: the JSON file `tick.sh --workers-from` (and so chief-wait.sh) reads
# on every sample, so a dispatch or a wrap edits one file instead of the chief
# restarting its waiter with a new 10-15 path --workers argv.
#
#   fleet-manifest.sh add    <manifest> <worker doc>... --lane <lane> [--pending] [--lockless] [--arm 200k|400k]
#   fleet-manifest.sh remove <manifest> <worker doc | label>...
#   fleet-manifest.sh list   <manifest>                      one doc per line
#   fleet-manifest.sh watch  <manifest> add    <pr> [--repo <owner/name>] [--head <sha>] [--comments <n>] [--reviews <n>] [--state open|closed|merged]
#   fleet-manifest.sh watch  <manifest> set    <pr> [--repo <owner/name>] [same seen-values]   (an existing row only)
#   fleet-manifest.sh watch  <manifest> remove <pr> [--repo <owner/name>]
#   fleet-manifest.sh watch  <manifest> list                 pr<TAB>head<TAB>comments<TAB>reviews<TAB>repo<TAB>state, `-` for unset
#   fleet-manifest.sh control init <manifest> --target N
#   fleet-manifest.sh control show <manifest>
#   fleet-manifest.sh control set <manifest> --mode paused|shadow|active [--target N] --expect-gen G
#   fleet-manifest.sh attempt bind <manifest> <doc> --attempt-id A
#   fleet-manifest.sh attempt settle <manifest> <doc> --attempt-id A --phase launched|refused|unknown
#   fleet-manifest.sh runtime settle --manifest M --doc D --name N --attempt-id A --reason "<text>" --confirm-no-session
#   fleet-manifest.sh t3 set    <manifest> <worker doc> [--thread <threadId|pending>] [--kind ask|task] [--notice pending:0..3|sent|failed]
#   fleet-manifest.sh t3 unbind <manifest> <threadId> [--reason <word>]
#
# `t3 set` and `t3 unbind` (scripts/t3/relay-bind.sh) carry a T3 thread's binding on its fleet row: the row's
# t3_thread / t3_kind / t3_notice fields, and a top-level t3_tombstones array of {thread, reason, at}. `t3 set` edits a listed
# row only (rc 1 for a doc not listed); `t3 unbind` removes every row whose t3_thread is the id AND appends the tombstone in one
# atomic rewrite (a thread with no row still gets its tombstone; one already tombstoned gets no second). Both hold the manifest
# lock, so a copy of the manifest (chief.sh next) carries every binding.
#
# `attempt settle` settles the manifest row only: it sets the row's .attempt phase and, for refused, removes the row and keeps
# .last_refused_attempt. It does NOT touch the control anchor's attempt record, the family target slot, the reservation
# directory or the launch-refusals.jsonl history, so `attempt settle --phase refused` on a committed or unknown attempt
# exits 0 while the attempt still holds its slot and reservation and `control ack` still lists it as unknown.
# `runtime settle` (fleet_runtime.py, reached through the `runtime` pass-through below) is the one explicit exit for
# that state, an attempt whose launcher died after commit with no session ever seen. Only the chief or the operator types
# it; nothing calls it (tick, the cadence, the doctor, ack and reconcile do not) and `control ack` only prints a
# hint text for each unknown attempt. It needs: the attempt committed or unknown with the exact attempt id, doc and name; its owner and
# committer proven dead by the existing process-identity check (another host, boot or an unreadable identity refuses);
# a full readable scan for a session finding none; no launched or terminal receipt in the history; --confirm-no-session
# and a non-empty --reason. It then writes one typed `refused` receipt (cause settled-no-session, the reason, the
# evidence, who settled), releases the attempt's own reservation, frees its target slot and removes its manifest row;
# every earlier history row stays. It reads no age, timestamp or elapsed time.
#
# Control init creates one paused generation-1 anchor in the manifest's physical
# bucket and stores only .control={family,anchor}. A copied successor reference
# keeps that anchor. Init never repairs/resets a broken bound anchor; conflicting
# target/family/path refuses. Set uses the anchor lock and compare-generation;
# active targets must fit the existing load_policy hard cap (no env override).
# Locks are bounded and ordered manifest fd9 -> anchor fd8. No subprocess calls
# this writer under those locks. Init writes anchor then reference: interruption
# can leave a paused orphan anchor, which an unbound init can safely adopt.
#
# Worker .attempt={attempt_id,phase,control_generation,receipt:{v:2,
# kind:"launch-attempt",attempt_id}} references existing typed launch receipts.
# Bind requires exactly one registered doc with its matching worker label; no
# legacy/unrecognized attempt is adopted. Pending -> unknown|launched|refused;
# unknown -> launched|refused; launched is terminal. Same phase/id is idempotent.
# Definite refused removes only the matched row, retaining .last_refused_attempt
# ={doc,receipt} as one bounded pointer, not history. Replay after replacement
# refuses. Existing launch-refusals.jsonl remains the history/evidence owner.
# Runtime operations below verify exact attempt and host/boot/start identity;
# `control ack` reports current in-flight/unknown/launched attempts separately.
# Snapshot and bind metadata grant no spawn authority. Settle
# remains safe bookkeeping if the anchor is missing; bind needs valid control,
# but may register intent while paused. Runtime commitment serializes with set
# through these same manifest/anchor locks. --pending marks a new preregistration,
# never a live owner or permission; unrecognized legacy ownership stays protected.
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
# as lane `unknown`, not lockless. A doc already listed is left alone, flags and all,
# except for an arm it lacks (below).
# add also stores an optional `arm` (200k|400k, the autocompact A/B
# arm the worker launched on); a worker added with no --arm carries no `arm` key.
# A listed row with no arm takes the arm of a later add (the chief or the launch
# runtime registers the row before the launcher knows its arm); a different arm
# than the stored one is refused.
# Only `workers[].doc` drives tick; label (worker-identity.sh's N<k>) is what remove
# matches and what a human reads. Any other key, top-level or per worker, is
# carried through every rewrite untouched, so a wider worker manifest
# (chains, lanes, write-sets) can grow in the same object.
#
# add is idempotent (a doc already listed is left alone, an arm it lacks aside); removing a worker that is
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
if [ "${1:-}:${2:-}" = control:ack ] && [ "$#" -eq 3 ]; then
    exec python3 -I "$HERE/../../lib/fleet_runtime.py" ack --manifest "$3"
fi
if [ "${1:-}" = runtime ]; then
    shift
    exec python3 -I "$HERE/../../lib/fleet_runtime.py" "$@"
fi
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
usage: fleet-manifest.sh add    <manifest> <worker doc>... --lane <lane> [--pending] [--lockless] [--arm 200k|400k]
       fleet-manifest.sh remove <manifest> <worker doc | label>...
       fleet-manifest.sh list   <manifest>
       fleet-manifest.sh watch  <manifest> add|set <pr> [--repo <owner/name>] [--head <sha>] [--comments <n>] [--reviews <n>] [--state open|closed|merged]
       fleet-manifest.sh watch  <manifest> remove <pr> [--repo <owner/name>]
       fleet-manifest.sh watch  <manifest> list
       fleet-manifest.sh control init <manifest> --target N
       fleet-manifest.sh control show <manifest>
       fleet-manifest.sh control ack <manifest>
       fleet-manifest.sh control set <manifest> --mode paused|shadow|active [--target N] --expect-gen G
       fleet-manifest.sh attempt bind <manifest> <doc> --attempt-id A
       fleet-manifest.sh attempt settle <manifest> <doc> --attempt-id A --phase launched|refused|unknown
       fleet-manifest.sh t3 set    <manifest> <worker doc> [--thread <threadId|pending>] [--kind ask|task] [--notice pending:0..3|sent|failed]
       fleet-manifest.sh t3 unbind <manifest> <threadId> [--reason <word>]
--lane is any lowercase word: native, claudex, openrouter, deepseek, t3 (a thread bound by scripts/t3/relay-bind.sh), ...
add writes a pending row for a doc no session ever ran on (no marker bullet, free lock, no claude on it), with or without --pending
USAGE
}

# Every worker's doc is an absolute path with no whitespace or glob character:
# tick word-splits its worker list, so anything else would silently shrink the
# fleet it judges. Run with `jq -s`: the file must hold exactly one top-level
# value — jq reads a stream, so two concatenated objects would
# otherwise pass per value and list/add would act on a multi-object file.
VALID="$JQ_W"'length == 1 and (.[0] | type == "object" and .schema == 1 and (W | type == "array")
    and all(W[]; type == "object" and (.doc | type == "string" and test("^/[^[:space:]*?\\[]+$"))))'

fleet_metadata() (
    [ "$#" -ge 3 ] || { usage >&2; exit 2; }
    local kind="$1" sub="$2" manifest="$3" doc="" target="" mode="" gen="" aid="" phase=""
    local anchor cur control now family value label result cap root
    shift 3
    # shellcheck source=../../lib/fleet-control.sh
    . "$HERE/../../lib/fleet-control.sh" || exit 1
    if [ "$kind:$sub" = control:show ]; then
        [ "$#" -eq 0 ] || { usage >&2; exit 2; }
        fleet_control_show "$manifest"
        exit $?
    fi
    manifest=$(fleet_control_path "$manifest") || exit 2
    case "$kind:$sub" in
        control:init|control:set) ;;
        attempt:bind|attempt:settle)
            [ "$#" -ge 1 ] || { usage >&2; exit 2; }
            doc="$1"; shift
            case "$doc" in /*) ;; *) exit 2 ;; esac
            case "$doc" in *[[:space:]]*|*'*'*|*'?'*|*'['*) exit 2 ;; esac ;;
        *) usage >&2; exit 2 ;;
    esac
    while [ "$#" -gt 0 ]; do
        [ "$#" -ge 2 ] || { usage >&2; exit 2; }
        case "$kind:$sub:$1" in
            control:init:--target|control:set:--target) [ -z "$target" ] || exit 2; target="$2" ;;
            control:set:--mode) [ -z "$mode" ] || exit 2; mode="$2" ;;
            control:set:--expect-gen) [ -z "$gen" ] || exit 2; gen="$2" ;;
            attempt:bind:--attempt-id|attempt:settle:--attempt-id) [ -z "$aid" ] || exit 2; aid="$2" ;;
            attempt:settle:--phase) [ -z "$phase" ] || exit 2; phase="$2" ;;
            *) usage >&2; exit 2 ;;
        esac
        [ -n "$2" ] || exit 2
        shift 2
    done
    if [ "$kind:$sub" = control:init ] || [ -n "$target" ]; then
        case "$target" in ''|0*|*[!0-9]*) echo 'fleet-manifest: target must be a positive integer' >&2; exit 2 ;; esac
        [ "${#target}" -le 10 ] && [ "$target" -le 2147483647 ] || exit 2
    fi
    if [ "$kind:$sub" = control:set ]; then
        case "$mode" in paused|shadow|active) ;; *) usage >&2; exit 2 ;; esac
        case "$gen" in ''|0*|*[!0-9]*) echo 'fleet-manifest: expected generation required' >&2; exit 2 ;; esac
        [ "${#gen}" -le 16 ] && [ "$gen" -lt 9007199254740990 ] || exit 2
    fi
    if [ "$kind" = attempt ]; then
        [[ $aid =~ ^[0-9A-Za-z-]{1,80}$ ]] || { echo 'fleet-manifest: invalid attempt id' >&2; exit 2; }
        if [ "$sub" = settle ]; then case "$phase" in launched|refused|unknown) ;; *) usage >&2; exit 2 ;; esac; fi
    fi
    [ ! -L "$manifest" ] && [ ! -L "$manifest.lock" ] || exit 1
    # prim-ok: bounded lock on fd9, matching the public legacy writer.
    exec 9>>"$manifest.lock" && flock -x -w 30 9 || exit 1
    if [ -e "$manifest" ]; then
        fleet_control_manifest_valid "$manifest" || { echo 'fleet-manifest: invalid manifest' >&2; exit 1; }
        cur=$(jq 'if has("legs") then .workers = (.workers // .legs) | del(.legs) else . end' "$manifest") || exit 1
    elif [ "$kind:$sub" = control:init ]; then cur='{"schema":1,"workers":[]}'
    else echo 'fleet-manifest: missing manifest' >&2; exit 1
    fi
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ) || exit 1
    anchor="${manifest%/*}/fleet-control.json"
    if [ "$kind" = control ] || [ "$sub" = bind ]; then
        [ ! -L "$anchor" ] && [ ! -L "$anchor.lock" ] || exit 1
        # prim-ok: distinct anchor lock, always after manifest; no reacquisition.
        exec 8>>"$anchor.lock" && flock -x -w 30 8 || exit 1
        if [ "$kind:$sub" = control:init ] && ! printf '%s\n' "$cur" | jq -e 'has("control")' >/dev/null; then
            if [ -e "$anchor" ]; then
                fleet_control_anchor_valid "$anchor" || { echo 'fleet-manifest: invalid anchor' >&2; exit 1; }
                control=$(cat -- "$anchor") || exit 1
                [ "$(printf '%s\n' "$control" | jq -r .target)" = "$target" ] || { echo 'fleet-manifest: conflicting target' >&2; exit 1; }
                family=$(printf '%s\n' "$control" | jq -r .family) || exit 1
            else
                family=$(cat /proc/sys/kernel/random/uuid) || exit 1
                control=$(jq -nc --arg f "$family" --arg t "$now" --argjson n "$target" \
                    '{schema:1,family:$f,mode:"paused",generation:1,target:$n,updated:$t,reason:"initialized"}') || exit 1
                printf '%s\n' "$control" | atomic_write "$anchor" || { echo 'fleet-manifest: cannot write anchor' >&2; exit 1; }
            fi
            cur=$(printf '%s\n' "$cur" | jq --arg f "$family" --arg a "$anchor" '.control = {family:$f,anchor:$a}') || exit 1
        else
            value=$(fleet_control_show "$manifest") || exit 1
            [ "$(printf '%s\n' "$value" | jq -r .state)" = ok ] || { echo 'fleet-manifest: control not bound to valid anchor' >&2; exit 1; }
            control=$(cat -- "$anchor") || exit 1
            if [ "$kind:$sub" = control:init ]; then
                [ "$(printf '%s\n' "$control" | jq -r .target)" = "$target" ] || { echo 'fleet-manifest: conflicting target' >&2; exit 1; }
                exit 0
            fi
        fi
    fi
    if [ "$kind:$sub" = control:set ]; then
        [ "$(printf '%s\n' "$control" | jq -r .generation)" = "$gen" ] || { echo 'fleet-manifest: stale control generation' >&2; exit 1; }
        [ -n "$target" ] || target=$(printf '%s\n' "$control" | jq -r .target) || exit 1
        if [ "$mode" = active ]; then
            # Same trusted cap reader and conservative fallback as usage-preflight.
            # shellcheck source=../../lib/load-dotenv.sh
            . "$HERE/../../lib/load-dotenv.sh" || exit 1
            root=$(cd "$HERE/../../.." && pwd) || exit 1
            root=$(_load_dotenv_primary_for "$root") || exit 1
            if load_policy --root "$root" HIMMEL_FLEET_CAP; then cap="${HIMMEL_FLEET_CAP:-4}"; else cap=4; fi
            case "$cap" in ''|*[!0-9]*) cap=4 ;; esac
            jq -ne --argjson n "$target" --arg c "$cap" '$n <= ($c | tonumber)' >/dev/null || { echo 'fleet-manifest: target exceeds approved hard cap' >&2; exit 1; }
        fi
        result=$(printf '%s\n' "$control" | jq --arg m "$mode" --argjson n "$target" --arg t "$now" \
            '.mode=$m | .target=$n | .generation += 1 | .updated=$t | .reason="explicit control set"') || exit 1
        printf '%s\n' "$result" | atomic_write "$anchor" || { echo 'fleet-manifest: cannot write anchor' >&2; exit 1; }
        exit 0
    elif [ "$kind" = attempt ]; then
        label=$(worker_label "$doc") || exit 1
        # The jq error branch refuses without publishing any output. Foreign
        # attempt metadata remains protected; only this contract is mutable.
        result=$(printf '%s\n' "$cur" | jq --arg d "$doc" --arg l "$label" --arg a "$aid" --arg sub "$sub" --arg p "$phase" --argjson c "${control:-null}" '
            def refuse: error("attempt identity or transition conflict");
            def valid_attempt:
                type == "object" and (.attempt_id | type == "string" and test("^[0-9A-Za-z-]{1,80}$"))
                and (.phase == "pending" or .phase == "unknown" or .phase == "launched")
                and (.control_generation | type == "number" and . >= 1 and . <= 9007199254740990 and floor == .)
                and .receipt.v == 2 and .receipt.kind == "launch-attempt" and .receipt.attempt_id == .attempt_id;
            [.workers[] | select(.doc == $d)] as $rows
            | if ($rows | length) == 0 then
                if $sub == "settle" and $p == "refused" and .last_refused_attempt.doc == $d
                    and .last_refused_attempt.receipt == {v:2,kind:"launch-attempt",attempt_id:$a} then . else refuse end
              elif ($rows | length) != 1 or $rows[0].label != $l then refuse
              else $rows[0] as $row
                | if $sub == "bind" then
                    if ($row | has("attempt_id") or has("phase")) then refuse
                    elif ($row | has("attempt")) then
                        if ($row.attempt | valid_attempt) and $row.attempt.attempt_id == $a and $row.attempt.phase == "pending" then . else refuse end
                    elif any(.workers[]; .attempt.attempt_id == $a) or .last_refused_attempt.receipt.attempt_id == $a then refuse
                    else .workers |= map(if .doc == $d then .attempt = {attempt_id:$a,phase:"pending",control_generation:$c.generation,receipt:{v:2,kind:"launch-attempt",attempt_id:$a}} else . end) end
                  elif ($row.attempt | valid_attempt) and $row.attempt.attempt_id == $a then
                    if $row.attempt.phase == "launched" and $p != "launched" then refuse
                    elif $p == "refused" then
                        .last_refused_attempt = {doc:$d,receipt:$row.attempt.receipt}
                        | .workers |= map(select(.doc != $d))
                    else .workers |= map(if .doc == $d then .attempt.phase=$p else . end) end
                  else refuse end
              end') || exit 1
        cur="$result"
    fi
    printf '%s\n' "$cur" | atomic_write "$manifest" || { echo 'fleet-manifest: cannot write manifest' >&2; exit 1; }
)

fleet_t3() (
    local sub="${2:-}" manifest="${3:-}" doc="" thread="" kind="" notice="" reason="" tid="" cur now result
    [ "$#" -ge 3 ] || { usage >&2; exit 2; }
    shift 3
    case "$sub" in
        set)
            [ "$#" -ge 3 ] || { usage >&2; exit 2; }
            doc="$1"; shift
            case "$doc" in /*) ;; *) echo "fleet-manifest: worker doc must be an absolute path: $doc" >&2; exit 2 ;; esac
            case "$doc" in *[[:space:]]*|*'*'*|*'?'*|*'['*) echo "fleet-manifest: worker doc must not contain whitespace or a glob character: $doc" >&2; exit 2 ;; esac
            while [ "$#" -gt 0 ]; do
                [ "$#" -ge 2 ] || { usage >&2; exit 2; }
                case "$1" in
                    --thread) [ -z "$thread" ] || exit 2
                        [[ $2 =~ ^[A-Za-z0-9:_-]{1,64}$ ]] || { echo "fleet-manifest: --thread must be pending or [A-Za-z0-9:_-]{1,64}" >&2; exit 2; }
                        thread="$2" ;;
                    --kind) [ -z "$kind" ] || exit 2
                        case "$2" in ask|task) kind="$2" ;; *) echo "fleet-manifest: --kind must be ask or task: $2" >&2; exit 2 ;; esac ;;
                    --notice) [ -z "$notice" ] || exit 2
                        [[ $2 =~ ^(pending:[0-3]|sent|failed)$ ]] || { echo "fleet-manifest: --notice must be pending:0..3, sent or failed: $2" >&2; exit 2; }
                        notice="$2" ;;
                    *) usage >&2; exit 2 ;;
                esac
                shift 2
            done
            [ -n "$thread$kind$notice" ] || { usage >&2; exit 2; } ;;
        unbind)
            [ "$#" -ge 1 ] || { usage >&2; exit 2; }
            tid="$1"; shift
            { [[ $tid =~ ^[A-Za-z0-9:_-]{1,64}$ ]] && [ "$tid" != pending ]; } || { echo "fleet-manifest: unbind needs a threadId ([A-Za-z0-9:_-]{1,64}, not pending): $tid" >&2; exit 2; }
            while [ "$#" -gt 0 ]; do
                { [ "$#" -ge 2 ] && [ "$1" = --reason ] && [ -z "$reason" ]; } || { usage >&2; exit 2; }
                [[ $2 =~ ^[a-z0-9:_-]{1,40}$ ]] || { echo "fleet-manifest: --reason must be [a-z0-9:_-]{1,40}: $2" >&2; exit 2; }
                reason="$2"; shift 2
            done
            [ -n "$reason" ] || reason=unbound ;;
        *) usage >&2; exit 2 ;;
    esac
    { [ ! -L "$manifest" ] && [ ! -L "$manifest.lock" ]; } || exit 1
    # prim-ok: a 30 s bounded flock on fd 9, as the other manifest writers.
    { exec 9>>"$manifest.lock" && flock -x -w 30 9; } || { echo "fleet-manifest: cannot lock $manifest.lock" >&2; exit 1; }
    [ -e "$manifest" ] || { echo "fleet-manifest: missing manifest: $manifest" >&2; exit 1; }
    jq -e -s "$VALID" "$manifest" >/dev/null 2>&1 || { echo "fleet-manifest: refusing to rewrite an invalid manifest: $manifest" >&2; exit 1; }
    cur=$(jq 'if has("legs") then .workers = (.workers // .legs) | del(.legs) else . end' "$manifest") || exit 1
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ) || exit 1
    if [ "$sub" = set ]; then
        printf '%s\n' "$cur" | jq -e --arg d "$doc" 'any(.workers[]; .doc == $d)' >/dev/null || { echo "fleet-manifest: not a listed worker doc: $doc" >&2; exit 1; }
        result=$(printf '%s\n' "$cur" | jq --arg d "$doc" --arg th "$thread" --arg k "$kind" --arg n "$notice" \
            '.workers |= map(if .doc == $d then . + (if $th != "" then {t3_thread: $th} else {} end)
                + (if $k != "" then {t3_kind: $k} else {} end) + (if $n != "" then {t3_notice: $n} else {} end) else . end)') || exit 1
    else
        result=$(printf '%s\n' "$cur" | jq --arg id "$tid" --arg r "$reason" --arg t "$now" \
            '(.t3_tombstones // []) as $ts
             | .workers |= map(select(.t3_thread != $id))
             | .t3_tombstones = (if any($ts[]; .thread == $id) then $ts else $ts + [{thread: $id, reason: $r, at: $t}] end)') || exit 1
    fi
    printf '%s\n' "$result" | atomic_write "$manifest" || { echo "fleet-manifest: cannot write $manifest" >&2; exit 1; }
)

case "${1:-}" in control|attempt) fleet_metadata "$@"; exit $? ;; esac
case "${1:-}" in t3) fleet_t3 "$@"; exit $? ;; esac

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

lane=unknown; lockless=false; lane_given=false; arm=""; pending=false
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
            --pending) pending=true; shift ;;
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
    fresh_docs=$'\n'
    if [ "$pending" != true ]; then
        for doc in "$@"; do
            [ "$(python3 -I "$HERE/../../lib/fleet_runtime.py" unlaunched --doc "$doc")" != true ] || fresh_docs="$fresh_docs$doc"$'\n'
        done
    fi
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
        # stored lane, lockless or arm are refused, not silently ignored. The one write
        # is an arm onto a row that has none (the row exists before the launcher knows its arm).
        conflict="$(printf '%s\n' "$cur" | jq -r --arg wk "$wk" --arg d "$arg" --arg ln "$lane" --argjson lg "$lane_given" --argjson ll "$lockless" --arg ar "$arm" \
            '[.[$wk][] | select(.doc == $d) | select(($lg and ((.lane // "unknown") != $ln)) or ($ll and (.lockless != true)) or ($ar != "" and (.arm // "") != "" and .arm != $ar))] | length')" || exit 1
        if [ "$conflict" -gt 0 ]; then
            echo "fleet-manifest: $arg is already listed with a different lane/lockless/arm; remove it first, then add it again: $arg" >&2
            exit 1
        fi
        row_pending=$pending
        case "$fresh_docs" in *$'\n'"$arg"$'\n'*) row_pending=true ;; esac
        cur="$(printf '%s\n' "$cur" | jq --arg wk "$wk" --arg d "$arg" --arg l "$label" --arg t "$now" --arg ln "$lane" --argjson ll "$lockless" --arg ar "$arm" --argjson pending "$row_pending" \
            'if any(.[$wk][]; .doc == $d) then .[$wk] |= map(if .doc == $d and $ar != "" and (.arm // "") == "" then . + {arm: $ar} else . end) else .[$wk] += [{doc: $d, label: $l, added: $t, lane: $ln} + (if $ll then {lockless: true} else {} end) + (if $ar != "" then {arm: $ar} else {} end) + (if $pending then {registration:"pending"} else {} end)] end')" || exit 1
    else
        cur="$(printf '%s\n' "$cur" | jq --arg wk "$wk" --arg a "$arg" \
            '.[$wk] |= map(select(.doc != $a and .label != $a))')" || exit 1
    fi
done

if ! printf '%s\n' "$cur" | atomic_write "$manifest"; then
    echo "fleet-manifest: cannot write $manifest" >&2
    exit 1
fi
