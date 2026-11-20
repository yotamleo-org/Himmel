#!/usr/bin/env bash
set -euo pipefail
export HARVEST_SCRAPE_DENY=all  # the default run fetches thin articles; this suite stays offline
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../tools/lib/clip-lookup.mjs"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
LIBURL="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$lib")"
# The harvest runbook's thinness decision must come from the shared predicate.
cat > "$tmp/h.mjs" <<'JS'
const { isThinClipBody } = await import(process.env.LIB);
const NL = "\n";
const skel = NL + "## Core Argument" + NL + "*(claim?)*" + NL + "## Key Evidence" + NL + "- ";
if (isThinClipBody(skel,"research")!==true){console.error("FAIL skeleton");process.exit(1);}
const real = NL + "## Summary" + NL + "Real multi-sentence summary of the article body.";
if (isThinClipBody(real,"research")!==false){console.error("FAIL real");process.exit(1);}
console.log("OK harvest thinness decision");
JS
LIB="$LIBURL" node "$tmp/h.mjs"
# Triage's own URL-only `## Summary` is not source text: an article carrying only
# that line (and the Source footer + triage promotion block) stays thin, while a
# real summary, or real text in another section next to it, stays rich.
cat > "$tmp/urlonly.mjs" <<'JS'
const { isThinClipBody } = await import(process.env.LIB);
const NL = "\n";
const MARK = "Inferred from the source URL only — re-read the source before promoting.";
const only = NL + "## Summary" + NL + MARK + " Clip captured no body; awaiting thin-body enrichment." + NL + NL
  + "## Source" + NL + "[https://example.com/docs/guide](https://example.com/docs/guide)" + NL + NL
  + "## Promotion candidate" + NL + "- **Suggested target:** `30-Resources/Tech/`" + NL;
