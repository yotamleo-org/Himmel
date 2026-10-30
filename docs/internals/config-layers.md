# Configuration layers

Every himmel setting has one home and one rule for who wins. This page lists
the homes, who owns each one, whether it is tracked in git, and the order in
which they are read.

Settings come in two scopes. **User scope** is every file under `~/.himmel`
(and the keyring): it applies to every repo you run himmel in. **Project
scope** is one file, `.himmel/project.conf`, committed in a repo you adopted:
it applies only to sessions that run in that repo. A project file can change
the project-scope behaviour keys for its repo, and can make a gate stricter than your user
setting, but never looser.

## The layers

| Layer | File | Owner | Tracked? | Holds |
|---|---|---|---|---|
| Project override | `<repo>/.himmel/project.conf` | the repo's maintainers (a hook refuses agent writes) | yes, in the adopted repo | project-scope behaviour keys (never station paths or identity), and gate-policy keys that may only tighten |
| Secrets | the OS keyring through `scripts/lib/himmel-secrets`, then legacy `<primary checkout>/.env` | operator | never (gitignored, unreadable to agents) | API tokens, passwords, credentials, and the keys not yet classified (below) |
| Behaviour config | `~/.himmel/himmel.conf` | operator, reviewable | yes on a luna install (a link to `<vault>/.himmel/himmel.conf`); a plain file otherwise | non-secret knobs: `HANDOVER_DIR`, `CR_PROFILE`, `HIMMEL_INITIATIVE`, … |
| Station profile | `<vault>/.himmel/profiles/<name>.conf`, found beside the link target of `~/.himmel/himmel.conf` | operator, reviewable | yes, in the vault | the same behaviour keys, for one named station; `himmel.conf` is the DEFAULT profile |
| Local override | `~/.himmel/himmel.conf.local` | operator, this machine | never | the same keys, for one machine only |
| Gate policy | `~/.himmel/config.json`, under `"policy"` | operator only (a hook refuses agent writes) | no | `CR_REQUIRE_CROSS_MODEL`, `CR_FLOOR_FALLBACK`, `ARMAUTOMERGE`, `ENV_MIGRATION_CONSENT`, `HIMMEL_FLEET_CAP` |
| Adopter config | `~/.himmel/config.json`, other fields | `himmelctl install`; `jira.sectorField` by the operator | no | luna cadence, bridge, PHI declarations, the Jira Sector field id (`jira.sectorField`) |
| Install profile | `~/.claude/himmel/install-profile.json` | `himmelctl install` | no | the wizard's answers, replayed by `--from-profile` |
| Handover registry | `~/.claude/handover/registry.json` | `/handover` | no | handover repos, buckets, branch prefixes |
| Plugin and lane profiles | `scripts/machine-setup/` profiles, chief-kit `--profile` | himmel repo | yes | which plugins and tools a session loads |
| Chief rules | chief template, worker and judge system prompts, hooks | himmel repo | yes | how chiefs and workers behave |
| Per-chief state | the fleet manifest in the handover bucket | the chief | in the state repo | which workers are live, their docs and tokens |

Status and state are never tracked as configuration: a file that changes
every session (fleet manifest, queue locks, ledgers) is state, not config.

## Who wins

Behaviour keys, read by `load_dotenv` in `scripts/lib/load-dotenv.sh`:

1. the process environment (a non-empty value)
2. `<repo>/.himmel/project.conf`, project-scope keys only
3. `~/.himmel/himmel.conf.local`
4. the active station profile (next section), when one is named
5. `~/.himmel/himmel.conf`, the DEFAULT profile
6. legacy `.env`, with a `DEPRECATED` notice on stderr
7. the consumer's own default

Gate-policy keys, read by `load_policy` in `scripts/lib/load-dotenv.sh`:

1. `~/.himmel/config.json` `.policy`
2. legacy `.env`, with a `DEPRECATED` notice
3. unset, which every gate treats as its safe default

Then the project file is checked: a policy key it sets replaces the value
above only when it is stricter (next section).

The process environment is **not** in the policy list. A gate-policy key can
only change by editing a file the operator owns, so
`CR_FLOOR_FALLBACK=claude-only bash scripts/cr/clear-review-marker.sh` does not
loosen the review gate; `load_policy` drops the value and prints
`ignoring process-env CR_FLOOR_FALLBACK`. A policy key written into
`himmel.conf` or `himmel.conf.local` is ignored too, because no hook guards
agent writes to those files yet.

