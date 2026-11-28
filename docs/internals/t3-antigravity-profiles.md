# T3 Antigravity profiles

`scripts/t3/antigravity-profiles.sh` prepares one Antigravity home per himmel profile, so T3
Code can run an `antigravity_<profile>` provider instance (for example `antigravity_design`)
that already has the himmel hooks and the profile's skills. The registry is
`scripts/t3/antigravity-profiles.json`: per profile, `fromProfiles` (names in
`scripts/lanes/plugin-profiles.json`) and `pinnedSkills` (extra skills from a pinned git commit).

Required top-level key, beside `profiles`: `laneMcpServers`, a list of the MCP server names every
Antigravity thread may call (`t3-code`, `graphify`). Only the hook adapter reads it and checks its
shape; without it every MCP call on every Antigravity thread is denied.

Optional registry fields per profile:

- `excludePlugins`: plugin ids dropped from the profile's resolved plugin list (a list of strings,
  else rc 2), so a profile can inherit `fromProfiles` and leave one plugin out.
- `mcpServers`: a map of MCP server definitions written to the home's `config/mcp_config.json`
  (`{"mcpServers":{...}}`, mode 600), checked and rewritten like `skills.json`. Write each entry in
  the shape `agy mcp add` itself writes: `command` and `args` for a stdio server, `serverUrl` for an
  http server (smoke also reads `url`, but agy does not). A profile with neither
  `mcpServers` nor `optionalMcpServers` leaves `mcp_config.json` alone; a profile that names either key
  (even an empty one) owns the file, so a removed server leaves it. `--check` also needs mode 600, and
  `--apply` sets it. A non-object `mcpServers`, a non-object server entry, a non-list
  `optionalMcpServers`, a non-list `excludePlugins` or a server name outside letters, digits, `.`, `_`, `-` exits 2.
- `optionalMcpServers`: names resolved from `mcpCatalog` in `scripts/lanes/plugin-profiles.json` and
  added to the same file. A name missing from the catalog, or whose definition needs a checkout path
  (`${...}`), is skipped with a note on stderr, not an error. An own `mcpServers` entry wins over a
  catalog entry of the same name.
- `mcpEnv`: `{"<server>": {"<VARIABLE>": "<string>"}}`, merged into the `env` of that server's generated
  entry (a catalog server too, since `mcpCatalog` refuses literal `env` values). A name with no
  generated entry adds nothing; any other shape exits 2. The `design` profile sets `TMPDIR=/tmp` for
  `playwright`: T3's long `TMPDIR` pushes Chrome's `SingletonSocket` path past Linux's 108-byte socket
  limit, and Chrome aborts with `Socket path too long`.

## What it writes

T3 runs each Antigravity instance as `agy acp --gemini-dir <home>` with
`<home> = ${T3CODE_HOME:-$HOME/.t3}/userdata/providers/antigravity/<sha256 hex of the instance id>`.
For `antigravity_design` that is `.../0a26fb5900d14a0aec6070688e23bf158dc4097e2721393e4d7b746a1b54914e`.

`--apply` touches these paths in that home and nothing else:

