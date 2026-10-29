---
description: Any repo; start or hand over a chief.
argument-hint: new|next [--bucket <slug>] [--name <slug>] [--arm] [--dry-run] [--doc <path>] [--model <m>] [--project <dir>]
---

Starts or hands over a chief (defined in `docs/glossary.md` in the himmel
checkout). Background + the operating contract: `docs/handover/running-a-chief.md`.

This command runs from **any directory**: first resolve the himmel checkout —
`$HIMMEL_REPO` → canonical install paths → error, never the cwd's own git
toplevel (a foreign repo shipping its own `chief.sh` must never win over
himmel's) — then point `chief.sh` at the PROJECT this session is actually
running in via `--project`. That is the whole point of this plugin copy over
the project-local `.claude/commands/chief.md`: a chief started from e.g.
`~/Websites` or a Websites repo gets THAT project's own bucket/prefix derived
from the handover registry (or its basename, unregistered) — never himmel's
own `JIRA_PROJECT_KEY`. The chief itself always runs in the himmel
checkout: `--project` is recorded as data in the chief doc, and a worker for
the project is dispatched into it explicitly with `WORKER_SESSION_REPO=<path>`.

```bash
# Resolve the himmel checkout: $HIMMEL_REPO -> canonical paths -> error. Never
# the cwd's own git toplevel: a foreign repo shipping its own
# scripts/handover/chief/chief.sh would otherwise get ITS script executed
# in preference to himmel's (HIMMEL-3623 verdict J1268O change 5, F6).
REPO="${HIMMEL_REPO:-}"
if [ -z "$REPO" ] || [ ! -f "$REPO/scripts/handover/chief/chief.sh" ]; then
  for c in "$HOME/Documents/github/himmel" "$HOME/Documents/github/Himmel" "$HOME/github/himmel" "$HOME/github/Himmel" "$HOME/Himmel" "$HOME/himmel"; do
    [ -f "$c/scripts/handover/chief/chief.sh" ] && { REPO="$c"; break; }
  done
fi
[ -n "$REPO" ] && [ -f "$REPO/scripts/handover/chief/chief.sh" ] || { echo "ERR: cannot locate himmel checkout — set HIMMEL_REPO to your himmel clone" >&2; exit 1; }

# The chief is FOR the project this session runs in: git toplevel, mapped
# from a linked worktree to its MAIN worktree (git worktree list's first
# entry) so a worktree checkout still resolves to the repo's own registry
# entry. --git-common-dir's dirname is wrong for submodules (yields
# super/.git/modules/<name>) and --separate-git-dir checkouts (yields the
# parent of the git dir) -- change 6, F7.
PROJECT="$PWD"
if TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  PROJECT="$TOPLEVEL"
  MAIN_WT="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -n1)"
  [ -n "$MAIN_WT" ] && PROJECT="$MAIN_WT"
fi

# A bare /himmel-ops:chief (no subcommand) must print usage, not
# "unknown command: --project" (change 9, F11).
#
# --project is only ever DERIVED for `new`. A running chief always lives
# in $REPO by design (see above), so deriving it the same way for `next`
# would force --project=$REPO on every handover of a foreign-project chain
# -- chief.sh's `next` already inherits the predecessor doc's own
# recorded project when none is passed, and an operator's own explicit
# --project in $ARGUMENTS is passed through untouched either way (codex-1,
# pr-check round 1, HIMMEL-3623).
#
# Two more fixes here (codex-1, codex-2, pr-check round 2, HIMMEL-3623):
# the derived --project is appended only when $ARGUMENTS carries none of its
# own, so an operator's explicit `/chief new --project <dir>` still wins
# (chief.sh keeps the LAST --project, so appending ours unconditionally
# always clobbered theirs); and chief.sh is invoked by absolute path with
# no `cd "$REPO"` first, since it resolves its own script dir from
# `${BASH_SOURCE[0]}` and never needs cwd == $REPO, and a `cd` before
# expanding $ARGUMENTS resolved any relative --doc/--project the operator
# passed against the himmel checkout instead of their own cwd.
case "$ARGUMENTS" in
  new|"new "*)
    case "$ARGUMENTS" in
      *--project*) bash "$REPO/scripts/handover/chief/chief.sh" $ARGUMENTS ;;
      *) bash "$REPO/scripts/handover/chief/chief.sh" $ARGUMENTS --project "$PROJECT" ;;
    esac
    ;;
  "")
    bash "$REPO/scripts/handover/chief/chief.sh"
    ;;
  *)
    bash "$REPO/scripts/handover/chief/chief.sh" $ARGUMENTS
    ;;
esac
```

- `/chief new` — write `<handover-root>/<user>/<bucket>/<PREFIX>-nextleg-<date>A-chief.md`
  from `docs/handover/chief-template.md`, acquire the queue lock on it, and
  print the launch line. A second `new` the same day bumps the letter; it never
  overwrites.
- `/chief next` — from a running chief, write the successor stub (letter
  bumped, pointed at this chief and its HANDOFF) plus this chief's
  `-HANDOFF.md` skeleton. Run it at 45 % context fill or after 90 k input
  tokens in one turn.
- `--arm` — also arm the session headed via `scripts/handover/headed-arm.sh`,
  on a signal file plus a deadline; prints the arm log path. Supervisor
  sessions launch with `--autocompact auto` (1m context) by default
  (HIMMEL-3884); pass `--context standard` or set `CHIEF_CONTEXT=standard`
  in the launching shell to opt down to `--autocompact 200000`. The `[1m]`
  model suffix is appended only to the 4.6 family (native-1M and
  non-Anthropic ids launch bare), and a Claude Code below 2.1.280 refuses the
  armed launch with `claude update` named (HIMMEL-5501).
- `--dry-run` — print what it would write, prefixed `would-`, and touch nothing.
- `--bucket <slug>` / `--prefix <P>` — override the project-derived defaults
  (e.g. `/chief new --arm --bucket websites`); the resolved `--project`
  above only supplies the DEFAULT bucket/prefix, it never forces one.
- `--project <dir>` — this plugin copy derives one from the cwd this session
  is running in, but ONLY for `new`, and only when your own arguments carry
  no `--project` of their own — an explicit `/chief new --project <dir>`
  always wins over the derived one (codex-1, pr-check round 2, HIMMEL-3623).
  `next` derives nothing here: with no `--project` of your own, chief.sh
  inherits the predecessor doc's own recorded project instead (codex-1,
  pr-check round 1, HIMMEL-3623); an explicit `--project`/`--bucket`/`--prefix`
  on `next` still wins. To target a different repo on `new` without passing
  `--project`, start the session there, or override just the naming with
  `--bucket`/`--prefix`.

Record the printed `release-token: ` line — now backticked around the token
itself (HIMMEL-2910) — in the chief's first Results bullet verbatim:
releasing the lock at wrap requires it.

Linux/macOS only — `--arm` launches through konsole. The Windows station arms
through `scripts/handover/arm-resume.sh`'s schtasks backend instead.
