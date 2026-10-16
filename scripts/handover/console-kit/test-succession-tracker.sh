#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-gen-briefs.sh
# test-succession-tracker.sh — Exercises succession-tracker.sh on fixture console
# and leg docs: the per-leg relayed / quoted-back / missing state, the strict
# `SUCCESSION accepted:` parse (an ambiguous line is missing, never accepted), the printed
# LIVE line once the set is complete, and that the script only ever reads. Every path is a
# fixture under a temp dir: no real doc, no send. SUCCESSION_TRACKER overrides the script
# under test (the RED control: a missing script fails every row). bash 3.2-safe.
#
# Run: bash scripts/handover/console-kit/test-succession-tracker.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SUCCESSION_TRACKER:-$HERE/succession-tracker.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac; }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/succession-tracker-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT

SUCC="HIMMEL-nextleg-2026-10-13Z-roadmap-console"
PRED="HIMMEL-nextleg-2026-10-13Y-roadmap-console"
CDOC="$WORK/$SUCC.md"
MAN="$WORK/$SUCC.fleet.json"

mkleg() { # <label> <bullet...>: writes $WORK/<label>.md with a Results section
    local f="$WORK/$1.md"; shift
    { printf '# leg\n\n## Results (newest at the bottom)\n\n'; for b in "$@"; do printf '%s\n' "$b"; done; } > "$f"
}
q() { printf '%s' "- 04:17 SUCCESSION accepted: \`$1\` replaces \`$2\`"; }

mkleg N1 "- 03:00 LIVE — started" "$(q "$SUCC" "$PRED")"
mkleg N2 "- 03:00 LIVE — started"
mkleg N3 "- 03:00 LIVE — started" "- SUCCESSION accepted: $SUCC replaces $PRED"
mkleg N4 "- 03:00 LIVE — started" "$(q "$SUCC" "$PRED")" "$(q "HIMMEL-nextleg-2026-10-13Z2-other-console" "$SUCC")"
mkleg N5 "- 03:00 LIVE — started" "note: SUCCESSION accepted: $SUCC replaces $PRED (prose, not a bullet)"
mkleg N6 "- 03:00 LIVE — started" "- 04:17 SUCCESSION accepted: \`$SUCC\` replaces \`$PRED\` but still checking"
mkleg N7 "- 03:00 LIVE — started" "$(q "${SUCC}2" "$PRED")"
mkleg N8 "- 03:00 LIVE — started" "$(q "$SUCC" "$PRED")"

# shellcheck disable=SC2016  # the backticks are literal markers in the Live state
printf '# console\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` `N2:Y-N2-bb:lockB:12`\n\n## Results\n' > "$CDOC"
cat > "$MAN" <<EOF
{"schema": 1, "legs": [
 {"doc": "$WORK/N1.md", "label": "N1", "lane": "native"},
 {"doc": "$WORK/N2.md", "label": "N2", "lane": "native"}
]}
EOF

run() { bash "$SUT" "$CDOC" --successor "$SUCC" "$@" 2>&1; }

before="$(cksum < "$CDOC")$(cksum < "$MAN")"
out="$(run)"; rc=$?
eq "a leg with no bullet makes the set incomplete (rc 1)" "$rc" 1
has "N1 with a strict bullet naming the successor is quoted-back" "$out" "N1 quoted-back"
has "N2 with no bullet is missing" "$out" "N2 missing"
lacks "an incomplete set prints no LIVE line" "$out" "append-results.sh"
has "an incomplete set names who is missing" "$out" "INCOMPLETE 1/2"

out="$(run --relayed N2)"
has "--relayed marks a leg that has no bullet yet as relayed, not missing" "$out" "N2 relayed"
has "relayed is still incomplete" "$out" "INCOMPLETE 1/2"

