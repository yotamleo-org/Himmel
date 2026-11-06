#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines, as in test-gen-briefs.sh
# test-succession-tracker.sh — Exercises succession-tracker.sh on fixture chief
# and worker docs: the per-worker relayed / quoted-back / missing state, the strict
# `SUCCESSION accepted:` parse (an ambiguous line is missing, never accepted), the printed
# LIVE line once the set is complete, and that the script only ever reads. Every path is a
# fixture under a temp dir: no real doc, no send. SUCCESSION_TRACKER overrides the script
# under test (the RED control: a missing script fails every row). bash 3.2-safe.
#
# Run: bash scripts/handover/chief-kit/test-succession-tracker.sh
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

SUCC="HIMMEL-nextleg-2026-10-13Z-roadmap-chief"
PRED="HIMMEL-nextleg-2026-10-13Y-roadmap-chief"
CDOC="$WORK/$SUCC.md"
MAN="$WORK/$SUCC.fleet.json"

mkleg() { # <label> <bullet...>: writes $WORK/<label>.md with a Results section
    local f="$WORK/$1.md"; shift
    { printf '# worker\n\n## Results (newest at the bottom)\n\n'; for b in "$@"; do printf '%s\n' "$b"; done; } > "$f"
}
q() { printf '%s' "- 04:17 SUCCESSION accepted: \`$1\` replaces \`$2\`"; }

mkleg N1 "- 03:00 LIVE — started" "$(q "$SUCC" "$PRED")"
mkleg N2 "- 03:00 LIVE — started"
mkleg N3 "- 03:00 LIVE — started" "- SUCCESSION accepted: $SUCC replaces $PRED"
mkleg N4 "- 03:00 LIVE — started" "$(q "$SUCC" "$PRED")" "$(q "HIMMEL-nextleg-2026-10-13Z2-other-chief" "$SUCC")"
mkleg N5 "- 03:00 LIVE — started" "note: SUCCESSION accepted: $SUCC replaces $PRED (prose, not a bullet)"
mkleg N6 "- 03:00 LIVE — started" "- 04:17 SUCCESSION accepted: \`$SUCC\` replaces \`$PRED\` but still checking"
mkleg N7 "- 03:00 LIVE — started" "$(q "${SUCC}2" "$PRED")"
mkleg N8 "- 03:00 LIVE — started" "$(q "$SUCC" "$PRED")"

# shellcheck disable=SC2016  # the backticks are literal markers in the Live state
printf '# chief\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` `N2:Y-N2-bb:lockB:12`\n\n## Results\n' > "$CDOC"
cat > "$MAN" <<EOF
{"schema": 1, "workers": [
 {"doc": "$WORK/N1.md", "label": "N1", "lane": "native"},
 {"doc": "$WORK/N2.md", "label": "N2", "lane": "native"}
]}
EOF

run() { bash "$SUT" "$CDOC" --successor "$SUCC" "$@" 2>&1; }

before="$(cksum < "$CDOC")$(cksum < "$MAN")"
out="$(run)"; rc=$?
eq "a worker with no bullet makes the set incomplete (rc 1)" "$rc" 1
has "N1 with a strict bullet naming the successor is quoted-back" "$out" "N1 quoted-back"
has "N2 with no bullet is missing" "$out" "N2 missing"
lacks "an incomplete set prints no LIVE line" "$out" "append-results.sh"
has "an incomplete set names who is missing" "$out" "INCOMPLETE 1/2"

out="$(run --relayed N2)"
has "--relayed marks a worker that has no bullet yet as relayed, not missing" "$out" "N2 relayed"
has "relayed is still incomplete" "$out" "INCOMPLETE 1/2"

# the strict parse, one worker at a time through a one-worker chief/manifest
one() { # <label> -> prints the tracker output for a chief holding just that worker
    local l="$1"
    # shellcheck disable=SC2016
    printf '# chief\n\n## Live state\nlegs: `%s:Y-%s-aa:lockA:11`\n' "$l" "$l" > "$CDOC"
    printf '{"schema": 1, "workers": [{"doc": "%s/%s.md", "label": "%s", "lane": "native"}]}\n' "$WORK" "$l" "$l" > "$MAN"
    run "${@:2}"
}
has "a bullet without backticks or a time stamp is accepted" "$(one N3)" "N3 quoted-back"
has "the LATEST bullet decides: a later bullet naming another chief reads missing" "$(one N4)" "N4 missing"
has "a prose line mentioning SUCCESSION accepted is not a bullet" "$(one N5)" "N5 missing"
has "an ambiguous bullet (trailing text) is missing, never accepted" "$(one N6)" "N6 missing"
has "a successor that merely starts with the name does not match" "$(one N7)" "N7 missing"

