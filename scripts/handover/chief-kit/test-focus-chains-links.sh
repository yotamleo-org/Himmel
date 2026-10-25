#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-gen-briefs.sh
# test-focus-chains-links.sh — Exercises focus-chains-links.sh on a fixture chains file
# and mirror: the dry-run states (new / linked / reversed / closed / unknown), that a dry
# run and an --apply without --chain write nothing, that --apply writes only the `new`
# rows of the named chains, and the read-back verdict. A fake jira (FCL_JIRA) records
# every call; nothing reaches Jira. FOCUS_CHAINS_LINKS overrides the script under test
# (the RED control: a missing script fails every row). bash 3.2-safe.
#
# Run: bash scripts/handover/console-kit/test-focus-chains-links.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${FOCUS_CHAINS_LINKS:-$HERE/focus-chains-links.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac; }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/focus-chains-links-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
M="$WORK/mirror"; mkdir -p "$M"

mk() { # <n> <statusCategory> <blocks> <blocked_by>
    printf -- '---\nkey: "HIMMEL-%s"\nstatusCategory: "%s"\nlinks:\n  blocks: [%s]\n  blocked_by: [%s]\n  relates: []\n---\n\n# HIMMEL-%s\n' "$1" "$2" "$3" "$4" "$1" > "$M/HIMMEL-$1.md"
}
mk 1 "To Do" "" ""
mk 2 "To Do" "" ""
mk 3 "To Do" "" '"HIMMEL-2"'
mk 4 "Done" "" ""
mk 5 "To Do" '"HIMMEL-6"' ""
mk 6 "To Do" "" '"HIMMEL-5"'
cat > "$WORK/chains.json" <<'EOF'
[
 {"name": "A — order", "steps": [{"key": "HIMMEL-1"}, {"key": "HIMMEL-2"}, {"key": "HIMMEL-3"}, {"key": "HIMMEL-4"}]},
 {"name": "B — group", "steps": [{"key": "HIMMEL-6"}, {"key": "HIMMEL-5"}, {"key": "HIMMEL-9"}]},
 {"name": "C — again", "steps": [{"key": "HIMMEL-1"}, {"key": "HIMMEL-2"}, {"key": "HIMMEL-7"}, {"key": "HIMMEL-2"}]},
 {"name": "D — loop", "steps": [{"key": "HIMMEL-8"}, {"key": "HIMMEL-10"}, {"key": "HIMMEL-11"}, {"key": "HIMMEL-8"}]},
 {"name": "E — via mirror", "steps": [{"key": "HIMMEL-12"}, {"key": "HIMMEL-13"}]},
 {"name": "F — against A", "steps": [{"key": "HIMMEL-2"}, {"key": "HIMMEL-1"}]},
 {"name": "G — via blocked_by", "steps": [{"key": "HIMMEL-15"}, {"key": "HIMMEL-16"}]}
]
EOF
mk 7 "To Do" "" ""
mk 8 "To Do" "" ""
mk 10 "To Do" "" ""
mk 11 "To Do" "" ""
mk 12 "To Do" "" '"HIMMEL-14"'
mk 13 "To Do" '"HIMMEL-14"' ""
mk 14 "To Do" '"HIMMEL-12"' '"HIMMEL-13"'
mk 15 "To Do" "" ""
mk 16 "To Do" "" ""
mk 17 "To Do" '"HIMMEL-15"' '"HIMMEL-16"'
# fake jira: logs each call; `links` answers from $WORK/links.<key>
cat > "$WORK/jira" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/calls"
case "\$1" in
    link) echo "Linked: \$2 blocks \$4" ;;
    links) [ -f "$WORK/links-down" ] && { echo "jira: 503 unavailable" >&2; exit 1; }
           cat "$WORK/links.\$2" 2>/dev/null || true ;;
esac
EOF
chmod +x "$WORK/jira"
export FCL_JIRA="$WORK/jira"
TAB="$(printf '\t')"

