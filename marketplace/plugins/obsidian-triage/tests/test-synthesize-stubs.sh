#!/usr/bin/env bash
# Fixture-gated acceptance test for SYNTHESIZE stub mode — core +
# dedup gate + generation-ledger + divergence guard.
#
# Contract (handover HARD GUARDRAIL #2): fire a stub only when >=2 _evidence/
# clips share a concept/tag/author AFTER (a) canonical-URL dedup of
# contributors AND (b) >=2 distinct domains/authors.
#
# Fixture F:
#   - 2 same-URL dups of one URL (share tag rag-caching)  -> 0 stubs
#   - 2 distinct-author clips on concept C (tag context-windows) -> exactly 1 stub
#
# Asserts: promoted_to: stamped on both contributors; ledger entry written;
# divergence guard refuses to revert a touched page but reverts an untouched one.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$PLUGIN_DIR/tools/synthesize-stubs.mjs"

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

# ── Build a temp vault with fixture F ────────────────────────────────────────
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
EV="$tmp/Clippings/_evidence"
mkdir -p "$EV/_rejected" "$tmp/30-Resources/Concepts" "$tmp/_Templates"

# Concept-C pair: 2 distinct authors, 2 distinct domains, tag context-windows.
cat > "$EV/alice-cw.md" <<'EOF'
---
type: article
source: "https://example.com/cw"
author: Alice Researcher
processed: true
evidence_kind:
  - concepts
tags:
  - context-windows
  - concepts
---
Alice on context windows.
EOF

cat > "$EV/bob-cw.md" <<'EOF'
---
type: article
source: "https://blog.example.org/cw2"
author: Bob Writer
processed: true
evidence_kind:
  - concepts
tags:
  - context-windows
  - concepts
---
Bob on context windows.
EOF

# Same-URL dup pair: same canonical URL after dropping ?source=, tag rag-caching.
cat > "$EV/dup-a.md" <<'EOF'
---
type: article
source: "https://medium.com/rag?source=feed"
author: Carol Author
processed: true
evidence_kind:
  - concepts
tags:
  - rag-caching
  - concepts
---
RAG caching, clipped once.
EOF

cat > "$EV/dup-b.md" <<'EOF'
---
type: article
source: "https://medium.com/rag"
author: Carol Author
processed: true
evidence_kind:
  - concepts
tags:
  - rag-caching
  - concepts
---
RAG caching, clipped twice (same article).
EOF

# A rejected clip that ALSO carries context-windows — must be excluded entirely.
cat > "$EV/_rejected/junk-cw.md" <<'EOF'
---
type: article
source: "https://spam.example.net/x"
author: Spammer
processed: true
tags:
  - context-windows
---
Rejected — must not count toward the gate.
EOF

LEDGER="$tmp/.synthesize-stubs.ledger.jsonl"

# ── 1. APPLY — create stubs ──────────────────────────────────────────────────
echo "Test group 1: apply"
out1="$(node "$TOOL" "$tmp" --apply 2>&1)"
printf '%s
' "$out1"

stub="$tmp/30-Resources/Concepts/Context Windows.md"

if [ -f "$stub" ]; then f=yes; else f=no; fi
assert "context-windows stub created" "yes" "$f"

# Count stub pages under Concepts (must be exactly 1 — dups produce none)
nstubs="$(find "$tmp/30-Resources/Concepts" -type f -name '*.md' | wc -l | tr -d ' ')"
assert "exactly 1 stub page created (dups produce 0)" "1" "$nstubs"

if grep -qF 'status: stub' "$stub" 2>/dev/null; then f=yes; else f=no; fi
assert "stub page has status: stub" "yes" "$f"

# Evidence section wikilinks both contributors
if grep -qF '[[Clippings/_evidence/alice-cw]]' "$stub" && grep -qF '[[Clippings/_evidence/bob-cw]]' "$stub"; then f=yes; else f=no; fi
assert "stub Evidence wikilinks both contributors" "yes" "$f"

