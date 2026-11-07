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

- **Config:** is `HANDOVER_DIR` already set in the environment, or does
  `<repo-root>/.env` hold an active (uncommented) `HANDOVER_DIR=` line? An empty
  line is the recorded inline choice, so it counts as set. Do not read `.env`
  yourself (the secrets guard refuses it); ask the loader for that one layer
  (`<himmel-clone>` is `<repo-root>` in a himmel checkout and `$HIMMEL_REPO` in a
  project install). `<env-value>` is its output: `unset` means no line, empty
  means inline. A non-zero exit (for example a wrong clone path) is a failed
  read, not `unset`:

  ```bash
  env -u HANDOVER_DIR HIMMEL_CONFIG_DIR=/nonexistent bash -c '. <himmel-clone>/scripts/lib/load-dotenv.sh && load_dotenv --root <repo-root> HANDOVER_DIR 2>/dev/null && printf "%s" "${HANDOVER_DIR-unset}"'
  ```
- **Registry:** does `~/.claude/handover/registry.json` already contain an entry
  whose `path` canonicalises to `<repo-root>`?

Also run the three reads of step 4's reconcile (substeps 1 to 3: the project
pin, the user-scope pin and the himmel config files; they beat `.env`, same
stop-on-failure rule). The value that wins is the project pin, else the
user-scope pin, else the config value, else `<env-value>`; an empty `<env-value>`
means `<repo-root>/handovers` for this comparison. If the `.env` has a
`HANDOVER_DIR` line (empty or not) and the winning value differs from
`<env-value>`, setup is not complete: continue to step 3 so step 4 can reconcile
it. (A project pin equal to `<env-value>` over a different config root is
complete: the pin wins and agrees.) Without an `.env` line, the winning value is
the configured value on its own (a project install wrote it).

If **both** are present and agree, report the resolved state root and stop with: "Handover
already set up for this repo (HANDOVER_DIR=<…>, registered as '<name>'). Re-run a
specific step with `/handover register`, or tell me you want a different
location and I will ask again." If they say so, continue to step 3. Do not
silently re-prompt.

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
> - **Inline (this repo)** — state under `<repo-root>/handovers/`, found only
>   from `<repo-root>` itself, never from a git worktree of it (Claude Code and
>   himmel workers cut worktrees on demand). The `.env` gets an empty
>   `HANDOVER_DIR=` line. Only for work done in the primary checkout. (Mode A)

Pick ONE location — duplicated mode (state in both a vault and a state repo) is
unsupported; the resolver reads a single `HANDOVER_DIR` root.

For the **vault** or **external** choice, get the absolute path (the user types
it via the "Other" option or a follow-up). Expect a path ending in `/handovers`
inside a git repo — e.g. `/c/Users/<you>/Documents/<your-vault>/handovers`
(vault) or `/c/Users/<you>/Documents/github/<your-state-repo>/handovers`
(state repo).

### 4. Persist the choice

Both `.env` writers below are `scripts/handover/set-handover-dir.sh`. Use the
project's own copy (`<repo-root>/scripts/handover/set-handover-dir.sh`, copied by
a project-scope install); a project without one (a user-scope install) uses the
himmel clone's copy (`$HIMMEL_REPO/scripts/handover/set-handover-dir.sh`) with
`--env-file <repo-root>/.env`. `<writer>` below means that command.

