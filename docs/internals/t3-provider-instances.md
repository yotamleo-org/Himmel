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
- `operator` resolves to no settings file, so its `claudeAgent_operator` instance gets a
  settings file holding only the resolver's default for a profile that sets nothing: the
  Artifact tool denied. The built-in default instance, `providerInstances.claudeAgent`
  (created when absent, its other `config` kept), gets the same file, so a T3 thread on
  either writes local HTML like a terminal session. A `launchArgs` the user set on
  `claudeAgent` is left alone with a warning (only a `--settings .../<12 hex>/artifact-deny.json`
  of the shape the script writes is refreshed), and that entry never counts as covering a profile. A profile
  with `artifact: true` (`user`, the design family) keeps the tool through its own file.
- A profile already reachable through another instance (same `<profile>.json` in
  its `--settings`, e.g. the hand-made `claudeAgent_claude_chief`) gets no new id.
  Existing instances are never removed, and none is edited except a
  `claudeAgent_<profile>` whose stable path moved (its `launchArgs` is refreshed) and the
  default `claudeAgent` (its `launchArgs` only when empty or a deny file the script wrote).
- A resolved path containing whitespace is refused (rc 2): `launchArgs` would split it.
  If the settings file changes while the profiles resolve, `--apply` writes nothing (rc 2).
- A final settings document in which any `env` / `environment` entry is named
  `*_OK` or `*BYPASS*` is refused (rc 3), nothing written. T3 keeps an instance's
  `environment` list on the instance itself, beside `config` (checked in T3 0.1.10's
  schema); the scan reads that and the `config` copies. An instance whose `launchArgs`
  carry `--dangerously-skip-permissions` or `bypassPermissions` is refused the same way.
- A malformed settings file is refused (rc 2) and left untouched.

## Relay copies (`.t3.relay_instances`)

A relay-marked instance is the one-click switch for a thread to reach the chief.
The operator lists base instance ids in `~/.himmel/config.json`,
beside `.t3.instance_allowlist`:

```json
{ "t3": { "relay_instances": ["claudeAgent_worker-impl", "antigravity"] } }
```

- For each listed id the script adds `<id>_relay`: the base entry as regenerated in the
  same run (same driver and `config`), `enabled: true`, named `<base displayName> + chief relay`.
  A hand-edited copy is regenerated from its base; picking the copy in T3 is the click.
- A `*_relay` key never marks a profile covered, so the base still refreshes.
- Off by default: an absent field, `[]` or no config file generates nothing. The file is
  read only from `$HOME/.himmel/config.json`; no env variable moves it.
- An id that names no instance warns and is skipped (rc 0). The bypass-flag refusal
  (rc 3) covers the copies. The printed allowlist block lists the `_relay` ids; adding
  them to `.t3.instance_allowlist` is the operator's.
- `codex` is a built-in with no entry. A driver-only `codex_relay` is written only with
  `T3_PI_BUILTIN_RELAY=1`; the default is off, with a warning, until a read-only
  check shows T3 lists such an entry.

## Dry run, then apply

```bash
bash scripts/t3/provider-instances.sh --settings-file ~/.t3/userdata/settings.json
bash scripts/t3/provider-instances.sh --apply --settings-file ~/.t3/userdata/settings.json
```

The default `--dry-run` prints a diff and the ids to add to
`.t3.instance_allowlist` in `~/.himmel/config.json` (the script never writes that
file; `guard-t3-thread-tools.sh` no longer reads that key: it refuses bypass instances, ids off the optional
`.t3.instance_narrow`, and every id when its config or T3's settings cannot be read; see `docs/internals/enforcement.md`).
`--apply` first copies the file to `<file>.bak.<UTC stamp>`, then replaces it
atomically. The live T3 settings file is fenced by `block-edit-live-settings`, so
an agent applies it only through the update step:

```bash
bash scripts/himmel-update.sh --only t3_providers
```

That step runs `--apply` on `${T3CODE_HOME:-$HOME/.t3}/userdata/settings.json`, is
idempotent, and also runs at the end of every full `himmel-update.sh`.

## Test

`bash scripts/t3/test-provider-instances.sh` (fixture copies only).

The chief-thread scripts (`t3-send.sh`, `keepalive.sh`, `chief-threads-check.sh`) are
described in `docs/handover/running-a-chief.md`, "Chief threads in T3 Code"; their tests
are `scripts/t3/test-t3-send.sh`, `test-keepalive.sh` and `test-chief-threads-check.sh`.
