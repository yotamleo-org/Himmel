# himmel

> **A control plane for coding agents.**

**Agents you can trust.** himmel wraps [Claude Code](https://claude.com/claude-code)
in runtime guards, local git gates, independent code review, and (in fleet runs)
commit-locked merge sign-off so parallel and unattended agents ship cleanly
without you hovering over every session.

[Quickstart](#quickstart) ·
[How it works](#how-a-change-clears-himmel) ·
[Modular tracks](#what-you-get) ·
[Measured evals](#measured-not-promised) ·
[What runs where](#what-runs-where) ·
[Adoption trail](https://yotamleo-org.github.io/Himmel/adoption-trail.html)

---

## Agents you can trust

**Trust is engineered into the environment, not prompted.** Spawning ten agents
without trust only multiplies low-quality PRs and silent regressions. Rules
written in prompt prose fall out of the context window during long sessions;
himmel pushes every recurring failure as high up the trust ladder as it will
go so the safe path is the default path:

| Rung | Layer | What it enforces |
|---|---|---|
| **1** | **Runtime hooks** | Block specified risky actions before they execute: worktree isolation (never edit `main`), secret-file read blocks (`.env`, keys), and destructive-command guards (`rm -rf`, `git reset --hard`). |
| **2** | **Git gates + your CI** | Pre-commit, commit-message, and push gates run locally; on GitHub, himmel plugs into your existing CI and blocks Claude Code merges while checks are red or pending. |
| **3** | **Independent review & fleet GO** | A fresh review pass — Codex/GPT for cross-model coverage, or Claude alone once you [turn the required reviewer off](docs/configuration.md#reviewer-modes) — audits the diff; every finding is ruled against code, and in fleet runs the chief signs `GO` for that exact commit. |
| **4** | **Human judgment** | Reserved for what's left: you own specs, product calls, branch conflicts, and releases — never policing forgotten instructions. |

himmel is most useful when you run parallel sessions, leave work unattended, or
need decisions to survive session boundaries.

---

## How a change clears himmel

<p align="center">
  <img src="docs/assets/flows.svg" alt="Animated himmel delivery graph: Chief dispatches a scoped ticket to an isolated worker worktree guarded by PreToolUse hooks; local git gates, your existing GitHub CI, and independent /pr-check review verify the change; blocking findings or red CI loop back to the worktree; on GitHub the merge gate checks green CI, ruled findings, and exact HEAD match, and in fleet runs the chief signs GO before merge and cleanup" width="960">
</p>

<!-- The diagram is rendered by scripts/docs/render-flows.py: edit the script, not the image. -->

### What branch protection cannot stop

Repository branch protection governs changes at the remote; himmel also guards
actions inside the agent's local runtime:

- **Intercept before the tool runs.** `PreToolUse` hooks stop secret reads
  (`.env`, SSH/API keys), destructive shell commands (`rm -rf`,
  `git reset --hard`, `git clean -f`), and edits on `main` at the tool call —
  before credentials enter model context or commands execute.
- **No self-rubber-stamped merges (GitHub).** In a project-scope install or a
  himmel checkout on GitHub, the merge gate refuses a Claude Code session's
  merge while your CI is red or pending, a reviewer finding is still unruled
  against the code, the required reviewer has not passed at that exact HEAD
  commit, or (in a fleet run) the chief has not signed a `GO` for that PR and
  commit.
- **Parallel waves, human calls only.** Hand a queue of tickets to one *chief*
  session; it dispatches isolated *workers* across worktrees, verifies test and
  review evidence on every PR, escalates guardrail or CI changes to an
  independent judge, and interrupts you only when a decision needs your call.
  Each file keeps one writer at a time; a later PR merges the latest `main` in
  and its description says which conflicts it resolved
  ([parallel waves](docs/handover/running-a-chief.md#parallel-waves)).

### The daily loop

You work in Claude Code; the agent handles git, worktrees, and PR mechanics while himmel's hooks and gates enforce the rules automatically at every step:

1. **Give Claude a task or ticket.** If Claude tries to edit on `main`, a `PreToolUse` hook stops it and directs it into an isolated branch and worktree.
2. **Claude implements, tests, and commits.** Local git gates verify commit format, ticket reference, and branch safety on every commit and push automatically.
3. **Run an independent review pass** in Claude Code:

   ```text
   /himmel-ops:pr-check    # `/pr-check` inside a himmel checkout
   ```

   Every finding is ruled against the code; blocking issues loop back for fixes before merge.
4. **Ship through the gate.** Claude opens the PR and merges it once GitHub CI is green and findings are ruled, then prunes the merged worktree.

Going unattended across a queue of tickets, in Claude Code:

```text
/afk-shift --limit 5    # dispatch tickets to parallel workers, each ending in a reviewed PR
/stop                   # halt an unattended shift gracefully
```

[`docs/daily-loop.md`](docs/daily-loop.md) walks every hook at the moment it
fires; [`how-a-change-ships.html`](https://yotamleo-org.github.io/Himmel/guide/how-a-change-ships.html)
lets you inspect every check and its source citation.

---

<a id="what-you-get"></a>
## Start with Core, add only the tracks you want

Start with Guarded Core, then choose the optional tracks that fit your
workflow. Each track can be turned off cleanly, and you never need an Obsidian
vault or a Telegram bot just to get cross-model PR review, usage protection, or
parallel workers:

- **Start here — Guarded Core (`--scope project`):** Worktree isolation,
  secret-file and destructive-command guards, local git commit/push gates, the
  local UI (`himmelctl ui`), and reversible uninstall. Complete on its own.
- **Independent review:** Opt in to OpenAI GPT via Codex (`--with-codex`) for
  true cross-model coverage plus a tracked critic scorecard (`/cr-scores`,
  `/cr-tune`). Without Codex, `/himmel-ops:pr-check` reviews with Claude alone;
  once a review is recorded in your clone, the GitHub merge gate holds merges
  until you [turn the required reviewer off](docs/configuration.md#reviewer-modes).
- **Autonomous shifts & spend protection (opt-in):** Usage-window preflight
  (`usage-preflight.sh`) before heavy runs, plain-markdown handovers across
  session boundaries, `/afk-shift` queues, and one `/morning-report`.
- **Parallel fleet (opt-in):** One chief coordinating parallel workers across
  tickets, signed `GO` approvals pinned to the exact reviewed commit, and the
  live AG-UI Fleet console (`himmelctl ui`).
- **Second brain & mobile (optional):** Cross-project Obsidian vault (the
  `luna` [install profile](docs/setup/profiles/README.md)) with end-session
  capture, local `qmd` keyword+vector search, `graphify` code/note maps, and
  Telegram alerts.

The interactive [adoption trail](https://yotamleo-org.github.io/Himmel/adoption-trail.html)
lists what each capability installs, what it costs, and how to turn it off.

---

## Measured, not promised

Every claim below links to its measured sample — including what the review
panel misses. Token and byte metrics are reported as counts, never unmeasured
dollar claims:

| Metric | Measured | Sample & methodology |
|---|---|---|
| **PRs reviewed on himmel** | **4,630** | PRs building himmel itself; 3,332 of them drew 19,982 review findings (19,219 ruled, 763 unadjudicated) (as of 2026-11-11, [`review-panel.md`](docs/evals/review-panel.md)). |
| **Required reviewer agreement** | **80.1%** | Author agreed with 5,584 of 6,968 ruled `codex:gpt-6.1-sol` findings across 2,053 PRs (95% CI 78.7–81.5%, [`evals`](docs/evals/README.md)). |
| **Cached session input** | **99.1%** | In a sample of 176 sessions (4.95B tokens), 99.1% of input tokens were prompt-cache reads rather than uncached input or cache writes; `cache-health-cadence.sh` watches for drift hourly ([`evals`](docs/evals/README.md)). |
| **Hard-escape defect catch** | **38.3%** | `claude` + `codex` matched 18 of 47 planted and historical review-escape defects on a strict key-match proxy (95% CI 25.8–52.6%, as of 2026-11-04; CodeRabbit not in that sweep, [`evals`](docs/evals/README.md)). |

Full methodology and failure taxonomy live in
[`docs/evals/README.md`](docs/evals/README.md) and
[`docs/token-economy.md`](docs/token-economy.md).

---

<a id="quickstart"></a>
## Quickstart (2 minutes, reversible)

Test the guards, worktree flow, and local UI in a fresh folder before adding
himmel to a real repo — uninstall removes everything cleanly. Requires `node`
(with `npm` or `bun`), `git`, `jq`, `python3`, and signed-in
[Claude Code](https://claude.com/claude-code)
(`curl -fsSL https://claude.ai/install.sh | bash`), plus `bun` for the UI (the
installer warns if `claude` is missing and never checks sign-in):

```bash
# 1. Create a fresh folder, clone himmel once, preview and install
mkdir ~/try-himmel && cd ~/try-himmel
git init -b main && git commit --allow-empty -m "chore: initial commit #1"
git clone https://github.com/yotamleo-org/Himmel ~/himmel
node ~/himmel/scripts/himmelctl/bin.js install --scope project --dry-run
node ~/himmel/scripts/himmelctl/bin.js install --scope project

# 2. Commit the wiring on a branch (worktrees cut from committed history)
git switch -c chore/install-himmel && git add -A && git commit -m "chore: install himmel #1"
git switch main && git merge --ff-only chore/install-himmel

# 3. Start a change in its own worktree and run Claude Code there
bash scripts/worktree.sh feat/try-himmel
(cd .claude/worktrees/feat+try-himmel && claude)

# 4. Open the local UI (from a terminal outside Claude Code)
node ~/himmel/scripts/himmelctl/bin.js ui

# 5. Remove everything cleanly whenever you want
node ~/himmel/scripts/himmelctl/bin.js uninstall --dry-run
node ~/himmel/scripts/himmelctl/bin.js uninstall --yes
```

No issue tracker? Set `TICKET_ID_REQUIRED=0` in `~/.himmel/himmel.conf`. For
real-repo adoption, `--scope user`, Linux checksummed release tarballs, `.env`
variables (Jira CLI, `HANDOVER_DIR`, `USER_SLUG`), upgrading, and rollback, see
[`docs/getting-started.md`](docs/getting-started.md),
[`docs/setup/install.md`](docs/setup/install.md), and
[`docs/setup/updating.md`](docs/setup/updating.md).

---

## What runs where

himmel uses a two-part layout: your cloned `~/himmel` folder acts as the
control plane, while each adopted repository gets lightweight local guards and
worktree scripts.

| Capability | Adopted repo (`--scope project`) | Control plane (`~/himmel` clone) | Optional vault (`luna` install profile) |
|---|---|---|---|
| Worktree, secret & destructive-command guards | Yes | Yes (+ attestation & secret gates) | — |
| Independent `pr-check` & GitHub merge gate | Yes (reviewer gate activates after 1st recorded review) | Yes (+ review-owed PR-creation gate) | — |
| Chief, worker fleet & `/afk-shift` | Target repo | Orchestrates from here | — |
| Handovers & usage-cap auto-relaunch* | Setup & resume | Full write, ship & relaunch | Stored & indexed in vault |
| Second brain (`qmd` search, `graphify` map, auto-capture) | Optional | Code graph & search | Cross-project Obsidian vault |

*\*Usage-cap auto-relaunch requires an OS scheduler backend ([`docs/setup/new-machine.md`](docs/setup/new-machine.md#4c-scheduler-backend-auto-arm-resume)). The CI and reviewer merge gate runs on GitHub for merges invoked from Claude Code sessions; manual merges via `gh` or the web UI are not intercepted, and Bitbucket Cloud gets the worktree, PR, and merge loop without those gates.*

### Support matrix

himmel runs on Linux and macOS. Windows (Git Bash or WSL) is not supported.

| Dimension | Status |
|---|---|
| **Linux** | Supported — required check on every PR ([CI runs on `main`](https://github.com/yotamleo-org/Himmel/actions/workflows/ci.yml?query=branch%3Amain)); release tarball & project install/uninstall tested end to end. |
| **macOS** | **Beta** — checked twice weekly ([scheduled macOS runs](https://github.com/yotamleo-org/Himmel/actions/workflows/macos-cadence.yml?query=event%3Aschedule)); scripts stay bash 3.2-safe. |
| **Coding agents** | Built for Claude Code; guardrails also run under Codex CLI via hooks + `AGENTS.md` ([`docs/internals/harness-compat.md`](docs/internals/harness-compat.md)). |
| **Git hosts** | GitHub (full gates) and Bitbucket Cloud (worktree, PR & merge loop), detected automatically from `origin`. |
| **Install channels** | `git clone` + `himmelctl install` (Linux/macOS), checksummed Linux [release tarballs](https://github.com/yotamleo-org/Himmel/releases), Claude Code plugin marketplace (`marketplace/plugins/`), and Arch PKGBUILD recipe in [`packaging/aur/`](packaging/aur/) (not yet on AUR). |

---

## Contributing

Full workflow in [`docs/contributing.md`](docs/contributing.md); standing agent rules in [`CLAUDE.md`](CLAUDE.md).

1. All work lands through a PR; `main` is protected.
2. One worktree per `<type>/<slug>` branch (`feat`, `fix`, `chore`, `docs`, `refactor`, `test`) created with `scripts/worktree.sh`; never edit on `main`.
3. Conventional Commits with a ticket reference (`type(scope): [PROJ-123] message`); pre-commit and pre-push hooks must pass.
4. New shell scripts stay bash 3.2-safe (for macOS default bash) and ship with a matching smoke test under `scripts/`.

## License

himmel is licensed under the MIT License; see [`LICENSE`](LICENSE).

The vendored fork `marketplace/plugins/telegram-himmel` keeps its upstream
**Apache-2.0** license; see its `LICENSE` file. `scripts/cr/floor-reviewer.md`
is a modified copy of the Apache-2.0 `code-reviewer` agent from
`anthropics/claude-plugins-official` (see [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)).
