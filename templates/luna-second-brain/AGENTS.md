The rules for this directory live in [`_CLAUDE.md`](_CLAUDE.md). Read it first.

## Antigravity (Gemini) addendum

- No vault MCP server is loaded, the same as `_CLAUDE.md` says for Claude sessions. Use your native file tools to read and edit notes.
- To search the vault, run `bash "$HIMMEL_DIR/scripts/lib/qmd-bounded.sh" query -c <collection> "<question>"`, where `$HIMMEL_DIR` is the absolute path of your himmel checkout (the wrapper ships with himmel, not with this vault). A bare `qmd` call is refused, and a miss is not proof of absence.
- Hooks for this directory come from the user-scope Antigravity config, never from a repo-local `.agents/hooks.json`. Do not create one.
- Never read secrets, provider config homes (`~/.gemini/config`, the T3 Antigravity provider directory) or `.env` files.