# the handshake is read from the Results section only, and backticks must balance
printf '# worker\n\n## Instructions\n\n%s\n\n## Results (newest at the bottom)\n\n- 03:00 LIVE — started\n' "$(q "$SUCC" "$PRED")" > "$WORK/N10.md"
mkleg N11 "- 03:00 LIVE — started" "- 04:17 SUCCESSION accepted: \`$SUCC replaces $PRED"
mkleg N12 "- 03:00 LIVE — started" "- 04:17 SUCCESSION accepted: $SUCC\` replaces \`$PRED"
has "a strict bullet outside the Results section confirms nothing" "$(one N10)" "N10 missing"
has "an opening backtick with no closing one is missing" "$(one N11)" "N11 missing"
has "a closing backtick with no opening one is missing" "$(one N12)" "N12 missing"

# a claudex worker's quote-back lands under the Chief Rulings section inbox-send.sh opened
# after Results, and a later relay mirror quoting the phrase is not a bullet of the worker's own
RELAY="- 04:16 [Y-N13-aa] from=$PRED SUCCESSION relay: your quote-back is a Results bullet containing exactly: SUCCESSION accepted: $SUCC replaces $PRED"
printf '# worker\n\n## Results (newest at the bottom)\n\n- 03:00 LIVE — started\n\n## Chief Rulings (newest at the bottom)\n%s\n%s\n%s\n' "$RELAY" "$(q "$SUCC" "$PRED")" "$RELAY" > "$WORK/N13.md"
has "a quote-back under Chief Rulings (claudex) is quoted-back" "$(one N13)" "N13 quoted-back"

# a worker the successor dispatched itself names the successor as its chief and never quotes back
# shellcheck disable=SC2016
printf '# worker\n\n> - **Token and console:** your RETASK token is `Z-N14-cc`; your chief is **`%s`** (the only session)\n\n## Results (newest at the bottom)\n\n- 03:00 LIVE — started\n' "$SUCC" > "$WORK/N14.md"
# shellcheck disable=SC2016
printf '# chief\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` `N14:Z-N14-cc:lockC:13`\n' > "$CDOC"
printf '{"schema": 1, "workers": [{"doc": "%s/N1.md", "label": "N1", "lane": "native"}, {"doc": "%s/N14.md", "label": "N14", "lane": "native"}]}\n' "$WORK" "$WORK" > "$MAN"
out="$(run)"; rc=$?
has "a worker the successor dispatched is skipped, not missing" "$out" "N14 own"
eq "and the inherited set reads complete without it (rc 0)" "$rc" 0
has "and the tally counts inherited workers only" "$out" "COMPLETE 1/1"


# a complete set prints the LIVE line, once, print only
# shellcheck disable=SC2016
printf '# chief\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` `N8:Y-N8-bb:lockB:12`\n' > "$CDOC"
cat > "$MAN" <<EOF
{"schema": 1, "workers": [
 {"doc": "$WORK/N1.md", "label": "N1", "lane": "native"},
 {"doc": "$WORK/N8.md", "label": "N8", "lane": "native"}
]}
EOF
sum_before="$(cksum < "$CDOC")"
man_before="$(cksum < "$MAN")"
out="$(run)"; rc=$?
eq "every worker quoted back: complete (rc 0)" "$rc" 0
has "COMPLETE 2/2 is printed" "$out" "COMPLETE 2/2"
has "the exact LIVE line is printed for append-results.sh" "$out" "bash scripts/handover/chief-kit/append-results.sh $CDOC \"LIVE —"
lacks "the LIVE bullet carries no > character" "$(printf '%s\n' "$out" | grep 'append-results.sh')" ">"
eq "it only prints: the chief doc is untouched" "$(cksum < "$CDOC")" "$sum_before"
eq "and the manifest is untouched too" "$(cksum < "$MAN")" "$man_before"

