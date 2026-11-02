#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-next-dispatchable.sh
# test-priority-prune.sh — Exercises priority-prune.sh on a fixture chief doc
# and a fixture Jira mirror: no real mirror, Jira or chief doc is touched.
# PRIORITY_PRUNE overrides the script under test (the RED control: a missing
# script fails every row). bash 3.2-safe.
#
# Run: bash scripts/handover/chief-kit/test-priority-prune.sh
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

DOC="$WORK/chief.md"
printf '%s\n' '# chief' '' 'priority: 6127 above Live state is not the line' '' '## Live state' \
    'workers: none' \
    'priority: 6127 | 6137(K1) 6143(K7) 6138(K2) | 6123 6125 | 6132(BOARD +5217 6057) 1481(+6057 6078 6025) (verify-close 1293) 5641d | rest of v1.1.3 | 5993 6100' \
    'versions: v1.1.3' '' '## Results' > "$DOC"
cp "$DOC" "$WORK/chief.orig"

run() { bash "$SUT" --mirror "$M" "$@" 2>/dev/null; }

same "count: closed (Done and wont do) over the keys on the Live state line" "$(run --doc "$DOC" --count)" "7/14"
same "prune drops Done and wont-do keys and keeps the order of the rest" "$(run --doc "$DOC")" \
    'priority: 6143(K7) | 6125 | 6132(BOARD +5217) 1481(+6078) (verify-close 1293) 5641d | rest of v1.1.3 | 5993'
same "prune without --apply writes nothing" "$(cmp -s "$DOC" "$WORK/chief.orig" && echo same)" "same"
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
same "--apply changes no other line" "$(diff "$WORK/chief.orig" "$DOC" | grep -c '^[<>]')" "2"
same "a pruned line counts no closed key" "$(run --doc "$DOC" --count)" "0/7"

# --apply keeps a CRLF doc's line endings.
printf '## Live state\r\nlegs: none\r\npriority: 6127 5993\r\n' > "$WORK/crlf.md"
run --doc "$WORK/crlf.md" --apply >/dev/null
same "--apply keeps CRLF line endings" "$(tr -cd '\r' < "$WORK/crlf.md" | wc -c | tr -d ' ')" "3"
same "--apply prunes a CRLF line" "$(grep -c '^priority: 5993.$' "$WORK/crlf.md")" "1"

# --apply keeps the doc's file mode.
printf '%s\n' '## Live state' 'priority: 6127 5993' > "$WORK/mode.md"
chmod 640 "$WORK/mode.md"
run --doc "$WORK/mode.md" --apply >/dev/null
same "--apply keeps the doc's file mode" "$(find "$WORK/mode.md" -perm 640)" "$WORK/mode.md"

# No line, no doc, no mirror: exit 1 and print nothing.
printf '%s\n' '## Live state' 'workers: none' > "$WORK/none.md"
out="$(run --doc "$WORK/none.md" --count)"; rc=$?
same "no priority: line exits 1" "$rc" "1"
same "no priority: line prints nothing" "$out" ""
bash "$SUT" --mirror "$WORK/no-mirror" --doc "$DOC" --count >/dev/null 2>&1; same "a missing mirror exits 1" "$?" "1"
bash "$SUT" --mirror "$M" >/dev/null 2>&1; same "no --doc is a usage error" "$?" "2"

# --- --from-chains: the line proposed from chain-state.mjs --json output, print-only.
# Chain c1 lists B (9002) before A (9001) but A blocks B (A is step 1, B step 2); c2 shares 9001 and holds a
# Done 9004; c3 lists 9006 before 9005, both step 1; c4 has only Done members.
cat > "$WORK/reg.json" <<'JSON'
{"schema":"himmel.chain-registry/1","chains":[
 {"id":"c1","goal":"A then B in one chain","members":["HIMMEL-9002","HIMMEL-9001"]},
 {"id":"c2","goal":"A shared with a second chain","members":["HIMMEL-9003","HIMMEL-9001","HIMMEL-9004"]},
 {"id":"c3","goal":"Two tickets in the same layer","members":["HIMMEL-9006","HIMMEL-9005"]},
 {"id":"c4","goal":"Every member is already Done","members":["HIMMEL-9007"]}]}
