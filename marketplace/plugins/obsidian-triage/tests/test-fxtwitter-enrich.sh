#!/usr/bin/env bash
# Smoke tests for LUNA-33 fxtwitter enricher.
#
# Scope:
#   - script parses (node --check)
#   - package.json declares js-yaml
#   - canonicalisation rules
#   - DraftJS→md unit converter: header-two + unstyled + unordered-list-item
#     fixture renders to expected markdown
#   - inline styles (BOLD, ITALIC, CODE) + LINK entity render correctly
#   - idempotency: re-run skips clips with enriched_at:
#   - G-3 byte-identity check is present in the script
#   - --dry-run blocks writes
#   - smoke against cached fxt JSON in /tmp/fxt-compare/ (skip if absent)
#
# Does NOT hit the network.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
SCRIPT="$TOOLS_DIR/fxtwitter-enrich.mjs"

pass=0
fail=0

assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"
        pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

# -- Test 1: script parses via node --check ------------------------------
echo "Test 1: fxtwitter-enrich.mjs parses"
if [ ! -r "$SCRIPT" ]; then
    assert "script exists" "yes" "no"
else
    assert "script exists" "yes" "yes"
    if node --check "$SCRIPT" 2>/dev/null; then parsed=ok; else parsed=fail; fi
    assert "script parses (node --check)" "ok" "$parsed"
fi

# -- Test 2: package.json declares js-yaml -------------------------------
echo "Test 2: js-yaml dep present"
pkg="$TOOLS_DIR/package.json"
if grep -q '"js-yaml"' "$pkg"; then has_yaml=yes; else has_yaml=no; fi
assert "package.json declares js-yaml" "yes" "$has_yaml"

# -- Test 3: canonicalisation rules ------------------------------------
# The script must use the /[^/]+/status/\d+ regex + map twitter.com -> x.com.
echo "Test 3: canonicalisation rules"
if grep -q 'canonicalXUrl' "$SCRIPT"; then has_fn=yes; else has_fn=no; fi
assert "canonicalXUrl symbol present" "yes" "$has_fn"
# Spot-check: strips mobile./www. and maps twitter->x (literal substring match).
if grep -q 'mobile\\\.' "$SCRIPT" && grep -qE '\(\??:?x\|twitter\)' "$SCRIPT"; then
    has_rx=yes
else
    has_rx=no
fi
assert "$(basename "$SCRIPT") strips mobile. + maps twitter→x" "yes" "$has_rx"

# -- Test 4: DraftJS→md fixture --------------------------------------
echo "Test 4: DraftJS → markdown converter"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
# Resolve the absolute file:// URL once so node ESM works on Win + POSIX.
script_url="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$SCRIPT")"
cat >"$tmpdir/draft-test.mjs" <<EOF
import { draftJsToMarkdown } from "$script_url";

// Block-type fixture: header-two + unstyled + unordered-list-item.
const fixture1 = {
  blocks: [
    { type: "header-two", text: "Heading", inlineStyleRanges: [], entityRanges: [], depth: 0 },
    { type: "unstyled", text: "A paragraph.", inlineStyleRanges: [], entityRanges: [], depth: 0 },
    { type: "unordered-list-item", text: "item one", inlineStyleRanges: [], entityRanges: [], depth: 0 },
    { type: "unordered-list-item", text: "item two", inlineStyleRanges: [], entityRanges: [], depth: 0 },
  ],
  entityMap: {},
};
const md1 = draftJsToMarkdown(fixture1);
const expected1 = "## Heading\n\nA paragraph.\n\n- item one\n\n- item two";
console.log("FIXTURE1_MATCH=" + (md1 === expected1 ? "yes" : "no"));
if (md1 !== expected1) {
  console.log("  got     :", JSON.stringify(md1));
  console.log("  expected:", JSON.stringify(expected1));
}

// Inline-style fixture: BOLD wrap on a substring + LINK entity.
const fixture2 = {
  blocks: [{
    type: "unstyled",
    text: "Hello bold world",
    inlineStyleRanges: [{ offset: 6, length: 4, style: "BOLD" }],
    entityRanges: [{ offset: 11, length: 5, key: 0 }],
    depth: 0,
  }],
  entityMap: { "0": { type: "LINK", mutability: "MUTABLE", data: { url: "https://x.com" } } },
};
const md2 = draftJsToMarkdown(fixture2);
// Expect: "Hello **bold** [world](https://x.com)"
console.log("FIXTURE2_BOLD=" + (md2.includes("**bold**") ? "yes" : "no"));
console.log("FIXTURE2_LINK=" + (md2.includes("[world](https://x.com)") ? "yes" : "no"));

// Ordered-list-item counter
const fixture3 = {
  blocks: [
    { type: "ordered-list-item", text: "first", inlineStyleRanges: [], entityRanges: [], depth: 0 },
    { type: "ordered-list-item", text: "second", inlineStyleRanges: [], entityRanges: [], depth: 0 },
    { type: "ordered-list-item", text: "third", inlineStyleRanges: [], entityRanges: [], depth: 0 },
  ],
  entityMap: {},
};
const md3 = draftJsToMarkdown(fixture3);
const expected3 = "1. first\n\n2. second\n\n3. third";
console.log("FIXTURE3_OL=" + (md3 === expected3 ? "yes" : "no"));

// Unknown block type — falls back to plain text
const fixture4 = {
  blocks: [{ type: "some-future-type", text: "unknown but printed", inlineStyleRanges: [], entityRanges: [], depth: 0 }],
  entityMap: {},
};
const md4 = draftJsToMarkdown(fixture4);
console.log("FIXTURE4_FALLBACK=" + (md4.includes("unknown but printed") ? "yes" : "no"));

// Code-block
const fixture5 = {
  blocks: [{ type: "code-block", text: "console.log('hi')", inlineStyleRanges: [], entityRanges: [], depth: 0 }],
  entityMap: {},
};
const md5 = draftJsToMarkdown(fixture5);
console.log("FIXTURE5_CODE=" + (md5.startsWith("\`\`\`") && md5.endsWith("\`\`\`") ? "yes" : "no"));
EOF

# Use node (NOT bun) because bun may not be on PATH in CI;
# import.meta.main is bun-only but we don't need it for an import-only test.
out="$(node "$tmpdir/draft-test.mjs" 2>&1)"
grep -q 'FIXTURE1_MATCH=yes' <<<"$out" && r1=yes || r1=no
grep -q 'FIXTURE2_BOLD=yes' <<<"$out" && r2=yes || r2=no
grep -q 'FIXTURE2_LINK=yes' <<<"$out" && r3=yes || r3=no
grep -q 'FIXTURE3_OL=yes' <<<"$out" && r4=yes || r4=no
grep -q 'FIXTURE4_FALLBACK=yes' <<<"$out" && r5=yes || r5=no
grep -q 'FIXTURE5_CODE=yes' <<<"$out" && r6=yes || r6=no
assert "DraftJS: header-two + unstyled + ul block-types" "yes" "$r1"
assert "DraftJS: BOLD inline-style wrap" "yes" "$r2"
assert "DraftJS: LINK entity wrap" "yes" "$r3"
assert "DraftJS: ordered-list-item counter" "yes" "$r4"
assert "DraftJS: unknown block-type fallback to plain text" "yes" "$r5"
assert "DraftJS: code-block fenced output" "yes" "$r6"
if [ "$r1" != "yes" ] || [ "$r2" != "yes" ]; then
    echo "  (debug output)"
    printf '    %s\n' "$out"
