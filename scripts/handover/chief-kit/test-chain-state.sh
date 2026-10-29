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
# Platform guard: POSIX bash 3.2+, no .ps1 twin by design (shell-only harness).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/chain-state.mjs"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/chain-state-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]"; fails=$((fails+1)) ;; esac; }

M="$tmp/mirror" S="$tmp/state" NOW=2026-11-05T00:00:00Z
reset() { rm -rf "$M" "$S"; mkdir -p "$M" "$S"; }

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
cs() { node "$SUT" --json --mirror "$M" --state "$S" --version v1 --now "$NOW" > "$tmp/out" 2>"$tmp/err"; }
q()  { jq -r "$1" "$tmp/out" 2>/dev/null; }
tk() { q ".tickets[\"$1\"]$2"; }

# --- E25: blocked means a real block ----------------------------------------
reset
issue HIMMEL-1 "In Progress" labels='["chain-mem"]'
issue HIMMEL-2 "To Do" labels='["chain-mem"]' bb='["HIMMEL-1"]'
issue HIMMEL-3 "To Do" labels='["chain-mem"]' bb='["HIMMEL-9"]'
issue HIMMEL-9 "To Do" versions='["v2"]'
issue HIMMEL-4 "To Do" labels='["chain-mem"]'
cs; rc=$?
check "E25: exits 0" "$rc" 0
check "E25: the schema is himmel.chains/1" "$(q .schema)" "himmel.chains/1"
check "E25: a ticket whose only open link is an earlier step of a moving chain waits on that step, not blocked" \
    "$(tk HIMMEL-2 .state)" "waits on step 1"
check "E25: the earlier step is in flight" "$(tk HIMMEL-1 .state)" "in flight"
check "E25: an open blocker outside the version is a real block" "$(tk HIMMEL-3 .state)" "blocked"
check "E25: nothing open stops a ticket: can launch" "$(tk HIMMEL-4 .state)" "can launch"
check "E25: a ticket in no chain is not listed" "$(tk HIMMEL-9 .key)" "null"

# --- E29: the order check at the completing merge ----------------------------
reset
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
    "$(tk HIMMEL-7379 .state)" "done · order held"
check "E29: the two partial PRs are ticks with their numbers" "$(tk HIMMEL-7379 '.ticks | map(.pr) | join(" ")')" "101 102"
check "E29: and their times" "$(tk HIMMEL-7379 '.ticks[0].ts')" "2026-11-01T16:40:00Z"
check "E29: the check reads the completing merge" "$(tk HIMMEL-7379 '.check.merge | .pr + " " + .ts')" "103 2026-11-02T18:40:00Z"
check "E29: and gives the time the hold cleared" "$(tk HIMMEL-7379 '.check.links[0].at')" "2026-11-02T15:10:00Z"
check "E29: a ticket completed before the chain existed is not checked" "$(tk HIMMEL-7125 .check.result)" "not-checked"
check "E29: a ticket closed by hand is read at its last PR merged before Jira went Done" "$(tk HIMMEL-7380 .check.merge.pr)" "302"

reset
issue HIMMEL-8004 "To Do" type=Epic
issue HIMMEL-8005 Done parent=HIMMEL-8004 resolved=2026-11-02T15:20:00.000+0000
issue HIMMEL-7379 Done parent=HIMMEL-8004 resolved=2026-11-02T14:10:00.000+0000
cl '{"ts":"2026-10-28T20:56:00Z","change":"hold","key":"HIMMEL-7379","kind":"file-collision","on":"HIMMEL-8005","who":"chief","reason":"the memory notice file"}'
merge 2026-11-02T14:00:00Z HIMMEL-7379 103 yes
merge 2026-11-02T15:10:00Z HIMMEL-8005 200 yes
cs
check "E29: the completing PR merging before the hold clears reads out of order" "$(tk HIMMEL-7379 .state)" "done · out of order"
check "E29: with the hold record that stood open" "$(tk HIMMEL-7379 '.check.links[0] | .on + " " + .kind + " " + .status + " " + .added')" \
    "HIMMEL-8005 file-collision open 2026-10-28T20:56:00Z"

# --- E30: a chain changes ----------------------------------------------------
reset
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
check "E30: a reorder before the merge: the check reads the chain as of the merge (held)" "$(tk HIMMEL-8010 .state)" "done · order held"
check "E30: the reordered ticket is now the earlier step" "$(tk HIMMEL-8010 '.chains[0].step') $(tk HIMMEL-8009 '.chains[0].step')" "1 2"
check "E30: the change log lists each change in time order" \
    "$(q '.chains[0].log | map(.change) | join(" ")')" "hold release hold add remove"
check "E30: with its kind, reason and source" "$(q '.chains[0].log[2] | .kind + " " + .reason + " " + .who')" "chain-order docs land first chief"
check "E30: n/m follows the chain's tickets" "$(q '.chains[0] | "\(.done)/\(.total)"')" "1/3"
reset
issue HIMMEL-8009 "To Do" labels='["chain-mem"]'
issue HIMMEL-8010 "To Do" labels='["chain-mem"]'
cl '{"ts":"2026-10-28T20:56:00Z","change":"hold","key":"HIMMEL-8010","kind":"chain-order","on":"HIMMEL-8009","who":"chief","reason":"r"}'
cl '{"ts":"2026-11-03T12:00:00Z","change":"release","key":"HIMMEL-8010","who":"chief"}'
cl '{"ts":"2026-11-06T00:00:00Z","change":"hold","key":"HIMMEL-8009","kind":"chain-order","on":"HIMMEL-8010","who":"chief","reason":"r"}'
cs
check "E30: a hold released before its target completed, and one not yet set, add no step" \
    "$(tk HIMMEL-8010 '.chains[0].step') $(tk HIMMEL-8009 '.chains[0].step')" "1 1"