JSON
cat > "$WORK/cs.json" <<JSON
{"schema":"himmel.chains/1","registry":{"path":"$WORK/reg.json"},
 "chains":[{"id":"c1"},{"id":"c2"},{"id":"c3"},{"id":"c4"}],
 "tickets":{
 "HIMMEL-9001":{"done":false,"chains":[{"id":"c1","step":1},{"id":"c2","step":1}]},
 "HIMMEL-9002":{"done":false,"chains":[{"id":"c1","step":2}]},
 "HIMMEL-9003":{"done":false,"chains":[{"id":"c2","step":2}]},
 "HIMMEL-9004":{"done":true,"chains":[{"id":"c2","step":1}]},
 "HIMMEL-9005":{"done":false,"chains":[{"id":"c3","step":1}]},
 "HIMMEL-9006":{"done":false,"chains":[{"id":"c3","step":1}]},
 "HIMMEL-9007":{"done":true,"chains":[{"id":"c4","step":1}]}}}
JSON
printf '%s\n' '# chief' '' '## Live state' 'priority: 6127 5993' 'focus-version: v1.1.3' '' '## Results' > "$WORK/fc.md"
cp "$WORK/fc.md" "$WORK/fc.orig"
fc="$(run --doc "$WORK/fc.md" --from-chains "$WORK/cs.json")"
case "$fc" in "priority: 9001 9002 | 9003 | 9006 9005 | rest of v1.1.3") pass "--from-chains" ;; *) fail "--from-chains (got '$fc')" ;; esac
same "--from-chains: a blocker prints before the ticket it blocks although the registry lists the blocked one first" \
    "$(printf '%s\n' "$fc" | sed -n 's/^priority: \(9001 9002\) .*/\1/p')" "9001 9002"
same "--from-chains: a member shared by two chains prints once" "$(printf '%s\n' "$fc" | grep -o 9001 | wc -l | tr -d ' ')" "1"
same "--from-chains: a Done member and a chain with no open member print nothing" "$(printf '%s\n' "$fc" | grep -c '9004\|9007')" "0"
same "--from-chains: within a layer the registry member order holds" "$(printf '%s\n' "$fc" | sed -n 's/.*| \(9006 9005\) |.*/\1/p')" "9006 9005"
same "--from-chains writes nothing" "$(cmp -s "$WORK/fc.md" "$WORK/fc.orig" && echo same)" "same"
bash "$SUT" --mirror "$M" --doc "$WORK/fc.md" --from-chains "$WORK/cs.json" --apply >/dev/null 2>&1
same "--from-chains with --apply is a usage error" "$?" "2"
same "--from-chains with --apply still writes nothing" "$(cmp -s "$WORK/fc.md" "$WORK/fc.orig" && echo same)" "same"
printf '%s\n' '## Live state' 'priority: 6127' > "$WORK/nofv.md"
same "--from-chains without a focus-version: line has no rest-of tail" "$(run --doc "$WORK/nofv.md" --from-chains "$WORK/cs.json")" \
    "priority: 9001 9002 | 9003 | 9006 9005"
bash "$SUT" --mirror "$M" --doc "$WORK/fc.md" --from-chains "$WORK/no-such.json" >/dev/null 2>&1; same "--from-chains with a missing state file exits 1" "$?" "1"
bash "$SUT" --mirror "$M" --doc "$WORK/fc.md" --from-chains "" --apply >/dev/null 2>&1; same "an empty --from-chains value with --apply is a usage error" "$?" "2"
same "an empty --from-chains value with --apply writes nothing" "$(cmp -s "$WORK/fc.md" "$WORK/fc.orig" && echo same)" "same"
# The state records the registry's sha256: a registry that changed since is refused, a matching one is read.
reg_sha="$(sha256sum "$WORK/reg.json" | cut -d' ' -f1)"
sed "s|\"registry\":{\"path\":\"$WORK/reg.json\"}|\"registry\":{\"path\":\"$WORK/reg.json\",\"sha256\":\"$reg_sha\"}|" "$WORK/cs.json" > "$WORK/cs-sha.json"
same "--from-chains: a state whose registry sha256 matches is read" "$(run --doc "$WORK/fc.md" --from-chains "$WORK/cs-sha.json")" "$fc"
sed "s|\"sha256\":\"$reg_sha\"|\"sha256\":\"0000\"|" "$WORK/cs-sha.json" > "$WORK/cs-badsha.json"
out="$(run --doc "$WORK/fc.md" --from-chains "$WORK/cs-badsha.json")"; rc=$?
same "--from-chains: a registry that changed since the state was read exits 1" "$rc" "1"
same "--from-chains: a registry that changed prints no proposal" "$out" ""