fi

# -- Test 5: idempotency — already-enriched clips skip --------------
echo "Test 5: idempotency on enriched_at: marker"
if grep -q 'alreadyEnriched' "$SCRIPT" && grep -q 'enriched_at:' "$SCRIPT"; then
    has_idem=yes
else
    has_idem=no
fi
assert "alreadyEnriched / enriched_at: present in script" "yes" "$has_idem"

# -- Test 6: G-3 byte-identity check + revert-on-failure ----------------
echo "Test 6: G-3 byte-identity check present"
if grep -q 'G-3' "$SCRIPT" && grep -q 'reverted' "$SCRIPT"; then
    has_g3=yes
else
    has_g3=no
fi
assert "G-3 invariant + revert paths present" "yes" "$has_g3"

# -- Test 7: --dry-run guard blocks writes ------------------------------
echo "Test 7: --dry-run flag is honored"
if grep -q 'dryRun' "$SCRIPT" && grep -q 'would enrich' "$SCRIPT"; then
    has_dry=yes
else
    has_dry=no
fi
assert "--dry-run short-circuits write path" "yes" "$has_dry"

# Functional dry-run: build a fake vault, invoke --dry-run --limit 1, confirm
# zero file mutations.
fake_vault="$tmpdir/vault"
mkdir -p "$fake_vault/Clippings"
cat >"$fake_vault/Clippings/sample.md" <<'EOF'
---
source: https://x.com/jack/status/20
processed: true
---
# Sample
body
EOF
before_sha="$(sha256sum "$fake_vault/Clippings/sample.md" | cut -d' ' -f1)"
node "$SCRIPT" --vault "$fake_vault" --limit 1 --dry-run >/dev/null 2>"$tmpdir/dr.err"
dr_rc=$?
after_sha="$(sha256sum "$fake_vault/Clippings/sample.md" | cut -d' ' -f1)"
assert "--dry-run exit 0" "0" "$dr_rc"
assert "--dry-run leaves clip byte-identical" "$before_sha" "$after_sha"
dr_out="$(node "$SCRIPT" --vault "$fake_vault" --limit 1 --dry-run 2>/dev/null)"
grep -q 'dry-run' <<<"$dr_out" && has_dr_txt=yes || has_dr_txt=no
assert "--dry-run valid clip reports dry-run text" "yes" "$has_dr_txt"

