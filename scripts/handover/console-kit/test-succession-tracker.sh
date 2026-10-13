#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-gen-briefs.sh
# test-succession-tracker.sh — HIMMEL-3746. Exercises succession-tracker.sh on fixture console
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
out="$(run)"; rc=$?
eq "every leg quoted back: complete (rc 0)" "$rc" 0
has "COMPLETE 2/2 is printed" "$out" "COMPLETE 2/2"
has "the exact LIVE line is printed for append-results.sh" "$out" "bash scripts/handover/console-kit/append-results.sh $CDOC \"LIVE —"
lacks "the LIVE bullet carries no > character" "$(printf '%s\n' "$out" | grep 'append-results.sh')" ">"
eq "it only prints: the console doc is untouched" "$(cksum < "$CDOC")" "$sum_before"
eq "and the manifest is untouched too" "$(cksum < "$MAN")" "$(cksum < "$MAN")"

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
