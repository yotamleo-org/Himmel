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
HIDE_SHIM="$PLUGIN_DIR/tests/fixtures/hide-from-listing.mjs"
run_hiding() { local names="$1"; shift; HIDE_FROM_LISTING="$names" NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--import $HIDE_SHIM" node "$@"; }

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
tmp="$(mktemp -d)" || exit 1
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
tmp4="$(mktemp -d)" || exit 1
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
mk8 hidden "hidden-topic"
mk8 folder "folder-topic"
mk8 pipe "pipe-topic"
mk8 clean "clean-topic"
printf 'the operator wrote this page by hand\n' > "$C8/Hidden Topic.md"
cp "$C8/Hidden Topic.md" "$tmp8/hand.copy"
mkdir "$C8/Folder Topic.md"
mkfifo "$C8/Pipe Topic.md"
out8="$(run_hiding "Hidden Topic.md" "$TOOL" "$tmp8" --apply 2>&1)"; printf '%s
' "$out8"
assert "a tag holding a slash creates no nested page" "no" "$([ -e "$C8/Ai" ] && echo yes || echo no)"
assert "a tag holding .. writes nothing above Concepts" "no" "$([ -e "$tmp8/outside.md" ] || [ -e "$tmp8/30-Resources/sibling.md" ] && echo yes || echo no)"
assert "each of the three is skipped with its reason" "3" "$(grep -c "skipped (subject name holds '/' or '..')" <<<"$out8")"
assert "a regular file the index never lists is byte for byte unchanged" "same" "$(cmp -s "$tmp8/hand.copy" "$C8/Hidden Topic.md" && echo same || echo changed)"
assert "and it is refused with its reason" "1" "$(grep -c 'refused: a file already sits there' <<<"$out8")"
assert "a directory at a page path is refused as a directory" "1" "$(grep -c 'refused: an existing directory sits there' <<<"$out8")"
assert "a special file at a page path is refused as one" "1" "$(grep -c 'refused: an existing special file sits there' <<<"$out8")"
assert "the summary counts the skips and the refusals" "synthesize-stubs.mjs: 1 created, 0 densified, 3 skipped, 3 refused (path taken)" "$(tail -n 1 <<<"$out8")"
assert "no clip of a skipped or refused subject is stamped" "0" "$(grep -lF 'promoted_to:' "$EV8"/slash-*.md "$EV8"/root-*.md "$EV8"/up-*.md "$EV8"/hidden-*.md "$EV8"/folder-*.md "$EV8"/pipe-*.md 2>/dev/null | wc -l | tr -d ' ')"
assert "the one clean subject is still created" "yes" "$([ -f "$C8/Clean Topic.md" ] && echo yes || echo no)"
mkdir -p "$C8/Ai"
printf 'the operator rewrote this page by hand\n' > "$C8/Ai/agents.md"
cp "$C8/Ai/agents.md" "$tmp8/edit.copy"
run_hiding "Hidden Topic.md" "$TOOL" "$tmp8" --apply >/dev/null 2>&1
assert "a hand edit under a slash tag survives the next night" "same" "$(cmp -s "$tmp8/edit.copy" "$C8/Ai/agents.md" && echo same || echo changed)"
assert "and the hand-written file is still unchanged" "same" "$(cmp -s "$tmp8/hand.copy" "$C8/Hidden Topic.md" && echo same || echo changed)"

echo "Test group 9: a subject name with a quote is escaped in the clip header"
tmp9="$(mktemp -d -t synth9.XXXXXX)" || exit 1
trap 'rm -rf "$tmp" "$tmp4" "$tmp5" "$tmp5b" "$tmp6" "$tmp6b" "$tmp7" "$tmp8" "$tmp9"' EXIT
EV9="$tmp9/Clippings/_evidence"
C9="$tmp9/30-Resources/Concepts"
mkdir -p "$EV9" "$C9"
printf -- '---\ntype: concept\ntags:\n  - concept\n---\n# Fizz "buzz"\n\n## Evidence\n\n- (hand-written)\n' > "$C9/Fizz \"buzz\".md"
mkclip5 "$EV9" q-1.md "Quill One" "https://q-one.com/x" 'say-"hi"-topic'
mkclip5 "$EV9" q-2.md "Quill Two" "https://q-two.org/x" 'say-"hi"-topic'
mkclip5 "$EV9" f-1.md "Fizz One" "https://f-one.com/x" 'fizz-"buzz"'
mkclip5 "$EV9" f-2.md "Fizz Two" "https://f-two.org/x" 'fizz-"buzz"'
mkclip5 "$EV9" b-1.md "Back One" "https://b-one.com/x" 'back\slash'
mkclip5 "$EV9" b-2.md "Back Two" "https://b-two.org/x" 'back\slash'
LEDGER9="$tmp9/.synthesize-stubs.ledger.jsonl"
out9="$(node "$TOOL" "$tmp9" --apply 2>&1)"; printf '%s
' "$out9"
promoted_of() {
  node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").split("\n").find((x)=>x.startsWith("promoted_to: ")); process.stdout.write(l ? JSON.parse(l.slice(13)) : "no promoted_to line")' "$1" 2>&1 | tail -n 1
}
assert "a created page with a quote in its name parses back from the clip header" '[[30-Resources/Concepts/Say "hi" Topic]]' "$(promoted_of "$EV9/q-1.md")"
assert "and so does the second clip" '[[30-Resources/Concepts/Say "hi" Topic]]' "$(promoted_of "$EV9/q-2.md")"
assert "a densified page with a quote in its name parses back from the clip header" '[[30-Resources/Concepts/Fizz "buzz"]]' "$(promoted_of "$EV9/f-1.md")"
assert "a backslash in a name parses back too" '[[30-Resources/Concepts/Back\slash]]' "$(promoted_of "$EV9/b-1.md")"
if python3 -I -c 'import yaml' 2>/dev/null; then
  yaml_of() { python3 -I -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1], encoding="utf-8").read().split("---")[1])["promoted_to"])' "$1" 2>&1 | tail -n 1; }
  assert "a YAML parser reads the created page's name from the header" '[[30-Resources/Concepts/Say "hi" Topic]]' "$(yaml_of "$EV9/q-1.md")"
  assert "a YAML parser reads the densified page's name from the header" '[[30-Resources/Concepts/Fizz "buzz"]]' "$(yaml_of "$EV9/f-1.md")"
