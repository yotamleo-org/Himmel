# Identifier rename proposal (HIMMEL-5689, step 2: for operator approval)

PROPOSE ONLY. This file renames nothing. It is the per-name table the operator
approves, changes or drops row by row; after the refactor lands the names are
frozen (see [Freeze](#freeze)). The family plan, the nine rename PRs P0-P8 and
the data-contract list live in
[`identifier-rename-inventory.md`](identifier-rename-inventory.md); this file
refines that inventory from per-family to per-old-name.

Counts are measured at `c058a5916481a2424081346a7c1f4cee6fc672ec`, over the whole repo (`git grep -c -I -E`),
excluding `docs/glossary.md`, `handovers/`, the inventory doc and this file.
`lines/files` = matching lines / files containing a match. Rows are measured by
regex, so a row can include hits that are not the identifier (marked AMBIGUOUS).
Hits under `archive/windows/` are counted (they are in the tree) but Windows is
dropped: no row proposes a Windows, WSL or PowerShell mechanism, and the P-PR that
reaches those files may delete rather than rename.

Alias plan terms: **env** = read-both via `scripts/lib/env-alias.sh`
(`alias_env NEW OLD`, `env_alias_any`); **wrapper** = script at the old path that
`exec`s the new one; **symlink**; **command alias**; **accept-both token**.
Risk terms: **data contract** = the old spelling is persisted somewhere that
outlives the rename; **allow-rule literal** = `.claude/settings.json` names the
path or name literally (operator-only edit); **ci-trust-path** = the file matches
`scripts/ci/ci-trust-paths.txt` (notably all of `scripts/lib/`, `scripts/ci/`,
`go.sh`, `clear-cr-marker.sh`, `merge-on-green.sh`, `.claude/settings.json`), so its
change needs a trust-reviewed GO; **AMBIGUOUS** = the word has other meanings and
each hit needs a read.

## First rename-PR step (P1 prerequisite, out of scope here)

Harden `scripts/lib/env-alias.sh` before any family row below lands:
1. validate NEW and OLD as shell identifiers (reject anything else);
2. make `env_alias_any` fail closed (an invalid or unreadable name denies);
3. add the NEW-empty / OLD-set row to its test.
The 2885 judge asked for this; it is not part of this proposal PR.

## Proposed rename table

`#` is the row id used in the decision list. Decision default is **approve**.

| # | Family | Old name | Proposed new name | Kind | Hits (lines / files) | Top owning paths (files) | Read-both alias plan | Risk |
|---|---|---|---|---|---|---|---|---|
| 1 | F1 | `HIMMEL_CONSOLE_LEG` | `HIMMEL_CHIEF_WORKER` | env var | 660 / 78 | `scripts/handover/console-kit/` (10); `scripts/hooks/fixtures/` (6); `scripts/handover/fixtures/` (2) | read-both; guard on the marker uses `env_alias_any` (deny if either set) | data contract (identity marker; `go.sh`, judge write-guard key on it); ci-trust-path (`go.sh`) |
| 2 | F1 | `HIMMEL_CONSOLE_RELAY` | `HIMMEL_CHIEF_RELAY` | env var | 107 / 30 | `scripts/handover/console-kit/` (10); `CHANGELOG.md` (1); `docs/handover/relay-brief-template.md` (1) | read-both; guard on the marker uses `env_alias_any` (deny if either set) | data contract (identity marker; relay write-guard) |
| 3 | F1 | `HIMMEL_CONSOLE_JUDGE` | `HIMMEL_CHIEF_JUDGE` | env var | 37 / 13 | `scripts/handover/console-kit/` (6); `docs/handover/judge-preface.md` (1); `docs/internals/enforcement.md` (1) | read-both; guard on the marker uses `env_alias_any` (deny if either set) | data contract (identity marker; judge write-guard) |
| 4 | F1b | `HIMMEL_CONSOLE_DOC` | `HIMMEL_CHIEF_DOC` | env var | 115 / 17 | `docs/internals/enforcement.md` (1); `scripts/handover/arm-resume.sh` (1); `scripts/handover/console-kit/` (1) | read-both: `alias_env NEW OLD` in readers; writers export both | none beyond the shared env contract |
| 5 | F1b | `HIMMEL_CONSOLE_NAME` | `HIMMEL_CHIEF_NAME` | env var | 104 / 18 | `scripts/handover/console-kit/` (2); `CHANGELOG.md` (1); `docs/handover/console-template.md` (1) | read-both: `alias_env NEW OLD` in readers; writers export both | none; value is a session name and keeps its `-console` suffix |
| 6 | F1b | `HIMMEL_CONSOLE_WORKDIR` | `HIMMEL_CHIEF_WORKDIR` | env var | 41 / 8 | `docs/internals/enforcement.md` (1); `scripts/handover/arm-resume.sh` (1); `scripts/handover/headed-arm.sh` (1) | read-both: `alias_env NEW OLD` in readers; writers export both | none |
| 7 | F1b | `HIMMEL_CONSOLE_RUNDIR` | `HIMMEL_CHIEF_RUNDIR` | env var | 11 / 7 | `scripts/handover/console-kit/` (6); `docs/internals/retask-channel.md` (1) | read-both: `alias_env NEW OLD` in readers; writers export both | none |
| 8 | F1b | `HIMMEL_CONSOLE_JUDGE_DOC` | `HIMMEL_CHIEF_JUDGE_DOC` | env var | 17 / 7 | `scripts/handover/console-kit/` (2); `docs/internals/enforcement.md` (1); `marketplace/plugins/himmel-ops/` (1) | read-both: `alias_env NEW OLD` in readers; writers export both | none |
| 9 | F1b | `HIMMEL_CONSOLE_JUDGE_QID` | `HIMMEL_CHIEF_JUDGE_QID` | env var | 15 / 7 | `scripts/handover/console-kit/` (2); `docs/internals/enforcement.md` (1); `marketplace/plugins/himmel-ops/` (1) | read-both: `alias_env NEW OLD` in readers; writers export both | none |
| 10 | F1b | `HIMMEL_CONSOLE_JUDGE_EFFORT` | `HIMMEL_CHIEF_JUDGE_EFFORT` | env var | 18 / 3 | `scripts/handover/console-kit/` (2); `docs/handover/judge-brief-template.md` (1) | read-both: `alias_env NEW OLD` in readers; writers export both | none |
| 11 | F2 | `HIMMEL_LEG_* (all)` | `HIMMEL_WORKER_*` | env var | 154 / 35 | `scripts/handover/console-kit/` (10); `scripts/eval/leg-digest/` (5); `docs/handover/leg-sections/` (1) | read-both: `alias_env NEW OLD` in readers; writers export both | none; list the exact suffixes in P1 (CONTEXT_MODE, AUTOCOMPACT, PROFILE, CONTEXT_SHARE, FAILURES_LEDGER, others found by this count) |
| 12 | F2 | `HIMMEL_LEAN_LEG` | `HIMMEL_LEAN_WORKER` | env var | 49 / 13 | `scripts/handover/console-kit/` (2); `CHANGELOG.md` (1); `docs/handover/running-a-console.md` (1) | read-both: `alias_env NEW OLD` in readers; writers export both | none |
| 13 | F3 | `CADENCE_BANK_*` | `CADENCE_BUDGET_*` | env var | 317 / 77 | `scripts/handover/console-kit/` (7); `scripts/config-ui/tests/` (4); `scripts/hooks/fixtures/` (2) | read-both: `alias_env NEW OLD` in readers; writers export both | ci-trust-path (`scripts/lib/`); operator `.env` files carry the old names |
| 14 | F3 | `BANK_LIFT_*` | `BUDGET_LIFT_*` | env var | 74 / 13 | `scripts/handover/console-kit/` (2); `docs/internals/enforcement.md` (1); `scripts/chokepoints.json` (1) | read-both: `alias_env NEW OLD` in readers; writers export both | data contract (the lift file the operator writes); ci-trust-path |
| 15 | F3 | `CODEX_BANK_*` | `CODEX_BUDGET_*` | env var | 92 / 22 | `scripts/config-ui/tests/` (3); `scripts/lanes/tests/` (3); `scripts/config-ui/agui/` (2) | read-both: `alias_env NEW OLD` in readers; writers export both | operator `.env` files carry the old names |
| 16 | F3 | `CLAUDEX_BANK_*` | `CLAUDEX_BUDGET_*` | env var | 24 / 7 | `.env.example` (1); `docs/configuration.md` (1); `docs/tooling-catalog.md` (1) | read-both: `alias_env NEW OLD` in readers; writers export both | operator `.env` files carry the old names |
| 17 | F3 | `PARKED-BANK` | `PARKED-BUDGET` | marker token | 17 / 10 | `scripts/handover/console-kit/` (5); `docs/handover/leg-preface.md` (1); `marketplace/plugins/himmel-bus/` (1) | accept-both token in the tick parser; emit the old spelling until the removal release | data contract (marker token the tick parses; old docs and bullets keep it forever) |
| 18 | F4 | `bank-preflight.sh` | `budget-preflight.sh` | file | 494 / 154 | `scripts/handover/console-kit/` (15); `scripts/probes/claude-p/` (5); `scripts/eval/lane-quality/` (4) | wrapper at old path `exec`s the new script | allow-rule literal; ci-trust-path (`scripts/lib/`); CLAUDE.md names it; invoked by name from 150+ files |
| 19 | F4 | `bank-lift.sh` | `budget-lift.sh` | file | 229 / 28 | `scripts/handover/console-kit/` (2); `.claude/settings.json` (1); `.codex/hooks.json` (1) | wrapper at old path `exec`s the new script | allow-rule literal; hook `block-bank-lift-writes.sh` matches the path; ci-trust-path |
| 20 | F4 | `bank-monitor.sh` | `budget-monitor.sh` | file | 25 / 7 | `scripts/handover/console-kit/` (2); `docs/internals/lane-calibration.md` (1); `scripts/ci/suite-durations.tsv` (1) | wrapper at old path `exec`s the new script | ci-trust-path |
| 21 | F4 | `bank-attribution.sh` | `budget-attribution.sh` | file | 31 / 8 | `CHANGELOG.md` (1); `docs/internals/lane-calibration.md` (1); `docs/internals/usage-records.md` (1) | wrapper at old path `exec`s the new script | ci-trust-path |
| 22 | F4 | `bank-status` | `budget-status` | command | 133 / 36 | `scripts/lanes/tests/` (5); `scripts/handover/console-kit/` (2); `scripts/lanes/bench/` (2) | wrapper / command alias | none |
| 23 | F5 | `clear-cr-marker.sh` | `clear-review-marker.sh` | file | 540 / 95 | `scripts/cr/pr-check-ref/` (10); `scripts/eval/leg-digest/` (4); `scripts/lanes/tests/` (3) | wrapper at old path `exec`s the new script | allow-rule literal and ci-trust-path (listed by exact path in `ci-trust-paths.txt`); CLAUDE.md and the leg preface name it |
| 24 | F5 | `cr-*.sh helpers (scripts/cr, scripts/lib/cr-*)` | `review-*.sh` | file | 327 / 101 | `scripts/hooks/fixtures/` (7); `scripts/handover/console-kit/` (3); `scripts/lanes/tests/` (3) | wrapper at old path `exec`s the new script per script | allow-rule literal for some; ci-trust-path (`scripts/lib/`); the regex also catches third-party `cr-*.sh` names, so per-hit read |
| 25 | F5 | `CR_MARKER*` | `REVIEW_MARKER*` | env var | 17 / 5 | `scripts/cr/clear-cr-marker.sh` (1); `scripts/cr/test-clear-cr-marker.sh` (1); `scripts/handover/test-pr-merge.sh` (1) | read-both: `alias_env NEW OLD` in readers; writers export both | none |
| 26 | F5 | `cr-pending (marker dir)` | `review-pending` | directory | 226 / 44 | `scripts/handover/fixtures/` (2); `docs/daily-loop.md` (1); `docs/handover/overnight-mode.md` (1) | readers check both dirs; the pre-push hook writes the new one | data contract (state under `<git-dir>`; an in-flight review marker must survive the switch) |
| 27 | F6 | `headed-arm-leg.sh` | `headed-arm-worker.sh` | file | 430 / 116 | `scripts/handover/console-kit/` (21); `scripts/lanes/bench/` (8); `scripts/hooks/fixtures/` (6) | wrapper at old path `exec`s the new script | allow-rule literal; leg preface and launcher memory name it; `scripts/handover/console-kit/` is ci-trust-path for `go.sh` only |
| 28 | F7 | `leg-identity.sh` | `worker-identity.sh` | file | 73 / 29 | `scripts/handover/console-kit/` (14); `scripts/lanes/bench/` (5); `CHANGELOG.md` (1) | wrapper at old path `exec`s the new script; keep parsing legacy `-leg[N]<k>-` doc names | ci-trust-path (`scripts/lib/`); data contract (classifies session names) |
| 29 | F7 | `leg-doc-lock.sh` | `worker-doc-lock.sh` | file | 26 / 10 | `scripts/handover/console-kit/` (6); `scripts/ci/run-shell-tests.sh` (1); `scripts/ci/test-run-shell-tests.sh` (1) | wrapper at old path `exec`s the new script | none |
| 30 | F7 | `leg-event.sh` | `worker-event.sh` | file | 17 / 10 | `scripts/handover/console-kit/` (4); `docs/handover/console-sections/` (1); `docs/handover/console-template.md` (1) | wrapper at old path `exec`s the new script | none |
| 31 | F7 | `leg-jira-status.sh` | `worker-jira-status.sh` | file | 34 / 15 | `scripts/handover/console-kit/` (3); `docs/handover/leg-preface.md` (1); `marketplace/plugins/himmel-ops/` (1) | wrapper at old path `exec`s the new script | named in the leg preface |
| 32 | F7 | `leg-pretrust.sh` | `worker-pretrust.sh` | file | 44 / 5 | `scripts/handover/console-kit/` (3); `scripts/eval/lane-quality/` (1); `scripts/lint/swallowed-errors-baseline.txt` (1) | wrapper at old path `exec`s the new script | none |
| 33 | F7 | `leg-transcripts.sh` | `worker-transcripts.sh` | file | 9 / 4 | `scripts/handover/console-kit/` (3); `scripts/lint/swallowed-errors-baseline.txt` (1) | wrapper at old path `exec`s the new script | none |
| 34 | F7 | `leg-graph.sh` | `worker-graph.sh` | file | 39 / 12 | `scripts/eval/graphify-ab/` (3); `docs/handover/leg-preface.md` (1); `scripts/eval/leg-digest/` (1) | wrapper at old path `exec`s the new script | named in the leg preface |
| 35 | F7 | `leg-digest*` | `worker-digest*` | file / directory | 107 / 42 | `scripts/eval/leg-digest/` (10); `scripts/ci/test-shard-manifest-verify-fixtures/` (8); `scripts/handover/console-kit/` (8) | wrapper at old path `exec`s the new script per script; directory symlink for `scripts/eval/leg-digest/` | none |
| 36 | F7 | `close-wrapped-leg.sh` | `close-wrapped-worker.sh` | file | 140 / 42 | `scripts/handover/console-kit/` (16); `docs/handover/console-sections/` (2); `.claude/settings.json` (1) | wrapper at old path `exec`s the new script | allow-rule literal |
| 37 | F7 | `leg-preface*.md` | `worker-preface*.md` | file | 95 / 37 | `scripts/handover/console-kit/` (6); `docs/handover/leg-sections/` (5); `CHANGELOG.md` (1) | redirect stub at old path | the launcher appends it to the system prompt by path; the path is a contract between launcher and docs |
| 38 | F8 | `console-kit (directory)` | `chief-kit` | directory | 790 / 251 | `scripts/handover/console-kit/` (78); `scripts/hooks/fixtures/` (6); `docs/handover/console-sections/` (5) | directory symlink `console-kit` to `chief-kit` | allow-rule literal (13 literal rules); ci-trust-path (`go.sh` by exact path); largest blast radius; symlink resolution under git must be tested on Linux and macOS |
| 39 | F8 | `console-template.md` | `chief-template.md` | file | 59 / 29 | `docs/handover/console-sections/` (9); `scripts/handover/console-kit/` (8); `scripts/handover/console/` (2) | redirect stub | named by launchers |
| 40 | F9 | `/console (command)` | `/chief` | command | 120 / 29 | `scripts/handover/console-kit/` (2); `scripts/handover/console/` (2); `scripts/hooks/fixtures/` (2) | command alias file `console.md` forwards to `chief.md` | muscle memory; plugin commands in two places |
| 41 | F9 | `console.sh` | `chief.sh` | file | 169 / 57 | `scripts/handover/console-kit/` (14); `docs/handover/console-sections/` (3); `scripts/handover/console/` (3) | wrapper at old path `exec`s the new script | allow-rule literal |
| 42 | F9 | `console-context.sh` | `chief-context.sh` | file | 26 / 11 | `scripts/handover/console/` (3); `scripts/handover/console-kit/` (2); `scripts/handover/arm-resume.sh` (1) | wrapper at old path `exec`s the new script | none |
| 43 | F10 | `overnight-shift` | `afk-shift` | command / directory | 56 / 31 | `marketplace/plugins/himmel-ops/` (2); `.claude/commands/overnight-shift.md` (1); `.claude/commands/stop.md` (1) | command alias; wrapper for the directory | plugin skills mention it; `/overnight-shift` kept per the glossary until the removal release |
| 44 | F10 | `overnight-mode.md` | `afk-mode.md` | file | 60 / 35 | `marketplace/plugins/handover/` (6); `marketplace/plugins/pr-review-toolkit-himmel/` (2); `.agents/skills/handover-arm-resume/` (1) | redirect stub (docs link it) | docs links |
| 45 | F10 | `OVERNIGHT_*` | `AFK_*` | env var | 22 / 8 | `.env.example` (1); `docs/configuration.md` (1); `scripts/handover/test-template-operator-gated-clause.sh` (1) | read-both: `alias_env NEW OLD` in readers; writers export both | operator `.env` files carry the old names |
| 46 | F11 | `watchdog` | `auto-relaunch` (auto-arm hooks only) | ambiguous word | 306 / 75 | `archive/windows/scripts/` (3); `marketplace/plugins/lean-skills/` (2); `.agents/skills/handover-arm-resume/` (1) | read-both: `alias_env NEW OLD` in readers; writers export both; wrapper for scripts | AMBIGUOUS: glossary scopes it to the auto-arm hooks; a wall-clock killer is a "run timeout"; per-hit read; some hits are in `archive/windows/` (dropped) |
| 47 | F12 | `chokepoint (HOLD)` | `sanctioned-script` (HOLD) | ambiguous word | 789 / 167 | `scripts/handover/console-kit/` (8); `scripts/cr/pr-check-ref/` (4); `archive/windows/scripts/` (3) | n/a | ON HOLD: docs-only per the glossary; `scripts/chokepoints.json` and hook names are code |
| 48 | F13 | `class-sweep / class sweep` | `sibling-sweep` | marker token / message text | 62 / 15 | `scripts/eval/lane-quality/` (2); `scripts/eval/leg-digest/` (2); `archive/windows/scripts/` (1) | accept-both ledger keyword and exit reason | data contract (ledger rows already written keep `SWEEP`) |
| 49 | F13 | `missing-class-sweep` | `missing-sibling-sweep` | exit reason | 7 / 4 | `scripts/cr/clear-cr-marker.sh` (1); `scripts/cr/test-clear-cr-marker.sh` (1); `scripts/eval/friction/` (1) | accept-both exit reason | data contract (exit-14 reason string tests assert) |
| 50 | F14 | `speed bump` | `soft block` | message text | 12 / 9 | `docs/internals/egress-matrix.md` (1); `docs/internals/enforcement.md` (1); `docs/internals/retask-channel.md` (1) | none; message text only | tests that grep the message text |
| 51 | F15 | `HIMMEL_*WAVE*/*CHAIN* env` | `HIMMEL_*SEQUENCE*` / `HIMMEL_*BATCH*` | env var | 10 / 2 | `scripts/himmel-doctor.sh` (1); `scripts/test-himmel-doctor.sh` (1) | read-both: `alias_env NEW OLD` in readers; writers export both | tiny: 2 files |
| 52 | F15 | `wave- files` | `batch-` | file | 10 / 8 | `marketplace/plugins/obsidian-triage/` (2); `docs/internals/environment-gotchas.md` (1); `marketplace/plugins/handover/` (1) | none (prose file names) | AMBIGUOUS: `wave-` also matches unrelated words; per-hit read |

52 rows. Line totals overlap between rows (one line can match several
old names), so the column does not sum to a repo-wide count.

## Rows that must NOT be renamed

| Item | Why | Kind |
|---|---|---|
| `-console`, `-relay`, `-N<k>-`, `-judge-<qid>` session-name suffixes | data contract: scorecard classifiers, `leg-identity.sh`, `verdict-template.md`; `-chief` may be accepted in addition, never instead | session name |
| `HIMMEL_FLEET_CAP` | no doc rename; not in the glossary tables | env var |
| `HIMMEL_INITIATIVE` | no doc rename | env var |
| `HIMMEL_HOOK_INTEGRITY_BYPASS_OK` | no doc rename (the off switch row is prose) | env var |
| `bypassPermissions` | a different thing from the off switch; Claude Code's own value | settings value |
| `handover`, `trailer`, `floor`, `anchor`, `arm`, `lane`, `queue lock` | glossary: not renamed on purpose | plain names |
| `PARKED-BANK` as a historic token in already-written handover docs | old docs keep it; only the parser gains the new spelling | marker token |
| `/overnight-shift` command name until the removal release | glossary keeps it; `afk-shift` is added beside it | command |

## Freeze

1. When the last rename PR (P8) merges, this table is the **closed list**. A name
   not on it is not renamed; a new name for a row already renamed is a new ruling.
2. Any later rename needs a new operator ruling and a new row here, then the same
   approve / change / drop pass. No leg renames on its own judgement.
3. After the removal release (the release after v1.1.3) the old spellings stop
   working. Until then each row keeps its read-both alias, pinned by a test.
4. The `Do not rename` list above is permanent, not tied to a release.

## Decision list for the operator

Reply per row id with **approve**, **change <new name>** or **drop**. One reply
covering ranges is enough, e.g. `1-12 approve; 15 change CODEX_SPEND_*; 50 drop`.
Rows to look at first (a wrong name is the costly kind):

1. Rows 1-3: the identity markers (`HIMMEL_CHIEF_WORKER` is the sensitive name).
2. Rows 13-17: `bank` to `budget` (the whole F3 family, plus `PARKED-BANK`).
3. Rows 38-42: `console-kit` to `chief-kit`, `/console` to `/chief`.
4. Rows 46-47: `watchdog` (AMBIGUOUS) and `chokepoint` (HOLD): confirm both stay as marked.
5. Rows 48-52: ledger, message-text and wave/chain rows; low risk, drop them if the churn is not worth it.

Also decide:
- Is `afk-shift` / `afk-mode` the final name for overnight mode?
- Keep F12 (`chokepoint`) on hold?
- Rename the `cr-pending` marker directory, or keep it and rename only the scripts?

## Appendix: owning directories per row

Full file lists are the re-run recipe below (per row they run to hundreds of
paths). This appendix gives the top directories, up to six per row.

- **1** `HIMMEL_CONSOLE_LEG`: `scripts/handover/console-kit/` 10; `scripts/hooks/fixtures/` 6; `scripts/handover/fixtures/` 2; `.claude/agents/console-judge.md` 1; `CHANGELOG.md` 1; `docs/handover/judge-preface.md` 1.
- **2** `HIMMEL_CONSOLE_RELAY`: `scripts/handover/console-kit/` 10; `CHANGELOG.md` 1; `docs/handover/relay-brief-template.md` 1; `docs/internals/api-credit-lane.md` 1; `docs/internals/console-ops-lane.md` 1; `scripts/api-lane/bulk-call.sh` 1.
- **3** `HIMMEL_CONSOLE_JUDGE`: `scripts/handover/console-kit/` 6; `docs/handover/judge-preface.md` 1; `docs/internals/enforcement.md` 1; `marketplace/plugins/himmel-ops/` 1; `scripts/hooks/guard-judge-writes.sh` 1; `scripts/hooks/test-crlf-boundary.sh` 1.
- **4** `HIMMEL_CONSOLE_DOC`: `docs/internals/enforcement.md` 1; `scripts/handover/arm-resume.sh` 1; `scripts/handover/console-kit/` 1; `scripts/handover/headed-arm.sh` 1; `scripts/handover/hop.sh` 1; `scripts/handover/merge-on-green.sh` 1.
- **5** `HIMMEL_CONSOLE_NAME`: `scripts/handover/console-kit/` 2; `CHANGELOG.md` 1; `docs/handover/console-template.md` 1; `docs/handover/running-a-console.md` 1; `docs/internals/enforcement.md` 1; `docs/internals/leg-context-guard.md` 1.
- **6** `HIMMEL_CONSOLE_WORKDIR`: `docs/internals/enforcement.md` 1; `scripts/handover/arm-resume.sh` 1; `scripts/handover/headed-arm.sh` 1; `scripts/handover/test-arm-resume.sh` 1; `scripts/handover/test-headed-arm.sh` 1; `scripts/hooks/console-compact-reinject.sh` 1.
- **7** `HIMMEL_CONSOLE_RUNDIR`: `scripts/handover/console-kit/` 6; `docs/internals/retask-channel.md` 1.
- **8** `HIMMEL_CONSOLE_JUDGE_DOC`: `scripts/handover/console-kit/` 2; `docs/internals/enforcement.md` 1; `marketplace/plugins/himmel-ops/` 1; `scripts/hooks/guard-judge-writes.sh` 1; `scripts/hooks/test-guard-judge-writes.sh` 1; `scripts/lib/console-context.sh` 1.
- **9** `HIMMEL_CONSOLE_JUDGE_QID`: `scripts/handover/console-kit/` 2; `docs/internals/enforcement.md` 1; `marketplace/plugins/himmel-ops/` 1; `scripts/hooks/guard-judge-writes.sh` 1; `scripts/hooks/test-guard-judge-writes.sh` 1; `scripts/lib/console-context.sh` 1.
- **10** `HIMMEL_CONSOLE_JUDGE_EFFORT`: `scripts/handover/console-kit/` 2; `docs/handover/judge-brief-template.md` 1.
- **11** `HIMMEL_LEG_* (all)`: `scripts/handover/console-kit/` 10; `scripts/eval/leg-digest/` 5; `docs/handover/leg-sections/` 1; `docs/internals/enforcement.md` 1; `docs/internals/leg-context-guard.md` 1; `scripts/config-ui/README.md` 1.
- **12** `HIMMEL_LEAN_LEG`: `scripts/handover/console-kit/` 2; `CHANGELOG.md` 1; `docs/handover/running-a-console.md` 1; `docs/internals/lane-calibration.md` 1; `scripts/handover/console/` 1; `scripts/hooks/graphify-freshness-advisory.sh` 1.
- **13** `CADENCE_BANK_*`: `scripts/handover/console-kit/` 7; `scripts/config-ui/tests/` 4; `scripts/hooks/fixtures/` 2; `docs/handover/running-a-console.md` 1; `docs/internals/api-credit-lane.md` 1; `docs/internals/enforcement.md` 1.
- **14** `BANK_LIFT_*`: `scripts/handover/console-kit/` 2; `docs/internals/enforcement.md` 1; `scripts/chokepoints.json` 1; `scripts/himmel-doctor.sh` 1; `scripts/hooks/auto-arm-on-cap.sh` 1; `scripts/hooks/guard-implementor-dispatch.sh` 1.
- **15** `CODEX_BANK_*`: `scripts/config-ui/tests/` 3; `scripts/lanes/tests/` 3; `scripts/config-ui/agui/` 2; `scripts/handover/console-kit/` 2; `scripts/claude-codex` 1; `scripts/config-ui/README.md` 1.
- **16** `CLAUDEX_BANK_*`: `.env.example` 1; `docs/configuration.md` 1; `docs/tooling-catalog.md` 1; `scripts/lanes/funded-max-pct.mjs` 1; `scripts/lanes/tests/` 1; `scripts/telegram/spawn-claudex.test.ts` 1.
- **17** `PARKED-BANK`: `scripts/handover/console-kit/` 5; `docs/handover/leg-preface.md` 1; `marketplace/plugins/himmel-bus/` 1; `scripts/config-ui/agui-web/` 1; `scripts/config-ui/roadmap.ts` 1; `scripts/lib/leg-tail-status.sh` 1.
- **18** `bank-preflight.sh`: `scripts/handover/console-kit/` 15; `scripts/probes/claude-p/` 5; `scripts/eval/lane-quality/` 4; `scripts/lanes/bench/` 4; `docs/handover/console-sections/` 2; `marketplace/plugins/qmd/` 2. Settings allow-list: `.claude/settings.json`.
- **19** `bank-lift.sh`: `scripts/handover/console-kit/` 2; `.claude/settings.json` 1; `.codex/hooks.json` 1; `docs/handover/running-a-console.md` 1; `docs/internals/enforcement.md` 1; `docs/release/v1.1.2-notes.md` 1. Settings allow-list: `.claude/settings.json`.
- **20** `bank-monitor.sh`: `scripts/handover/console-kit/` 2; `docs/internals/lane-calibration.md` 1; `scripts/ci/suite-durations.tsv` 1; `scripts/lib/bank-monitor.sh` 1; `scripts/lib/bank-preflight.sh` 1; `scripts/lib/test-bank-monitor.sh` 1.
- **21** `bank-attribution.sh`: `CHANGELOG.md` 1; `docs/internals/lane-calibration.md` 1; `docs/internals/usage-records.md` 1; `scripts/ci/suite-durations.tsv` 1; `scripts/lib/bank-attribution.sh` 1; `scripts/lib/test-bank-attribution.sh` 1.
- **22** `bank-status`: `scripts/lanes/tests/` 5; `scripts/handover/console-kit/` 2; `scripts/lanes/bench/` 2; `.agents/skills/pr-check/` 1; `.env.example` 1; `docs/configuration.md` 1.
- **23** `clear-cr-marker.sh`: `scripts/cr/pr-check-ref/` 10; `scripts/eval/leg-digest/` 4; `scripts/lanes/tests/` 3; `scripts/handover/fixtures/` 2; `.agents/skills/pr-check/` 1; `.claude/commands/pr-check.md` 1.
- **24** `cr-*.sh helpers (scripts/cr, scripts/lib/cr-*)`: `scripts/hooks/fixtures/` 7; `scripts/handover/console-kit/` 3; `scripts/lanes/tests/` 3; `scripts/cr/pr-check-ref/` 2; `scripts/handover/fixtures/` 2; `.agents/skills/cr-scores/` 1. Settings allow-list: `.claude/settings.json`.
- **25** `CR_MARKER*`: `scripts/cr/clear-cr-marker.sh` 1; `scripts/cr/test-clear-cr-marker.sh` 1; `scripts/handover/test-pr-merge.sh` 1; `scripts/hooks/check-cr-before-push.sh` 1; `scripts/hooks/test-check-cr-before-push.sh` 1.
- **26** `cr-pending (marker dir)`: `scripts/handover/fixtures/` 2; `docs/daily-loop.md` 1; `docs/handover/overnight-mode.md` 1; `docs/internals/enforcement.md` 1; `docs/operator-conventions.md` 1; `scripts/ci/suite-durations.tsv` 1.
- **27** `headed-arm-leg.sh`: `scripts/handover/console-kit/` 21; `scripts/lanes/bench/` 8; `scripts/hooks/fixtures/` 6; `scripts/eval/lane-quality/` 2; `scripts/handover/console/` 2; `scripts/handover/fixtures/` 2. Settings allow-list: `.claude/settings.json`.
- **28** `leg-identity.sh`: `scripts/handover/console-kit/` 14; `scripts/lanes/bench/` 5; `CHANGELOG.md` 1; `docs/handover/judge-brief-template.md` 1; `docs/handover/leg-brief-template.md` 1; `docs/internals/leg-context-guard.md` 1.
- **29** `leg-doc-lock.sh`: `scripts/handover/console-kit/` 6; `scripts/ci/run-shell-tests.sh` 1; `scripts/ci/test-run-shell-tests.sh` 1; `scripts/cr/pr-check-context.sh` 1; `scripts/lint/swallowed-errors-baseline.txt` 1.
- **30** `leg-event.sh`: `scripts/handover/console-kit/` 4; `docs/handover/console-sections/` 1; `docs/handover/console-template.md` 1; `docs/handover/running-a-console.md` 1; `docs/internals/console-ops-lane.md` 1; `scripts/eval/console-load-inventory.py` 1.
- **31** `leg-jira-status.sh`: `scripts/handover/console-kit/` 3; `docs/handover/leg-preface.md` 1; `marketplace/plugins/himmel-ops/` 1; `scripts/cr/impacted-suites.sh` 1; `scripts/cr/pr-check-context.sh` 1; `scripts/cr/test-cr-guarded-closure.sh` 1.
- **32** `leg-pretrust.sh`: `scripts/handover/console-kit/` 3; `scripts/eval/lane-quality/` 1; `scripts/lint/swallowed-errors-baseline.txt` 1.
- **33** `leg-transcripts.sh`: `scripts/handover/console-kit/` 3; `scripts/lint/swallowed-errors-baseline.txt` 1.
- **34** `leg-graph.sh`: `scripts/eval/graphify-ab/` 3; `docs/handover/leg-preface.md` 1; `scripts/eval/leg-digest/` 1; `scripts/graphify/leg-graph.sh` 1; `scripts/graphify/test-leg-graph-rationale.sh` 1; `scripts/graphify/test-leg-graph.sh` 1.
- **35** `leg-digest*`: `scripts/eval/leg-digest/` 10; `scripts/ci/test-shard-manifest-verify-fixtures/` 8; `scripts/handover/console-kit/` 8; `docs/cadences.md` 1; `docs/handover/console-sections/` 1; `docs/internals/egress-matrix.md` 1.
- **36** `close-wrapped-leg.sh`: `scripts/handover/console-kit/` 16; `docs/handover/console-sections/` 2; `.claude/settings.json` 1; `CHANGELOG.md` 1; `docs/handover/console-template.md` 1; `docs/handover/leg-preface.md` 1. Settings allow-list: `.claude/settings.json`.
- **37** `leg-preface*.md`: `scripts/handover/console-kit/` 6; `docs/handover/leg-sections/` 5; `CHANGELOG.md` 1; `docs/handover/console-template.md` 1; `docs/handover/judge-brief-template.md` 1; `docs/handover/lane-canary-brief-template.md` 1.
- **38** `console-kit (directory)`: `scripts/handover/console-kit/` 78; `scripts/hooks/fixtures/` 6; `docs/handover/console-sections/` 5; `marketplace/plugins/himmel-bus/` 5; `scripts/lanes/tests/` 4; `scripts/config-ui/agui/` 2. Settings allow-list: `.claude/settings.json`.
- **39** `console-template.md`: `docs/handover/console-sections/` 9; `scripts/handover/console-kit/` 8; `scripts/handover/console/` 2; `.claude/commands/supervisor-session.md` 1; `docs/handover/running-a-console.md` 1; `docs/internals/context-architecture.md` 1.
- **40** `/console (command)`: `scripts/handover/console-kit/` 2; `scripts/handover/console/` 2; `scripts/hooks/fixtures/` 2; `.claude/commands/console.md` 1; `.claude/skills/domain-modeling/` 1; `AGENTS.md` 1.
- **41** `console.sh`: `scripts/handover/console-kit/` 14; `docs/handover/console-sections/` 3; `scripts/handover/console/` 3; `marketplace/plugins/himmel-ops/` 2; `scripts/hooks/fixtures/` 2; `.claude/commands/console.md` 1. Settings allow-list: `.claude/settings.json`.
- **42** `console-context.sh`: `scripts/handover/console/` 3; `scripts/handover/console-kit/` 2; `scripts/handover/arm-resume.sh` 1; `scripts/handover/headed-arm.sh` 1; `scripts/handover/test-arm-resume-queue-lock.sh` 1; `scripts/handover/test-headed-arm.sh` 1.
- **43** `overnight-shift`: `marketplace/plugins/himmel-ops/` 2; `.claude/commands/overnight-shift.md` 1; `.claude/commands/stop.md` 1; `.claude/mcp-profiles/README.md` 1; `.env.example` 1; `AGENTS.md` 1.
- **44** `overnight-mode.md`: `marketplace/plugins/handover/` 6; `marketplace/plugins/pr-review-toolkit-himmel/` 2; `.agents/skills/handover-arm-resume/` 1; `.claude/commands/handover-arm-resume.md` 1; `.claude/commands/handover-resume.md` 1; `.claude/commands/overnight-shift.md` 1.
- **45** `OVERNIGHT_*`: `.env.example` 1; `docs/configuration.md` 1; `scripts/handover/test-template-operator-gated-clause.sh` 1; `scripts/lib/initiative-legs.sh` 1; `scripts/overnight/build-plan.sh` 1; `scripts/overnight/stop-marker.sh` 1.
- **46** `watchdog`: `archive/windows/scripts/` 3; `marketplace/plugins/lean-skills/` 2; `.agents/skills/handover-arm-resume/` 1; `.claude/commands/handover-arm-resume.md` 1; `.env.example` 1; `CHANGELOG.md` 1.
- **47** `chokepoint (HOLD)`: `scripts/handover/console-kit/` 8; `scripts/cr/pr-check-ref/` 4; `archive/windows/scripts/` 3; `marketplace/plugins/himmel-ops/` 2; `marketplace/plugins/obsidian-triage/` 2; `scripts/eval/guard-corpus/` 2. Settings allow-list: `.claude/settings.json`.
- **48** `class-sweep / class sweep`: `scripts/eval/lane-quality/` 2; `scripts/eval/leg-digest/` 2; `archive/windows/scripts/` 1; `docs/internals/api-credit-lane.md` 1; `docs/internals/lane-calibration.md` 1; `scripts/api-lane/bulk-call.sh` 1.
- **49** `missing-class-sweep`: `scripts/cr/clear-cr-marker.sh` 1; `scripts/cr/test-clear-cr-marker.sh` 1; `scripts/eval/friction/` 1; `scripts/eval/leg-digest/` 1.
- **50** `speed bump`: `docs/internals/egress-matrix.md` 1; `docs/internals/enforcement.md` 1; `docs/internals/retask-channel.md` 1; `scripts/handover/test-retask-doc-bus.sh` 1; `scripts/himmelctl/lib/` 1; `scripts/hooks/guard-bus-store.sh` 1.
- **51** `HIMMEL_*WAVE*/*CHAIN* env`: `scripts/himmel-doctor.sh` 1; `scripts/test-himmel-doctor.sh` 1.
- **52** `wave- files`: `marketplace/plugins/obsidian-triage/` 2; `docs/internals/environment-gotchas.md` 1; `marketplace/plugins/handover/` 1; `scripts/handover/test-arm-resume-identity.sh` 1; `scripts/handover/test-arm-resume-long-gap.sh` 1; `scripts/handover/test-arm-resume-source-key.sh` 1.

## Re-run recipe

For row `<rx>` (the regex is in the extraction list, one per row; the family
regexes in the inventory recipe are the coarse versions):

```
git grep -c -I -E -e '<rx>' -- . ':!docs/glossary.md' ':!handovers' \
  ':!docs/internals/identifier-rename-inventory.md' ':!docs/internals/identifier-rename-proposal.md'
```

Sum the `:N` suffixes for lines, count the output lines for files. Regexes used:

| # | Regex (ERE) |
|---|---|
| 1 | `HIMMEL_CONSOLE_LEG` |
| 2 | `HIMMEL_CONSOLE_RELAY` |
| 3 | `HIMMEL_CONSOLE_JUDGE([^_A-Za-z]\|$)` |
| 4 | `HIMMEL_CONSOLE_DOC` |
| 5 | `HIMMEL_CONSOLE_NAME` |
| 6 | `HIMMEL_CONSOLE_WORKDIR` |
| 7 | `HIMMEL_CONSOLE_RUNDIR` |
| 8 | `HIMMEL_CONSOLE_JUDGE_DOC` |
| 9 | `HIMMEL_CONSOLE_JUDGE_QID` |
| 10 | `HIMMEL_CONSOLE_JUDGE_EFFORT` |
| 11 | `HIMMEL_LEG_[A-Z_]+` |
| 12 | `HIMMEL_LEAN_LEG` |
| 13 | `CADENCE_BANK_[A-Z_]+` |
| 14 | `(^\|[^A-Z_])BANK_LIFT_[A-Z_]+` |
| 15 | `CODEX_BANK_[A-Z_]+` |
| 16 | `CLAUDEX_BANK_[A-Z_]+` |
| 17 | `PARKED-BANK` |
| 18 | `bank-preflight` |
| 19 | `bank-lift` |
| 20 | `bank-monitor` |
| 21 | `bank-attribution` |
| 22 | `bank-status` |
| 23 | `clear-cr-marker` |
| 24 | `(^\|[^A-Za-z0-9_-])cr-[a-z][a-z0-9-]*\.sh` |
| 25 | `CR_MARKER[A-Z_]*` |
| 26 | `cr-pending` |
| 27 | `headed-arm-leg` |
| 28 | `leg-identity` |
| 29 | `leg-doc-lock` |
| 30 | `leg-event` |
| 31 | `leg-jira-status` |
| 32 | `leg-pretrust` |
| 33 | `leg-transcripts` |
| 34 | `leg-graph` |
| 35 | `leg-digest` |
| 36 | `close-wrapped-leg` |
| 37 | `leg-preface` |
| 38 | `console-kit` |
| 39 | `console-template` |
| 40 | `commands/console\|(^\|[^A-Za-z0-9_/.-])/console([^A-Za-z0-9_/.-]\|$)` |
| 41 | `console\.sh` |
| 42 | `console-context` |
| 43 | `overnight-shift` |
| 44 | `overnight-mode` |
| 45 | `OVERNIGHT_[A-Z_]+` |
| 46 | `watchdog` |
| 47 | `chokepoint\|CHOKEPOINT` |
| 48 | `class-sweep\|class sweep` |
| 49 | `missing-class-sweep` |
| 50 | `speed.bump` |
| 51 | `HIMMEL_[A-Z_]*(WAVE\|CHAIN)[A-Z_]*` |
| 52 | `wave-` |
