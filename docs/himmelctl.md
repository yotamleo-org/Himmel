# himmelctl verb reference

`himmelctl` is the install, converge and offboard CLI. Run it as
`node <himmel-checkout>/scripts/himmelctl/bin.js <verb>` (or the `himmelctl`
shim if your install put one on `PATH`). `bin.js --help` prints the
authoritative text; this page is the map of what each verb is for and what its
exit codes mean.

Step-by-step install is [setup/install.md](setup/install.md); the four
lifecycle paths (install, update, ensure, uninstall) are
[setup/updating.md](setup/updating.md). This page covers every verb, including
the ones those pages only mention in passing.

## Verbs at a glance

| Verb | Mutates? | One line |
|---|---|---|
| `install` | yes | Wizard (or `--scope` / `--from-profile`) that wires himmel into a project or your user scope |
| `status` | no | Severity diff of installed items against the desired manifest |
| `ensure` | yes | Converge the install toward the manifest; converge-only unless `--prune` |
| `update` | yes | Update this checkout and its dependency chain (same engine as `/himmel-update`) |
| `uninstall` | yes | Offboard himmel; code only unless `--purge-state` |
| `scope` | yes (`set`) | Read or switch the install scope |
| `profile` | yes (`lean`/`full`/`enable`/`disable`) | Inspect or toggle the plugin profile (same engine as `/profile`) |
| `config` | yes (`set`) | Toggle capabilities: initiative auto-ship steps, lanes, opt-in hooks |
| `deps` | `ensure`/`upgrade` only | Check, install or bump the declared toolchain |
| `gaps` | no | What this setup lacks relative to a reference install profile |
| `trust` | yes | Wire or unwire the trust shadow ledger's hook entries |
| `report` | no | Read-only JSON config feed that the config UI renders; secrets show presence, never values. See [ui.md](ui.md) |
| `ui` | no | Read-only config console on 127.0.0.1 (needs bun); the operator runs it from a terminal. See [ui.md](ui.md) |
| `--version [--all]` | no | Version, describe string, commit; `--all` adds per-component currency |

Shared flags: `--dry-run` / `-n` prints the plan and changes nothing,
`--json` gives machine-readable output on `status`, `deps status` and `gaps`,
`--yes` skips the confirmation on `ensure`, `deps ensure`, `deps upgrade` and
`scope set`, and `--items <a,b>` scopes `status` / `ensure` to the listed item
ids. `-h` / `--help` prints the usage text.

## `status`

Read-only. Prints each desired item with a severity (green, degraded, red) for
the install in the current scope. Run it from the adopted project's root for
project scope, or from the himmel checkout for user scope. Use `--items` to
narrow it and `--json` to script it.

## `ensure`

Installs or wires whatever `status` reports red or degraded. By default it is
**converge-only**: it never unwires or disables an item that is no longer
desired. That is a separate, higher-risk consent behind `--prune`, never
bundled into the same prompt. `--profile <core|luna|all>` reconciles the
target to that install profile first. Run it from the same location the
matching `install` ran from.

## `update`

Thin wrapper around `scripts/himmel-update.sh`, the engine `/himmel-update`
uses: a full dependency-chain check and update with per-item status, aborting
on the first failure. A release-tarball install in the versioned layout
(`<base>/<version>/` plus `<base>/current`) instead downloads, verifies and
extracts the latest release into a new version directory and swaps `current`.

## `uninstall`

Symmetric offboarding across both scopes. `--dry-run` lists every path, plugin,
hook and settings key it would remove and touches nothing. The default removes
himmel's **code** only; operator state (Telegram pairing, bridge state) is kept
unless you pass `--purge-state`. `--yes` is required when non-interactive.

| Exit | Meaning |
|---|---|
| 0 | Torn down |
| 2 | Refused (non-interactive without `--yes`) or incomplete teardown (a required step could not run) |
| 3 | Declined by the operator, or teardown refused a wet run against a non-fixture `HOME` |
| other | The teardown script's own exit code |

## `scope`

`scope get` (alias `scope status`) prints the current scope. `scope set
<project|user>` re-projects the install: it wires the target scope **and**
unwires the old one, with an interactive confirm (`--yes` skips it,
`--dry-run` prints the plan). It refuses to leave any item wired in both scopes
(fail-closed).

| Exit | Meaning |
|---|---|
| 0 | Done (or a dry run that predicts success) |
| 1 / 2 | A real error, or a usage or consent problem |
| 3 | Refused before any change was made. A `--dry-run` that predicts that refusal also exits 3 |

## `profile`

