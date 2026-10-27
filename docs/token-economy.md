# Usage and cost

Everything himmel runs on Claude draws from your Claude subscription's usage.
This page says how to read it, and what a run checks before it spends it.

## The 5-hour and weekly gauges

Your subscription has two usage windows, and himmel's status line shows how
much of each you have used:

- **5h %**: the 5-hour window.
- **7d %**: the weekly window.

Each one resets on its own clock, and the status line counts down to the
reset.

Every Claude session counts against both: the one you type in, a chief, its
workers, their subagents, and headless `claude -p` runs. A long AFK shift or a
wide parallel wave can fill the 5-hour window in a few hours. Extra usage, the
paid overflow some plans carry once a window is full, is shown separately. The
checks below keep runs from starting on a full window, but they cannot stop all
of it: a run that started on stale figures, or fills a window while it works,
can still draw on extra usage if your plan has it turned on.

## What a run checks before heavy work

- **Before it launches.** Every scheduled or armed run, and every worker the
  chief starts, first runs `scripts/lib/usage-preflight.sh`. It refuses to start
  when either window is at or over the ceiling (`CADENCE_USAGE_MAX_PCT`, 85 % by
  default). Armed runs and workers the chief starts are also refused when
  `HIMMEL_FLEET_CAP` sessions are already running; other scheduled runs check
  only usage. When it cannot read fresh figures it lets the run go ahead and
  says so.
- **Before it hands out implementation work.** A session that dispatches a
  `general-purpose`, `claude` or `Plan` subagent on sonnet, opus or fable, or
  with no model named, is refused at 80 % of the 5-hour window or 85 % of the
  weekly one (`IMPL_GUARD_HARD`, `IMPL_GUARD_WEEKLY_HARD`). Other subagent types
  and haiku are exempt. When it cannot see when the window resets, it only warns.
- **A usage lift you set** lets runs spend the weekly window up to 100 %; a
  standing lift does the same for the 5-hour window unless you set
  `CADENCE_USAGE_MAX_PCT`. Even then a run does not start on a full window.

Run `bash scripts/lib/usage-preflight.sh` yourself to see both figures and the
usage verdict a run would get now. A manual run reports how many sessions are
running but is never refused at `HIMMEL_FLEET_CAP`; only an armed run or a
worker launch is, so compare that count with the cap yourself.

## For maintainers

The full policy: which optimizer owns which token boundary, its invariants,
decision records and measured deltas.

> Operative reference (load-on-trigger instead of a CLAUDE.md rule, by
> layer selection). Single source of truth for **who owns which token
> boundary**. Sessions and evals cite this doc; changes to a boundary owner
> go through the measurement gate below. The design spec is
> `himmel/specs/design/ws6-token-economy-policy.md` in the state repo.

## The policy

Counter-pattern first, because it frames everything: **token burn is a
vanity metric, so measure outcomes instead of tokens.** Optimizers compose because
each targets a different boundary; they conflict only when two target the
same one (then pick the stronger and disable the loser).

