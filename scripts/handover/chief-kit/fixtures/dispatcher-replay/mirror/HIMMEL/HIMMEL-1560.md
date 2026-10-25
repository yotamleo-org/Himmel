---
key: "HIMMEL-1560"
type: "Bug"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["sector2-visibility"]
fixVersions: ["v1.0.0","v1.1.3"]
parent: null
created: "2026-08-05T01:08:22.480+0200"
updated: "2026-10-17T20:49:00.452+0200"
resolution: "Done"
resolved: "2026-10-17T20:49:00.427+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-1560: wire-trust-hooks checks the recorder EXISTS, not that it implements the six verbs it is wiring

## Description

THE DEFECT scripts/trust/wire-trust-hooks.mjs asserts only that a file EXISTS at the resolved recorder path. Existence is not compatibility. The recorder's verb set grew in HIMMEL-1539 from three to six, and the recorder's CLI dispatch is a silent fall-through: an unrecognised verb matches no branch
Verified in the repository:     git show c49716d5:scripts/trust/shadow-ledger.mjs -> pre, post, notify     main (3ef04645)                                   -> pre, post, postfail, denied, permreq, notify
WHY IT MATTERS MORE THAN THE SCENARIO SUGGESTS This is the same class the whole programme exists to close: an instrument that reports healthy while under-collecting, in the direction that makes the gate number LOOK smaller. A 6/6 status is the single piece of evidence an operator is told to trust th
$ node scripts/trust/shadow-ledger.mjs capabilities < /dev/null
$ git show c49716d5:scripts/trust/shadow-ledger.mjs > old.mjs
- scripts/trust/wire-trust-hooks.mjs:473-512: recorderCapabilities spawns the recorder's capabilities verb with a 10s timeout and reads empty stdout as INCAPABLE, never a pass; SHADOW_LEDGER_ID (line 83) pins the recorder identity; the required verb set is the recorder-owned EXPECTED_HOOKS (2b31b54e
