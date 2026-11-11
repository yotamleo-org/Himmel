#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()
# scripts/handover/chief-kit/test-chain-add.sh - suite for chain-add.sh, the chain registry writer:
#   1. two linked open keys in no chain open a new chain with the given goal; chain-state.mjs
#      then reports neither unchained
#   2. a key joins the existing chain that holds the other key; that chain keeps its goal
#   3. a pair already in one chain changes nothing
#   4. a refusal leaves the registry byte for byte: a goal over 90 characters or under 3 words,
#      a new chain with no goal, a key not open, a key outside the version, an unlinked pair,
#      keys in two chains, an invalid registry
#   5. usage errors exit 2
#
# Hermetic: a temp mirror and registry, never the real ones. PLATFORM GUARD: Linux-only kit.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/chain-add.sh"

if ! command -v node >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "skip - test-chain-add.sh: needs node and jq (the chief kit is Linux-only)"
    exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/chain-add-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

M="$tmp/mirror" S="$tmp/state" R="$tmp/chains.json"
mkdir -p "$M" "$S"
# issue <KEY> <statusCategory> <versions json> <blocked_by json> [labels json]
issue() {
    printf -- '---\nkey: "%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "%s"\nlabels: %s\nfixVersions: %s\nparent: null\nresolved: null\nlinks:\n  blocks: []\n  blocked_by: %s\n  relates: []\n---\n\n# %s: title of %s\n' \
        "$1" "$2" "$2" "${5:-[]}" "$3" "$4" "$1" "$1" > "$M/$1.md"
}
issue HIMMEL-1 "To Do" '["v1"]' '[]'
issue HIMMEL-2 "In Progress" '["v1"]' '["is blocked by HIMMEL-1"]'
issue HIMMEL-3 "To Do" '["v1"]' '["is blocked by HIMMEL-2"]'
issue HIMMEL-4 "Done" '["v1"]' '["is blocked by HIMMEL-1"]'
issue HIMMEL-5 "To Do" '["v2"]' '["is blocked by HIMMEL-1"]'
issue HIMMEL-6 "To Do" '["v1"]' '[]' '["standalone"]'
issue HIMMEL-7 "To Do" '["v1"]' '["is blocked by HIMMEL-9"]' '["standalone"]'
issue HIMMEL-9 "To Do" '["v1"]' '[]'
printf '{"schema":"himmel.chain-registry/1","chains":[{"id":"other-work","goal":"Other work lands before the rest","members":["HIMMEL-9"]}]}\n' > "$R"

add() { bash "$SUT" "$@" --registry "$R" --mirror "$M" > "$tmp/out" 2> "$tmp/err"; }
unchained() { node "$HERE/chain-state.mjs" --json --registry "$R" --mirror "$M" --state "$S" --version v1 2>&1 >/dev/null | sed -n 's/^WARN unchained=//p'; }

check '0. control: before chain-add the keys read unchained' '3 HIMMEL-1 HIMMEL-2 HIMMEL-3' "$(unchained)"

# 1. a new chain with the goal
add HIMMEL-1 HIMMEL-2 --goal "The waiter wakes once before the drain line"; rc=$?
check '1. a new chain is opened (rc 0)' 0 "$rc"
check '1. it holds both keys' 'HIMMEL-1,HIMMEL-2' "$(jq -r '.chains[] | select(.members | index("HIMMEL-1")) | .members | join(",")' "$R")"
check '1. it carries the goal' 'The waiter wakes once before the drain line' "$(jq -r '.chains[] | select(.members | index("HIMMEL-1")) | .goal' "$R")"
check '1. its id is the goal, slugged' 'the-waiter-wakes-once-before' "$(jq -r '.chains[] | select(.members | index("HIMMEL-1")) | .id' "$R")"
check '1. the other chain is kept' 'Other work lands before the rest|HIMMEL-9' "$(jq -r '.chains[] | select(.id == "other-work") | .goal + "|" + (.members | join(","))' "$R")"
check '1. chain-state.mjs no longer lists the two keys unchained' '1 HIMMEL-3' "$(unchained)"