# --- --stale: <open>/<total> then `low` under 25 % open, then each open key whose fixVersion is not the focus-version.
mkv() { # <num> <statusCategory> <fixVersions json>
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "Task"\nstatus: "x"\nstatusCategory: "%s"\npriority: "Medium"\nlabels: []\nfixVersions: %s\n---\n\n# HIMMEL-%s: t\n' \
        "$1" "$2" "$3" "$1" > "$M/HIMMEL-$1.md"
}
mkv 7001 Done '["v1.1.3"]'; mkv 7002 Done '["v1.1.3"]'; mkv 7003 Done '["v1.1.3"]'; mkv 7004 "To Do" '["v1.1.3"]'
mkv 7005 "To Do" '["v1.1.5"]'; mkv 7006 "To Do" '[]'
printf '%s\n' '## Live state' 'priority: 7001 7002 7003 7004' 'focus-version: v1.1.3' > "$WORK/s1.md"
same "--stale: 1 open key of 4 is exactly 25 %, not low" "$(run --doc "$WORK/s1.md" --stale)" "1/4"
printf '%s\n' '## Live state' 'priority: 7001 7002 7003 7004 7006' 'focus-version: v1.1.3' > "$WORK/s2.md"
same "--stale: an open key with no fixVersion is not off-version" "$(run --doc "$WORK/s2.md" --stale)" "2/5"
printf '%s\n' '## Live state' 'priority: 7001 7002 7003 7004 9998 7001' 'focus-version: v1.1.3' > "$WORK/s3.md"
same "--stale: a key missing from the mirror is open" "$(run --doc "$WORK/s3.md" --stale)" "2/5"
printf '%s\n' '## Live state' 'priority: 7001 7002 7003 7004' 'focus-version: v1.1.3' > "$WORK/s4.md"
mkv 7004 Done '["v1.1.3"]'
same "--stale: every key closed is 0 open of 4, low" "$(run --doc "$WORK/s4.md" --stale)" "0/4 low"
mkv 7004 "To Do" '["v1.1.3"]'
mkv 7007 "To Do" '["New Version 1"]'
printf '%s\n' '## Live state' 'priority: 7001 7002 7003 7007 7004' 'focus-version: v1.1.3' > "$WORK/s9.md"
same "--stale: a fixVersion name with spaces stays one token" "$(run --doc "$WORK/s9.md" --stale)" "2/5 HIMMEL-7007@New_Version_1"
printf '%s\n' '## Live state' 'priority: 7001 7002 7003 7005 7004 7003' 'focus-version: v1.1.3' > "$WORK/s5.md"
same "--stale: an open v1.1.5 key under focus-version v1.1.3 is named" "$(run --doc "$WORK/s5.md" --stale)" "2/5 HIMMEL-7005@v1.1.5"
printf '%s\n' '## Live state' 'priority: 7001 7002 7003 7005 7004 7003' 'focus-version: auto' > "$WORK/s6.md"
same "--stale: focus-version: auto names no off-version key" "$(run --doc "$WORK/s6.md" --stale)" "2/5"
big="priority:"; for n in $(seq 7101 7180); do mkv "$n" Done '["v1.1.3"]'; big="$big $n"; done
printf '%s\n' '## Live state' "$big 7004" 'focus-version: v1.1.3' > "$WORK/s7.md"
same "--stale: 1 open key of 81 is low" "$(run --doc "$WORK/s7.md" --stale)" "1/81 low"
printf '%s\n' '## Live state' 'workers: none' > "$WORK/s8.md"
out="$(run --doc "$WORK/s8.md" --stale)"; rc=$?
same "--stale: no priority: line exits 1" "$rc" "1"

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-priority-prune.sh'
    exit 0
fi
printf 'FAIL - test-priority-prune.sh (%s failure(s))\n' "$fails"
exit 1