fi
node "$TOOL" "$tmp9" --revert "$LEDGER9" >/dev/null 2>&1
assert "revert clears the stamp of a quoted name" "0" "$(grep -lF 'promoted_to:' "$EV9"/*.md | wc -l | tr -d ' ')"

echo "Test group 10: a page with a non-Latin name is extended, not refused"
tmp10="$(mktemp -d -t synth10.XXXXXX)" || exit 1
trap 'rm -rf "$tmp" "$tmp4" "$tmp5" "$tmp5b" "$tmp6" "$tmp6b" "$tmp7" "$tmp8" "$tmp9" "$tmp10"' EXIT
EV10="$tmp10/Clippings/_evidence"
C10="$tmp10/30-Resources/Concepts"
mkdir -p "$EV10" "$C10"
printf -- '---\ntype: concept\ntags:\n  - concept\n---\n# Агенты\n\n## Evidence\n\n- (hand-written)\n' > "$C10/Агенты.md"
cp "$C10/Агенты.md" "$tmp10/hand.copy"
mkclip5 "$EV10" cy-1.md "Cy One" "https://cy-one.com/x" "агенты"
mkclip5 "$EV10" cy-2.md "Cy Two" "https://cy-two.org/x" "агенты"
LEDGER10="$tmp10/.synthesize-stubs.ledger.jsonl"
out10="$(node "$TOOL" "$tmp10" --apply 2>&1)"; printf '%s
' "$out10"
assert "the non-Latin page receives both clips" "2" "$(grep -c '^- \[\[Clippings/_evidence/cy-' "$C10/Агенты.md" 2>/dev/null || echo 0)"
assert "the run prints no refusal" "0" "$(grep -c 'refused' <<<"$out10")"
assert "the summary counts one densify" "synthesize-stubs.mjs: 0 created, 1 densified, 0 skipped" "$(tail -n 1 <<<"$out10")"
assert "no second page appears" "1" "$(find "$C10" -type f -name '*.md' | wc -l | tr -d ' ')"
assert "both clips are stamped" "2" "$(grep -lF 'promoted_to:' "$EV10"/cy-*.md | wc -l | tr -d ' ')"
out10b="$(node "$TOOL" "$tmp10" --apply 2>&1)"
assert "the next night changes nothing" "synthesize-stubs.mjs: 0 created, 0 densified, 0 skipped, 1 unchanged" "$(tail -n 1 <<<"$out10b")"
node "$TOOL" "$tmp10" --revert "$LEDGER10" >/dev/null 2>&1
assert "revert restores the page byte for byte" "same" "$(cmp -s "$tmp10/hand.copy" "$C10/Агенты.md" && echo same || echo changed)"

