#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-append-results.sh
# scripts/handover/chief-kit/test-fleet-manifest.sh - suite for
# fleet-manifest.sh, the chief's one writer for its fleet
# manifest (the JSON `tick.sh --workers-from` reads every sample):
#   1. add to a missing manifest creates it (schema 1, doc + N-label entry)
#   2. add is idempotent; a second worker appends in order; list prints docs
#   3. remove by label and by doc; removing an absent worker is not an error
#   4. a relative doc is refused (tick would resolve it against a different root)
#   5. keys the writer does not own survive a rewrite (room for a wider worker manifest)
#   6. list on a missing or invalid manifest fails (a bad worker entry included);
#      add refuses to clobber an invalid one
#   6b. add refuses a doc with whitespace or a glob character (tick word-splits)
#   7. concurrent adds (two dispatches at once) lose no entry
#   12. retire removes only rows proven gone across the bucket's manifests, a dry run by default
#
# Hermetic: temp dir only. PLATFORM GUARD: the
# chief kit is Linux-only (util-linux flock). bash 3.2-safe.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/fleet-manifest.sh"

if ! command -v flock >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "skip - test-fleet-manifest.sh: needs flock and jq (the chief kit is Linux-only)"
    exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/fleet-manifest-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

m="$tmp/console.fleet.json"
d1="$tmp/HIMMEL-1-N61-a-2026-09-30-RESUME.md"
d2="$tmp/HIMMEL-2-N65-b-2026-09-30-RESUME.md"

# 1. add creates the manifest.
bash "$SCRIPT" add "$m" --lane native "$d1" >/dev/null 2>&1; rc=$?
check '1. add to a missing manifest succeeds' 0 "$rc"
check '1. the new manifest is schema 1' 1 "$(jq -r '.schema' "$m" 2>/dev/null)"
check '1. the entry carries the absolute doc' "$d1" "$(jq -r '.workers[0].doc' "$m" 2>/dev/null)"
check '1. the entry carries the worker-identity label' N61 "$(jq -r '.workers[0].label' "$m" 2>/dev/null)"
check '1. the entry carries an added timestamp' yes "$(jq -e '.workers[0].added | test("^[0-9]{4}-")' "$m" >/dev/null 2>&1 && echo yes)"

# 2. idempotent add, order, list.
bash "$SCRIPT" add "$m" --lane native "$d1" >/dev/null 2>&1
bash "$SCRIPT" add "$m" --lane native "$d2" >/dev/null 2>&1
check '2. a repeated add does not duplicate a worker' 2 "$(jq '.workers | length' "$m" 2>/dev/null)"
check '2. list prints the docs in manifest order' "$d1
$d2" "$(bash "$SCRIPT" list "$m" 2>/dev/null)"

# 3. remove.
bash "$SCRIPT" remove "$m" N61 >/dev/null 2>&1; rc=$?
check '3. remove by label succeeds' 0 "$rc"
check '3. remove by label drops only that worker' "$d2" "$(bash "$SCRIPT" list "$m" 2>/dev/null)"
bash "$SCRIPT" remove "$m" "$d2" >/dev/null 2>&1
check '3. remove by doc empties the worker set' 0 "$(jq '.workers | length' "$m" 2>/dev/null)"
check '3. an empty manifest lists nothing and succeeds' "0:" "$(out="$(bash "$SCRIPT" list "$m" 2>/dev/null)"; echo "$?:$out")"
bash "$SCRIPT" remove "$m" N99 >/dev/null 2>&1; rc=$?
check '3. removing a worker that is not listed is not an error' 0 "$rc"

# 4. relative doc refused.
bash "$SCRIPT" add "$m" --lane native relative/HIMMEL-3-N70-c.md >/dev/null 2>&1; rc=$?
check '4. a relative doc is a usage error (rc 2)' 2 "$rc"
check '4. and writes nothing' 0 "$(jq '.workers | length' "$m" 2>/dev/null)"

# 5. foreign keys survive.
printf '{"schema":1,"chains":{"c1":["N61"]},"workers":[{"doc":"%s","label":"N61","lane":"opus"}]}\n' "$d1" > "$m"
bash "$SCRIPT" add "$m" --lane native "$d2" >/dev/null 2>&1
check '5. a top-level key the writer does not own survives' '["N61"]' "$(jq -c '.chains.c1' "$m" 2>/dev/null)"
check '5. a per-worker key the writer does not own survives' opus "$(jq -r '.workers[0].lane' "$m" 2>/dev/null)"

# 6. missing / invalid.
bash "$SCRIPT" list "$tmp/none.fleet.json" >/dev/null 2>&1; rc=$?
check '6. list on a missing manifest fails' 1 "$rc"
printf 'not json\n' > "$tmp/bad.fleet.json"
bash "$SCRIPT" list "$tmp/bad.fleet.json" >/dev/null 2>&1; rc=$?
check '6. list on an invalid manifest fails' 1 "$rc"
bash "$SCRIPT" add "$tmp/bad.fleet.json" --lane native "$d1" >/dev/null 2>&1; rc=$?
check '6. add refuses an invalid manifest' 1 "$rc"
check '6. and leaves it untouched' 'not json' "$(cat "$tmp/bad.fleet.json")"
printf '{"schema":2,"workers":[]}\n' > "$tmp/v2.fleet.json"
bash "$SCRIPT" list "$tmp/v2.fleet.json" >/dev/null 2>&1; rc=$?
check '6. an unknown schema version is refused' 1 "$rc"
for bad in '{"doc":""}' '{"doc":"rel/x.md"}' '{"doc":7}' '{}' '{"doc":"/a b.md"}' '{"doc":"/a*.md"}'; do
    printf '{"schema":1,"workers":[%s]}\n' "$bad" > "$tmp/worker.fleet.json"
    bash "$SCRIPT" list "$tmp/worker.fleet.json" >/dev/null 2>&1; rc=$?
    check "6. a worker entry $bad is refused (tick would read it as a smaller fleet)" 1 "$rc"
done

# 6b. tick splits worker paths on whitespace, so the writer refuses what tick cannot carry.
for bad in "$tmp/a b.md" "$tmp/a*.md" "$tmp/a?.md" "$tmp/a[1].md"; do
    bash "$SCRIPT" add "$m" --lane native "$bad" >/dev/null 2>&1; rc=$?
    check "6b. a doc tick cannot carry is a usage error (rc 2): $bad" 2 "$rc"
done

# 7. concurrent adds lose nothing.
c="$tmp/race.fleet.json"
pids=""
i=1
while [ "$i" -le 12 ]; do
    bash "$SCRIPT" add "$c" --lane native "$tmp/HIMMEL-$i-N$((100 + i))-r.md" >/dev/null 2>&1 &
    pids="$pids $!"
    i=$((i + 1))
