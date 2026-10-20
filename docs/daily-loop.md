# Daily loop walkthrough

> **Prerequisites:**
> 1. himmel installed and configured on your machine — see
>    [docs/setup/new-machine.md](setup/new-machine.md) (or
>    [docs/setup/install.md](setup/install.md) if you're
>    adopting the portable core in your own repo).
> 2. **An active Claude Code session in the repo root** — run `claude` in your
>    terminal (or use your IDE's Claude extension). Need
>    [Claude Code](https://claude.com/claude-code) first?
>    `curl -fsSL https://claude.ai/install.sh | bash` (Linux/macOS) /
>    `irm https://claude.ai/install.ps1 | iex` (Windows). Every hook behaviour
>    below fires *inside* a session; the steps assume you are already in one.

This page walks one complete loop — a toy change from worktree creation
to handover — explaining every hook and gate you will hit along the way.
By the end you will have run the real workflow on a real branch.

This is the solo loop. The agent loop (console, legs, judges) is the
development graph.

---

## Toy change used throughout

We will add a single line to `docs/contributing.md`. Docs-only change, no
shell scripts touched. That simplifies the attestation story; the
differences for code or script changes are called out inline.

---

## 0. Start from a ticket

Every commit subject and every PR title carries a ticket ID: the
commit-message gate refuses a subject without one while
`TICKET_ID_REQUIRED=1` (see step 4). So the loop starts in your tracker.
Search for an existing ticket that covers the change and extend it before
filing a new one. This walkthrough uses `PROJ-289`.

The ticket moves with the work. With the `ticket` step in
`HIMMEL_INITIATIVE` the session moves it for you; without it, you move it.

---

## 1. First touch on main — the block-edit-on-main surprise

Before you create a worktree, try editing a file in the primary checkout
(i.e., while Claude's working directory is the repo root with `HEAD ==
main`). Claude will attempt the edit and immediately hit:

```
⛔ block-edit-on-main: refusing to edit `docs/contributing.md` — its repo is on main/master.
(file: /abs/path/docs/contributing.md — repo: /abs/path)

Feature work must go in a worktree per CLAUDE.md. To start one:

    bash scripts/worktree.sh feat/<scope>   # create the worktree
    cd .claude/worktrees/feat+<scope>   # switch in the existing shell

Or to bypass for an emergency hotfix, set EDIT_ON_MAIN_OK=1 in the shell
that launched Claude Code (the hook reads its environment, so per-edit
prefix syntax cannot work — Claude Code cannot inject env vars into a
hook process). Example:

    EDIT_ON_MAIN_OK=1 claude

The bypass lasts for the entire Claude Code session (it's session-sticky,
not per-edit). Restart Claude without the env var to re-enable the guard.

Or, if this is a single-writer repo you always commit to main directly
(a personal vault / state repo), opt it out locally:

    touch "/abs/path/.single-writer"

(Local + gitignored — never committed, so it cannot weaken a shared clone.)

Or temporarily comment out the hook stanza in .claude/settings.json.
```

This is a **PreToolUse hook** (`scripts/hooks/block-edit-on-main.sh`) that
fires on every Edit/Write/MultiEdit tool call. It exits 2 so Claude sees
the error and the edit never happens. The message tells you exactly what
to do: create a worktree first.

**The bypass** (`EDIT_ON_MAIN_OK=1`) must be set in the shell that
launched `claude`, not as a per-command prefix — a per-call prefix cannot
reach the hook process. Bypass is intentionally session-sticky so you
cannot accidentally toggle it per-edit. The per-repo alternative is the
gitignored `.single-writer` marker shown above.

---

## 2. Create a worktree

```
/worktree docs/himmel-289-daily-loop
```

`/worktree` is a thin alias for `/clean_garden --no-prune`. It creates
`.claude/worktrees/docs+himmel-289-daily-loop/` and checks out a new
branch `docs/himmel-289-daily-loop`. Branch names must be `type/slug`
(for example `feat/foo`, `docs/bar`).

You now have an isolated copy of the repo. Claude's file operations in
this session target the worktree path, not the primary checkout — the
`block-edit-on-main` hook will no longer fire.

To prune old merged-PR worktrees at the same time, use `/clean_garden
docs/himmel-289-daily-loop` (runs prune then create). To only prune
without creating a new one, use `/clean`.

---

## 3. Make the change

Edit `docs/contributing.md` inside the worktree. For this walkthrough,
add one line:

```markdown
<!-- toy change for daily-loop walkthrough -->
```

`block-edit-on-main` no longer blocks you inside a worktree, but edits are
not unguarded: `orchestrator-inline-guard`, `shadow-ledger` and
`check-hook-file-parse` also run on Edit/Write and stay silent on a
well-formed docs change.

> **Code changes start with a failing test.** For a bug fix or a feature,
> write the test that shows the problem first and watch it fail, then make
> the change and watch it pass. The review in step 6 runs every suite that
> references a file you touched (`scripts/cr/impacted-suites.sh`), so a
> change that breaks a neighbour shows up before the PR opens.

---

## 4. Commit

The examples below use `PROJ-N` ticket IDs; they pass the gate when
`JIRA_PROJECT_KEY=PROJ` (or a matching `TICKET_ID_PATTERN`) is set, as in
[contributing](contributing.md).

```
git add docs/contributing.md
git commit -m "docs: [PROJ-289] toy change for daily-loop walkthrough"
```

The **commit-msg gate** (`check-commit-msg.sh`) runs and validates:

```
Pattern:  type[(scope)][!]: [PROJ-N] message
Types:    feat fix chore docs refactor test style perf ci build revert
```

If you get the format wrong you see:

```
COMMIT REJECTED: message does not match conventional commit format.

  Required:  type(scope): message
  Ticket:    required by default; TICKET_ID_REQUIRED=0 opts out

  Types: feat fix chore docs refactor test style perf ci build revert

  Examples:
    feat(auth): [#12] add JWT validation
    fix(api): PROJECT-23 correct status code on 404
    chore: [#13] update dependencies

  Got: my bad message
```

Fix the message and commit again. Once the format is valid the commit
succeeds and pre-commit runs the commit-stage hooks listed in
[`.pre-commit-config.yaml`](../.pre-commit-config.yaml) (whitespace and
format fixers, linters, gitleaks, and the repo's own checks).

### Attestation trailers — when they are required

Trailers go in the **commit body** (blank line after the subject), not in
the subject line. They are required only in certain circumstances:

| Change type | Trailer required |
|---|---|
| Touches `*.sh`, `*.bash`, `*.ps1`, `scripts/**`, `**/bin/*` | `Platforms tested: <os>` |
| Touches any non-docs code (non-`*.md`/`*.txt`/`docs/`/`handovers/`) | `Security reviewed: <token>` |
| Docs-only (`*.md`, `*.txt`, `docs/**`, `handovers/**`) | _neither required_ |

Our toy change is docs-only — no trailers needed. For a change that DOES
require them, the full commit looks like:

```
fix(scripts): PROJ-42 correct bash exit code

Platforms tested: linux, windows
Security reviewed: manual

Co-Authored-By: Claude <noreply@anthropic.com>
```

Trailers go in the **first commit** after genuinely testing and reviewing
— not in a reactive amend. If you forget, add a **new commit** that only
adds the trailer (amending is hard-blocked in auto-mode). Details:
[docs/internals/stuck-playbook.md](internals/stuck-playbook.md).

Recognised platform tokens: `linux windows macos ubuntu debian fedora
arch mac darwin wsl posix gitbash git-bash powershell pwsh`.

Recognised security-review tokens: `manual claude-code-security-review
pr-review-toolkit ad-hoc`.

---

## 5. Push

```
git push -u origin docs/himmel-289-daily-loop
```

Several **pre-push gates** run in sequence:

| Gate | What it checks |
|---|---|
| `no-push-to-main` | Blocks pushes directly to `main`. |
| `npm-audit` / `npm-licenses` / `npm-audit-signatures` | npm dependency hygiene on changed packages. |
| `code-review-before-push` | Writes a review-owed marker (see below). |
| `platforms-tested` | Shell/script changes need `Platforms tested:` attestation. |
| `security-reviewed` | Non-docs changes need `Security reviewed:` attestation. |
| `added-unwired-check` | A file the branch adds must be wired into its suite/inventory. |
| `doc-guard-push` | An added command or skill needs its catalog entry. |
| `template-version-push` | A template content change needs a `metadata.version` bump. |
| `pr-mergeable-gate` / `no-force-push` | Branch not conflicting, no force-push. |

For our docs-only change, `platforms-tested` and `security-reviewed` skip
themselves (docs-only fast-path). The important gate is
`code-review-before-push`.

### The review-owed marker flow

On push, `check-cr-before-push.sh` writes a marker file at
`.git/cr-pending/docs/himmel-289-daily-loop`. It does NOT run a review;
it just flags that a review is owed. You see:

```
→ code-review: docs-audit marker written for docs/himmel-289-daily-loop (HEAD=abc1234). Run /pr-check (docs-audit lane: one code-reviewer with the docs charter) before opening the PR — docs are never zero-CR.
```

(Our toy change edits `docs/contributing.md`, a reviewable doc, so it gets a
`docs-audit`-lane marker. A code diff would get a `full`-lane marker instead;
a handover-state-only diff gets none.) Push succeeds either way — the marker
is advisory at push time and becomes a hard block at PR creation time.

> **Docs-only path:** Reviewable docs (`docs/`, repo
> `*.md`/`*.txt`) are **never zero-CR**. The `code-review-before-push` gate
> writes a **`docs-audit` marker** for them, so `gh pr create`
> is blocked until `/pr-check` clears it — same hard gate as code, but a
> lighter lane: `/pr-check` reads the marker's `docs-audit` lane and applies
> the docs charter (repo-claim accuracy — hooks/gates/flags/paths/commands vs
> the actual code — dead links, stale file/flag/ticket refs, example
> correctness, internal consistency; not prose nitpicks; `CLAUDE.md` →
> `/claude-md-audit`) inline in your session, with no reviewer agent unless
> `CR_CLAUDE_AGENTS=1` (then ONE `pr-review-toolkit:code-reviewer`). A
> cross-model critic also runs when `CR_REQUIRE_CROSS_MODEL` is set. It does
> not run the full lane's critic panel.
> **Handover state stays exempt:** `handovers/` diffs (and handover/* state
> commits) get NO marker — personal auto-committed state, not reviewable docs.

---

## 6. Run /pr-check

A marker was written (reviewable docs → `docs-audit` lane; code → `full`
lane), so run:

```
/pr-check
```

`/pr-check` reads the marker's lane: a `full`-lane marker runs the cross-model
critic panel and adjudicates its findings; a `docs-audit`-lane marker (our toy
docs change) applies the docs charter inline (see the callout above). Either
way the marker is cleared only through `clear-cr-marker.sh`, and only when
there are no blocking findings, no unresolved review threads and every
impacted suite passed. If findings are critical, address them before
continuing.

Reviews are counted in rounds: `/pr-check` prints `round N of 3` and, after
round 3, allows one delta round scoped to what changed since; a further full
round exits 8 and goes to the operator or console (`scripts/cr/review-round.sh`).

While the marker exists, `gh pr create` is blocked by the
`check-cr-marker-on-pr-create` PreToolUse hook:

```
Automated review pending for docs/himmel-289-daily-loop (HEAD=abc1234). Run /pr-check (or /pr-review-toolkit:review-pr) first. After review passes, marker auto-clears.
```

You cannot open a PR until the marker is cleared by a passing review.

---

## 7. Open the PR

Once the marker is cleared (a marker is only ever skipped for a handover-only change):

```
gh pr create --title "docs: [PROJ-289] toy change for daily-loop walkthrough" \
  --body "Toy change per daily-loop walkthrough."
```

The `protect-main` ruleset (read with `gh api repos/:owner/:repo/rules/branches/main`)
requires a pull request with **0** approving reviews, all review threads
resolved, and squash as the only merge method, plus these status checks:
`bun-suites`, `codeowner-review-gate`, `commit-lint`, `doc-invariants`,
`guardrail-matrices`, `lanes-and-trust-suites`, `leak-classes`, `lint`,
`node-suites` (bitbucket, ci-orchestrator, himmel-run, jira), `secret-scan`,
`security-scan`, `shell-unit`, `pr-title-lint`, `unchecked-mktemp-range`,
`claude-startup` and `git-env-scrub`. The ruleset sets
`require_extra_approval_for_unattributed_changes`, so a change GitHub cannot
attribute to a user may still need an extra approval; a normal PR needs none,
so wait for CI instead: `scripts/check-ci.sh <pr>` blocks until the checks settle.

---

## 7a. Review on the pull request: CodeRabbit and the review gate

Two kinds of reviewer look at a change:

- **Critics** run inside `/pr-check` (step 6), before the PR exists:
  `codex` and `claude`, the rows of `scripts/cr/critics.json`. Their findings
  and your dispositions go to the CR ledger, stamped with the exact head.
  When no critic lane is configured, `/pr-check` reviews the diff itself:
  the claude-only floor. There is never "no review".
- **CodeRabbit** is a GitHub App. It reviews the PR after `gh pr create`,
  posts review threads and a `CodeRabbit` commit status, and is read by
  `check-ci.sh` and the merge gate through `scripts/lib/cr-signal.sh`. A repo
  without the App is detected (`git config --local himmel.coderabbit`,
  `scripts/lib/cr-available.sh`) and its CodeRabbit gate is a no-op.

**Today CodeRabbit is a best-effort reviewer.** A thread it posts must be
resolved before the merge: fix it in a commit, or reply with why it is fixed
elsewhere, deferred to a ticket, or wrong, and resolve the thread. A finding
outside the diff (in the review body, with no thread) needs a recorded
disposition at that head instead. But when CodeRabbit is absent, skipped or
rate-limited, `check-ci.sh` and the merge gate print a NOTE and carry on:
an unavailable CodeRabbit never makes you wait.

### Reviewer modes (planned, HIMMEL-6580)

> Not live yet. This describes the design under build for v1.1.3. Until it
> lands, the rules above are the ones that run.

Every reviewer gets a **mode** in config, `hard` or `best-effort`, in any
combination. The mode decides what happens when the reviewer cannot review.

| Mode | It posted findings at this head | It is unavailable at this head |
|---|---|---|
| `hard` | each finding fixed or dispositioned, then it passes | **hold**: nothing moves on until it reviews, and you are told why |
| `best-effort` | each finding fixed or explained, exactly as for hard | **relaxed**: it is skipped, provided every hard reviewer passed |

- *Unavailable* means the lane is configured but could not review this head:
  it errored, ran out of credit, or is rate-limited. A rate-limited CodeRabbit
  is its own state, never read as clean.
- *Absent* means the lane is not set up on this machine at all (no key, no
  App). An absent reviewer leaves the set; it neither passes nor holds.
- *Not selected* means `/pr-check` did not run that critic for this head
  (a trivial or docs-only diff, or your `CR_PROFILE`). It leaves the set for
  that head too.
- The **claude-only floor** counts as a hard reviewer, so a machine with no
  critic lane still has one.
- A config with no hard reviewer, or a mode other than `hard` and
  `best-effort`, is a config error: the gate refuses, it never guesses.

**Defaults.**

- **Shipped (`scripts/cr/critics.json`):** `codex` hard, `claude` hard,
  `coderabbit` best-effort. Because an unconfigured lane is absent, an
  install with one lane gets one critic, codex or claude, plus the floor.
  That is the adopter default.
- **himmel's own repo:** both lanes are configured, so codex and claude (on
  the Claude API lane) are hard on every PR and CodeRabbit is best-effort.

**Change a mode for one machine** in the overlay `scripts/cr/critics.local.json`
(gitignored), one row per reviewer you change:

```json
{ "panel": [
  { "slug": "coderabbit", "mode": "hard" },
  { "slug": "claude", "drop": true }
] }
```

The first row makes CodeRabbit hard; the second removes the claude critic,
which gives a codex-only gate. A row that cannot be read is a config error,
not a silent fallback to the shipped file.

**On a rate limit.** CodeRabbit runs at a per-account limit, and most heads
are limited. A limited head is a best-effort CodeRabbit unavailable at that
head: it is relaxed, and the head moves on once the hard critics pass.
Nothing waits for the limit to reset and nothing re-requests the review. If
CodeRabbit posts later, its threads still have to be resolved before the
merge. A **hard** reviewer that is rate-limited or out of credit holds the
head and says so in `check-ci.sh` and `ready-check.sh`; the levers are to
restore the lane, or (an operator decision) to set that reviewer to
`best-effort` or drop it in the overlay for the duration.

### CI release: heavy CI after review (planned, HIMMEL-6581 and HIMMEL-6582)

> Not live yet, and himmel-only: it needs a CI workflow that listens to the
> `ci:go` label. A repo that does not opt in keeps running CI on every push.

A push runs only the cheap checks (`plan`, `lint`, and the folded `ci-quick`
job once it lands). The heavy jobs
(the shell-unit shards and the bun, node and lanes-and-trust suites) start
when the review gate passes at that head, so a head a reviewer is about to
send back does not burn an hour of runners.

1. You push. The cheap checks run.
2. Each time the review loop concludes something about the head (the critic
   panel finishes, you disposition a finding, CodeRabbit's verdict is read, a
   thread is resolved), the station checks the review gate at that head.
   There is no timer: the check runs on those events only.
3. When every hard reviewer passes and every best-effort reviewer passes or is
   relaxed, and the cheap checks are green, the station adds the `ci:go`
   label. That label event starts the heavy jobs at that head.
4. A new push starts over at step 1 and cancels the heavy run of the old
   head.

What does not change: the merge still needs every required check green at
the final head and a passing review gate (step 8). `ci:go` only starts CI
early or late; it never lets anything merge. Adding `ci:go` by hand starts
heavy CI at once, which is the lever when a hold is understood. Until the
heavy jobs report, `check-ci.sh` prints `CR-FIRST HOLD <reason>` for the head
instead of failing on missing checks. A thread resolved in the GitHub web UI
is picked up by the next `/pr-check` or `check-ci.sh` run, or by the console
tick when you run a console.

Opting in is one repository variable, read by both the workflow and the
station, so the two cannot disagree; turning it off brings back CI on every
push without editing the workflow.

---

## 8. Merge

Once CI is green and review threads are resolved:

```
gh pr merge --squash
```

A `PreToolUse` hook (`block-unresolved-cr-merge.sh`) refuses `gh pr merge`
until four gates pass:

1. no unresolved CodeRabbit threads, and no CodeRabbit check still running;
2. the head SHA has green overall CI (no failing or pending check or status);
3. in a console-spawned leg, a console GO file matches the head SHA;
4. a PR touching a CI trust path (`scripts/ci/ci-trust-paths.txt`) carries a
   trust-reviewed GO and is merged pinned to its head.

Gates 3 and 4 fail closed. Gates 1 and 2 have session bypasses set in the
launching shell (`CR_MERGE_GATE_OK=1` and `CI_MERGE_GATE_OK=1`; `CR_PROFILE=none`
also skips gate 1), and an API error while evaluating them fails open.

The branch is squash-merged into main. The worktree is now stale.

Console legs do not call `gh pr merge`; they merge through
`merge-on-green.sh` on a GO file, which also refuses while the newest main CI
run is red. The console verifies each PR with `ready-check.sh` before it
writes that GO. This page covers the solo loop; the agent loop (console,
legs, judges) is the development graph.

---

## 8a. Close the ticket

A merge does not close the ticket by itself. If the PR finishes the ticket,
move it to Done and note the PR number and merge commit on it; if work
remains, leave it open. `merge-on-green.sh --jira-transition` closes the
first `[KEY]` in the PR title at merge, and only when you pass the flag;
the `ticket` step in `HIMMEL_INITIATIVE` does it for you.

---

## 9. Clean up with /clean

```
/clean
```

`/clean` is a thin alias for `/clean_garden --prune-only`. It identifies
worktrees whose branch has a merged PR and removes them. The worktree at
`.claude/worktrees/docs+himmel-289-daily-loop/` disappears.

---

## 10. Handover

At session end (or when switching context), snapshot your in-progress
state:

```
/handover
```

The handover skill writes a structured summary of what was done, what is
in-flight, and what the next session should pick up. State is stored in
your handover state repo (not in himmel's `handovers/` stub). To resume in
a future session, use `/handover-resume-armed` or browse the handover
registry via `/handover repos`.

Full handover internals:
[docs/internals/handover-system.md](internals/handover-system.md).

---

## Summary — the full sequence

```
# find or file the ticket       # 0. start from a ticket
/worktree docs/<slug>           # 1. create worktree
# edit files                    # 2. make the change
git add …                       # 3. stage
git commit -m "type: message"   # 4. commit (commit-msg gate fires)
git push -u origin <branch>     # 5. push (pre-push gates fire)
/pr-check                       # 6. if marker was written: run review
gh pr create …                  # 7. open PR
# resolve CodeRabbit threads    # 7a. review on the PR (the review gate)
# wait for CI, then merge       # 8. merge (check-ci.sh; merge gates fire)
# move the ticket               # 8a. close the ticket
/clean                          # 9. prune merged worktree
/handover                       # 10. snapshot session state
```

---

## Hook and gate reference

| Hook / gate | Stage | What it does |
|---|---|---|
| `block-edit-on-main` | PreToolUse (Edit/Write) | Blocks edits in primary worktree while on main |
| `check-cr-marker-on-pr-create` | PreToolUse (Bash) | Blocks `gh pr create` while a review-owed marker exists |
| `conventional-commit-msg` | commit-msg | Validates conventional shape and required ticket traceability in this repo |
| `code-review-before-push` | pre-push | Writes review-owed marker for every non-handover change (`full` or `docs-audit` lane) |
| `platforms-tested` | pre-push | Requires `Platforms tested:` trailer on shell/script diffs |
| `security-reviewed` | pre-push | Requires `Security reviewed:` trailer on non-docs code |
| `no-push-to-main` | pre-push | Blocks direct pushes to main |

Full enforcement detail: [docs/internals/enforcement.md](internals/enforcement.md).
Recovery when stuck: [docs/internals/stuck-playbook.md](internals/stuck-playbook.md).
