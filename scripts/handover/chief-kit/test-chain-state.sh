#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check(), as in test-status-drift.sh
# scripts/handover/chief-kit/test-chain-state.sh - Hermetic tests for chain-state.mjs
# (board v4 slice S1). Each row writes a Jira mirror, status-events.jsonl and
# chain-log.jsonl into a temp dir and reads the himmel.chains/1 JSON back.
#   E25  waits on step N is not blocked; blocked is a blocker outside the version
#   E29  the order check reads only the completing merge, as of that merge
#   E30  a reorder before the merge holds the order; the change log lists each row
#   E33  a link across two chains shows on both, and goes when Jira drops it
#   E24  step and steps, two badges then more
#
# Platform guard: POSIX bash 3.2+ (shell-only harness).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/chain-state.mjs"
python3 -I "$HERE/fixtures/chain-parity/check.py" state || exit 1

tmp="$(mktemp -d "${TMPDIR:-/tmp}/chain-state-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
KP=HIMMEL
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]"; fails=$((fails+1)) ;; esac; }

M="$tmp/mirror" S="$tmp/state" NOW=2026-11-05T00:00:00Z
reg() {
    node -e 'const fs=require("fs"); fs.writeFileSync(process.argv[1], JSON.stringify({schema:"himmel.chain-registry/1", chains:process.argv.slice(2).map(s => {const [id,ks]=s.split("="); return {id,goal:"Goal for " + id,members:ks.split(",").map(k=>"HIMMEL-"+k)};})}));' "$tmp/registry.json" "$@"
}
reset() { rm -rf "$M" "$S"; mkdir -p "$M" "$S"; reg; }

# issue <KEY> <status> [type=|parent=|labels=|versions=|bb=|resolved=]...
issue() {
    local key="$1" status="$2" type=Task parent=null labels='[]' versions='["v1"]' bb='[]' resolved=null cat kv
    shift 2
    for kv in "$@"; do
        case "$kv" in
            type=*) type="${kv#*=}" ;;
            parent=*) parent="\"${kv#*=}\"" ;;
            labels=*) labels="${kv#*=}" ;;
            versions=*) versions="${kv#*=}" ;;
            bb=*) bb="${kv#*=}" ;;
            resolved=*) resolved="\"${kv#*=}\"" ;;
        esac
    done
    case "$status" in Done) cat=Done ;; "To Do") cat="To Do" ;; *) cat="In Progress" ;; esac
    printf -- '---\nkey: "%s"\ntype: "%s"\nstatus: "%s"\nstatusCategory: "%s"\nlabels: %s\nfixVersions: %s\nparent: %s\nresolved: %s\nlinks:\n  blocks: []\n  blocked_by: %s\n  relates: []\n---\n\n# %s: title of %s\n' \
        "$key" "$type" "$status" "$cat" "$labels" "$versions" "$parent" "$resolved" "$bb" "$key" "$key" > "$M/$key.md"
}
ev() { printf '%s\n' "$1" >> "$S/status-events.jsonl"; }
cl() { printf '%s\n' "$1" >> "$S/chain-log.jsonl"; }
merge() { ev "{\"ts\":\"$1\",\"event\":\"merge\",\"key\":\"$2\",\"pr\":\"$3\",\"contract\":\"$4\",\"result\":\"moved\"}"; }
cs() { node "$SUT" --json --registry "$tmp/registry.json" --mirror "$M" --state "$S" --version v1 --now "$NOW" > "$tmp/out" 2>"$tmp/err"; }
q()  { jq -r "$1" "$tmp/out" 2>/dev/null; }
tk() { q ".tickets[\"$1\"]$2"; }

# --- E25: blocked means a real block ----------------------------------------
reset
reg chain-mem=1,2,3,4
issue HIMMEL-1 "In Progress" labels='["chain-mem"]'
issue HIMMEL-2 "To Do" labels='["chain-mem"]' bb='["HIMMEL-1"]'
issue HIMMEL-3 "To Do" labels='["chain-mem"]' bb='["HIMMEL-9"]'
issue HIMMEL-9 "To Do" versions='["v2"]'
issue HIMMEL-4 "To Do" labels='["chain-mem"]'
cs; rc=$?
check "E25: exits 0" "$rc" 0
check "E25: the schema is himmel.chains/1" "$(q .schema)" "himmel.chains/1"
check "E25: a ticket whose only open link is an earlier step of a moving chain waits on that step, not blocked" \
    "$(tk "$KP"-2 .state)" "waits on step 1"
