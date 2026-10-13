# Glossary

The one place himmel's fleet vocabulary is defined. Everything else — templates, prefaces, command
files, guard messages, internals docs — links here instead of restating a
definition, because a term defined in two places drifts.

It holds two vocabularies: the fleet lexicon (sessions and their roles, below)
and the [harness wiring lexicon](#harness-wiring-lexicon) (the hooks, gates and
scripts that enforce the rules), with an [overlap map](#overlap-map) of which
layers enforce each invariant. Per-hook behaviour lives in
[`internals/enforcement.md`](internals/enforcement.md), not here.

## The lexicon

| Term | Meaning |
|---|---|
| **CR** | Code review — the pre-PR review gate and everything named for it: the CR marker, the CR ledger, the critic panel, `/pr-check` (operator ruling, 2026-09-24). CodeRabbit is one best-effort CI reviewer inside that gate and is always spelled out, never abbreviated CR. |
| **Console** | The operator's chief of staff: a persistent, operator-facing session that owns the shift. It holds the queue lock on its own document, the GO authority and the nonce mint. It dispatches legs, watches the fleet, acts on rulings and merges on GO, and does no implementation itself. `/console new` starts one. |
| **Judge** | A clean session, headed or headless, spawned for one question, sometimes on a deliberately thin brief. **Advisory: it rules, the console acts.** Several may run in parallel on one question with different scopes. Two shapes — see [Judge: call and session](#judge-call-and-session). |
| **Consolidator** | Combines several judges' outputs into one reconciled answer, so the console does not absorb N judgments. A lexicon term only: nothing in the repo implements it yet. |
| **Relay** | Transport. Receives and moves messages and owns the machine wakes. Also called the *communicator* in the design spec; the code name is `relay`. It is launched as a leg of the console (`headed-arm-leg.sh --relay`), never as a console. |
| **Leg** | A working item: one ticket, one worktree, one brief, one PR. A leg has *kinds*: a work leg (implements and ships), a relay leg, and a judge leg. `HIMMEL_CONSOLE_LEG` marks every console-spawned session of any kind. |
| **Chain** | A set of work: an ordered sequence of legs that belong together. |
| **Wave** | A bulk of legs dispatched together — the unit that collision-checking, single-writer and `HIMMEL_FLEET_CAP` apply to. |
| **Arming** | Launching a headed or headless session on a schedule (`arm-resume.sh`, `headed-arm.sh`, `/console new --arm`). |
| **Manual override** | An ad-hoc operator-side session — a whiteboard. It passes work to the console as a ticket and a brief, never as a relayed ruling. |
| **Succession** | One console handing over to the next: the outgoing console arms its successor and writes a HANDOFF (`/console next`). Not a chain — a chain is legs. |
| **himmel-bus** | The local, hash-chained message bus between a console and its legs (`marketplace/plugins/himmel-bus`). Delivery is by hook (`bus-deliver-hook`), and a message is a ruling only under a `from` header from the receiver's registered console (see [RETASK §3b](internals/retask-channel.md)). It is not the Telegram bridge (`scripts/telegram/bus.ts` is that bridge's own store, which himmel-bus reuses for storage only) and not the file inbox (`inbox-send.sh`, the `handovers/inbox/` files), which stays the fallback transport. |

**Not roles.** *Orchestrator* is a rule (`orchestrator-inline-guard`: a
top-tier parent must not implement inline), not a session role; the word also
names a script (`scripts/clean-garden.sh`) and CI components. *Conductor* is
the cross-project layer, not a role in this fleet.

## Plain names

The headwords in this glossary keep the repo's own names, because ids, env
vars, file names, flags and command names use them (`/console`,
`HIMMEL_CONSOLE_LEG`, `go.sh`). In prose for people, use the plain name. The old
name is the alias: say it once, the first time, in brackets.

| Plain name | Old name (alias) | Notes |
|---|---|---|
| **supervisor session** | console | Never a bare "supervisor": `scripts/telegram/supervisor.ts` is a process keeper. |
| **worker session** | leg | Fleet sense only. A lane worker or a dispatched subagent worker is a different thing. |
| **auto-ship step** | leg (initiative sense) | A step `HIMMEL_INITIATIVE` takes by itself, such as prcheck or merge. |
| **judge subagent** | judge call | A judge session stays "judge session". |
| **ticket sequence** | chain (fleet sense) | The hook chain and the RETASK chain keep "chain". |
| **batch** | wave | `batch mode` in a cadence script and a ledger batch row are other senses. |
| **subscription usage budget** | bank | `PARKED-BANK` and the `CADENCE_BANK_*` variables keep their names. |
| **weekly budget override** | bank lift | |
| **automated review** | CR, code review | The pre-PR critic panel. A human read of the PR is "human review". |
| **review-owed marker** | CR marker | |
| **finding status** | verdict (of a CR finding) | A judge verdict stays "judge verdict". |
| **sibling sweep** | class sweep | |
| **review round** / **diff-only round** | round / delta round | Docs only. The printed `pr-check:` line is unchanged. |
| **GO file (merge approval)** | GO file | The other GO is written "judge verdict GO". |
| **off switch** | bypass flag | Never "bypass" alone: `bypassPermissions` is a different thing. |
| **sanctioned script** | chokepoint | Docs only. |
| **warn-only** | advisory | |
| **worker system prompt** | preface | There are five prefaces (leg, leg claudex, leg openrouter, judge, consult). |
| **side session** | manual override | |
| **usage-cap auto-relaunch** | watchdog | Only where the README, getting-started and why-himmel mean the auto-arm hooks. A wall-clock killer is a "run timeout". |
| **AFK (unattended) mode** | overnight mode | `/overnight-shift` and `overnight-mode.md` keep their names. |
| **soft block (speed bump)** | speed bump | Stops only the accidental form. |

Not renamed on purpose: handover (the command, the directory and the doc keep
the word; "handoff" already has four senses), attestation trailer ("trailer" is
git's own term), floor, anchor, arm, lane, queue lock.

## Who holds what

| Authority | Console | Judge session | Judge call | Relay | Work leg |
|---|---|---|---|---|---|
| Queue lock on the **console** document | yes | no | no | no | no |
| Queue lock on its **own** document | yes | yes | no (in-process child: no document, no lock) | yes | yes |
| Run `go.sh` (write a GO) | yes | no | no | no | no |
| Mint a nonce, send a token-quoting message (`inbox-send.sh --token`) | yes | no | no | no | no |
| Send tokenless messages (narrowing, halt, RUN notes) | yes | no | no | yes | to its console |
| Rule on a question | acts on the ruling | rules, advisory | rules, advisory | never | escalates |

A judge leg is a leg kind, so a judge session inherits the leg guards; a judge
call runs inside the caller's process and holds nothing of its own.

`go.sh` refuses under `HIMMEL_CONSOLE_LEG` (every console-spawned session) and
under `HIMMEL_CONSOLE_RELAY`; `inbox-send.sh` refuses `--token` under
`HIMMEL_CONSOLE_RELAY`. The RETASK channel that these nonces belong to is in
[`internals/retask-channel.md`](internals/retask-channel.md).

## Judge: call and session

A judge is a **leg kind**: a *judge leg*. A judge session is launched by the
leg launcher (`console-kit/headed-arm-leg.sh --judge`), runs under the leg
guards, and carries the same `HIMMEL_CONSOLE_LEG` identity variable as any leg, plus a
`HIMMEL_CONSOLE_JUDGE` identity variable that `scripts/hooks/guard-judge-writes.sh` reads
to confine its writes to its own doc and qid; it cannot write its
own GO. What differs from a
work leg is the job: it reads, verifies, writes one verdict file and stops. It
does not implement, push or merge.

| Shape | What it is | Brief |
|---|---|---|
| judge **session** | a judge leg with its own worktree, queue lock and lifecycle; survives past one turn | [`handover/judge-brief-template.md`](handover/judge-brief-template.md), verdict per [`handover/verdict-template.md`](handover/verdict-template.md) |
| judge **call** | an in-process child (`.claude/agents/console-judge-ro.md`, or `console-judge.md`) for one question that fits in one dispatch | the dispatch prompt |

The console template records which shape asked each question as
`grade: call|session`.

## Session-name suffix contract

Session names carry the role, and tooling reads it back:

| Name contains | Meaning |
|---|---|
| `-console` | a console (`<PREFIX>-nextleg-<date><letter>-console`) |
| `-relay` | a relay leg |
| `-N<k>-` | a leg (session `<TICKET>-N<k>-<slug>`, doc `<TICKET>-N<k>-<slug>-<date>-RESUME.md`, label `N<k>`, a successor `N<k>b` is a distinct session; the legacy `…-leg[N]<k>-…` doc spelling is still read — `scripts/lib/leg-identity.sh`) |
| `-judge-<qid>` | a judge session (`HIMMEL-<ticket>-judge-<qid>`) |

The scorecard classifiers (`scripts/lanes/bench/scorecard/`) read a leg from
`scripts/lib/leg-identity.sh` (so a leg whose slug says `console` is still a
leg), key a console and a relay on the `-console` and `-relay` substrings, and
count an untitled session as `unattributed`; `verdict-template.md` keys on
`-judge-<qid>`. Renaming a suffix silently misclassifies burn data.

## Lane

A **lane** is a dispatch backend a leg or subagent runs on (`--lane
native|claudex`, the Codex lane, the critic and bulk lanes); `/lanes` prints
the set available on this machine. It is not a role, and not a wave.

## Industry terms

Where a himmel word maps onto a term in the
[Dictionary of AI Coding](https://github.com/mattpocock/dictionary-of-ai-coding), this row links to it instead of redefining it.

| Dictionary term | In himmel |
|---|---|
| Automated check | A gate: a hook, a pre-commit or pre-push check, a CI job. Deterministic, pass or fail. |
| Automated review | The critic panel and `/pr-check`. An agent reviews another agent's work, so it is not deterministic and it is not a check. |
| Human review | The operator reading a PR. Write it out, never "CR". |
| Handoff, handoff artifact | A handover doc, a RESUME doc or a HANDOFF file. The artifact is a secondary source: verify it against the code. |
| Compaction, autocompact | The summary Claude Code writes when the context fills. `Compact instructions` in `CLAUDE.md` steer it. |
| AFK | A session left unattended. Overnight mode and arming are two ways to start one. |
| Subagent | A judge call or an `Agent` dispatch. In the dictionary a subagent cannot spawn another; himmel allows deeper trees under the spawn-depth cap in the environment. |
| Progressive disclosure | Lean-invoke: a slash command run on demand instead of an always-loaded rule. |
| Smart zone, attention degradation | Why a leg hands off before its context is full (`internals/leg-context-guard.md`). |
| Primary source, secondary source | The code and tests are primary. A handover doc or a memory line is secondary. |
| Software factory | What himmel is: sessions started by triggers, with at least one human approval per PR. It is not a dark factory, which has no human step. |
| AX | `internals/context-architecture.md`: what a session sees, what loads always and what loads on demand. |
| Memory system | `MEMORY.md` plus its topic files. The index routes; it does not store. |

## Same word, different thing

Some words in this glossary also have a second sense somewhere else in the repo.
The rows below are the ones that still do. Senses that were renamed to avoid a
collision are not listed: they now use the new wording.

| Word | What it means in this glossary | Other things it is used for | How to tell which one |
|---|---|---|---|
| **judge** | A judge leg: a session or an in-process child that rules on one question. A review by the CR critic panel is a "panel review", and an independent check in the token-economy docs is a "validator". | `follow-judge`, the judge pass of the X follow-list scorer. It is being renamed to follow-scorer (ticket to come). | A judge leg writes a verdict file for the console. The follow-list judge pass scores one account and feeds a queue. The charter is `marketplace/plugins/obsidian-triage/tools/follow-judge-charter.md` and the queue is `_judge-queue.jsonl`. |
| **chain** | An ordered sequence of legs that belong together. | A serial hook chain, and the `--chain` flag of the hook runner. | Legs mean the fleet sense. Hooks mean the other. The hook sense is in `architecture.md` and `harness-compat.md`. |
| **armed** | Arming: launching a session on a schedule. | Opt-in auto-merge (`ARMAUTOMERGE`). That use of "armed" is kept on purpose. Starting a Monitor loop is no longer called arming, and the tick now runs in `console-wait.sh`. | A session or a schedule means arming. A PR merge means the other. |
| **orchestrator** / **coordinator** | Not session roles. Orchestrator is a rule, `orchestrator-inline-guard`. | The external pattern catalog's names for the parent session. The CI orchestrator daemon. | A hook name means the rule. A pattern description means the catalog. A CI run means the daemon. The catalog is `orchestration-patterns.md` and the daemon is `scripts/ci-orchestrator`. |
| **GO** | The console's GO file that authorises one merge. | A judge verdict `GO` or `NO-GO`, written by `write-verdict.sh`. It is one input the console reads before it signs a GO file. | In prose write "judge verdict GO" for the verdict and "GO file" for the merge authorisation. The verdict format is in `handover/verdict-template.md`. |
| **supervisor** | In the plain names, always "supervisor session": the console. | `scripts/telegram/supervisor.ts`, the process that keeps the Telegram poller alive. Also a generic "external timeout or supervisor" in the shell docs. | A session means the console. A bun process or a restart loop means the other. |
| **worker** | In the plain names, "worker session": a leg. | A lane worker, a dispatched subagent worker (`internals/worker-spawn-matrix.md`) and a Codex lane worker. | "Session" after the word means a leg. A dispatch or a lane means the other. |
| **batch** | In the plain names, a group of worker sessions started together (formerly a wave). | `batch mode` in a scheduled script, a ledger batch row, a panel batch spec. | A fleet doc means the group of sessions. A script flag or a ledger means the other. |
| **handoff** | A session passing its work to another: a handover doc, a RESUME doc, a HANDOFF file. | A scope handoff, a launch handoff, and the anchor handoff (`anchor-handoff.sh`). | The fleet docs mean the document. A launcher or a gate script means the other. |

## Harness wiring lexicon

The words the enforcement surface uses: deny messages, `scripts/hooks/`
headers and [`internals/enforcement.md`](internals/enforcement.md) (HIMMEL-5419).
One definition per term; a word under *Avoid* is a synonym to replace with the
canonical term. Script names without a directory live in `scripts/hooks/`.

### Mechanisms

| Term | Meaning | Avoid |
|---|---|---|
| **Hook** | A script an event runs. Six homes: a Claude Code hook (`.claude/settings.json`), a plugin hook (`marketplace/plugins/himmel-ops/hooks/hooks.json`), a Codex hook (`.codex/hooks.json`, through `.codex/run-hook.sh`), a git hook staged by `.pre-commit-config.yaml` (pre-commit, commit-msg, pre-push), the installed `reference-transaction` shim (`install-main-ref-transaction.sh`), and the installed single-writer `pre-push` shim (`install-single-writer-floor.sh`, which runs `check-single-writer-push-floor.sh`). The `i-have-adhd`, `lean-skills` and `qmd` plugins carry their own `hooks/hooks.json` too. Two homes sit outside those files: the `rtk hook claude` PreToolUse rewriter that `rtk init -g` registers in the user's `~/.claude/settings.json`, and the Hermes `parity_guard.py` hook that `scripts/hermes/assets/wire_parity_guard.py` wires into a Hermes profile. `SessionEnd` and `Stop` are events inside the homes above, not homes of their own. | trigger |
| **Wirer / inventory** | The two scripts that write hook entries, each from its own hand-kept ordered list (the inventory): `wire-hook-bash.mjs` (`EXPECTED_SCRIPT_ORDER`, into `.claude/settings.json`) and `wire-plugin-hook-bash.mjs` (`EXPECTED_HOOKS`, into the himmel-ops `hooks.json`). A wirer run installs an inventory entry its target lacks. | hook list |
| **Impostor** | A `scripts/hooks/*.sh` call under an event the wirer owns (`PreToolUse`, `PostToolUse`, `SessionStart`) that its inventory does not list; `wire-hook-bash.mjs` refuses it (HIMMEL-1552). | — |
| **Hook runner** | `run-hook-with-bash.js`: runs one hook, or a `--chain` of them in one process, under the right bash on every platform. The Codex twin is `.codex/run-hook.sh`. | wrapper |
| **Guard** | A PreToolUse hook that can deny a tool call before it runs (`block-*`, `guard-*`). It judges the call's text, not its effect. A `guard-` prefix or a "guard" in a file name does not mean this role: `stop-console-idle-guard.sh` is a Stop hook, `check-doc-guard.sh` is a pre-commit and pre-push gate, and `parity_guard.py` is a Hermes hook. | gate (for a session hook) |
| **Gate** | A check that stops work moving to its next stage: a git hook (commit, push), a CI job, or a precondition inside a chokepoint (the CR gate, the CI-green gate, the GO gate). | guard (for a git or CI check) |
| **Fence** | A guard that confines writes or egress to an allowed set and that the session cannot lift (the terminal write-fence, the egress fences, the judge write fence). It fails closed. | wall |
| **Speed bump** | A guard documented as stopping only the accidental shape; a determined caller can route around it (`block-himmel-config-writes.sh`, `guard-bus-store.sh`). Its header says so. | fence |
| **Floor** | The deterministic minimum that still holds when every other layer is absent: the destructive-command floor (`block-destructive-commands.sh`, shared by Claude and Codex) and the single-writer force-push floor (`check-single-writer-push-floor.sh`). | baseline |
| **Gate integrity** | A gate's own collaborators are fixed paths, never environment seams, so a contaminated environment cannot forge the evidence it reads. `clear-cr-marker.sh` and `merge-on-green.sh` carry a `GATE INTEGRITY` note: the CR ledger path, `check-ci.sh` and `gh` are not overridable there. | — |
| **Advisory** | A hook or check that prints and never blocks (exit 0): `scripts/cr/doc-freshness-advisory.sh`, `graphify-freshness-advisory.sh`, `jira-nudge-on-end.sh`, the `api` backend tier. | soft gate |
| **Nudge** | A hook that steers a habit rather than protecting a secret or a checkout (`require-quiet-run.sh`, `guard-leg-wakeup.sh`, `jira-nudge-on-end`, `inject-worktree-nudge`). Advisory-only versus may-deny is a separate axis, so both kinds count: some only print, some deny. A denying nudge fails open on its own errors (missing `jq`, unparsed input). Its opposite is a security fence, which fails closed. | — |
| **Watchdog** | A hook that watches a resource and acts on its own, deliberately fail-open: `auto-arm-on-cap.sh` and `auto-arm-on-subagent-cap.sh` arm a resume as a usage cap nears and block once to force a handover (off with `AUTO_ARM_DISABLE=1`). | monitor |
| **Chokepoint** | The one sanctioned script for a privileged action, registered with its seam variables in `scripts/chokepoints.json` (`merge-on-green.sh`, `clear-cr-marker.sh`, the codex dispatchers). Agents run it by its literal path. | wrapper, helper |
| **Seam variable** | An environment variable a chokepoint reads as a test seam or opt-in. Set only in the launching shell; a per-call `VAR=` prefix on a chokepoint is denied (`block-chokepoint-env-prefix.sh`). | override |
| **Bypass flag** | An environment variable that switches one guard off for a whole session, set in the launching shell (`EDIT_ON_MAIN_OK=1 claude`); a per-call prefix never reaches a hook process. Registry: `scripts/himmelctl/lib/bypass-flags.json`. | escape hatch |
| **Fail-open / fail-closed** | What a guard does when it cannot evaluate (missing `jq`, unparsable input): allow, or deny. Hygiene guards fail open, fences fail closed; `check-fail-open-lint.sh` lints the shape. | — |
| **Classifier** | Claude Code's auto-mode permission classifier: model judgement on a call no allow rule matched, denying by named category (`[CI Bypass]`, `[Merge Without Review]`, `[Out-of-Place Publication]`). Not a himmel script; `log-classifier-denial.sh` records its denials. Codex has none, and `block-terminal-write-fence.sh` stands in for it there. | the guard |
| **Allow rule** | A literal entry the native permission matcher compares against the command *text*. A `VAR=` prefix, a quote, `$(…)` or a compound drops the call to the classifier; `auto-approve-safe-bash.sh` approves the shapes the matcher refuses. | whitelist |
| **Hook integrity** | Every guard script pinned to its committed blob hash at session start (`record-hook-integrity.sh`); a pinned guard edited mid-session locks tool use. | — |
| **Shadow ledger** | `scripts/trust/shadow-ledger.mjs`: a passive, hash-chained record of every approval-shaped decision. It records and never denies. | audit log |
| **Trust path** | A path matching `scripts/ci/ci-trust-paths.txt` (CI, the merge gate and their helpers). A PR touching one merges through `merge-on-green.sh` only on a trust-reviewed GO (`go.sh --trust-reviewed`); the list is read from the default branch, never the PR. | protected file |

### Places and identity

| Term | Meaning | Avoid |
|---|---|---|
| **Primary checkout** | The repo's main working tree, the directory holding `.git`. No feature edits land there. | main repo, root checkout |
| **Worktree isolation** | The rule that feature work happens in a worktree (`.claude/worktrees/<slug>`), never on `main` in the primary checkout. | — |
| **Anchor** | The primary checkout's absolute path, from which gate writers run. `scripts/cr/anchor-handoff.sh` hands a relative entry over to the anchor's copy, so bytes a branch controls never run as the gate. | — |
| **Single-writer** | The rule: one writer per shared artifact, many readers. | — |
| **`.single-writer`** | A gitignored sentinel file at a repo root that lets that repo commit on `main` by design (vaults, state repos); clones without it stay protected. | — |
| **`.himmel-dev`** | A sentinel file that turns on the contributor-only gates (doc-guard, the doc invariants) in a checkout. | — |
| **Queue lock** | `scripts/handover/queue-lock.sh`: one writer per handover document; acquiring prints the release token. | mutex |

### Review and merge

| Term | Meaning | Avoid |
|---|---|---|
| **CR marker** | The untracked file `.git/cr-pending/<branch>` that pre-push `check-cr-before-push.sh` writes. While it exists, `gh pr create` is denied (`check-cr-marker-on-pr-create.sh`); only `clear-cr-marker.sh` removes it. | review flag |
| **CR ledger** | `<git-common-dir>/cr-critic-scores.jsonl`: one row per critic that responded at a head. `clear-cr-marker.sh` and ready-check item 4 read it. | review log |
| **Verdict (CR)** | One disposition per review finding. `scripts/cr/write-verdicts.sh` writes `agreed`, `disproved`, `conflict` (evidence both agrees and disproves), `unaddressed` (no verdict reached; blocks) or `deferred -> <TICKET>` (a bare `deferred` is refused); it never writes `fixed`. `fixed` comes from `review-round.sh promote`, which amends an `agreed` row on a clean round (`clear-cr-marker.sh` gate 4c runs it), or from `ledger-append.sh --set verdict=fixed`. Terminal, per `promote`: `fixed`, `disproved`, `deferred`; `agreed` waits for promotion, and `conflict` and `unaddressed` are never promoted. | resolution |
| **Class sweep** | One `SWEEP` line per agreed or fixed finding, naming every site of the finding's class; `clear-cr-marker.sh` refuses without it (`missing-class-sweep`). | — |
| **Round** | One counted panel run on a branch, printed as `pr-check: round N of 3 on <branch>`. A CR round, a panel round and a pr-check round are the same counter. It advances once per panel run, not per critic or retry. | — |
| **Delta round** | The one extra round allowed after round 3, printed as `pr-check: delta round 4 on <branch>`. It reviews only the diff since the last counted head, and only a Critical or escape-class finding blocks. A fourth full round or a second delta round exits 8. | 4th round |
| **Ready-check** | `scripts/handover/console-kit/ready-check.sh`: the numbered pre-GO checks on one PR head (head and merge state, check rollup, threads, CR ledger, trailers, ticket ids, coverage). `go.sh` runs it before it signs. | — |
| **GO / GO file** | The console's merge authorisation for one PR at one head sha, written by `go.sh`. The file *is* the GO: `merge-on-green.sh` refuses (exit 17) a console-spawned leg without it, whatever any message says. | approval |
| **Attestation trailer** | `Platforms tested: <os>` or `Security reviewed: <token>` in a PR's first commit, checked at pre-push and by ready-check item 5. | sign-off |
| **Ticket ID** | The `[KEY-n]` every commit subject and PR title carries. | — |
| **Impacted suites** | The test suites that reference a file a range touches, listed by `scripts/cr/impacted-suites.sh`; PR CI runs only these. | affected tests |

### Fleet plumbing

| Term | Meaning | Avoid |
|---|---|---|
| **Bank** | The subscription usage budget (5-hour and 7-day). `scripts/lib/bank-preflight.sh` prints one verdict token (`PROCEED`, …) and always exits 0. | quota |
| **Bank lift** | `~/.himmel/state/bank-lift.json`, which relaxes the 7-day bank check. Setting it is operator-only; `block-bank-lift-writes.sh` denies every agent write. | — |
| **Plugin profile** | A plugin set a leg launches with (`headed-arm-leg.sh --profile <name>`, defined in `scripts/lanes/plugin-profiles.json`). | — |
| **Preface** | [`handover/leg-preface.md`](handover/leg-preface.md): the rules appended to every leg's system prompt at launch. Five prefaces exist (leg, leg claudex, leg openrouter, judge, consult), so write "leg preface" or "judge preface", never a bare "preface". | system prompt |
| **Brief** | In this glossary, the per-leg header of a handover document, not a task prompt (`brief.md` and `--brief-file` name whole task prompts). It holds: ticket, worktree, base sha, token, console, contract. The brief wins over the preface where they disagree. | — |
| **Nonce** | The RETASK token minted per child; a revision must quote it ([`internals/retask-channel.md`](internals/retask-channel.md)). | password |
| **Tick** | `scripts/handover/console-kit/tick.sh`: one batched snapshot line of the fleet, read from each leg's newest status-marker bullet. | poll |
| **Waiter** | `scripts/handover/console-kit/console-wait.sh`: the console's one background command, silent until the first real event, then it exits. | monitor loop |
| **Board** | The console board: a generated HTML page of fleet state and leg phases (HIMMEL-3361). | dashboard |
| **Tracker** | The ticket backend a run uses, `TRACKER=jira\|local\|none` ([configuration](configuration.md); HIMMEL-4759). | — |
| **Status marker** | The leading word of a leg's Results bullet (`LIVE`, `FINDING`, `RESOLVED`, `READY`, `BLOCKED`, `HALTED`, `WRAPPED`, `PARKED-BANK`, `RESUMED`), written by `scripts/handover/console-kit/append-results.sh`. | state |
| **Ponytail comment** | A `ponytail: <ceiling>, <upgrade path>` code comment for a deliberate simplification ([`internals/ponytail-convention.md`](internals/ponytail-convention.md)). | TODO |
| **Backend tier** | The CLI-over-MCP routing registry `scripts/backends.json`, enforced by `block-backend-tier.sh`. | — |

### Same harness word, different thing

Renamed senses are not listed. A sentinel file is `.single-writer` or
`.himmel-dev`, an identity variable is `HIMMEL_CONSOLE_LEG`, and a ponytail
comment is the `ponytail:` code comment.

| Word | What it means in this glossary | Other things it is used for | How to tell which one |
|---|---|---|---|
| **marker** | Two things: a status marker and the CR marker. | Nothing else now. The other former uses are renamed: sentinel file, identity variable and ponytail comment. | A status marker is the leading word of a Results bullet. The CR marker is an untracked file under `.git/cr-pending/`. |
| **verdict** | One disposition per review finding, written by `write-verdicts.sh`. | A judge's verdict file. The one-word answer `bank-preflight.sh` prints. These are three different objects. | A review verdict sits in the CR ledger. A judge verdict is a file written for one question (`handover/verdict-template.md`). The bank token is script output. |
| **ledger** | The CR ledger, one row per critic that responded at a head. | The shadow ledger, the claudex inbox ledger, and the bank-preflight ledger row. | Name which one. The CR ledger is `cr-critic-scores.jsonl` in the git common dir. |
| **board** | The console board, a generated HTML page of fleet state. | The Jira board, set by `JIRA_BOARD_ID`. The console board does not replace it. | A `JIRA_BOARD_ID` or a Jira URL means the Jira board. |
| **tracker** | The ticket backend a run uses, `TRACKER=jira\|local\|none`. | The roadmap page `tracker.py`, until its rename ticket lands. The version-first roadmap view (HIMMEL-3990). Neither is the `TRACKER` backend. | The `TRACKER` variable means the backend. A page or a ticket means one of the others. The page is `scripts/handover/console-kit/tracker.py`. |
| **profile** | A plugin profile: the plugin set a leg launches with (`--profile <name>`). | An install profile. An MCP profile. `CR_PROFILE`, the critic tier switch (`free,paid`, or `none` to skip the panel). The `himmelctl` install profile (`starter`, `luna`, `operator`, `custom`). The Hermes profile `himmel_agent`. | A `--profile` flag on a leg launcher means the plugin profile. `CR_PROFILE` is an env var read by `scripts/cr/critic-panel.sh` and set in `.env.example`. The `himmelctl` profile is a wizard answer (`docs/setup/new-machine.md`). The Hermes profile is in `docs/hermes-runbook.md`. The others live in `docs/setup/profiles/` and `.claude/mcp-profiles/profiles.json`. |

## Overlap map

One row per enforced invariant, one column per layer, re-derived from the live
wiring files on 2026-10-13 at merged head `610e7c01a` (origin/main `1ab4cacd0`).
A cell names the script; `—` means the layer does not enforce it. Columns:

- **Claude** — `.claude/settings.json` hooks (Pre = PreToolUse, Post = PostToolUse).
- **Plugin** — `marketplace/plugins/himmel-ops/hooks/hooks.json` (Claude sessions with the himmel-ops plugin).
- **Codex** — `.codex/hooks.json`.
- **Git** — `.pre-commit-config.yaml` stages (pc = pre-commit, cm = commit-msg, pp = pre-push) and the installed shims: reference-transaction (rt) and the single-writer pre-push (sw).
- **CI** — `.github/workflows/` jobs and the `scripts/ci/` scripts they run.
- **Kit** — a chokepoint or kit script that refuses on its own.

| Invariant | Claude | Plugin | Codex | Git | CI | Kit |
|---|---|---|---|---|---|---|
| No edits in the primary checkout | `block-edit-on-main`, `block-write-into-main-checkout`; Post `detect-dirty-primary` (reports) | `record-primary-baseline` (records) | `block-edit-on-main`, `block-terminal-write-fence`, `record-primary-baseline`, Post `detect-dirty-primary` | pc `check-worktree-isolation`; rt `check-main-ref-transaction` | — | — |
| No direct push to `main` | none (`permissions.allow` lists bare `git push`) | — | `block-terminal-write-fence` (every push needs `CODEX_EXTERNAL_WRITES_OK=1`) | pp `check-push-target` | — | `merge-on-green.sh` is the merge path |
| No force push | `block-destructive-commands`; `permissions.deny` (`git push --force`, `-f`, `--mirror`) | — | `block-destructive-commands`, `block-terminal-write-fence` | pp `check-no-force-push`; sw `check-single-writer-push-floor` (`.single-writer` repos) | — | — |
| Secrets never read | `block-read-secrets` (Bash, PowerShell, Read, Grep) | — | `block-read-secrets` (Bash, PowerShell, Read, Grep) | — | — | — |
| Secrets never committed | — | — | — | pc `gitleaks`, `leak-classes`, `git-env-scrub` | `secret-scan` (`check-no-secrets.sh`), `security-scan` (gitleaks), `leak-classes`, `git-env-scrub` | — |
| Ticket ID on every commit and PR | — | — | — | cm `check-commit-msg` | `commit-lint` (`check-commit-range.sh`), `pr-title-lint` (`scripts/lib/check-pr-title.sh`) | ready-check item 6 |
| CR before the PR opens | Pre `check-cr-marker-on-pr-create` | — | `check-cr-marker-on-pr-create` | pp `check-cr-before-push` (writes the marker) | — | `clear-cr-marker.sh`, ready-check item 4 |
| Review findings resolved before merge | Post `trigger-cr-on-pr-create`, `trigger-cr-on-push` (request CodeRabbit) | `block-unresolved-cr-merge` (gate 1) | — | pc `check-cr-best-effort` (a text lint: no tracked doc waits on CodeRabbit) | `codeowner-review-gate` (outside PRs only) | ready-check item 3, `merge-on-green.sh` (via `check-ci.sh`) |
| Merge only on green CI and a GO | — | `block-unresolved-cr-merge` (gates 2–3) | `block-terminal-write-fence` (`gh pr merge` needs an opt-in) | pp `check-pr-mergeable` (conflicts only) | — | `go.sh`, `merge-on-green.sh` (exit 17 without the GO file) |
| Trust-path PRs need a trust-reviewed GO | — | `block-unresolved-cr-merge` (gate 4, every session) | — | — | — | `go.sh --trust-reviewed`, `merge-on-green.sh` (both read `ci-trust-paths.txt`) |
| Attestation trailers in the first commit | — | — | — | pp `check-platforms-tested`, `check-security-reviewed`; cm `check-commit-msg` (warns only) | `commit-lint` (first commit, PR events only, through `check-hooks-on-pr-range.sh`) | ready-check item 5 |
| No rogue scheduler job launches `claude` | `block-rogue-claude-schedule` (Bash, PowerShell) | — | `block-rogue-claude-schedule` (Bash, PowerShell) | — | — | — |
| Destructive commands denied | `block-destructive-commands` | `block-docker-privesc` | `block-destructive-commands`, `block-docker-privesc` | — | — | — |
| No `git stash` | `block-git-stash` (Bash, PowerShell) | — | `block-git-stash` (Bash, PowerShell) | — | — | — |
| Live settings not writable | `block-edit-live-settings` (Bash, PowerShell, Edit) | — | `block-edit-live-settings` (Bash, PowerShell; not `apply_patch`, HIMMEL-5430 open) | — | — | — |
| Bank lift not writable | `block-bank-lift-writes` (Bash, Edit) | — | `block-bank-lift-writes` (Bash, Edit) | — | — | — |
| `~/.himmel/config.json` opt-ins not writable | `block-himmel-config-writes` | — | `block-himmel-config-writes` | — | — | — |
| Lesson and enforcement files not agent-written | — | `block-lesson-enforcement-writes` | `block-lesson-enforcement-writes` | — | — | — |
| No commit onto a merged PR's branch | — | `block-merged-pr-commit` | `block-merged-pr-commit` | pc `check-merged-branch` (warns) | — | — |
| Chokepoints called bare | `block-chokepoint-env-prefix`, `guard-pr-check-literal` | `block-rogue-codex-exec`, `block-rogue-codex-wsl` | `guard-pr-check-literal` | — | — | — |
| Agent dispatch names a model and the right lane | `guard-agent-model` (blocks a Fable model and a `console-judge` tier override; allows a missing model) | `guard-subagent-model` (denies a missing model unless a fork; `SUBAGENT_MODEL_OK=1`), `guard-implementor-dispatch`, `guard-console-dispatch` | — | — | — | — |
| Egress stays inside policy | `mcp-policy`, `block-backend-tier` | `block-graphify-egress`, `block-agent-native-egress`, `block-glm-external-writes` | `mcp-policy`, `block-backend-tier`, `block-terminal-write-fence` | — | — | — |
| Leg session discipline | `block-leg-askuserquestion`, `guard-leg-wakeup`, `guard-leg-context-handoff` (+ PreCompact), `block-subagent-park` | — | `guard-leg-context-handoff` | — | — | — |
| Judge and relay writes confined | `guard-relay-writes` | `guard-judge-writes` | — | — | — | `go.sh` refuses under `HIMMEL_CONSOLE_LEG` / `HIMMEL_CONSOLE_RELAY` |
| Guard scripts intact | Post `check-hook-file-parse` | `record-hook-integrity` | — | pc `fail-open-lint`, `hook-lib-node-suites`, `guardrail-matrices` | `guardrail-matrices`, `lanes-and-trust-suites` (`check-hook-lib-suites.sh`) | `ci-trust-paths.txt` lists `scripts/hooks/lib/` |
| Test suites run through `quiet-run` | `require-quiet-run`, `block-tail-pipe-on-gates` | — | `require-quiet-run` | — | — | — |
| Dependency supply chain | — | — | — | pc `lockfile-integrity`, `uv-lock-integrity`, `pip-hashes`; pp `npm-audit`, `npm-licenses`, `npm-audit-signatures` | `security-scan` (same scripts, `pip-hashes` excepted) | — |
| Generated docs match their sources | — | — | — | pc `agents-md-fresh`, `debrand-coverage`, `lanes-inventory-guard`, `commands-catalog-drift`, `secrets-doc-drift`, `skill-description-cap`, `doc-guard`; pp `doc-guard-push` | `doc-invariants` (same checks over the staged tree, plus `doc-guard` over the PR range) | — |
| Plugin edits bump the version | — | — | — | pc `plugin-version-bump-required` | `plugin-version-bump` | — |

### Overlaps worth a look

Facts only; nothing here is a proposed change.

**Enforced three or more times**

1. **Primary-checkout writes** — seven scripts across four layers:
   `block-edit-on-main`, `block-write-into-main-checkout`,
   `detect-dirty-primary`, `record-primary-baseline`,
   `block-terminal-write-fence`,
   `check-worktree-isolation` and `check-main-ref-transaction`.
2. **The CR gate** — the pre-push marker, the PR-create guard (Claude and
   Codex), `clear-cr-marker.sh`, ready-check items 3–4, `block-unresolved-cr-merge`
   and `merge-on-green.sh` all decide some part of "reviewed before it lands".
3. **Force push** — `block-destructive-commands` (Claude and Codex), the
   settings `permissions.deny` rules, `block-terminal-write-fence` (Codex),
   pre-push `check-no-force-push` and, in `.single-writer` repos, the installed
   pre-push `check-single-writer-push-floor`.
4. **Ticket ID** — commit-msg, CI `commit-lint`, CI `pr-title-lint` and
   ready-check item 6.
5. **Secrets committed** — `gitleaks` and `leak-classes` at pre-commit, then
   again in CI (`security-scan`, `leak-classes`), plus `check-no-secrets.sh` on
   workflow files.
6. **Agent dispatch** — four `Agent` PreToolUse guards in two files
   (`guard-agent-model` in settings; `guard-subagent-model`,
   `guard-implementor-dispatch`, `guard-console-dispatch` in the plugin).
7. **Attestation trailers** — pre-push `check-platforms-tested` and
   `check-security-reviewed`, the same two gates re-run over the PR range in CI
   `commit-lint`, and ready-check item 5.

**Look redundant on a first read**

- `guard-agent-model` (settings) and `guard-subagent-model` (plugin) both read
  an `Agent` call's `model` field, but split the job. `guard-agent-model`
  denies a blocked model (Fable) and a `console-judge` tier override, and
  allows a missing model. `guard-subagent-model` denies a missing model for
  every subagent type except a fork (`SUBAGENT_MODEL_OK=1` lets one through)
  and never reads the model's value.
- The green-CI check runs in `block-unresolved-cr-merge` (on `gh pr merge`) and
  in `merge-on-green.sh` (on its own merge); they guard two entry points to one
  action.
- The trust-path rule runs in `block-unresolved-cr-merge` (gate 4, on
  `gh pr merge`, every session) and in `merge-on-green.sh`. Both ask the same
  `trust_path_check` in `scripts/lib/go-gate.sh`.
- `check-merged-branch` (pre-commit, warns) and `block-merged-pr-commit`
  (PreToolUse, denies) catch the same commit at two moments.
- Most pre-commit checks re-run in CI. That is by design: a commit made with
  `--no-verify` skips every git hook, and CI is where that is caught.

**One layer only**

- Secrets never *read* — `block-read-secrets` only (Claude and Codex wire the
  same script).
- `git stash`, live settings writes, rogue scheduler jobs, `quiet-run` — a
  PreToolUse hook only (Claude and Codex wire the same scripts); no git or CI
  layer. Codex does not cover the live-settings write path through
  `apply_patch` (HIMMEL-5430, open).
- No direct push to `main` from a Claude session — pre-push
  `check-push-target` only; no Claude hook, and `permissions.allow` lists bare
  `git push`.
- Bank lift and `~/.himmel/config.json` — one script per invariant, wired in
  both Claude and Codex.
- Attestation trailers in CI — `commit-lint` runs them on `pull_request`
  events only, so a push with no PR is not re-checked there.

**Codex parity** (guards only: hooks that can deny a tool call; context
injectors, watchdogs and end-side hooks are not counted): `.codex/hooks.json`
wires no plugin-only guard except `block-docker-privesc`,
`block-merged-pr-commit` and `block-lesson-enforcement-writes`; it adds
`block-terminal-write-fence`, which no Claude file wires.