- `config/hooks.json`, through `scripts/antigravity/install-antigravity-backstop.sh` (that installer
  also writes `~/.gemini/config/hooks.json` and every other provider home's `config/hooks.json`);
- `antigravity-acp/` (created mode 700 when missing) and `antigravity-acp/antigravity-oauth-token`, a
  symlink to the bare `antigravity` home's token (see "The login");
- `config/skills.json`, a regular file (mode 600) written by atomic rename;
- `config/mcp_config.json`, only for a profile that names `mcpServers` or `optionalMcpServers`: a
  regular file (mode 600) written by atomic rename.

The home is created mode 700 if missing. A pinned skill that is not cached is fetched with `git fetch`,
so an offline `--apply` exits 2.

## The login

A thread on a profile home asks for an Antigravity login unless the home holds
`antigravity-acp/antigravity-oauth-token` (every home keeps its login there; `agy acp` has no flag or
env that moves it). `--apply` links that path to the bare `antigravity` home's token
(`<T3 home>/userdata/providers/antigravity/<sha256 hex of "antigravity">/antigravity-acp/antigravity-oauth-token`):

- the script only tests and links paths; it never opens, copies or prints the token;
- a profile's own token file (a regular file) is kept, never replaced (`LOGIN-KEPT`);
- a stale or dangling link is repaired (`ln -sfn`); a token path that is a directory is refused (rc 2);
- a symlinked bare home, bare `antigravity-acp` or bare token is not shared (`NOLOGIN`), and with no
  bare login at all it prints `NOLOGIN` and rc stays 0: log in once on the bare instance, then re-run;
- `--check` fails (`login not shared`) only when the bare login exists and the profile has neither the
  link nor its own token, so a station that never logged in is not blocked. This applies to every
  `--check` caller, with the flag on or off.

Risks, accepted: if agy writes the token in place, a refresh or logout in a profile thread changes the
bare login too; if it renames on refresh, the link becomes the profile's own token file (a valid login of
its own, kept). The mechanism is provisional until the operator's live check passes: delete the design
home's own token, run `--apply`, start a thread on `antigravity_design`, expect no login prompt, then
confirm the bare `antigravity` instance still works.

## Why skills.json and not copied skills

`skills.json` is a list of directories agy scans one level deep:
`{"entries":[{"path":"/abs/dir","include_only":["name",...]}]}`. Each entry points at where the
skills already live (a Claude plugin install dir, or the pinned-skill cache), so there are no
copies to go stale, and the file is regenerated from the registry on every run. It has to be a
regular file: on each launch T3 deletes `config/skills.json` when it is a symlink and
`~/.gemini/config/skills.json` is absent.

Plugin skill locations are found the way Claude finds them: the plugin's
`.claude-plugin/plugin.json` `skills` (a string or a list), else the `skills` of its entry in the
marketplace manifest, else `./skills`. A path that is itself a skill (has `SKILL.md`) is one
skill; a directory is scanned one level for children with `SKILL.md`. A plugin that is not
installed is skipped with a warning; one with no skills adds nothing.

Pinned skills are fetched at the exact commit into
`${HIMMEL_AGY_SKILL_CACHE:-$HOME/.himmel/cache/agy-skills}/<repo>@<commit>` and the checkout's
`HEAD` must equal the commit, or the run stops (rc 2).

## Hooks first

The backstop installer only covers homes that already exist, so a new instance's first launch
would run with no himmel hooks. `--apply` therefore creates the home, runs the installer,
checks that `hooks.json` has the `himmel-antigravity-backstop` key, and only then writes
`skills.json`. If the installer fails or the key is missing, `skills.json` is not written (rc 2).

## The fence rule

himmel's Antigravity read fence denies reads under `userdata/providers/antigravity/**`, and the
hook adapter denies shell commands naming `.agents` or `.gemini`. Every entry path is resolved
(symlinks followed) and refused with `REFUSED` (rc 3, nothing written) if it lands under
`<T3 home>/userdata/providers/antigravity` or has a path segment starting `/.agents` or
`/.gemini`. This also catches a plugin whose install path is a symlink into an Antigravity home.

Besides the thread's own artifact folder, one read inside the provider home is allowed: agy's lazy MCP
tool schemas, `<own home>/antigravity-acp/mcp/<server>/<tool>.json`, `*.json` only (the
`instructions.md` beside them stays denied).
`block-antigravity-read-fence.sh` derives `<own home>` from the artifact folder, which must be
`<T3 home>/userdata/providers/antigravity/<home>/antigravity-acp/brain/<conversation>`. Only `Read` and
`read_file` get it: shell commands, `read_resource`, `list_resources` and writes stay denied. It needs a
regular file whose path, as given, ends in that `mcp/<server>/<tool>.json` under the own
`antigravity-acp/`. A `..` in the path, any other file or depth, a path naming
`antigravity-oauth-token`, and a path that reaches the file through an alias or a symlink below
`antigravity-acp/` are denied. A path that goes through `mcp/` into a symlink is denied wherever the
link points.