check "E25: the earlier step is in flight" "$(tk "$KP"-1 .state)" "in flight"
check "E25: an open blocker outside the version is a real block" "$(tk "$KP"-3 .state)" "blocked"
check "E25: nothing open stops a ticket: can launch" "$(tk "$KP"-4 .state)" "can launch"
check "E25: a ticket in no chain is not listed" "$(tk "$KP"-9 .key)" "null"
# Each link carries its blocker's fixVersions so a page narrowed to one version can tell a wait on an earlier version from a block
check "E25b: a link to a blocker in a later version names that version" "$(tk HIMMEL-3 '.links[0].onVersions | join(",")')" "v2"
check "E25b: a link to a blocker in the picked version names it" "$(tk HIMMEL-2 '.links[0].onVersions | join(",")')" "v1"
reset
reg chain-nov=1,2
issue HIMMEL-1 "To Do" labels='["chain-nov"]' bb='["HIMMEL-7"]'
issue HIMMEL-7 "To Do" versions='[]'
issue HIMMEL-2 "To Do" labels='["chain-nov"]'
cl '{"ts":"2026-11-01T00:00:00Z","change":"hold","key":"HIMMEL-2","kind":"operator","who":"chief"}'
cs
nov_len=$(tk HIMMEL-1 '.links[0].onVersions | length')
nov_state=$(tk HIMMEL-1 .state)
hold_vs=$(tk HIMMEL-2 '.links[0].onVersions')
check "E25b: a blocker with no version has an empty list, and it is still blocked" "$nov_len $nov_state" "0 blocked"
check "E25b: a hold that names no ticket has no blocker versions" "$hold_vs" "null"
check "E25b: the word blocked and the exit code are unchanged" "$nov_state" "blocked"

# --- E29: the order check at the completing merge ----------------------------
reset
reg chain-8004=8005,7379,7125,7380
issue HIMMEL-8004 "To Do" type=Epic
issue HIMMEL-8005 Done parent=HIMMEL-8004 resolved=2026-11-02T15:20:00.000+0000
issue HIMMEL-7379 Done parent=HIMMEL-8004 resolved=2026-11-02T18:52:00.000+0000
issue HIMMEL-7125 Done parent=HIMMEL-8004 resolved=2026-10-23T03:40:00.000+0000
issue HIMMEL-7380 Done parent=HIMMEL-8004 resolved=2026-11-03T10:00:00.000+0000
cl '{"ts":"2026-10-28T20:56:00Z","change":"hold","key":"HIMMEL-7379","kind":"file-collision","on":"HIMMEL-8005","who":"chief","reason":"the memory notice file"}'
merge 2026-10-23T03:29:00Z HIMMEL-7125 3613 yes
merge 2026-11-01T16:40:00Z HIMMEL-7379 101 no
merge 2026-11-02T11:05:00Z HIMMEL-7379 102 no
merge 2026-11-02T15:10:00Z HIMMEL-8005 200 yes
merge 2026-11-02T18:40:00Z HIMMEL-7379 103 yes
merge 2026-11-01T09:00:00Z HIMMEL-7380 301 no
merge 2026-11-02T09:00:00Z HIMMEL-7380 302 no
merge 2026-11-04T09:00:00Z HIMMEL-7380 303 no
cs
check "E29: a partial PR merged before the hold clears, then the completing PR after it, reads order held" \
    "$(tk "$KP"-7379 .state)" "done · order held"
check "E29: the two partial PRs are ticks with their numbers" "$(tk HIMMEL-7379 '.ticks | map(.pr) | join(" ")')" "101 102"
check "E29: and their times" "$(tk "$KP"-7379 '.ticks[0].ts')" "2026-11-01T16:40:00Z"
check "E29: the check reads the completing merge" "$(tk "$KP"-7379 '.check.merge | .pr + " " + .ts')" "103 2026-11-02T18:40:00Z"
check "E29: hold clearing respects the current resolution time" "$(tk "$KP"-7379 '.check.links[0].at')" "2026-11-02T15:20:00Z"
check "E29: a ticket completed before the chain existed is not checked" "$(tk "$KP"-7125 .check.result)" "not-checked"
check "E29: a ticket closed by hand is read at its last PR merged before Jira went Done" "$(tk "$KP"-7380 .check.merge.pr)" "302"