# --dry-run must run the write path's YAML validation, so a clip
# whose frontmatter fails the parse-validate in a real run fails in a dry-run
# too (and still writes nothing).
bad_vault="$tmpdir/badvault"
mkdir -p "$bad_vault/Clippings"
cat >"$bad_vault/Clippings/bad.md" <<'EOF'
---
source: https://x.com/jack/status/20
processed: true
broken: [unclosed
---
# Sample
body
EOF
bad_before="$(sha256sum "$bad_vault/Clippings/bad.md" | cut -d' ' -f1)"
node "$SCRIPT" --vault "$bad_vault" --limit 1 --dry-run >"$tmpdir/bad.out" 2>"$tmpdir/bad.err"
bad_rc=$?
bad_after="$(sha256sum "$bad_vault/Clippings/bad.md" | cut -d' ' -f1)"
assert "--dry-run bad-YAML clip exits 3 (failed)" "3" "$bad_rc"
grep -q 'failed (yaml parse' "$tmpdir/bad.err" && bad_msg=yes || bad_msg=no
assert "--dry-run bad-YAML clip reports yaml parse failure" "yes" "$bad_msg"
assert "--dry-run bad-YAML clip left byte-identical" "$bad_before" "$bad_after"

# js-yaml missing: a copy of the script with no node_modules in reach must
# fail --dry-run the way a real run would.
mkdir -p "$tmpdir/noyaml"
cp "$SCRIPT" "$tmpdir/noyaml/fxtwitter-enrich.mjs"
node "$tmpdir/noyaml/fxtwitter-enrich.mjs" --vault "$fake_vault" --limit 1 --dry-run >/dev/null 2>"$tmpdir/ny.err"
ny_rc=$?
assert "--dry-run without js-yaml exits 3 (failed)" "3" "$ny_rc"
grep -q 'failed (yaml' "$tmpdir/ny.err" && ny_msg=yes || ny_msg=no
assert "--dry-run without js-yaml reports the import failure" "yes" "$ny_msg"

# -- Test 8: YAML parse-validate via js-yaml present -------------------
echo "Test 8: js-yaml import + parse-validate present"
if grep -q 'js-yaml' "$SCRIPT"; then has_yi=yes; else has_yi=no; fi
assert "js-yaml referenced in script" "yes" "$has_yi"

# -- Test 9: rate-limit politeness — 1s sleep before fetch -------------
echo "Test 9: rate-limit 1000ms sleep present"
if grep -qE 'RATE_LIMIT_MS\s*=\s*1000' "$SCRIPT"; then has_rl=yes; else has_rl=no; fi
assert "1000ms rate-limit constant present" "yes" "$has_rl"

# -- Test 10: smoke against cached fxt JSON -------------------------------
echo "Test 10: cached fxt JSON smoke"
# smoke_fxt_dir <dir> -> prints the PARSED=/WITH_*= counters for every *.json in
# <dir>. Resolves <dir> to a node-friendly absolute path first: /tmp/ on Git Bash
# is a shell alias to %TEMP%; node sees /tmp/ as C:\tmp\ literally. Use cygpath
# when available; fall back to the bash-visible path otherwise.
smoke_fxt_dir() {
    local dir_raw="$1" dir dir_js
    if command -v cygpath >/dev/null 2>&1; then
        dir="$(cygpath -w "$dir_raw" 2>/dev/null)"
    else
        dir="$dir_raw"
    fi
    # Normalise backslashes for the JS string literal.
    dir_js="${dir//\\//}"
    cat >"$tmpdir/smoke.mjs" <<EOF
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
const dir = "$dir_js";
const files = readdirSync(dir).filter(f => f.endsWith(".json"));
let parsed = 0, withTweet = 0, withArticle = 0, withNote = 0, withQuote = 0;
for (const f of files) {
  const raw = JSON.parse(readFileSync(join(dir, f), "utf-8"));
  parsed++;
  if (raw.tweet) {
    withTweet++;
    if (raw.tweet.article) withArticle++;
    if (raw.tweet.is_note_tweet) withNote++;
    if (raw.tweet.quote) withQuote++;
  }
}
console.log("PARSED=" + parsed);
console.log("WITH_TWEET=" + withTweet);
console.log("WITH_NOTE=" + withNote);
console.log("WITH_QUOTE=" + withQuote);
console.log("WITH_ARTICLE=" + withArticle);
EOF
    node "$tmpdir/smoke.mjs" 2>&1
}

# the hermetic case runs everywhere — a fixture cache built here,
# never the operator's scratch dir (absent on CI, where this used to SKIP).
fxt_fixture="$tmpdir/fxt-fixture"
mkdir -p "$fxt_fixture"
printf '%s\n' '{"tweet":{"text":"plain"}}' > "$fxt_fixture/plain.json"
printf '%s\n' '{"tweet":{"text":"note","is_note_tweet":true}}' > "$fxt_fixture/note.json"
printf '%s\n' '{"tweet":{"text":"q","quote":{"text":"inner"},"article":{"title":"a"}}}' > "$fxt_fixture/quote-article.json"
printf '%s\n' '{"code":404}' > "$fxt_fixture/no-tweet.json"
out="$(smoke_fxt_dir "$fxt_fixture")"
assert "fxt fixture JSON cache: counters match the fixture" \
    "PARSED=4 WITH_TWEET=3 WITH_NOTE=1 WITH_QUOTE=1 WITH_ARTICLE=1" \
    "$(echo "$out" | tr '\n' ' ' | sed 's/ $//')"

# Optional extra: the operator's scratch dir of real payloads, when present.
fxt_cache_raw="/tmp/fxt-compare"
if [ ! -d "$fxt_cache_raw" ]; then
    echo "  SKIP  $fxt_cache_raw not present — real cached fxt payloads NOT smoked on this host"
else
    out="$(smoke_fxt_dir "$fxt_cache_raw")"
    parsed_n="$(echo "$out" | grep -oE 'PARSED=[0-9]+' | cut -d= -f2)"
    if [ -n "$parsed_n" ] && [ "$parsed_n" -gt 0 ]; then
        assert "fxt JSON cache parses (n>0)" "yes" "yes"
        printf '    info: %s\n' "$out"
    else
        assert "fxt JSON cache parses (n>0)" "yes" "no"
    fi
fi

# -- Test 11: Stage-4 gate — only processed: true clips enrich -------
echo "Test 11: Stage-4 gate (processed: true) present"
if grep -q 'isProcessed' "$SCRIPT" && grep -q 'processed' "$SCRIPT"; then
    has_p4=yes
else
    has_p4=no
fi
assert "isProcessed gate present" "yes" "$has_p4"

# -- Test 12: needs_thread written to .md frontmatter (end-to-end write path) --
echo "Test 12: needs_thread written to clip frontmatter (end-to-end)"

# Strategy: use the FXT_FIXTURE env var (supported by fetchFxt in fxtwitter-enrich.mjs)
# to serve a local JSON file as the fxtwitter API response, bypassing the network.
# We drive the full processClip → writeEnrichment path and grep the written .md.

# --- Case A: thread-signal tweet (text contains "1/5") → needs_thread: true ---
thread_vault="$tmpdir/vault-thread"
mkdir -p "$thread_vault/Clippings"
cat >"$thread_vault/Clippings/thread-clip.md" <<'EOF'
---
source: https://x.com/jack/status/20
processed: true
---
# tweet from x.com/jack/status/20

## The Idea

## Source
https://x.com/jack/status/20
EOF

# Minimal fxtwitter JSON fixture with a thread-signal in tweet.text (1/5).
cat >"$tmpdir/fixture-thread.json" <<'EOF'
{
  "code": 200,
  "tweet": {
    "text": "thoughts on agents\n\n1/5 first point",
    "replies": 0,
    "retweets": 0,
    "quotes": 0,
    "likes": 0,
    "views": 0,
    "author": { "screen_name": "jack" }
  }
}
EOF

FXT_FIXTURE="$tmpdir/fixture-thread.json" node "$SCRIPT" --vault "$thread_vault" --limit 1 >"$tmpdir/t12a.out" 2>&1
t12a_rc=$?
t12a_written="$thread_vault/Clippings/thread-clip.md"
if grep -q "needs_thread: true" "$t12a_written" 2>/dev/null; then
    t12a_has_flag=yes
else
    t12a_has_flag=no
fi
assert "Test12A: thread tweet writes needs_thread: true to frontmatter" "yes" "$t12a_has_flag"
t12a_partial=no; grep -q "enrichment_status: partial" "$t12a_written" 2>/dev/null && t12a_partial=yes
assert "Test12A: detected-but-uncaptured thread is enrichment_status partial, not ok" "yes" "$t12a_partial"
t12a_err=no; grep -q "last_error: thread_not_captured" "$t12a_written" 2>/dev/null && t12a_err=yes
assert "Test12A: thread partial names last_error thread_not_captured" "yes" "$t12a_err"
if [ "$t12a_has_flag" != "yes" ]; then
    echo "  (debug rc=$t12a_rc out=$(cat "$tmpdir/t12a.out" 2>/dev/null))"
    echo "  (written file: $(head -20 "$t12a_written" 2>/dev/null))"
fi

# --- Case B: plain tweet (no thread signal) → needs_thread absent ---
plain_vault="$tmpdir/vault-plain"
mkdir -p "$plain_vault/Clippings"
cat >"$plain_vault/Clippings/plain-clip.md" <<'EOF'
---
source: https://x.com/jack/status/21
processed: true
---
# tweet from x.com/jack/status/21

## The Idea

## Source
https://x.com/jack/status/21
EOF

cat >"$tmpdir/fixture-plain.json" <<'EOF'
{
  "code": 200,
  "tweet": {
    "text": "just a normal tweet",
    "replies": 5,
    "retweets": 0,
    "quotes": 0,
    "likes": 0,
    "views": 0,
    "author": { "screen_name": "jack" }
  }
}
EOF

cat >"$tmpdir/fixture-thread-none.json" <<'EOF'
{ "code": 200, "thread": null }
EOF
FXT_FIXTURE="$tmpdir/fixture-plain.json" FXT_THREAD_FIXTURE="$tmpdir/fixture-thread-none.json" node "$SCRIPT" --vault "$plain_vault" --limit 1 >"$tmpdir/t12b.out" 2>&1
t12b_rc=$?
t12b_written="$plain_vault/Clippings/plain-clip.md"
if grep -q "needs_thread:" "$t12b_written" 2>/dev/null; then
    t12b_has_flag=yes
else
    t12b_has_flag=no
fi
assert "Test12B: plain tweet does NOT write needs_thread to frontmatter" "no" "$t12b_has_flag"
if [ "$t12b_has_flag" != "no" ]; then
    echo "  (debug rc=$t12b_rc out=$(cat "$tmpdir/t12b.out" 2>/dev/null))"
    echo "  (written file: $(head -20 "$t12b_written" 2>/dev/null))"
fi

# -- Test 13: --reflag backfills needs_thread onto already-enriched clips ------
echo "Test 13: --reflag mode (body-safe needs_thread backfill)"

# Case A: an ALREADY-enriched clip (enriched_at set) with NO needs_thread, whose
# tweet has a thread signal → --reflag adds needs_thread:true, body byte-identical,
# enriched_at untouched.
reflag_vault="$tmpdir/vault-reflag"
mkdir -p "$reflag_vault/Clippings"
cat >"$reflag_vault/Clippings/enriched-clip.md" <<'EOF'
---
source: https://x.com/jack/status/30
processed: true
enriched_at: 2026-06-01
enrichment_source: fxtwitter
enrichment_status: ok
---
# tweet from x.com/jack/status/30

## The Idea
real body content that must survive verbatim

## Source
https://x.com/jack/status/30
EOF
body_before_a=$(awk 'f{print} /^---$/{c++} c==2{f=1}' "$reflag_vault/Clippings/enriched-clip.md")

cat >"$tmpdir/fixture-reflag-thread.json" <<'EOF'
{ "code": 200, "tweet": { "text": "deep dive on agents\n\n1/5 the first point", "replies": 0, "author": { "screen_name": "jack" } } }
EOF

FXT_FIXTURE="$tmpdir/fixture-reflag-thread.json" node "$SCRIPT" --vault "$reflag_vault" --reflag --limit 1 >"$tmpdir/t13a.out" 2>&1
t13a_flag=no; grep -q "needs_thread: true" "$reflag_vault/Clippings/enriched-clip.md" 2>/dev/null && t13a_flag=yes
assert "Test13A: --reflag adds needs_thread:true to enriched clip with signal" "yes" "$t13a_flag"
t13a_partial=no; grep -q "enrichment_status: partial" "$reflag_vault/Clippings/enriched-clip.md" 2>/dev/null && t13a_partial=yes
assert "Test13A: --reflag downgrades enrichment_status ok to partial" "yes" "$t13a_partial"
t13a_enriched=no; grep -q "enriched_at: 2026-06-01" "$reflag_vault/Clippings/enriched-clip.md" 2>/dev/null && t13a_enriched=yes
assert "Test13A: --reflag leaves enriched_at untouched" "yes" "$t13a_enriched"
body_after_a=$(awk 'f{print} /^---$/{c++} c==2{f=1}' "$reflag_vault/Clippings/enriched-clip.md")
t13a_body=changed; [ "$body_before_a" = "$body_after_a" ] && t13a_body=identical
assert "Test13A: --reflag leaves body byte-identical (no section added)" "identical" "$t13a_body"

# Case B: already-enriched clip, tweet has NO thread signal → needs_thread NOT added.
cat >"$reflag_vault/Clippings/enriched-plain.md" <<'EOF'
---
source: https://x.com/jack/status/31
processed: true
enriched_at: 2026-06-01
---
## The Idea
plain enriched body
EOF
cat >"$tmpdir/fixture-reflag-plain.json" <<'EOF'
{ "code": 200, "tweet": { "text": "just a normal tweet", "replies": 0, "author": { "screen_name": "jack" } } }
EOF
FXT_FIXTURE="$tmpdir/fixture-reflag-plain.json" node "$SCRIPT" --vault "$reflag_vault" --reflag >"$tmpdir/t13b.out" 2>&1 || true
t13b_flag=no; grep -q "needs_thread:" "$reflag_vault/Clippings/enriched-plain.md" 2>/dev/null && t13b_flag=yes
assert "Test13B: --reflag does NOT flag a no-signal enriched clip" "no" "$t13b_flag"

# Case C: a NON-enriched clip in --reflag mode is skipped (reflag only backfills enriched).
cat >"$reflag_vault/Clippings/not-enriched.md" <<'EOF'
---
source: https://x.com/jack/status/32
processed: true
---
## The Idea
not yet enriched
EOF
FXT_FIXTURE="$tmpdir/fixture-reflag-thread.json" node "$SCRIPT" --vault "$reflag_vault" --reflag >"$tmpdir/t13c.out" 2>&1 || true
t13c_flag=no; grep -q "needs_thread:" "$reflag_vault/Clippings/not-enriched.md" 2>/dev/null && t13c_flag=yes
assert "Test13C: --reflag skips a non-enriched clip (no needs_thread written)" "no" "$t13c_flag"

# -- Test 14: unmarked self-thread escalation via /2/thread/<id> --
echo "Test 14: unmarked self-thread caught via the fxtwitter thread API"

# Post-1 text carries NO text signal (no n/N counter, no thread, no pointer) —
# this is the Opus 5.5 launch-tweet shape from the ticket. replies > 0 is the
# only hint, so the fix must fall back to /2/thread/<id>.
cat >"$tmpdir/fixture-unmarked-status.json" <<'EOF'
{
  "code": 200,
  "tweet": {
    "text": "Introducing Opus 5.5, the first model in our new family.",
    "replies": 1906,
    "retweets": 0,
    "quotes": 0,
    "likes": 0,
    "views": 0,
    "author": { "screen_name": "claudeai" }
  }
}
EOF

# Case A: thread API returns >1 post by the same author -> needs_thread:true.
unmarked_vault="$tmpdir/vault-unmarked"
mkdir -p "$unmarked_vault/Clippings"
cat >"$unmarked_vault/Clippings/unmarked-clip.md" <<'EOF'
---
source: https://x.com/claudeai/status/40
processed: true
---
# tweet from x.com/claudeai/status/40

## The Idea

## Source
https://x.com/claudeai/status/40
EOF
cat >"$tmpdir/fixture-thread-multi.json" <<'EOF'
{
  "code": 200,
  "thread": [
    { "id": "40", "author": { "screen_name": "claudeai" }, "text": "post 1" },
    { "id": "41", "author": { "screen_name": "claudeai" }, "text": "post 2" }
  ]
}
EOF
FXT_FIXTURE="$tmpdir/fixture-unmarked-status.json" FXT_THREAD_FIXTURE="$tmpdir/fixture-thread-multi.json" \
    node "$SCRIPT" --vault "$unmarked_vault" --limit 1 >"$tmpdir/t14a.out" 2>&1
# A multi-post self-thread is CAPTURED under ## Thread, so nothing is missing
# and the clip carries no needs_thread.
t14a_flag=no; grep -q "post 2" "$unmarked_vault/Clippings/unmarked-clip.md" 2>/dev/null && ! grep -q "needs_thread:" "$unmarked_vault/Clippings/unmarked-clip.md" 2>/dev/null && t14a_flag=yes
assert "Test14A: no-text-signal + thread API multi-post -> captured under ## Thread, no needs_thread" "yes" "$t14a_flag"
if [ "$t14a_flag" != "yes" ]; then
    echo "  (debug out=$(cat "$tmpdir/t14a.out" 2>/dev/null))"
fi

# Case B: thread API returns only 1 post (itself) -> no escalation.
unmarked_vault_b="$tmpdir/vault-unmarked-b"
mkdir -p "$unmarked_vault_b/Clippings"
cat >"$unmarked_vault_b/Clippings/unmarked-clip-b.md" <<'EOF'
---
source: https://x.com/claudeai/status/41
processed: true
---
## The Idea

## Source
https://x.com/claudeai/status/41
EOF
cat >"$tmpdir/fixture-thread-single.json" <<'EOF'
{ "code": 200, "thread": [ { "id": "41", "author": { "screen_name": "claudeai" }, "text": "post 1" } ] }
EOF
FXT_FIXTURE="$tmpdir/fixture-unmarked-status.json" FXT_THREAD_FIXTURE="$tmpdir/fixture-thread-single.json" \
    node "$SCRIPT" --vault "$unmarked_vault_b" --limit 1 >"$tmpdir/t14b.out" 2>&1
t14b_flag=no; grep -q "needs_thread:" "$unmarked_vault_b/Clippings/unmarked-clip-b.md" 2>/dev/null && t14b_flag=yes
assert "Test14B: thread API single-post -> needs_thread NOT set" "no" "$t14b_flag"
t14b_ok=no; grep -q "enrichment_status: ok" "$unmarked_vault_b/Clippings/unmarked-clip-b.md" 2>/dev/null && t14b_ok=yes
assert "Test14B: clip still enriches normally on single-post thread" "yes" "$t14b_ok"

# Case C: thread API errors on a tweet with replies -> partial, never ok.
unmarked_vault_c="$tmpdir/vault-unmarked-c"
mkdir -p "$unmarked_vault_c/Clippings"
cat >"$unmarked_vault_c/Clippings/unmarked-clip-c.md" <<'EOF'
---
source: https://x.com/claudeai/status/42
processed: true
---
## The Idea

## Source
https://x.com/claudeai/status/42
EOF
cat >"$tmpdir/fixture-thread-error.json" <<'EOF'
{ "code": 404, "message": "not found" }
EOF
FXT_FIXTURE="$tmpdir/fixture-unmarked-status.json" FXT_THREAD_FIXTURE="$tmpdir/fixture-thread-error.json" \
    node "$SCRIPT" --vault "$unmarked_vault_c" --limit 1 >"$tmpdir/t14c.out" 2>&1
# A failed thread check on a tweet with replies does not fail open: it is
# stamped needs_thread + partial, never ok.
t14c_flag=no; grep -q "needs_thread: true" "$unmarked_vault_c/Clippings/unmarked-clip-c.md" 2>/dev/null && t14c_flag=yes
assert "Test14C: thread API error on a tweet with replies -> needs_thread true" "yes" "$t14c_flag"
t14c_ok=no; grep -q "enrichment_status: ok" "$unmarked_vault_c/Clippings/unmarked-clip-c.md" 2>/dev/null && t14c_ok=yes
assert "Test14C: thread API error on a tweet with replies is never ok" "no" "$t14c_ok"

# -- Test 15: --reflag surfaces the same unmarked-self-thread miss --
echo "Test 15: --reflag backfill catches an unmarked self-thread via the thread API"
reflag_unmarked_vault="$tmpdir/vault-reflag-unmarked"
mkdir -p "$reflag_unmarked_vault/Clippings"
cat >"$reflag_unmarked_vault/Clippings/enriched-unmarked.md" <<'EOF'
---
source: https://x.com/claudeai/status/50
processed: true
enriched_at: 2026-06-01
enrichment_source: fxtwitter
enrichment_status: ok
---
## The Idea
already-enriched body, only post 1 was captured

## Source
https://x.com/claudeai/status/50
EOF
cat >"$tmpdir/fixture-reflag-unmarked-status.json" <<'EOF'
{
  "code": 200,
  "tweet": {
    "text": "Introducing Opus 5.5, the first model in our new family.",
    "replies": 1906,
    "author": { "screen_name": "claudeai" }
  }
}
EOF
FXT_FIXTURE="$tmpdir/fixture-reflag-unmarked-status.json" FXT_THREAD_FIXTURE="$tmpdir/fixture-thread-multi.json" \
    node "$SCRIPT" --vault "$reflag_unmarked_vault" --reflag --limit 1 >"$tmpdir/t15.out" 2>&1
t15_flag=no; grep -q "needs_thread: true" "$reflag_unmarked_vault/Clippings/enriched-unmarked.md" 2>/dev/null && t15_flag=yes
assert "Test15: --reflag flags a past unmarked-self-thread clip via thread API" "yes" "$t15_flag"
if [ "$t15_flag" != "yes" ]; then
    echo "  (debug out=$(cat "$tmpdir/t15.out" 2>/dev/null))"
fi

# -- Test 16: exit code reflects failures ----------------
echo "Test 16: exit code is non-zero when any clip failed"
if [ "$(id -u)" -ne 0 ]; then
    fail_vault="$tmpdir/vault-fail"
    mkdir -p "$fail_vault/Clippings"
    cat >"$fail_vault/Clippings/unreadable.md" <<'EOF'
---
source: https://x.com/jack/status/99
processed: true
---
# tweet from x.com/jack/status/99

## The Idea

## Source
https://x.com/jack/status/99
EOF
    chmod 000 "$fail_vault/Clippings/unreadable.md"
    node "$SCRIPT" --vault "$fail_vault" --limit 1 >"$tmpdir/t16.out" 2>&1
    t16_rc=$?
    chmod 644 "$fail_vault/Clippings/unreadable.md"
    assert "Test16: run with 1 failed clip exits 3 (documented failure code)" "3" "$t16_rc"
    if [ "$t16_rc" != "3" ]; then
        echo "  (debug out=$(cat "$tmpdir/t16.out" 2>/dev/null))"
    fi
else
    echo "  SKIP Test16 (running as root; permission bits do not deny read)"
fi

# Control: an all-skipped / zero-failure run still exits 0.
skip_vault="$tmpdir/vault-skip"
mkdir -p "$skip_vault/Clippings"
cat >"$skip_vault/Clippings/not-processed.md" <<'EOF'
---
source: https://x.com/jack/status/98
processed: false
---
# tweet from x.com/jack/status/98

## The Idea
This body already has real content, so it is not thin and is skipped regardless of processed state.

## Source
https://x.com/jack/status/98
EOF
node "$SCRIPT" --vault "$skip_vault" --limit 1 >"$tmpdir/t16b.out" 2>&1
t16b_rc=$?
assert "Test16b: zero-failure (all-skipped) run still exits 0" "0" "$t16b_rc"
if [ "$t16b_rc" != "0" ]; then
    echo "  (debug out=$(cat "$tmpdir/t16b.out" 2>/dev/null))"
fi

# -- Tests 17-21: the author's self-thread is kept ----------------------
BACKFILL="$TOOLS_DIR/x-thread-backfill.mjs"
THEO_FX="$SCRIPT_DIR/fixtures/x-thread/theo-thread.json"

mk_x_clip() {  # <dir> <file> <user> <id>
    mkdir -p "$1/Clippings"
    cat >"$1/Clippings/$2" <<EOF
---
source: https://x.com/$3/status/$4
processed: true
---
# tweet from x.com/$3/status/$4

## The Idea

## Source
https://x.com/$3/status/$4
EOF
}
line_of() { grep -n -F -- "$1" "$2" 2>/dev/null | head -1 | cut -d: -f1; }

# -- Test 17: the Theo fixture (the real endpoint answer, trimmed) -------
echo "Test 17: author self-reply is kept under ## Thread (Theo fixture)"
t17_vault="$tmpdir/vault-t17"
mk_x_clip "$t17_vault" theo.md theo 2114653423937507555
cat >"$tmpdir/t17-status.json" <<'EOF'
{ "code": 200, "tweet": { "text": "I got a set of Sonos speakers a few months ago.", "replies": 230, "author": { "screen_name": "theo" } } }
EOF
FXT_FIXTURE="$tmpdir/t17-status.json" FXT_THREAD_FIXTURE="$THEO_FX" \
    node "$SCRIPT" --vault "$t17_vault" --limit 1 >"$tmpdir/t17.out" 2>&1
t17_clip="$t17_vault/Clippings/theo.md"
t17_has=no; grep -q "Wild world we live in" "$t17_clip" 2>/dev/null && t17_has=yes
assert "Test17: reply 2114653762619068547 text is in the clip" "yes" "$t17_has"
t17_head=no; grep -q "^## Thread$" "$t17_clip" 2>/dev/null && t17_head=yes
assert "Test17: clip has a ## Thread section" "yes" "$t17_head"
t17_ok=no; grep -q "enrichment_status: ok" "$t17_clip" 2>/dev/null && ! grep -q "needs_thread:" "$t17_clip" 2>/dev/null && t17_ok=yes
assert "Test17: captured thread reads ok with no needs_thread" "yes" "$t17_ok"

# -- Test 18: author posts kept in order, other authors only when link-bearing
echo "Test 18: author posts in order; other authors only when link-bearing"
cat >"$tmpdir/t18-status.json" <<'EOF'
{ "code": 200, "tweet": { "text": "alpha one", "replies": 3, "author": { "screen_name": "alice" } } }
EOF
cat >"$tmpdir/t18-nolink.json" <<'EOF'
{ "code": 200, "thread": [
  { "id": "60", "author": { "screen_name": "alice" }, "text": "alpha one" },
  { "id": "61", "author": { "screen_name": "bob" }, "text": "bob chatter without a link" },
  { "id": "62", "author": { "screen_name": "alice" }, "text": "alpha two" }
] }
EOF
cat >"$tmpdir/t18-link.json" <<'EOF'
{ "code": 200, "thread": [
  { "id": "60", "author": { "screen_name": "alice" }, "text": "alpha one" },
  { "id": "61", "author": { "screen_name": "bob" }, "text": "the repo: https://github.com/example/repo" },
  { "id": "62", "author": { "screen_name": "alice" }, "text": "alpha two" }
] }
EOF
t18a_vault="$tmpdir/vault-t18a"; mk_x_clip "$t18a_vault" a.md alice 60
FXT_FIXTURE="$tmpdir/t18-status.json" FXT_THREAD_FIXTURE="$tmpdir/t18-nolink.json" \
    node "$SCRIPT" --vault "$t18a_vault" --limit 1 >"$tmpdir/t18a.out" 2>&1
t18a="$t18a_vault/Clippings/a.md"
l1="$(line_of "alpha one" "$t18a")"; l2="$(line_of "alpha two" "$t18a")"
t18a_order=no; [ -n "$l1" ] && [ -n "$l2" ] && [ "$l1" -lt "$l2" ] && t18a_order=yes
assert "Test18A: both author posts present, in order" "yes" "$t18a_order"
t18a_bob=no; grep -q "bob chatter" "$t18a" 2>/dev/null && t18a_bob=yes
assert "Test18A: a non-link reply by another author is NOT captured" "no" "$t18a_bob"
t18b_vault="$tmpdir/vault-t18b"; mk_x_clip "$t18b_vault" b.md alice 60
FXT_FIXTURE="$tmpdir/t18-status.json" FXT_THREAD_FIXTURE="$tmpdir/t18-link.json" \
    node "$SCRIPT" --vault "$t18b_vault" --limit 1 >"$tmpdir/t18b.out" 2>&1
t18b="$t18b_vault/Clippings/b.md"
t18b_link=no; grep -q "github.com/example/repo" "$t18b" 2>/dev/null && t18b_link=yes
assert "Test18B: a link-bearing reply by another author is captured" "yes" "$t18b_link"
t18b_label=no; grep -q "@bob" "$t18b" 2>/dev/null && grep -q "@alice" "$t18b" 2>/dev/null && t18b_label=yes
assert "Test18B: every captured post is labelled with its author handle" "yes" "$t18b_label"

# -- Test 19: a failed thread check never reads ok (fail-open regression) --
echo "Test 19: failed thread check on a tweet with replies reads partial, not ok"
cat >"$tmpdir/t19-err.json" <<'EOF'
{ "code": 500, "message": "boom" }
EOF
cat >"$tmpdir/t19-replies.json" <<'EOF'
{ "code": 200, "tweet": { "text": "a plain statement", "replies": 5, "author": { "screen_name": "jack" } } }
EOF
cat >"$tmpdir/t19-noreplies.json" <<'EOF'
{ "code": 200, "tweet": { "text": "a plain statement", "replies": 0, "author": { "screen_name": "jack" } } }
EOF
t19a_vault="$tmpdir/vault-t19a"; mk_x_clip "$t19a_vault" a.md jack 90
FXT_FIXTURE="$tmpdir/t19-replies.json" FXT_THREAD_FIXTURE="$tmpdir/t19-err.json" \
    node "$SCRIPT" --vault "$t19a_vault" --limit 1 >"$tmpdir/t19a.out" 2>&1
t19a="$t19a_vault/Clippings/a.md"
t19a_p=no; grep -q "enrichment_status: partial" "$t19a" 2>/dev/null && t19a_p=yes
assert "Test19A: replies>0 + thread error -> enrichment_status partial" "yes" "$t19a_p"
t19a_n=no; grep -q "needs_thread: true" "$t19a" 2>/dev/null && t19a_n=yes
assert "Test19A: replies>0 + thread error -> needs_thread true" "yes" "$t19a_n"
t19a_e=no; grep -q "last_error: thread_not_captured" "$t19a" 2>/dev/null && t19a_e=yes
assert "Test19A: replies>0 + thread error -> last_error thread_not_captured" "yes" "$t19a_e"
t19a_ok=no; grep -q "enrichment_status: ok" "$t19a" 2>/dev/null && t19a_ok=yes
assert "Test19A: replies>0 + thread error is never ok" "no" "$t19a_ok"
# Negative control: replies == 0 with the same erroring endpoint stays ok.
t19b_vault="$tmpdir/vault-t19b"; mk_x_clip "$t19b_vault" b.md jack 91
FXT_FIXTURE="$tmpdir/t19-noreplies.json" FXT_THREAD_FIXTURE="$tmpdir/t19-err.json" \
    node "$SCRIPT" --vault "$t19b_vault" --limit 1 >"$tmpdir/t19b.out" 2>&1
t19b="$t19b_vault/Clippings/b.md"
t19b_ok=no; grep -q "enrichment_status: ok" "$t19b" 2>/dev/null && ! grep -q "needs_thread:" "$t19b" 2>/dev/null && t19b_ok=yes
assert "Test19B (control): replies==0 + thread error stays ok, no needs_thread" "yes" "$t19b_ok"

# -- Test 20: Scrapling fallback is reached when the endpoint fails -------
echo "Test 20: Scrapling fallback (stubbed) is reached when the thread endpoint fails"
cat >"$tmpdir/t20-scrapling.json" <<'EOF'
{ "status": "ok", "posts": [
  { "id": "95", "author": { "screen_name": "jack" }, "text": "a plain statement" },
  { "id": "96", "author": { "screen_name": "jack" }, "text": "scrapling recovered continuation" }
] }
EOF
t20_vault="$tmpdir/vault-t20"; mk_x_clip "$t20_vault" a.md jack 95
FXT_FIXTURE="$tmpdir/t19-replies.json" FXT_THREAD_FIXTURE="$tmpdir/t19-err.json" FXT_SCRAPLING_FIXTURE="$tmpdir/t20-scrapling.json" \
    node "$SCRIPT" --vault "$t20_vault" --limit 1 >"$tmpdir/t20.out" 2>&1
t20="$t20_vault/Clippings/a.md"
t20_has=no; grep -q "scrapling recovered continuation" "$t20" 2>/dev/null && t20_has=yes
assert "Test20: continuation from the Scrapling fallback is in ## Thread" "yes" "$t20_has"
t20_ok=no; grep -q "enrichment_status: ok" "$t20" 2>/dev/null && t20_ok=yes
assert "Test20: a captured fallback thread reads ok" "yes" "$t20_ok"

# -- Test 21: x-thread-backfill.mjs -------------------------------------
echo "Test 21: x-thread-backfill (dry-run default, --apply, idempotent)"
bf_vault="$tmpdir/vault-bf"
bf_fx="$tmpdir/bf-fixtures"
mkdir -p "$bf_fx"
mk_x_clip "$bf_vault" theo.md theo 2114653423937507555
cp "$THEO_FX" "$bf_fx/2114653423937507555.json"
mk_x_clip "$bf_vault" single.md solo 81
# Archived clips live below Clippings/_done/<month>/: the walk must reach them.
mkdir -p "$bf_vault/Clippings/_done/2026-05"
cp "$bf_vault/Clippings/single.md" "$bf_vault/Clippings/_done/2026-05/deep-single.md"
mk_x_clip "$tmpdir/bf-deep" deep-theo.md theo 2114653423937507555
cp "$tmpdir/bf-deep/Clippings/deep-theo.md" "$bf_vault/Clippings/_done/2026-05/deep-theo.md"
cat >"$bf_fx/81.json" <<'EOF'
{ "code": 200, "thread": [ { "id": "81", "author": { "screen_name": "solo" }, "text": "only post" } ] }
EOF
mk_x_clip "$bf_vault" broken.md gone 82
cat >"$bf_vault/Clippings/flagged.md" <<'EOF'
---
source: https://x.com/theo/status/2114653423937507555
processed: true
enriched_at: 2026-06-01
enrichment_status: partial
needs_thread: true
last_error: thread_not_captured
---
## The Idea
post one only

## Source
https://x.com/theo/status/2114653423937507555
EOF
cat >"$bf_vault/Clippings/notx.md" <<'EOF'
---
source: https://example.com/article
processed: true
---
## The Idea
not an x clip
EOF
vault_sum() { (cd "$1" && find . -type f | sort | xargs sha256sum | sha256sum | cut -d' ' -f1); }
sum0="$(vault_sum "$bf_vault")"
notx0="$(sha256sum "$bf_vault/Clippings/notx.md" | cut -d' ' -f1)"
FXT_THREAD_FIXTURE_DIR="$bf_fx" node "$BACKFILL" --vault "$bf_vault" >"$tmpdir/t21-dry.out" 2>&1
t21_rc=$?
assert "Test21: dry-run exits 0" "0" "$t21_rc"
assert "Test21: dry-run writes nothing (vault checksum unchanged)" "$sum0" "$(vault_sum "$bf_vault")"
assert "Test21: dry-run summary carries the four counts" \
    "summary: seen=6 adds-text=3 no-new-text=2 fetch-failed=1" \
    "$(grep '^summary:' "$tmpdir/t21-dry.out")"
t21_per=no; grep -q "theo.md.*adds-text" "$tmpdir/t21-dry.out" && grep -q "broken.md.*fetch-failed" "$tmpdir/t21-dry.out" && grep -q "single.md.*no-new-text" "$tmpdir/t21-dry.out" && t21_per=yes
assert "Test21: dry-run prints a verdict per clip" "yes" "$t21_per"
FXT_THREAD_FIXTURE_DIR="$bf_fx" node "$BACKFILL" --vault "$bf_vault" --apply >"$tmpdir/t21-apply.out" 2>&1
t21_add=no; grep -q "Wild world we live in" "$bf_vault/Clippings/theo.md" 2>/dev/null && t21_add=yes
assert "Test21: --apply adds the thread section" "yes" "$t21_add"
t21_fl=no; f="$bf_vault/Clippings/flagged.md"
grep -q "Wild world we live in" "$f" && grep -q "enrichment_status: ok" "$f" && ! grep -q "needs_thread:" "$f" && ! grep -q "last_error: thread_not_captured" "$f" && grep -q "enriched_at: 2026-06-01" "$f" && t21_fl=yes
assert "Test21: --apply clears the flag a captured thread resolves, enriched_at untouched" "yes" "$t21_fl"
assert "Test21: a clip that is not an X clip is untouched" "$notx0" "$(sha256sum "$bf_vault/Clippings/notx.md" | cut -d' ' -f1)"
sum1="$(vault_sum "$bf_vault")"
FXT_THREAD_FIXTURE_DIR="$bf_fx" node "$BACKFILL" --vault "$bf_vault" --apply >"$tmpdir/t21-apply2.out" 2>&1
assert "Test21: a second --apply is a byte-identical no-op" "$sum1" "$(vault_sum "$bf_vault")"
assert "Test21: second run reports nothing left to add" \
    "summary: seen=6 adds-text=0 no-new-text=5 fetch-failed=1" \
    "$(grep '^summary:' "$tmpdir/t21-apply2.out")"
FXT_THREAD_FIXTURE_DIR="$bf_fx" node "$BACKFILL" --vault "$bf_vault" --limit 1 >"$tmpdir/t21-limit.out" 2>&1
assert "Test21: --limit stops after N clips" \
    "summary: seen=1 adds-text=0 no-new-text=1 fetch-failed=0" \
    "$(grep '^summary:' "$tmpdir/t21-limit.out")"
FXT_THREAD_FIXTURE_DIR="$bf_fx" node "$BACKFILL" --vault "$bf_vault" --resume-after "Clippings/_done/2026-05/deep-theo.md" >"$tmpdir/t21-resume.out" 2>&1
assert "Test21: --resume-after skips every clip up to that path" \
    "summary: seen=4 adds-text=0 no-new-text=3 fetch-failed=1" \
    "$(grep '^summary:' "$tmpdir/t21-resume.out")"
t21_help="$(node "$BACKFILL" --help 2>&1)"
t21_help_ok=no; case "$t21_help" in *"25 minutes"*) t21_help_ok=yes ;; esac
assert "Test21: --help names the rate and the 25 minute estimate" "yes" "$t21_help_ok"

