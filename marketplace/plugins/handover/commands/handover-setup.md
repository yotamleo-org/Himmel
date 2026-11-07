---
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion, Skill
description: First-time handover bootstrap — pick where handover state lives, persist HANDOVER_DIR to .env, then init/register.
argument-hint: "[handover-dir]"
---

## Your task

Bootstrap the handover system for this operator/repo. The job of this command
is the one-time **setup** the rest of the handover skill assumes is already
done: pick *where* handover state lives, persist that choice so every later
session resolves it the same way, and hand off to the skill's `init`/`register`
flow. Do **not** hardcode any specific repo (e.g. `<state-repo>`) — always ask.

### 1. Resolve the target repo root

Run `git rev-parse --git-common-dir` and take its parent — that is the primary
checkout root (`<repo-root>`), where the gitignored `.env` lives even when you
are inside a worktree. If git fails, stop and tell the user to run from inside a
git repo.

### 2. Detect whether setup already ran

Check both signals:

- **Config:** is `HANDOVER_DIR` already set in the environment, or present as an
  active (uncommented) line in `<repo-root>/.env`?
- **Registry:** does `~/.claude/handover/registry.json` already contain an entry
  whose `path` canonicalises to `<repo-root>`?

Also read `env.HANDOVER_DIR` in `<repo-root>/.claude/settings.json` (it beats
`.env`). If it is present and differs from the `.env` value, setup is not
complete: continue to step 3 so step 4 can reconcile it.

If **both** are present and agree, report the resolved state root and stop with: "Handover
already set up for this repo (HANDOVER_DIR=<…>, registered as '<name>'). Re-run a
specific step with `/handover register` or edit `.env` manually if you need to
change the location." Do not silently re-prompt.

If only one is present, continue — you will fill the missing half.

### 3. Ask where handover state should live

If `$1` (the `handover-dir` argument) was provided, treat it as the operator's
explicit Mode-B path and skip the prompt. Otherwise ask via `AskUserQuestion`:

> **Where should handover state live?**
> - **Inside your vault (Recommended)** — a `handovers/` folder in your
>   luna-style Obsidian vault. State joins the knowledge base (wikilinkable,
>   searchable, graphify-able) and rides the vault's own git. (Mode B)
> - **External state repo** — a separate directory (typically a dedicated repo)
>   so handover commits never land on your feature branches. You'll enter the
>   path. (Mode B)
> - **Inline (this repo)** — state under `<repo-root>/handovers/`. Simplest; no
>   `.env` change. Best for a single-repo setup. (Mode A)

Pick ONE location — duplicated mode (state in both a vault and a state repo) is
unsupported; the resolver reads a single `HANDOVER_DIR` root.

For the **vault** or **external** choice, get the absolute path (the user types
it via the "Other" option or a follow-up). Expect a path ending in `/handovers`
inside a git repo — e.g. `/c/Users/<you>/Documents/<your-vault>/handovers`
(vault) or `/c/Users/<you>/Documents/github/<your-state-repo>/handovers`
(state repo).

### 4. Persist the choice

- **Inline (Mode A):** nothing to write — `HANDOVER_DIR` stays unset and the
  resolver (`scripts/lib/handover-path.sh`) defaults to `<repo-root>/handovers`.
  Continue to step 5 with `<state-root-host>` = `<repo-root>/handovers`.
- **Vault or external (Mode B — both persist identically):** if the chosen
  directory does not exist yet, ask whether
  to create it (`mkdir -p`) — do not write a `HANDOVER_DIR` that points at a
  missing path. Then run the idempotent writer (this never echoes secret values,
  so it passes the secrets guard):

  ```bash
  bash <repo-root>/scripts/handover/set-handover-dir.sh "<chosen-path>"
  ```

  It creates-or-updates the `HANDOVER_DIR=` line in `<repo-root>/.env`. Confirm
  the printed `OK set-handover-dir:` line. `<state-root-host>` = the chosen path.

  Note for the current session: `.env` is read by tools at launch, so the new
  `HANDOVER_DIR` takes effect for shell scripts the next time Claude is launched
  from this repo (the loader `scripts/lib/load-dotenv.sh` picks it up); the
  skill steps below use the path directly.

- **All three choices — reconcile the project's settings pin.** A project
  install (`adopt.sh --profile all`) may have pinned `env.HANDOVER_DIR` in
  `<repo-root>/.claude/settings.json`, and a settings `env` value beats `.env`,
  so a different choice would silently not take effect. Read it:

  ```bash
  jq -r '.env.HANDOVER_DIR // empty' <repo-root>/.claude/settings.json
  ```

  No settings file or no value: nothing to do. Otherwise compare it to the
  chosen root (`<chosen-path>`; for inline, `<repo-root>/handovers`) and act
  only when they differ. The writers live in the himmel clone, which is
  `<repo-root>` in a himmel checkout and `$HIMMEL_REPO` in a project install:

  - **Vault or external:** point the pin at the choice:
    `bash <himmel-clone>/scripts/lib/wire-handover-dir.sh <repo-root>/.claude/settings.json "<chosen-path>"`
  - **Inline:** remove the pin so the repo default applies:
    `bash <himmel-clone>/scripts/lib/unwire-handover-dir.sh <repo-root>/.claude/settings.json`

  Tell the user what changed ("env.HANDOVER_DIR in .claude/settings.json was
  `<old>`, now `<new>` / removed"). Settings are read at launch, so this too
  takes effect from the next Claude launch in the project.

### 5. Initialise or adopt the state

Resolve `<state-root>` = `<state-root-host>/<USER_SLUG>` (USER_SLUG via
`scripts/lib/user-slug.sh`; ask if it cannot be resolved).

- If `<state-root>` has no `.md` items yet → invoke the **handover** skill's
  `init` flow (`Skill` tool, handover) against `<state-root-host>` to seed
  `_templates/` (which holds the `roadmap.md` template), `status.md`,
  `backlog.md`, `counter.md`, and register the repo.
- If `<state-root>` already contains handover items (existing state being
  adopted) → invoke the skill's `register` flow instead (idempotent).

Pass the resolved path so the skill does not re-prompt for it. Follow the full
specs in the skill's `references/init-register.md`.

### 6. Confirm

Print a one-line summary: the mode (inline / vault / external), the resolved
`<state-root>`, and the registered repo name. Suggest the next step by where
this ran:

- **A himmel checkout** (`<repo-root>/marketplace/plugins/handover/` exists):
  `/handover new-epic <name>`.
- **A project install** (that folder is absent): do not suggest `new-epic` or the
  other `new-*` commands, because only a himmel checkout has been shown running
  them. Say that `/handover-resume` here picks up an item already in this repo's
  bucket of the state root.

### Notes

- This command is the **only** place the state-root location is chosen
  interactively. Everything downstream resolves it from `.env` (Mode B) or the
  inline default (Mode A) — never a hardcoded path.
- Re-running is safe: step 2 short-circuits when setup is already complete, and
  `set-handover-dir.sh` + the skill's `register` flow are both idempotent.
