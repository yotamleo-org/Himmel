---
key: "HIMMEL-6043"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["operator-directed","sector2-ship"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6176"
created: "2026-10-17T02:56:41.247+0200"
updated: "2026-10-17T18:42:01.273+0200"
resolution: "Done"
resolved: "2026-10-17T18:39:26.230+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-3420","relates to HIMMEL-3423","relates to HIMMEL-6146"]
---

# HIMMEL-6043: Wire scripts/lint/shell-lint.sh into pre-commit and a CI changed-files step, with baseline triage

## Description

# HIMMEL-6043: Wire scripts/lint/shell-lint.sh into pre-commit and a CI changed-files step, with baseline triage
scripts/lint/shell-lint.sh (mktemp, gnu-flag, errexit-leak, POSIX-ERE, bash32 classes) runs in neither pre-commit nor CI; it is lean-invoke only (/shell-lint). The portability findings it already knows how to catch keep reaching review, and .coderabbit.yaml tells CodeRabbit "the repo's shell-lint ga
1. Run shell-lint.sh over the tree, record the baseline count, and either fix or allowlist each hit (# shell-lint: allow <rule> - reason, or a baseline file like scripts/lint/swallowed-errors-baseline.txt).
2. Add a local pre-commit hook shell-lint (entry: bash scripts/lint/shell-lint.sh --staged, files: '\.sh$') to .pre-commit-config.yaml.
3. Add a CI changed-files step in .github/workflows/ci.yml, copying the skill-lint pattern (~:437-453).
- Files: .pre-commit-config.yaml (trust path), .github/workflows/ci.yml (trust path), a baseline/allowlist file under scripts/lint/, scripts/lint/test-shell-lint.sh. Trust-path diff: judge plus trust-reviewed GO.
