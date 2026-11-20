#!/usr/bin/env bash

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$PLUGIN_DIR/tools/synthesis-candidates.mjs"
RUNBOOK="$PLUGIN_DIR/commands/synthesize-clips.md"
TODAY="2026-11-20"

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

tmp="$(mktemp -d "${TMPDIR:-/tmp}/synthesis-candidates.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
V="$tmp/vault"
EV="$V/Clippings/_evidence"
mkdir -p "$EV" "$V/Clippings/_done" "$V/Clippings/_synthesis" \
         "$V/30-Resources/Concepts" "$V/60-Maps" "$V/20-Areas" "$V/00-Inbox"
echo "2026-11-20T01:00:00Z deadbeef" > "$V/.harvest.done"

clip() {
    local file="$1" author="$2" source="$3" dc="$4" tags="$5" promo="${6:-}" name
    name="$(basename "$file" .md)"
    {
        echo "---"
        echo "title: \"clip $name\""
        printf 'author:%b\n' "$author"
        echo "source: \"$source\""
        echo "date_clipped: $dc"
        echo "type: \"tweet\""
        if [ -z "$tags" ]; then
            echo "tags: []"
        else
            echo "tags:"
            local t
            for t in ${tags//,/ }; do echo "  - $t"; done
        fi
        echo "processed: true"
        echo "triaged_at: $dc"
        echo "---"
        echo "# body of $name"
        if [ -n "$promo" ]; then
            echo ""
            echo "## Promotion candidate"
            echo "- **Suggested target:** \`$promo\`"
            echo "- **Rationale:** fixture."
        fi
    } > "$file"
}

diverse() {
    local p="$1" n="$2" tag="$3" d0="$4" promo="${5:-}" i
    for i in $(seq 1 "$n"); do
        clip "$EV/$p-$i.md" " Writer $p $i" "https://$p-$i.example.org/post" \
             "2026-09-$(printf '%02d' $((d0 + i)))" "$tag" "$promo"
    done
}

for i in 1 2 3 4; do
    clip "$EV/ctx-$i.md" "\n  - \"@voice_$i\"" "https://x.com/voice_$i/status/100$i" \
         "2026-10-0$i" "context-windows"
done
clip "$EV/ctx-5.md" "\n  - \"@voice_5\"" "https://mobile.twitter.com/voice_5/status/1005" \
     "2026-10-05" "context-windows"

for i in 1 2 3 4 5; do
    clip "$EV/solo-$i.md" " @lone_voice" "https://x.com/lone_voice/status/200$i" \
         "2026-10-0$((i+5))" "solo-voice"
done

for i in 1 2 3; do
    clip "$EV/blog-$i.md" " Blog Author $i" "https://example.com/p$i" \
         "2026-09-0$i" "blog-roll"
done

clip "$EV/burst-1.md" " Burst Author 1" "https://alpha.example.org/a" "2026-11-10" "same-day-burst"
clip "$EV/burst-2.md" " Burst Author 2" "https://beta.example.net/b"  "2026-11-10" "same-day-burst"
clip "$EV/burst-3.md" " Burst Author 3" "https://gamma.example.com/c" "2026-11-10" "same-day-burst"

diverse haspage 3 has-page 0
printf -- '---\ntype: concept\n---\nExisting.\n' > "$V/30-Resources/Concepts/Has Page.md"

diverse mapped 5 mapped 10
printf -- '---\ntype: moc\n---\nMap.\n' > "$V/60-Maps/mapped-MOC.md"

for i in $(seq 1 45); do
    clip "$EV/big-$i.md" " Big Writer $i" "https://big-$i.example.org/post" \
         "2026-0$((i / 28 + 1))-$(printf '%02d' $((i % 28 + 1)))" "big-topic"
done
{
    printf -- '---\ntype: synthesis\n---\n## Evidence (40 clips, 40 unique URLs)\n\n'
    for i in $(seq 1 40); do printf -- '- [[Clippings/_evidence/big-%s]] — x\n' "$i"; done
} > "$V/Clippings/_synthesis/2026-10-01-concept-big-topic.md"

diverse recent 3 recent-topic 0
printf -- '---\ntype: synthesis\n---\n## Evidence (3 clips, 3 unique URLs)\n\n- [[Clippings/_evidence/recent-1]] — a\n- [[Clippings/_evidence/recent-2]] — b\n- [[Clippings/_evidence/recent-3]] — c\n' \
    > "$V/Clippings/_synthesis/2026-11-17-concept-recent-topic.md"
diverse grown 4 grown-topic 0
printf -- '---\ntype: synthesis\n---\n## Evidence (3 clips, 3 unique URLs)\n\n- [[Clippings/_evidence/grown-1]] — a\n- [[Clippings/_evidence/grown-2]] — b\n- [[Clippings/_evidence/grown-3]] — c\n' \
    > "$V/Clippings/_synthesis/2026-10-01-concept-grown-topic.md"
diverse steady 3 steady-topic 0
printf -- '---\ntype: synthesis\n---\n## Evidence (3 clips, 3 unique URLs)\n\n- [[Clippings/_evidence/steady-1]] — a\n- [[Clippings/_evidence/steady-2]] — b\n- [[Clippings/_evidence/steady-3]] — c\n' \
    > "$V/Clippings/_synthesis/2026-10-01-concept-steady-topic.md"

diverse recskip 3 rec-recent 0
diverse recold 3 rec-old 0
diverse recgrown 4 rec-grown 0
diverse recsame 4 rec-same 0
printf '2026-11-17\tconcept-rec-recent\t3\n2026-10-25\tconcept-rec-old\t3\n2026-11-17\tconcept-rec-grown\t3\n2026-11-17\tconcept-rec-same\t3\n2026-11-17\tconcept-rec-same\t4\nnot a record\n' \
    > "$V/Clippings/_synthesis/.substance-skips.tsv"

diverse idea 5 "" 0 "Ideas/"
diverse inbox 5 "" 5 "00-Inbox/"
for i in 1 2 3 4 5; do
    clip "$EV/notes-$i.md" " Notes Author $i" "https://same.example.org/n$i" \
         "2026-08-0$i" "" "Notes/"
done

diverse escape 5 "" 15 "../escape/"

clip "$EV/alice-1.md" " Alice Researcher" "https://one.example.org/a" "2026-07-10" ""
clip "$EV/alice-2.md" " Alice Researcher" "https://two.example.org/a" "2026-07-20" ""
clip "$EV/bob-1.md"   " Bob Writer"       "https://one.example.org/b" "2026-07-11" ""
clip "$EV/bob-2.md"   " Bob Writer"       "https://two.example.org/b" "2026-07-21" ""
printf -- '---\ntype: person\n---\nBob.\n' > "$V/20-Areas/Bob Writer.md"
clip "$EV/carol-1.md" " Carol Burst"      "https://one.example.org/c" "2026-07-12" ""
clip "$EV/carol-2.md" " Carol Burst"      "https://two.example.org/c" "2026-07-12" ""
clip "$EV/dan-1.md"   " Dan Recent"       "https://one.example.org/d" "2026-07-13" ""
clip "$EV/dan-2.md"   " Dan Recent"       "https://two.example.org/d" "2026-07-23" ""
printf -- '---\ntype: synthesis\n---\n## Evidence (2 clips, 2 unique URLs)\n\n- [[Clippings/_evidence/dan-1]] — a\n- [[Clippings/_evidence/dan-2]] — b\n' \
    > "$V/Clippings/_synthesis/2026-11-18-author-dan-recent.md"

for i in 1 2 3 4 5; do
    clip "$EV/noauth-$i.md" "" "https://x.com/i/status/300$i" "2026-06-0$i" "no-author-feed"
done
clip "$EV/urlv-1.md" "" "https://x.com/u_one/status/4001"   "2026-05-01" "url-voices"
clip "$EV/urlv-2.md" "" "https://x.com/u_two/status/4002"   "2026-05-02" "url-voices"
clip "$EV/urlv-3.md" "" "https://x.com/u_three/status/4003" "2026-05-03" "url-voices"

clip "$EV/twov-1.md" " @alice_t" "https://x.com/alice_t/status/5001" "2026-04-01" "two-voices"
clip "$EV/twov-2.md" " @alice_t" "https://x.com/alice_t/status/5002" "2026-04-05" "two-voices"
clip "$EV/twov-3.md" " @bob_t"   "https://x.com/bob_t/status/5003"   "2026-04-09" "two-voices"
for i in 1 2 3; do
    clip "$EV/twovf-$i.md" " @alice_f" "https://x.com/alice_f/status/600$i" "2026-04-1$i" "two-voices-five"
done
for i in 4 5; do
    clip "$EV/twovf-$i.md" " @bob_f" "https://x.com/bob_f/status/600$i" "2026-04-1$i" "two-voices-five"
done

clip "$EV/udm-1.md" " Undated Mixed 1" "https://udm-1.example.org/p" "2026-02-10" "undated-mixed"
clip "$EV/udm-2.md" " Undated Mixed 2" "https://udm-2.example.org/p" "2026-02-10" "undated-mixed"
printf -- '---\ntitle: nodate\nauthor: Undated Mixed 3\nsource: "https://udm-3.example.org/p"\ntags:\n  - undated-mixed\nprocessed: true\n---\nbody\n' > "$EV/udm-3.md"
clip "$EV/uds-1.md" " Undated Sparse 1" "https://uds-1.example.org/p" "2026-02-10" "undated-sparse"
for i in 2 3; do
    printf -- '---\ntitle: nodate\nauthor: Undated Sparse %s\nsource: "https://uds-%s.example.org/p"\ntags:\n  - undated-sparse\nprocessed: true\n---\nbody\n' "$i" "$i" > "$EV/uds-$i.md"
done
for i in 1 2 3; do
    clip "$EV/udw-$i.md" " Undated Wide $i" "https://udw-$i.example.org/p" "2026-01-0$((i * 3))" "undated-wide"
done
printf -- '---\ntitle: nodate\nauthor: Undated Wide 4\nsource: "https://udw-4.example.org/p"\ntags:\n  - undated-wide\nprocessed: true\n---\nbody\n' > "$EV/udw-4.md"

clip "$EV/dst-1.md" " Dst Author 1" "https://dst-1.example.org/p" "2026-03-08T01:00:00" "dst-pair"
clip "$EV/dst-2.md" " Dst Author 2" "https://dst-2.example.org/p" "2026-03-08T13:00:00" "dst-pair"
clip "$EV/dst-3.md" " Dst Author 3" "https://dst-3.example.org/p" "2026-03-09T01:30:00" "dst-pair"

printf -- '---\nauthor: Ghost\nsource: "https://ghost.example.org/x"\ndate_clipped: 2026-10-09\ntags:\n  - context-windows\n---\nbody\n' \
    > "$EV/unprocessed.md"
clip "$V/Clippings/_done/archived.md" " Done Author" "https://done.example.org/x" "2026-10-09" "context-windows"
printf -- '---\ntype: synthesis\nprocessed: true\ntags:\n  - context-windows\n---\nbody\n' \
    > "$V/Clippings/_synthesis/2026-09-09-stray-marker.md"
printf -- '---\nprocessed: true\ntags:\n  - context-windows\n---\nbody\n' > "$V/Clippings/_deferred.md"
printf -- '---\ntitle: broken\nprocessed: true\ntags:\n  - context-windows\n' > "$EV/broken.md"
printf -- '---\ntitle: malformed\nprocessed: true\nthis line is no key and no list item\n---\nbody\n' > "$EV/malformed.md"

run() { node "$TOOL" "$V" --today "$TODAY" "$@"; }

echo "Test 0: tool exists"
[ -f "$TOOL" ] && have=yes || have=no
assert "tools/synthesis-candidates.mjs is present" "yes" "$have"

run --format json > "$tmp/out1.json" 2> "$tmp/err1.txt"
rc=$?
assert "json run exits 0" "0" "$rc"
run --format json > "$tmp/out2.json" 2>/dev/null
run > "$tmp/lines1.txt" 2>/dev/null
run > "$tmp/lines2.txt" 2>/dev/null

J="$tmp/out1.json"
field() {
    node -e '
      const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const c = j.candidates.find((x) => x.slug === process.argv[2]);
      console.log(c ? String(c[process.argv[3]]) : "ABSENT");
    ' "$J" "$1" "$2" 2>/dev/null || echo "NO-JSON"
}
top() {
    node -e '
      const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      console.log(String(eval(process.argv[2])));
    ' "$J" "$1" 2>/dev/null || echo "NO-JSON"
}

echo "Test 1: determinism — two runs are byte-identical"
cmp -s "$tmp/out1.json" "$tmp/out2.json" && same=identical || same=differs
assert "json output identical on two runs" "identical" "$same"
cmp -s "$tmp/lines1.txt" "$tmp/lines2.txt" && same=identical || same=differs
assert "line output identical on two runs" "identical" "$same"
assert "line output is non-empty" "yes" "$([ -s "$tmp/lines1.txt" ] && echo yes || echo no)"

echo "Test 2: all four pattern kinds list at least one passing candidate"
for k in concept author tag folder; do
    assert "a $k candidate passes" "true" \
        "$(top "j.candidates.some((c) => c.kind === \"$k\" && c.status === \"pass\")")"
done

echo "Test 3: platform-domain rule (concept + tag)"
assert "5 unrelated authors on one platform: concept passes" "pass" "$(field concept-context-windows status)"
assert "…with 5 evidence clips" "5" "$(field concept-context-windows clipCount)"
assert "…counting 5 distinct sources" "5" "$(field concept-context-windows distinctSources)"
assert "…and its tag lens is dropped: one candidate per subject, the concept" "same-subject-as-concept" "$(field tag-context-windows-moc reason)"
assert "…as a dedup skip" "dedup" "$(field tag-context-windows-moc category)"
assert "3 clips from 2 sources (2 by one author, 1 by another): concept skipped" "skip" "$(field concept-two-voices status)"
assert "…as too-few-sources" "too-few-sources" "$(field concept-two-voices reason)"
assert "…a confidence-floor skip" "confidence-floor" "$(field concept-two-voices category)"
assert "5 clips from 2 sources: concept skipped" "too-few-sources" "$(field concept-two-voices-five reason)"
assert "…and the tag lens, which needs 2 sources, passes" "pass" "$(field tag-two-voices-five-moc status)"
assert "exactly 3 distinct sources: concept passes" "pass" "$(field concept-url-voices status)"
assert "5-clip single-author group: concept skipped" "skip" "$(field concept-solo-voice status)"
assert "…reason names the single author" "single-author-on-platform" "$(field concept-solo-voice reason)"
assert "…as a confidence-floor skip" "confidence-floor" "$(field concept-solo-voice category)"
assert "single-author tag lens skipped too" "single-author-on-platform" "$(field tag-solo-voice-moc reason)"
assert "unknown authors are ONE source, not many" "single-author-on-platform" "$(field concept-no-author-feed reason)"
assert "author recovered from the status URL counts" "pass" "$(field concept-url-voices status)"
assert "non-platform single domain still fails" "single-source-domain" "$(field concept-blog-roll reason)"

echo "Test 4: the other confidence-floor and exclusion reasons"
assert "same-day burst skipped" "single-24h-window" "$(field concept-same-day-burst reason)"
assert "existing concept page excludes the concept" "existing-vault-page" "$(field concept-has-page reason)"
assert "existing concept page is a dedup-category skip" "dedup" "$(field concept-has-page category)"
assert "existing MOC excludes the tag" "existing-vault-page" "$(field tag-mapped-moc reason)"
assert "existing MOC also covers the concept of the same name" "existing-vault-page" "$(field concept-mapped reason)"
assert "existing person note excludes the author" "existing-vault-page" "$(field author-bob-writer reason)"
assert "same-day author pair skipped" "single-24h-window" "$(field author-carol-burst reason)"
assert "existing folder excludes the folder" "existing-vault-page" "$(field folder-00-inbox reason)"
assert "single-domain folder skipped" "single-source-domain" "$(field folder-notes reason)"

echo "Test 4b: the 24-hour floor fails closed on undated clips"
assert "2 dated clips on one day plus an undated one: skipped" "single-24h-window" "$(field concept-undated-mixed reason)"
assert "fewer than 2 dated clips: skipped" "undated-evidence" "$(field concept-undated-sparse reason)"
assert "…as a confidence-floor skip" "confidence-floor" "$(field concept-undated-sparse category)"
assert "dated clips spread over weeks plus an undated one: passes" "pass" "$(field concept-undated-wide status)"

echo "Test 4c: a zoneless date-time is UTC, whatever the station zone"
assert "24.5 h apart in UTC, 23.5 h in a DST zone: passes" "pass" "$(field concept-dst-pair status)"
for z in UTC America/Los_Angeles Pacific/Kiritimati; do
    TZ=$z node "$TOOL" "$V" --today "$TODAY" --format json > "$tmp/tz.json" 2>/dev/null
    cmp -s "$tmp/tz.json" "$tmp/out1.json" && same=identical || same=differs
    assert "TZ=$z prints the same output" "identical" "$same"
done

echo "Test 5: 14-day dedup window"
assert "synthesis page 3 days old: skipped" "synthesis-page-within-14d" "$(field concept-recent-topic reason)"
assert "…as a dedup skip" "dedup" "$(field concept-recent-topic category)"
assert "author page 2 days old: skipped" "synthesis-page-within-14d" "$(field author-dan-recent reason)"
assert "old page + more clips: passes" "pass" "$(field concept-grown-topic status)"
assert "…supersedes the old page" "2026-10-01-concept-grown-topic.md" "$(field concept-grown-topic supersedes)"
assert "old page, no new evidence: skipped" "no-new-evidence" "$(field concept-steady-topic reason)"

echo "Test 5a: a candidate that failed the substance gate is not re-offered every run"
assert "failed 3 days ago, same evidence: skipped" "substance-floor-recorded" "$(field concept-rec-recent reason)"
assert "…as a dedup skip" "dedup" "$(field concept-rec-recent category)"
assert "failed 26 days ago: offered again" "pass" "$(field concept-rec-old status)"
assert "failed 3 days ago, evidence since grew: offered again" "pass" "$(field concept-rec-grown status)"
assert "two records the same day: the later one wins" "substance-floor-recorded" "$(field concept-rec-same reason)"

echo "Test 5b: evidence cap"
assert "group of 45 reports its full size" "45" "$(field concept-big-topic clipCount)"
assert "…lists the 40 newest clips" "40" "$(field concept-big-topic evidenceCount)"
assert "…and is not re-proposed against a page that lists 40" "no-new-evidence" "$(field concept-big-topic reason)"

echo "Test 6: author and folder lenses"
assert "author with 2 spread clips and no note passes" "pass" "$(field author-alice-researcher status)"
assert "author of a single-author platform group passes (domain-exempt)" "pass" "$(field author-lone-voice status)"
assert "folder with 5 diverse promotion candidates passes" "pass" "$(field folder-ideas status)"
assert "folder slug lowercases and joins with hyphens" "5" "$(field folder-ideas clipCount)"
assert "unknown author is not an author candidate" "ABSENT" "$(field author-unknown status)"
assert "a promotion target that climbs out of the vault is no folder" "ABSENT" "$(field folder-escape status)"

echo "Test 7: counted inputs"
assert "unprocessed / _done / _synthesis / _deferred clips do not count" "5" "$(field concept-context-windows clipCount)"
assert "an unclosed and a malformed frontmatter are the input exclusions" "2" "$(top 'j.inputsExcluded.length')"
assert "…the unclosed one named by path" "Clippings/_evidence/broken.md" "$(top 'j.inputsExcluded[0].path')"
assert "…the malformed one named by path" "Clippings/_evidence/malformed.md" "$(top 'j.inputsExcluded[1].path')"
assert "…with the line that is not a key" "frontmatter parse error: line 4 is not a \"key: value\" entry" "$(top 'j.inputsExcluded[1].reason')"
assert "groups below the lens threshold are not candidates" "ABSENT" "$(field tag-blog-roll-moc status)"

echo "Test 8: line output carries the runbook log lines"
assert "skip lines use the runbook ⊘ shape" "1" \
    "$(grep -c '^⊘ concept-solo-voice — skipped (confidence-floor): single-author-on-platform' "$tmp/lines1.txt")"
assert "input exclusions use the runbook shape" "1" \
    "$(grep -c '^⊘ Clippings/_evidence/broken.md — excluded from synthesis (input): frontmatter parse error' "$tmp/lines1.txt")"
assert "a passing candidate has a PASS line" "1" \
    "$(grep -c '^PASS .* concept-context-windows ' "$tmp/lines1.txt")"

echo "Test 9: --since restricts to triaged_at >= date"
node "$TOOL" "$V" --today "$TODAY" --since 2026-10-04 --format json > "$tmp/since.json" 2>/dev/null
J="$tmp/since.json"
assert "--since 2026-10-04 leaves 2 context-windows clips: no candidate" "ABSENT" "$(field concept-context-windows status)"
J="$tmp/out1.json"

echo "Test 10: harvest-completion gate"
rm -f "$V/.harvest.done"
node "$TOOL" "$V" --today "$TODAY" > "$tmp/gate.out" 2> "$tmp/gate.err"
rc=$?
assert "no .harvest.done: exit 2" "2" "$rc"
assert "…with the runbook message" "1" "$(grep -c 'upstream harvest incomplete' "$tmp/gate.err")"
echo "x" > "$V/.harvest.done"

echo "Test 11: read-only — the vault is unchanged by a run"
before=$(find "$V" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
run --format json > /dev/null 2>&1
after=$(find "$V" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
assert "no file written or touched" "$before" "$after"

echo "Test 11b: vault resolution and usage errors"
OBSIDIAN_VAULT_PATH="$V" node "$TOOL" --today "$TODAY" --format json > "$tmp/env.json" 2>/dev/null
cmp -s "$tmp/env.json" "$tmp/out1.json" && same=identical || same=differs
assert "vault defaults to OBSIDIAN_VAULT_PATH" "identical" "$same"
node "$TOOL" "$V" --bogus > /dev/null 2>&1; assert "unknown flag: exit 1" "1" "$?"
node "$TOOL" "$V" --format xml > /dev/null 2>&1; assert "bad --format: exit 1" "1" "$?"
node "$TOOL" "$V" --today 20-11-2026 > /dev/null 2>&1; assert "bad --today: exit 1" "1" "$?"
node "$TOOL" "$V" --since soon > /dev/null 2>&1; assert "bad --since: exit 1" "1" "$?"
node "$TOOL" "$V" --today 2026-99-99 > /dev/null 2>&1; assert "--today with no such month: exit 1" "1" "$?"
node "$TOOL" "$V" --today 2026-02-30 > /dev/null 2>&1; assert "--today with no such day: exit 1" "1" "$?"
node "$TOOL" "$V" "$V" > /dev/null 2>&1; assert "second positional argument: exit 1" "1" "$?"

echo "Test 12: no Clippings/ is a clean no-op"
mkdir -p "$tmp/empty"
out=$(node "$TOOL" "$tmp/empty" --today "$TODAY" 2>&1); rc=$?
assert "exit 0" "0" "$rc"
assert "runbook message" "synthesize-clips: no Clippings/ — nothing to synthesize" "$out"

echo "Test 13: runbook wiring"
first_tool=$(grep -n 'synthesis-candidates.mjs' "$RUNBOOK" | head -1 | cut -d: -f1)
input_val=$(grep -n '^### Input validation' "$RUNBOOK" | head -1 | cut -d: -f1)
detect=$(grep -n '^### Pattern detection' "$RUNBOOK" | head -1 | cut -d: -f1)
[ -n "$first_tool" ] && [ -n "$input_val" ] && [ "$first_tool" -lt "$input_val" ] && order=ok || order=bad
assert "runbook names the tool before input validation" "ok" "$order"
[ -n "$first_tool" ] && [ -n "$detect" ] && [ "$first_tool" -lt "$detect" ] && order=ok || order=bad
assert "runbook names the tool before pattern detection" "ok" "$order"
assert "runbook requires one skip line per failing candidate" "1" \
    "$(grep -c 'one skip line per failing candidate' "$RUNBOOK")"
assert "runbook keeps the harvest-completion gate" "1" "$(grep -c '^### G-8' "$RUNBOOK")"
assert "runbook keeps the counting invariant" "1" "$(grep -c 'Counting invariant' "$RUNBOOK")"

echo
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
