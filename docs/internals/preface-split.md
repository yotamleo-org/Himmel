# Preface and console-template split (HIMMEL-5508)

Every leg pays its preface and every console its template on every turn, so both
keep an always-on **core** and move rarely-read text into **sections** the core
names at the point of need. The core carries one sentence per rule; the section
carries the detail, moved verbatim.

| File | Budget | Pinned by |
|---|---|---|
| `docs/handover/leg-preface.md` | 12288 B | `console-kit/test-gen-briefs.sh` |
| `docs/handover/console-template.md` | 16384 B | `console-kit/test-gen-briefs.sh` |

## Leg sections (`docs/handover/leg-sections/`)

| Section | Read when |
|---|---|
| `succession.md` | a message changes your console (relay/chain table, stranded leg, `SUCCESSION accepted:` grammar) |
| `shell-and-tests.md` | a command is refused, or before running suites (shell shapes, classifier denials, memory-kill check, sandbox, impacted suites, Results `%` rule) |
| `ci-red.md` | a CI job is red (triage, merge-forward, `suite-coverage.sh`, loaded budgets) |
| `consult.md` | you need a skill your profile lacks (`CONSULT`) |
| `context-guard.md` | past 75 % of the autocompact ceiling with the guard on |

## Console sections (`docs/handover/console-sections/`)

`waiter.md` (wake keys, heartbeat), `board-tracker.md`, `live-state.md` (entry
format, optional fields), `monitors.md` (tick fields), `wrapping.md` (hand wrap,
digest), `merges.md` (trust-path PRs, cut-tag), `judge.md`, `successor-start.md`.

## Rules for editing

- A rule keeps one carrying sentence in the core; never drop it for the section.
- Tests that pin wording read the core or the section that now holds it
  (`test-succession-docs.sh`, `test-ruling-bullet-docs.sh`, `test-tick.sh`).
- The claudex, openrouter, judge and consult prefaces stay single files.
