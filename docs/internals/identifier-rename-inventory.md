# Identifier rename inventory (HIMMEL-5689, step 1)

Every code identifier whose plain doc name differs from the repo name, per the
alias tables in [`../glossary.md`](../glossary.md) (HIMMEL-5504, HIMMEL-5585).
This is the plan the rename PRs execute; it renames nothing itself.

Counts are `git grep -l` file hits at `239670d87`, excluding `docs/glossary.md`
and `handovers/`. Re-run the recipe at the bottom before starting any PR: the
tree moves.

Operator rulings (HIMMEL-5689 comments, 2026-10-15): the rename overrides the
glossary's never-rename rule for repo identifiers; every old name stays a
**read-both alias for one release**, pinned by a test; the short name for
*supervisor session* is **chief**; v1.1.3 (2026-10-22) carries all of it, and
the rename PRs start once 5629, 5508 and 5691 land.

## Scope: what is and is not a code identifier

Of the 15 glossary alias rows, only the rows below have a code identifier.
The rest are prose-only (nothing to rename): *auto-ship step*, *finding
status*, *review round / diff-only round*, *GO file*, *sanctioned script*
(`chokepoint-*` names are an exception, F12), *warn-only*, *off switch*,
*worker system prompt* (prose; the `*-preface.md` file names are F8).

**New names below are proposals** except `chief`. The console rules them
before the first rename PR; the alias mechanics do not depend on the choice.

## Rows (one per rename family)

Size: XS < 5 files, S 5-15, M 16-40, L 41-100, XL > 100 hit files. Collision
columns: 5629 = `scripts/hooks`, `scripts/lib/[q-z]*`; 5508 = `docs/handover`
leg prefaces + console template; 5691 = skills/commands.