# the printed command is safe to paste: a doc path with a space is escaped, a successor that
# could break the quoted message is a usage error
SPD="$WORK/sp ace"; mkdir -p "$SPD"
# shellcheck disable=SC2016
printf '# chief\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11`\n' > "$SPD/c.md"
printf '{"schema": 1, "workers": [{"doc": "%s/N1.md", "label": "N1", "lane": "native"}]}\n' "$WORK" > "$SPD/c.fleet.json"
out="$(bash "$SUT" "$SPD/c.md" --successor "$SUCC" 2>&1)"
has "a doc path with a space is escaped in the printed command" "$out" 'append-results.sh '"$WORK"'/sp\ ace/c.md '
bash "$SUT" "$CDOC" --successor 'x"; touch /tmp/pwn; "' >/dev/null 2>&1; rc=$?
eq "a successor with shell metacharacters is a usage error (rc 2)" "$rc" 2

# a malformed worker entry beside a valid quoted-back worker must not read COMPLETE
# shellcheck disable=SC2016
printf '# chief\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` `N8:Y-N8` junk\n' > "$CDOC"
out="$(run)"; rc=$?
eq "a malformed workers entry beside a valid one is not complete (rc 1)" "$rc" 1
lacks "and prints no LIVE line for it" "$out" "append-results.sh"
has "and names the malformed entry" "$out" "malformed"

# A real chief doc glued `queue: none` onto the workers: line and the next
# line is `last GO:`. Prose after the spans is tolerated, a field line is never a worker.
# shellcheck disable=SC2016
printf '# chief\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` `N8:Y-N8-bb:lockB:12`queue: none\nlast GO: `2846:1874de54:x:y` (BC)\nacked: none\n\n## Results\n' > "$CDOC"
out="$(run)"; rc=$?
eq "trailing prose glued after the spans is not malformed: complete (rc 0)" "$rc" 0
has "and both workers are read from the spans" "$out" "COMPLETE 2/2"
lacks "and the queue: text is not reported as a malformed entry" "$out" "malformed"
# shellcheck disable=SC2016
printf '# chief\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` (note: held) `N8:Y-N8-bb:lockB:12`\nqueue: `Q:a:b:c`\n' > "$CDOC"
out="$(run)"; rc=$?
eq "prose between spans is tolerated and a later field line's span is not a worker (rc 0)" "$rc" 0
has "2 workers, not 3" "$out" "COMPLETE 2/2"

# an un-backticked four-field entry is a malformed entry, never prose: the worker would vanish
# from the set and the tally would read complete without its quote-back
# shellcheck disable=SC2016
printf '# chief\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` N2:Y-N2-bb:lockB:12\n' > "$CDOC"
out="$(run)"; rc=$?
eq "a bare four-field entry beside a valid one is not complete (rc 1)" "$rc" 1
lacks "and prints no LIVE line for a bare entry" "$out" "append-results.sh"
has "and names it as malformed" "$out" "malformed"

# quoted tick fields and bare worker names are prose, not malformed entries
# shellcheck disable=SC2016
printf '# chief\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` (tick said `procs:2`, `livestate=DRIFT:N8`, see `N8`) `N8:Y-N8-bb:lockB:12`\n' > "$CDOC"
out="$(run)"; rc=$?
eq "quoted tick fields and a bare label are prose (rc 0)" "$rc" 0
has "and the two real entries are the set" "$out" "COMPLETE 2/2"

# a manifest worker missing from the workers: line still counts, so a dropped entry cannot
# make the set read complete
cp "$MAN" "$MAN.keep"
printf '{"schema": 1, "workers": [{"doc": "%s/N1.md", "label": "N1", "lane": "native"}, {"doc": "%s/N2.md", "label": "N2", "lane": "native"}]}\n' "$WORK" "$WORK" > "$MAN"
# shellcheck disable=SC2016
printf '# chief\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11`\n' > "$CDOC"
out="$(run)"; rc=$?
eq "a manifest worker absent from the workers: line keeps the set incomplete (rc 1)" "$rc" 1
has "and names the absent worker as waiting" "$out" "waiting on: N2"

# a duplicated span counts its worker once
printf '{"schema": 1, "workers": [{"doc": "%s/N1.md", "label": "N1", "lane": "native"}]}\n' "$WORK" > "$MAN"
# shellcheck disable=SC2016
printf '# chief\n\n## Live state\nlegs: `N1:Y-N1-aa:lockA:11` `N1:Y-N1-aa:lockA:11`\n' > "$CDOC"
out="$(run)"; rc=$?
eq "a duplicated span is one worker (rc 0)" "$rc" 0
has "and it reads COMPLETE 1/1" "$out" "COMPLETE 1/1"