done
for p in $pids; do wait "$p"; done
check '7. twelve concurrent adds keep all twelve workers' 12 "$(jq '.workers | length' "$c" 2>/dev/null)"
check '7. no temp file is left behind' 0 "$(find "$tmp" -name 'race.fleet.json.*' ! -name '*.lock' | wc -l | tr -d ' ')"

# 7b. two concatenated schema-1 objects are not one manifest
# (jq reads a stream, so a per-value check would pass it).
s="$tmp/stream.fleet.json"
printf '%s\n%s\n' "{\"schema\":1,\"workers\":[{\"doc\":\"$d1\"}]}" "{\"schema\":1,\"workers\":[{\"doc\":\"$d2\"}]}" > "$s"
before="$(cat "$s")"
bash "$SCRIPT" list "$s" >/dev/null 2>&1; rc=$?
check '7b. list refuses a multi-object stream (rc 1)' 1 "$rc"
bash "$SCRIPT" add "$s" --lane native "$tmp/HIMMEL-3-N66-c.md" >/dev/null 2>&1; rc=$?
check '7b. add refuses a multi-object stream (rc 1)' 1 "$rc"
check '7b. the multi-object file is left unchanged' "$before" "$(cat "$s")"
printf '' > "$s"
bash "$SCRIPT" list "$s" >/dev/null 2>&1; rc=$?
check '7b. list refuses an empty file (rc 1)' 1 "$rc"

# 7c. add requires --lane (a missing one is a usage error, rc 2, nothing written) and stores it; --lockless is stored too.
m5="$tmp/lane.fleet.json"
l1="$tmp/HIMMEL-5-N70-x.md"; l2="$tmp/HIMMEL-5-N71-y.md"; l3="$tmp/HIMMEL-5-P01-z.md"; l4="$tmp/HIMMEL-5-N72-w.md"
m5n="$tmp/nolane.fleet.json"
msg="$(bash "$SCRIPT" add "$m5n" "$l1" 2>&1)"; rc=$?
check '7c. add with no --lane is a usage error (rc 2)' 2 "$rc"
check '7c. and writes no manifest' absent "$([ -e "$m5n" ] && echo present || echo absent)"
case "$msg" in *--lane*native*claudex*openrouter*deepseek*) refusal=names ;; *) refusal=silent ;; esac
check '7c. and the refusal names --lane and its valid values' names "$refusal"
bash "$SCRIPT" add "$m5" --lane native "$l1" >/dev/null 2>&1; rc=$?
check '7c. add --lane native still writes (control)' 0 "$rc"
check '7c. and stores native' native "$(jq -r '.workers[0].lane' "$m5")"
check '7c. a missing --lockless stores no lockless key' null "$(jq -r '.workers[0].lockless // "null"' "$m5")"
bash "$SCRIPT" add "$m5" --lane claudex "$l2" >/dev/null 2>&1; rc=$?
check '7c. add --lane claudex succeeds' 0 "$rc"
check '7c. the lane is stored' claudex "$(jq -r --arg d "$l2" '.workers[] | select(.doc == $d) | .lane' "$m5")"
bash "$SCRIPT" add "$m5" "$l3" --lane deepseek --lockless >/dev/null 2>&1; rc=$?
check '7c. flags after the doc are accepted' 0 "$rc"
check '7c. --lockless is stored as true' true "$(jq -r --arg d "$l3" '.workers[] | select(.doc == $d) | .lockless' "$m5")"
check '7c. the lockless row also keeps its lane' deepseek "$(jq -r --arg d "$l3" '.workers[] | select(.doc == $d) | .lane' "$m5")"
bash "$SCRIPT" add "$m5" --lane 'Bad Lane' "$l4" >/dev/null 2>&1; rc=$?
check '7c. a malformed lane is a usage error (rc 2)' 2 "$rc"
check '7c. and writes nothing' 3 "$(jq '.workers | length' "$m5")"
bash "$SCRIPT" add "$m5" --lane >/dev/null 2>&1; rc=$?
check '7c. --lane with no value is a usage error (rc 2)' 2 "$rc"
# A manifest written before the fields existed still lists and accepts adds.
m6="$tmp/old.fleet.json"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N70","added":"x"}]}\n' "$l1" > "$m6"
check '7c. an old manifest still lists' "$l1" "$(bash "$SCRIPT" list "$m6" 2>/dev/null)"
bash "$SCRIPT" add "$m6" --lane native "$l2" >/dev/null 2>&1; rc=$?
check '7c. an old manifest still takes an add' 0 "$rc"
check '7c. the old row keeps no lane key' null "$(jq -r '.workers[0].lane // "null"' "$m6")"

# 8. M1a: `list` and the schema check take a `workers` array first, the pre-rename `legs` array
#    still reads, and HIMMEL_LEGACY_NAMES=0 refuses the old one. (M1b: the writer rewrote m6 above to `workers`,
#    so the frozen old-manifest input is written again here.)
printf '{"schema":1,"legs":[{"doc":"%s","label":"N70","added":"x"}]}\n' "$l1" > "$m6"
m8="$tmp/workers.fleet.json"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N70","added":"x"}]}\n' "$l1" > "$m8"
check '8. a manifest with a workers array lists' "$l1" "$(bash "$SCRIPT" list "$m8" 2>/dev/null)"
check '8. an old legs manifest lists the same docs' "$l1" "$(bash "$SCRIPT" list "$m6" 2>/dev/null | head -n 1)"
m8b="$tmp/both.fleet.json"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N1"}],"workers":[{"doc":"%s","label":"N70"}]}\n' "$l2" "$l1" > "$m8b"
check '8. with both arrays the workers one wins' "$l1" "$(bash "$SCRIPT" list "$m8b" 2>/dev/null)"
printf '{"schema":1,"workers":[{"doc":"relative.md"}]}\n' > "$tmp/badw.fleet.json"
bash "$SCRIPT" list "$tmp/badw.fleet.json" >/dev/null 2>&1; rc=$?
check '8. a workers array is held to the same absolute-doc rule (rc 1)' 1 "$rc"
HIMMEL_LEGACY_NAMES=0 bash "$SCRIPT" list "$m6" >/dev/null 2>&1; rc=$?
check '8. with HIMMEL_LEGACY_NAMES=0 an old legs manifest is not a schema-1 manifest (rc 1)' 1 "$rc"
check '8. with HIMMEL_LEGACY_NAMES=0 a workers manifest still lists' "$l1" "$(HIMMEL_LEGACY_NAMES=0 bash "$SCRIPT" list "$m8" 2>/dev/null)"
# the writer edits the array the readers read: `workers` when the manifest holds one, and a new manifest
# says `workers` only with legacy names off
bash "$SCRIPT" add "$m8b" --lane native "$l3" >/dev/null 2>&1; rc=$?
check '8. add to a manifest holding both arrays succeeds (rc 0)' 0 "$rc"
check '8. the add lands in the workers array the readers read' 2 "$(jq '.workers | length' "$m8b")"
check '8. the add drops the stale legs array' false "$(jq 'has("legs")' "$m8b")"
bash "$SCRIPT" remove "$m8" "$l1" >/dev/null 2>&1; rc=$?
check '8. remove from a workers-only manifest succeeds (rc 0)' 0 "$rc"
check '8. the remove empties the workers array and adds no legs key' "0 false" "$(jq -r '"\(.workers | length) \(has("legs"))"' "$m8")"
m8n="$tmp/new-off.fleet.json"
HIMMEL_LEGACY_NAMES=0 bash "$SCRIPT" add "$m8n" --lane native "$l1" >/dev/null 2>&1; rc=$?
check '8. with HIMMEL_LEGACY_NAMES=0 a new manifest is created (rc 0)' 0 "$rc"
check '8. that new manifest says workers and no legs' "true false" "$(jq -r '"\(has("workers")) \(has("legs"))"' "$m8n")"
check '8. and it lists with HIMMEL_LEGACY_NAMES=0' "$l1" "$(HIMMEL_LEGACY_NAMES=0 bash "$SCRIPT" list "$m8n" 2>/dev/null)"
HIMMEL_LEGACY_NAMES=0 bash "$SCRIPT" add "$m6" --lane native "$l3" >/dev/null 2>&1; rc=$?
check '8. with HIMMEL_LEGACY_NAMES=0 an add to an old legs manifest is refused (rc 1)' 1 "$rc"