- **Inline (Mode A):** inline does not work from a git worktree yet, whether or
  not one exists today: the resolver (`scripts/lib/handover-path.sh`) resolves
  inline to `git rev-parse --show-toplevel`, which in a worktree is
  `<worktree>/handovers`, not `<repo-root>/handovers`. A session there finds none
  of the primary's state, `/handover-resume` exits 2, and a write path
  (`handover_root_ensure`) silently creates an empty `<worktree>/handovers` and
  strands the new state in it. Always tell the user this plainly before writing
  anything (`git -C <repo-root> worktree list` showing more than one line means
  it applies already) and recommend vault or external; continue with inline only
  if they confirm they will work from `<repo-root>` itself. Then record the
  choice as an empty `HANDOVER_DIR=` line in `<repo-root>/.env`:

  ```bash
  bash <writer> --inline
  ```

  An empty value reads as unset, so the resolver defaults to
  `<repo-root>/handovers` when run from `<repo-root>`. The line replaces a vault
  or external path left by an earlier choice and is what stops a later re-run of
  `adopt.sh` from pinning the vault again. Confirm the printed
  `OK set-handover-dir:` line; on any other result stop and show it. If the
  writer prints `unknown flag: --inline`, the project's copy predates the flag:
  re-run `adopt.sh` to refresh it, or use the himmel clone's copy with
  `--env-file <repo-root>/.env`. Then do the reconcile below, then continue to
  step 5 with `<state-root-host>` = `<repo-root>/handovers`.
- **Vault or external (Mode B — both persist identically):** if the chosen
  directory does not exist yet, ask whether
  to create it (`mkdir -p`) — do not write a `HANDOVER_DIR` that points at a
  missing path. Then run the idempotent writer (this never echoes secret values,
  so it passes the secrets guard):

  ```bash
  bash <writer> "<chosen-path>"
  ```

  It creates-or-updates the `HANDOVER_DIR=` line in `<repo-root>/.env`. Confirm
  the printed `OK set-handover-dir:` line; on any other result stop and show it.
  The writer stores the canonical absolute path (`<canonical-path>`), which may
  differ from what the user typed (relative, trailing slash). Get it without
  reading `.env` (the secrets guard refuses that):
  `bash -c 'cd "<chosen-path>" && pwd'`. `<state-root-host>` = `<canonical-path>`.

  Note for the current session: `.env` is read by tools at launch, so the new
  `HANDOVER_DIR` takes effect for shell scripts the next time Claude is launched
  from this repo (the loader `scripts/lib/load-dotenv.sh` picks it up); the
  skill steps below use the path directly. Then do the reconcile below before
  step 5.