| Boundary | Owner | Status / gate |
|---|---|---|
| Dev command output | **RTK (hooked)**, which keeps the boundary | context-mode is **REJECTED for adoption while NOASSERTION-licensed** (himmel targets an MIT-licensed public path); re-open ONLY if it ships an OSI license AND beats RTK on a measured real-session delta (same measured-eval protocol) |
| Conversational / verbose output | **unowned** | the boundary is deliberately empty: a candidate enters through invariant 2 (license) then invariant 3 (measured delta) |
| MCP / tool output | **open; the MCP eval decides** (Headroom lead candidate, Apache-2.0), with token-optimizer-mcp as TAKE-PARTS comparator (PolyForm-NC = personal-internal ceiling, never redistributed) | adoption gate = measured token delta on a real himmel workday + outcome-per-session verdict |
| Stable prefixes (prompt cache) | **owner = the operator** (as `/morning-report` reviewer), responder path below | cheapest lever, least instrumented. **monitored by `scripts/eval/cache-health-cadence.sh`** (HIMMEL-5672, [`docs/internals/cache-health.md`](internals/cache-health.md)): hourly, no model, per-role hit rate against a 7-day baseline, one Telegram + chief message only on a real threshold crossing (baseline 2026-10-14: 97.9 % overall, chiefs 99.3, workers 97.8, subagents 94.9). The circulating 76.5% read-ratio / "<40% = structural issue" figures are one-tweet heuristics from someone else's workspace, flagged non-representative by the source note itself; himmel's own read-ratio was first measured 2026-09-29: 98.2% over 1,210 session first-turns and 36.0G tokens of a single project's transcripts (`scripts/eval/cache-probe.sh first-turn`, [`docs/internals/prompt-cache.md`](internals/prompt-cache.md)) |
| Context bloat | **CLAUDE.md hygiene** | with the Vercel passive-beats-on-demand caveat baked into its acceptance (always-on beat on-demand 100% vs 79% for general knowledge; don't blanket-move content out of always-on) |
| Whole task (routing) | **lane selection** ([`lane-calibration.md`](internals/lane-calibration.md)); this doc only states the policy: trivial→cheap is the biggest lever | seam: this doc = policy + measurement bar; lane selection = mechanism (lane table, model defaults, fallback chains) |
| Downgraded bulk output (validation) | **the sampling rule** (below) | every downgraded task class names its validation sampling rule: rate, judge, escalation trigger (sampled failure ⇒ batch escalates to the frontier lane). Proposed as an acceptance criterion on the bulk-downgrade routing work; cheap routing that silently degrades outcome-per-session is the named failure |

### Prompt-cache responder path (owner: operator)

Once the cache-monitor follow-up establishes a himmel-measured baseline: investigate when
read-ratio trends **materially below that baseline sustained over ≥3 days**
(single-day dips after idle/fresh sessions are known false positives).
Responder action = file a context-hygiene investigation ticket
(context-bloat shaped). Until then this boundary is explicitly unmonitored.

### Downgrade-safety

Cheap-lane bulk work (the downgraded task classes: clip-filling,
mechanical sweeps) is validated by **SAMPLING, not 100% review**, because
reviewing every output of a cheap batch erases the savings that justified the
downgrade.
The downgrade-safety loop is: cheap lane executes → a sampled subset is
validated → a sampled failure **escalates the whole batch to the frontier
lane**. So every downgraded task class MUST name its sampling rule (the
**rate**, the **judge**, and the **escalation trigger**), or it is not
eligible for the cheap lane (proposed as an acceptance criterion).
The validation MECHANICS (the critic panel, diversity, the correctness
ledger) belong to the review stack; gate PLACEMENT (where the sampling gate
sits in a workflow, PASS/FAIL, human checkpoints) is set in
[`validation-gates.md`](internals/validation-gates.md). This page states the
pattern and the criterion, not a sampling harness: no bulk cheap lane is live
to sample.

## Invariants (normative)

1. **One optimizer owns each boundary.** Two tools on one boundary = pick
   the stronger, disable the other. Concretely: any router or proxy
   deployment MUST disable its whole bundled compression stack;
   himmel owns the dev-output boundary with RTK, and no other optimizer may
   claim a boundary without clearing invariant 3.
2. **License gate precedes measurement gate.** NOASSERTION / non-OSI /
   noncommercial licenses are REJECT-for-adoption on himmel's public MIT
   path; at most personal-internal pilot, never wired into shipped config.
   Current casualties: context-mode (NOASSERTION), token-optimizer-mcp
   (PolyForm-NC; TAKE-PARTS comparator only).
3. **Measurement gate (boundary-owner CHANGES).** Every change requires a
   measured token delta on a real himmel session AND an outcome-per-session
   verdict. Vendor percentages are never sufficient. **Incumbent
   grandfathering is explicit:** RTK predates this
   gate and keeps its boundary, but carries a re-measure obligation via
   measure-during telemetry once the telemetry record format ships (tracked
   in the sequencing comment).

## Decision records

- **Dev-command contest (decided 2026-07-02):** RTK keeps the boundary.
  context-mode REJECT-while-unlicensed (18.4k★ and a 98% vendor claim do
  not clear the license gate). Evidence snapshot: RTK Apache-2.0/67.9k★
  active; context-mode NOASSERTION as of 2026-07-02. Reversal protocol:
  OSI license + a measured win over RTK.
- **MCP/tool-output contest (protocol, decision deferred by design):**
  license gate → measured eval (Headroom Apache-2.0/55.8k★ lead
  vs rtk incumbent), token-optimizer-mcp as comparator. The eval ticket owns the
  verdict; this doc records the protocol so the decision is reproducible.
- **Lane compliance (2026-07-03):** panel/router lanes terminate PER-TOKEN
  keys only; subscription lanes (ToS-restricted to officially supported
  tools) are launcher-only, and Claude Code qualifies as a launcher.

## Measured preload deltas

Session-start preload is a boundary like any other, so a change to it owes
invariant 3 a measured delta. Numbers land here; the method is restated with
them so a later re-measure is reproducible.

### `inject-initiative.sh` → pointer form (measured 2026-08-23)

**Method.** Byte-sum of the hook's own stdout (the exact string the SessionStart
chain injects) per auto-ship step set, on this machine, both harnesses (Claude Code
`.claude/settings.json` and Codex `.codex/hooks.json` run the same script):

