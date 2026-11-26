# Jira Projects

Catalog of Jira projects on the `yotamleo.atlassian.net` instance. Keys are
public — safe to commit. Refresh with `jira projects` (subcommand added in
PR introducing this file).

| Key | ID | Name | Scope | Notes |
|-----|----|------|-------|-------|
| HIMMEL | 10033 | Himmel | himmel repo — engineering, infra, tooling. | Default project for the `jira` CLI (`JIRA_PROJECT_KEY=HIMMEL` in `~/.himmel/himmel.conf`). All Epics for himmel work live here. Standalones historically NOT tracked here. |
| LUNA | 10066 | Luna | Luna vault (personal second brain). | Created 2026-05-19 via `jira project-create`. Template: Kanban classic. For tickets tracking Luna-specific work. Vault content lives in the `luna` repo; Luna handover docs live in the handover state repo `<state-repo>/handovers/<USER_SLUG>/luna/` (himmel `handovers/` is a stub). |
| HTEST | 10132 | himmel CLI live test | Jira test project for live tests and audits. | The station's `JIRA_TEST_PROJECT`. Under a live test the `jira` CLI refuses a write to any other project. Holds throwaway tickets only, never work. |
| HIMTEST | 10099 | Himmel Test Sandbox | Former e2e sandbox. | Nothing writes here any more: the HIMTEST e2e suite was deleted, and the live suite takes its project from `JIRA_TEST_PROJECT`. |

## Usage

- Default project (HIMMEL): `jira list`, `jira create --type Story --title "..." --desc-file body.md --labels standalone`
- Non-default project: pass `--project <KEY>` to any subcommand. Example:
  `jira create --project LUNA --type Story --title "..." --desc-file body.md --labels standalone`
- A Task, Story or Bug needs either `--parent <epic>` or `--labels standalone`, and a body with the seven sections (`jira create --type Task --skeleton` prints them). It needs no placement flag: the four rules place it (an operator ask in the current or a named version, High and Highest in the current version, anything else in the backlog), and `--fix-version` or `--backlog --proposed-version backlog --why <line>` place it by hand. `--sector` is required only where sectors are configured (`jira.sectorField`).
- Test project: live tests and audits write only to `JIRA_TEST_PROJECT` (HTEST here). Set it with
  `himmelctl config set jira.testProject HTEST`; `jira live-test --json` prints the value in force.
- Refresh this catalog: run `jira projects` and update the table above.

## Conventions

- Epics: `<PROJECT>-N` (e.g. `PROJ-29` for VirtualBox VM Management).
- Standalones (himmel concept): historically not in Jira — tracked only in
  `<state-repo>/handovers/<USER_SLUG>/<repo>/standalones/` (`<repo>` ∈ himmel | luna |
  cross in practice; `luna_brain` remains a built-in resolver bucket but is
  inactive; current bucket layout). New convention from
  2026-05-19 forward files standalones as Stories in their topical project
  (e.g. Luna-related standalones → LUNA-N Story under
  `<state-repo>/handovers/<USER_SLUG>/luna/standalones/`).
- Theme label: a ticket carries at most one `theme-<slug>` label (`<slug>` is lowercase `a-z0-9` with
  single hyphens, at most 40 characters). The config-ui Kanban theme select writes it through the Jira CLI and
  replaces any other `theme-*` label; other labels are kept. The config-ui roadmap and the chief-kit tracker read it
  first and fall back to the plan's stage1 / overlay theme only when no label is set. A slug that matches a plan theme
  (lowercased, non-alphanumerics to `-`) shows that theme's plan name.