# --- E33: links across other work ---------------------------------------------
reset
issue HIMMEL-6000 "To Do" type=Epic
issue HIMMEL-6713 "In Progress" parent=HIMMEL-6000
issue HIMMEL-7120 "In Progress" labels='["chain-macos"]'
issue HIMMEL-7101 "To Do" labels='["chain-macos"]' bb='["HIMMEL-6000"]'
cl '{"ts":"2026-10-28T20:56:00Z","change":"hold","key":"HIMMEL-6713","kind":"file-collision","on":"HIMMEL-7120","who":"chief","reason":"scripts/hooks/"}'
cs
check "E33: the waiting chain lists the link across other work" \
    "$(q '.chains[] | select(.id == "HIMMEL-6000") | .across[] | select(.on == "HIMMEL-7120") | .dir + " " + .key + " " + .kind + " " + (.chains | join(","))')" \
    "waits-on HIMMEL-6713 file-collision chain-macos"
check "E33: the held-up chain lists the same link" \
    "$(q '.chains[] | select(.id == "chain-macos") | .across[] | select(.key == "HIMMEL-6713") | .dir + " " + .on + " " + .kind')" \
    "holds-up HIMMEL-7120 file-collision"
check "E33: a chain is named by its epic or its chain- label" "$(q '[.chains[] | .id + ":" + .source] | join(" ")')" "HIMMEL-6000:epic chain-macos:label"
check "E33: a Jira link across chains shows too" "$(q '[.chains[] | select(.id == "chain-macos") | .across[] | select(.kind == "jira-link") | .on] | join(" ")')" "HIMMEL-6000"
issue HIMMEL-7101 "To Do" labels='["chain-macos"]'
cs
check "E33: removing it from Jira removes it from both chains" "$(q '[.chains[].across[] | select(.kind == "jira-link")] | length')" "0"

# --- E24: step, steps and the badge cap ---------------------------------------
reset
issue HIMMEL-8004 "To Do" type=Epic
issue HIMMEL-8016 "In Progress" parent=HIMMEL-8004
issue HIMMEL-8005 "To Do" parent=HIMMEL-8004 bb='["HIMMEL-8016"]' labels='["chain-a","chain-b"]'
issue HIMMEL-8006 "To Do" parent=HIMMEL-8004 bb='["HIMMEL-8005"]'
cs
check "E24: a ticket's badge gives its step of the chain's steps" "$(tk HIMMEL-8005 '.chains[] | select(.id == "HIMMEL-8004") | "\(.step)/\(.steps)"')" "2/3"
check "E24: a ticket in three chains shows two badges" "$(tk HIMMEL-8005 '.badges | length')" "2"
check "E24: then +1" "$(tk HIMMEL-8005 .more)" "1"
check "E24: next is the lowest step that can launch" "$(q '.chains[] | select(.id == "HIMMEL-8004") | .next')" "null"

# --- hold kinds: waits on you, date-gated --------------------------------------
reset
issue HIMMEL-1 "To Do" labels='["chain-x"]'
issue HIMMEL-2 "To Do" labels='["chain-x"]'
issue HIMMEL-3 "To Do" labels='["chain-x"]'
cl '{"ts":"2026-11-01T00:00:00Z","change":"hold","key":"HIMMEL-1","kind":"operator","who":"chief","reason":"your go"}'
cl '{"ts":"2026-11-01T00:00:00Z","change":"hold","key":"HIMMEL-2","kind":"date","who":"chief","reason":"not before","until":"2026-11-07"}'
ev '{"ts":"2026-11-01T00:00:00Z","event":"hold","key":"HIMMEL-3","result":"moved"}'
cs
check "kinds: an operator hold reads waits on you" "$(tk HIMMEL-1 .state)" "waits on you"
check "kinds: a date hold before its date reads date-gated" "$(tk HIMMEL-2 .state)" "date-gated"
check "kinds: a hold set without a kind still waits" "$(tk HIMMEL-3 .state)" "waits on hold"
check "kinds: the Why fields carry kind, source, added, clears" \
    "$(tk HIMMEL-2 '.links[0] | .kind + " " + .source + " " + .added + " " + .clears')" "date chain-log 2026-11-01T00:00:00Z 2026-11-07"
NOW=2026-11-08T00:00:00Z cs
check "kinds: past its date the date hold clears" "$(tk HIMMEL-2 .state)" "can launch"
check "kinds: next is the lowest step that can launch" "$(q '.chains[0].next | "\(.step) " + (.keys | join(" "))')" "1 HIMMEL-2"
reset
issue HIMMEL-1 "To Do" labels='["chain-x"]'
ev '{"ts":"2026-11-01T00:00:00Z","event":"hold","key":"HIMMEL-1","kind":"operator","result":"moved"}'
cs
check "kinds: a typed hold whose chain-log row is missing still waits, from its event row" "$(tk HIMMEL-1 .state)" "waits on you"
reset
issue HIMMEL-1 "To Do" labels='["chain-x"]'
ev '{"ts":"2026-11-01T00:00:00Z","event":"hold","key":"HIMMEL-1","kind":"date","until":"2026-11-07","result":"moved"}'
NOW=2026-11-08T00:00:00Z cs
check "kinds: and a date hold read from its event row clears past its date" "$(tk HIMMEL-1 .state)" "can launch"

echo "---"
[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
