# pstack@himmel

Seven opt-in skills vendored from [`cursor/plugins`](https://github.com/cursor/plugins)
`pstack/` at `99743e9c151c8537cbbf1f98bb38f34ef3368453` (MIT, (c) 2026 Lauren Tan).
Inventory and deviations: [`VENDORED.md`](VENDORED.md).

| Skill | Use |
|---|---|
| `/correct` | find the mistakes agents repeat in a repo and make each impossible |
| `/blast-radius` | find what a change could break outside the diff, proven by running code |
| `/create-verification-skill` | generate a project-local skill that drives the app like a user |
| `/maintain-verification-skill` | periodic pass keeping that skill and its feature map honest |
| `/benchmark-checklist` | vet a perf measurement before reporting it |
| `principle-explain-the-number` | find what limits a measured number before trusting it |
| `/in-your-own-words` | restate the user's goals |

Every skill is `disable-model-invocation: true`, so it costs no listing tokens
and runs only when you type it. The plugin ships no hooks, agents, commands, MCP
servers or scripts, and grants no autonomy: merging, GO and RETASK stay with the
console.

## Where it is on

On in the interactive `user` profile and the adopter `settings-template.json`.
Off in every leg, lane and console profile: it is in the `catalog` of
`scripts/lanes/plugin-profiles.json` and in no `base`, `floor` or `enable` list
beyond `user`, so each lean profile resolves it to `false`. Legs are not
disrupted.

## Remove it (one step)

```
claude plugin disable pstack@himmel
```

or, to delete it:

```
claude plugin uninstall pstack@himmel
```

Inside a session, `/profile disable pstack@himmel` does the same for the current
profile. Nothing else depends on it.

## Not vendored, on purpose

`poteto-mode`, `setup-pstack`, `shipping`, `autopilot-*`, `orchestrate`,
`autonomous-run`, the 24 other `principle-*` skills, and everything from the
`michael-denyer/pstack-claude` fork (SessionStart hook, ship scripts). Plan:
HIMMEL-5802.
