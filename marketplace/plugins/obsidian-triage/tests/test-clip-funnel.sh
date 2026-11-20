#!/usr/bin/env bash
# Acceptance test for tools/clip-funnel.mjs: the read-only funnel of the clip pipeline.
#
#   node clip-funnel.mjs --vault V [--as-of YYYY-MM-DD] [--days N]
#
# prints one JSON object: how many of the clips taken in were cited by a synthesis
# page, how many subject pages were created or extended, how many daily actions are
# open and applied, how many clips wait on media, and which stages made no
# movement in the window. The fixture vault (fixtures/clip-funnel/build-vault.sh) is
# synthetic; its expected counts are listed in that file.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$PLUGIN_DIR/tools/clip-funnel.mjs"
BUILD="$SCRIPT_DIR/fixtures/clip-funnel/build-vault.sh"
PRELOAD="$SCRIPT_DIR/fixtures/clip-funnel/count-reads.mjs"
D="2026-06-28"

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

# jget <path.to.key> <json> — the value at that path, JSON-encoded.
jget() {
    node -e 'let o = JSON.parse(process.argv[2]); for (const k of process.argv[1].split(".")) o = o?.[k]; process.stdout.write(JSON.stringify(o))' "$1" "$2"
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/clip-funnel.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT

A="$tmp/a"; bash "$BUILD" "$A"
B="$tmp/b"; bash "$BUILD" "$B" --apply-ledger

echo "Group 1: every stage counts what the fixture holds (no apply ledger)"
out="$(node "$TOOL" --vault "$A" --as-of "$D" 2>"$tmp/err")"; rc=$?
assert "exit 0" "0" "$rc"
assert "stderr empty" "" "$(cat "$tmp/err")"
assert "as_of echoed" '"2026-06-28"' "$(jget as_of "$out")"
assert "the window defaults to 7 days" "7" "$(jget window_days "$out")"
assert "intake: clips taken in" "10" "$(jget intake.clips "$out")"
assert "intake: taken in inside the window" "6" "$(jget intake.moved_in_window "$out")"
assert "intake: last" '"2026-06-28"' "$(jget intake.last "$out")"
assert "cited: clips linked by a synthesis page (by name, a stale folder counts)" "4" "$(jget cited.clips "$out")"
assert "cited: share of the clips taken in" "0.4" "$(jget cited.share "$out")"
assert "cited: synthesis pages" "2" "$(jget cited.synthesis_pages "$out")"
assert "cited: pages dated inside the window" "0" "$(jget cited.moved_in_window "$out")"
assert "cited: last page" '"2026-06-18"' "$(jget cited.last "$out")"
assert "subjects: distinct pages created" "2" "$(jget subjects.created "$out")"
assert "subjects: distinct pages extended" "2" "$(jget subjects.extended "$out")"
assert "subjects: distinct pages touched inside the window" "2" "$(jget subjects.moved_in_window "$out")"
assert "subjects: last" '"2026-06-27"' "$(jget subjects.last "$out")"
assert "actions: open (a dismissed, a ticked and a non-report line are not)" "3" "$(jget actions.open "$out")"
assert "actions: an absent ledger is zero applied" "0" "$(jget actions.applied "$out")"
assert "actions: last applied" "null" "$(jget actions.last "$out")"
assert "media: clips waiting (an inbox ig flag and two x flags; _done, _rejected and false do not)" "3" "$(jget media.waiting "$out")"
assert "media: enriched inside the window" "1" "$(jget media.moved_in_window "$out")"
assert "media: last" '"2026-06-26"' "$(jget media.last "$out")"
assert "stalled lists the stages with no movement, in stage order" '["cited","actions"]' "$(jget stalled "$out")"

echo "Group 2: the applied-actions ledger moves actions from open to applied"
outb="$(node "$TOOL" --vault "$B" --as-of "$D" 2>&1)"
assert "applied: distinct fold/archive ids" "2" "$(jget actions.applied "$outb")"
assert "open: an applied id is no longer open" "1" "$(jget actions.open "$outb")"
assert "applied inside the window" "1" "$(jget actions.moved_in_window "$outb")"
assert "last applied" '"2026-06-27"' "$(jget actions.last "$outb")"
assert "a stage with movement is not stalled" '["cited"]' "$(jget stalled "$outb")"

echo "Group 3: the seven-day stall flag on the subject stage"
subj() { # <ledger-body> -> the tool's JSON on a copy of the fixture with that subject ledger
    local v="$tmp/s"; rm -rf "$v"; bash "$BUILD" "$v"
    if [ -n "$1" ]; then printf '%s\n' "$1" > "$v/.synthesize-stubs.ledger.jsonl"; else rm -f "$v/.synthesize-stubs.ledger.jsonl"; fi
    node "$TOOL" --vault "$v" --as-of "$D" 2>&1
}
o="$(subj '{"ts":"2026-06-27T10:00:00.000Z","action":"stub-create","subject":"30-Resources/Concepts/Y.md"}')"
assert "created yesterday: not stalled" "false" "$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).stalled.includes("subjects")))' "$o")"
o="$(subj '{"ts":"2026-06-22T10:00:00.000Z","action":"stub-create","subject":"30-Resources/Concepts/Y.md"}')"
assert "created 6 days ago, the oldest day of the window: not stalled" "false" "$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).stalled.includes("subjects")))' "$o")"
o="$(subj '{"ts":"2026-06-21T10:00:00.000Z","action":"stub-create","subject":"30-Resources/Concepts/Y.md"}')"
assert "created 7 days ago: stalled" "true" "$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).stalled.includes("subjects")))' "$o")"
assert "created 7 days ago: the last movement is still reported" '"2026-06-21"' "$(jget subjects.last "$o")"
o="$(subj '')"
assert "no subject ledger: zero created, extended" "0 0" "$(jget subjects.created "$o") $(jget subjects.extended "$o")"
assert "no subject ledger: stalled, last null" "true null" "$(node -e 'const j=JSON.parse(process.argv[1]);process.stdout.write(j.stalled.includes("subjects")+" "+j.subjects.last)' "$o")"
o="$(subj '{"ts":"2026-06-27T10:00:00.000Z","action":"densify","subject":"60-Maps/Z-MOC.md"}')"
assert "extended yesterday: not stalled" "false" "$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).stalled.includes("subjects")))' "$o")"

echo "Group 4: --days sets the window"
out14="$(node "$TOOL" --vault "$A" --as-of "$D" --days 14 2>&1)"
assert "window_days follows --days" "14" "$(jget window_days "$out14")"
assert "a wider window counts more intake" "7" "$(jget intake.moved_in_window "$out14")"
assert "a wider window reaches the 06-18 synthesis page" "1" "$(jget cited.moved_in_window "$out14")"
out1="$(node "$TOOL" --vault "$A" --as-of "$D" --days 1 2>&1)"
assert "a 1-day window is the as-of day only" "4" "$(jget intake.moved_in_window "$out1")"

echo "Group 5: deterministic and read-only"
node "$TOOL" --vault "$A" --as-of "$D" > "$tmp/run1.json" 2>&1
node "$TOOL" --vault "$A" --as-of "$D" > "$tmp/run2.json" 2>&1
assert "two runs print identical bytes" "" "$(cmp "$tmp/run1.json" "$tmp/run2.json" 2>&1)"
assert "the output is one JSON document" "object" "$(node -e 'process.stdout.write(typeof JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")))' "$tmp/run1.json")"
snap() { (cd "$1" && find . -type f -exec cksum {} + | LC_ALL=C sort; find . | LC_ALL=C sort) | cksum; }
before="$(snap "$A")"
node "$TOOL" --vault "$A" --as-of "$D" >/dev/null 2>&1
assert "the vault is byte for byte unchanged after a run (no file, no lock)" "$before" "$(snap "$A")"