```bash
printf '{}' | HIMMEL_INITIATIVE=all bash scripts/hooks/inject-initiative.sh | wc -c
```

Before-figures come from the pre-change script (`git show <base>:scripts/hooks/inject-initiative.sh`)
run the same way, with `HIMMEL_REPO` pointed at an empty dir so no local `.env`
perturbs the auto-ship step set. This is the same listing-sum method as the
2026-08-22 context-preload audit, narrowed to the one block that changed.

| Auto-ship step set | Before (B) | After (B) | Delta |
|---|---:|---:|---:|
| `prcheck,pr` | 1,707 | 350 | −1,357 (−80%) |
| `all` (interactive: 4 auto-ship steps) | 1,803 | 366 | −1,437 (−80%) |
| `all` (overnight: 6 auto-ship steps) | 2,477 | 376 | −2,101 (−85%) |
| all 8 auto-ship steps (widest) | 3,155 | 378 | −2,777 (−88%) |

After-figures are for a **canonical install** (a primary checkout, whose
absolute runbook path is 74 B on the reference machine), computed as
`fixed content + 74`, where *fixed content* is the emitted bytes minus the
emitted path. That path is the only variable term. It is absolute because the
hook is wired at user scope and reads the himmel clone's `.env`, so a session
started in another repo can be initiative-active and a repo-relative path would
not resolve there; a worktree under `.claude/worktrees/<branch-slug>/` then pays
~62 B more for byte-identical pointer content, which is a property of where the
checkout lives, not of the pointer. The budget assertion therefore bounds the
fixed content at `400 − 74 = 326 B`, so a canonical install always fits the
400 B acceptance criterion, and reports the raw total alongside, so an
unusually long path stays visible without failing the budget.

Paid on **both** harnesses, on every session start the gate is on, whether or not
a completion point is ever reached, so the operator's overnight profile saves
~2.2 KB × 2 per session. The step bodies moved to
[`scripts/hooks/initiative-runbook.md`](../scripts/hooks/initiative-runbook.md);
the enforcement sentence and the no-merge guard stayed inline because a rail is
not a lookup.

**The saving comes from the read TRIGGER as well as the move.** A pointer that said
"read the runbook first" would defer the 3.1 KB to the first turn rather than
remove it. The pointer instead names the two moments the bodies are needed (a
natural completion point, and a handover resume when the tasklist-seed section
applies), so an ordinary session never opens the file at all.

**What could NOT be deferred is the directive itself.** "At a completion point,
run them unasked" is what makes a session recognise a completion point; behind
the read trigger it would never fire, and the whole feature would vanish with no
error, the failure mode the audit named as this change's real risk. One inline
line carries it; only the step BODIES are deferred. The budget assertion in
`scripts/hooks/test-inject-initiative.sh` (test 27) holds the line, and test 28
fails if a runbook body creeps back inline.