# 9. M1b: every write says `workers` and drops `legs`, an old legs manifest included (same entries, same order).
m9a="$tmp/m1b-add.fleet.json"
printf '{"schema":1,"chains":{"c1":["N70"]},"legs":[{"doc":"%s","label":"N70","added":"x","lane":"opus"},{"doc":"%s","label":"N71","added":"y"}]}\n' "$l1" "$l2" > "$m9a"
bash "$SCRIPT" add "$m9a" --lane native "$l3" >/dev/null 2>&1; rc=$?
check '9. an add to an old legs manifest succeeds (rc 0)' 0 "$rc"
check '9. that manifest now has a workers array and no legs key' "true false" "$(jq -r '"\(has("workers")) \(has("legs"))"' "$m9a")"
check '9. the old entries keep their order and the new one is appended' "$l1 $l2 $l3" "$(jq -r '[.workers[].doc] | join(" ")' "$m9a")"
check '9. a per-worker and a top-level key survive the rename' "opus [\"N70\"]" "$(jq -r '"\(.workers[0].lane) \(.chains.c1 | tojson)"' "$m9a")"
m9b="$tmp/m1b-remove.fleet.json"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N70","added":"x"},{"doc":"%s","label":"N71","added":"y"}]}\n' "$l1" "$l2" > "$m9b"
bash "$SCRIPT" remove "$m9b" N70 >/dev/null 2>&1; rc=$?
check '9. a remove from an old legs manifest succeeds (rc 0)' 0 "$rc"
check '9. that manifest now has a workers array and no legs key' "true false" "$(jq -r '"\(has("workers")) \(has("legs"))"' "$m9b")"
check '9. the remove leaves the other entry' "$l2" "$(jq -r '[.workers[].doc] | join(" ")' "$m9b")"
m9c="$tmp/m1b-new.fleet.json"
bash "$SCRIPT" add "$m9c" --lane native "$l1" >/dev/null 2>&1
check '9. a new manifest has a workers array and no legs key' "true false" "$(jq -r '"\(has("workers")) \(has("legs"))"' "$m9c")"
check '9. the new manifest lists the doc' "$l1" "$(bash "$SCRIPT" list "$m9c" 2>/dev/null)"

m7="$tmp/m7.json"
bash "$SCRIPT" add "$m7" --lane native $'/a/x.md\n/b/y.md' >/dev/null 2>&1; rc=$?
check '7c. a doc argument holding a newline is refused (rc 2), not split into two rows' 2 "$rc"
check '7c. a newline-holding argument adds no row' 0 "$(jq -r '.workers | length' "$m7" 2>/dev/null || echo 0)"

# N2: re-adding a listed doc with a different lane/lockless is refused, not ignored.
m8="$tmp/m8.json"
bash "$SCRIPT" add "$m8" --lane native "$l1" >/dev/null 2>&1
bash "$SCRIPT" add "$m8" --lane claudex "$l1" >/dev/null 2>&1; rc=$?
check '7d. re-adding with a different --lane is refused (rc 1)' 1 "$rc"
check '7d. the refused re-add leaves the lane alone' native "$(jq -r '.workers[0].lane' "$m8")"
bash "$SCRIPT" add "$m8" --lane native --lockless "$l1" >/dev/null 2>&1; rc=$?
check '7d. re-adding with --lockless on a locked row is refused (rc 1)' 1 "$rc"
bash "$SCRIPT" add "$m8" --lane native "$l1" >/dev/null 2>&1; rc=$?
check '7d. re-adding with the same lane stays a no-op (rc 0)' 0 "$rc"
bash "$SCRIPT" add "$m8" "$l1" >/dev/null 2>&1; rc=$?
check '7d. re-adding a listed doc with no --lane is refused too (rc 2), no exception to the rule' 2 "$rc"
check '7d. still one row' 1 "$(jq '.workers | length' "$m8")"

# an optional autocompact A/B arm is stored, validated and conflict-checked.
m9="$tmp/m9.json"
bash "$SCRIPT" add "$m9" --lane native --arm 400k "$l1" >/dev/null 2>&1; rc=$?
check '7e. add --arm 400k (rc 0)' 0 "$rc"
check '7e. the arm is stored' 400k "$(jq -r '.workers[0].arm' "$m9")"
bash "$SCRIPT" add "$m9" --lane native "$l2" >/dev/null 2>&1
check '7e. a worker added with no --arm carries no arm key' false "$(jq '.workers[1] | has("arm")' "$m9")"
bash "$SCRIPT" add "$m9" --lane native --arm 300k "$l3" >/dev/null 2>&1; rc=$?
check '7e. a bad --arm value is a usage error (rc 2)' 2 "$rc"
bash "$SCRIPT" add "$m9" --lane native --arm 200k "$l1" >/dev/null 2>&1; rc=$?
check '7e. re-adding with a different arm is refused (rc 1)' 1 "$rc"
check '7e. the refused re-add leaves the arm alone' 400k "$(jq -r '.workers[0].arm' "$m9")"
bash "$SCRIPT" add "$m9" --lane native --arm 400k "$l1" >/dev/null 2>&1; rc=$?
check '7e. re-adding with the same arm stays a no-op (rc 0)' 0 "$rc"