reset
reg chain-8004=8005,7379
issue HIMMEL-8004 "To Do" type=Epic
issue HIMMEL-8005 Done parent=HIMMEL-8004 resolved=2026-11-02T15:20:00.000+0000
issue HIMMEL-7379 Done parent=HIMMEL-8004 resolved=2026-11-02T14:10:00.000+0000
cl '{"ts":"2026-10-28T20:56:00Z","change":"hold","key":"HIMMEL-7379","kind":"file-collision","on":"HIMMEL-8005","who":"chief","reason":"the memory notice file"}'
merge 2026-11-02T14:00:00Z HIMMEL-7379 103 yes
merge 2026-11-02T15:10:00Z HIMMEL-8005 200 yes
cs
check "E29: the completing PR merging before the hold clears reads out of order" "$(tk "$KP"-7379 .state)" "done · out of order"
check "E29: with the hold record that stood open" "$(tk "$KP"-7379 '.check.links[0] | .on + " " + .kind + " " + .status + " " + .added')" \
    "HIMMEL-8005 file-collision open 2026-10-28T20:56:00Z"

reset
reg chain-8004=7379,7381,7382
issue HIMMEL-8004 "To Do" type=Epic
issue HIMMEL-7379 "In Progress" parent=HIMMEL-8004
issue HIMMEL-7381 "To Do" parent=HIMMEL-8004 bb='["HIMMEL-7379"]'
issue HIMMEL-7382 "In Progress" parent=HIMMEL-8004
ev '{"ts":"2026-11-02T14:00:00Z","event":"merge","key":"HIMMEL-7379","pr":"103","contract":"yes","result":"miss","stage":"transition"}'
ev '{"ts":"2026-11-02T14:00:00Z","event":"merge","key":"HIMMEL-7382","pr":"104","contract":"yes","result":"deferred","stage":"lock"}'
cs
check "E29: a completing merge whose Jira transition failed does not read done" "$(tk "$KP"-7379 .state)" "in flight"
check "E29: nor one whose transition was deferred" "$(tk "$KP"-7382 .state)" "in flight"
check "E29: and its dependent still waits on it" "$(tk "$KP"-7381 .state)" "waits on step 1"
issue HIMMEL-7379 Done parent=HIMMEL-8004 resolved=2026-11-02T16:00:00.000+0000
cs
check "E29: closed by hand afterwards, the check reads that merge" "$(tk "$KP"-7379 .check.merge.pr)" "103"
ev '{"ts":"2026-11-02T14:00:05Z","event":"merge","key":"HIMMEL-7379","pr":"999","result":"noop","rule":"D3"}'
cs
check "E29: a contract-less derive row under event merge is not read as the merge" "$(tk "$KP"-7379 .check.merge.pr)" "103"

