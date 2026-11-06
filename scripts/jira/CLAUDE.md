# scripts/jira (Jira CLI source)

Loads only when working in this subtree. The repo-wide **prefer-plugin-
over-MCP** rule is frame-shaping and lives in the root `CLAUDE.md`, not
restated here.

## What this is
The Jira CLI itself (`jira-cli`). Run from repo root as
`node scripts/jira/dist/index.js <op>`. ESM (`"type": "module"`),
arg-parsing via `commander`. One file per op in `src/commands/`.
A second binary ships from the same package: the **Confluence CLI**
(`node scripts/jira/dist/confluence.js <op>`, entry `src/confluence.ts`,
ops under `src/commands/confluence/`), shares `client.ts` auth + ADF
helpers.

## Editing conventions
- **`dist/` is gitignored, not committed.** After editing `src/`, run
  `npm run build` (`tsc`) or the `dist/index.js` callers run stale code.
- Tests are colocated `*.test.ts`; run `npm run test` (vitest) after edits.
- `transition` takes a status **NAME**, not an ID (no two-call lookup).
- `transition <key> Done` adds the earliest unreleased fixVersion when the ticket
  has none and prints it; `--no-version` opts out. Closed / wont do never stamp.
  A frozen version is stamped unless the key is outside the frozen
  set and its latest admission-ledger row is a deferral or an `rm-remove`; that
  key closes unstamped, prints `FAIL` on stderr and exits 3.
- `create --summary` is an alias for `create --title` (Jira's own field name
  is `summary`, so it's the natural reach). If both are given, `--title`
  wins; one of the two is required.
- `create` refuses a body without the Impact/What/Why/Plan/DoD/Agent detail
  sections, Plan and DoD each needing a real bullet or numbered line (Epic and
  Subtask only warn; `create --type Task --skeleton` prints the six headings
  to fill); the rule lives in `src/plain-block.ts`, shared by the CLI and MCP
  `create`.
- `create` also refuses a Task, Story or Bug with neither `--parent <epic>` nor
  `--labels standalone`, and (only when `jira.sectorField` is set in `~/.himmel/config.json`) with no
  `--sector` (Epic and Subtask only warn); `homeVerdict` in `src/plain-block.ts`,
  shared by the CLI and MCP `create`. Sector is opt-in: the field
  id is config and the options are read live, never hardcoded; `jira sector
  setup` creates it. With no `--sector`, a title `<Sector>: x` naming a
  live option supplies the Sector and an unknown prefix on a Task, Story or Bug is
  refused (`titleSector`, same file). Open tickets with an empty Sector:
  `JIRA_PROJECT_KEY=HIMMEL bash scripts/jira/empty-sector-check.sh`.
- `create` refuses a Task, Story or Bug with no placement: `--proposed-version <v>`
  (labels `proposed-<v>` and files the INTAKE request in the same call; the backlog is
  `--backlog --proposed-version backlog --why <line>`), `--fix-version`,
  `--gate`, `--residual-of`, `--follow-up-of` or an inherited blocker version (a Bug may
  also be Highest). A ticket filed with no version queues an INTAKE request to the one
  declared release, on stderr (`jira release request`); `--follow-up-of <key>` makes that
  request ask for an open parent's current version, with a why of facts (parent, status,
  version) and the same in its evidence; `--remainder` adds that the parent cannot close
  without this ticket; a Done parent asks for none; a frozen version goes to the next open
  one; the residual cap is not checked (an explicit `--fix-version`, `--backlog`,
  `--proposed-version` or `--why` wins); a Bug that blocks open work goes
  into a version, then needs a requested INTAKE. Open tickets
  that already have no version: `scripts/handover/chief-kit/intake-backfill.sh` prints a
  proposed version for each (dry run; `--commands` adds the lines for one rm-run).
- Verify every `create`/`move` by checking the printed `Created HIMMEL-N`.
- `JIRA_PROJECT_KEY` is required at runtime. No `HIMMEL` fallback.

## Reference
- Op ↔ MCP mapping: [`docs/internals/jira-plugin.md`](../../docs/internals/jira-plugin.md).