Wraps `scripts/machine-setup/plugin-profile.sh`, the engine `/profile` uses.

```bash
himmelctl profile list [--json]     # always-on tier and on-demand tier, enabled or disabled
himmelctl profile lean              # the always-on set only
himmelctl profile full              # also enable the on-demand set
himmelctl profile enable <spec>     # one plugin
himmelctl profile disable <spec>
```

`<spec>` is `plugin@marketplace`, or a bare name when unambiguous. `--dry-run`
prints the plugin-toggle commands instead of running them. This is the
**plugin** profile; it is unrelated to the *install* profile that `install`
and `gaps` read.

## `config`

Bare `himmelctl config` asks nothing: it prints the link to the UI Configure
page, where himmel capabilities are toggled without hand-editing files. When
the UI service is not installed it says how to open the UI (`himmelctl ui`, or
`himmelctl ui --service install` to keep it running). For scripts, the same
settings the UI shows are read and written with:

```bash
himmelctl config get <path>
himmelctl config set <path> on|off
```

| Path | Controls |
|---|---|
| `initiative.<leg>` | Initiative auto-ship steps (`HIMMEL_INITIATIVE` steps) |
| `lanes.<id>` | Delegation lanes |
| `hooks.plugin.<name>` | Opt-in hook plugins; set-only, runs `claude plugin enable` or `disable` |

`hooks.improveOnSubmit` is a launching-shell env var, not settable here, and
`config get` does not report hook state (exit 2).

## `deps`

Operates on the toolchain declared in `scripts/install/deps.json`.

| Verb | Effect |
|---|---|
| `deps status` | Read-only version and presence check; `--json` for scripts |
| `deps ensure` | Install MISSING deps through their per-OS recipe |
| `deps upgrade` | Bump present deps toward latest; qmd's model pull (about 2 GB) is gated behind a prompt or `--with-models` |

## `gaps`

Read-only. Diffs your saved install profile against a reference profile
(default `docs/setup/profiles/operator.install-profile.json`; pick another
with `--preset <name>`, which resolves to
`docs/setup/profiles/<name>.install-profile.json`). It prints four groups:

1. **Answered off/none** — your own choice, not a gap.
2. **Not recorded** — the profile predates the question; not a choice.
3. **Reference-only** — no wizard question can produce it yet (each carries its ticket).
4. **Present but unverified** — recorded, but `gaps` is a static diff, not a
   live probe; run `himmelctl status` to confirm it is still wired.

It is a report, not a gate: it exits 0 whenever the report was produced, even
when gaps exist.

## `trust`

`trust on|off|status` wires, unwires, or reports the trust shadow ledger's
hook entries in this project's `.claude/settings.json`. It is idempotent and
`off` removes only what `on` added, so adding and removing it are both zero
behaviour change. The hooks take effect on the next matching event, with no
restart. `trust status` reports how many entries are wired (for example
`7/7`) and writes nothing. "Wired" is a different claim from "recording": to
confirm rows are actually landing, run `node scripts/trust/shadow-ledger.mjs
report` and check for non-zero rows and a PROVEN collection line.

## `--version`

`himmelctl --version` prints the himmel version, the `git describe` string and
the commit. `--version --all` adds one line per updatable component (himmel
checkout, plugins, Jira CLI, qmd, hermes, luna template, CLI-proxy pin,
node/npm/bun) with installed against available. It is read-only.

| Exit | Meaning |
|---|---|
| 0 | Everything current |
| 1 | At least one component is behind |
| 3 | Nothing is behind, but at least one is unknown |

## Install-time flags

| Flag | Applies to | Effect |
|---|---|---|
| `--scope <project\|user>` | `install` | Non-interactive install from the shipped adopter profile |
| `--default-scope <s>` | `install` | Default answer to the scope question (still confirmable) |
| `--from-profile <path>` | `install` | Run non-interactively from a saved install-profile file |
| `--contribute` | `install` | Layer the contributor dev setup on top |
| `--with-codex` / `--with-hermes` | `install` | Additionally select that lane (opt-in) |
| `--lanes <csv>` | `install` | v1 accepts only `none` |
| `--purge-state` | `uninstall` | Also remove operator state |
| `--prune` | `ensure` | Opt in to the disable phase |
| `--with-models` | `deps upgrade` | Pull qmd's embedding and rerank models |
| `--no-network` | `ensure` | Run only items whose manifest entry declares a no-network path (local file wiring); refuse the rest |
| `--allow-agent-session` | `ui` | Override the refusal to start the config UI inside a Claude session |
| `--deep` | `report` | Add the wiring rows to the config feed |