# -- Test 22: what clears a needs_thread flag, and what a rewrite may drop --
echo "Test 22: only the author's own continuation clears needs_thread; a thread is never shrunk"
cat >"$tmpdir/t22-status.json" <<'EOF'
{ "code": 200, "tweet": { "text": "deep dive\n\n1/3 the first point", "replies": 3, "author": { "screen_name": "alice" } } }
EOF
cat >"$tmpdir/t22-linkonly.json" <<'EOF'
{ "code": 200, "thread": [
  { "id": "100", "author": { "screen_name": "alice" }, "text": "deep dive 1/3 the first point" },
  { "id": "101", "author": { "screen_name": "bob" }, "text": "code is here https://github.com/example/repo" }
] }
EOF
t22a_vault="$tmpdir/vault-t22a"; mk_x_clip "$t22a_vault" a.md alice 100
FXT_FIXTURE="$tmpdir/t22-status.json" FXT_THREAD_FIXTURE="$tmpdir/t22-linkonly.json" \
    node "$SCRIPT" --vault "$t22a_vault" --limit 1 >"$tmpdir/t22a.out" 2>&1
t22a="$t22a_vault/Clippings/a.md"
t22a_flag=no; grep -q "needs_thread: true" "$t22a" 2>/dev/null && grep -q "enrichment_status: partial" "$t22a" 2>/dev/null && t22a_flag=yes
assert "Test22A: a link reply by another author does not clear a heuristic needs_thread" "yes" "$t22a_flag"
t22a_link=no; grep -q "github.com/example/repo" "$t22a" 2>/dev/null && t22a_link=yes
assert "Test22A: the link reply is still kept under ## Thread" "yes" "$t22a_link"
cat >"$tmpdir/t22-scrapling-only-post1.json" <<'EOF'
{ "status": "ok", "posts": [ { "id": "97", "author": { "screen_name": "jack" }, "text": "a plain statement" } ] }
EOF
t22b_vault="$tmpdir/vault-t22b"; mk_x_clip "$t22b_vault" b.md jack 97
FXT_FIXTURE="$tmpdir/t19-replies.json" FXT_THREAD_FIXTURE="$tmpdir/t19-err.json" FXT_SCRAPLING_FIXTURE="$tmpdir/t22-scrapling-only-post1.json" \
    node "$SCRIPT" --vault "$t22b_vault" --limit 1 >"$tmpdir/t22b.out" 2>&1