echo "Test group 11: the dry run reports what the real run does"
tmp11="$(mktemp -d -t synth11.XXXXXX)" || exit 1
trap 'rm -rf "$tmp" "$tmp4" "$tmp5" "$tmp5b" "$tmp6" "$tmp6b" "$tmp7" "$tmp8" "$tmp9" "$tmp10" "$tmp11"' EXIT
V11="$tmp11/dry"
EV11="$V11/Clippings/_evidence"
C11="$V11/30-Resources/Concepts"
mkdir -p "$EV11" "$C11"
for t in aa-phantom clean-a clean-b zz-phantom; do
  mkclip5 "$EV11" "$t-1.md" "$t One" "https://$t-one.com/x" "$t"
  mkclip5 "$EV11" "$t-2.md" "$t Two" "https://$t-two.org/x" "$t"
done
printf 'the operator wrote this page by hand\n' > "$C11/Aa Phantom.md"
printf 'the operator wrote this page by hand\n' > "$C11/Zz Phantom.md"
for v in real limit limitreal; do cp -a "$V11" "$tmp11/$v"; done
as_real() { sed -e 's/would-create/created/' -e 's/would-densify/densified/'; }
HIDDEN11="Aa Phantom.md|Zz Phantom.md"
dry11="$(run_hiding "$HIDDEN11" "$TOOL" "$V11" --dry-run 2>&1)"; printf '%s
' "$dry11"
real11="$(run_hiding "$HIDDEN11" "$TOOL" "$tmp11/real" --apply 2>&1)"
assert "a dry run announces no page for a name the real run refuses" "0" "$(grep -c 'would create.*Phantom' <<<"$dry11")"
assert "it prints the refusal for each" "2" "$(grep -c 'refused: a file already sits there' <<<"$dry11")"
assert "its refusals are the real run's" "$(grep '^⊘' <<<"$real11")" "$(grep '^⊘' <<<"$dry11")"
assert "its counts are the real run's" "$(tail -n 1 <<<"$real11")" "$(tail -n 1 <<<"$dry11" | as_real)"
assert "and the counts are two created, two refused" "synthesize-stubs.mjs: 2 created, 0 densified, 0 skipped, 2 refused (path taken)" "$(tail -n 1 <<<"$dry11" | as_real)"
assert "the dry run wrote nothing" "2" "$(find "$C11" -type f | wc -l | tr -d ' ')"
dryl="$(run_hiding "$HIDDEN11" "$TOOL" "$tmp11/limit" --dry-run --limit 1 2>&1)"
reall="$(run_hiding "$HIDDEN11" "$TOOL" "$tmp11/limitreal" --apply --limit 1 2>&1)"
assert "under --limit the dry run counts what the real run counts" "$(tail -n 1 <<<"$reall")" "$(tail -n 1 <<<"$dryl" | as_real)"
assert "a refused name takes no slot and the one after the limit is pending" "synthesize-stubs.mjs: 1 created, 0 densified, 0 skipped, 1 refused (path taken), 2 pending (limit 1)" "$(tail -n 1 <<<"$dryl" | as_real)"