# --- E29b: a merge row written before the merge call counts once its PR is proven merged ---
cat > "$tmp/mrgh" <<'EOF'
#!/usr/bin/env bash
# the merge-rows filter gh seam: pr view <n> --json ...
case "$3" in 105) echo "OPEN h5" ;; 106) echo "MERGED h6" ;; *) exit 1 ;; esac
EOF
chmod +x "$tmp/mrgh"
reset
reg chain-8004=7379,7381,7382
issue HIMMEL-8004 "To Do" type=Epic
issue HIMMEL-7379 Done parent=HIMMEL-8004 resolved=2026-11-02T16:00:00.000+0000
issue HIMMEL-7381 "To Do" parent=HIMMEL-8004 bb='["HIMMEL-7379"]'
issue HIMMEL-7382 Done parent=HIMMEL-8004 resolved=2026-11-02T16:00:00.000+0000
ev '{"ts":"2026-11-02T14:00:00Z","event":"merge","key":"HIMMEL-7379","pr":"105","head":"h5","contract":"yes","result":"pending","stage":"pre-merge"}'
ev '{"ts":"2026-11-02T14:00:00Z","event":"merge","key":"HIMMEL-7382","pr":"106","head":"h6","contract":"yes","result":"pending","stage":"pre-merge"}'
MERGE_ROWS_GH="$tmp/mrgh" cs
check "E29b: a pre-merge row whose PR is still open is not read as the merge" "$(tk "$KP"-7379 .check.merge.pr)" "null"
check "E29b: a pre-merge row whose PR GitHub reports MERGED is read as the merge" "$(tk "$KP"-7382 .check.merge.pr)" "106"
ev '{"ts":"2026-11-02T14:00:01Z","event":"merge","key":"HIMMEL-7382","pr":"106","head":"h6","result":"not-merged","stage":"merge-failed"}'
MERGE_ROWS_GH="$tmp/mrgh" cs
check "E29b: a not-merged row after it retires the pre-merge row" "$(tk "$KP"-7382 .check.merge.pr)" "null"
reset
reg chain-8004=7379,7381,7382
issue HIMMEL-8004 "To Do" type=Epic
issue HIMMEL-7382 Done parent=HIMMEL-8004 resolved=2026-11-02T16:00:00.000+0000
ev '{"ts":"2026-11-02T14:00:00Z","event":"merge","key":"HIMMEL-7382","pr":"106","head":"h6","contract":"yes","result":"pending","stage":"pre-merge"}'
pad='{"ts":"2026-11-02T13:00:00Z","event":"hold-release","key":"HIMMEL-1","result":"moved","note":"padding to push the ledger past 1 MiB..................................................."}'
for _ in $(seq 1 12000); do printf '%s\n' "$pad"; done >> "$S/status-events.jsonl"
MERGE_ROWS_GH="$tmp/mrgh" cs
check "E29b: a ledger past 1 MiB still reads the merged PR's pre-merge row" "$(tk "$KP"-7382 .check.merge.pr)" "106"

# --- E30: a chain changes ----------------------------------------------------
reset
reg chain-mem=8009,8010,8011
issue HIMMEL-8009 "To Do" labels='["chain-mem"]'
issue HIMMEL-8010 Done labels='["chain-mem"]' resolved=2026-11-03T14:30:00.000+0000
issue HIMMEL-8011 "To Do" labels='["chain-mem"]'
cl '{"ts":"2026-10-28T20:56:00Z","change":"hold","key":"HIMMEL-8010","kind":"file-collision","on":"HIMMEL-8009","who":"chief","reason":"enforcement.md"}'
ev '{"ts":"2026-11-03T12:00:00Z","event":"hold-release","key":"HIMMEL-8010","result":"moved"}'
cl '{"ts":"2026-11-03T12:00:00Z","change":"release","key":"HIMMEL-8010","who":"chief"}'
cl '{"ts":"2026-11-03T12:00:01Z","change":"hold","key":"HIMMEL-8009","kind":"chain-order","on":"HIMMEL-8010","who":"chief","reason":"docs land first"}'
cl '{"ts":"2026-11-03T12:05:00Z","change":"add","chain":"chain-mem","key":"HIMMEL-8011","who":"chief","reason":"joins after 8009"}'
cl '{"ts":"2026-11-03T12:06:00Z","change":"remove","chain":"chain-mem","key":"HIMMEL-8012","who":"chief","reason":"moved to v2"}'
merge 2026-11-03T14:02:00Z HIMMEL-8010 400 yes
cs
check "E30: a reorder before the merge: the check reads the chain as of the merge (held)" "$(tk "$KP"-8010 .state)" "done · order held"
check "E30: the reordered ticket is now the earlier step" "$(tk "$KP"-8010 '.chains[0].step') $(tk "$KP"-8009 '.chains[0].step')" "1 2"
check "E30: the change log lists each change in time order" \
    "$(q '.chains[0].log | map(.change) | join(" ")')" "hold release hold add remove"