t22b="$t22b_vault/Clippings/b.md"
t22b_flag=no; grep -q "needs_thread: true" "$t22b" 2>/dev/null && grep -q "enrichment_status: partial" "$t22b" 2>/dev/null && t22b_flag=yes
assert "Test22B: a Scrapling page showing only post 1 on a tweet with replies reads partial, not ok" "yes" "$t22b_flag"
# A shorter answer never shrinks a thread the clip already holds.
t22c_vault="$tmpdir/vault-t22c"; t22c_fx="$tmpdir/t22c-fixtures"; mkdir -p "$t22c_fx"
mk_x_clip "$t22c_vault" theo.md theo 2114653423937507555
cp "$THEO_FX" "$t22c_fx/2114653423937507555.json"
FXT_THREAD_FIXTURE_DIR="$t22c_fx" node "$BACKFILL" --vault "$t22c_vault" --apply >"$tmpdir/t22c1.out" 2>&1
t22c_sum="$(vault_sum "$t22c_vault")"
cat >"$t22c_fx/2114653423937507555.json" <<'EOF'
{ "code": 200, "thread": [
  { "id": "2114653423937507555", "author": { "screen_name": "theo" }, "text": "the first post" },
  { "id": "999", "author": { "screen_name": "bob" }, "text": "see https://example.com/x" }
] }
EOF
FXT_THREAD_FIXTURE_DIR="$t22c_fx" node "$BACKFILL" --vault "$t22c_vault" --apply >"$tmpdir/t22c2.out" 2>&1
assert "Test22C: a shorter thread answer leaves the fuller section in place" "$t22c_sum" "$(vault_sum "$t22c_vault")"
node "$BACKFILL" --vault "$t22c_vault" --limit abc >"$tmpdir/t22d.out" 2>&1
assert "Test22D: --limit with a non-number is a usage error (exit 1)" "1" "$?"
mkdir -p "$tmpdir/vault-with-no-clippings"
node "$BACKFILL" --vault "$tmpdir/vault-with-no-clippings" >"$tmpdir/t22e.out" 2>&1
assert "Test22E: a vault with no Clippings/ is an error (exit 1)" "1" "$?"

