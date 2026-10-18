# i-have-adhd — vendored output-shaping plugin

Shapes agent output for a reader with ADHD: lead with the next action, number
multi-step work, restate state, suppress tangents, give specific time
estimates, make wins visible. Vendored verbatim from
[`ayghri/i-have-adhd`](https://github.com/ayghri/i-have-adhd) (MIT).

## Pin

| Field | Value |
|---|---|
| source | `https://github.com/ayghri/i-have-adhd` |
| commit | `723af7d9afaf43eb871dbcce6129e2bf80de90d5` |
| license | MIT, Copyright (c) 2026 Ayoub Ghriss (`LICENSE`, copied verbatim) |
| vendored | 2026-10-11 (HIMMEL-5239) |
| upstream version | `0.4.1`; local manifest `0.4.2` (version-bump gate, always-on.ps1 dropped with Windows); no release tag, so the pin is a commit and there is no `scripts/upstreams.json` row |
| taken, byte for byte | `hooks/hooks.json`, `hooks/always-on.mjs`, `hooks/always-on.sh`, `skills/i-have-adhd/SKILL.md`, `LICENSE` |
| left out | `skills/i-have-adhd/agents/` (Codex/Gemini interface metadata), `.codex-plugin`, `.agents`, `.cursor`, `.opencode`, `extensions/`, `gemini`/`qwen`/`kimi` manifests, `evals/`, `scripts/`, `tests/`, `.github/` (translations and CI), `package.json`, `AGENTS.md`, `GEMINI.md` |

Do not edit vendored files locally: a local edit turns the next re-vendor into
a merge. himmel's framing lives in this README and in `docs/`.
Repair is a reviewed re-vendor (re-copy the listed files at the new commit and
update the pin above), never a hand edit.

## What it does, and what it costs

- **Skill `/i-have-adhd`**: `disable-model-invocation: true`, so it is invoked
  only by the user, adds no entry the model sees in its skill listing, and stays
  on for the session until the reader says "stop adhd mode".
- **Hook**: one `SessionStart` hook (`startup|resume|clear|compact`). It checks
  for the flag file `$CLAUDE_CONFIG_DIR/.i-have-adhd-always` (default
  `~/.claude/.i-have-adhd-always`). Absent: it prints nothing, 0 tokens.
  Present: it prints the skill body (6781 bytes, about 1.75k tokens) once per
  SessionStart, which then sits in the cached prefix.
- **Per turn**: nothing. There is no per-prompt hook.
- **Always-on is created by himmel's installer and updater, never by this
  plugin** (HIMMEL-5239). `scripts/machine-setup/install-plugins.sh` and
  `scripts/himmel-update.sh` both call
  `scripts/machine-setup/enable-i-have-adhd-always.sh`, which creates
  `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.i-have-adhd-always` when
  `i-have-adhd@himmel` is installed and prints one line saying so. It is
  idempotent: a present flag is a silent no-op. By hand: `touch` or delete that
  file.
- **Opt out: `HIMMEL_NO_ADHD_ALWAYS=1`** (also `true`/`yes`) in the shell that
  runs the installer or updater. The flag is then never created, so deleting it
  sticks. Without the opt-out an updater run recreates a deleted flag. The
  installer does not remove the flag on uninstall.
- Hook review (HIMMEL-5239): all three hook implementations were read in full.
  No network, no installs, no writes, no settings changes; any failure exits 0.

## Overlap

Overlaps the Concise output style and the `prose-audit` skill: the output style
sets brevity for every reply, `prose-audit` lints written prose after the fact,
and this skill shapes the reply for an ADHD reader (action first, numbered
steps, one next action). Use whichever fits; they do not conflict.

## Where it is enabled

`i-have-adhd@himmel` is in `base` in `scripts/lanes/plugin-profiles.json`
beside `lean-skills@himmel`, so every non-bare lane inherits it; the relay and
judge profiles drop it.
