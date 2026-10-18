# Release notes shape

Release notes answer four questions for someone who installs himmel, in this
order, then fold everything else into one line. `docs/release/<tag>-notes.md`
is what the release workflow publishes; `CHANGELOG.md` stays the generated
per-commit record (`scripts/gen-changelog.sh`) for anyone who wants the churn.

## Sections

Every notes file has exactly these `##` sections, in this order. An empty one
reads `Nothing.`

1. **What you can now do**: a capability that did not exist before.
2. **What changed that you will notice**: behaviour you would see without
   being told, including fixes you would have hit.
3. **What you must do on update**: a command to run, a config key to set, a
   migration. Give the exact command.
4. **Known issues**: what is broken or unfinished, with the workaround.
5. **Internal**: one line with a count. Nothing else.

## User-visible versus internal

A change is user-visible if an adopter can see it from outside the repo: a
command, flag, config key, skill, UI, doc or default changed, or a bug they
could hit is gone. Everything else is internal: guards and hooks, console-kit
and leg mechanics, review gates, CI and test tooling, lint baselines, refactors,
dependency pins.

User sections are written in plain words and contain no ticket key
(`HIMMEL-123`) and no PR number (`#123`); both belong in `CHANGELOG.md`. The
internal line gives a count, not a list.

## How a PR opts in

A PR whose body has a `## Release note` block is user-visible. One line per
item, kind first:

```
## Release note
- new: The run page shows a live board.
- changed: `jira create` no longer requires a Sector unless you configure one.
- update: Run `himmel update` once.
- known: Sector options are cached for five minutes.
```

`new`, `changed`, `update` and `known` map to sections 1 to 4. A PR with no
block is counted in the Internal line.

## Producing and checking a release's notes

```
gh pr list --state merged --search 'merged:>=<prev-tag-date>' --json number,title,body > prs.json
bash scripts/release/gen-release-notes.sh --prs prs.json --version vX.Y.Z > docs/release/vX.Y.Z-notes.md
bash scripts/release/gen-release-notes.sh --check docs/release/vX.Y.Z-notes.md
```

Edit the generated file for wording, then keep `--check` green: it fails on a
missing or reordered section, a ticket key or PR number in a user section, or
an Internal section that is not one line. The release workflow publishes
`docs/release/<tag>-notes.md` when it exists.