echo "Group 6: each vault file is read once"
FUNNEL_READ_LOG="$tmp/reads.log" node --import "$PRELOAD" "$TOOL" --vault "$A" --as-of "$D" >/dev/null 2>&1
assert "no path is read twice" "" "$(awk -F'\t' '$1 > 1' "$tmp/reads.log")"
assert "all ten evidence clips were read (the check is not vacuous)" "10" "$(grep -c '/Clippings/_evidence/e' "$tmp/reads.log")"

echo "Group 7: empty vault and bad arguments"
mkdir -p "$tmp/empty"
oute="$(node "$TOOL" --vault "$tmp/empty" --as-of "$D" 2>&1)"; rc=$?
assert "an empty vault is not an error" "0" "$rc"
assert "empty: counts are zero, share is 0 not NaN" "0 0 0" "$(jget intake.clips "$oute") $(jget cited.share "$oute") $(jget actions.open "$oute")"
assert "empty: the flow stages are stalled" '["intake","cited","subjects"]' "$(jget stalled "$oute")"
node "$TOOL" --vault "$tmp/none" --as-of "$D" >/dev/null 2>&1; assert "a missing vault exits 1" "1" "$?"
node "$TOOL" --as-of "$D" >/dev/null 2>&1; assert "no --vault exits 1" "1" "$?"
node "$TOOL" --vault "$A" --as-of 2026-13-01 >/dev/null 2>&1; assert "an impossible --as-of exits 1" "1" "$?"
node "$TOOL" --vault "$A" --days 0 >/dev/null 2>&1; assert "--days 0 exits 1" "1" "$?"
node "$TOOL" --vault "$A" --bogus >/dev/null 2>&1; assert "an unknown flag exits 1" "1" "$?"

echo "Group 8: the default day and a clip without frontmatter"
oute="$(node "$TOOL" --vault "$tmp/empty" 2>&1)"
assert "--as-of defaults to today, local" "\"$(date +%F)\"" "$(jget as_of "$oute")"
mkdir -p "$tmp/nofm/Clippings/_evidence"
printf 'A clip with no frontmatter.\n' > "$tmp/nofm/Clippings/_evidence/x.md"
outn="$(node "$TOOL" --vault "$tmp/nofm" --as-of "$D" 2>&1)"
assert "a clip with no frontmatter is taken in but has no day" "1 0 null" "$(jget intake.clips "$outn") $(jget intake.moved_in_window "$outn") $(jget intake.last "$outn")"
assert "a clip with no frontmatter is not waiting on media" "0" "$(jget media.waiting "$outn")"

echo
echo "test-clip-funnel: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
