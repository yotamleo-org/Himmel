# T3 provider instances for every launch profile

`scripts/t3/provider-instances.sh` makes each himmel launch profile (the names
`node scripts/lanes/plugin-profiles.mjs --list` prints) a T3 Code provider
instance, so the profile can be picked in T3 without the settings GUI.

## What it writes

One `providerInstances.claudeAgent_<profile>` entry per profile:

```json
{ "driver": "claudeAgent", "displayName": "Claude (<profile>)", "enabled": true,
  "config": { "launchArgs": "--settings <stable profile file> [--mcp-config <file> --strict-mcp-config]" } }
```

- The paths come from `scripts/lanes/profile-settings.sh`: content-addressed, so a
  path stays valid after the registry changes. Re-run the script after a registry
  change; it updates `launchArgs` of the `claudeAgent_<profile>` ids it owns.
- `operator` resolves to no settings file and is skipped.
- A profile already reachable through another instance (same `<profile>.json` in
  its `--settings`, e.g. the hand-made `claudeAgent_claude_chief`) gets no new id.
  Existing instances are never edited or removed.
- A final settings document in which any instance `env` / `environment` entry is
  named `*_OK` or `*BYPASS*` is refused (rc 3), nothing written.
- A malformed settings file is refused (rc 2) and left untouched.

## Dry run, then apply

```
bash scripts/t3/provider-instances.sh --settings-file ~/.t3/userdata/settings.json
bash scripts/t3/provider-instances.sh --apply --settings-file ~/.t3/userdata/settings.json
```

The default `--dry-run` prints a diff and the ids to add to
`.t3.instance_allowlist` in `~/.himmel/config.json` (the script never writes that
file; `guard-t3-thread-tools.sh` refuses an instance id not listed there).
`--apply` first copies the file to `<file>.bak.<UTC stamp>`, then replaces it
atomically. The live T3 settings file is fenced by `block-edit-live-settings`, so
the operator runs `--apply` at their own prompt, after the VM proof.

## Test

`bash scripts/t3/test-provider-instances.sh` (fixture copies only).
