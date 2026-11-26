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

`--apply` touches two files in that home and nothing else:

- `config/hooks.json`, through `scripts/antigravity/install-antigravity-backstop.sh`;
- `config/skills.json`, a regular file (mode 600) written by atomic rename.

The home is created mode 700 if missing.

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
  matches path text, and `--apply` names none). `himmel-update` does not run this step yet.
- Provision before the instance exists: T3 starts an instance the moment it is in T3's settings,
  and a home that `--check` has not passed has no himmel hooks.
- The bare `antigravity` instance is not touched; only `antigravity_<profile>` homes are.

rc: 0 ok (`--list` too); 1 `--check` not satisfied; 2 usage, missing `jq`, malformed registry or JSON input,
unknown `fromProfiles` name, a reserved `--list` profile name, pinned fetch or verify failure, backstop failure; 3 fence refusal.

Env seams (tests): `T3_AP_REGISTRY`, `T3_AP_PLUGIN_PROFILES`, `T3_AP_BACKSTOP`,
`HIMMEL_AGY_SKILL_CACHE`; `HOME` and `T3CODE_HOME` as usual.

## Test

`bash scripts/quiet-run.sh suite -- bash scripts/t3/test-antigravity-profiles.sh` (a mktemp
sandbox for `HOME` and `T3CODE_HOME`, a local git repo as the pinned source, a stub backstop; no
network, nothing under the real `~/.t3`, `~/.gemini`, `~/.himmel` or `~/.claude`).