# the strict parse, one leg at a time through a one-leg console/manifest
one() { # <label> -> prints the tracker output for a console holding just that leg
    local l="$1"
    # shellcheck disable=SC2016
    printf '# console\n\n## Live state\nlegs: `%s:Y-%s-aa:lockA:11`\n' "$l" "$l" > "$CDOC"
    printf '{"schema": 1, "legs": [{"doc": "%s/%s.md", "label": "%s", "lane": "native"}]}\n' "$WORK" "$l" "$l" > "$MAN"
    run "${@:2}"
}
has "a bullet without backticks or a time stamp is accepted" "$(one N3)" "N3 quoted-back"
has "the LATEST bullet decides: a later bullet naming another console reads missing" "$(one N4)" "N4 missing"
has "a prose line mentioning SUCCESSION accepted is not a bullet" "$(one N5)" "N5 missing"
has "an ambiguous bullet (trailing text) is missing, never accepted" "$(one N6)" "N6 missing"
has "a successor that merely starts with the name does not match" "$(one N7)" "N7 missing"

# the handshake is read from the Results section only, and backticks must balance
printf '# leg\n\n## Instructions\n\n%s\n\n## Results (newest at the bottom)\n\n- 03:00 LIVE — started\n' "$(q "$SUCC" "$PRED")" > "$WORK/N10.md"
mkleg N11 "- 03:00 LIVE — started" "- 04:17 SUCCESSION accepted: \`$SUCC replaces $PRED"
mkleg N12 "- 03:00 LIVE — started" "- 04:17 SUCCESSION accepted: $SUCC\` replaces \`$PRED"
has "a strict bullet outside the Results section confirms nothing" "$(one N10)" "N10 missing"
has "an opening backtick with no closing one is missing" "$(one N11)" "N11 missing"
has "a closing backtick with no opening one is missing" "$(one N12)" "N12 missing"

# a leg held in Live state with no manifest row cannot be read
# shellcheck disable=SC2016
printf '# console\n\n## Live state\nlegs: `N9:Y-N9-aa:lockA:11`\n' > "$CDOC"
printf '{"schema": 1, "legs": []}\n' > "$MAN"
has "a Live-state leg with no manifest row is missing (no doc to read)" "$(run)" "N9 missing"

# a complete set prints the LIVE line, once, print only
# shellcheck disable=SC2016
printf '# console\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` `N8:Y-N8-bb:lockB:12`\n' > "$CDOC"
cat > "$MAN" <<EOF
{"schema": 1, "legs": [
 {"doc": "$WORK/N1.md", "label": "N1", "lane": "native"},
 {"doc": "$WORK/N8.md", "label": "N8", "lane": "native"}
]}
EOF
sum_before="$(cksum < "$CDOC")"
man_before="$(cksum < "$MAN")"
out="$(run)"; rc=$?
eq "every leg quoted back: complete (rc 0)" "$rc" 0
has "COMPLETE 2/2 is printed" "$out" "COMPLETE 2/2"
has "the exact LIVE line is printed for append-results.sh" "$out" "bash scripts/handover/console-kit/append-results.sh $CDOC \"LIVE —"
lacks "the LIVE bullet carries no > character" "$(printf '%s\n' "$out" | grep 'append-results.sh')" ">"
eq "it only prints: the console doc is untouched" "$(cksum < "$CDOC")" "$sum_before"
eq "and the manifest is untouched too" "$(cksum < "$MAN")" "$man_before"

# the printed command is safe to paste: a doc path with a space is escaped, a successor that
# could break the quoted message is a usage error
SPD="$WORK/sp ace"; mkdir -p "$SPD"
# shellcheck disable=SC2016
printf '# console\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11`\n' > "$SPD/c.md"
printf '{"schema": 1, "legs": [{"doc": "%s/N1.md", "label": "N1", "lane": "native"}]}\n' "$WORK" > "$SPD/c.fleet.json"
out="$(bash "$SUT" "$SPD/c.md" --successor "$SUCC" 2>&1)"
has "a doc path with a space is escaped in the printed command" "$out" 'append-results.sh '"$WORK"'/sp\ ace/c.md '
bash "$SUT" "$CDOC" --successor 'x"; touch /tmp/pwn; "' >/dev/null 2>&1; rc=$?
eq "a successor with shell metacharacters is a usage error (rc 2)" "$rc" 2

