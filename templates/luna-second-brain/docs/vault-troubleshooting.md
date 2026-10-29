# Vault troubleshooting

Traps a running luna vault hits, each with its symptom and its fix. The
pre-commit stash trap is in `_CLAUDE.md` ("pre-commit trap").

## A vault commit STALL: paths staged, no new commit

<!-- mem:3fed3a521ad3 -->
**Symptom:** a vault-autosync STALL alert, or `git status` shows staged paths
while the last commit is older than two sync intervals. **Cause:** the
auto-committer (the github-sync Obsidian plugin or `scripts/vault-autosync.sh`)
staged the paths and its commit was refused by a pre-commit hook, most often
gitleaks. A refused commit stops silently; the paths stay staged.

<!-- mem:80349365be49 -->
Diagnose in three commands from the vault root:

```bash
pgrep -af obsidian                  # is Obsidian (and its sync plugin) running?
git diff --cached --name-only       # what the refused commit held
SKIP=trailing-whitespace,end-of-file-fixer git hook run pre-commit   # the refusal, without the fixers rewriting files
```

`pgrep` needs `-f`: the process name is often the Electron or AppImage
binary, not `obsidian`. `git hook run pre-commit` runs the vault's installed
hook, so it names the same hook and file the sync commit failed on.

<!-- mem:a7e25145b33b -->
**A gitleaks finding on a token shape** (a 40-hex sha, a lock or release
token, a nonce) is first a template-propagation check: compare the vault's
`.gitleaks.toml` with the template's and run the vault upgrade if it is
behind. Only add a rule when the template has none for that shape, and add it
upstream in the template, since `.gitleaks.toml` is template-owned (see below).

<!-- mem:72bb24b5a9c2 -->
**A secret staged by a parallel session** blocks every vault commit, yours
included. Never unstage, reset or rewrite another session's staged paths to
get your own commit through. Tell that session's owner which rule, file and
line fired; once they fix the file, the next auto-commit sweeps the whole
staged backlog.

## Upgrading the vault: template-owned files

<!-- mem:a14314bc96a3 -->
`scripts/upgrade.sh` (the `/luna-upgrade` skill) owns `scripts/`, `docs/`,
`.pre-commit-config.yaml`, `.gitleaks.toml`, `.gitignore`, `.gitattributes`,
`.env.example`, `README.md` and the core `.obsidian/*.json` files, and
replaces them with the template's copy. A vault-local edit to one of them is
detected and withheld: the run prints `local edits withheld (not
overwritten)` and exits 3 (`NEEDS-RECONCILE`). Either upstream the edit to the
template, or keep it on purpose with `--keep <path>`; a later template change
to that file surfaces it again. `_CLAUDE.md` is merged three-way instead, so
your own sections survive an upgrade.

## Auditing clips

<!-- mem:9993e75c03ba -->
`/triage-clips` moves every clip it marks `processed: true` into
`Clippings/_evidence/`, and `/archive-clips` moves clips on to `_done/`. An
audit that counts or searches only the top level of `Clippings/` misses every
triaged clip and reports a false negative ("clip never captured"). Search
`Clippings/` recursively.

## Searching and pushing

<!-- mem:a552ac14a466 -->
The obsidian-vault MCP's `obsidian_simple_search` is a fuzzy substring match,
not a word or phrase match: a hit is a candidate, so read the note before
relying on it, and a near-miss spelling can still match. On the push side, a
vault branch with no upstream makes an automated `git push` fail with "has no
upstream branch"; set it once with `git push -u origin <branch>`.