# a listed row with no arm takes the arm the launcher reports; a different lane, lockless or arm is still refused and writes nothing.
m7f="$tmp/m7f.json"
bash "$SCRIPT" add "$m7f" --lane native --pending "$l1" >/dev/null 2>&1
bash "$SCRIPT" add "$m7f" --lane native --arm 200k "$l1" >/dev/null 2>&1; rc=$?
check '7f. --arm on a listed row with no arm is accepted (rc 0)' 0 "$rc"
check '7f. the arm is stored on that row' 200k "$(jq -r '.workers[0].arm' "$m7f")"
check '7f. the row keeps its lane, label and pending registration, and stays one row' "native N70 pending 1" "$(jq -r '"\(.workers[0].lane) \(.workers[0].label) \(.workers[0].registration) \(.workers | length)"' "$m7f")"
bash "$SCRIPT" add "$m7f" --lane native --arm 400k "$l1" >/dev/null 2>&1; rc=$?
check '7f. a different arm on that row is then refused (rc 1)' 1 "$rc"
check '7f. the refused re-add leaves the stored arm alone' 200k "$(jq -r '.workers[0].arm' "$m7f")"
m7g="$tmp/m7g.json"
bash "$SCRIPT" add "$m7g" --lane native "$l1" >/dev/null 2>&1
bash "$SCRIPT" add "$m7g" --lane claudex --arm 200k "$l1" >/dev/null 2>&1; rc=$?
check '7f. a different lane with an arm on a row with no arm is refused (rc 1)' 1 "$rc"
check '7f. the refused re-add stores no arm' false "$(jq '.workers[0] | has("arm")' "$m7g")"
bash "$SCRIPT" add "$m7g" --lane native --lockless --arm 200k "$l1" >/dev/null 2>&1; rc=$?
check '7f. --lockless with an arm on a locked row with no arm is refused (rc 1)' 1 "$rc"
check '7f. that refused re-add stores no arm either' false "$(jq '.workers[0] | has("arm")' "$m7g")"
bash "$SCRIPT" add "$m7g" --lane native "$l1" >/dev/null 2>&1; rc=$?
check '7f. a re-add with no --arm leaves a row with no arm alone (rc 0)' "0 false" "$rc $(jq '.workers[0] | has("arm")' "$m7g")"