echo "Test group 12: the deferred-clips file is refused when it is not a plain file"
tmp12="$(mktemp -d -t synth12.XXXXXX)" || exit 1
trap 'rm -rf "$tmp" "$tmp4" "$tmp5" "$tmp5b" "$tmp6" "$tmp6b" "$tmp7" "$tmp8" "$tmp9" "$tmp10" "$tmp11" "$tmp12"' EXIT
L12="$tmp12/link"
P12="$tmp12/plain"
EV12="$L12/Clippings/_evidence"
mkdir -p "$EV12" "$L12/30-Resources/Tech" "$tmp12/outside"
mkclip5 "$EV12" kit-1.md "Kit One" "https://github.com/acme/agent-kit" "agent-kit"
mkclip5 "$EV12" kit-2.md "Kit Two" "https://github.com/zeta/orchestrator" "agent-kit"
printf '# Deferred\n\n- [ ] acme/agent-kit tail-skipped by the cap\n- [ ] zeta/orchestrator tail-skipped by the cap\n- [ ] other/unrelated tail-skipped by the cap\n' > "$tmp12/outside/deferred.md"
cp "$tmp12/outside/deferred.md" "$tmp12/deferred.copy"
cp -a "$L12" "$P12"
cp "$tmp12/deferred.copy" "$P12/Clippings/_deferred.md"
ln -s "$tmp12/outside/deferred.md" "$L12/Clippings/_deferred.md"
DEF_REFUSAL="⊘ Clippings/_deferred.md — refused: an existing symbolic link sits there, nothing written"
dry12="$(node "$TOOL" "$L12" --dry-run 2>&1)"
assert "a dry run reports the refusal" "1" "$(grep -cF "$DEF_REFUSAL" <<<"$dry12")"
out12="$(node "$TOOL" "$L12" --apply 2>&1)"; printf '%s
' "$out12"
assert "the target of a linked deferred file is byte for byte unchanged" "same" "$(cmp -s "$tmp12/deferred.copy" "$tmp12/outside/deferred.md" && echo same || echo changed)"
assert "the link is still a link" "yes" "$([ -L "$L12/Clippings/_deferred.md" ] && echo yes || echo no)"
assert "the real run reports the refusal once" "1" "$(grep -cF "$DEF_REFUSAL" <<<"$out12")"
assert "the Tech page is still created" "yes" "$([ -f "$L12/30-Resources/Tech/Agent Kit.md" ] && echo yes || echo no)"
outp12="$(node "$TOOL" "$P12" --apply 2>&1)"
assert "control: a plain deferred file has both rows claimed" "2" "$(grep -c '^- \[x\] ' "$P12/Clippings/_deferred.md")"
assert "control: and prints no refusal" "0" "$(grep -c 'refused' <<<"$outp12")"
cp "$P12/Clippings/_deferred.md" "$tmp12/outside/claimed.md"
cp "$tmp12/outside/claimed.md" "$tmp12/claimed.copy"
rm "$P12/Clippings/_deferred.md"
ln -s "$tmp12/outside/claimed.md" "$P12/Clippings/_deferred.md"
rev12="$(node "$TOOL" "$P12" --revert "$P12/.synthesize-stubs.ledger.jsonl" 2>&1)"; printf '%s
' "$rev12"
assert "a revert never writes through a linked deferred file" "same" "$(cmp -s "$tmp12/claimed.copy" "$tmp12/outside/claimed.md" && echo same || echo changed)"
assert "and reports the refusal" "1" "$(grep -cF "$DEF_REFUSAL" <<<"$rev12")"
assert "the summary counts it apart from the diverged pages" "synthesize-stubs.mjs: 1 reverted, 0 refused (diverged), 0 already-gone, 2 refused (not a plain file)" "$(tail -n 1 <<<"$rev12")"

echo "Test group 13: a housekeeping word is ignored in its plural form too"
tmp13="$(mktemp -d -t synth13.XXXXXX)" || exit 1
trap 'rm -rf "$tmp" "$tmp4" "$tmp5" "$tmp5b" "$tmp6" "$tmp6b" "$tmp7" "$tmp8" "$tmp9" "$tmp10" "$tmp11" "$tmp12" "$tmp13"' EXIT
EV13="$tmp13/Clippings/_evidence"
C13="$tmp13/30-Resources/Concepts"
mkdir -p "$EV13" "$C13"
for t in articles plugins clips libraries inboxes ideas repos syntheses theories gardening; do
  mkclip5 "$EV13" "$t-1.md" "$t One" "https://$t-one.com/x" "$t"
  mkclip5 "$EV13" "$t-2.md" "$t Two" "https://$t-two.org/x" "$t"
