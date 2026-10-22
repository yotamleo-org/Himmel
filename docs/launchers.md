# Launchers and lanes

A **launcher** is a thin script that starts Claude Code against a different
inference backend. Each one exports the Anthropic-compatible endpoint and key
for the child `claude` only, seeds its own config directory so it never touches
your normal `~/.claude`, and fails closed on a missing key, an egress refusal
or a low balance. Launchers live in `scripts/`; the delegation registry that
decides which lane a task goes to is `scripts/lanes/lanes.json` (inspect it with
`/lanes`).

Egress is governed by one policy file, `scripts/guardrails/egress-matrix.json`.
No launcher has a `--force` bypass around it.

## Status at a glance

| Launcher | Backend | Status |
|---|---|---|
| `scripts/claude-codex` | Codex subscription through a local CLIProxyAPI proxy | Supported |
| `scripts/claude-openrouter` | OpenRouter, metered | Available, **not health-checked** |
| `scripts/claude-deepseek` | DeepSeek's Anthropic-compatible endpoint, metered | Available, **not health-checked** |
| `scripts/claude-glm` | Z.ai GLM | **Removed** from the supported set (see below) |

"Not health-checked" means the launcher is in the repo and works as described
below, but no scheduled canary currently proves it end to end. Treat a failure
as possible and check the provider before relying on it.

## Common exit codes

The launchers share a convention:

| Exit | Meaning |
|---|---|
| 2 | Missing API key, or `claude` / a required dependency not on `PATH` |
| 3 | Egress or PHI-guard refusal (also: `node` missing, so the matrix cannot be consulted) |
| 4 | Config-directory seed failed |
| 5 | Remaining credit or balance below the floor, or unknown (OpenRouter, DeepSeek) |

Every launcher is `bash` 3.2-safe. Keys come from the process environment
first, then the primary checkout's `.env`; never put them in `settings.json`.

## `claude-codex`

Runs Claude Code on the Codex subscription through a local CLIProxyAPI proxy
(default `http://127.0.0.1:8317`, override with `CODEX_PROXY_BASE_URL`).
Per-host bring-up: [setup/cli-proxy-lane.md](setup/cli-proxy-lane.md); full
reference: the `claude-codex` section of [tooling-catalog.md](tooling-catalog.md).

| Variable | Default | Effect |
|---|---|---|
| `CODEX_MODEL` | the proxy's current Codex model | Main model slug |
| `CODEX_HAIKU`, `CODEX_SUBAGENT_MODEL` | `CODEX_MODEL` | Small-model and subagent slugs |
| `CODEX_CONTEXT_WINDOW` | `272000` | Compaction window. Above about 272k input is billed at a higher rate; above about 372k exceeds the backend window and warns. `spawn-claudex --context-tier 272k\|353k\|900k` sets it per dispatch and always overrides an ambient value (unstated = 272k, the cheapest); `dispatch-codex-exec.sh` takes the same flag with the same rule, and `/lanes` shows the default and the enum on each of those lanes; the tier used is recorded as `context_tier` in the session `meta.json` |

## `claude-openrouter`

Runs Claude Code on OpenRouter's native Anthropic-compatible endpoint with a
1M-context Claude tier. Two gates the other launchers do not have:

1. **Egress matrix.** It refuses until you declare an explicit `openrouter`
   provider and cell in `scripts/guardrails/egress-matrix.json`. Reaching a
   Claude model through OpenRouter is not covered by the `anthropic` cell.
2. **Credit floor.** It checks the remaining OpenRouter balance and refuses
   (exit 5) below `OPENROUTER_MIN_CREDIT_USD` (default `3`) or when the balance
   is unknown. An unknown balance is reported loudly, never silently allowed.

Key: `OPENROUTER_API_KEY`.

## `claude-deepseek`

Runs Claude Code against DeepSeek's Anthropic-compatible endpoint
(`https://api.deepseek.com/anthropic`).

| Item | Detail |
|---|---|
| Key | `DEEPSEEK_API_KEY` (shell env, else the primary `.env`) |
| Station opt-in | `HIMMEL_DEEPSEEK_INFERENCE_OK=1` in the **process environment**; `.env` supplies only the key, never the opt-in |
| Egress | Checked against the matrix; a refusal exits 3, with no override |
| Balance floor | Refuses (exit 5) below `DEEPSEEK_MIN_BALANCE_USD` (default `3`) or when the balance cannot be read. Session cost is the balance delta from the start snapshot printed at launch |
| `--seed-only` | Seed the lane config directory and exit 0 before the balance probe and launch |
| `--reseed` | Rebuild the seeded config directory |

## `claude-glm` (removed)

The Z.ai GLM lane has been dropped and is **not supported**. The launcher and
its historical notes remain in the tree, but do not plan on it. The
`claude-glm` section of [tooling-catalog.md](tooling-catalog.md) describes the
retired design. Use
`claude-codex` or a native Claude subagent instead.

## Not a lane: `himmel-run`

`scripts/himmel-run` is a token-discipline runner for the `himmel-jira` and
`himmel-gh` plugin CLIs. It is not an inference backend and has no launcher
behaviour.

## See also

- [setup/codex.md](setup/codex.md): running himmel under `codex-cli` itself.
- [hermes-runbook.md](hermes-runbook.md): the hermes junior-tier model lane.
- [orchestration-patterns.md](orchestration-patterns.md): which work goes to which lane.
- [configuration.md](configuration.md): every knob and off-switch.
