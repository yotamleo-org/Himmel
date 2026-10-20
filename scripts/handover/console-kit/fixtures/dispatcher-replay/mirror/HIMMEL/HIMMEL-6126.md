---
key: "HIMMEL-6126"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["must-v1.1.3","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6201"
created: "2026-10-17T16:15:18.750+0200"
updated: "2026-10-19T04:18:31.204+0200"
resolution: "Done"
resolved: "2026-10-19T04:18:17.802+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6309","relates to HIMMEL-6310","relates to HIMMEL-6311","relates to HIMMEL-6312","relates to HIMMEL-6313","relates to HIMMEL-6314"]
---

# HIMMEL-6126: Fork drift check reports behind-upstream for every fork and pinned fork branch; resync claude-obsidian and claude-squad

## Description

1. Drift check (the script behind GH issue 2809): add a row kind fork-behind for every yotamleo fork (gh repo list --fork) and every pinned fork branch in scripts/upstreams.json / plugin-upstreams.json: behind/ahead vs upstream default via the compare API.
Files: the fork-drift checker under scripts/ (find via git grep -l fork-drift), scripts/upstreams.json, its suite. Registry: HIMMEL-5900. Memory: forks-synced-before-work.
PR #3133 (yotamleo/Himmel) merged @ 5f939be8db5730e5dd638c4bfa026f828e5cc6c5. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
Merged PR 3133 as 8af7a7bca1a04850e5175bbaca2d8b95f7c62888. claude-obsidian (de-forked, HIMMEL-2925) and claude-squad (archived, HIMMEL-929) are retired forks, so instead of a resync both now carry a hold-reason row in scripts/upstreams.json and the drift checker reports HELD for each. No fork pushe
