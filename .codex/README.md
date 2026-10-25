# `.codex/` — himmel guardrails under Codex (HIMMEL-427)

Wires himmel's PreToolUse / PostToolUse / SessionStart / UserPromptSubmit
guardrails so they fire when himmel runs under **Codex** (which implements a
Claude-compatible hook engine). See `docs/internals/harness-compat.md` for the
full compat matrix.

## Files
- **`hooks.json`** — the project hook config (Codex recognises a project
  `.codex/hooks.json` layer). Every tracked entry uses `command` to invoke
  `run-hook.sh --sandbox <script.sh>`.
  Kept to the strict schema (only a top-level `hooks` key — Codex's parser uses
  `deny_unknown_fields`, so an extra key like `description`/`_comment` would make
  it skip the hooks).
  Includes `block-docker-privesc.sh` + `block-merged-pr-commit.sh` (HIMMEL-589):
  these two SECURITY guards ship via the `himmel-ops` plugin `hooks.json` using
  `$CLAUDE_PROJECT_DIR`, which Codex leaves unset for plugin hooks — so they
  silently no-op under Codex unless mirrored here, where the wrapper
  derives the repo root from its own location.
  Also wires the three advisory **SessionStart** hooks `inject-initiative.sh`,
  `inject-where-are-we.sh`, `inject-doc-freshness.sh` (HIMMEL-596) for the same
  root-resolution reason. These are advisory (always exit 0) and emit their
  `<system-reminder>` on stdout, so `codex-hook-adapter.sh` wraps a
  SessionStart/UserPromptSubmit hook's output into the
  `hookSpecificOutput.additionalContext` JSON channel (raw stdout is not a
  reliable Codex context channel). The wrap is gated on the **event**, not the
  exit code (any exit code → additionalContext; these events have no deny path).
  Adding hooks re-trust-hashes `.codex/hooks.json` on the next Codex session.
- **`run-hook.sh`** — the shell wrapper every entry invokes. Codex injects no
  `CLAUDE_PROJECT_DIR` for project hooks (plugin hooks get
  `CLAUDE_PLUGIN_ROOT`), so the wrapper derives the repo root from its **own**
  location (`.codex/..`) and exports `CLAUDE_PROJECT_DIR` for the guardrail
  scripts. It owns the `--lifecycle` contract and delegates to
  `codex-hook-adapter.sh` (below), because Codex blocks a tool call only on a
  JSON `permissionDecision:"deny"` on stdout and ignores the exit 2 himmel
  guardrails block with.
- **`codex-hook-adapter.sh`** — the exit-code→JSON-decision bridge. Runs the
  named guardrail with the hook JSON on **stdin** (inherited untouched) and, when
  it exits 2 (block), re-emits the block as Codex's JSON
  `permissionDecision:"deny"` with the guardrail's stderr as the reason, exiting
  0. All other outcomes pass through (stdout decisions forwarded, exit code
  propagated). This keeps the guardrails single-sourced: they run verbatim under
  Claude Code, which never invokes the adapter.

## Tests
- `scripts/hooks/test-codex-run-hook.sh` — the `run-hook.sh` wrapper. It
  asserts: `CLAUDE_PROJECT_DIR` derived+exported, stdin forwarded, a normal
  non-block outcome proceeds cleanly, an **exit-2 block translated to a JSON
  `deny`** (stderr → reason), and fail-closed JSON denies for wrapper/adapter
  precondition failures.
- `scripts/hooks/test-codex-sessionstart-hooks.sh` — asserts the three advisory
  SessionStart hooks (HIMMEL-596) are wired through the wrapper, the
  strict schema holds, and `inject-initiative` fires end-to-end through the
  adapter as `additionalContext` JSON (gate ON) / no-op (gate OFF).

## Setup modes
- **Sandboxed project hooks (recommended):** use the tracked `.codex/hooks.json`
  as-is. Every entry passes `--sandbox`, which `run-hook.sh` accepts and
  ignores. Codex needs a writable sandbox (`workspace-write` or wider); `read-only` can suppress hook
  side effects.

## Live-verified (codex-cli 0.141.0, Windows, HIMMEL-427)
Confirmed against a real `codex exec` run: `.codex/hooks.json` parses (no
`deny_unknown_fields` rejection), the guardrails **fire and block** —
`block-read-secrets` denies a secret read (`PreToolUse Blocked`), and a benign
command is allowed. The exit-2→`deny` translation in `codex-hook-adapter.sh` is
what makes the block land (Codex ignores exit 2). Caveats observed live:
- Codex runs hooks **inside the tool sandbox**; a `read-only` sandbox suppresses
  their side effects, so the interactive default (`workspace-write`) or wider is
  needed for them to act.
- Run from a git **worktree**, Codex loads project hooks from the **main
  checkout** (the worktree's `.git` is a file) — trust/edit hooks there.
- New project hooks are trust-hashed on first use; interactive Codex prompts to
  trust them once (non-interactive `codex exec` needs
  `--dangerously-bypass-hook-trust`).
See `docs/internals/harness-compat.md` §"Codex deep-dive → Hooks" for detail.

## codex-cli 0.142.0 note (HIMMEL-533)
Once the project hooks are **already trusted** (persisted from a prior
interactive trust, or this checkout's hooks already hashed), plain
`codex exec "<prompt>"` runs **without** `--dangerously-bypass-hook-trust` — the
flag is only the first-run / still-untrusted non-interactive path. (The flag
still exists in 0.142.0; this README's live-verified block above is 0.141.0.)
Skill discovery: Codex reads **project-local `.agents/skills/<name>/SKILL.md`**
from the run cwd — live-verified under 0.142.0 (HIMMEL-533 ships the himmel
driver skills there).