| # | Old name | Proposed new name | Hit files (5629 / 5508 / 5691 overlap) | Defined by | Alias mechanism | Pin test | Size |
|---|---|---|---|---|---|---|---|
| F1 | `HIMMEL_CONSOLE_LEG`, `_RELAY`, `_JUDGE` (identity markers, 638/109/38 occurrences) | `HIMMEL_CHIEF_WORKER`, `HIMMEL_CHIEF_RELAY`, `HIMMEL_CHIEF_JUDGE` | 96 (39 / 2 / 0) | exported by `scripts/handover/console-kit/headed-arm-leg.sh`; read by ~35 hooks, `go.sh`, `inbox-send.sh`, `merge-on-green.sh` | writer exports **both**; every reader tests new then old (`scripts/lib` helper `env-alias.sh`, P0). A guard that keys on the marker must deny when either is set | a guard test per family: old var alone still trips `go.sh` refusal and `guard-judge-writes.sh`; new var alone does too | L |
| F1b | `HIMMEL_CONSOLE_DOC`, `_NAME`, `_WORKDIR`, `_RUNDIR`, `_JUDGE_{DOC,QID,EFFORT}` | `HIMMEL_CHIEF_*` | within F1 | `arm-resume.sh:4985`, `:6201`; `headed-arm-leg.sh` | read-both via helper; writers export both | `console-precompact-snapshot` test reads old var only | M |
| F2 | `HIMMEL_LEG_{CONTEXT_MODE,AUTOCOMPACT,PROFILE,CONTEXT_SHARE,FAILURES_LEDGER}`, `HIMMEL_LEAN_LEG` | `HIMMEL_WORKER_*`, `HIMMEL_LEAN_WORKER` | 41 (9 / 1 / 0) | `headed-arm-leg.sh`; read by `guard-leg-context-handoff.sh`, `scripts/eval/leg-digest/` | read-both helper | existing `HIMMEL_LEG_CONTEXT_MODE` tests (3) gain an old-name case | M |
| F3 | `CADENCE_BANK_*`, `BANK_LIFT_*`, `CODEX_BANK_*`, `CLAUDEX_BANK_*`, `PARKED-BANK` | `CADENCE_BUDGET_*`, `BUDGET_LIFT_*`, `CODEX_BUDGET_*`, `CLAUDEX_BUDGET_*`, `PARKED-BUDGET` | 101 (18 / 0 / 0) | `scripts/lib/bank-preflight.sh`, `bank-lift.sh`, `bank-monitor.sh`; consumers across `scripts/handover`, `lanes`, `config-ui` | read-both helper. `PARKED-BANK` is a **marker token** the tick parses: accept both, emit old until the release after | `bank-preflight` test gets an old-var case; tick parser test for the marker | L |
| F4 | `bank-preflight.sh`, `bank-lift.sh`, `bank-monitor.sh`, `bank-attribution.sh`, `bank-status` | `budget-*.sh` | 188 (29 / 3 / 2) | `scripts/lib/`; invoked by name from 148 files; allow rules in settings name `bank-preflight.sh` literally | old path becomes a one-line wrapper `exec`ing the new script (allow rules and `CLAUDE.md` keep working); settings allow-list gets both | wrapper test: old path forwards args and exit code | XL |
| F5 | `clear-cr-marker.sh`, `cr-*.sh` helpers, `CR_MARKER*`, the `<git-dir>/cr-pending/<branch>` marker path | `clear-review-marker.sh`, `review-*.sh`, `REVIEW_MARKER*` | 127 (35 / 1 / 2) | `scripts/cr/`, `scripts/lib/cr-*.sh`; `check-cr-marker-on-pr-create.sh`; allow rules name `clear-cr-marker.sh` and `/pr-check` absolute paths | wrapper script at old path; marker path: `clear-cr-marker.sh` and `check-cr-marker-on-pr-create.sh` read both `cr-pending/` and the new dir, the pre-push hook writes the new one | `test-clear-cr-marker.sh` runs once through the old path | XL |
| F6 | `headed-arm-leg.sh` | `headed-arm-worker.sh` | 114 (23 / 6 / 0) | `scripts/handover/console-kit/` | wrapper at old path; allow rules and `leg preface` text name it | wrapper test | L |
| F7 | `leg-identity.sh`, `leg-doc-lock.sh`, `leg-event.sh`, `leg-jira-status.sh`, `leg-pretrust.sh`, `leg-transcripts.sh`, `leg-graph.sh`, `leg-digest*`, `close-wrapped-leg.sh` | `worker-*.sh` | 116 (6 / 2 / 0) | `scripts/lib/leg-identity.sh`, `scripts/handover/console-kit/`, `scripts/eval/leg-digest/`, `scripts/graphify/leg-graph.sh` | wrapper per script. `leg-identity.sh` also keeps parsing the legacy `…-leg[N]<k>-…` doc names (already does) | one wrapper test per directory | L |
| F8 | `scripts/handover/console-kit/` (directory) and `leg-preface*.md`, `console-template.md` | `scripts/handover/chief-kit/` | 218 (26 / 5 / 0) | directory path in 218 files, settings allow rules, `ci-trust-paths.txt`, `check-ci` shards | directory **symlink** `console-kit` to `chief-kit`; CI trust paths list both | `ls console-kit/go.sh` resolves; trust-path test | XL |
| F9 | `/console` command, `console.sh`, `console-context.sh`, `scripts/console/`, `scripts/handover/console/`, `.claude/commands/console.md`, himmel-ops `commands/console.md` | `/chief` | 73 (8 / 1 / 2) | `.claude/commands/`, `marketplace/plugins/himmel-ops/commands/`, `scripts/handover/console/console.sh` | command alias file `console.md` forwarding to `chief.md`; wrapper for `console.sh` | `test-console-cmd-resolution.sh` resolves both | M |
| F10 | `overnight-shift` (command, `scripts/overnight/`), `overnight-mode.md`, `OVERNIGHT_*` env | `afk-shift`, `afk-mode.md` | 54 (2 / 0 / 7) | `.claude/commands/overnight-shift.md`, `scripts/overnight/`, plugin skills | command alias; `overnight-mode.md` kept as a redirect stub (docs link it) | command-resolution test | M |
| F11 | `watchdog` in env/script/hook names | `auto-relaunch` | 75 (16 / 0 / 4) | `scripts/telegram/`, `scripts/lib`, hooks | read-both env; wrapper for scripts. **Ambiguous word**: glossary scopes it to the auto-arm hooks only, so each hit needs a read before renaming (many are a wall-clock killer = "run timeout") | env alias test | M |
| F12 | `chokepoint-*` (`chokepoint-seam-guard.sh`, `block-chokepoint-env-prefix.sh`, `CHOKEPOINT_*`) | `sanctioned-script-*` | not counted: **glossary marks this docs-only**; confirm before including | `scripts/lib`, `scripts/hooks` | wrapper | n/a | hold |
| F13 | `class-sweep` (`write-verdicts.sh sweep`, `SWEEP` ledger rows, `missing-class-sweep` exit text) | `sibling-sweep` | 16 (1 / 1 / 0) | `scripts/cr/`, `scripts/eval/` | read-both ledger keyword; exit-14 reason string emitted under both | `clear-cr-marker` refusal test accepts either spelling | S |
| F14 | `speed bump` (hook messages, `himmelctl` text) | `soft block` | 10 (5 / 0 / 0) | `scripts/hooks/`, `scripts/himmelctl` | message text only | none needed (strings) | XS, **after 5629** |
| F15 | `chain`/`wave` idents (`HIMMEL_*_WAVE`, `*_CHAIN`, `wave-` files) | `sequence`, `batch` | 11 (0 / 0 / 1) | `scripts/handover`, plugins | read-both env | env alias test | S |

