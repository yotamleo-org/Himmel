# himmel working principles (user-scope template)

`scripts/adopt.sh` appends the fenced block below to your
user-scope `~/.claude/CLAUDE.md` (creating the file if absent). The block is
delimited by the `HIMMEL:working-principles` markers. When the file already
holds both marker lines, install and update replace the text between them
with this block (a no-op when equal); text outside the markers is never
touched, and a file with the principles but no markers is left alone.

The first four defaults used to sit in himmel's project `CLAUDE.md`. They are
general engineering defaults, not himmel invariants, so they belong on the
user-scope layer where every project gets them once instead of every himmel
session paying for them. Operator machines that already carry a
user-scope `CLAUDE.md` with these principles are detected and left alone.

**Why this is not the same file as
[`global-claude-md.md`](global-claude-md.md)**, which states the same four
principles: that one is the *operator's* personal user-scope file, copied
wholesale on a new machine and ending in an `@RTK.md` import an adopter has no
file for. It is the operator's to reword. This one is the adopter payload with
a stable marker fence, and adopt.sh reads it at run time, so an edit to the
operator's personal prose can never silently change what adopters install.

Everything between (and including) the two marker lines is the payload:

<!-- BEGIN HIMMEL:working-principles -->
## Working principles (general defaults)

Use judgement on trivial tasks.

1. **Think before coding** — read the code the change touches before editing
   it; trace the real flow end to end. State your assumptions and proceed.
   Ask only when different readings of the request would lead to materially
   different work, or when the action is destructive or hard to reverse. If a
   simpler approach exists, take it unless told otherwise.
2. **Simplicity first** — the minimum code that solves the problem. Nothing
   speculative: no unrequested features, abstractions, configurability, or
   error handling for impossible scenarios.
3. **Surgical changes** — touch only what the task requires. Match the existing
   style. Don't refactor what isn't broken. Remove only the orphans your own
   change created; mention unrelated dead code rather than deleting it.
4. **Verify before you claim** — turn the task into a check that fails if the
   work is wrong (e.g. a test that reproduces the bug). Make it pass, then
   report the actual result.
5. **POC before build** — a new mechanism or tool gets a live end-to-end proof
   of concept, plus a check that it is used and worth its cost, before more is
   built on top of it.
6. **Top tier for the hard call only** — routine ops work (pipeline drains,
   ingests, bulk triage) never runs on the scarcest model tier, and is never
   orchestrated from a parent session on it. Spend that tier on the one
   judgement call that needs it.
<!-- END HIMMEL:working-principles -->

The memory-row anchors for principles 5 and 6 sit below the END marker, so
the installer never copies them into an adopter's file:

<!-- mem:e9c0126c43f0 -->
- principle 5, POC before build
<!-- mem:6dcc4aece8c1 -->
- principle 6, top tier for the hard call only
