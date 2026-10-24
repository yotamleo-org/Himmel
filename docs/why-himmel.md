# Why himmel

Audience: newcomer. Use this page to decide whether himmel is worth adding
to your project. It walks the failure modes that show up once you run Claude
Code seriously, what himmel does about each, where that protection stops, and
what it costs you.
[`README.md`](../README.md) says what himmel is, and
[`getting-started.md`](getting-started.md) is the trial you can run on a spare
project to see the first of these protections for yourself.

If you are happy running Claude Code vanilla, you do not need any of this. It
starts to pay for its complexity once you run more than one session at a
time, want work to continue while you sleep, or need context to survive a
session boundary.

---

## The five failure modes

### 1. The rule Claude forgot

You write "never commit directly to main" into a `CLAUDE.md`. It holds for a
week. Then a long session compacts, the instruction falls out of the live
window, and a commit lands on main.

Prose in a context window is a *probability*, not a constraint. The failure is
silent and you find it later.

**What himmel does:** the same rule becomes a hook that exits non-zero.
`block-edit-on-main.sh` runs before the Edit tool call, sees the branch, and
refuses. Nobody has to remember the rule.

**A bounded example.** In a project where himmel is installed, on `main`, you
ask Claude to create `hello.txt`. The edit is refused with
`block-edit-on-main: refusing to edit …`, and the file is not written. Step 7
of [`getting-started.md`](getting-started.md) shows exactly this. The hook
covers Claude Code's file-edit tools (Edit, Write, MultiEdit, NotebookEdit) in
a session started where the hooks are installed. It does not inspect a file a
shell command writes; for that, the git commit gate, where it is installed,
refuses the commit on `main` instead (step 8 of the same page says when it
runs).

The escalation rule is written down as part of the design: *structural
beats instructional — the first drift is signal; on the second, escalate to a
hook, gate, or classifier, never to stronger prose.* Over time that policy
produced layers of hooks and gates. Their number changes with almost every
release, so this page gives no count; each layer's config file is the
inventory, and you can count it yourself:

| Layer | Source of truth | Count it (from a himmel checkout) |
|---|---|---|
| PreToolUse hook entries (project scope; one entry can chain several scripts) | `.claude/settings.json` | `jq '[.hooks.PreToolUse[].hooks[]] \| length' .claude/settings.json` |
| PreToolUse guards (himmel-ops plugin) | `marketplace/plugins/himmel-ops/hooks/hooks.json` | `jq '[.hooks.PreToolUse[].hooks[]] \| length' marketplace/plugins/himmel-ops/hooks/hooks.json` |
| pre-commit, pre-push and commit-msg gates | `.pre-commit-config.yaml` | `grep -c -E '^[[:space:]]*- id:' .pre-commit-config.yaml` (gate ids, all stages) |
| CI jobs | `.github/workflows/ci.yml` | the entries under `jobs:` |

Where each one fires, and how to get past it when it stops you for a good
reason:
[`internals/enforcement.md`](internals/enforcement.md) and
[`internals/stuck-playbook.md`](internals/stuck-playbook.md).

### 2. The gate that drifts away from the thing it guards

A gate that hand-maintains a list of what to block is a second copy of the
truth. Add a feature, forget the list, and the gate stops covering it while
it stays green.

