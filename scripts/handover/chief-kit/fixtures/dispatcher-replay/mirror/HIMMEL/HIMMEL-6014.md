---
key: "HIMMEL-6014"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "High"
labels: ["operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6181"
created: "2026-10-17T01:03:09.285+0200"
updated: "2026-10-19T10:06:24.348+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6148","relates to HIMMEL-6249"]
---

# HIMMEL-6014: feat(hooks): parse Bash once into an AST (shfmt --to-json) and feed every PreToolUse guard the same command-position model

## Description

- Add scripts/hooks/lib/bash-ast: runs shfmt --to-json once per call and emits normalized commands (program, argv, redirect targets, env prefixes, subshells, heredoc bodies flagged as data).
- Touches scripts/hooks/lib (trust path): console approval and VM-first replay. Agent: opus, design profile. P50 3-4 legs.
- Done when: ported guards are predicates over the AST, the equivalence corpus passes, hook suites pass (bash scripts/ci/run-shell-tests.sh).
The guard-pr-check-literal python check (command-position case) fires only on a bare python/python3 command word. These spellings fall through to the shell-word text scan, which allows a python list argv (['bash', 'scripts/cr/x.sh']) and a non-canonical path literal inside the python text:
- a python list argv: execv('/bin/bash', ['bash', 'scripts/cr/x.sh']), where the shell-word scan reads scripts/cr/x.sh', as no target;
- non-canonical paths inside the python text: scripts/cr//x.sh, scripts/cr/./x.sh, scripts/c""r/x.sh;