# an unreadable manifest cannot be cross-checked, so the set is never complete
printf 'not json\n' > "$MAN"
out="$(run)"; rc=$?
eq "an unreadable manifest is not complete (rc 1)" "$rc" 1
lacks "and prints no LIVE line for it" "$out" "append-results.sh"
has "and says the manifest is unreadable" "$out" "unreadable"
mv "$MAN.keep" "$MAN"

# no workers at all is not a complete set
printf '# chief\n\n## Live state\nlegs:\n' > "$CDOC"
out="$(run)"; rc=$?
eq "an empty Live-state worker set is not complete (rc 1)" "$rc" 1
lacks "and prints no LIVE line" "$out" "append-results.sh"

# usage
bash "$SUT" >/dev/null 2>&1; rc=$?
eq "no arguments is a usage error (rc 2)" "$rc" 2
bash "$SUT" "$WORK/absent.md" --successor X >/dev/null 2>&1; rc=$?
eq "a missing chief doc is a usage error (rc 2)" "$rc" 2

# M1a: `workers:` / `.workers` first, the pre-rename `legs:` / `.legs` still read,
# `workers:` wins when both lines exist, HIMMEL_LEGACY_NAMES=0 drops the old spelling.
twin() { # <live line key> <manifest array key>: a chief holding N1 and N8, both quoted back
    # shellcheck disable=SC2016
    printf '# chief\n\n## Live state\n%s: `N1:Y-N1-aa:lockA:11` `N8:Y-N8-bb:lockB:12`\n\n## Results\n' "$1" > "$CDOC"
    printf '{"schema": 1, "%s": [{"doc": "%s/N1.md", "label": "N1", "lane": "native"}, {"doc": "%s/N8.md", "label": "N8", "lane": "native"}]}\n' "$2" "$WORK" "$WORK" > "$MAN"
}
twin legs legs; old_out="$(run)"; old_rc=$?
twin workers workers; new_out="$(run)"; new_rc=$?
eq "an old legs: doc over a legs manifest reads complete (rc 0)" "$old_rc" 0
eq "a workers: doc over a workers manifest reads complete (rc 0)" "$new_rc" 0
has "the workers twin reads both workers" "$new_out" "COMPLETE 2/2"
eq "the old doc and its workers twin print the same" "$old_out" "$new_out"
twin legs workers; out="$(run)"
eq "an old legs: doc over a workers manifest prints the same" "$out" "$new_out"
twin workers legs; out="$(run)"
eq "a workers: doc over an old legs manifest prints the same" "$out" "$new_out"
# shellcheck disable=SC2016
printf '# chief\n\n## Live state\nlegs: `N2:Y-N2-aa:lockA:11`\nworkers: `N1:Y-N1-aa:lockA:11` `N8:Y-N8-bb:lockB:12`\n\n## Results\n' > "$CDOC"
out="$(run)"
has "a doc with both lines reads the workers: one (it wins)" "$out" "COMPLETE 2/2"
lacks "and never the legs: one" "$out" "N2"
twin legs legs; out="$(HIMMEL_LEGACY_NAMES=0 run)"; rc=$?
eq "with HIMMEL_LEGACY_NAMES=0 an old legs: doc is not read as complete (rc 1)" "$rc" 1
lacks "and prints no LIVE line for it" "$out" "append-results.sh"
twin workers workers; out="$(HIMMEL_LEGACY_NAMES=0 run)"; rc=$?
eq "with HIMMEL_LEGACY_NAMES=0 a workers: doc still reads complete (rc 0)" "$rc" 0
twin workers legs; out="$(HIMMEL_LEGACY_NAMES=0 run)"; rc=$?
eq "with HIMMEL_LEGACY_NAMES=0 an old legs manifest cannot be cross-checked (rc 1)" "$rc" 1
has "and says the manifest is unreadable" "$out" "unreadable"
: "$before"