# promoted_to stamped on both contributors
if grep -qF 'promoted_to:' "$EV/alice-cw.md" && grep -qF 'promoted_to:' "$EV/bob-cw.md"; then f=yes; else f=no; fi
assert "promoted_to stamped on both contributors" "yes" "$f"

# dup contributors NOT stamped (no stub fired for them)
if grep -qF 'promoted_to:' "$EV/dup-a.md"; then f=stamped; else f=clean; fi
assert "dup clip NOT stamped (collapsed to 1, no stub)" "clean" "$f"

# ledger written with an entry for the stub
if [ -f "$LEDGER" ] && grep -qF 'Context Windows' "$LEDGER"; then f=yes; else f=no; fi
assert "generation-ledger written with stub entry" "yes" "$f"

if grep -qF 'subject_sha256' "$LEDGER" 2>/dev/null; then f=yes; else f=no; fi
assert "ledger entry records subject_sha256 (divergence baseline)" "yes" "$f"

# Re-run apply is idempotent: no second stub, no duplicate ledger create-entry
node "$TOOL" "$tmp" --apply >/dev/null 2>&1
nstubs2="$(find "$tmp/30-Resources/Concepts" -type f -name '*.md' | wc -l | tr -d ' ')"
assert "re-apply is idempotent (still 1 stub)" "1" "$nstubs2"

# ── 2. REVERT divergence guard — UNTOUCHED page is reverted ───────────────────
echo "Test group 2: revert untouched"
out2="$(node "$TOOL" "$tmp" --revert "$LEDGER" 2>&1)"
printf '%s
' "$out2"

if [ -f "$stub" ]; then f=present; else f=removed; fi
assert "untouched stub IS reverted (page removed)" "removed" "$f"

if grep -qF 'promoted_to:' "$EV/alice-cw.md"; then f=stamped; else f=cleared; fi
assert "promoted_to cleared on contributor after revert" "cleared" "$f"

# ── 3. REVERT divergence guard — TOUCHED page is refused ──────────────────────
echo "Test group 3: revert touched (divergence refusal)"
# Re-create the stub
node "$TOOL" "$tmp" --apply >/dev/null 2>&1
[ -f "$stub" ] || { echo "  FAIL  re-create stub for divergence test"; fail=$((fail+1)); }
# Operator edits the page
printf '\n## Operator note\nHand-edited.\n' >> "$stub"

out3="$(node "$TOOL" "$tmp" --revert "$LEDGER" 2>&1)"
printf '%s
' "$out3"

if [ -f "$stub" ]; then f=present; else f=removed; fi
assert "TOUCHED stub is NOT reverted (divergence guard refuses)" "present" "$f"

if grep -qiE 'diverg|refus|skip' <<<"$out3"; then f=yes; else f=no; fi
assert "revert reports divergence refusal" "yes" "$f"

# ── 4. Subject-name collision: two distinct tags title-case to one page ───────
# Distinct tags `local-first` and `local first` both resolve to "Local First".
# Each group fires independently (>=2 clips, distinct authors). The merge pass
# must yield ONE page listing ALL contributors, ONE ledger entry, and revert
# must un-stamp every contributor (no stranded promoted_to).
echo "Test group 4: subject-name collision merge"
tmp4="$(mktemp -d)"
trap 'rm -rf "$tmp" "$tmp4"' EXIT
EV4="$tmp4/Clippings/_evidence"
mkdir -p "$EV4" "$tmp4/30-Resources/Concepts"
mkclip() { # $1=file $2=author $3=url $4=tag
  cat > "$EV4/$1" <<EOF
---
type: article
source: "$3"
author: $2
processed: true
evidence_kind:
  - concepts
tags:
  - $4
---
clip $1
EOF
}
mkclip lf-a.md "Dan Author"   "https://da.com/lf"  "local-first"
mkclip lf-b.md "Eve Author"   "https://ev.com/lf"  "local-first"
mkclip lf-c.md "Frank Author" "https://fr.com/lf"  "local first"
mkclip lf-d.md "Grace Author" "https://gr.com/lf"  "local first"

