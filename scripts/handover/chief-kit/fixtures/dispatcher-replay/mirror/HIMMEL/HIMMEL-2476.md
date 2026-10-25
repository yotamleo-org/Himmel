---
key: "HIMMEL-2476"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["operator-gated","sector2-knowledge"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-09-03T08:11:47.707+0200"
updated: "2026-10-18T20:12:07.492+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-3306","relates to HIMMEL-3308"]
---

# HIMMEL-2476: Adoption Trail: fresh-user readability pass — two newcomer personas cold-read, then rewrite so the page answers what/what-it-does/how-to-undo first

## Description

Arm a session that reviews the Adoption Trail (docs/adoption-trail.html, the user-facing guide from HIMMEL-2327 / #2103) as a fresh user — someone with no understanding of Claude Code or the himmel harness — and then makes the Trail easier to understand for that reader.
2. Rewrite pass on docs/adoption-trail.html for that reader: plain-language opening (what himmel is in three sentences, who it is for, what it installs and where, how to uninstall), definitions on first use or a short glossary, a "first 5 minutes" path separated from the full trail, one platform blo
3. Fence: docs/adoption-trail.html (+ docs/setup/new-machine.md only where a Trail link target is wrong). No scripts, no settings, no VM. Docs-only PR. The user-facing artifact (55433aec) is republished by the console/operator after merge.
Rewrite half merged: PR #998 (squash sha d7705fe96c87d76cb0c214ab442d48c5c39f1424) — docs/adoption-trail.html rewritten for a reader who has never used Claude Code (three questions above the fold, separate first-5-minutes path, one box per OS, terms defined on first use plus glossary, no internal re
Each leg worked in its own directory containing only a copy of `docs/adoption-trail.html`, under a brief forbidding any read under the himmel repo, Jira, graphify or qmd, and forbidding reading the sibling persona's directory. Both confirmed at wrap that they held the fence.
The isolation was of tool access only. Both legs independently disclosed, before reading a line, that the launcher had already loaded the project's CLAUDE.md and memory index into their system prompt — the leg launcher pins --workdir to the repo regardless of the brief's resume_cwd. Filed separately