m10="$tmp/m10.json"
h1=1111111111111111111111111111111111111111
h2=2222222222222222222222222222222222222222
bash "$SCRIPT" add "$m10" --lane native "$l1" >/dev/null 2>&1
bash "$SCRIPT" watch "$m10" add 4761 --head "$h1" --comments 3 --reviews 1 >/dev/null 2>&1; rc=$?
check '9. watch add (rc 0)' 0 "$rc"
check '9. the row holds the PR, head, comment and review counts' "4761 $h1 3 1" "$(jq -r '.watch[0] | "\(.pr) \(.head) \(.comments) \(.reviews)"' "$m10" 2>/dev/null)"
check '9. the row carries an added timestamp' yes "$(jq -e '.watch[0].added | test("^[0-9]{4}-")' "$m10" >/dev/null 2>&1 && echo yes)"
check '9. schema 1 is still valid: list still prints the workers' "$l1" "$(bash "$SCRIPT" list "$m10" 2>/dev/null)"
bash "$SCRIPT" watch "$m10" add 4761 --comments 5 >/dev/null 2>&1
check '9. a second add of the same PR updates the given field only, never a second row' "1 $h1 5 1" "$(jq -r '"\(.watch | length) \(.watch[0].head) \(.watch[0].comments) \(.watch[0].reviews)"' "$m10" 2>/dev/null)"
bash "$SCRIPT" watch "$m10" set 4761 --head "$h2" --comments 6 --reviews 2 >/dev/null 2>&1
check '9. watch set rewrites the row to what was last seen' "$h2 6 2" "$(jq -r '.watch[0] | "\(.head) \(.comments) \(.reviews)"' "$m10" 2>/dev/null)"
bash "$SCRIPT" watch "$m10" set 999 --head "$h1" >/dev/null 2>&1; rc=$?
check '9. watch set on a PR with no row is a no-op, not a new row' "0 1" "$rc $(jq '.watch | length' "$m10" 2>/dev/null)"
bash "$SCRIPT" add "$m10" --lane native "$l2" >/dev/null 2>&1
bash "$SCRIPT" remove "$m10" "$l1" >/dev/null 2>&1
check '9. a worker add and remove carry the watch rows through untouched' "1 $h2" "$(jq -r '"\(.watch | length) \(.watch[0].head)"' "$m10" 2>/dev/null)"
m10b="$tmp/successor.fleet.json"; cp "$m10" "$m10b"
check '9. a successor reading the inherited manifest lists the same row (no re-arm)' "4761	$h2	6	2	-	-" "$(bash "$SCRIPT" watch "$m10b" list 2>/dev/null)"
bash "$SCRIPT" watch "$m10" add 4762 --repo yotamleo-org/Himmel >/dev/null 2>&1
check '9. a row with only a PR and a repo lists a dash for what is unset' "4762	-	-	-	yotamleo-org/Himmel	-" "$(bash "$SCRIPT" watch "$m10" list 2>/dev/null | sed -n 2p)"
bash "$SCRIPT" watch "$m10" add 4762 --repo other/Repo --head "$h1" --state open >/dev/null 2>&1
check '9. the same PR number in another repository is a second row, never an overwrite' "3 yotamleo-org/Himmel:- other/Repo:$h1" "$(jq -r '"\(.watch | length) " + ([.watch[] | select(.pr == 4762) | "\(.repo):\(.head // "-")"] | join(" "))' "$m10" 2>/dev/null)"
bash "$SCRIPT" watch "$m10" set 4762 --repo other/Repo --state merged >/dev/null 2>&1
check '9. set with --repo updates that repository row only' "merged -" "$(jq -r '([.watch[] | select(.repo == "other/Repo") | .state][0]) + " " + ([.watch[] | select(.repo == "yotamleo-org/Himmel") | .state // "-"][0])' "$m10" 2>/dev/null)"
bash "$SCRIPT" watch "$m10" remove 4762 --repo other/Repo >/dev/null 2>&1
check '9. remove with --repo drops that repository row only' "2 4761,4762" "$(jq -r '"\(.watch | length) " + (.watch | map(.pr) | join(","))' "$m10" 2>/dev/null)"
bash "$SCRIPT" watch "$m10" add 4762 --state sideways >/dev/null 2>&1; rc=$?
check '9. a state that is not open, closed or merged is a usage error (rc 2)' 2 "$rc"
bash "$SCRIPT" watch "$m10" remove 4762 --repo yotamleo-org/Himmel --head "$h1" >/dev/null 2>&1; rc=$?
check '9. remove takes no seen-values (rc 2)' 2 "$rc"
bash "$SCRIPT" watch "$m10" remove 4761 >/dev/null 2>&1; rc=$?
check '9. watch remove drops one row' "0 4762" "$rc $(jq -r '.watch | map(.pr) | join(",")' "$m10" 2>/dev/null)"
bash "$SCRIPT" watch "$m10" remove 5555 >/dev/null 2>&1; rc=$?
check '9. removing a PR that is not watched is not an error' 0 "$rc"
bash "$SCRIPT" watch "$m10" add notanumber >/dev/null 2>&1; rc=$?
check '9. a non-numeric PR is a usage error (rc 2)' 2 "$rc"
bash "$SCRIPT" watch "$m10" add 4763 --head XYZ >/dev/null 2>&1; rc=$?
check '9. a head that is not lowercase hex is a usage error (rc 2)' 2 "$rc"
bash "$SCRIPT" watch "$m10" add 4763 --repo notaslug >/dev/null 2>&1; rc=$?
check '9. a repo that is not owner/name is a usage error (rc 2)' 2 "$rc"
check '9. and the refused adds wrote nothing' 4762 "$(jq -r '.watch | map(.pr) | join(",")' "$m10" 2>/dev/null)"
bash "$SCRIPT" watch "$tmp/bad.fleet.json" add 4764 >/dev/null 2>&1; rc=$?
check '9. watch refuses to rewrite an invalid manifest (rc 1)' 1 "$rc"
m11="$tmp/m11.json"
bash "$SCRIPT" watch "$m11" add 4765 >/dev/null 2>&1; rc=$?
check '9. watch add on a missing manifest creates a schema-1 one' "0 1 0 4765" "$rc $(jq -r '"\(.schema) \(.workers | length) \(.watch[0].pr)"' "$m11" 2>/dev/null)"
for i in 1 2 3 4 5 6; do bash "$SCRIPT" watch "$m11" add "50$i" >/dev/null 2>&1 & done; wait
check '9. concurrent watch adds lose no row' 7 "$(jq '.watch | length' "$m11" 2>/dev/null)"

# 8. usage.
bash "$SCRIPT" >/dev/null 2>&1; rc=$?
check '8. no verb is a usage error (rc 2)' 2 "$rc"
bash "$SCRIPT" frob "$m" >/dev/null 2>&1; rc=$?
check '8. an unknown verb is a usage error (rc 2)' 2 "$rc"

# Attempt metadata changes only an existing exact worker registration. Readers
# still see pending/unknown/launched rows through the public legacy list API.
mkdir "$tmp/attempts"
am="$tmp/attempts/chief.json"
ad="$tmp/HIMMEL-8-N81-attempt.md"
bd="$tmp/HIMMEL-8-N82-peer.md"
bash "$SCRIPT" add "$am" --lane api "$ad" "$bd"
jq '.foreign = {keep:true} | .workers[0].foreign = ["keep"]' "$am" > "$tmp/edit.json"
cp "$tmp/edit.json" "$am"
bash "$SCRIPT" control init "$am" --target 1
bash "$SCRIPT" attempt bind "$am" "$ad" --attempt-id A1; rc=$?
check 'attempt bind attaches to registered worker' 0 "$rc"
check 'pending records exact id and observed generation' 'A1 pending 1' "$(jq -r '.workers[0].attempt | "\(.attempt_id) \(.phase) \(.control_generation)"' "$am")"
bash "$SCRIPT" control set "$am" --mode shadow --expect-gen 1
bash "$SCRIPT" attempt bind "$am" "$ad" --attempt-id A1; rc=$?
check 'same pending bind is idempotent' 0 "$rc"
check 'pending replay retains original control generation' 1 "$(jq '.workers[0].attempt.control_generation' "$am")"
bash "$SCRIPT" attempt bind "$am" "$ad" --attempt-id A2 >/dev/null 2>&1; rc=$?
check 'another pending attempt cannot replace owner' 1 "$rc"
bash "$SCRIPT" attempt bind "$am" "$tmp/unregistered.md" --attempt-id A2 >/dev/null 2>&1; rc=$?
check 'bind cannot invent worker' 1 "$rc"
bash "$SCRIPT" attempt settle "$am" "$ad" --attempt-id A2 --phase refused >/dev/null 2>&1; rc=$?
check 'stale refusal cannot remove current owner' 1 "$rc"
check 'pending worker remains visible to old readers' "$ad
$bd" "$(bash "$SCRIPT" list "$am")"
bash "$SCRIPT" attempt settle "$am" "$ad" --attempt-id A1 --phase unknown
bash "$SCRIPT" attempt bind "$am" "$ad" --attempt-id A2 >/dev/null 2>&1; rc=$?
check 'unknown stays protected from retry' 1 "$rc"
check 'unknown preserves registration and truth' unknown "$(jq -r '.workers[0].attempt.phase' "$am")"
bash "$SCRIPT" attempt settle "$am" "$ad" --attempt-id A1 --phase launched
bash "$SCRIPT" attempt settle "$am" "$ad" --attempt-id A1 --phase launched; rc=$?
check 'launched replay is idempotent' 0 "$rc"
bash "$SCRIPT" attempt settle "$am" "$ad" --attempt-id A1 --phase refused >/dev/null 2>&1; rc=$?
check 'launched cannot be downgraded to refusal' 1 "$rc"
bash "$SCRIPT" attempt settle "$am" "$ad" --attempt-id A1 --phase unknown >/dev/null 2>&1; rc=$?
check 'launched cannot be downgraded to unknown' 1 "$rc"
check 'attempt mutation preserves foreign metadata' '["keep"] true' "$(jq -r '"\(.workers[0].foreign | tojson) \(.foreign.keep)"' "$am")"
bash "$SCRIPT" attempt bind "$am" "$bd" --attempt-id B1
bash "$SCRIPT" attempt settle "$am" "$bd" --attempt-id B1 --phase refused; rc=$?
check 'definite refusal settles' 0 "$rc"
check 'refusal releases only exact active worker ownership' "$ad" "$(bash "$SCRIPT" list "$am")"
check 'refusal retains minimal typed receipt reference' 'B1 launch-attempt 2' "$(jq -r '.last_refused_attempt.receipt | "\(.attempt_id) \(.kind) \(.v)"' "$am")"
bash "$SCRIPT" attempt settle "$am" "$bd" --attempt-id B1 --phase refused; rc=$?
check 'refused replay is idempotent' 0 "$rc"
bash "$SCRIPT" add "$am" --lane api "$bd"
bash "$SCRIPT" attempt bind "$am" "$bd" --attempt-id B2
bash "$SCRIPT" attempt settle "$am" "$bd" --attempt-id B1 --phase refused >/dev/null 2>&1; rc=$?
check 'old refusal replay cannot remove retry' 1 "$rc"
check 'retry retains identity' B2 "$(jq -r '.workers[1].attempt.attempt_id' "$am")"
# Foreign/legacy attempt metadata is never silently adopted as verified intent.
jq '.workers[1].attempt = {custom:"unknown"}' "$am" > "$tmp/edit.json"
cp "$tmp/edit.json" "$am"
bash "$SCRIPT" attempt bind "$am" "$bd" --attempt-id B3 >/dev/null 2>&1; rc=$?
check 'unrecognized attempt metadata is protected' 1 "$rc"
before="$(jq -Sc . "$am")"
bash "$SCRIPT" attempt bind "$am" "$bd" --attempt-id 'bad/id' >/dev/null 2>&1; rc=$?
check 'malformed attempt identity refused' 2 "$rc"
check 'refused mutation leaves metadata unchanged' "$before" "$(jq -Sc . "$am")"
jq '.workers[1] |= (del(.attempt) | .attempt_id="legacy-unverified")' "$am" > "$tmp/edit.json"
cp "$tmp/edit.json" "$am"
bash "$SCRIPT" attempt bind "$am" "$bd" --attempt-id B5 >/dev/null 2>&1; rc=$?
check 'legacy attempt identity cannot be silently adopted' 1 "$rc"
jq '.workers[1] |= (del(.attempt_id) | .label="N999")' "$am" > "$tmp/edit.json"
cp "$tmp/edit.json" "$am"
bash "$SCRIPT" attempt bind "$am" "$bd" --attempt-id B5 >/dev/null 2>&1; rc=$?
check 'mismatched registered worker label refuses bind' 1 "$rc"
# Two binders must not replace one another, even when both saw a bare row.
bash "$SCRIPT" add "$am" --lane native "$tmp/HIMMEL-8-N83-race.md"
cdoc="$tmp/HIMMEL-8-N83-race.md"
bash "$SCRIPT" attempt bind "$am" "$cdoc" --attempt-id C1 > "$tmp/bind1" 2>&1 & p1=$!
bash "$SCRIPT" attempt bind "$am" "$cdoc" --attempt-id C2 > "$tmp/bind2" 2>&1 & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
check 'competing binders leave exactly one pending identity' 1 "$((r1+r2))"
winner="$(jq -r --arg d "$cdoc" '.workers[] | select(.doc==$d) | .attempt.attempt_id' "$am")"
check 'pending race keeps one intact worker row' 1 "$(jq --arg d "$cdoc" '[.workers[] | select(.doc==$d and .attempt.phase=="pending")] | length' "$am")"
# Failed publication cannot drop ownership or certify refusal.
mkdir "$tmp/fail-bin"
printf '#!/usr/bin/env bash\nexit 73\n' > "$tmp/fail-bin/mv"
chmod +x "$tmp/fail-bin/mv"
before="$(jq -Sc . "$am")"
PATH="$tmp/fail-bin:$PATH" bash "$SCRIPT" attempt settle "$am" "$cdoc" --attempt-id "$winner" --phase refused >/dev/null 2>&1; rc=$?
check 'failed settle is visible' 1 "$rc"
check 'failed settle retains previous owner and receipt pointer' "$before" "$(jq -Sc . "$am")"
# Settlement is bookkeeping and must remain possible after control disappears.
rm "$tmp/attempts/fleet-control.json"
bash "$SCRIPT" attempt settle "$am" "$cdoc" --attempt-id "$winner" --phase unknown; rc=$?
check 'lost control still permits identity-matched unknown settlement' 0 "$rc"
bash "$SCRIPT" attempt bind "$am" "$bd" --attempt-id B4 >/dev/null 2>&1; rc=$?
check 'lost control refuses new bind' 1 "$rc"

m10="$tmp/m10/chief.fleet.json"; mkdir -p "$tmp/m10"
free="$tmp/m10/queue-lock-free"; printf '#!/bin/bash\nexit 0\n' > "$free"; chmod +x "$free"
fresh="$tmp/m10/HIMMEL-10-N80-fresh.md"; printf '# worker\n\n## Results\n' > "$fresh"
started="$tmp/m10/HIMMEL-11-N81-started.md"; printf '# worker\n\n## Results\n\n- 10:00 LIVE — started\n' > "$started"
TICKET_STATUS_QUEUE_LOCK="$free" bash "$SCRIPT" add "$m10" --lane native "$fresh" "$started" >/dev/null 2>&1; rc=$?
check '10. a plain add of a fresh and a started doc succeeds' 0 "$rc"
check '10. the doc with no session is written as a pending row' pending "$(jq -r --arg d "$fresh" '.workers[] | select(.doc == $d) | .registration // "live"' "$m10")"
check '10. the doc with a LIVE bullet is written as a live row' live "$(jq -r --arg d "$started" '.workers[] | select(.doc == $d) | .registration // "live"' "$m10")"
onit="$tmp/m10/HIMMEL-12-N82-onit.md"; printf '# worker\n\n## Results\n' > "$onit"
WORKER_SESSION_DOC="$onit" python3 -c 'import ctypes,time; ctypes.CDLL(None).prctl(15,b"claude",0,0,0); time.sleep(30)' & live=$!
sleep .2
TICKET_STATUS_QUEUE_LOCK="$free" bash "$SCRIPT" add "$m10" --lane native "$onit" >/dev/null 2>&1; rc=$?
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
check '10. a plain add of a doc a claude session is on succeeds' 0 "$rc"
check '10. the doc a claude session is on is written as a live row' live "$(jq -r --arg d "$onit" '.workers[] | select(.doc == $d) | .registration // "live"' "$m10")"

mkdir -p "$tmp/m11"
m11="$tmp/m11/chief.fleet.json"
t1="$tmp/m11/HIMMEL-10798-N1-t3-a-2026-11-24.md"; t2="$tmp/m11/T3ASK-abcd1234-2026-11-24.md"; t3d="$tmp/m11/T3ASK-ffff0000-2026-11-24.md"
bash "$SCRIPT" add "$m11" --lane t3 --lockless --pending "$t1" "$t2" >/dev/null 2>&1; rc=$?
check '11. add --lane t3 --lockless is accepted' 0 "$rc"
check '11. the t3 lane is stored' t3 "$(jq -r --arg d "$t1" '.workers[] | select(.doc == $d) | .lane' "$m11")"
bash "$SCRIPT" t3 set "$m11" "$t1" --thread pending >/dev/null 2>&1; rc=$?
check '11. t3 set --thread pending succeeds' 0 "$rc"
check '11. t3 set stores t3_thread on that row' pending "$(jq -r --arg d "$t1" '.workers[] | select(.doc == $d) | .t3_thread' "$m11")"
check '11. t3 set leaves the other row alone' null "$(jq -r --arg d "$t2" '.workers[] | select(.doc == $d) | .t3_thread // "null"' "$m11")"
bash "$SCRIPT" t3 set "$m11" "$t2" --thread 'thr:abc_1-2' --kind ask --notice pending:0 >/dev/null 2>&1; rc=$?
check '11. t3 set takes thread, kind and notice in one write' 0 "$rc"
check '11. the three fields land together' 'thr:abc_1-2 ask pending:0' "$(jq -r --arg d "$t2" '.workers[] | select(.doc == $d) | "\(.t3_thread) \(.t3_kind) \(.t3_notice)"' "$m11")"
bash "$SCRIPT" t3 set "$m11" "$t2" --notice sent >/dev/null 2>&1; rc=$?
check '11. a later set changes only the field named' 'thr:abc_1-2 ask sent' "$(jq -r --arg d "$t2" '.workers[] | select(.doc == $d) | "\(.t3_thread) \(.t3_kind) \(.t3_notice)"' "$m11")"
before="$(cat "$m11")"
bash "$SCRIPT" t3 set "$m11" "$t3d" --thread x1 >/dev/null 2>&1; rc=$?
check '11. t3 set on an unlisted doc is refused (rc 1)' 1 "$rc"
check '11. and writes nothing' "$before" "$(cat "$m11")"
for badargs in "--thread bad/id" "--thread ''" "--kind other" "--notice pending:9" "--notice weird" "--bogus x" ""; do
    eval "bash \"\$SCRIPT\" t3 set \"\$m11\" \"\$t1\" $badargs" >/dev/null 2>&1; rc=$?
    check "11. t3 set with [$badargs] is a usage error (rc 2)" 2 "$rc"
done
bash "$SCRIPT" t3 set "$m11" "rel.md" --thread x1 >/dev/null 2>&1; rc=$?
check '11. t3 set with a relative doc is a usage error (rc 2)' 2 "$rc"
check '11. the refused sets wrote nothing' "$before" "$(cat "$m11")"
printf 'not json\n' > "$tmp/m11/bad.fleet.json"
bash "$SCRIPT" t3 set "$tmp/m11/bad.fleet.json" "$t1" --thread x1 >/dev/null 2>&1; rc=$?
check '11. t3 set refuses an invalid manifest (rc 1)' 1 "$rc"
check '11. and leaves it untouched' 'not json' "$(cat "$tmp/m11/bad.fleet.json")"
bash "$SCRIPT" t3 set "$tmp/m11/none.fleet.json" "$t1" --thread x1 >/dev/null 2>&1; rc=$?
check '11. t3 set on a missing manifest is refused (rc 1)' 1 "$rc"
bash "$SCRIPT" add "$m11" --lane t3 --lockless "$t2" >/dev/null 2>&1
check '11. a repeated add keeps the t3_* fields' 'thr:abc_1-2 ask sent' "$(jq -r --arg d "$t2" '.workers[] | select(.doc == $d) | "\(.t3_thread) \(.t3_kind) \(.t3_notice)"' "$m11")"
mkdir -p "$tmp/shim"
printf '#!/bin/sh\necho x >> "%s/mv.log"\nexec /bin/mv "$@"\n' "$tmp" > "$tmp/shim/mv"; chmod +x "$tmp/shim/mv"
: > "$tmp/mv.log"
PATH="$tmp/shim:$PATH" bash "$SCRIPT" t3 unbind "$m11" 'thr:abc_1-2' >/dev/null 2>&1; rc=$?
check '11. t3 unbind succeeds' 0 "$rc"
check '11. t3 unbind removes the row' 1 "$(jq '.workers | length' "$m11")"
check '11. t3 unbind records the tombstone' 'thr:abc_1-2' "$(jq -r '.t3_tombstones[0].thread' "$m11")"
check '11. the tombstone carries a reason and a time' 'unbound yes' "$(jq -r '.t3_tombstones[0] | "\(.reason) \(if (.at | test("^[0-9]{4}-")) then "yes" else "no" end)"' "$m11")"
check '11. row removal and tombstone are one rewrite (one rename)' 1 "$(wc -l < "$tmp/mv.log" | tr -d ' ')"
bash "$SCRIPT" t3 unbind "$m11" 'thr:abc_1-2' >/dev/null 2>&1; rc=$?
check '11. a second unbind of the same thread is rc 0' 0 "$rc"
check '11. and adds no second tombstone' 1 "$(jq '.t3_tombstones | length' "$m11")"
bash "$SCRIPT" t3 unbind "$m11" thr-refused --reason refused:gitleaks >/dev/null 2>&1; rc=$?
check '11. unbind of a thread with no row writes a reasoned tombstone' 'thr-refused refused:gitleaks 1' "$(jq -r '.t3_tombstones[1] | "\(.thread) \(.reason)"' "$m11") $(jq '.workers | length' "$m11")"
for badargs in "bad/id" "x --reason 'A B'" "x --reason ''" "x extra" ""; do
    eval "bash \"\$SCRIPT\" t3 unbind \"\$m11\" $badargs" >/dev/null 2>&1; rc=$?
    check "11. t3 unbind with [$badargs] is a usage error (rc 2)" 2 "$rc"
done
check '11. the refused unbinds wrote nothing' 2 "$(jq '.t3_tombstones | length' "$m11")"
cp "$m11" "$tmp/m11/copy.fleet.json"
check '11. a cp of the manifest keeps the tombstones' "$(jq -c '.t3_tombstones' "$m11")" "$(jq -c '.t3_tombstones' "$tmp/m11/copy.fleet.json")"
check '11. and a doc that lists still lists' "$t1" "$(bash "$SCRIPT" list "$m11" 2>/dev/null)"
( flock -x 8; sleep 2 ) 8>>"$m11.lock" & holder=$!
sleep 0.4
bash "$SCRIPT" t3 set "$m11" "$t1" --thread held1 >/dev/null 2>&1 & setter=$!
sleep 0.6
check '11. t3 set waits while the manifest lock is held' pending "$(jq -r --arg d "$t1" '.workers[] | select(.doc == $d) | .t3_thread' "$m11")"
wait "$setter"; wait "$holder"
check '11. and lands once the lock is free' held1 "$(jq -r --arg d "$t1" '.workers[] | select(.doc == $d) | .t3_thread' "$m11")"
m11b="$tmp/m11/race.fleet.json"
i=1; pids=""
while [ "$i" -le 8 ]; do bash "$SCRIPT" add "$m11b" --lane t3 --lockless "$tmp/m11/T3ASK-r$i-d.md" >/dev/null 2>&1; i=$((i + 1)); done
i=1
while [ "$i" -le 8 ]; do
    bash "$SCRIPT" t3 set "$m11b" "$tmp/m11/T3ASK-r$i-d.md" --thread "t$i" >/dev/null 2>&1 &
    pids="$pids $!"; i=$((i + 1))
done
for p in $pids; do wait "$p"; done
check '11. eight concurrent t3 sets all land' 8 "$(jq '[.workers[] | select(.t3_thread != null)] | length' "$m11b")"
m11c="$tmp/m11/guard.fleet.json"
g1="$tmp/m11/G1-N1-a.md"; g2="$tmp/m11/G2-N2-b.md"
bash "$SCRIPT" add "$m11c" --lane t3 --lockless "$g1" "$g2" >/dev/null 2>&1
bash "$SCRIPT" t3 set "$m11c" "$g1" --thread uniq1 >/dev/null 2>&1; rc=$?
check '11. a first thread binds' 0 "$rc"
bash "$SCRIPT" t3 set "$m11c" "$g1" --thread uniq1 >/dev/null 2>&1; rc=$?
check '11. setting the same thread on the same row again is fine (rc 0)' 0 "$rc"
bash "$SCRIPT" t3 set "$m11c" "$g2" --thread uniq1 >/dev/null 2>&1; rc=$?
check '11. a thread another row holds is refused under the lock (rc 1)' 1 "$rc"
check '11. and the second row stays unbound' null "$(jq -r --arg d "$g2" '.workers[] | select(.doc == $d) | .t3_thread // "null"' "$m11c")"
bash "$SCRIPT" t3 set "$m11c" "$g1" --thread pending >/dev/null 2>&1
bash "$SCRIPT" t3 set "$m11c" "$g2" --thread pending >/dev/null 2>&1; rc=$?
check '11. pending is shared by path A rows (rc 0)' 0 "$rc"
bash "$SCRIPT" t3 unbind "$m11c" tomb9 --reason refused:gitleaks >/dev/null 2>&1
bash "$SCRIPT" t3 set "$m11c" "$g1" --thread tomb9 >/dev/null 2>&1; rc=$?
check '11. a tombstoned thread cannot be set again (rc 1)' 1 "$rc"
check '11. and the row keeps its value' pending "$(jq -r --arg d "$g1" '.workers[] | select(.doc == $d) | .t3_thread' "$m11c")"
usage_text="$(bash "$SCRIPT" 2>&1)"
case "$usage_text" in *'lowercase word: native, claudex, openrouter, deepseek, t3'*) usage_names=yes ;; *) usage_names=no ;; esac
check '11. the usage text names lane t3' yes "$usage_names"

