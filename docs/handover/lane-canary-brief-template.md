---
resume_cwd: @REPO@
description: Lane canary (@LANE@): a no-op leg that proves this lane launches, registers and writes a first Results bullet
template_version: 3
---

# Lane canary — @LANE@ @STAMP@

> **Prior art:** lane canary; no-op by design, rendered by `scripts/lanes/lane-canary.sh`.
> **Console:** none. Nobody reads this leg: send no messages, ask no questions, open no PR.

**You are a lane canary leg on the @LANE@ lane.** Do exactly the three steps below,
one Bash call each, in order, and nothing else. Read no other file, touch no other
path, do not run the leg-preface ceremony beyond these steps.

1. `bash scripts/handover/queue-lock.sh acquire "@DOC@"`
2. `bash scripts/handover/chief-kit/append-results.sh "@DOC@" "LIVE — canary @LANE@ first bullet"`
3. `bash scripts/handover/chief-kit/append-results.sh "@DOC@" "WRAPPED — canary @LANE@ done"`,
   then `bash scripts/handover/queue-lock.sh release "@DOC@"` (the token it printed at step 1 is
   persisted; pass it as the last argument if release asks for it), then stop.

## Results (newest at the bottom)