check "E30: with its kind, reason and source" "$(q '.chains[0].log[2] | .kind + " " + .reason + " " + .who')" "chain-order docs land first chief"
check "E30: n/m follows the chain's tickets" "$(q '.chains[0] | "\(.done)/\(.total)"')" "1/3"
reset
reg chain-mem=8009,8010
issue HIMMEL-8009 "To Do" labels='["chain-mem"]'
issue HIMMEL-8010 "To Do" labels='["chain-mem"]'
cl '{"ts":"2026-10-28T20:56:00Z","change":"hold","key":"HIMMEL-8010","kind":"chain-order","on":"HIMMEL-8009","who":"chief","reason":"r"}'
cl '{"ts":"2026-11-03T12:00:00Z","change":"release","key":"HIMMEL-8010","who":"chief"}'
cl '{"ts":"2026-11-06T00:00:00Z","change":"hold","key":"HIMMEL-8009","kind":"chain-order","on":"HIMMEL-8010","who":"chief","reason":"r"}'
cs
check "E30: a hold released before its target completed, and one not yet set, add no step" \
    "$(tk "$KP"-8010 '.chains[0].step') $(tk "$KP"-8009 '.chains[0].step')" "1 1"

# --- E33: links across other work ---------------------------------------------
reset
reg chain-6000=6713 chain-macos=7120,7101
issue HIMMEL-6000 "To Do" type=Epic
issue HIMMEL-6713 "In Progress" parent=HIMMEL-6000
issue HIMMEL-7120 "In Progress" labels='["chain-macos"]'
issue HIMMEL-7101 "To Do" labels='["chain-macos"]' bb='["HIMMEL-6000"]'
cl '{"ts":"2026-10-28T20:56:00Z","change":"hold","key":"HIMMEL-6713","kind":"file-collision","on":"HIMMEL-7120","who":"chief","reason":"scripts/hooks/"}'
cs
check "E33: the waiting chain lists the link across other work" \
    "$(q '.chains[] | select(.id == "chain-6000") | .across[] | select(.on == "HIMMEL-7120") | .dir + " " + .key + " " + .kind + " " + (.chains | join(","))')" \
    "waits-on HIMMEL-6713 file-collision chain-macos"
check "E33: the held-up chain lists the same link" \
    "$(q '.chains[] | select(.id == "chain-macos") | .across[] | select(.key == "HIMMEL-6713") | .dir + " " + .on + " " + .kind')" \
    "holds-up HIMMEL-7120 file-collision"
check "E33: chains come only from the registry" "$(q '[.chains[] | .id + ":" + .source] | join(" ")')" "chain-6000:registry chain-macos:registry"
check "E33: a Jira link across chains shows too" "$(q '[.chains[] | select(.id == "chain-macos") | .across[] | select(.kind == "jira-link") | .on] | join(" ")')" "HIMMEL-6000"
issue HIMMEL-7101 "To Do" labels='["chain-macos"]'
cs
check "E33: removing it from Jira removes it from both chains" "$(q '[.chains[].across[] | select(.kind == "jira-link")] | length')" "0"

# --- E24: step, steps and the badge cap ---------------------------------------
reset
reg chain-8004=8016,8005,8006 chain-a=8005 chain-b=8005
issue HIMMEL-8004 "To Do" type=Epic
issue HIMMEL-8016 "In Progress" parent=HIMMEL-8004
issue HIMMEL-8005 "To Do" parent=HIMMEL-8004 bb='["HIMMEL-8016"]' labels='["chain-a","chain-b"]'
issue HIMMEL-8006 "To Do" parent=HIMMEL-8004 bb='["HIMMEL-8005"]'
cs
check "E24: a ticket's badge gives its step of the chain's steps" "$(tk HIMMEL-8005 '.chains[] | select(.id == "chain-8004") | "\(.step)/\(.steps)"')" "2/3"
check "E24: a ticket in three chains shows two badges" "$(tk "$KP"-8005 '.badges | length')" "2"
check "E24: then +1" "$(tk "$KP"-8005 .more)" "1"
check "E24: next is the lowest step that can launch" "$(q '.chains[] | select(.id == "chain-8004") | .next')" "null"