LEDGER4="$tmp4/.synthesize-stubs.ledger.jsonl"
out4="$(node "$TOOL" "$tmp4" --apply 2>&1)"; printf '%s
' "$out4"

npages="$(find "$tmp4/30-Resources/Concepts" -type f -name '*.md' | wc -l | tr -d ' ')"
assert "collision yields exactly 1 page" "1" "$npages"

nentries="$(grep -cF 'Local First.md' "$LEDGER4" 2>/dev/null || echo 0)"
assert "exactly 1 ledger entry for the merged page" "1" "$nentries"

nstamp="$(grep -lF 'promoted_to:' "$EV4"/lf-*.md 2>/dev/null | wc -l | tr -d ' ')"
assert "all 4 contributors stamped" "4" "$nstamp"

node "$TOOL" "$tmp4" --revert "$LEDGER4" >/dev/null 2>&1
nstamp_after="$(grep -lF 'promoted_to:' "$EV4"/lf-*.md 2>/dev/null | wc -l | tr -d ' ')"
assert "no stranded stamp after revert (all 4 cleared)" "0" "$nstamp_after"

echo "Test group 5: singular and plural are one subject"
tmp5="$(mktemp -d -t synth5.XXXXXX)" || exit 1
trap 'rm -rf "$tmp" "$tmp4" "$tmp5"' EXIT
EV5="$tmp5/Clippings/_evidence"
mkdir -p "$EV5" "$tmp5/30-Resources/Concepts"
pages_like() {
  local dir="$1" prefix="$2" f out=""
  for f in "$dir"/"$prefix"*.md; do [ -e "$f" ] && out="$out${out:+ }$(basename "$f")"; done
  printf '%s' "$out"
}
mkclip5() {
  local dir="$1" file="$2" author="$3" url="$4" tag="$5"
  cat > "$dir/$file" <<EOF
---
type: article
source: "$url"
author: $author
processed: true
evidence_kind:
  - concepts
tags:
  - $tag
---
clip $file
EOF
}
mkclip5 "$EV5" wf-a.md "Ann Author"  "https://aa.com/wf"   "workflow"
mkclip5 "$EV5" wf-b.md "Ben Author"  "https://bb.com/wf"   "workflow"
mkclip5 "$EV5" wf-c.md "Cy Author"   "https://cc.com/wf"   "workflows"
mkclip5 "$EV5" wf-d.md "Di Author"   "https://dd.com/wf"   "workflows"
mkclip5 "$EV5" ag-a.md "Eli Author"  "https://ee.com/ag"   "agent"
mkclip5 "$EV5" ag-b.md "Flo Author"  "https://ff.com/ag"   "agents"
mkclip5 "$EV5" ag-c.md "Gus Author"  "https://gg.com/ag"   "agents"
mkclip5 "$EV5" wl-a.md "Hal Author"  "https://hh.com/wl"   "workload"
mkclip5 "$EV5" wl-b.md "Ian Author"  "https://ii.com/wl"   "workload"
mkclip5 "$EV5" an-a.md "Jo Author"   "https://jj.com/an"   "analysis"
mkclip5 "$EV5" an-b.md "Kim Author"  "https://kk.com/an"   "analysis"
mkclip5 "$EV5" bi-a.md "Pat Author"  "https://pp.com/bi"   "bias"
mkclip5 "$EV5" bi-b.md "Quin Author" "https://qq.com/bi"   "biases"
mkclip5 "$EV5" bi-c.md "Rae Author"  "https://rr.com/bi"   "biases"
mkclip5 "$EV5" ln-a.md "Sal Author"  "https://ss.com/ln"   "lens"
mkclip5 "$EV5" ln-b.md "Tom Author"  "https://tt.com/ln"   "lenses"
mkclip5 "$EV5" st-a.md "Uma Author"  "https://uu.com/st"   "status"
mkclip5 "$EV5" st-b.md "Val Author"  "https://vv.com/st"   "statuses"
mkclip5 "$EV5" lb-a.md "Lee Author"  "https://ll.com/lb"   "dependency"
mkclip5 "$EV5" lb-b.md "Max Author"  "https://mm.com/lb"   "dependencies"

