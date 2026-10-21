# himmel-guard

Himmel's safety guards as a standalone plugin: install it with no himmel
checkout. This first slice carries one guard family, the destructive-command
guard (`hooks/block-destructive-commands.sh`), which denies `rm -rf`, force
pushes, hard resets and similar before the Bash call runs.

```text
/plugin marketplace add yotamleo/himmel
/plugin install himmel-guard@himmel
```

Needs `bash` and `jq` on the machine. A missing `jq` or a malformed payload
fails closed (the call is denied).

## On by default, and how to opt out

The starter install enables this plugin: `himmel-guard@himmel` is `true` in
the `enabledPlugins` map of `docs/setup/settings-template.json`, so a fresh
install refuses destructive commands with no extra step. To opt out:

```text
/profile disable himmel-guard@himmel
```

(or `claude plugin disable himmel-guard@himmel --scope user`). A later
`/himmel-update` with `HIMMEL_RECONCILE_PLUGINS=1` rewrites the template map
verbatim and turns it back on, so to keep it off permanently also record
`"himmel-guard@himmel": false` under `enabledPlugins` in
`~/.claude/settings.local.json`. Turn it back on with
`/profile enable himmel-guard@himmel`.

## Layout

The hook and its libraries are copies of `scripts/hooks/` and
`scripts/guardrails/` in the harness, placing the guardrails library under hooks/guardrails/ so the
hook resolves it from its own directory. Only ticket references in
comments were removed from the two `hooks/lib/` files; the code is identical. Every path in `hooks/hooks.json`
is rooted at `${CLAUDE_PLUGIN_ROOT}`; nothing reaches `$CLAUDE_PROJECT_DIR`.
The harness keeps its own wiring: this plugin copies the hook, it does not move it.

## Test

`bash marketplace/plugins/himmel-guard/test-himmel-guard.sh` installs only this
plugin into an empty `HOME` and checks the installed hook denies a destructive
payload.