# -- Test 23: reflag leaves a captured thread alone; a rewrite never loses text --
echo "Test 23: --reflag skips a clip that holds ## Thread; a thread rewrite keeps the fuller text"
t23a_vault="$tmpdir/vault-t23a"; mkdir -p "$t23a_vault/Clippings"
cat >"$t23a_vault/Clippings/captured.md" <<'EOF'
---
source: https://x.com/claudeai/status/50
processed: true
enriched_at: 2026-06-01
enrichment_source: fxtwitter
enrichment_status: ok
---
## The Idea
post one

## Thread
<!-- fxtwitter thread -->

**@claudeai** (author) https://x.com/claudeai/status/51

> the second post, already captured

## Source
https://x.com/claudeai/status/50
EOF
t23a_sum="$(sha256sum "$t23a_vault/Clippings/captured.md" | cut -d' ' -f1)"
FXT_FIXTURE="$tmpdir/fixture-reflag-unmarked-status.json" FXT_THREAD_FIXTURE="$tmpdir/fixture-thread-multi.json" \
    node "$SCRIPT" --vault "$t23a_vault" --reflag --limit 1 >"$tmpdir/t23a.out" 2>&1
assert "Test23A: --reflag leaves a clip that already holds ## Thread byte-identical" "$t23a_sum" "$(sha256sum "$t23a_vault/Clippings/captured.md" | cut -d' ' -f1)"