## What a thread may call

The hook adapter (`scripts/hooks/antigravity-hook-adapter.sh`) reads the registry on every MCP call,
by `mcp_*` name or `call_mcp_tool`:

- A server in `laneMcpServers` is admitted on every thread.
- A profile's declared servers (its `mcpServers` keys and `optionalMcpServers`) are admitted on that
  profile's thread only, and each tool only when `scripts/guardrails/mcp-policy.json` gives the server,
  under the name Antigravity reports, `verdict: "allow"` and classes the tool `read` or `write`. A new
  profile's servers need such entries; a destructive or unlisted tool is denied.
- Every other server is denied, and so is every MCP call when the registry cannot be read or has the
  wrong shape.

The thread's profile is the one whose instance home (above) holds the session's artifact folder. A
folder with a symlink anywhere below the T3 provider home, or with an empty, `.` or `..` path
segment, places no profile: the thread keeps the lane servers and loses the profile's servers and the
right to read and write that folder. A T3 home that is itself a symlink still works. The guard chain
on each admitted call still applies.

## Use

```bash
bash scripts/t3/antigravity-profiles.sh                      # dry-run: show the plan, write nothing
bash scripts/t3/antigravity-profiles.sh --apply              # every profile in the registry
bash scripts/t3/antigravity-profiles.sh --apply --profile design
bash scripts/t3/antigravity-profiles.sh --check --profile design   # rc 0 only when the home is ready
bash scripts/t3/antigravity-profiles.sh --list               # the registry's profile names, one per line
```

Copywriting: start a T3 thread on `antigravity_design` with model `gemini-4-neon`. The profile pins
no model; the thread's `modelSelection` names it, as every T3 thread does. `/lanes` lists it as the
designer lane, row `antigravity-t3-design` in `scripts/lanes/lanes.json`; models, tiers and quota stay on
the `antigravity-t3` row. Not in the patient-data vault: no Gemini thread, bare or profile, runs the
Higgsfield egress fence yet, and the `higgsfield` CLI is on PATH for both.

- `--dry-run` prints the instance id, home, whether the backstop key is present, any pinned
  fetch it would do, and the `skills.json` it would write. It creates and fetches nothing.
- `--check` writes and fetches nothing: rc 0 only when the backstop key is present, `skills.json` (and
  `mcp_config.json`, when the profile manages MCP servers) equals what `--apply` would write now with mode
  600, and the login is shared when the bare login exists; otherwise it says why (rc 1).
- A second `--apply` prints `UNCHANGED` for each file already right and leaves it byte-identical.
- `--list` is the one place the profile list is computed; `provider-instances.sh` calls it and
  never reads the registry. It prints nothing else, and exits 2 on a malformed registry or a
  profile named `relay` or ending `_relay` (its relay copy id would collide).
- Only the operator runs `--apply` on the live home; no guard enforces this (`block-edit-live-settings`
  matches path text, and `--apply` names none). `himmel-update` runs it for the operator when the
  `agy_design_profile` flag is on (see "himmel-update").
- Provision before the instance exists: T3 starts an instance the moment it is in T3's settings,
  and a home that `--check` has not passed has no himmel hooks.
- The bare `antigravity` instance is not touched; only `antigravity_<profile>` homes are.

rc: 0 ok (`--list` too); 1 `--check` not satisfied; 2 usage, missing `jq`, malformed registry or JSON input,
unknown `fromProfiles` name, a reserved `--list` profile name, pinned fetch or verify failure, backstop failure,
a symlinked profile `antigravity-acp` or a token path that is not a file or link; 3 fence refusal; 96, in
every mode, the seam guard's refusal (see "The seams are fenced").
`--smoke`: 0 every line PASS, 1 any FAIL, 2 malformed registry data (a bad profile field or registry file). `--flag-on`: 0 flag on, 1 off, 2 bad value or unreadable reader.

