# claudex classifier flag: refuse an alias not served by the cli-proxy Claude OAuth provider

Impact
With the opt-in claudex classifier flag on, an operator who picks a cli-proxy alias that OpenRouter serves would send every safety-classifier query to OpenRouter. The standing ruling is that the classifier goes through Claude OAuth only, never OpenRouter. Today nothing stops that choice.
What
Make scripts/claude-codex (and the .ps1 twin) refuse a --classifier-model alias that cli-proxy does not serve through its Claude OAuth provider.
Why
Judge j2403a (PR 2403, HIMMEL-5273) found the launcher checks only that the alias is served, not by which provider. The operator ruling depends on picking the right alias, and no code enforces it.
Agent detail
Files: scripts/claude-codex (served-alias check, about line 584), scripts/claude-codex.ps1 (about lines 567-576), scripts/test-claude-codex.sh. Read the provider from cli-proxy's /v1/models owned_by field (or its config), and exit 2 unless it is the Claude OAuth provider. RED row: an alias served by an OpenRouter provider exits 2. Done when the RED row passes and the existing flag-on row still launches.

## What to deliver

Make the change this ticket asks for, in this repository. It is checked by these test files, which you may add to or change:

- `scripts/test-claude-codex.sh`

The checks it must pass include:

- `scripts/test-claude-codex.sh`: classifier flag: OpenRouter-served alias refuses
- `scripts/test-claude-codex.sh`: classifier flag: alias with no owned_by refuses (fail closed)

Run the tests you touch before you finish. Report what you changed and what you checked.