LEDGER5="$tmp5/.synthesize-stubs.ledger.jsonl"
out5="$(node "$TOOL" "$tmp5" --apply 2>&1)"; printf '%s
' "$out5"
C5="$tmp5/30-Resources/Concepts"

assert "workflow + workflows: one page named for the singular on a tie" "Workflow.md" "$(pages_like "$C5" Workflow)"
nwf="$(grep -c '^- \[\[Clippings/_evidence/wf-' "$C5/Workflow.md" 2>/dev/null || echo 0)"
assert "the one workflow page lists all four contributors" "4" "$nwf"
assert "workflow + workflows: exactly one ledger entry" "1" "$(grep -cF 'Workflow.md' "$LEDGER5" 2>/dev/null || echo 0)"
assert "agent (1) + agents (2): one page named for the more common form" "Agents.md" "$(pages_like "$C5" Agent)"
assert "agent + agents converge only because the forms fold" "3" "$(grep -c '^- \[\[Clippings/_evidence/ag-' "$C5/Agents.md" 2>/dev/null || echo 0)"
assert "workload stays its own subject" "yes" "$([ -f "$C5/Workload.md" ] && echo yes || echo no)"
assert "analysis keeps its form" "yes" "$([ -f "$C5/Analysis.md" ] && echo yes || echo no)"
assert "no page named Analysi" "no" "$([ -f "$C5/Analysi.md" ] && echo yes || echo no)"
assert "dependency + dependencies: one page" "1" "$(pages_like "$C5" Dependenc | wc -w | tr -d ' ')"
assert "bias (1) + biases (2): one page, named for the more common form" "Biases.md" "$(pages_like "$C5" Bias)"
assert "the bias page lists all three contributors" "3" "$(grep -c '^- \[\[Clippings/_evidence/bi-' "$C5/Biases.md" 2>/dev/null || echo 0)"
assert "lens + lenses: one page, the shorter on a tie" "Lens.md" "$(pages_like "$C5" Lens)"
assert "status + statuses: one page, the shorter on a tie" "Status.md" "$(pages_like "$C5" Status)"
assert "eight subjects in all" "8" "$(find "$C5" -type f -name '*.md' | wc -l | tr -d ' ')"

tmp5b="$(mktemp -d -t synth5b.XXXXXX)" || exit 1
trap 'rm -rf "$tmp" "$tmp4" "$tmp5" "$tmp5b"' EXIT
EV5B="$tmp5b/Clippings/_evidence"
mkdir -p "$EV5B" "$tmp5b/30-Resources/Concepts"
printf -- '---\ntype: concept\ntags:\n  - concept\n---\n# Workflows\n\n## Evidence\n\n- (hand-written)\n' > "$tmp5b/30-Resources/Concepts/Workflows.md"
mkclip5 "$EV5B" e-a.md "Ann Author" "https://aa.com/e" "workflow"
mkclip5 "$EV5B" e-b.md "Ben Author" "https://bb.com/e" "workflow"
node "$TOOL" "$tmp5b" --apply >/dev/null 2>&1
assert "tag workflow densifies the existing Workflows page" "2" "$(grep -c '^- \[\[Clippings/_evidence/e-' "$tmp5b/30-Resources/Concepts/Workflows.md" 2>/dev/null || echo 0)"
assert "tag workflow adds no second page beside Workflows" "1" "$(find "$tmp5b/30-Resources/Concepts" -type f -name '*.md' | wc -l | tr -d ' ')"

echo "Test group 6: --limit bounds one apply"
tmp6="$(mktemp -d -t synth6.XXXXXX)" || exit 1
trap 'rm -rf "$tmp" "$tmp4" "$tmp5" "$tmp5b" "$tmp6"' EXIT
EV6="$tmp6/Clippings/_evidence"
mkdir -p "$EV6" "$tmp6/30-Resources/Concepts"
for t in alpha beta gamma delta; do
  mkclip5 "$EV6" "$t-1.md" "$t One" "https://$t-one.com/x" "$t"
  mkclip5 "$EV6" "$t-2.md" "$t Two" "https://$t-two.org/x" "$t"
