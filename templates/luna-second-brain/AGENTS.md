<!-- _CLAUDE.md is the one source of rules for this directory; edit that file for rules. This file adds only the Antigravity addendum below, and upgrade.sh overwrites it. -->

The rules for this directory live in [`_CLAUDE.md`](_CLAUDE.md). Read it first.

## Antigravity (Gemini) addendum

- `_CLAUDE.md` prefers the `obsidian-vault` MCP. Antigravity sessions do not have it: it is not on the hook adapter's allowlist. Use your native file tools to read and edit notes.
- To search the vault, run `bash scripts/lib/qmd-bounded.sh query -c <collection> "<question>"`. A bare `qmd` call is refused, and a miss is not proof of absence.
- Hooks for this directory come from the user-scope Antigravity config, never from a repo-local `.agents/hooks.json`. Do not create one.
- Never read secrets, provider config homes (`~/.gemini/config`, the T3 Antigravity provider directory) or `.env` files.
