# Worker preface section — context guard

Read on demand: `worker-preface.md` names this file when the context guard denies a call. Moved verbatim from the preface.

**Context past 75 % of your `--autocompact` ceiling, when the context guard
is on:** checkpoint or hand off. The guard (`guard-worker-context-handoff.sh`) is **off by default**: it runs only when your chief
launched you with `--context-guard compact|handoff`, which sets
`HIMMEL_WORKER_SESSION_CONTEXT_MODE`, or when your profile turns it on (a native Sonnet 5.5
`worker-impl` or `worker-eval` launch compacts, at an 850000 ceiling; a native
Opus 5.5 launch on any `worker-*` profile compacts, at an 850000 ceiling
with the deny at 740000 tokens); you cannot
change it in-session. The one reference is
`docs/internals/worker-context-guard.md`. The threshold is 75 % of the ceiling by default
(73 on a Sonnet profile, 87 on an Opus one; the deny names yours), not of the window: an opus worker pinned at 200000 runs on a 1000000-token window, so it
fires at 15 % fill (150k tokens), 7k before the earliest observed compaction
(none fired below 157k of 200k). Past it the hook denies every call
but the hand-off ones; its deny names your mode and exactly what unlocks it.

- **`compact`:** commit your WIP in one line (`git commit -m "<subject>" -m
  "<body>" --trailer "…"`; a newline in the command is denied), `git push`, then
  append `LIVE — CHECKPOINT <full sha of HEAD> pushed` with `append-results.sh`
  (`… clean` instead when the tree is clean and there is nothing to push). The
  hook unlocks once that sha is your HEAD and your upstream, and it also
  refuses the auto-compaction until then. Then carry on: the compaction is a
  backstop, not lost work — when it fires, re-read the worker preface and your handover
  doc (309 of 349 compacted workers still wrapped).
- **`handoff`:** write your successor brief under your own doc's name with
  your label bumped one letter (`N<k>` becomes `N<k>b`, `N<k>b` becomes `N<k>c`: `<TICKET>-<next label>-<slug>-<date>-RESUME.md`; keep
  `description:` double-quoted, on one line), message the chief, stop. Copy the
  `> **Prior art:**` line and its `> ` continuation lines from your own doc, and keep
  `description:` and an absolute `resume_cwd:` in the front matter: the hook runs the
  primary checkout's `brief-lint.sh` on the RESUME doc, and unlocks (and takes your
  `BLOCKED` bullet) only once it passes. Check it first with the deny's step 1a
  command. A lint refusal is quoted in the deny: fix the doc with Edit and append
  `BLOCKED` again; a refusal you cannot clear (a core ticket with no signed spec, a
  missing Jira mirror) goes into your `BLOCKED` bullet for your chief, which always
  passes. `scripts/handover/hop-brief.py write`
  writes that brief from your transcript with no model call (its newest chief
  message carried whole, tokens scrubbed); `hop-brief.py verify` checks it.

In both modes a last marker of `WRAPPED` unlocks everything; `BLOCKED` frees
only the hand-off calls and reads, so a worker that cannot commit or push sends
`BLOCKED` to its chief and stops. Run the context-fill probe after **every**
completed step, not only when you notice growth (ruling A1), so the threshold
never surprises you mid-edit.
