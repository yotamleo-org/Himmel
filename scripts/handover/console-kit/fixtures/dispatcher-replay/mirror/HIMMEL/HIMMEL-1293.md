---
key: "HIMMEL-1293"
type: "Bug"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["sector2-knowledge"]
fixVersions: ["v1.0.0","v1.1.3"]
parent: null
created: "2026-07-26T18:18:47.887+0200"
updated: "2026-10-17T20:48:58.932+0200"
resolution: "Done"
resolved: "2026-10-17T20:48:58.914+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-1289","relates to HIMMEL-1294"]
---

# HIMMEL-1293: graphify_update runs the destructive uv reinstall when the holder probe is UNAVAILABLE (caller-side fail-open)

## Description

scripts/lib/graphify-bin.sh, the else arm at ~line 705:
- codex-adv verdict needs-attention, one [high], scripts/lib/graphify-bin.sh:705-710, recorded in the CR ledger as codex-adv-1 / agreed against head 5afc6439.
Grounds: the fail-open arm at scripts/lib/graphify-bin.sh ~705 is out of that branch's diff, pre-existing, and already public at pub/cadence-cr-robustness@77672a6d — merging adds no new exposure. The branch strictly REDUCES how often the arm is reached (the PowerShell apostrophe fix and the resolved
1. scripts/cr/ledger-append.sh cannot re-record. Its dedup ends in if(dup) process.exit(0) — re-running it with a new severity on an existing (head, finding_id, artifact, perspective) key writes nothing and exits 0. Anything that instructs "re-run ledger-append to change a severity" is silently a no
Reopened by the 2026-10-16 premature-Done triage (HIMMEL-5877 / HIMMEL-5837). Remaining: the fail-open arm at scripts/lib/graphify-bin.sh (~705), deferred by the operator on 2026-07-26 and never fixed; no commit cites this key.
- scripts/lib/graphify-bin.sh:1211-1226: when the holder probe cannot run, the reinstall is skipped ("SKIP: cannot probe for graphify-mcp holders ... NOT attempting the reinstall"); GRAPHIFY_UNPROBED_OK=1 is the explicit escape hatch (02d41e252, PR 529).