# 2. a key joins the chain that holds the other
add HIMMEL-2 HIMMEL-3; rc=$?
check '2. a key joins the existing chain (rc 0)' 0 "$rc"
check '2. no new chain is opened' 2 "$(jq '.chains | length' "$R")"
check '2. the chain holds the three keys' 'HIMMEL-1,HIMMEL-2,HIMMEL-3' "$(jq -r '.chains[] | select(.members | index("HIMMEL-1")) | .members | join(",")' "$R")"
check '2. the chain keeps its goal' 'The waiter wakes once before the drain line' "$(jq -r '.chains[] | select(.members | index("HIMMEL-3")) | .goal' "$R")"
check '2. chain-state.mjs prints unchained=0' 0 "$(unchained)"
add HIMMEL-7 HIMMEL-9; rc=$?
check '2. a key joins a chain that holds its blocker (rc 0)' 0 "$rc"
check '2. that key joined other-work' 'HIMMEL-9,HIMMEL-7' "$(jq -r '.chains[] | select(.id == "other-work") | .members | join(",")' "$R")"

# 3. a pair already in one chain
cp "$R" "$tmp/before"
add HIMMEL-1 HIMMEL-2 --goal "The waiter wakes once before the drain line"; rc=$?
check '3. a pair already in one chain exits 0' 0 "$rc"
check '3. and changes nothing' "$(cat "$tmp/before")" "$(cat "$R")"

# 4. refusals leave the registry byte for byte
refused() { # <label> <args...>
    local label="$1"; shift
    cp "$R" "$tmp/before"
    add "$@"; local rc=$?
    check "4. $label is refused (rc 1)" 1 "$rc"
    check "4. $label leaves the registry unchanged" "$(cat "$tmp/before")" "$(cat "$R")"
}
issue HIMMEL-11 "To Do" '["v1"]' '[]'
issue HIMMEL-12 "To Do" '["v1"]' '["is blocked by HIMMEL-11"]'
long="$(printf 'word %.0s' $(seq 1 18))end"
refused 'a goal over 90 characters' HIMMEL-11 HIMMEL-12 --goal "$long"
refused 'a goal under 3 words' HIMMEL-11 HIMMEL-12 --goal "Two words"
refused 'a new chain with no goal' HIMMEL-11 HIMMEL-12
refused 'a key that is not open' HIMMEL-1 HIMMEL-4 --goal "A done key joins nothing"
refused 'a key outside the version' HIMMEL-1 HIMMEL-5 --version v1 --goal "A later key joins nothing"
refused 'two keys in no shared version' HIMMEL-1 HIMMEL-5 --goal "A later key joins nothing"
refused 'an unlinked pair' HIMMEL-1 HIMMEL-6 --goal "Unlinked keys join nothing here"
refused 'keys held by two chains' HIMMEL-3 HIMMEL-9 --goal "Two chains are never merged here"
refused 'a key missing from the mirror' HIMMEL-11 HIMMEL-99 --goal "An unknown key joins nothing"
refused 'a new chain whose id is taken' HIMMEL-11 HIMMEL-12 --id other-work --goal "A taken id opens nothing"
printf '{"schema":"himmel.chain-registry/1","chains":[{"id":"x","goal":"short","members":["HIMMEL-9"]}]}\n' > "$R"
refused 'an invalid registry' HIMMEL-11 HIMMEL-12 --goal "A valid goal for a new chain"

# 5. usage
bash "$SUT" HIMMEL-1 >/dev/null 2>&1; rc=$?
check '5. one key is a usage error' 2 "$rc"
bash "$SUT" HIMMEL-1 HIMMEL-1 --goal "The same key twice here" --registry "$R" --mirror "$M" >/dev/null 2>&1; rc=$?
check '5. the same key twice is a usage error' 2 "$rc"
bash "$SUT" HIMMEL-1 HIMMEL-2 --bogus >/dev/null 2>&1; rc=$?
check '5. an unknown option is a usage error' 2 "$rc"

[ "$fails" -eq 0 ] && echo "PASS" || { echo "$fails FAILED"; exit 1; }