# --- hold kinds: waits on you, date-gated --------------------------------------
reset
reg chain-x=1,2,3
issue HIMMEL-1 "To Do" labels='["chain-x"]'
issue HIMMEL-2 "To Do" labels='["chain-x"]'
issue HIMMEL-3 "To Do" labels='["chain-x"]'
cl '{"ts":"2026-11-01T00:00:00Z","change":"hold","key":"HIMMEL-1","kind":"operator","who":"chief","reason":"your go"}'
cl '{"ts":"2026-11-01T00:00:00Z","change":"hold","key":"HIMMEL-2","kind":"date","who":"chief","reason":"not before","until":"2026-11-07"}'
ev '{"ts":"2026-11-01T00:00:00Z","event":"hold","key":"HIMMEL-3","result":"moved"}'
cs
check "kinds: an operator hold reads waits on you" "$(tk "$KP"-1 .state)" "waits on you"
check "kinds: a date hold before its date reads date-gated" "$(tk "$KP"-2 .state)" "date-gated"
check "kinds: a hold set without a kind still waits" "$(tk "$KP"-3 .state)" "waits on hold"
check "kinds: the Why fields carry kind, source, added, clears" \
    "$(tk "$KP"-2 '.links[0] | .kind + " " + .source + " " + .added + " " + .clears')" "date chain-log 2026-11-01T00:00:00Z 2026-11-07"
NOW=2026-11-08T00:00:00Z cs
check "kinds: past its date the date hold clears" "$(tk "$KP"-2 .state)" "can launch"
check "kinds: next is the lowest step that can launch" "$(q '.chains[0].next | "\(.step) " + (.keys | join(" "))')" "1 HIMMEL-2"
reset
reg chain-x=1
issue HIMMEL-1 "To Do" labels='["chain-x"]'
ev '{"ts":"2026-11-01T00:00:00Z","event":"hold","key":"HIMMEL-1","kind":"operator","result":"moved"}'
cs
check "kinds: a typed hold whose chain-log row is missing still waits, from its event row" "$(tk "$KP"-1 .state)" "waits on you"
reset
reg chain-x=1
issue HIMMEL-1 "To Do" labels='["chain-x"]'
ev '{"ts":"2026-11-01T00:00:00Z","event":"hold","key":"HIMMEL-1","kind":"date","until":"2026-11-07","result":"moved"}'
NOW=2026-11-08T00:00:00Z cs
check "kinds: and a date hold read from its event row clears past its date" "$(tk "$KP"-1 .state)" "can launch"

# --- an absent chain-log is no holds; one that cannot be read is no answer ------
reset
reg chain-x=1
issue HIMMEL-1 "To Do" labels='["chain-x"]'
cs; rc=$?
st=$(tk HIMMEL-1 .state)
check "chain-log: an absent log reads as no holds" "$rc $st" "0 can launch"
mkdir "$S/chain-log.jsonl"
cs; rc=$?
check "chain-log: a log that cannot be read fails the read instead of reading as no holds" "$rc" 2
contains "chain-log: and the error names the file" "$(cat "$tmp/err")" "chain-log.jsonl"

reset
reg chain-x=1,31
issue HIMMEL-1 "To Do" labels='["chain-x"]'
issue HIMMEL-21 "To Do" labels='["standalone"]' bb='["HIMMEL-22"]'
issue HIMMEL-22 "To Do" labels='["standalone"]' bb='["HIMMEL-21"]'
issue HIMMEL-31 "To Do" labels='["chain-x"]' bb='["HIMMEL-32"]'
issue HIMMEL-32 "To Do" labels='["standalone"]' bb='["HIMMEL-31"]'
issue HIMMEL-41 "To Do" bb='["HIMMEL-43"]'
issue HIMMEL-42 "To Do" bb='["HIMMEL-41"]'
issue HIMMEL-43 "In Progress" bb='["HIMMEL-42"]'
issue HIMMEL-51 "To Do" versions='["v2"]' bb='["HIMMEL-52","HIMMEL-53"]'
issue HIMMEL-52 "To Do" versions='["v2"]' bb='["HIMMEL-51"]'
issue HIMMEL-53 "To Do" labels='["standalone"]' bb='["HIMMEL-51"]'
issue HIMMEL-61 "To Do" labels='["standalone"]' bb='["HIMMEL-69"]'
issue HIMMEL-71 Done bb='["HIMMEL-72"]' resolved=2026-11-01T00:00:00.000+0000
issue HIMMEL-72 "To Do" bb='["HIMMEL-71"]'
cs; rc=$?
check "integrity: exits 0" "$rc" 0
check "integrity: a loop of two standalone tickets, a registered-standalone loop and a loop of three are each listed" \
    "$(q '.cycles | map(join(" ")) | sort | join(",")')" "HIMMEL-21 HIMMEL-22,HIMMEL-31 HIMMEL-32,HIMMEL-41 HIMMEL-42 HIMMEL-43"