Secrets come from the resolver (next section), never from `himmel.conf`. A
secret key planted in `himmel.conf` is never loaded.

A policy key exported from a shell profile (for example a sourced
`~/.config/himmel/env`) is process env too, so it is ignored with the same
notice. Move it into `config.json` `.policy`; a behaviour key exported there
still wins, as the list above says.

The policy directory is `<account home>/.himmel`, where the home comes from
the account's passwd entry (`getent passwd`, or `dscl` on macOS), never from
`$HOME`. So `HOME=/tmp/x bash scripts/cr/clear-review-marker.sh` still reads the
operator's own policy file, not one planted under `/tmp/x`. Behaviour keys in
`himmel.conf` still follow `$HOME` (or `HIMMEL_CONFIG_DIR`).
`HIMMEL_LUNA_CONFIG_PATH`, which `himmelctl` honours for its own fields, is
not consulted for policy. The test suites set `HIMMEL_POLICY_FOLLOWS_HOME=1`
to point the policy directory back at their temp `$HOME`. That variable is a
registered seam on the gates that read policy (`scripts/chokepoints.json`),
so a per-call prefix or export of it in a session is refused.

### The project override

The file is `.himmel/project.conf` at the root of the repo's primary
checkout, in the same `KEY=value` form as `himmel.conf`, parsed and never
executed. The repo is the one the command runs in, found through
`git rev-parse --git-common-dir`, so a session in a worktree reads its
primary checkout's file, not the worktree's copy. The gate scripts pass
`--root` pointing at the himmel checkout; that root still picks `.env`, but
never the project file. Outside a git repo there is no project file.

- **Behaviour keys**: the project file serves project-scope keys only:
  `CR_PROFILE`, `CR_CLAUDE_AGENTS`, `TICKET_ID_REQUIRED`, `TICKET_ID_PATTERN`,
  `TICKET_ID_EXEMPT_AUTHORS`, `TRACKER`, `JIRA_PROJECT_KEY`, `JIRA_PROJECTS`
  and `HIMMEL_DOC_FRESHNESS`. They beat `himmel.conf.local` and
  `himmel.conf`; the process environment still beats the project file.
  Station-scope keys (`HANDOVER_DIR`, `LUNA_VAULT_PATH`, `USER_SLUG`,
  `JIRA_EMAIL`, the org and account ids, `HIMMEL_UPDATE_AUTOSTASH`, the
  initiative and AFK keys) are never read from it, even when `himmel.conf`
  does not set them, so a committed file cannot move where a station keeps
  its state.
- **Gate-policy keys** from the project file can only tighten. Each key has a
  strict side, read as the gates read it (trimmed, any case):

  | Key | Strict | Loose |
  |---|---|---|
  | `CR_REQUIRE_CROSS_MODEL` | `1`, `true`, `on`, `yes` | anything else, or unset |
  | `CR_FLOOR_FALLBACK` | anything but `claude-only`, or unset | `claude-only` |
  | `ARMAUTOMERGE` | anything but `1`, `true`, `on`, `yes`, or unset | `1`, `true`, `on`, `yes` |

  A project value on the strict side replaces a user value on the loose side,
  so `CR_REQUIRE_CROSS_MODEL=1` in the project file turns the cross-model
  requirement on for that repo when your user value is `0`. A project value
  on the loose side, while your user value is strict, is ignored with one
  line on stderr:
  `himmel: ignoring CR_FLOOR_FALLBACK from <file>: a project file may only tighten gate policy, never loosen it`.
  `load_dotenv` applies the same rule to the policy keys it serves, even
  one the process environment set, so `pr-check-env.sh` shows the project
  file's tightening the gate enforces.
  A project `ARMAUTOMERGE=0` governs only the default `arm-resume.sh` reads
  through `load_policy`. It does not stop `headed-arm.sh`, which launches
  with `ARMAUTOMERGE=1`, or an `ARMAUTOMERGE=1` passed to `merge-on-green.sh`
  in its environment.
- **Secret keys** are never read from the project file. A token written there
  is skipped and the resolver order below applies.
