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

## Layout

The hook and its libraries are copies of `scripts/hooks/` and
`scripts/guardrails/` in the harness, keeping their relative layout so the
hook's own `source` lines resolve unchanged. Only ticket references in
comments were removed from the two `hooks/lib/` files; the code is identical. Every path in `hooks/hooks.json`
is rooted at `${CLAUDE_PLUGIN_ROOT}`; nothing reaches `$CLAUDE_PROJECT_DIR`.
The harness keeps its own wiring: this plugin copies the hook, it does not move it.

## Test

`bash marketplace/plugins/himmel-guard/test-himmel-guard.sh` installs only this
plugin into an empty `HOME` and checks the installed hook denies a destructive
payload.