done
out13="$(node "$TOOL" "$tmp13" --apply 2>&1)"; printf '%s
' "$out13"
assert "two clips tagged with a housekeeping plural make no page, a real topic still does" "Gardening.md" "$(pages_like "$C13" '')"
assert "only the real topic's clips are stamped" "2" "$(grep -lF 'promoted_to:' "$EV13"/*.md | wc -l | tr -d ' ')"
leaks13="$(node --input-type=module -e '
const { STRUCTURAL_TAGS, topicalTags } = await import("file://" + process.argv[1]);
const plural = (w) => /[^aeiou]y$/.test(w) ? w.slice(0, -1) + "ies" : /(x|z|ch|sh|ss)$/.test(w) ? w + "es" : /sis$/.test(w) ? w.slice(0, -2) + "es" : w + "s";
const forms = (w) => /s$/.test(w) && !/sis$/.test(w) ? [w] : [w, plural(w)];
const leaks = [...STRUCTURAL_TAGS].flatMap(forms).filter((t) => topicalTags([t]).length);
process.stdout.write(leaks.join(" "));
' "$PLUGIN_DIR/tools/lib/stub-synthesis.mjs" 2>&1)"
assert "every housekeeping word is ignored in both forms" "" "$leaks13"

echo "Test group 14: an archived clip feeds no subject page"
tmp14="$(mktemp -d -t synth14.XXXXXX)" || exit 1
trap 'rm -rf "$tmp" "$tmp4" "$tmp5" "$tmp5b" "$tmp6" "$tmp6b" "$tmp7" "$tmp8" "$tmp9" "$tmp10" "$tmp11" "$tmp12" "$tmp13" "$tmp14"' EXIT
EV14="$tmp14/Clippings/_evidence"
C14="$tmp14/30-Resources/Concepts"
mkdir -p "$EV14" "$C14"
mkclip14() {
  local f="$1" tag="$2" arch="$3" name="${1%.md}"
  { printf -- '---\ntype: article\nsource: "https://%s.example.com/x"\nauthor: %s Author\nprocessed: true\nevidence_kind:\n  - concepts\ntags:\n  - %s\n' "$name" "$name" "$tag"
    [ -z "$arch" ] || printf '%s\narchived_at: 2026-11-20\n' "$arch"
    printf -- '---\nclip %s\n' "$f"; } > "$EV14/$f"
}
mkclip14 only-live.md  "converges-late"  ""
mkclip14 only-arch.md  "converges-late"  "archived: true"
mkclip14 ctl-a.md      "converges-ctl"   ""
mkclip14 ctl-b.md      "converges-ctl"   "archived: false"
mkclip14 held-a.md     "held-topic"      "archived: true"
mkclip14 held-b.md     "held-topic"      ""
printf -- '---\ntype: concept\ntags:\n  - concept\n---\n# Held Topic\n\n## Evidence\n\n- [[Clippings/_evidence/held-a]] — cited before the clip was archived\n' > "$C14/Held Topic.md"
cp "$C14/Held Topic.md" "$tmp14/held.copy"
cp "$EV14/only-arch.md" "$tmp14/only-arch.copy"
LEDGER14="$tmp14/.synthesize-stubs.ledger.jsonl"
dry14="$(node "$TOOL" "$tmp14" --dry-run 2>&1)"; printf '%s
' "$dry14"
assert "a tag that converges only through an archived clip makes no page in a dry run" "0" "$(grep -c "would create.*Converges Late" <<<"$dry14")"
assert "the same tag with no clip archived does (archived: false is live)" "1" "$(grep -c "would create.*Converges Ctl" <<<"$dry14")"
assert "an existing page that cites an archived clip is not densified in a dry run" "0" "$(grep -c "Held Topic" <<<"$dry14")"
out14="$(node "$TOOL" "$tmp14" --apply 2>&1)"; printf '%s
' "$out14"
assert "no page is made for the archived convergence" "no" "$([ -e "$C14/Converges Late.md" ] && echo yes || echo no)"
assert "the live convergence is made" "yes" "$([ -f "$C14/Converges Ctl.md" ] && echo yes || echo no)"
assert "an existing page that cites an archived clip is byte for byte unchanged" "same" "$(cmp -s "$tmp14/held.copy" "$C14/Held Topic.md" && echo same || echo changed)"
assert "the archived clip is byte for byte unchanged (no promoted_to stamp)" "same" "$(cmp -s "$tmp14/only-arch.copy" "$EV14/only-arch.md" && echo same || echo changed)"
assert "the summary counts one created and nothing densified" "synthesize-stubs.mjs: 1 created, 0 densified, 0 skipped" "$(tail -n 1 <<<"$out14")"
node "$TOOL" "$tmp14" --revert "$LEDGER14" >/dev/null 2>&1
assert "revert removes the one page made" "0" "$(find "$C14" -type f -name '*.md' | grep -vc 'Held Topic')"

