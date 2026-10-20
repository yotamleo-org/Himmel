#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-next-dispatchable.sh
# test-priority-prune.sh — Exercises priority-prune.sh on a fixture console doc
# and a fixture Jira mirror: no real mirror, Jira or console doc is touched.
# PRIORITY_PRUNE overrides the script under test (the RED control: a missing
# script fails every row). bash 3.2-safe.
#
# Run: bash scripts/handover/console-kit/test-priority-prune.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${PRIORITY_PRUNE:-$HERE/priority-prune.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
same() { # <name> <got> <want>
    [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/priority-prune-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
M="$WORK/jira-mirror/HIMMEL"; mkdir -p "$M"

mk() { # <num> <status> <statusCategory>
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "%s"\npriority: "Medium"\nlabels: []\nfixVersions: []\n---\n\n# HIMMEL-%s: t\n' \
        "$1" "$2" "$3" "$1" > "$M/HIMMEL-$1.md"
}
for n in 6127 6138 6123 6057 6025 6100 1293; do mk "$n" Done Done; done
mk 6137 "wont do" Done
mk 6143 "To Do" "To Do"
mk 6125 "In Progress" "In Progress"
mk 6132 "IN CI" "In Progress"
mk 1481 "To Do" "To Do"
mk 6078 "In Review" "In Progress"
mk 5993 "To Do" "To Do"
mk 5217 "To Do" "To Do"

DOC="$WORK/console.md"
printf '%s\n' '# console' '' 'priority: 6127 above Live state is not the line' '' '## Live state' \
    'legs: none' \
    'priority: 6127 | 6137(K1) 6143(K7) 6138(K2) | 6123 6125 | 6132(BOARD +5217 6057) 1481(+6057 6078 6025) (verify-close 1293) 5641d | rest of v1.1.3 | 5993 6100' \
    'versions: v1.1.3' '' '## Results' > "$DOC"
cp "$DOC" "$WORK/console.orig"

run() { bash "$SUT" --mirror "$M" "$@" 2>/dev/null; }

same "count: closed (Done and wont do) over the keys on the Live state line" "$(run --doc "$DOC" --count)" "7/14"
same "prune drops Done and wont-do keys and keeps the order of the rest" "$(run --doc "$DOC")" \
    'priority: 6143(K7) | 6125 | 6132(BOARD +5217) 1481(+6078) (verify-close 1293) 5641d | rest of v1.1.3 | 5993'
same "prune without --apply writes nothing" "$(cmp -s "$DOC" "$WORK/console.orig" && echo same)" "same"
dropped="$(bash "$SUT" --mirror "$M" --doc "$DOC" 2>&1 >/dev/null)"
case "$dropped" in *"dropped 7: 6127 6137 6138 6123 6057 6025 6100"*) pass "stderr names the dropped keys" ;; *) fail "stderr names the dropped keys (got '$dropped')" ;; esac

# An open key inside a closed key's group keeps the group.
printf '%s\n' '## Live state' 'priority: 6123(+5217) 6127(K1) 5993' > "$WORK/g.md"
same "a closed key's group is kept while it holds an open key" "$(run --doc "$WORK/g.md")" 'priority: (+5217) 5993'

# A key missing from the mirror counts as open.
printf '%s\n' '## Live state' '- **priority:** 9999 6127' > "$WORK/m.md"
same "a key missing from the mirror is open" "$(run --doc "$WORK/m.md" --count)" "1/2"
same "a bulleted bold priority: line keeps its prefix" "$(run --doc "$WORK/m.md")" '- **priority:** 9999'

# Every key closed: the line reads none.
printf '%s\n' '## Live state' 'priority: 6127 | 6138' > "$WORK/all.md"
same "every key closed reads none" "$(run --doc "$WORK/all.md")" 'priority: none'

# --apply rewrites only the Live state priority: line.
run --doc "$DOC" --apply >/dev/null
same "--apply rewrites the Live state line" "$(grep -c '^priority: 6143(K7) | 6125 | ' "$DOC")" "1"
same "--apply keeps the line above Live state" "$(grep -c '^priority: 6127 above Live state' "$DOC")" "1"
same "--apply changes no other line" "$(diff "$WORK/console.orig" "$DOC" | grep -c '^[<>]')" "2"
same "a pruned line counts no closed key" "$(run --doc "$DOC" --count)" "0/7"

# No line, no doc, no mirror: exit 1 and print nothing.
printf '%s\n' '## Live state' 'legs: none' > "$WORK/none.md"
out="$(run --doc "$WORK/none.md" --count)"; rc=$?
same "no priority: line exits 1" "$rc" "1"
same "no priority: line prints nothing" "$out" ""
bash "$SUT" --mirror "$WORK/no-mirror" --doc "$DOC" --count >/dev/null 2>&1; same "a missing mirror exits 1" "$?" "1"
bash "$SUT" --mirror "$M" >/dev/null 2>&1; same "no --doc is a usage error" "$?" "2"

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-priority-prune.sh'
    exit 0
fi
printf 'FAIL - test-priority-prune.sh (%s failure(s))\n' "$fails"
exit 1