**Not re-measured here:** the plugin/skill listing blocks. Disabling
`ui-ux-pro-max` + `scroll-world` (audit O1, ~6 KB) is a user-scope operator
action already applied outside this repo, and `security-guidance` is an adopter-
default change (see
[`docs/setup/new-machine.md`](setup/new-machine.md#security-guidance--recommended-off-operator-decision-pending))
with the operator-box decision still pending. Neither changes this machine's
current listing sum.

### Skill/command descriptions → a 120-char cap (measured 2026-08-23)

Audit O4. Every `description:` byte in a skill or command frontmatter is paid on
every session start, and Claude Code's own cap is 1,536 chars, so nothing
truncates and nothing self-limits. himmel's own entries averaged 219 B each.
Capping `description` at **120 chars** and rewriting the 78 over-cap
frontmatters (meaning-preserving, routing/trigger phrase kept, since that
phrase is what the description is *for*) gives:

| Bucket | Entries | Before (chars) | After (chars) | Delta |
|---|---:|---:|---:|---:|
| `.claude/commands/` | 44 | 9,617 | 5,162 | −46% |
| `marketplace/plugins/*/commands/` | 20 | 7,472 | 2,485 | −67% |
| `marketplace/plugins/*/skills/` | 15 | 7,809 | 1,910 | −76% |
| `.agents/skills/` (Codex lane) | 19 | 3,782 | 2,235 | −41% |
| **TOTAL** | **98** | **28,680** | **11,792** | **−59%** |

The three Claude-listing buckets alone go **24,898 → 9,557 chars (24.3 KB →
9.3 KB, −61.6%)**, against the ticket's ≥40% / ≤15 KB acceptance. The Codex lane
pays its own `.agents/skills/` listing, so the 98-entry total is the honest
cross-harness figure. Both are measured with the skill-cost harness
(`scripts/lanes/skill-cost.mjs`), same arithmetic as the audit; its
`project-commands` before-figure reproduces the audit's 9,617 B to the byte.

`--max-desc <n> <paths…>` on that same script is the gate, wired twice: the
`skill-description-cap` pre-commit hook over the staged frontmatter paths, and a
`doc-invariants` CI step over the whole tracked set (`git ls-files`), because the
pre-commit hook is blind to anything that arrived through a bypass. It names the
offending file and its length and exits 1.

**No cap on `when_to_use`, and none needed:** himmel uses the field in zero
entries; the audit's warning about it came from measuring other harnesses.
`argument-hint` is likewise untouched: it is a completion affordance, not a
routing signal, and it was not the offender.

**The risk is in routing.** A description that stops being *selected*
costs far more than it saved, and there is no automated routing check to prove
otherwise: `/skill-find` and the golden-profile fixtures cover the index and
plugin resolution, not selection quality. The mitigation is in the rewrite rule:
the trigger phrase survives; what was cut is restatement of the body (mechanism,
ticket IDs, wrapper plumbing, sub-flag enumerations) that a reader only needs
*after* the skill is already selected.

### `CLAUDE.md` lean-invoke (measured 2026-08-23)

Audit O5. The root `CLAUDE.md` is the one preload block every harness pays
(Claude Code loads it directly, Codex and Hermes load the `AGENTS.md` generated
from it), and it had grown to 19,018 B. Every rule was re-sorted by layer
(hook/gate → one line naming the enforcer; reference detail → `docs/internals/`;
recovery → the stuck-playbook; general engineering defaults → a user-scope
block installed once by `adopt.sh`/`himmel-update`), and a
pre-commit byte gate (`scripts/ci/check-claude-md-budget.sh`, ≤ 6,144 B since HIMMEL-5512) keeps
it from re-accreting.

**Method.** Tracked bytes straight from the object store (`git show <rev>:<path> | wc -c`)
for the rule files; the skill/command listing rows reuse the skill/command description figures
above (name + description chars, `scripts/lanes/skill-cost.mjs` arithmetic) so
the two audits add without double counting. Tokens are estimated at 4 B/token,
the same divisor `skill-cost.mjs` prints. "Before" is `main@6215f5e8`, the last
commit before the description cap landed; "after" is this branch.

| Harness | Always-loaded set (himmel's share) | Before (B) | After (B) | Delta | ≈ tokens |
|---|---|---:|---:|---:|---|
| Claude Code | `CLAUDE.md` (file total) | 19,018 | 12,310 | −6,708 (−35.3%) | ~4,750 → ~3,080 |
| Claude Code | + skill/command listing (2037) | 24,898 | 9,557 | −15,341 (−61.6%) | ~6,220 → ~2,390 |
| **Claude Code total** | | **43,916** | **21,867** | **−22,049 (−50.2%)** | **~10,980 → ~5,470** |
| Codex | `AGENTS.md` (generated, total) | 20,851 | 14,143 | −6,708 (−32.2%) | ~5,210 → ~3,540 |
| Codex | + `.agents/skills/` listing (2037) | 3,782 | 2,235 | −1,547 (−40.9%) | ~950 → ~560 |
| **Codex total** | | **24,633** | **16,378** | **−8,255 (−33.5%)** | **~6,160 → ~4,090** |
| Hermes | `AGENTS.md` (generated, total) | 20,851 | 14,143 | −6,708 (−32.2%) | ~5,210 → ~3,540 |

Of the 12,310 B file, **11,537 B is himmel content** (what the budget gate
held ≤ 12,288 B at the time; the limit is now 6,144 B) and **773 B is the upstream-owned `## graphify` section**,
excluded from the budget (see below). The `CLAUDE.md` lean-invoke share alone is the
`CLAUDE.md`/`AGENTS.md` rows: **−6,708 B on every session of every harness.**
On the operator's own machine the working principles were paid *twice* before
(user-scope `~/.claude/CLAUDE.md` and the project file both state them); now
once.

**What could NOT be demoted is the directive itself.** Each rule that is
structurally enforced kept its one-line directive and gained the enforcer's
name (`block-edit-on-main`, `check-push-target`, `orchestrator-inline-guard`, …);
only the rationale and recovery detail moved. The session-critical paragraph
(hook bypass = launching-shell env, `.single-writer`), the RETASK rule, the
Jira absolute-path invocation, the qmd `--collections` trap and the egress
clause stayed inline verbatim, because a directive behind a lookup is a dead
directive.

**The `## graphify` section stays as verbatim upstream text (operator ruling
2026-08-23).** `graphify install --platform claude` writes a stock `## graphify`
section into the project `CLAUDE.md` on every run (`graphifyy`
`install.py: claude_install` → `_replace_or_append_section`: replace the
section in place if a line is exactly `## graphify`, else append at EOF), and
it is the same command that upgrades the hook-guard hooks and the user skill,
so it recurs. After such a run, re-apply himmel's hook pricing with
`bash scripts/lib/graphify-bin.sh price-hooks`, because the installer
restores the stock four-tool, no-timeout entries. The section is therefore **upstream-owned**: himmel keeps exactly
what the installer writes, unmodified, so a reinstall or upgrade is a no-op
(or a clean upstream text bump), never a conflict. himmel's own rules live
entirely OUTSIDE the section; where they conflict, the RULES above it win. The budget gate
(`scripts/ci/check-claude-md-budget.sh`) counts ONLY himmel's bytes (it
excludes the section using the installer's own boundary rule) and asserts
exactly one section (zero = anchor deleted, hint to reinstall; duplicates never
self-heal because the installer replaces only the last). Proven against the
real installer: `scripts/ci/test-check-claude-md-budget.sh` Case H runs
graphifyy's `claude_install` over the committed file: byte-identical result,
one section, gate green.

**Behavioural half: not yet run.** Fewer bytes is only half the claim; the
other half is that a fresh session still refuses to commit on main, still routes
Jira through the CLI, still reaches for `graphify query` on a structure
question. The with/without recipe (arms, probes, metrics, acceptance) is in
[`docs/internals/token-economy-bench.md`](internals/token-economy-bench.md); it
needs a quiet subscription usage budget window, so it runs post-merge and its numbers land here.

## Pointers

- Open eval boundaries: MCP boundary owner, token-optimizer-mcp comparator,
  context bloat, cache data source, routing policy input, router mechanism,
  validation-lane sampling.
- Tooling inventory: [`docs/tooling-catalog.md`](tooling-catalog.md).
- Adoption method: [`docs/tool-adoption/rubric.md`](tool-adoption/rubric.md).