**What himmel does:** where possible, gates derive their input from the thing
they guard. The hook that blocks Jira MCP calls when a local CLI verb exists
carries no list of verbs. It runs the CLI's own
`--list-commands` and blocks exactly what the CLI implements. Adding a verb
tightens the gate on its own; removing one loosens it. Same idea in the
`commands-catalog-drift` gate (the catalog's Description column is regenerated
from each command's own frontmatter and a divergent hand-edit is refused) and
`guardrail-matrices` (the egress policy JSON is the only copy, and both its
tests and its consumers are checked against it).

### 3. Context that dies with the session

A session ends. The next one starts cold: what shipped, what was tried and
rejected, why the obvious approach does not work. Re-explaining that is the
largest recurring cost of agentic development, and a paraphrase loses the
*why* first.

**What himmel does:** handover state is plain markdown in a directory you own,
written at session end and read at session start. It records the ship state
rather than a summary of the session: ticket, branch, worktree, what is committed vs. dirty, unresolved review
findings, the remaining ordered steps.

It is deliberately **not** a memory backend. Nothing extracts your files into
a separate store that gets queried instead of the source. The local search
index over the same markdown is a derived, drop-and-rebuild view that always
returns a pointer back to the real file. You can read the memory, correct it
by hand, and diff it — see
[`internals/handover-system.md`](internals/handover-system.md) and the
architecture view in [`architecture.md`](architecture.md#2-the-handover-system).

### 4. Two agents, one artifact

Run several sessions in parallel and coordination becomes the bug. Two armed
sessions pick up the same queue; both dispatch; both ship. A shared markdown
file and a convention cannot prevent that, because the convention is prose and
prose does not lock.

**What himmel does:** one writer per queue, enforced.
`scripts/handover/queue-lock.sh` takes a lock that is a *directory* (`mkdir` is
atomic, with no check-then-create window, and it works on NTFS under Git Bash).
`acquire` prints a release token; `release` and `heartbeat` refuse without it,
so a stale or wrong session cannot delete a live lock.

The script was written after prose coordination failed three ways in one
night: duplicate dispatch, duplicate shipping, and a coordination-by-append
race. The incident is recorded in the script's own header, where an escalation
of this kind belongs.

Delegation follows the same rules. Many readers, one writer, never parallel
writes at a shared artifact. Every dispatch names its model explicitly. A
revision to a running agent arrives only as a direct message carrying an
echoed nonce, never inside a tool result, which is attacker-reachable text.
See [`internals/retask-channel.md`](internals/retask-channel.md).

### 5. Monitoring that lies, then pages you

Instrumentation that guesses is worse than none. A session that crashes never
writes its "session ended" record, so a naive reader reports it as still
running, forever. And a scrape that times out marks its target down, stales
every series, resolves the alert, then re-fires it on the next good scrape.

**What himmel does:** the exporter is a pure reader. It never writes a
ledger, never mutates state, never starts or kills a process, and omits a
metric family entirely when its substrate is absent, so missing data stays
missing.

The *reader* decides liveness, from transcript mtime, because the record that
never gets written is the informative one. An expired unpaired row is split by
whether its process is confirmed dead: `abandoned` (real hygiene information,
but nothing is hung and nobody can act, so it must not page) versus `stalled`
(everything else).

The flap above produced 53 Telegram pages in one night on the operator's
machine. The fix came from measuring: over 24 hours of live scrapes, the
exporter's render took ~6.6 s on average and ~9.9 s at peak, against a 10 s
default timeout, so the scrape timeout went to 30 s. Those numbers describe
that one machine at the time of the fix (in the tree since 2026-09-08 at the
latest), not a current benchmark. The reasoning is written into
`scripts/observability/prometheus.yml` next to the value it justifies.

---

## What that buys you

- **Unattended runs that survive their own interruptions.** A scoped ticket
  runs end to end (branch, build, self-review, PR). When the run nears a
  usage cap, the usage-cap auto-relaunch schedules an OS-level relaunch so the
  run resumes instead of dying.
- **Review before merge.** Push writes a review-owed marker; the PR
  gate refuses while it exists; a clean multi-agent review clears it. The
  merge gate also requires CI green *and* zero unresolved threads.
- **Small context by construction.** A local CLI instead of an always-loaded
  MCP server, an output-summarizing proxy for noisy commands, and a hard byte
  budget on the always-on instruction file, because every call pays for an
  instruction file that grows without limit. The budget is the `MAX_BYTES`
  default in `scripts/ci/check-claude-md-budget.sh`, which a pre-commit gate
  runs.
- **Linux and macOS.** Linux is checked on every PR and macOS on a scheduled
  run, with each change attesting the platform it was tested on. Windows is
  not supported; the README's
  [support matrix](../README.md#support-matrix) has the detail.

---

## What it costs

- **Gates fire on you too.** `.pre-commit-config.yaml` registers dozens of
  gate ids across the three git stages (count them with the command in the
  table above), and some of them will stop a change you believe is fine. That is the design
  working, and the recovery path is documented, but you will hit that friction
  every day.
- **Setup is not one command for the full stack.** The portable core adopts
  into an existing repo in one command; the observability stack, the Telegram
  bridge, and the vault tooling are each separate, optional bring-ups.
- **It assumes a PR-gated, ticket-tracked workflow.** If you commit to main by
  design, most of the value here is aimed at a problem you do not have.
- **The harness is opinionated about where knowledge lives.** Reference docs
  in the repo, internal specs out of it, memory as readable markdown. Fighting
  that costs more than adopting it.

---

## The provenance argument

Every mechanism above is traceable. On 2026-10-24 (main at `4daf5c89f`),
himmel's `CHANGELOG.md` carried 1,070 distinct ticket references
(`grep -o -E 'HIMMEL-[0-9]+' CHANGELOG.md | sort -u | wc -l`) and 1,421
distinct pull-request references (the same command with `'#[0-9]+'`), and
`scripts/ci/suite-tiers.tsv` listed 1,112 test suites run by 40 CI jobs.
These grow with every merge, so treat them as a dated snapshot and re-run the
commands for today's numbers. Nearly every guardrail in the
enforcement table was added *after* a specific failure, and the ticket that
motivated it is in the script's header.

So the claim is narrow. Each constraint in this harness is a recorded failure
that was paid for once and then made structurally impossible to repeat.

Start at [`getting-started.md`](getting-started.md); the wiring is in
[`architecture.md`](architecture.md).