contains "integrity: the standalone loop keeps its stderr warn line" "$(cat "$tmp/err")" "WARN cycle HIMMEL-21 HIMMEL-22"
check "integrity: a link whose status cannot be read is listed with the ticket that holds it" \
    "$(q '.unknown | map(.key + " on " + .on) | join(",")')" "HIMMEL-61 on HIMMEL-69"
free_state=$(tk HIMMEL-1 .state)
check "integrity: an unrelated ticket still can launch" "$free_state" "can launch"
node "$SUT" --json --registry "$tmp/registry.json" --mirror "$M" --state "$S" --now "$NOW" > "$tmp/out" 2>"$tmp/err"
check "integrity: with no --version the walk starts from the registry's members only" \
    "$(q '.cycles | map(join(" ")) | join(",")') $(q '.unknown | length')" "HIMMEL-31 HIMMEL-32 0"
reset
reg chain-x=1
issue HIMMEL-1 "To Do" labels='["chain-x"]'
issue HIMMEL-2 "To Do" labels='["standalone"]' bb='["HIMMEL-1"]'
cs
check "integrity: a clean version lists no loop and no unreadable link" "$(q '.cycles | length') $(q '.unknown | length')" "0 0"

KH="$tmp/key-home" KC="$tmp/key-conf" KCACHE="$tmp/key-cache" K2=HIMMEL-2
mkdir -p "$KH/.himmel/state/jira-mirror/CONFKEY" "$KC" "$KCACHE"
printf 'JIRA_PROJECT_KEY=CONFKEY\n' > "$KC/himmel.conf"
: > "$KCACHE/.env"
reset
reg chain-x=1,2
M0="$M"; M="$KH/.himmel/state/jira-mirror/CONFKEY"
issue HIMMEL-1 "In Progress" labels='["chain-x"]'
issue HIMMEL-2 "To Do" labels='["chain-x"]' bb='["HIMMEL-1"]'
M="$M0"
state_in_clean_env() { env -i HOME="$KH" PATH="$PATH" HIMMEL_CONFIG_DIR="$KC" HIMMELCTL_CACHE_DIR="$KCACHE" "$@" \
    node "$SUT" --json --registry "$tmp/registry.json" --version v1 --now "$NOW" > "$tmp/out" 2>"$tmp/err"; state_rc=$?; }
state_in_clean_env
check "default mirror: the himmel.conf run exits 0 with JSON" "$state_rc $(jq -e . "$tmp/out" >/dev/null 2>&1 && echo json || echo none)" "0 json"
check "default mirror: a key only in himmel.conf reads jira-mirror/<that key>" "$(tk $K2 .state)" "waits on step 1"
state_in_clean_env JIRA_PROJECT_KEY=OTHER
check "default mirror: the env key wins over himmel.conf (no mirror there, exit 2)" "$state_rc $(tk $K2 .state | grep -c 'waits on step 1')" "2 0"
state_in_clean_env HIMMEL_JIRA_MIRROR="$KH/.himmel/state/jira-mirror/CONFKEY" JIRA_PROJECT_KEY=OTHER
check "default mirror: HIMMEL_JIRA_MIRROR is read through the resolver" "$(tk $K2 .state)" "waits on step 1"
env -i HOME="$KH" PATH="$PATH" HIMMEL_CONFIG_DIR="$KC" HIMMELCTL_CACHE_DIR="$KCACHE" \
    node "$SUT" --json --registry "$tmp/registry.json" --mirror "$KH/.himmel/state/jira-mirror/CONFKEY" --state "$S" --version v1 --now "$NOW" > "$tmp/out" 2>"$tmp/err"
check "default mirror: --mirror still wins" "$(tk $K2 .state)" "waits on step 1"

echo "---"
[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
