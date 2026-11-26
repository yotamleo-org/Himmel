# T3 Antigravity profiles

`scripts/t3/antigravity-profiles.sh` prepares one Antigravity home per himmel profile, so T3
Code can run an `antigravity_<profile>` provider instance (for example `antigravity_design`)
that already has the himmel hooks and the profile's skills. The registry is
`scripts/t3/antigravity-profiles.json`: per profile, `fromProfiles` (names in
`scripts/lanes/plugin-profiles.json`) and `pinnedSkills` (extra skills from a pinned git commit).

## What it writes

T3 runs each Antigravity instance as `agy acp --gemini-dir <home>` with
`<home> = ${T3CODE_HOME:-$HOME/.t3}/userdata/providers/antigravity/<sha256 hex of the instance id>`.
For `antigravity_design` that is `.../0a26fb5900d14a0aec6070688e23bf158dc4097e2721393e4d7b746a1b54914e`.

`--apply` touches three files in that home and nothing else:

- `config/hooks.json`, through `scripts/antigravity/install-antigravity-backstop.sh` (that installer
  also writes `~/.gemini/config/hooks.json` and every other provider home's `config/hooks.json`);
- `antigravity-acp/antigravity-oauth-token`, a symlink to the bare `antigravity` home's token (see
  "The login");
- `config/skills.json`, a regular file (mode 600) written by atomic rename.

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

## Use

```bash
bash scripts/t3/antigravity-profiles.sh                      # dry-run: show the plan, write nothing
bash scripts/t3/antigravity-profiles.sh --apply              # every profile in the registry
bash scripts/t3/antigravity-profiles.sh --apply --profile design
bash scripts/t3/antigravity-profiles.sh --check --profile design   # rc 0 only when the home is ready
bash scripts/t3/antigravity-profiles.sh --list               # the registry's profile names, one per line
```

Copywriting: start a T3 thread on `antigravity_design` with model `gemini-4-neon`. The profile pins
no model; the thread's `modelSelection` names it, as every T3 thread does.

- `--dry-run` prints the instance id, home, whether the backstop key is present, any pinned
  fetch it would do, and the `skills.json` it would write. It creates and fetches nothing.
- `--check` writes and fetches nothing: rc 0 only when the backstop key is present and
  `skills.json` equals what `--apply` would write now; otherwise it says why (rc 1).
- A second `--apply` prints `UNCHANGED` and leaves `skills.json` byte-identical.
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
unknown `fromProfiles` name, a reserved `--list` profile name, pinned fetch or verify failure, backstop failure; 3 fence refusal.

Env seams (tests): `T3_AP_REGISTRY`, `T3_AP_PLUGIN_PROFILES`, `T3_AP_BACKSTOP`,
`HIMMEL_AGY_SKILL_CACHE`; `HOME` and `T3CODE_HOME` as usual. Modes also include `--smoke` and `--flag-on`
(below).

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

## Smoke

`bash scripts/t3/antigravity-profiles.sh --smoke [--profile design]`, run after setup, prints one line per
link a thread needs and exits 0 only when every line is `PASS`:

| line | PASS means |
|---|---|
| `login` | the profile has the bare login's link, or its own token file |
| `hooks` | `config/hooks.json` has the backstop key, and its PreToolUse command denies a control read of the login file |
| `skills` | every `skills.json` entry's skill has a `SKILL.md` |
| `mcp` | every server in `config/mcp_config.json` has its command on PATH, or its URL answers (none configured is a pass: T3 serves its own `t3-code` server to each thread) |
| `instance` | T3's settings has an enabled `antigravity_<profile>` |
| `allowlist` | `.t3.instance_allowlist` in `~/.himmel/config.json` names it |

A `FAIL` line names the missing link and the command that fixes it. Smoke writes and fetches nothing and
never opens the login file; the hook command it runs may write its own hook log.

## Test

`bash scripts/quiet-run.sh suite -- bash scripts/t3/test-antigravity-profiles.sh` (a mktemp
sandbox for `HOME` and `T3CODE_HOME`, a local git repo as the pinned source, a stub backstop; no
network, nothing under the real `~/.t3`, `~/.gemini`, `~/.himmel` or `~/.claude`).
