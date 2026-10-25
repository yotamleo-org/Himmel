---
key: "HIMMEL-5498"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["glossary","needs-standard","operator-directed","ps3-blocker","theme-docs-glossary","tool-adoption","unscheduled"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6215"
created: "2026-10-13T13:30:30.928+0200"
updated: "2026-10-18T01:12:26.052+0200"
resolution: "Done"
resolved: "2026-10-18T01:12:10.147+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-5498: Adopt Matt Pocock's glossary skill (mattpocock/skills) to maintain docs/glossary.md: rubric eval and A/B first

## Description

# HIMMEL-5498: Adopt Matt Pocock's glossary skill (mattpocock/skills) to maintain docs/glossary.md: rubric eval and A/B first
The harness glossary (docs/glossary.md, HIMMEL-5419) is kept by hand. Terms drift, synonyms creep in, and nobody is prompted to define a new term when a PR coins one.
Evaluate and, if it passes, adopt Matt Pocock's glossary skill from mattpocock/skills (grill-with-docs / domain-modeling, the GLOSSARY.md style 5419 already follows) so agents maintain docs/glossary.md the same way: one definition per term, aliases pointing at the canonical term.
- Run the tool-adoption rubric (docs/tool-adoption/rubric.md): license, what the skill actually instructs, context cost of its listing, overlap with existing skills (lean-skills:grilling, minerva), and an A/B on one real glossary task (add the terms from one merged PR) with and without it. POC befor
- If adopted: vendor or pin it per the upstream-and-vendoring rules (pin-or-better), register it in the right plugin profile only (not every leg), and record it in docs/tool-adoption/registry.md.
PR #2741 merged, squash sha ceb7a4b70cd00cee7c66c09c52d0e1e2c02c5177. Verdict recorded in docs/tool-adoption/registry.md: ADOPT (narrow margin; upstream pin 49dd158d1076134a641b33efb035946536778336).