done
LEDGER6="$tmp6/.synthesize-stubs.ledger.jsonl"
out6a="$(node "$TOOL" "$tmp6" --dry-run --limit 3 2>&1)"; printf '%s
' "$out6a"
assert "dry run with --limit 3 plans 3 pages" "3" "$(grep -c '^✓ would create' <<<"$out6a")"
assert "dry run writes nothing" "0" "$(find "$tmp6/30-Resources/Concepts" -type f | wc -l | tr -d ' ')"
out6="$(node "$TOOL" "$tmp6" --apply --limit 3 2>&1)"; printf '%s
' "$out6"
assert "--limit 3 writes exactly 3 of 4 pages" "3" "$(find "$tmp6/30-Resources/Concepts" -type f -name '*.md' | wc -l | tr -d ' ')"
assert "the summary names the limit and what is left" "synthesize-stubs.mjs: 3 created, 0 densified, 0 skipped, 1 pending (limit 3)" "$(tail -n 1 <<<"$out6")"
assert "only the written pages' clips are stamped" "6" "$(grep -lF 'promoted_to:' "$EV6"/*.md | wc -l | tr -d ' ')"
out6b="$(node "$TOOL" "$tmp6" --apply --limit 3 2>&1)"
assert "the next run writes the one left" "4" "$(find "$tmp6/30-Resources/Concepts" -type f -name '*.md' | wc -l | tr -d ' ')"
assert "and reports nothing pending" "synthesize-stubs.mjs: 1 created, 0 densified, 0 skipped, 3 unchanged, 0 pending (limit 3)" "$(tail -n 1 <<<"$out6b")"
rc6=0; node "$TOOL" "$tmp6" --apply --limit 0 >/dev/null 2>&1 || rc6=$?
assert "--limit 0 is a usage error" "1" "$rc6"
rc6=0; node "$TOOL" "$tmp6" --apply --limit many >/dev/null 2>&1 || rc6=$?
assert "--limit many is a usage error" "1" "$rc6"
node "$TOOL" "$tmp6" --revert "$LEDGER6" >/dev/null 2>&1
assert "a limited run reverts through the one ledger" "0" "$(find "$tmp6/30-Resources/Concepts" -type f | wc -l | tr -d ' ')"
assert "and leaves no stamp behind" "0" "$(grep -lF 'promoted_to:' "$EV6"/*.md | wc -l | tr -d ' ')"

echo "Test group 6b: --limit counts densifies"
tmp6b="$(mktemp -d -t synth6b.XXXXXX)" || exit 1
trap 'rm -rf "$tmp" "$tmp4" "$tmp5" "$tmp5b" "$tmp6" "$tmp6b"' EXIT
EV6B="$tmp6b/Clippings/_evidence"
C6B="$tmp6b/30-Resources/Concepts"
mkdir -p "$EV6B" "$C6B"
for t in alpha beta gamma delta; do
  title="$(printf '%s' "$t" | cut -c1 | tr '[:lower:]' '[:upper:]')$(printf '%s' "$t" | cut -c2-)"
  printf -- '---\ntype: concept\ntags:\n  - concept\n---\n# %s\n\n## Evidence\n\n- (hand-written)\n' "$title" > "$C6B/$title.md"
  mkclip5 "$EV6B" "$t-1.md" "$t One" "https://$t-one.com/x" "$t"
  mkclip5 "$EV6B" "$t-2.md" "$t Two" "https://$t-two.org/x" "$t"