- **Writes**: `block-himmel-config-writes.sh` refuses an agent's Edit, Write
  and `apply_patch` on any `.himmel/project.conf`, in any repo or worktree, and
  a Bash command that names one, except a plain read. A session therefore
  cannot change its own repo's settings; the maintainers change the file by
  hand, and through review like any other tracked file.
- A project file that exists but cannot be read or parsed, including a
  symlink whose target is gone or a directory, makes `load_policy` return
  non-zero, so the gate refuses instead of guessing.

### Station profiles

`~/.himmel/himmel.conf` is the DEFAULT profile. A named profile is
`<vault>/.himmel/profiles/<name>.conf`, in the same `KEY=value` form, parsed
and never executed. It sits in the vault beside the file `himmel.conf` links
to, so it is tracked with DEFAULT; a plain `himmel.conf` (no vault link) has no
profiles.

- **Selecting one**: `HIMMEL_PROFILE=<name>` in the process environment, else
  a `HIMMEL_PROFILE=<name>` line in `~/.himmel/himmel.conf.local`, which is
  per machine and never tracked. The tracked files cannot select a profile. A
  name that is not a plain file stem (letters, digits, `.`, `_`, `-`; no
  leading dot) selects nothing, so a name cannot walk out of `profiles/`.
- **Layering**: a profile key beats DEFAULT, and loses to the process env,
  the project file and `himmel.conf.local`. A key the profile lacks falls
  through to DEFAULT.
- **Behaviour keys only**: the profile is read by the same class filter as
  `himmel.conf`, so a gate-policy or secret key in it is never honoured.
  Policy still comes only from `config.json`, read by `load_policy`, which
  never opens a profile.
- **Creating one**: `bash scripts/setup/migrate-env-config.sh --vault <dir>
  --profile <name>` makes `<dir>/.himmel/`, links `himmel.conf` into it, and
  creates an empty `profiles/<name>.conf`. Re-run it with only `--profile
  <name>` on a linked vault. It needs no `.env`, and never overwrites an
  existing profile.
- **Uninstall**: profiles live in the vault, behind the `himmel-conf` link,
  so `--purge-state` unlinks `himmel.conf` and never touches them; no manifest
  row is added.

### Failure behaviour

| Situation | Behaviour keys | Gate-policy keys |
|---|---|---|
| `himmel.conf` missing | fall through to `.env`, then the default | n/a |
| `config.json` missing | n/a | notice; legacy `.env` or the safe default |
| `config.json` not valid JSON | notice; legacy `.env` | `load_policy` returns non-zero; `clear-review-marker.sh` refuses (exit 14) |
| `.env` present but unreadable | key stays unset | `load_policy` returns non-zero; the gate refuses |
| the account's passwd entry cannot be read | n/a | `load_policy` returns non-zero; the gate refuses |

`himmel-doctor` check C74 reports a half-migrated station: `himmel.conf`
missing or unparseable, behaviour keys still in `.env`, and gate keys the
policy file does not yet hold. It prints key names only, never values.

A missing file never turns a gate on its permissive side: unset policy keys
leave the cross-model requirement off, the floor fallback off, and automerge
off, which are today's defaults.

## Secrets: the keyring resolver

`scripts/lib/himmel-secrets` serves every secret-class key. `load_dotenv`
asks it for secret keys it has not found yet, so shell consumers need no
change. Order, first hit wins:

1. the process environment (a non-empty value)
2. `$CREDENTIALS_DIRECTORY/<KEY>` (a systemd unit's `LoadCredential=`)
3. the OS keyring: first the item for this project
   (`service himmel key <KEY> project <primary checkout path>`), then the
   user-wide item (`service himmel key <KEY> scope user`)
4. legacy `.env`, with one `DEPRECATED` line on stderr naming the keys,
   printed only where `secret-tool` is installed (never on macOS)
5. unset

The keyring is Linux only for now (libsecret's `secret-tool` against a Secret
Service such as gnome-keyring or KWallet); macOS falls through to `.env`. The
resolver never prompts: a locked keyring prints
`himmel-secrets: keyring locked (unlock the wallet or run himmel-secrets status)`
and falls through within 3 s, and a cron or systemd job without
`DBUS_SESSION_BUS_ADDRESS` finds the session bus under
`$XDG_RUNTIME_DIR/bus`, or `/run/user/<uid>/bus` when `XDG_RUNTIME_DIR` is
unset too. `HIMMEL_SECRETS_KEYRING=off` skips the keyring.

The secret keys of a `.env` that git tracks are refused with one line naming
the file; only an untracked `.env` serves secrets.

Verbs: `get KEY…`, `exec --keys KEY[,KEY…] -- <command>` (runs the command
with only those keys added to its env), `status [KEY…]` (the layer serving
each key, names only), `put KEY` (value from stdin or a silent prompt;
`--project` stores a per-project item), `import-env <file>` (stores each
secret key of a dotenv file that `scripts/himmelctl/lib/secrets-manifest.json`
lists, in `secrets` or `stationSecrets`, and prints names only; any other line is named by its number, and a
file whose quoted value does not close on its line is refused) and `export-env <file>`
(writes the keyring's himmel items to a new 0600 dotenv file).
`block-read-secrets.sh` refuses an agent's direct `get`, `put`, `import-env`
and `export-env` commands and direct keyring reads. That is not a full
barrier: an agent can still reach `get` by sourcing the script
(`. scripts/lib/himmel-secrets get KEY`), which HIMMEL-7585 tracks.

`himmel-doctor` check C75 reports the keyring state (`C75-keyring`) and which
secret names are still served from `.env` (`C75-secrets`), names only.

Moving a station: import-env skips a secret the manifest does not list, so
add a new one to `stationSecrets` first. Then:

1. `bash scripts/lib/himmel-secrets import-env <primary checkout>/.env`. It
   prints `stored KEY` for each key it moved.
2. `himmel-secrets status KEY…` with those keys names `keyring` for each one.
   `env`, `credentials` or `keyring-project` means another layer still serves
   that key ahead of the stored item: settle that layer first.
3. Delete from `.env` exactly the lines import-env printed as `stored`, and
   nothing else. Until you do, each secret is still in plain text on disk.
   A line it skipped stays: `JIRA_BASE_URL`, `FIRECRAWL_BASE_URL` and
   `WHISPER_MODEL` stay in `.env` for good (nothing else reads them). The
   others stay until they move to `~/.himmel`: a config key, or
   `HIMMEL_FLEET_CAP`, which is gate policy and belongs in `config.json`
   `.policy` (see the gate policy list below). A legacy `.env` cap still
   applies, with the `DEPRECATED: HIMMEL_FLEET_CAP read from .env` notice.
4. `bash scripts/himmel-doctor.sh --only C75` shows `OK C75-secrets: no secret
   comes from .env`. C75 counts only the manifest's secrets, so a
   `HIMMEL_FLEET_CAP` line left in `.env` does not fail it.

## The .env split: what moves, what stays, and a mismatch

Behaviour config (`himmel.conf`): `HANDOVER_DIR`, `USER_SLUG`,
`LUNA_VAULT_PATH`, `HIMMEL_DOC_FRESHNESS`, `HIMMEL_INITIATIVE`,
`HIMMEL_AFK`, `HIMMEL_INITIATIVE_AFK`, `HIMMEL_WHERE_ARE_WE`,
`HIMMEL_WHERE_ARE_WE_STALE_HOURS`, `HIMMEL_WORKTREE_NUDGE`,
`HIMMEL_UPDATE_AUTOSTASH`, `CR_PROFILE`, `CR_CLAUDE_AGENTS`,
`TICKET_ID_REQUIRED`, `TICKET_ID_PATTERN`, `TICKET_ID_EXEMPT_AUTHORS`,
`TRACKER`, and the plain settings `HIMMEL_REPO`,
`CLAUDE_HUD_ALLOW_EXTRA_CMD`, `HIMMEL_WHERE_ARE_WE_ROLLUP_TTL`,
`HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT`, `HIMMEL_JIRA_NUDGE`, `CR_APP`,
`CR_PUBLIC_REPO`, `CLAUDE_END_SESSION_WIKI`, `SKILL_INDEX_DIR` and the four
`ALIBABA_*_BASE_URL` endpoints.

Non-secret Jira and service identifiers also belong in `himmel.conf`:
`JIRA_EMAIL`, `JIRA_PROJECTS`, `JIRA_PROJECT_KEY`, `JIRA_CLOUD_ID`,
`GCP_CI_PROJECT_ID`, `SNYK_ORG_ID`,
`SNYK_ORG_SLUG`, `VERCEL_TEAM_ID`, `VERCEL_USER_ID`, `ANTHROPIC_API_ORG_ID_A`,
`ANTHROPIC_API_ORG_ID_B`. Their meanings and defaults are unchanged;
`.env.example` documents them. The Jira CLI reads its identifiers through
these same config layers; API tokens still come only from the process env
or legacy `.env`, never from `himmel.conf` or its local override.

Every reader of these keys follows the same order as `load_dotenv`: the
process env, `himmel.conf.local`, `himmel.conf`, the legacy `.env`, the
default. Only the shell loader reads the project file so far; the Jira CLI,
the lane resolver, the profile capture and the config UI (HIMMEL-7134) do
not yet. A reader that opens only `.env`, or only the process env, misses a
key the operator has moved; the shell, the Jira CLI
(`scripts/jira/src/handover-root.ts`), the lane resolver, the profile capture
and the config UI all resolve it that way.

Gate policy (`config.json` `.policy`): `CR_REQUIRE_CROSS_MODEL`,
`CR_FLOOR_FALLBACK`, `ARMAUTOMERGE`, `ENV_MIGRATION_CONSENT` and
`HIMMEL_FLEET_CAP` (read only from `config.json`, then the legacy `.env`).

`HIMMEL_FLEET_CAP` became gate policy in HIMMEL-3111. `usage-preflight.sh`
reads it through `load_policy`, so **an exported `HIMMEL_FLEET_CAP` no longer
counts**: a launching shell, a wrapper or a per-call prefix cannot raise the
cap, and `load_policy` prints `ignoring process-env HIMMEL_FLEET_CAP` when one
differs. Set it in `~/.himmel/config.json` `.policy.HIMMEL_FLEET_CAP` (a whole
number); a legacy `.env` line still applies, with the `DEPRECATED` notice, until
`scripts/setup/migrate-env.sh` moves it. Unset, or a value that cannot be read,
means 4. The project file cannot set it (it has no strict side). The config UI
shows the cap read-only and names the file to edit; no tool writes it.

Three keys an operator may have in `.env` are never read from it:

- `HIMMEL_STATUSLINE_ECON` is read from the process environment only, by
  `scripts/statusline/hud-custom-lines.sh`; `scripts/lib/wire-statusline.sh` sets it as a prefix on the
  status line's `customLineCommand` in the settings.
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is Claude Code's own variable; the lane
  launchers export their own value, and the worker context guard reads the
  process environment.
- `CODERABBIT_CLI_DISABLE` is dead: its reader went with the CodeRabbit CLI
  review step (HIMMEL-2704). Deleting the line is the operator's call.

Everything else stays in `.env`. That includes keys whose secret-or-config
class has not been decided yet: other account emails, cookie-file
paths, service URLs and VM user names. Only the explicitly named identifiers
above are config; tokens and all other unclassified keys remain secrets.
Five more keys are config, so `import-env` leaves them alone (HIMMEL-8165).
`TELEGRAM_CHAT_ID` and `TELEGRAM_GROUP_CHAT_ID` are served from `himmel.conf`;
they decide where messages go, and `himmel.conf` is not guarded against an
agent's writes. That exposure is accepted: a changed chat id re-routes
Telegram messages, not credentials. A git-tracked `.env` serves neither id.
`JIRA_BASE_URL`, `FIRECRAWL_BASE_URL` and `WHISPER_MODEL` are env-only: no
`himmel.conf` layer serves them, so `JIRA_BASE_URL` (the destination of the
Jira token, HIMMEL-3111) cannot be redirected by a planted config, and
`import-env`, `migrate-env.sh` and the setup wizard keep them in `.env`.

The registry is `_himmel_key_class` in `scripts/lib/load-dotenv.sh`. A key
moves from secret to config only by editing that list in a reviewed PR.

`TICKET_ID_REQUIRED` and `TICKET_ID_EXEMPT_AUTHORS` loosen the commit-message
gate when set, so they are candidates for the policy list. They stay
behaviour config until the commit-message hook reads them through
`load_policy`.

**What stays in `.env`.** Secrets that something reads stay in `.env` until
the keyring work (HIMMEL-7147, HIMMEL-7576) is complete.
`scripts/setup/migrate-env.sh` leaves in `.env` every secret a tracked himmel
file other than docs still reads, every secret
named in `~/.himmel/env-keep.txt` and every key `.env.example` and the registry
do not name (another tool's key). Only a himmel secret that nothing in this
checkout reads moves, to `~/.config/secrets/himmel.env` (mode 600). The migration
report lists the secrets that stay. It removes only the moved lines, so a
`.env` that held nothing else ends up with no keys, and
`himmel-secrets import-env` copies secrets into the keyring without removing
them from `.env`.

**On a mismatch.** When a key's `~/.himmel` side (`himmel.conf`, or
`config.json` `.policy` for a gate-policy key) already holds a different value
from `.env`, the migration names the key and both files, never the values, and
asks `[e/h]`: `e` writes the `.env` value to `~/.himmel`, `h` keeps the
`~/.himmel` value. The readers then run again, and the moved lines leave
`.env` only when they agree. Any other answer, or none, stops with every
`.env` line in place. If any failure is of another kind (a reader that
disagrees on a key `~/.himmel` did not hold, or a `verify:` line), there is no
prompt and nothing is removed: fix the reader or make the two files agree,
then run the migration again. Never empty `.env` by hand to settle one; to go back, run the
`restore:` command it printed
([updating.md](../setup/updating.md#the-env-split-what-moves-what-stays-and-a-mismatch)).

## Example files

Tracked templates to copy: `docs/setup/himmel.conf.example` (every behaviour
key, commented out) and `docs/setup/himmel-config.example.json` (the policy
section, every key `null`, which reads as unset). `scripts/lib/test-load-config.sh`
checks that each template names only keys of its own class.

`~/.himmel/himmel.conf` uses the same `KEY=value` form as `.env`. It is
parsed, never executed:

```
HANDOVER_DIR=/home/me/Documents/luna/handovers
CR_PROFILE=free,paid
HIMMEL_INITIATIVE=prcheck,pr,ticket,handover
```

`~/.himmel/config.json`, policy section (other fields belong to `himmelctl`):

```json
{
  "version": 1,
  "policy": {
    "CR_REQUIRE_CROSS_MODEL": "1",
    "CR_FLOOR_FALLBACK": "claude-only"
  }
}
```

`himmelctl install` keeps the `policy` field untouched and names it in one
`WARN` line, as it does for any field outside its own schema.

## Chief rules

Prose and hooks stay where they are: the chief template, the worker and judge
system prompts, and the hooks are code, reviewed in the himmel repo. A rule that is
a tunable number or switch moves to `himmel.conf`; per-chief state stays in
the fleet manifest.

Example: the fleet size cap. The rule "a chief never runs more workers than
the cap" stays in the chief template and its enforcing script. The number
itself is a tunable knob, so it belongs in configuration, not prose. Raising
it loosens a safety limit, so its home is the policy section of
`config.json`, not `himmel.conf`: `.policy.HIMMEL_FLEET_CAP`, which the
preflight reads while ignoring the process env. Which workers are live right
now is state, so it stays in the fleet manifest.

## Feature flags

A feature flag ships new behaviour dark and lets one run turn it on. The registry
is `scripts/lib/flags.tsv`: one row per flag (`name default kind owner removal
expires description`). A flag is read only through `scripts/lib/flags.sh`
(`himmel_flag <name>`, rc 0 on, 1 off, 2 unknown), `flags.py` or `flags.mjs`.

Resolution order, first hit wins: the process env `HIMMEL_FLAG_<NAME>` (`1` or `0`),
then `himmel.conf.local`, then `himmel.conf` under `HIMMEL_CONFIG_DIR`, then the
registry default. A flag is never read from `.env`.

Rules, enforced by `scripts/ci/check-flags.sh` on every CI event:

- **No guard behind a flag.** A flag never wraps a safety rail: not under
  `scripts/hooks/`, not in a gate script, not on a `ci-trust-paths.txt` path.
- **14-day expiry.** `expires` is 14 days from birth; once it passes, CI goes red on
  main too. The removal sub-task named in the row deletes the flag and its branches.
- **Registered and read.** A flag the code reads must be in the registry, and a
  registered flag must have a reader.

Current readers: `chain_soft_edges` in `scripts/handover/chief-kit/next-dispatchable.sh`.

## Why this route

Two routes were compared.

**Option 1: a tracked file in the luna vault, with a gitignored `.local`
override.** Settings become reviewable and travel with the vault. On its own
it breaks adopters who have no luna vault: there is no tracked place for the
file, and every reader would need to find the vault first.

**Option 2: extend `~/.himmel/config.json`, with env > config > default.**
Works for every install, but the file is untracked, so changes are not
reviewable; and env > config contradicts the requirement that gate policy
cannot be overridden from the environment.

**Chosen: both, split by key class.**

- Behaviour keys use a fixed path, `~/.himmel/himmel.conf`. On a luna install
  it is a link into the vault, so it is tracked and reviewable (option 1's
  benefit). Without luna it is a plain file, so adopters lose nothing (option
  2's reach). Env still wins for these keys, as it always has.
- Gate-policy keys use `~/.himmel/config.json`, which a hook already keeps
  agents from writing, and their reader ignores the environment. This removes
  the env > config conflict for exactly the keys where it matters.
- Nothing that works today stops working: every key still found only in
  `.env` keeps its value until you migrate it.

Policy keys can move into the tracked `himmel.conf` once a hook guards agent
writes to it.

## Migrating an existing install

The update runs the whole migration as one step for himmel's own keys (other
tools' keys stay in `.env`): a dry run you confirm, a backup, the copy, a check
with the real readers, and only then the removal of the moved lines from
`.env` ([updating.md](../setup/updating.md#the-env-migration)). Preview it with
`bash scripts/setup/migrate-env.sh --dry-run`. The steps below are the manual
route for behaviour and policy keys.

The confirmation needs a terminal, so an update run by an agent stops at
`env_migration pending`. To let it finish unattended, set
`"ENV_MIGRATION_CONSENT": "1"` under `"policy"` in `~/.himmel/config.json`
yourself. The key is read only from that file: the process env and `.env`
cannot grant it. With it set, the migration skips the prompt but keeps the
backup and the check. A mismatch still stops before anything is removed, and
names the key and both readers, never the values; only you, at a terminal,
choose which side wins.

The consent covers less than a typed `y`, so an agent cannot use it to change
gate policy or move your files elsewhere:

- Gate-policy keys stay in `.env`. Run the move at your own prompt to move them.
- It applies only to the checkout's own `.env`, never a `--env` file somewhere else.
- It writes only into your account's own `~/.himmel`. With `HOME` or
  `HIMMEL_CONFIG_DIR` pointing elsewhere, it writes nothing.

Setup, adopt and `himmelctl` read and write the behaviour keys in
`~/.himmel/himmel.conf` (a key already set in `.env` is still read as a
fallback), so the migration can run at any time. `--dry-run` lists what would
move without writing.

1. Run `bash scripts/setup/migrate-env-config.sh --dry-run` to list the keys
   it would move. It prints key names only, never values.
2. Run it again without `--dry-run` (add `--vault <luna vault>` on a luna
   install to keep the file in the vault). Behaviour keys are copied into
   `~/.himmel/himmel.conf`; secrets are not touched.
3. For gate-policy keys it prints one command per key. Run each at your own
   prompt: it reads the value from `.env` and writes it into
   `~/.himmel/config.json`, so the value is never shown.
4. Start a session. When no `DEPRECATED: … read from .env, which is for
   secrets only` notice appears, delete the moved lines from `.env`, and only
   those: the secrets in it are still read, and their
   `DEPRECATED: secret … read from` notice is expected.
   Rebuild the Jira CLI first (`scripts/jira/dist` is not
   tracked): an older build reads `HANDOVER_DIR` from the process env or
   `.env` only, not from `himmel.conf`.

The `.env` fallback for non-secret keys is removed one release after setup,
adopt and `himmelctl` read the new files.

## Not covered yet

A shared multi-user layer (a team's company brain feeding settings to every
member) is out of scope. It is on the backlog; the layer table above leaves
room for it above `himmel.conf`.