## Do not rename (data contracts)

- **Session-name suffixes** `-console`, `-relay`, `-N<k>-`, `-judge-<qid>`:
  scorecard classifiers, `leg-identity.sh` and `verdict-template.md` key on
  them, and old session transcripts keep the old names forever. Renaming
  silently misclassifies burn data (glossary, Session-name suffix contract).
  If `chief` must appear in names, accept `-chief` **additionally**, never
  instead.
- `HIMMEL_FLEET_CAP`, `HIMMEL_INITIATIVE`, `HIMMEL_HOOK_INTEGRITY_BYPASS_OK`:
  no doc rename (the *off switch* row is prose).
- `bypassPermissions`, `handover`, `trailer`, `floor`, `anchor`, `arm`, `lane`,
  `queue lock`: glossary "not renamed on purpose".

## Alias mechanisms (the four shapes)

1. **Read-both env var** — one helper, `scripts/lib/env-alias.sh`
   (`alias_env NEW OLD` exports `NEW` from `OLD` when only `OLD` is set).
   Writers export both; guards that key on a marker treat either as set.
2. **Wrapper script** at the old path: `exec "$(dirname "$0")/<new>.sh" "$@"`,
   so settings allow rules, `CLAUDE.md` and operator muscle memory keep
   working.
3. **Directory symlink** for `console-kit` (git tracks it; Windows stations
   need `core.symlinks`, which is a hazard: see Risks).
4. **Command alias file** forwarding one slash command to the other.

## Rename PRs (disjoint file sets, in order)

Each PR renames every family's identifiers **inside its own paths only**, so
two PRs never touch one file. Writers land before readers, so readers always
see a name that exists.