echo "Test group 15: a clip file name with a quote or a backslash cannot break a new page"
tmp15="$(mktemp -d -t synth15.XXXXXX)" || exit 1
trap 'rm -rf "$tmp" "$tmp4" "$tmp5" "$tmp5b" "$tmp6" "$tmp6b" "$tmp7" "$tmp8" "$tmp9" "$tmp10" "$tmp11" "$tmp12" "$tmp13" "$tmp14" "$tmp15"' EXIT
EV15="$tmp15/Clippings/_evidence"
C15="$tmp15/30-Resources/Concepts"
mkdir -p "$EV15" "$C15"
mkclip5 "$EV15" 'a"q\b-1.md' "Name One" "https://name-one.com/x" "odd-file-name"
mkclip5 "$EV15" 'b-2.md' "Name Two" "https://name-two.org/x" "odd-file-name"
LEDGER15="$tmp15/.synthesize-stubs.ledger.jsonl"
out15="$(node "$TOOL" "$tmp15" --apply 2>&1)"; printf '%s
' "$out15"
derived_of() {
  node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").split("\n").find((x)=>x.startsWith("derived_from: ")); process.stdout.write(l ? JSON.parse(l.slice(14)) : "no derived_from line")' "$1" 2>&1 | tail -n 1
}
assert "the page is created" "yes" "$([ -f "$C15/Odd File Name.md" ] && echo yes || echo no)"
assert "derived_from parses back to the clip's name" '[[Clippings/_evidence/a"q\b-1]]' "$(derived_of "$C15/Odd File Name.md")"
if python3 -I -c 'import yaml' 2>/dev/null; then
  assert "a YAML parser reads the clip's name from derived_from" '[[Clippings/_evidence/a"q\b-1]]' "$(python3 -I -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1], encoding="utf-8").read().split("---")[1])["derived_from"])' "$C15/Odd File Name.md" 2>&1 | tail -n 1)"
fi
assert "both clips are stamped" "2" "$(grep -lF 'promoted_to:' "$EV15"/*.md | wc -l | tr -d ' ')"
node "$TOOL" "$tmp15" --revert "$LEDGER15" >/dev/null 2>&1
assert "revert removes the page and clears both stamps" "0 0" "$(find "$C15" -type f | wc -l | tr -d ' ') $(grep -lF 'promoted_to:' "$EV15"/*.md | wc -l | tr -d ' ')"

echo "Test group 15b: the hiding helper adds to NODE_OPTIONS and does not replace it"
mkdir "$tmp15/probe"
carried15="$(NODE_OPTIONS="--title=carried-setting" run_hiding "gone.md" -e 'const fs=require("fs"),p=require("path"),d=process.argv[1]; fs.writeFileSync(p.join(d,"gone.md"),"x"); fs.writeFileSync(p.join(d,"kept.md"),"x"); process.stdout.write(process.title+" "+fs.readdirSync(d).sort().join(","))' "$tmp15/probe" 2>&1 | tail -n 1)"
assert "a setting passed in survives and the preload still hides the file" "carried-setting kept.md" "$carried15"