const src = "https://example.com/docs/guide";
if (isThinClipBody(only, "article", src) !== true) { console.error("FAIL url-only summary reads rich (article)"); process.exit(1); }
if (isThinClipBody(only, "research", src) !== true) { console.error("FAIL url-only summary reads rich (research)"); process.exit(1); }
const realSummary = NL + "## Summary" + NL + "A real summary written from the page text, naming its claims and numbers." + NL;
if (isThinClipBody(realSummary, "article", src) !== false) { console.error("FAIL real summary reads thin"); process.exit(1); }
const withHighlights = only.replace("## Source", "## Highlights" + NL + "Quoted passage from the page that the clipper captured." + NL + NL + "## Source");
if (isThinClipBody(withHighlights, "article", src) !== false) { console.error("FAIL url-only summary masks real Highlights"); process.exit(1); }
const leadIn = NL + "## Summary" + NL + "X long-form article by @someone; the clipper captured no body. " + MARK + NL + NL + "## Source" + NL + "[l](" + src + ")" + NL;
if (isThinClipBody(leadIn, "article", src) !== true) { console.error("FAIL url-only summary with a lead-in reads rich"); process.exit(1); }
const otherSection = NL + "## Highlights" + NL + "Quoted passage that mentions " + MARK + " in running text." + NL;
if (isThinClipBody(otherSection, "article", src) !== false) { console.error("FAIL marker outside ## Summary treated as url-only"); process.exit(1); }
console.log("OK url-only summary is thin (clip-lookup)");
JS
LIB="$LIBURL" node "$tmp/urlonly.mjs"
# Doc-contract: the runbook must instruct partial+thin-body, and must shell out
# to the mechanical is-thin-cli (not "eyeball it").
hc="$tmp/harvest-clips.all.md"  # body plus its on-demand references
cat "$here/../commands/harvest-clips.md" "$here"/../references/harvest-clips/*.md > "$hc"
grep -qi "thin-body" "$hc" || { echo "FAIL: harvest-clips missing thin-body rule"; exit 1; }
grep -q "is-thin-cli.mjs" "$hc" || { echo "FAIL: harvest-clips not wired to is-thin-cli shim"; exit 1; }

# thin instagram clips must get ig_media_pending: true (idempotent)
# so /ig-media-enrich picks them up; other instagram wiring lives in
# harvest-clip-body-batch.py's process_clip -> persist_thin_partial.
tool="$here/../tools/harvest-clip-body-batch.py"
cat > "$tmp/ig_pending.py" <<PY
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("harvest_batch", "$tool")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.TODAY = "2026-09-14"

p = Path("$tmp/ig-thin.md")
p.write_text(
    "---\ntype: instagram\nsource: https://www.instagram.com/reel/IGTH043/\n---\nshort.\n",
    encoding="utf-8",
)
glyph, msg, _ = mod.process_clip(p, dry_run=False, firecrawl=None)
first = p.read_text(encoding="utf-8")
if glyph != "~" or "ig_media_pending: true" not in first:
    print("FAIL: thin instagram clip did not get ig_media_pending: true")
    print(first)
    sys.exit(1)

glyph2, msg2, _ = mod.process_clip(p, dry_run=False, firecrawl=None)
second = p.read_text(encoding="utf-8")
if second.count("ig_media_pending:") != 1:
    print("FAIL: second run duplicated ig_media_pending (not idempotent)")
    print(second)
    sys.exit(1)
if "ig_media_pending: true" not in second:
    print("FAIL: second run lost ig_media_pending: true")
    print(second)
    sys.exit(1)

# non-instagram thin clip must NOT get the key at all.
p2 = Path("$tmp/generic-thin.md")
p2.write_text(
    "---\ntype: article\nsource: https://example.com/post\n---\nshort.\n",
    encoding="utf-8",
)
mod.process_clip(p2, dry_run=False, firecrawl=None)
if "ig_media_pending" in p2.read_text(encoding="utf-8"):
    print("FAIL: non-instagram thin clip got ig_media_pending")
    sys.exit(1)

print("OK ig_media_pending thin-IG + idempotence + non-IG exclusion")
PY
python3 "$tmp/ig_pending.py"

# the clip scan must skip _evidence/ (the reviewed-evidence pool)
# the same way it already skips _synthesis/, _done/ and _deferred.md.
VEV="$tmp/vault-evidence"
mkdir -p "$VEV/Clippings/_evidence"
cat > "$VEV/Clippings/_evidence/leaked.md" <<'EOF'
---
type: instagram
source: https://www.instagram.com/reel/EVID043/
---
short.
EOF
before_evidence="$(cat "$VEV/Clippings/_evidence/leaked.md")"
python3 "$here/../tools/harvest-clip-body-batch.py" "$VEV" >"$tmp/evidence.out" 2>&1
after_evidence="$(cat "$VEV/Clippings/_evidence/leaked.md")"
if [ "$before_evidence" != "$after_evidence" ]; then
    echo "FAIL: _evidence/ clip was modified by the clip scan"
    diff <(echo "$before_evidence") <(echo "$after_evidence") || true
    exit 1
fi
if grep -q "EVID043" "$tmp/evidence.out"; then
    echo "FAIL: _evidence/ clip was reported as scanned"
    cat "$tmp/evidence.out"
    exit 1
fi
echo "OK _evidence/ clip untouched by clip scan"

# A: a Web-Clipper template skeleton (empty prompts, empty
# bullets, hidden triage comments, a bare Read-here link) is not a capture. It
# must be a thin-body partial, also when an older run already stamped it ok, and
# --reflag-silent-partials must mark the historical ones without touching bodies.
cat > "$tmp/silent_template.py" <<PY
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("harvest_batch", "$tool")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.TODAY = "2026-10-22"

BODY = """# Search 1.2M Agent Skills

## Core Argument
*(What is the single biggest claim this article is making?)*

## Key Evidence
-
-
-

## What I Highlighted


## What I Agree With

## What I Disagree With

## Questions This Raises
-
-

## How This Connects to My Work

## Action Items
- [ ]

## Related Notes

<!-- triage: no Related Notes candidates found; vault link graph too sparse for this topic -->
<!-- triage 2026-05-26: skillsmp.com — 1.2M agent skill search -->

## Promotion candidate
<!-- triage 2026-05-26 — do NOT auto-promote; user must explicitly accept -->
- **Suggested target:** 30-Resources/Tech/
- **Rationale:** skillsmp.com — search 1.2M agent skills; skill marketplace reference.
- **Bi-temporal anchor:** when promoted, the new note should carry a derived_from link and its own fresh date field.

## Source
[Read here](https://skillsmp.com/search)
"""
FM = 'title: "Search 1.2M Agent Skills"\nsource: "https://skillsmp.com/search"\ntype: "research"\n'
OK = 'harvested_at: 2026-05-26\nharvest_skill: clip-body\nharvest_url_canonical: "https://skillsmp.com/search"\nharvest_status: ok\n'

if not mod.is_thin_body(BODY):
    print("FAIL (A): template skeleton is not thin"); sys.exit(1)

p = Path("$tmp/tpl-fresh.md")
p.write_text("---\n" + FM + "---\n" + BODY, encoding="utf-8")
glyph, msg, _ = mod.process_clip(p, dry_run=False, firecrawl=None)
t = p.read_text(encoding="utf-8")
if glyph != "~" or "harvest_status: ok" in t or "harvest_status: partial" not in t:
    print("FAIL (A): fresh template skeleton was stamped ok:", glyph, msg); sys.exit(1)

p2 = Path("$tmp/tpl-stamped.md")
p2.write_text("---\n" + FM + OK + "---\n" + BODY, encoding="utf-8")
glyph, msg, _ = mod.process_clip(p2, dry_run=False, firecrawl=None)
t2 = p2.read_text(encoding="utf-8")
if glyph != "~" or "harvest_status: ok" in t2 or "harvest_status: partial" not in t2:
    print("FAIL (A): already-stamped-ok template skeleton was never re-checked:", glyph, msg); sys.exit(1)
if t2.split("---\n", 2)[2] != BODY:
    print("FAIL (A): re-check altered the body"); sys.exit(1)

real = "\n".join(f"Paragraph {i} with real article prose that is the capture." for i in range(12))
p3 = Path("$tmp/real-stamped.md")
p3.write_text("---\n" + FM + OK + "---\n# Real\n\n" + real + "\n", encoding="utf-8")
before = p3.read_text(encoding="utf-8")
glyph, msg, _ = mod.process_clip(p3, dry_run=False, firecrawl=None)
if glyph != "o" or p3.read_text(encoding="utf-8") != before:
    print("FAIL (A): a real harvested clip was touched:", glyph, msg); sys.exit(1)
print("OK silent-partial A: template skeleton is thin, ok-stamped one is re-checked, real clip untouched")
PY
python3 "$tmp/silent_template.py"

VR="$tmp/vault-reflag"
mkdir -p "$VR/Clippings/_done/2026-05" "$VR/Clippings/_done/2026-06"
printf -- '---\nsource: "https://skillsmp.com/search"\nharvested_at: 2026-05-26\nharvest_skill: clip-body\nharvest_status: ok\n---\n# T\n\n## Core Argument\n*(claim?)*\n\n## Key Evidence\n-\n-\n\n## Source\n[Read here](https://skillsmp.com/search)\n' > "$VR/Clippings/_done/2026-05/tpl.md"
printf -- '---\nsource: "https://www.youtube.com/watch?v=rmvDxxNubIg"\nharvested_at: 2026-06-01\nharvest_skill: youtube-scrapling\nharvest_status: ok\n---\n## Harvested content\n\n### Transcript\n\n_Transcript unavailable: transcript_empty_\n\n## Source\nx\n' > "$VR/Clippings/_done/2026-06/yt.md"
printf -- '---\nsource: "https://x.com/a/status/1"\nenriched_at: 2026-06-02\nenrichment_status: ok\nneeds_thread: true\nharvested_at: 2026-06-02\nharvest_skill: clip-body\nharvest_status: ok\n---\n## The Idea\n\n1/3 first\n\n## Source\nx\n' > "$VR/Clippings/_done/2026-06/x.md"
cp -r "$VR" "$tmp/vault-reflag-before"
dry="$(python3 "$tool" "$VR" --reflag-silent-partials --dry-run 2>&1)" || { echo "FAIL (A): --reflag-silent-partials --dry-run failed: $dry"; exit 1; }
echo "$dry" | grep -q "3 silent partial" || { echo "FAIL (A): dry-run count: $dry"; exit 1; }
diff -r "$VR" "$tmp/vault-reflag-before" >/dev/null || { echo "FAIL (A): dry-run wrote files"; exit 1; }
python3 "$tool" "$VR" --reflag-silent-partials >/dev/null 2>&1 || { echo "FAIL (A): --reflag-silent-partials failed"; exit 1; }
grep -q "harvest_status: partial" "$VR/Clippings/_done/2026-05/tpl.md" || { echo "FAIL (A): template not re-flagged"; exit 1; }
grep -q "harvest_flag: thin-body" "$VR/Clippings/_done/2026-05/tpl.md" || { echo "FAIL (A): template flag missing"; exit 1; }
grep -q "harvest_status: partial" "$VR/Clippings/_done/2026-06/yt.md" || { echo "FAIL (E): youtube transcript-unavailable not re-flagged"; exit 1; }
grep -q "enrichment_status: partial" "$VR/Clippings/_done/2026-06/x.md" || { echo "FAIL (C): needs_thread clip not re-flagged"; exit 1; }
for f in 2026-05/tpl 2026-06/yt 2026-06/x; do
    [ "$(awk 'c>=2{print} /^---$/{c++}' "$VR/Clippings/_done/$f.md")" = "$(awk 'c>=2{print} /^---$/{c++}' "$tmp/vault-reflag-before/Clippings/_done/$f.md")" ] || { echo "FAIL: reflag altered body of $f"; exit 1; }
done
python3 "$tool" "$VR" --reflag-silent-partials 2>&1 | grep -q "0 silent partial" || { echo "FAIL: reflag not idempotent"; exit 1; }
echo "OK --reflag-silent-partials: dry-run counts, marks A/C/E, bodies identical, idempotent"

VC="$tmp/vault-crlf"
mkdir -p "$VC/Clippings/_done"
printf -- '---\nsource: "https://skillsmp.com/search"\nharvested_at: 2026-05-26\nharvest_skill: clip-body\nharvest_status: ok\n---\n# T\r\n\r\n## Core Argument\r\n*(claim?)*\r\n\r\n## Source\r\n[Read here](https://skillsmp.com/search)\r\n' > "$VC/Clippings/_done/crlf.md"
cp "$VC/Clippings/_done/crlf.md" "$tmp/crlf-before.md"
python3 "$tool" "$VC" --reflag-silent-partials >"$tmp/crlf.out" 2>&1 || { echo "FAIL: CRLF reflag run failed"; cat "$tmp/crlf.out"; exit 1; }
cmp -s "$VC/Clippings/_done/crlf.md" "$tmp/crlf-before.md" || { echo "FAIL: reflag rewrote a CRLF note"; exit 1; }
grep -q "1 skipped" "$tmp/crlf.out" || { echo "FAIL: CRLF skip not reported"; cat "$tmp/crlf.out"; exit 1; }
echo "OK --reflag-silent-partials: CRLF note left byte-identical and reported skipped"

# U: triage's URL-only `## Summary` is not a capture. A clip whose only text is that
# line is a thin-body partial (never ok), also when an earlier run already stamped it
# ok; a clip with a real summary, or real text beside the marker, stays a success.
cat > "$tmp/url_only.py" <<PY
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("harvest_batch", "$tool")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.TODAY = "2026-11-20"

MARK = "Inferred from the source URL only — re-read the source before promoting."
URL = "https://example.com/docs/guide"
BODY = (
    "# article from example.com/docs/guide\n\n" + URL + "\n\n"
    "## Summary\n" + MARK + " Clip captured no body; awaiting thin-body enrichment.\n\n"
    "## Source\n[" + URL + "](" + URL + ")\n\n"
    "## Promotion candidate\n<!-- triage 2026-11-08 — do NOT auto-promote; user must explicitly accept -->\n"
    "- **Suggested target:** \`30-Resources/Tech/\`\n"
    "- **Rationale:** Tool/repo or docs reference fits Tech notes.\n"
)
FM = 'title: "article from example.com/docs/guide"\nsource: ' + URL + '\ntype: article\nprocessed: true\nsummary_basis: url-only\n'
OKM = 'harvested_at: 2026-10-11\nharvest_skill: clip-body\nharvest_url_canonical: "' + URL + '"\nharvest_status: ok\n'

if not mod.is_thin_body(BODY):
    print("FAIL (U): a URL-only summary reads as source text"); sys.exit(1)
LEAD = BODY.replace("## Summary\n" + MARK, "## Summary\nX long-form article by @someone; the clipper captured no body. " + MARK)
if not mod.is_thin_body(LEAD) or mod.is_thin_body(BODY.replace("## Source", "## Highlights\nQuoted passage that says " + MARK + " in running text, then goes on for a while.\n\n## Source")):
    print("FAIL (U): the marker rule is not scoped to ## Summary"); sys.exit(1)

p = Path("$tmp/u-fresh.md")
p.write_text("---\n" + FM + "---\n" + BODY, encoding="utf-8")
glyph, msg, _ = mod.process_clip(p, dry_run=False, firecrawl=None)
t = p.read_text(encoding="utf-8")
if glyph != "~" or "harvest_status: ok" in t or "harvest_status: partial" not in t or "harvested_at" in t:
    print("FAIL (U): a clip with no fetched text was recorded as a success:", glyph, msg); print(t); sys.exit(1)

p2 = Path("$tmp/u-stamped.md")
p2.write_text("---\n" + FM + OKM + "---\n" + BODY, encoding="utf-8")
glyph, msg, _ = mod.process_clip(p2, dry_run=False, firecrawl=None)
t2 = p2.read_text(encoding="utf-8")
if glyph != "~" or "harvest_status: ok" in t2 or "harvest_status: partial" not in t2:
    print("FAIL (U): an ok-stamped empty clip was never re-checked:", glyph, msg); sys.exit(1)
if t2.split("---\n", 2)[2] != BODY:
    print("FAIL (U): re-check altered the body"); sys.exit(1)

REAL = BODY.replace(MARK + " Clip captured no body; awaiting thin-body enrichment.", "The guide explains how to configure the tool, names its three modes and lists the flags each one accepts.")
p3 = Path("$tmp/u-real.md")
p3.write_text("---\n" + FM + OKM + "---\n" + REAL, encoding="utf-8")
before = p3.read_text(encoding="utf-8")
glyph, msg, _ = mod.process_clip(p3, dry_run=False, firecrawl=None)
if mod.is_thin_body(REAL) or glyph != "o" or p3.read_text(encoding="utf-8") != before:
    print("FAIL (U): a clip with a real summary was touched:", glyph, msg); sys.exit(1)

LONG = "\n".join(f"Captured paragraph {i} of the page, written by the clipper." for i in range(12))
p4 = Path("$tmp/u-fresh-rich.md")
p4.write_text("---\n" + FM + "---\n" + BODY.replace("## Source", "## Highlights\n" + LONG + "\n\n## Source"), encoding="utf-8")
glyph, msg, _ = mod.process_clip(p4, dry_run=False, firecrawl=None)
t4 = p4.read_text(encoding="utf-8")
if glyph != "v" or "harvest_status: ok" not in t4:
    print("FAIL (U): a clip with real text beside the marker did not end as a success:", glyph, msg); sys.exit(1)
print("OK url-only summary: partial when empty (fresh and ok-stamped), success when real text exists")

# An Instagram clip is judged by the media rule (a Transcript or Slides subsection under
# ## Crawled content is the capture), so a short enriched clip is a success, an empty
# crawl is a partial, and a clip whose media rung already ran ok is not queued for it again.
IGURL = "https://www.instagram.com/p/CCCC333/"
IGFM = 'title: "instagram"\nsource: ' + IGURL + '\ntype: instagram\nprocessed: true\nsummary_basis: url-only\n'
IGSUM = "## Summary\n" + MARK + " Instagram post.\n\n"
ig_rich = "# i\n\n" + IGURL + "\n\n" + IGSUM + "## Crawled content\n<!-- media-enriched 2026-10-10 via ig-media -->\n\nA caption.\n\n### Transcript\nSpoken words of the reel.\n\n## Source\n[l](" + IGURL + ")\n"
ig_empty = "# i\n\n" + IGURL + "\n\n" + IGSUM + "## Crawled content\n<!-- media-enriched 2026-10-10 via ig-media -->\n\n## Source\n[l](" + IGURL + ")\n"
if mod.is_thin_clip(IGURL, ig_rich) or not mod.is_thin_clip(IGURL, ig_empty):
    print("FAIL (U): the Instagram media rule is not applied"); sys.exit(1)
pr = Path("$tmp/ig-rich.md"); pr.write_text("---\n" + IGFM + "---\n" + ig_rich, encoding="utf-8")
glyph, msg, _ = mod.process_clip(pr, dry_run=False, firecrawl=None)
tr = pr.read_text(encoding="utf-8")
if glyph != "v" or "harvest_status: ok" not in tr or "ig_media_pending" in tr:
    print("FAIL (U): an enriched Instagram clip was not a plain success:", glyph, msg); print(tr); sys.exit(1)
pe = Path("$tmp/ig-empty.md"); pe.write_text("---\n" + IGFM + "---\n" + ig_empty, encoding="utf-8")
glyph, msg, _ = mod.process_clip(pe, dry_run=False, firecrawl=None)
te = pe.read_text(encoding="utf-8")
if glyph != "~" or "harvest_status: partial" not in te or "ig_media_pending: true" not in te:
    print("FAIL (U): an empty Instagram crawl was not a partial queued for the media rung:", glyph, msg); sys.exit(1)
pd = Path("$tmp/ig-done.md"); pd.write_text("---\n" + IGFM + "media_enrichment_status: ok\n---\n" + ig_empty, encoding="utf-8")
glyph, msg, _ = mod.process_clip(pd, dry_run=False, firecrawl=None)
td = pd.read_text(encoding="utf-8")
if glyph != "~" or "harvest_status: partial" not in td or "ig_media_pending" in td:
    print("FAIL (U): a clip whose media rung ran ok was queued for it again:", glyph, msg); print(td); sys.exit(1)
print("OK instagram: media rule decides thin, no second media queueing")
PY
python3 "$tmp/url_only.py"

MARKT="Inferred from the source URL only — re-read the source before promoting."

# E: a partial clip is retried wherever it sits. Run with every scrape backend denied, so
# the only visible effect is the defer counter (no network in this suite).
VE="$tmp/vault-evidence-retry"
mkdir -p "$VE/Clippings/_evidence/_rejected"
mk_partial() { # path source defer extra
    printf -- '---\ntype: article\nsource: %s\nsummary_basis: url-only\nharvest_status: partial\nharvest_flag: thin-body\nharvest_defer_count: %s\nharvest_defer_last: 2026-11-08\n%s---\n# t\n\n## Summary\n%s\n\n## Source\n[l](%s)\n' "$2" "$3" "$4" "$MARKT" "$2" > "$1"
}
mk_partial "$VE/Clippings/_evidence/art.md" "https://example.com/docs/art" 1 ""
mk_partial "$VE/Clippings/_evidence/attention.md" "https://example.com/docs/att" 5 "harvest_needs_attention: true
"
mk_partial "$VE/Clippings/_evidence/ig.md" "https://www.instagram.com/p/BBBB222/" 1 ""
mk_partial "$VE/Clippings/_evidence/x.md" "https://x.com/someone/article/1" 1 ""
mk_partial "$VE/Clippings/_evidence/_rejected/rej.md" "https://example.com/docs/rej" 1 ""
cp -r "$VE" "$tmp/vault-evidence-retry-before"
HARVEST_SCRAPE_DENY=all python3 "$tool" "$VE" --date 2026-11-21 >"$tmp/ev.out" 2>&1 || { echo "FAIL (E): run failed"; cat "$tmp/ev.out"; exit 1; }
grep -q "^harvest_defer_count: 2" "$VE/Clippings/_evidence/art.md" || { echo "FAIL (E): an _evidence/ partial was not retried"; cat "$tmp/ev.out"; exit 1; }
for f in attention ig x _rejected/rej; do
    cmp -s "$VE/Clippings/_evidence/$f.md" "$tmp/vault-evidence-retry-before/Clippings/_evidence/$f.md" || { echo "FAIL (E): _evidence/$f.md must be left alone"; exit 1; }
done
grep -q "Clippings/_evidence/art" "$VE/.harvest-pending.md" || { echo "FAIL (E): the retried partial is missing from the pending report"; exit 1; }
echo "OK _evidence/ partial retried in place; needs-attention, Instagram, X and _rejected/ left alone"

echo "HARVEST-THINNESS PASS"