d12="$tmp/m12"; mkdir -p "$d12"
m12="$d12/chief-a.fleet.json"; m12b="$d12/chief-b.fleet.json"
gone="$d12/HIMMEL-12-N90-gone.md"
wrapped="$d12/HIMMEL-12-N91-wrapped.md"; printf '# w\n\n## Results\n\n- 10:00 LIVE — x\n- 11:00 WRAPPED — done\n' > "$wrapped"
held="$d12/HIMMEL-12-N92-held.md"; printf '# w\n\n## Results\n\n- 11:00 WRAPPED — done\n' > "$held"
onproc="$d12/HIMMEL-12-N93-onproc.md"
open="$d12/HIMMEL-12-N94-open.md"; printf '# w\n\n## Results\n\n- 10:00 LIVE — x\n' > "$open"
race="$d12/HIMMEL-12-N95-race.md"
lock12="$d12/queue-lock"
# shellcheck disable=SC2016  # $2 and $n belong to the stub and expand when it runs
printf '#!/bin/bash\ncase "$2" in\n  */HIMMEL-12-N92-*) exit 11 ;;\n  */HIMMEL-12-N95-*) n=$(cat "%s/n95" 2>/dev/null || echo 0); echo $((n + 1)) > "%s/n95"; [ "$n" -lt 1 ] || exit 11 ;;\nesac\nexit 0\n' "$d12" "$d12" > "$lock12"
chmod +x "$lock12"
printf '{"schema":1,"keep_me":1,"workers":[{"doc":"%s","label":"N90"},{"doc":"%s","label":"N91"},{"doc":"%s","label":"N92"}]}\n' "$gone" "$wrapped" "$held" > "$m12"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N93"},{"doc":"%s","label":"N94"},{"doc":"%s","label":"N95"}]}\n' "$onproc" "$open" "$race" > "$m12b"
before_a="$(cat "$m12")"; before_b="$(cat "$m12b")"
WORKER_SESSION_DOC="$onproc" python3 -c 'import ctypes,time; ctypes.CDLL(None).prctl(15,b"claude",0,0,0); time.sleep(60)' & live12=$!
sleep .2
dry="$(TICKET_STATUS_QUEUE_LOCK="$lock12" bash "$SCRIPT" retire "$m12" 2>/dev/null)"; rc=$?
check '12. a dry run succeeds (rc 0)' 0 "$rc"
check '12. the dry run rewrites no manifest' "$before_a|$before_b" "$(cat "$m12")|$(cat "$m12b")"
check '12. the dry run lists a gone doc with its proof' 1 "$(grep -c "^would-retire	$m12	N90	$gone	lock free, no live session, doc gone$" <<<"$dry")"
check '12. the dry run lists a wrapped doc with its proof' 1 "$(grep -c "^would-retire	$m12	N91	$wrapped	lock free, no live session, newest marker WRAPPED$" <<<"$dry")"
check '12. a row whose lock is held is kept' 1 "$(grep -c "^keep	$m12	N92	$held	lock held$" <<<"$dry")"
check '12. a row a live claude session is on is kept, though its doc is gone' 1 "$(grep -c "^keep	$m12b	N93	$onproc	live session$" <<<"$dry")"
check '12. a row whose doc is not wrapped is kept' 1 "$(grep -c "^keep	$m12b	N94	$open	newest marker LIVE, not wrapped$" <<<"$dry")"
check '12. the sibling manifest is swept too' 1 "$(grep -c "^would-retire	$m12b	N95	$race	" <<<"$dry")"
check '12. the dry run names every row once' 6 "$(grep -c . <<<"$dry")"
rm -f "$d12/n95"
out="$(TICKET_STATUS_QUEUE_LOCK="$lock12" bash "$SCRIPT" retire "$m12" --apply 2>/dev/null)"; rc=$?
kill "$live12" 2>/dev/null; wait "$live12" 2>/dev/null
check '12. the apply succeeds (rc 0)' 0 "$rc"
check '12. the apply prints each row it retired' "retired	$m12	N90	$gone	lock free, no live session, doc gone
retired	$m12	N91	$wrapped	lock free, no live session, newest marker WRAPPED" "$(grep '^retired' <<<"$out")"
check '12. the proven-gone rows leave the manifest and the held row stays' "$held" "$(jq -r '.workers[].doc' "$m12")"
check '12. a key the writer does not own survives the rewrite' 1 "$(jq -r '.keep_me' "$m12")"
check '12. the live-session and not-wrapped rows stay' "$onproc
$open
$race" "$(jq -r '.workers[].doc' "$m12b")"
check '12. a row whose lock is taken before the rewrite is kept by the re-check under the lock' 1 "$(grep -c "^keep	$m12b	N95	$race	lock held$" <<<"$out")"
TICKET_STATUS_QUEUE_LOCK="$lock12" bash "$SCRIPT" retire "$m12" --force >/dev/null 2>&1; rc=$?
check '12. an unknown retire flag is a usage error (rc 2)' 2 "$rc"

if [ "$fails" -eq 0 ]; then
    echo "PASS - test-fleet-manifest.sh"
    exit 0
fi
echo "FAIL - test-fleet-manifest.sh ($fails failure(s))"
exit 1