t23_vault="$tmpdir/vault-t23"; t23_fx="$tmpdir/t23-fixtures"; mkdir -p "$t23_fx"
mk_x_clip "$t23_vault" a.md alice 100
cat >"$t23_fx/100.json" <<'EOF'
{ "code": 200, "thread": [
  { "id": "100", "author": { "screen_name": "alice" }, "text": "first post" },
  { "id": "101", "author": { "screen_name": "alice" }, "text": "second post with a long explanation of the point, see https://x.com/zed/status/555 for context" }
] }
EOF
FXT_THREAD_FIXTURE_DIR="$t23_fx" node "$BACKFILL" --vault "$t23_vault" --apply >"$tmpdir/t23-1.out" 2>&1
t23_sum="$(vault_sum "$t23_vault")"
cat >"$t23_fx/100.json" <<'EOF'
{ "code": 200, "thread": [
  { "id": "100", "author": { "screen_name": "alice" }, "text": "first post" },
  { "id": "101", "author": { "screen_name": "alice" }, "text": "second post" }
] }
EOF
FXT_THREAD_FIXTURE_DIR="$t23_fx" node "$BACKFILL" --vault "$t23_vault" --apply >"$tmpdir/t23-2.out" 2>&1
assert "Test23B: the same posts with truncated text leave the fuller section in place" "$t23_sum" "$(vault_sum "$t23_vault")"
cat >"$t23_fx/100.json" <<'EOF'
{ "code": 200, "thread": [
  { "id": "100", "author": { "screen_name": "alice" }, "text": "first post" },
  { "id": "101", "author": { "screen_name": "alice" }, "text": "second post with a long explanation of the point, see https://x.com/zed/status/555 for context" },
  { "id": "102", "author": { "screen_name": "alice" }, "text": "third post that arrived later" }
] }
EOF
FXT_THREAD_FIXTURE_DIR="$t23_fx" node "$BACKFILL" --vault "$t23_vault" --apply >"$tmpdir/t23-3.out" 2>&1
t23c=no; grep -q "third post that arrived later" "$t23_vault/Clippings/a.md" 2>/dev/null && t23c=yes
assert "Test23C: a status link inside a kept post's text does not block a later, fuller thread" "yes" "$t23c"
node "$BACKFILL" --vault "$t23_vault" --resume-after >"$tmpdir/t23d.out" 2>&1
assert "Test23D: --resume-after without a value is a usage error (exit 1)" "1" "$?"
mk_x_clip "$t23_vault" f.md alice 110
cat >"$t23_fx/110.json" <<'EOF'
{ "code": 200, "thread": [
  { "id": "110", "author": { "screen_name": "alice" }, "text": "main post" },
  { "id": "111", "author": { "screen_name": "alice" }, "text": "continuation of the point" },
  { "id": "112", "author": { "screen_name": "bob" }, "text": "hey @carol nice one", "raw_text": { "facets": [ { "type": "mention", "original": "@carol", "replacement": "@carol" } ] } },
  { "id": "113", "author": { "screen_name": "dave" }, "text": "docs are here", "raw_text": { "facets": [ { "type": "url", "original": "t.co/x", "replacement": "https://example.com/docs" } ] } }
] }
EOF
FXT_THREAD_FIXTURE_DIR="$t23_fx" node "$BACKFILL" --vault "$t23_vault" --apply >"$tmpdir/t23e.out" 2>&1
t23e=no; f="$t23_vault/Clippings/f.md"
grep -q "docs are here" "$f" && ! grep -q "hey @carol nice one" "$f" && t23e=yes
assert "Test23E: a reply is kept for a url facet, not for a mention facet" "yes" "$t23e"

# -- Summary -----------------------------------------------------------
total=$((pass + fail))
echo ""
echo "Results: $pass / $total passed, $fail failed."
[ "$fail" -eq 0 ]