echo "Test group 16: an option that takes a value, given none or followed by another option, is refused and writes nothing"
tmp16="$(mktemp -d -t synth16.XXXXXX)" || exit 1
trap 'rm -rf "$tmp" "$tmp4" "$tmp5" "$tmp5b" "$tmp6" "$tmp6b" "$tmp7" "$tmp8" "$tmp9" "$tmp10" "$tmp11" "$tmp12" "$tmp13" "$tmp14" "$tmp15" "$tmp16"' EXIT
V16="$tmp16/vault"
EV16="$V16/Clippings/_evidence"
mkdir -p "$EV16" "$V16/30-Resources/Concepts" "$tmp16/cwd"
mkclip5 "$EV16" arg-1.md "Arg One" "https://arg-one.com/x" "arg-topic"
mkclip5 "$EV16" arg-2.md "Arg Two" "https://arg-two.org/x" "arg-topic"
cp -a "$V16" "$tmp16/control"
whole_hash16() { ( cd "$1" && find . | LC_ALL=C sort; find . -type f -exec cksum {} + | LC_ALL=C sort ) | cksum; }
refused16() {
  local label="$1" rc hv hc
  shift
  hv="$(whole_hash16 "$V16")"; hc="$(whole_hash16 "$tmp16/cwd")"
  ( cd "$tmp16/cwd" && node "$TOOL" "$V16" "$@" >"$tmp16/out" 2>"$tmp16/err" ); rc=$?
  assert "$label: exit 1, a usage line, the vault and the working directory untouched" "1 1 same same" \
    "$rc $(grep -c 'usage: synthesize-stubs.mjs' "$tmp16/err") $([ "$hv" = "$(whole_hash16 "$V16")" ] && echo same || echo changed) $([ "$hc" = "$(whole_hash16 "$tmp16/cwd")" ] && echo same || echo changed)"
}
refused16 "--ledger with no value" --apply --ledger
refused16 "--ledger followed by another option" --ledger --apply
refused16 "--revert with no value" --revert
refused16 "--revert followed by another option" --revert --dry-run
refused16 "--ledger given an empty value" --apply --ledger ""
assert "control: a value given for each option is still taken (apply with --ledger)" "yes" "$(node "$TOOL" "$tmp16/control" --apply --ledger "$tmp16/own.jsonl" >/dev/null 2>&1; [ -f "$tmp16/own.jsonl" ] && [ -f "$tmp16/control/30-Resources/Concepts/Arg Topic.md" ] && echo yes || echo no)"
node "$TOOL" "$tmp16/control" --revert "$tmp16/own.jsonl" >/dev/null 2>&1
assert "control: and --revert <ledger> still undoes it" "no" "$([ -e "$tmp16/control/30-Resources/Concepts/Arg Topic.md" ] && echo yes || echo no)"

