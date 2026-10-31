# humanizer@himmel

One opt-in skill vendored from [`blader/humanizer`](https://github.com/blader/humanizer)
at `0ef9fe5bc3572734fd3ae6c448fe00a30cd5dcf0` (MIT, (c) 2025 Siqi Chen).
Inventory and deviation: [`VENDORED.md`](VENDORED.md). Eval:
`docs/tool-adoption/humanizer.md`.

| Skill | Use |
|---|---|
| `/humanizer` | rewrite AI-sounding prose so it reads like the writer, keeping every claim |

`disable-model-invocation: true`, so it costs no listing tokens and runs only
when you type it. The plugin ships no hooks, agents, commands, MCP servers or
scripts, and grants no autonomy.

## Where it is on

Nowhere by default. It is in no profile in `scripts/lanes/plugin-profiles.json`,
so no worker, lane, chief or interactive profile enables it. The adopter
settings template lists it as on-demand: installed, disabled. Enable it by hand:

```
/profile enable humanizer@himmel
```

## Remove it (one step)

```
claude plugin disable humanizer@himmel
```

or, to delete it:

```
claude plugin uninstall humanizer@himmel
```