- **All three choices — reconcile what outranks `.env`.** Three sources beat
  `.env`: the project's settings pin, the user-scope settings pin, and the
  himmel config files. A different choice would silently not take effect while
  one of them holds another root. Do all of substeps 1 to 3 in order; an absent
  file in one is not a reason to skip the next. Read the two settings files with
  the Read tool, never `jq` or `grep` on a shell line: the secrets guard refuses
  a `jq` filter such as `.env.HANDOVER_DIR` (it matches `.env.*`). In each read,
  a failure (a file that exists but cannot be read or parsed, a guard refusal, a
  non-zero exit) is not "no value": stop and show the error, because the choice
  is not applied until it is read. The writers live in
  the himmel clone, which is `<repo-root>` in a himmel checkout and
  `$HIMMEL_REPO` in a project install. `<choice>` is `<canonical-path>`; for
  inline it is `<repo-root>/handovers`.

  1. **Project pin.** If `<repo-root>/.claude/settings.json` does not exist,
     there is no project pin: go to substep 2. Otherwise Read that file and take
     `env.HANDOVER_DIR` from the JSON. No `env` object, no `HANDOVER_DIR` key or
     an empty string means no pin; invalid JSON is a failed read. `<project-pin>`
     is the value read.
  2. **User-scope pin.** A user-scope install (`adopt.sh --scope user`) may have
     pinned `env.HANDOVER_DIR` in `~/.claude/settings.json`. Read it the same
     way (an absent file means none). `<outer>` is that value.
  3. **Config files.** `scripts/lib/load-dotenv.sh` reads `~/.himmel/himmel.conf.local`,
     the active station profile and `~/.himmel/himmel.conf` before `.env`, and
     `adopt.sh` writes no pin when one holds a `HANDOVER_DIR`. Read the winning
     value with the loader itself:

     ```bash
     bash -c '. <himmel-clone>/scripts/lib/load-dotenv.sh && _himmel_config_layers HANDOVER_DIR'
     ```

     It prints `HANDOVER_DIR=<value>` or nothing. If `<outer>` is empty, a
     value here becomes `<outer>`. (A settings `env` value still beats these
     files, so a pin written below wins over them.)
  4. **Apply**, only where something differs from `<choice>`:
     - `<outer>` is non-empty and differs from `<choice>`: this project needs its
       own pin, even when it had none, because a project setting beats a user
       setting and any config file. Run
       `bash <himmel-clone>/scripts/lib/wire-handover-dir.sh <repo-root>/.claude/settings.json "<choice>"`
       (inline too: wire `<repo-root>/handovers` instead of removing). Tell the
       user the user-scope pin or config value is unchanged; never edit
       `~/.claude/settings.json` or `~/.himmel/himmel.conf*` here.
     - Else `<project-pin>` is non-empty and differs from `<choice>` (inline:
       any pin): vault or external, point it at the choice with the same
       `wire-handover-dir.sh` command; inline, remove it with
       `bash <himmel-clone>/scripts/lib/unwire-handover-dir.sh <repo-root>/.claude/settings.json`.

     If a writer exits non-zero, stop and show its output: `.env` is already
     written but the pin is not, so the choice is only half applied. Do not go on
     to step 5 and do not print the step 6 summary. Step 6 names only a mode
     that wins: the user-scope pin and the config files rank below the project
     pin, so leaving them is fine once the project pin is right; but if a source
     that outranks the project pin (for example `.claude/settings.local.json`)
     holds another root, do not report the choice as applied.

     **Expected warning.** With a project pin written over a config root,
     `/handover-resume` (`resume.sh`) prints "exported HANDOVER_DIR (...)
     overrides the configured root (...); unset it to follow the root
     /handover-setup chose". On this path the warning is expected and backwards:
     the pin is the root `/handover-setup` chose and `resume.sh` compares it with
     the config root it reads. Tell the user to ignore it and not to unset the
     pin.

     Tell the user what changed ("env.HANDOVER_DIR in .claude/settings.json was
     `<old>`, now `<new>` / removed"). Settings are read at launch, so this
     takes effect from the next Claude launch in the project.
  5. **Will worktrees see it?** Run
     `git -C <repo-root> ls-files --error-unmatch .claude/settings.json` when
     substep 4 wrote or removed a project pin.
     - **Tracked** (a committed install): only the working copy in `<repo-root>`
       changed. Every worktree and every other clone reads its own checked-out
       settings file and keeps the old pin, so their sessions keep reading and
       writing the old root until the change lands. Tell the user to commit the
       settings change on a branch and merge it through a PR, never on main.
     - **Untracked** (a user-scope install creates this file untracked): a
       worktree cut from HEAD has no such file, so it falls back to
       `<outer>` (the old root) and a new clone does too. Tell the user the
       choice holds only in `<repo-root>` until they either add the file and
       commit it on a branch (a PR, never on main) or change the user-scope pin
       or config value to the new root. Do not say "needs committing" for a file
       that was never committed.

     Say what the worktrees do meanwhile. Do not commit anything yourself.

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
  `set-handover-dir.sh` (both forms) + the skill's `register` flow are idempotent.
- Re-running `adopt.sh` keeps the choice: it leaves a `HANDOVER_DIR` line in the
  project's `.env`, empty or not, alone and does not pin a vault over it.
- `load_dotenv` prints a `DEPRECATED ... HANDOVER_DIR read from .env` notice for
  this line, empty or not. For the inline record that notice is expected: do not
  delete the line, because a later `adopt.sh` run would then pin the vault again
  (`himmel.conf` cannot hold the record: it skips an empty value). Tell the user
  the notice is the cost of the inline record.