# A replaced worker is not a silent inherited worker, even if its old row remains.
QL="$HERE/../queue-lock.sh"
export HANDOVER_DIR="$WORK/handover-root"; mkdir -p "$HANDOVER_DIR"
OLD="$WORK/HIMMEL-9-N80-demo-2026-01-01.md"
NEXT="$WORK/HIMMEL-9-N80b-demo-2026-01-01-RESUME.md"
printf '# worker\n\n## Results\n\n- 10:00 BLOCKED - context hand-off to %s\n' "$NEXT" > "$OLD"
printf '# successor\n\n## Results\n\n- 10:01 LIVE - working\n' > "$NEXT"
# shellcheck disable=SC2016
printf '# chief\n\n## Live state\nworkers: `N1:Y-N1-aa:lockA:11` `N80:Y-N80-bb:lockB:12`\n' > "$CDOC"
printf '{"schema":1,"workers":[{"doc":"%s/N1.md","label":"N1","lane":"native"},{"doc":"%s","label":"N80","lane":"claudex"}]}\n' "$WORK" "$OLD" > "$MAN"
out="$(run)"; rc=$?
eq "a replaced predecessor does not keep succession incomplete" "$rc" 0
has "the tally counts only the active inherited worker" "$out" "COMPLETE 1/1"
lacks "a replaced predecessor is never waiting on a quote-back" "$out" "N80 missing"

# A hand-off bullet on a doc whose lock is still held is a live session, never a replaced one:
# the tally must stay loud about it.
acq_out="$(bash "$QL" acquire "$OLD" "tracker-test-holder" 2>&1)"
# shellcheck disable=SC2016  # literal token delimiters
token="$(printf '%s' "$acq_out" | sed -n 's/.*release-token: `\([^`]*\)`.*/\1/p')"
eq "setup: the hand-off doc lock is acquired" "$([ -n "$token" ] && echo yes)" "yes"
eq "setup: the hand-off doc lock is held" "$(bash "$QL" status "$OLD" >/dev/null 2>&1 && echo free || echo held)" "held"
out="$(run)"; rc=$?
eq "a hand-off doc with its lock held keeps succession incomplete" "$rc" 1
has "and the held worker is reported as waiting, not replaced" "$out" "N80 missing"
lacks "and it is never called replaced" "$out" "N80 replaced"
[ -z "$token" ] || bash "$QL" release "$OLD" "$token" >/dev/null 2>&1

# An equal-label resume doc names the same live session as its predecessor, so the predecessor is
# not replaced even with its own lock free: the quote-back is still owed.
EQD="$WORK/HIMMEL-9-N82-demo-2026-01-01.md"
EQR="$WORK/HIMMEL-9-N82-demo-2026-01-01-RESUME.md"
printf '# worker\n\n## Results\n\n- 10:00 BLOCKED - context hand-off to %s\n' "$EQR" > "$EQD"
printf '# successor\n\n## Results\n\n- 10:01 LIVE - working\n' > "$EQR"
# shellcheck disable=SC2016
printf '# chief\n\n## Live state\nworkers: `N1:Y-N1-aa:lockA:11` `N82:Y-N82-cc:lockC:13`\n' > "$CDOC"
printf '{"schema":1,"workers":[{"doc":"%s/N1.md","label":"N1","lane":"native"},{"doc":"%s","label":"N82","lane":"claudex"}]}\n' "$WORK" "$EQD" > "$MAN"
out="$(run)"; rc=$?
eq "an equal-label resume keeps succession incomplete" "$rc" 1
has "and the shared-name worker is reported as waiting" "$out" "N82 missing"

# The doc names successor N84c while a lettered relaunch (the N84d session) holds the doc's own lock:
# a live session, never replaced.
LD="$WORK/HIMMEL-9-N84b-demo-2026-01-01.md"
LC="$WORK/HIMMEL-9-N84c-demo-2026-01-01-RESUME.md"
printf '# worker\n\n## Results\n\n- 10:00 BLOCKED - context hand-off to %s\n' "$LC" > "$LD"
printf '# successor\n\n## Results\n\n- 10:01 LIVE - working\n' > "$LC"
# shellcheck disable=SC2016
printf '# chief\n\n## Live state\nworkers: `N1:Y-N1-aa:lockA:11` `N84b:Y-N84b-dd:lockD:14`\n' > "$CDOC"
printf '{"schema":1,"workers":[{"doc":"%s/N1.md","label":"N1","lane":"native"},{"doc":"%s","label":"N84b","lane":"claudex"}]}\n' "$WORK" "$LD" > "$MAN"
acq_out="$(bash "$QL" acquire "$LD" "HIMMEL-9-N84d-demo-2026-01-01" 2>&1)"
# shellcheck disable=SC2016  # literal token delimiters
token="$(printf '%s' "$acq_out" | sed -n 's/.*release-token: `\([^`]*\)`.*/\1/p')"
eq "setup: the N84d session holds the doc lock" "$(bash "$QL" status "$LD" >/dev/null 2>&1 && echo free || echo held)" "held"
out="$(run)"; rc=$?
eq "a doc whose lock a lettered relaunch holds keeps succession incomplete" "$rc" 1
lacks "and it is never called replaced" "$out" "N84b replaced"
has "and it is reported as waiting" "$out" "N84b missing"
[ -z "$token" ] || bash "$QL" release "$LD" "$token" >/dev/null 2>&1

