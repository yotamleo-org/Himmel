# humanizer (`blader/humanizer`) — tool-adoption eval

HIMMEL-5857, 2026-10-16. Method: [`rubric.md`](rubric.md). Verdict: **vendor, opt-in** (PILOT-MEASURE, in no profile).

## Goal (rubric §1)

- **Problem:** documents written for a human reader (PR bodies, ADRs, handovers) still collect AI tells that cost the operator a reword pass. `unslop` already targets this.
- **Desired outcome:** an optional second pass that rewrites a full draft in the writer's voice without changing its claims.
- **KPI:** fewer operator reword passes per document. Not a token number.

## Facts

| Item | Finding |
|---|---|
| Source | `https://github.com/blader/humanizer`, pinned `225a6f39ac85f76ee48dbad772ea4abe4ed6c9d8` (2026-09-27, merge of PR 300) |
| License | MIT, (c) 2025 Siqi Chen. Permissive for vendoring |
| Activity | 97 commits, 54 in the last 60 days. Skill version 3.1.0 |
| What runs | Nothing. One prompt file (`SKILL.md`, 32 KB). Upstream also carries a validator script and CI files; none are vendored |
| Hooks, egress, keys | None. No network call, no credential, no `allowed-tools` grant. No `egress-matrix.json` row is needed |
| Injection surface | The skill reads text the user hands it. It tells the model to treat that text as material, never as instructions. Scan of `SKILL.md` for override phrases, fake system tags, tool-call requests and approval manipulation found none |
| Trust posture | `community-active → validate-before-adopt`. Source read in full; no secrets, hook or network surface, so `source-read-mandatory` is not triggered |

## Overlap with unslop and comment-sicko

`comment-sicko` removes code comments; no overlap. `unslop` (vendored, `.claude/skills/unslop/`) has about 25 rules, plus plain-speech rules 27 to 33 and a jargon list that humanizer lacks. Humanizer has 26 patterns in six families, and adds:

- A four-step process (mark tells, draft, check the draft for added or dropped facts, final) and three output modes (pasted text, file, embedded).
- Voice matching: a writer sample overrides the patterns, including the dash rule.
- A "when not to act" section (quotations, titles, pre-2022 text) and a "keep the writer's voice" list.
- Patterns unslop has no rule for: staged run-ups (§4), arguing with no one (§5), a heading repeated in the first sentence (§24), writing about the document (§25), re-explaining what the reader knows (§26).

Where both fire they agree. The one conflict is dashes: humanizer §8 bans them unless the sample uses them; himmel dropped that ban from unslop (deviation 3) because em-dashes are house style. Humanizer's sample override resolves it when a sample is given.

## Value test

No model call and no spend; rule application read by hand on two real samples. Method limit: n=2, one reader, not blinded. It shows which rules would fire, not that the rewrites are better.

| Sample | Words | Em-dashes | Bold-label bullets | Not-X-but-Y | Stock AI words |
|---|---|---|---|---|---|
| PR 2754 body | 369 | 0 | 0 | 0 | 0 |
| `docs/internals/headless-modes.md` | 1641 | 21 | 11 | 0 | 0 |

- The PR body is already terse; neither tool has much to cut. Adding a second pass here is cost with no gain.
- The headless-modes doc is where the tools diverge. Humanizer §8 and §19 would act on 21 dashes and 11 bold labels; with the file as the voice sample, §8 keeps the dashes. `unslop` rule 16 covers the bold labels and leaves the dashes. So the net new action on himmel prose is small.
- Expected gain over unslop is the process and the fact-preservation check, which suit long external prose (blog, README, clip text), not terse ticket text.

PILOT-MEASURE exit: after two weeks of use, count documents where `/humanizer` changed something `/unslop` had left and the operator kept it. Zero kept, REJECT and remove the plugin.

## Relation to unslop (for the HIMMEL-5851 mapping)

**Coexist, do not merge or replace.** `unslop` stays the himmel house-style pass for terse internal documents: it carries himmel's three recorded deviations and its plain-speech rules. `humanizer` is an on-demand full-rewrite pass for longer prose written for people outside the harness, where voice matching and the fact-preservation check earn their cost. Merging would break byte-identical vendoring of both. Replacing `unslop` would lose rules 26 to 33. If the pilot finds humanizer never beats unslop on himmel text, drop humanizer; do not fold its rules into unslop.

## Docs pass (HIMMEL-6966)

The pilot run: `/humanizer` in file mode over the user-facing docs pages, one PR per docs section, each page as its own voice sample. A change is one changed passage (a diff hunk at zero context); it is *kept* when it survives the fact check and *dropped* when the check reverts it. The fact check compares every fenced block, inline code span, link target, heading and number before and after (zero differences on every page), then a read of each diff for added or dropped claims. Counts use the value-test method above, on prose outside code.

| Batch | Page | Kept | Dropped | Em-dashes | Not-X-but-Y | Stock AI words |
|---|---|---:|---:|---|---|---|
| B1 start here | `why-himmel.md` | 23 | 1 | 18 → 2 | 2 → 1 | 2 → 0 |
| B1 | `getting-started.md` | 25 | 0 | 32 → 3 | 0 → 0 | 1 → 0 |
| B1 | `daily-loop.md` | 14 | 0 | 16 → 6 | 0 → 0 | 1 → 1 |
| B1 | `system-design.md` | 3 | 0 | 0 → 0 | 6 → 6 | 6 → 5 |
| B1 | `architecture.md` | 13 | 0 | 15 → 1 | 4 → 3 | 0 → 0 |

The dash rule worked against the voice sample. Each page used dashes heavily, so the sample override would have kept them, but most of those dashes joined clauses that needed a comma, colon or full stop. The pass kept dashes in quoted rules and table cells and replaced the rest. `system-design.md` had already been through `unslop` and shows the smallest change: three passages, mostly table cells.

## Decision

Vendor as `marketplace/plugins/humanizer/` with `disable-model-invocation: true` (one frontmatter line added, recorded in `VENDORED.md`), in no profile. The adopter template installs it on-demand (installed, disabled); the operator enables it by hand. Removal is `claude plugin disable humanizer@himmel`.
