# Daily loop walkthrough

> **Prerequisites:**
> 1. himmel installed and configured on your machine — see
>    [docs/setup/new-machine.md](setup/new-machine.md) (or
>    [docs/setup/install.md](setup/install.md) if you're
>    adopting the portable core in your own repo).
> 2. **An active Claude Code session in the repo root** — run `claude` in your
>    terminal (or use your IDE's Claude extension). Need
>    [Claude Code](https://claude.com/claude-code) first?
>    `curl -fsSL https://claude.ai/install.sh | bash` (Linux/macOS). Every hook behaviour
>    below fires *inside* a session; the steps assume you are already in one.

This page walks one complete loop — a toy change from worktree creation
to handover — explaining every hook and gate you will hit along the way.
By the end you will have run the real workflow on a real branch.

This is the solo loop. The agent loop (console, legs, judges) is the
development graph.

The agent loop drawn out: [the development graph](guide/dev-graph.html).

---

## Toy change used throughout

We will add a single line to `docs/contributing.md`. Docs-only change, no
shell scripts touched. That simplifies the attestation story; the
differences for code or script changes are called out inline.

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
| Touches `*.sh`, `*.bash`, PowerShell files, `scripts/**`, `**/bin/*` | `Platforms tested: <os>` |
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
/worktree docs/<slug>           # 1. create worktree
# edit files                    # 2. make the change
git add …                       # 3. stage
git commit -m "type: message"   # 4. commit (commit-msg gate fires)
git push -u origin <branch>     # 5. push (pre-push gates fire)
/pr-check                       # 6. if marker was written: run review
gh pr create …                  # 7. open PR
# wait for CI, then merge       # 8. merge (check-ci.sh; merge gates fire)
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