# A worker that wrapped (WRAPPED tail, its doc's lock free) or was closed and left
# the manifest can never quote back, so it is left out of the tally as replaced and own are.
# A live worker with no quote-back stays missing, so a real silent worker still pages.
hold() { # <doc> <session>: hold the doc's queue lock under <session> (token kept in $HELD_TOKEN)
    local o
    o="$(bash "$QL" acquire "$1" "$2" 2>&1)"
    # shellcheck disable=SC2016  # literal token delimiters
    HELD_TOKEN="$(printf '%s' "$o" | sed -n 's/.*release-token: `\([^`]*\)`.*/\1/p')"
    [ -n "$HELD_TOKEN" ] || echo "setup: could not hold the lock of $1" >&2
}
mkdoc() { # <label> <bullet...>: a worker doc that is not under the Live-state test above
    local f="$WORK/9395-$1.md"; shift
    { printf '# worker\n\n## Results (newest at the bottom)\n\n'; for b in "$@"; do printf '%s\n' "$b"; done; } > "$f"
}
mkdoc G1 "- 03:00 LIVE — started" "$(q "$SUCC" "$PRED")"
mkdoc W1 "- 03:00 LIVE — started" "- 09:00 WRAPPED — PR merged"
mkdoc W2 "- 03:00 LIVE — started" "- 09:00 WRAPPED — PR merged"
mkdoc L1 "- 03:00 LIVE — started" "- 09:00 LIVE — still working"
mkdoc WQ "- 03:00 LIVE — started" "$(q "$SUCC" "$PRED")" "- 09:00 WRAPPED — PR merged"
# shellcheck disable=SC2016
pair() { # <label> <lock token>: one Live-state entry
    printf '`%s:Y-%s-aa:%s:11` ' "$1" "$1" "$2"
}
chief_of() { # <entry...>: a chief doc listing the entries; the manifest rows follow from $ROWS
    { printf '# chief\n\n## Live state\nworkers: '; for e in "$@"; do pair "$e" "lock-$e"; done; printf '\n\n## Results\n'; } > "$CDOC"
}
row() { printf '{"doc": "%s/9395-%s.md", "label": "%s", "lane": "native"}' "$WORK" "$1" "$1"; }
manifest_of() { # <label...>: a manifest holding a row for each
    local first=1 l
    { printf '{"schema": 1, "workers": ['; for l in "$@"; do [ "$first" -eq 1 ] || printf ','; first=0; row "$l"; done; printf ']}\n'; } > "$MAN"
}

chief_of G1 W1; manifest_of G1 W1
out="$(run)"; rc=$?
has "a wrapped worker with its lock free and no quote-back is closed, not missing" "$out" "W1 closed"
lacks "and it is never called missing" "$out" "W1 missing"
eq "and the tally reads complete without it (rc 0)" "$rc" 0
has "and counts only the inherited workers that can quote back" "$out" "COMPLETE 1/1"

# a wrapped worker whose lock is still held is a live session
hold "$WORK/9395-W1.md" "9395-holder"
out="$(run)"; rc=$?
eq "a wrapped worker whose lock is held keeps succession incomplete (rc 1)" "$rc" 1
has "and it is reported as missing" "$out" "W1 missing"
lacks "and never as closed" "$out" "W1 closed"
has "and the tally counts it" "$out" "INCOMPLETE 1/2 (waiting on: W1)"
[ -z "$HELD_TOKEN" ] || bash "$QL" release "$WORK/9395-W1.md" "$HELD_TOKEN" >/dev/null 2>&1