# a malformed leg entry beside a valid quoted-back leg must not read COMPLETE
# shellcheck disable=SC2016
printf '# console\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` `N8:Y-N8` junk\n' > "$CDOC"
out="$(run)"; rc=$?
eq "a malformed legs entry beside a valid one is not complete (rc 1)" "$rc" 1
lacks "and prints no LIVE line for it" "$out" "append-results.sh"
has "and names the malformed entry" "$out" "malformed"

# A real console doc glued `queue: none` onto the legs: line and the next
# line is `last GO:`. Prose after the spans is tolerated, a field line is never a leg.
# shellcheck disable=SC2016
printf '# console\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` `N8:Y-N8-bb:lockB:12`queue: none\nlast GO: `2846:1874de54:x:y` (BC)\nacked: none\n\n## Results\n' > "$CDOC"
out="$(run)"; rc=$?
eq "trailing prose glued after the spans is not malformed: complete (rc 0)" "$rc" 0
has "and both legs are read from the spans" "$out" "COMPLETE 2/2"
lacks "and the queue: text is not reported as a malformed entry" "$out" "malformed"
# shellcheck disable=SC2016
printf '# console\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` (note: held) `N8:Y-N8-bb:lockB:12`\nqueue: `Q:a:b:c`\n' > "$CDOC"
out="$(run)"; rc=$?
eq "prose between spans is tolerated and a later field line's span is not a leg (rc 0)" "$rc" 0
has "2 legs, not 3" "$out" "COMPLETE 2/2"

# an un-backticked four-field entry is a malformed entry, never prose: the leg would vanish
# from the set and the tally would read complete without its quote-back
# shellcheck disable=SC2016
printf '# console\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` N2:Y-N2-bb:lockB:12\n' > "$CDOC"
out="$(run)"; rc=$?
eq "a bare four-field entry beside a valid one is not complete (rc 1)" "$rc" 1
lacks "and prints no LIVE line for a bare entry" "$out" "append-results.sh"
has "and names it as malformed" "$out" "malformed"

# quoted tick fields and bare leg names are prose, not malformed entries
# shellcheck disable=SC2016
printf '# console\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` (tick said `procs:2`, `livestate=DRIFT:N8`, see `N8`) `N8:Y-N8-bb:lockB:12`\n' > "$CDOC"
out="$(run)"; rc=$?
eq "quoted tick fields and a bare label are prose (rc 0)" "$rc" 0
has "and the two real entries are the set" "$out" "COMPLETE 2/2"

# a manifest leg missing from the legs: line still counts, so a dropped entry cannot
# make the set read complete
cp "$MAN" "$MAN.keep"
printf '{"schema": 1, "legs": [{"doc": "%s/N1.md", "label": "N1", "lane": "native"}, {"doc": "%s/N2.md", "label": "N2", "lane": "native"}]}\n' "$WORK" "$WORK" > "$MAN"
# shellcheck disable=SC2016
printf '# console\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11`\n' > "$CDOC"
out="$(run)"; rc=$?
eq "a manifest leg absent from the legs: line keeps the set incomplete (rc 1)" "$rc" 1
has "and names the absent leg as waiting" "$out" "waiting on: N2"

# a duplicated span counts its leg once
printf '{"schema": 1, "legs": [{"doc": "%s/N1.md", "label": "N1", "lane": "native"}]}\n' "$WORK" > "$MAN"
# shellcheck disable=SC2016
printf '# console\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` `N1:Y-N1-aa:lockA:11`\n' > "$CDOC"
out="$(run)"; rc=$?
eq "a duplicated span is one leg (rc 0)" "$rc" 0
has "and it reads COMPLETE 1/1" "$out" "COMPLETE 1/1"
mv "$MAN.keep" "$MAN"

# no legs at all is not a complete set
printf '# console\n\n## Live state\nlegs:\n' > "$CDOC"
out="$(run)"; rc=$?
eq "an empty Live-state leg set is not complete (rc 1)" "$rc" 1
lacks "and prints no LIVE line" "$out" "append-results.sh"

# usage
bash "$SUT" >/dev/null 2>&1; rc=$?
eq "no arguments is a usage error (rc 2)" "$rc" 2
bash "$SUT" "$WORK/absent.md" --successor X >/dev/null 2>&1; rc=$?
eq "a missing console doc is a usage error (rc 2)" "$rc" 2
: "$before"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
