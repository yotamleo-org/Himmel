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
 {"name": "C — again", "steps": [{"key": "HIMMEL-1"}, {"key": "HIMMEL-2"}, {"key": "HIMMEL-7"}, {"key": "HIMMEL-2"}]}
]
EOF
mk 7 "To Do" "" ""
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
has "an unlinked pair is new" "$out" "0${TAB}HIMMEL-1${TAB}HIMMEL-2${TAB}new"
has "a pair the mirror shows is linked" "$out" "0${TAB}HIMMEL-2${TAB}HIMMEL-3${TAB}linked"
has "a pair with a Done side is closed" "$out" "0${TAB}HIMMEL-3${TAB}HIMMEL-4${TAB}closed"
has "the opposite mirror link is reversed" "$out" "1${TAB}HIMMEL-6${TAB}HIMMEL-5${TAB}reversed"
has "a key with no mirror file is unknown" "$out" "1${TAB}HIMMEL-5${TAB}HIMMEL-9${TAB}unknown"
has "the opposite of an earlier chain's pair is reversed" "$out" "2${TAB}HIMMEL-7${TAB}HIMMEL-2${TAB}reversed${TAB}chain 2 proposes"
lacks "a pair repeated in a later chain is listed once" "$out" "2${TAB}HIMMEL-1${TAB}HIMMEL-2"
has "the last line counts the rows by state" "$out" "# pairs: 7 (closed 1, linked 1, new 2, reversed 2, unknown 1)"
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

: > "$WORK/links-down"
out="$(bash "$SUT" "$WORK/chains.json" --mirror "$M" --chain 0 --apply 2>&1)"; rc=$?
eq "a failed read-back call exits 1" "$rc" 1
has "a failed read-back call is named with its error" "$out" "readback HIMMEL-1 blocks HIMMEL-2 FAILED: jira: 503 unavailable"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
