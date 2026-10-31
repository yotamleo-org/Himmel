# pstack@himmel

Ten opt-in skills vendored from [`cursor/plugins`](https://github.com/cursor/plugins)
`pstack/` at `4dd1d05818d19792e7cd6e818f1667f95f7e1dbe` (0.15.36, MIT,
(c) 2026 Lauren Tan). Inventory and deviations: [`VENDORED.md`](VENDORED.md).
HIMMEL-6690 vendors the formal skills after HIMMEL-8218's accepted statechart pilot.

| Skill | Use |
|---|---|
| `/correct` | find the mistakes agents repeat in a repo and make each impossible |
| `/blast-radius` | find what a change could break outside the diff, proven by running code |
| `/create-verification-skill` | generate a project-local skill that drives the app like a user |
| `/maintain-verification-skill` | periodic pass keeping that skill and its feature map honest |
| `/benchmark-checklist` | vet a perf measurement before reporting it |
| `principle-explain-the-number` | find what limits a measured number before trusting it |
| `/in-your-own-words` | restate the user's goals |
| `/statechart` | check a TLA+ model and explain the shortest counterexample as a statechart |
| `/create-formal-verification-skill` | generate a bounded, code-grounded verification skill for a high-cost bug class |
| `/maintain-formal-verification-skill` | update verification after code changes and distinguish model drift from real defects |

Every skill is `disable-model-invocation: true`: no listing tokens, explicit
invocation only. The plugin ships no hooks, agents, commands or MCP servers.
Statechart includes its TypeScript runtime and upstream tests and fixtures. No
runtime npm dependencies are needed. The test-only dependency is `fast-check`
4.5.3; vendoring does not install it. Merging, GO and RETASK stay with the chief.

## Statechart prerequisites and limits

Java and TLC are **optional**: the other skills need neither. Run statechart
only on a test VM, with a small model in a scratch folder outside the repo.
Use Node 22.18–22.x or 23.6+, Bun 1.1.5+, or Deno 2+.
Provision Java 11+ and `tla2tools.jar` 1.7.4 on that VM, then set **absolute**
`JAVA` (executable) and `TLA2TOOLS` (jar) paths. Check the jar's SHA-256:

```text
936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
```

The runnable entry point is
`marketplace/plugins/pstack/skills/statechart/scripts/statechart`.
It returns 0 when the checked rules hold, 1 when a rule breaks, and 2 when a
prerequisite or check fails. The launcher returns 127 if no supported TypeScript
runtime is available; interruption returns 130 for SIGINT or 143 for SIGTERM.
Without absolute prerequisite paths it stops with
`Set TLA2TOOLS to an absolute path` or `Set JAVA to an absolute path`; an absent
file or a jar hash mismatch also stops it. The vendored runtime never installs
or downloads tools. A missing prerequisite is not a passing check.
Do not install Java, TLC, mise or the whole upstream pstack plugin on the station.

A defect is unconfirmed until its trace replays on the real code. An all-hold
result covers only the stated bounds and the code as written; a model that
closes a real race window does not establish that the code is safe. After the
first violation, upstream caps reruns at 100,000 states; read "Rules not checked"
before claiming all rules were checked. Above 500 states, the chart may contain
only counterexample paths, or be absent for a passing model.

Use the docs site's existing Pele 1.10.0 for rendering. Do not install the
upstream render reference's separate Pele version.

## Where it is on

On in the interactive `user` profile and the adopter `settings-template.json`.
Off in every worker, lane and chief profile: it is in the `catalog` of
`scripts/lanes/plugin-profiles.json` and in no `base`, `floor` or `enable` list
beyond `user`, so each lean profile resolves it to `false`. No profile changes
are part of this re-pin. A worker explicitly assigned a model-check may read the
vendored procedure without enabling the plugin.

The vendored [`docs/harness/claude-code.md`](docs/harness/claude-code.md) is an
upstream name-map reference, not permission to configure HOME or choose models.
Himmel's lane, chief and tool-schema rules take precedence. `setup-pstack` and
the agents mentioned in that reference are not shipped or installed.

## Remove it (one step)

```sh
claude plugin disable pstack@himmel
```

or, to delete it:

```sh
claude plugin uninstall pstack@himmel
```

Inside a session, `/profile disable pstack@himmel` does the same for the current
profile. Nothing else depends on it.

## Not vendored, on purpose

The subset stays in himmel; it does not track the `michael-denyer/pstack-claude`
fork or install all of `cursor-plugins`. `poteto-mode`, `setup-pstack`, `shipping`,
`autopilot-*`, `orchestrate`, `autonomous-run`, the other `principle-*` skills,
and all upstream hooks and agents remain excluded (HIMMEL-5802; audit U8 REJECT).
