#!/usr/bin/env bash
set -euo pipefail
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
# Doc-contract: the runbook must instruct partial+thin-body, and must shell out
# to the mechanical is-thin-cli (not "eyeball it").
hc="$tmp/harvest-clips.all.md"  # HIMMEL-5513: body plus its on-demand references
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

echo "HARVEST-THINNESS PASS"