# negative control: a live worker (newest bullet LIVE) with no quote-back still pages
chief_of G1 L1; manifest_of G1 L1
out="$(run)"; rc=$?
eq "a live worker with no quote-back stays incomplete (rc 1)" "$rc" 1
has "and is reported as missing" "$out" "L1 missing"
has "and is the one waiting on" "$out" "INCOMPLETE 1/2 (waiting on: L1)"
lacks "and prints no LIVE line" "$out" "append-results.sh"

# a wrapped worker that did quote back keeps counting as quoted-back
chief_of G1 WQ; manifest_of G1 WQ
out="$(run)"; rc=$?
has "a wrapped worker that quoted back is still quoted-back" "$out" "WQ quoted-back"
has "and stays in the tally" "$out" "COMPLETE 2/2"

# a tally of only closed workers reads complete; replaced-only stays incomplete as before
chief_of W1 W2; manifest_of W1 W2
out="$(run)"; rc=$?
eq "a set where every worker is closed reads complete (rc 0)" "$rc" 0
has "and says so with a 0/0 tally" "$out" "COMPLETE 0/0"
has "and prints the LIVE line" "$out" "append-results.sh"
has "and names both as closed" "$out" "W2 closed"
chief_of N80; manifest_of
printf '{"schema":1,"workers":[{"doc":"%s","label":"N80","lane":"claudex"}]}\n' "$OLD" > "$MAN"
out="$(run)"; rc=$?
has "setup: the replaced predecessor is left out" "$out" "N80 replaced"
eq "an empty set whose entries were replaced, not closed, stays incomplete (rc 1)" "$rc" 1
has "and reads INCOMPLETE 0/0" "$out" "INCOMPLETE 0/0"

# an entry with no manifest row cannot be read: no live session holding its lock token means closed,
# a held lock token means a live worker
chief_of N9; printf '{"schema": 1, "workers": []}\n' > "$MAN"
out="$(run)"; rc=$?
has "a Live-state worker with no manifest row and no lock held is closed" "$out" "N9 closed"
eq "and a set of only that reads complete (rc 0)" "$rc" 0
printf '# held\n' > "$WORK/9395-N9-lock.md"
hold "$WORK/9395-N9-lock.md" "lock-N9"
out="$(run)"; rc=$?
has "a Live-state worker with no manifest row whose lock token is held is missing" "$out" "N9 missing"
eq "and keeps the set incomplete (rc 1)" "$rc" 1
[ -z "$HELD_TOKEN" ] || bash "$QL" release "$WORK/9395-N9-lock.md" "$HELD_TOKEN" >/dev/null 2>&1
# with no manifest at all the lookup proved nothing: the worker is never read as closed
mv "$MAN" "$MAN.keep9395"
out="$(run)"; rc=$?
has "a Live-state worker with no manifest file is missing, not closed" "$out" "N9 missing"
eq "and keeps the set incomplete (rc 1)" "$rc" 1
mv "$MAN.keep9395" "$MAN"

# the 11-06 05:04 shape: 16 inherited workers, 10 quoted back; 4 wrapped and closed, 1 removed
# from the manifest, 1 alive and silent. Before: INCOMPLETE 10/16 naming 6. After: only the live one.
labels="N4880 N4881 N4882 N4883 N4884 N4887 N4888 N4889 N4890 N4891"
for l in $labels; do mkdoc "$l" "- 03:00 LIVE — started" "$(q "$SUCC" "$PRED")"; done
for l in N4895 N4900 N4892 N4898; do mkdoc "$l" "- 03:00 LIVE — started" "- 04:50 WRAPPED — PR merged"; done
mkdoc N4885 "- 03:00 LIVE — started" "- 05:01 LIVE — waiting on CI"
all="$labels N4885 N4895 N4900 N4892 N4898 N4886b"
# shellcheck disable=SC2086
chief_of $all
# shellcheck disable=SC2086
manifest_of $labels N4885 N4895 N4900 N4892 N4898
out="$(run)"; rc=$?
eq "05:04 shape: still incomplete, the live worker has not quoted back (rc 1)" "$rc" 1
has "05:04 shape: 10 of 11 once the closed ones are left out" "$out" "INCOMPLETE 10/11 (waiting on: N4885)"
for l in N4895 N4900 N4892 N4898 N4886b; do has "05:04 shape: $l is closed" "$out" "$l closed"; done

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