done
LEDGER6B="$tmp6b/.synthesize-stubs.ledger.jsonl"
out6ba="$(node "$TOOL" "$tmp6b" --dry-run --limit 2 2>&1)"
assert "dry run with --limit 2 over 4 densifies plans 2" "2" "$(grep -c '^≈ would densify' <<<"$out6ba")"
assert "dry run changes no page" "0" "$(grep -lF 'Clippings/_evidence' "$C6B"/*.md | wc -l | tr -d ' ')"
out6bb="$(node "$TOOL" "$tmp6b" --apply --limit 2 2>&1)"
assert "--limit 2 densifies exactly 2 of 4 pages" "2" "$(grep -lF 'Clippings/_evidence' "$C6B"/*.md | wc -l | tr -d ' ')"
assert "the summary names the 2 left pending" "synthesize-stubs.mjs: 0 created, 2 densified, 0 skipped, 2 pending (limit 2)" "$(tail -n 1 <<<"$out6bb")"
assert "only the densified pages' clips are stamped" "4" "$(grep -lF 'promoted_to:' "$EV6B"/*.md | wc -l | tr -d ' ')"
out6bc="$(node "$TOOL" "$tmp6b" --apply --limit 2 2>&1)"
assert "the next run densifies the 2 left" "4" "$(grep -lF 'Clippings/_evidence' "$C6B"/*.md | wc -l | tr -d ' ')"
assert "and reports the first 2 as unchanged" "synthesize-stubs.mjs: 0 created, 2 densified, 0 skipped, 2 unchanged, 0 pending (limit 2)" "$(tail -n 1 <<<"$out6bc")"
node "$TOOL" "$tmp6b" --revert "$LEDGER6B" >/dev/null 2>&1
assert "revert takes every appended block back out" "0" "$(grep -lF 'Clippings/_evidence' "$C6B"/*.md | wc -l | tr -d ' ')"
assert "and keeps the hand-written line" "4" "$(grep -lF '(hand-written)' "$C6B"/*.md | wc -l | tr -d ' ')"

echo "Test group 7: a subject path that is a link is refused, never written through"
tmp7="$(mktemp -d -t synth7.XXXXXX)" || exit 1
trap 'rm -rf "$tmp" "$tmp4" "$tmp5" "$tmp5b" "$tmp6" "$tmp6b" "$tmp7"' EXIT
EV7="$tmp7/Clippings/_evidence"
C7="$tmp7/30-Resources/Concepts"
mkdir -p "$EV7" "$C7" "$tmp7/outside"
printf 'a note of the operator that is not a subject page\n' > "$tmp7/outside/original.md"
cp "$tmp7/outside/original.md" "$tmp7/original.copy"
ln -s "$tmp7/outside/original.md" "$C7/Local First.md"
ln -s "$tmp7/outside/never-created.md" "$C7/Dangling Topic.md"
for t in local-first dangling-topic clean-topic; do
  mkclip5 "$EV7" "$t-1.md" "$t One" "https://$t-one.com/x" "$t"
  mkclip5 "$EV7" "$t-2.md" "$t Two" "https://$t-two.org/x" "$t"
done
LEDGER7="$tmp7/.synthesize-stubs.ledger.jsonl"
out7="$(node "$TOOL" "$tmp7" --apply 2>&1)"; printf '%s
' "$out7"
assert "the target of a linked subject page is byte for byte unchanged" "same" "$(cmp -s "$tmp7/original.copy" "$tmp7/outside/original.md" && echo same || echo changed)"
assert "the link is still a link" "yes" "$([ -L "$C7/Local First.md" ] && echo yes || echo no)"
assert "a dangling link creates nothing at its target" "no" "$([ -e "$tmp7/outside/never-created.md" ] && echo yes || echo no)"
assert "each refused page prints its reason" "2" "$(grep -c 'refused: an existing symbolic link' <<<"$out7")"
assert "the summary counts the refusals" "synthesize-stubs.mjs: 1 created, 0 densified, 0 skipped, 2 refused (path taken)" "$(tail -n 1 <<<"$out7")"
assert "the clips of a refused page are not stamped" "0" "$(grep -lF 'promoted_to:' "$EV7"/local-first-*.md "$EV7"/dangling-topic-*.md 2>/dev/null | wc -l | tr -d ' ')"
assert "a clean subject in the same run is still created" "yes" "$([ -f "$C7/Clean Topic.md" ] && echo yes || echo no)"
node "$TOOL" "$tmp7" --revert "$LEDGER7" >/dev/null 2>&1
assert "after revert the target is still byte for byte unchanged" "same" "$(cmp -s "$tmp7/original.copy" "$tmp7/outside/original.md" && echo same || echo changed)"
assert "after revert the link is still a link" "yes" "$([ -L "$C7/Local First.md" ] && echo yes || echo no)"
assert "and the created page is gone" "no" "$([ -e "$C7/Clean Topic.md" ] && echo yes || echo no)"