| PR | Owns | Families | Size | Can start before 5629 / 5508 / 5691? |
|---|---|---|---|---|
| P0 | new `scripts/lib/env-alias.sh` + test, `docs/glossary.md` (drop the never-rename rule, add the alias table) | foundation | S | **Yes** (new files; `env-alias.sh` sorts under `a-p`, outside 5629's `q-z`) |
| P1 | `scripts/handover/**` (launchers first) | F1, F1b, F2, F3, F6, F7 in place | L | **Yes** (no 5629/5508/5691 paths) |
| P2 | `scripts/cr/**`, `scripts/ci/**`, `scripts/guardrails/**` | F3-F7 readers, F5, F13 | L | **Yes** (`scripts/ci/ci-trust-paths.txt` entries need trust review) |
| P3 | `scripts/lanes/**`, `scripts/eval/**`, `scripts/config-ui/**`, `scripts/api-lane/**`, `scripts/cloud/**`, `scripts/probes/**`, `scripts/graphify/**`, `scripts/luna/**`, `scripts/statusline/**`, `scripts/*.sh` | readers of F1-F7 | L | **Yes** |
| P4 | `scripts/lib/[a-p]*` (the `bank-*` and `cr-*` scripts, `console-context.sh`, `leg-identity.sh`) | F3-F7 definers + wrappers | L | **Yes** |
| P5 | `scripts/telegram/**`, `scripts/overnight/**`, `scripts/hermes/**`, `scripts/codex/**`, `marketplace/plugins/**` except skills and commands | F10, F11, F14-F15 | M | **Yes** (plugin hooks such as `guard-judge-writes.sh` are 5691-adjacent: re-check) |
| P6 | `scripts/hooks/**`, `scripts/lib/[q-z]*` | F1-F7, F11, F14 readers | L | **No: after 5629** |
| P7 | `docs/handover/**` prefaces and console template, `docs/**`, `README.md`, `llms.txt`, `templates/**` | prose + code spans in docs | L | **No: after 5508** (prefaces and console template) |
| P8 | `.claude/commands/**`, plugin `commands/` and `skills/`, `console-kit` symlink | F8, F9, F10 | M | **No: after 5691** |

Order: P0, then P1 (writers), then P2-P5 in parallel (disjoint), then P6, P7,
P8 as their blockers land. P8's symlink goes last so every PR before it still
resolves `console-kit` by its real path.

**Starts now (before any blocker lands): P0, P1, P2, P3, P4, P5 — six PRs.**
Waits: P6 (5629), P7 (5508), P8 (5691).

## Risks and open rulings

1. **Names**: only `chief` is ruled. Console to confirm `HIMMEL_CHIEF_WORKER`
   (the marker is sensitive: `go.sh` and the judge write-guard key on it) and
   `budget` for `bank`. A wrong name costs a second rename; the alias
   mechanics do not change.
2. **Allow rules** in `.claude/settings.json` name `clear-cr-marker.sh`,
   `merge-on-green.sh`, and the leg scripts literally. Wrappers keep them
   valid; a settings edit is operator-only, so add the new names in a
   separate operator step, not in a rename PR.
3. **`ci-trust-paths.txt`** patterns cover parts of `scripts/handover` and
   `scripts/hooks`: P1, P2, P6 need a trust-reviewed GO.
4. **Symlink on Windows stations** (`core.symlinks`): decide before P8 whether
   F8 uses a symlink or a duplicated thin dir.
5. **Fleet quiet**: P1-P5 touch files that live legs read. The operator said
   dispatch when the fleet is quiet; the console decides when.
6. F12 (`chokepoint`) and F11 (`watchdog`) need a per-hit read first;
   estimated size assumes that read.

## Recipe

```
git grep -l -E '<old-name-regex>' -- . ':!docs/glossary.md' ':!handovers'
```

One line per family: F1 `HIMMEL_CONSOLE_[A-Z_]+`, F2 `HIMMEL_(LEG|LEAN_LEG)[A-Z_]*`,
F3 `CADENCE_BANK_[A-Z_]+|BANK_LIFT[A-Z_]*|CODEX_BANK_[A-Z_]+|CLAUDEX_BANK_[A-Z_]+`,
F4 `bank-preflight|bank-lift|bank-status`, F5 `clear-cr-marker|cr-marker|CR_MARKER`,
F6 `headed-arm-leg`, F7 `leg-(identity|doc-lock|event|jira-status|pretrust|transcripts|graph|digest|preface)`,
F8 `console-kit`, F9 `commands/console|/console |console\.sh`,
F10 `overnight-(shift|mode)`, F11 `watchdog`, F13 `class-sweep|class sweep`,
F14 `speed.bump`, F15 `HIMMEL_[A-Z_]*(WAVE|CHAIN)[A-Z_]*|wave-|chain-id`.
