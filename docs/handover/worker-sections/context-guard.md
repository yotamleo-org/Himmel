# Leg preface section — context guard

Read on demand: `leg-preface.md` names this file when the context guard denies a call. Moved verbatim from the preface.

**Context past 75 % of your `--autocompact` ceiling, when the context guard
is on:** checkpoint or hand off. The guard (`guard-leg-context-handoff.sh`) is **off by default**: it runs only when your console
launched you with `--context-guard compact|handoff`, which sets
`HIMMEL_WORKER_SESSION_CONTEXT_MODE`; you cannot change it in-session. The one reference is
`docs/internals/leg-context-guard.md`. The threshold is 75 % of the ceiling, not
of the window: an opus leg pinned at 200000 runs on a 1000000-token window, so it
fires at 15 % fill (150k tokens), 7k before the earliest observed compaction
(none fired below 157k of 200k). Past it the hook denies every call
but the hand-off ones; its deny names your mode and exactly what unlocks it.

- **`compact`:** commit your WIP in one line (`git commit -m "<subject>" -m
  "<body>" --trailer "…"`; a newline in the command is denied), `git push`, then
  append `LIVE — CHECKPOINT <full sha of HEAD> pushed` with `append-results.sh`
  (`… clean` instead when the tree is clean and there is nothing to push). The
  hook unlocks once that sha is your HEAD and your upstream, and it also
  refuses the auto-compaction until then. Then carry on: the compaction is a
  backstop, not lost work — when it fires, re-read the leg preface and your handover
  doc (309 of 349 compacted legs still wrapped).
- **`handoff`:** write `…legN<n>b-…-RESUME.md`, message the console, stop. The
  hook unlocks once that RESUME doc exists.

In both modes a last marker of `WRAPPED` unlocks everything; `BLOCKED` frees
only the hand-off calls and reads, so a leg that cannot commit or push sends
`BLOCKED` to its console and stops. Run the context-fill probe after **every**
completed step, not only when you notice growth (ruling A1), so the threshold
never surprises you mid-edit.