out="$(bash "$SUT" "$WORK/chains.json" --mirror "$M" 2>&1)"; rc=$?
eq "a dry run exits 0" "$rc" 0
has "an unlinked pair is new, naming every chain that proposes it" "$out" "0,2${TAB}HIMMEL-1${TAB}HIMMEL-2${TAB}new"
has "a pair the mirror shows is linked" "$out" "0${TAB}HIMMEL-2${TAB}HIMMEL-3${TAB}linked"
has "a pair with a Done side is closed" "$out" "0${TAB}HIMMEL-3${TAB}HIMMEL-4${TAB}closed"
has "the opposite mirror link is reversed" "$out" "1${TAB}HIMMEL-6${TAB}HIMMEL-5${TAB}reversed"
has "a key with no mirror file is unknown" "$out" "1${TAB}HIMMEL-5${TAB}HIMMEL-9${TAB}unknown"
has "the opposite of an earlier chain's pair is reversed" "$out" "2${TAB}HIMMEL-7${TAB}HIMMEL-2${TAB}reversed${TAB}chain 2 proposes"
eq "a pair repeated in a later chain is listed once" "$(printf '%s\n' "$out" | grep -c "${TAB}HIMMEL-1${TAB}HIMMEL-2${TAB}")" 1
has "a pair closing a loop of proposed pairs is a cycle" "$out" "3${TAB}HIMMEL-11${TAB}HIMMEL-8${TAB}cycle"
has "a pair closing a loop over mirror links is a cycle" "$out" "4${TAB}HIMMEL-12${TAB}HIMMEL-13${TAB}cycle"
has "a pair closing a loop over a link only the blocked side records is a cycle" "$out" "6${TAB}HIMMEL-15${TAB}HIMMEL-16${TAB}cycle"
has "the last line counts the rows by state" "$out" "# pairs: 13 (closed 1, cycle 3, linked 1, new 4, reversed 3, unknown 1)"
[ -f "$WORK/calls" ] && fail "a dry run calls jira ($(cat "$WORK/calls"))" || pass "a dry run calls jira never"

bash "$SUT" "$WORK/chains.json" --mirror "$M" --apply >/dev/null 2>&1; rc=$?
eq "--apply without --chain is refused (rc 2)" "$rc" 2
[ -f "$WORK/calls" ] && fail "a refused --apply calls jira" || pass "a refused --apply calls jira never"

printf '10001\tBlocks\tinward=HIMMEL-1\toutward=HIMMEL-2\tHIMMEL-1 blocks HIMMEL-2\n' > "$WORK/links.HIMMEL-1"
out="$(bash "$SUT" "$WORK/chains.json" --mirror "$M" --chain 0 --apply 2>&1)"; rc=$?
eq "--apply with every write read back exits 0" "$rc" 0
eq "--apply writes only the new rows of the named chain" "$(grep '^link ' "$WORK/calls")" "link HIMMEL-1 --blocks HIMMEL-2"
has "the written pair is read back" "$out" "readback HIMMEL-1 blocks HIMMEL-2 ok"

rm -f "$WORK/calls" "$WORK/links.HIMMEL-1"
out="$(bash "$SUT" "$WORK/chains.json" --mirror "$M" --chain 2 --apply 2>&1)"; rc=$?
eq "a pair missing on read-back exits 1" "$rc" 1
has "a pair missing on read-back is named" "$out" "readback HIMMEL-2 blocks HIMMEL-7 MISSING"
lacks "a reversed row is never written" "$(cat "$WORK/calls")" "link HIMMEL-7"
has "a pair shared with an earlier chain is written for the later chain" "$(cat "$WORK/calls")" "link HIMMEL-1 --blocks HIMMEL-2"

rm -f "$WORK/calls"
bash "$SUT" "$WORK/chains.json" --mirror "$M" --chain 3 --apply >/dev/null 2>&1
eq "a cycle row is never written" "$(grep '^link ' "$WORK/calls")" "link HIMMEL-8 --blocks HIMMEL-10
link HIMMEL-10 --blocks HIMMEL-11"

rm -f "$WORK/calls"
bash "$SUT" "$WORK/chains.json" --mirror "$M" --chain 5 --apply >/dev/null 2>&1
eq "a chain not named never marks a named chain's pair reversed" "$(grep '^link ' "$WORK/calls")" "link HIMMEL-2 --blocks HIMMEL-1"

rm -f "$WORK/calls"
bash "$SUT" "$WORK/chains.json" --mirror "$M" --chain 9 --apply >/dev/null 2>&1; rc=$?
eq "--chain past the last chain is refused (rc 2)" "$rc" 2
[ -f "$WORK/calls" ] && fail "a refused --chain calls jira" || pass "a refused --chain calls jira never"
bash "$SUT" "$WORK/chains.json" --mirror "$M" --chain 00 --apply >/dev/null 2>&1
has "--chain 00 names chain 0" "$(cat "$WORK/calls" 2>/dev/null)" "link HIMMEL-1 --blocks HIMMEL-2"

: > "$WORK/links-down"
out="$(bash "$SUT" "$WORK/chains.json" --mirror "$M" --chain 0 --apply 2>&1)"; rc=$?
eq "a failed read-back call exits 1" "$rc" 1
has "a failed read-back call is named with its error" "$out" "readback HIMMEL-1 blocks HIMMEL-2 FAILED: jira: 503 unavailable"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