echo "Test group 8: no nested or escaping page, and an existing file is never overwritten"
tmp8="$(mktemp -d -t synth8.XXXXXX)" || exit 1
trap 'rm -rf "$tmp" "$tmp4" "$tmp5" "$tmp5b" "$tmp6" "$tmp6b" "$tmp7" "$tmp8"' EXIT
EV8="$tmp8/Clippings/_evidence"
C8="$tmp8/30-Resources/Concepts"
mkdir -p "$EV8" "$C8"
mk8() {
  local slug="$1" tag="$2"
  mkclip5 "$EV8" "$slug-1.md" "$slug One" "https://$slug-one.com/x" "$tag"
  mkclip5 "$EV8" "$slug-2.md" "$slug Two" "https://$slug-two.org/x" "$tag"
}
mk8 slash "ai/agents"
mk8 root "../../outside"
mk8 up "../sibling"
mk8 cyrillic "агенты"
mk8 folder "folder-topic"
mk8 pipe "pipe-topic"
mk8 clean "clean-topic"
printf 'the operator wrote this page by hand\n' > "$C8/Агенты.md"
cp "$C8/Агенты.md" "$tmp8/hand.copy"
mkdir "$C8/Folder Topic.md"
mkfifo "$C8/Pipe Topic.md"
out8="$(node "$TOOL" "$tmp8" --apply 2>&1)"; printf '%s
' "$out8"
assert "a tag holding a slash creates no nested page" "no" "$([ -e "$C8/Ai" ] && echo yes || echo no)"
assert "a tag holding .. writes nothing above Concepts" "no" "$([ -e "$tmp8/outside.md" ] || [ -e "$tmp8/30-Resources/sibling.md" ] && echo yes || echo no)"
assert "each of the three is skipped with its reason" "3" "$(grep -c "skipped (subject name holds '/' or '..')" <<<"$out8")"
assert "a regular file the index never lists is byte for byte unchanged" "same" "$(cmp -s "$tmp8/hand.copy" "$C8/Агенты.md" && echo same || echo changed)"
assert "and it is refused with its reason" "1" "$(grep -c 'refused: a file already sits there' <<<"$out8")"
assert "a directory at a page path is refused as a directory" "1" "$(grep -c 'refused: an existing directory sits there' <<<"$out8")"
assert "a special file at a page path is refused as one" "1" "$(grep -c 'refused: an existing special file sits there' <<<"$out8")"
assert "the summary counts the skips and the refusals" "synthesize-stubs.mjs: 1 created, 0 densified, 3 skipped, 3 refused (path taken)" "$(tail -n 1 <<<"$out8")"
assert "no clip of a skipped or refused subject is stamped" "0" "$(grep -lF 'promoted_to:' "$EV8"/slash-*.md "$EV8"/root-*.md "$EV8"/up-*.md "$EV8"/cyrillic-*.md "$EV8"/folder-*.md "$EV8"/pipe-*.md 2>/dev/null | wc -l | tr -d ' ')"
assert "the one clean subject is still created" "yes" "$([ -f "$C8/Clean Topic.md" ] && echo yes || echo no)"
mkdir -p "$C8/Ai"
printf 'the operator rewrote this page by hand\n' > "$C8/Ai/agents.md"
cp "$C8/Ai/agents.md" "$tmp8/edit.copy"
node "$TOOL" "$tmp8" --apply >/dev/null 2>&1
assert "a hand edit under a slash tag survives the next night" "same" "$(cmp -s "$tmp8/edit.copy" "$C8/Ai/agents.md" && echo same || echo changed)"
assert "and the hand-written file is still unchanged" "same" "$(cmp -s "$tmp8/hand.copy" "$C8/Агенты.md" && echo same || echo changed)"

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "test-synthesize-stubs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