Env seams (tests): `T3_AP_REGISTRY`, `T3_AP_PLUGIN_PROFILES`, `T3_AP_BACKSTOP`, `T3_AP_ADAPTER`,
`HIMMEL_AGY_SKILL_CACHE`; `HOME` and `T3CODE_HOME` as usual. Modes also include `--smoke` and `--flag-on`
(below).

### The seams are fenced

The five seams above are registered in scripts/chokepoints.json, and so is the backstop installer's
`HIMMEL_PRIMARY_ROOT` (it picks the adapter written into every `hooks.json`, and `himmel-update.sh` runs
the installer on its own). Both scripts, and `provider-instances.sh`, source
`scripts/lib/chokepoint-seam-guard.sh` before any seam read: on the anchor checkout, in a session with a
Claude ancestor or a Claude Code marker, a seam that differs from the session's launch environment exits
96, however it is spelled, and a copy without the lib exits 96 too. The hook layer
(`block-chokepoint-env-prefix.sh`) also denies the typed `T3_AP_BACKSTOP=x bash scripts/t3/…` form.

Threat model: the fence stops a test seam set in a Claude session from reaching a live run of the anchor
copy. It does not stop an agent running its own worktree copy (the guard's posture for every chokepoint:
a copy is branch bytes it can run anyway), nor a Codex or Gemini session with no Claude ancestor that
exports a seam (there only the typed form is caught). Both are an accepted ceiling.

Not registered, and why: `T3CODE_HOME` (`provider-instances.sh` sets it per call for this script, so the
guard would refuse every real run); the operator opt-in `T3_PI_BUILTIN_RELAY` (adds a driver-only copy
that carries no bypass); `HOME`, `HIMMEL_REPO`, `CLAUDE_CONFIG_DIR`, `HIMMEL_FLAGS_TSV` and
`HIMMEL_CONFIG_DIR` (real configuration, which a headless or cadence launch may legitimately carry with
another value).

The suites pin each key's list against the code (rows S-LIST and S-GATE): every `${NAME` read in the
shell files and every `process.env.NAME` read in `scripts/lanes/plugin-profiles.mjs` that matches a seam
prefix must be in the key. The scan does not see three read forms: JavaScript destructuring of
`process.env`, `printenv`, and the bare `$NAME` form. None of the five files uses one today (nor any
indirect read such as `${!v}` or `process.env[...]`); a new read in those forms is caught only once its
name is added to the list.

## himmel-update

The `agy_profiles` step (`bash scripts/himmel-update.sh --only agy_profiles`, and in a full update right
before `t3_providers`) sits behind the feature flag `agy_design_profile` (`scripts/lib/flags.tsv`, default
off; a follow-up ticket removes it at publish, and it expires 2026-12-10). Turn it on with
`HIMMEL_FLAG_AGY_DESIGN_PROFILE=1` in `~/.himmel/himmel.conf.local`.

- Off: one line, `Antigravity profiles: skipped (flag agy_design_profile is off)`; nothing is written.
  A bad flag value is a `failed` row, not a silent off.
- On: `antigravity-profiles.sh --apply` for every registry profile (so each home passes `--check` before
  `t3_providers` adds its instance), then the `.t3.instance_allowlist` lines to paste into
  `~/.himmel/config.json`, for the profiles whose `--check` passes. The step never writes T3's settings
  or `~/.himmel/config.json`; skipped without T3's settings file or `jq`. A failed apply is a `failed` row.
- The flag is read through `antigravity-profiles.sh --flag-on`, because a gate script reaches
  `himmel-update.sh` by path and a flag never wraps a gate (`scripts/ci/check-flags.sh`).
- Re-apply on a plugin update: a plugin update moves its install path to a new version directory, so
  `skills.json` goes stale and `--check` prints `skills.json differs from what apply would write`. A full
  update runs every plugin-changing step (`sync_marketplaces`, `install_missing_himmel_plugins`,
  `update_installed_plugins`, `refresh_drifted_plugin_caches`, `reconcile_plugins`) before this step, so
  the home is current again when it ends (row U2 of `scripts/test-himmel-update-t3-providers.sh` pins the
  order). A `claude plugin update`, an `--only` plugin step, or a run with the flag off re-applies
  nothing; the doctor row below reports the stale home.