echo "Test group 17: the plural fold keeps quiz and quizzes together, https apart from http, and ignores trailing punctuation"
keys17="$(node --input-type=module -e '
const { tagKey, subjectKey } = await import("file://" + process.argv[1]);
const same = (a, b) => (tagKey(a) === tagKey(b) ? "same" : "differ");
process.stdout.write([
  same("quiz", "quizzes"), same("buzz", "buzzes"), same("https", "http"), same("c++", "c"), same("workflow", "workflows"), same("agent", "agents"),
  subjectKey("Workflows!") === subjectKey("workflow") ? "same" : "differ",
  subjectKey("Https") === subjectKey("Http") ? "same" : "differ",
  tagKey("https"), tagKey("quizzes"), tagKey("status"), tagKey("statuses"), tagKey("workflows!"),
].join(" "));
' "$PLUGIN_DIR/tools/lib/stub-synthesis.mjs" 2>&1)"
assert "quiz and quizzes share a key" "same" "$(cut -d' ' -f1 <<<"$keys17")"
assert "buzz and buzzes still share a key" "same" "$(cut -d' ' -f2 <<<"$keys17")"
assert "https and http keep two keys" "differ" "$(cut -d' ' -f3 <<<"$keys17")"
assert "https keeps its form" "https" "$(cut -d' ' -f9 <<<"$keys17")"
assert "c++ and c keep two tag keys" "differ" "$(cut -d' ' -f4 <<<"$keys17")"
assert "control: workflow and workflows, agent and agents still fold together" "same same" "$(cut -d' ' -f5-6 <<<"$keys17")"
assert "a trailing mark does not hide the plural: Workflows! and workflow are one subject key" "same" "$(cut -d' ' -f7 <<<"$keys17")"
assert "Https and Http are two subject keys" "differ" "$(cut -d' ' -f8 <<<"$keys17")"
assert "the stem of quizzes is quiz" "quiz" "$(cut -d' ' -f10 <<<"$keys17")"
assert "control: statuses still folds to the stem of status" "status status" "$(cut -d' ' -f11-12 <<<"$keys17")"
assert "the plural of a word followed by a mark folds under the mark" "workflow!" "$(cut -d' ' -f13 <<<"$keys17")"

tmp17="$(mktemp -d -t synth17.XXXXXX)" || exit 1
trap 'rm -rf "$tmp" "$tmp4" "$tmp5" "$tmp5b" "$tmp6" "$tmp6b" "$tmp7" "$tmp8" "$tmp9" "$tmp10" "$tmp11" "$tmp12" "$tmp13" "$tmp14" "$tmp15" "$tmp16" "$tmp17"' EXIT
EV17="$tmp17/Clippings/_evidence"
C17="$tmp17/30-Resources/Concepts"
mkdir -p "$EV17" "$C17"
mkclip5 "$EV17" qz-a.md "Ann Author" "https://qa.com/q" "quiz"
mkclip5 "$EV17" qz-b.md "Ben Author" "https://qb.com/q" "quizzes"
mkclip5 "$EV17" qz-c.md "Cy Author" "https://qc.com/q" "quizzes"
mkclip5 "$EV17" ht-a.md "Di Author" "https://da.com/h" "http"
mkclip5 "$EV17" ht-b.md "Eli Author" "https://db.com/h" "http"
mkclip5 "$EV17" hs-a.md "Flo Author" "https://ea.com/h" "https"
mkclip5 "$EV17" hs-b.md "Gus Author" "https://eb.com/h" "https"
mkclip5 "$EV17" wf-a.md "Hal Author" "https://fa.com/w" "workflow"
mkclip5 "$EV17" wf-b.md "Ian Author" "https://fb.com/w" "workflow"
printf -- '---\ntype: concept\ntags:\n  - concept\n---\n# Workflows!\n\n## Evidence\n\n- [[Clippings/_evidence/seed]] — seeded by hand\n' > "$C17/Workflows!.md"
out17="$(node "$TOOL" "$tmp17" --apply 2>&1)"; printf '%s
' "$out17"
assert "quiz (1) and quizzes (2): one page for the three clips" "3" "$(cat "$C17"/Quiz*.md 2>/dev/null | grep -c '^- \[\[Clippings/_evidence/qz-')"
assert "quiz and quizzes make exactly one page" "1" "$(pages_like "$C17" Quiz | wc -w | tr -d ' ')"
assert "http and https make two pages, each with its own two clips" "2 2 2" "$(pages_like "$C17" Http | wc -w | tr -d ' ') $(grep -c '^- \[\[Clippings/_evidence/ht-' "$C17/Http.md" 2>/dev/null) $(grep -c '^- \[\[Clippings/_evidence/hs-' "$C17/Https.md" 2>/dev/null)"
assert "an https clip is never listed on the http page" "0" "$(grep -c '/hs-' "$C17/Http.md" 2>/dev/null)"
assert "a planned workflow subject extends the existing Workflows!.md and makes no second page" "1 2" "$(pages_like "$C17" Workflow | wc -w | tr -d ' ') $(grep -c '^- \[\[Clippings/_evidence/wf-' "$C17/Workflows!.md" 2>/dev/null)"

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "test-synthesize-stubs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