## Doctor

`himmel-doctor` row `C104-agy-profiles` runs `antigravity-profiles.sh --list`, then `--check --profile <p>`
for each name, and reads `--check`'s own first reason. It never runs `--apply` or `--smoke` and writes
nothing; it says nothing about T3 registration (that is `--smoke`'s `instance` line).

| `--check` result | Row |
|---|---|
| rc 0 | OK: `antigravity_<p>: profile home current` |
| rc 1, first reason `home missing` | INFO: not set up on this station; fix: `/himmel-update` with the flag on, if you use Gemini design threads |
| rc 1, any other first reason | WARN with the line; fix: `--apply --profile <p>` (operator) or `/himmel-update` |
| any other rc, or `--list` fails | WARN naming the rc and the first stderr line |

Row C1 of the suite pins the `home missing` wording the INFO case reads.

## Smoke

`bash scripts/t3/antigravity-profiles.sh --smoke [--profile design]`, run after setup, prints one line per
link a thread needs and exits 0 only when every line is `PASS`:

| line | PASS means |
|---|---|
| `login` | the profile has the bare login's link, or its own token file |
| `hooks` | `config/hooks.json` has the backstop key, and its PreToolUse command (run only when it is exactly `exec bash '<this checkout's scripts/hooks/antigravity-hook-adapter.sh>' --event PreToolUse`) exits 0 with a deny for a control read of the login file |
| `skills` | every `skills.json` entry's skill has a `SKILL.md` |
| `mcp` | every server in `config/mcp_config.json` has its command on PATH, or its URL answers (none configured is a pass: T3 serves its own `t3-code` server to each thread) |
| `instance` | T3's settings has an enabled `antigravity_<profile>` |
| `allowlist` | `.t3.instance_allowlist` in `~/.himmel/config.json` names it |

A server from `optionalMcpServers` whose command is not on PATH (or whose URL does not answer) is an `INFO mcp` line, not a `FAIL`; a server from `mcpServers` still fails.
With registry MCP servers, `mcp` also fails when `config/mcp_config.json` is missing or differs from the
registry. After the profile lines, smoke prints four `INFO cli` lines (`pnpm`, `playwright`, `npx`,
`chromium`): optional local tools a design thread may use. `pnpm` serves shadcn and frontend scaffolds;
the `playwright` CLI on PATH beats `npx playwright`, which downloads it on each use; `npx` is the
fallback for it and for npx-served MCP servers; `chromium` (or `chromium-browser`, `google-chrome`) is
the browser playwright drives. An absent one is `INFO`, never `FAIL`, and does not change the exit code.

A `FAIL` line names the missing link and the command that fixes it. Smoke writes and fetches nothing, never
opens the login file, and reaches the network only to curl an http(s) MCP server URL (5 s); the hook
command it runs may write its own hook log.

## Test

`bash scripts/quiet-run.sh suite -- bash scripts/t3/test-antigravity-profiles.sh` (a mktemp
sandbox for `HOME` and `T3CODE_HOME`, a local git repo as the pinned source, a stub backstop; no
network, nothing under the real `~/.t3`, `~/.gemini`, `~/.himmel` or `~/.claude`). Run it from a
worktree: on the primary checkout a suite that sets a registered seam exits 96 by design.

## Live check notes

The live check of a design thread grades the thread's transcript,
`<home>/antigravity-acp/brain/<conversation>/.system_generated/logs/transcript.jsonl`. A `run_command`
result there has `Command exited with code <n>.` before `Command output:`, and transcripts also hold
`SYSTEM_MESSAGE` steps. The pinned frontend skill's path lies under `~/.himmel/cache/agy-skills` and
matches none of the three patterns the check's void rule looks for (`higgsfield`, `plugins/cache`,
`.agents`), so reading it never voids an attempt that read the Higgsfield skill first.
