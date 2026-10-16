# qmd (himmel fork)

`[yotamleo fork]` of `qmd@qmd` (upstream [tobi/qmd](https://github.com/tobi/qmd),
plugin manifest v0.1.0).

## Why this fork

Claude Code eagerly spawns every enabled plugin's MCP server at session start
(no native lazy spawn). Upstream qmd declares a **stdio** server
(`{"command": "qmd", "args": ["mcp"]}`), so **every** session spawns its own
`qmd mcp` process and loads the same read-only search index into RAM again —
the largest per-session MCP footprint on this machine (HIMMEL-592).

## The change

Two deltas vs upstream. The main one: the `qmd` MCP server is declared as a
shared **HTTP** endpoint instead of a per-session stdio process
(`marketplace/plugins/qmd/.mcp.json`):

```json
{ "mcpServers": { "qmd": { "type": "http", "url": "http://localhost:8181/mcp" } } }
```

All sessions now address ONE `qmd mcp --http --daemon` on `localhost:8181`.
The daemon requires `Authorization: Bearer <token>` (HIMMEL-5002; 401 without
it, `/health` stays open). The token is a 0600 file the daemon generates on
first start (`$QMD_HTTP_TOKEN_FILE`, else `~/.config/qmd/http-token`; Claude Code strips `*TOKEN*` env vars from the headers helper, so a custom path also needs `QMD_HTTP_AUTH_FILE` set to the same file). The
plugin's `.mcp.json` sends it through `headersHelper`
(`scripts/qmd-auth-headers.sh`), and `ensure-qmd-daemon.sh` probes with it, so
the secret is never in the repo or on a command line. Restart the daemon once
after the fork pin moves (`qmd mcp stop`, then the next session start).
The daemon is brought up lazily by the plugin's own SessionStart hook
(`hooks/hooks.json` -> `${CLAUDE_PLUGIN_ROOT}/scripts/ensure-qmd-daemon.sh`),
so the startup path ships INSIDE the plugin and works from ANY session in ANY
repo where the plugin is enabled — not just himmel checkouts. The ensure
script is idempotent (alive-probe short-circuits), bounds the daemon start
with `timeout(1)` so a hung start cannot stall SessionStart, and fails loudly
on a foreign listener holding port 8181. A manual PowerShell twin for
operators lives in the himmel repo at `scripts/qmd/ensure-qmd-daemon.ps1`.

The plugin **name stays `qmd`** and the server **name stays `qmd`**, so the
skill reference (`qmd:qmd`) and the MCP tool prefix
(`mcp__plugin_qmd_qmd__*`) are identical to upstream in NAME — the
intentional content deltas below are the skill's other fork deltas;
everything else in the skill tree is verbatim upstream.

The `skills/qmd/` skill is copied from upstream (the upstream `release`
skill, which is qmd-repo maintenance tooling, is not vendored) with two
content deltas:

- **One line changed:** the skill's `allowed-tools` gains
  `mcp__plugin_qmd_qmd__*` — upstream allows only `mcp__qmd__*`, which does
  not match the plugin-scoped tool prefix the plugin itself produces
  (pre-existing upstream mismatch; harmless there, fixed here since we own the
  copy).
- **One section added:** `What works here (himmel fork, measured)`, under
  `Collection Filtering` (HIMMEL-4184) — query guidance measured on himmel's
  own collections with `scripts/eval/qmd-quality/qmd-quality.sh`; re-run that
  eval before changing it.

## Freshness & lifecycle

The index is sqlite+WAL, read per query, so a shared daemon serves docs added
by `qmd update` immediately — no restart or watch needed. Stop the daemon with
`qmd mcp stop`. Blast radius: a shared-daemon crash affects all sessions' qmd,
acceptable for a read-only index (a connect failure is loud in `/mcp`, not a
silent empty index).

A hung **vector** query is the one failure that is not loud: on 2026-09-16 every
`vec` sub-query timed out while `lex` kept working, so an agent's semantic
sweep silently degraded to keyword-only (HIMMEL-3056). The MCP client only sees
a timeout, so himmel detects it instead: `bash scripts/himmel-doctor.sh`
check `C40-qmd-vec` probes the server with one bounded `vec` query and names
the reason (timed out / tool error / no vector index / foreign listener on
8181 / empty or dropped reply — a refused connection is an INFO skip, since qmd is
optional). `HIMMEL_DOCTOR_QMD_VEC_TIMEOUT` (seconds) must be a positive integer; `0`
or a non-number falls back to 30 with an INFO, because curl treats `-m 0` as "no
timeout". If a `vec` call times out, run that check — do not retry-loop the query, and
treat a lex-only result as incomplete coverage, not a miss.

The daemon's native memory grows over hours (6.8 GB RSS after ~4.5 h, with vec
queries timing out, HIMMEL-3062), so the SessionStart hook also bounds it. On the
healthy path it reads the daemon's RSS with ONE `ps` call (no network) and, over
`QMD_RSS_CEILING_MB` (default `4096`; `0` disables), recycles it: a DETACHED
child SIGTERMs the daemon, waits for it to exit, and starts a fresh one, so the
session that noticed is never held for the ~15 s unwind. A lock
(`~/.cache/qmd/recycle.lock`) lets exactly one of many concurrently starting
sessions recycle, and a stamp blocks another recycle for
`QMD_RECYCLE_COOLDOWN_MIN` minutes (default `30`). The recycler logs to
`~/.cache/qmd/recycle.log`. `himmel-doctor.sh` check `C45-qmd-daemon` reports the
daemon's RSS and uptime and WARNs over the same ceiling. The PowerShell twin does
not carry the ceiling yet (HIMMEL-3751).

## Remote embed models and the salus index (HIMMEL-5683)

qmd's `models:` block is per index, so a collection the egress matrix denies for
a remote provider (salus first) must live in its own index on local models.
`ensure-qmd-daemon.sh` honours `QMD_INDEX_NAME` (reads
`~/.config/qmd/<name>.yml`, starts `qmd --index <name> --port <QMD_MCP_URL port>
mcp --http --daemon`). When the index config or `QMD_*_MODEL` names an
`openai:` model it first runs `scripts/qmd/qmd-jina-gate.mjs`, which checks each
collection against the matrix (`scripts/qmd/qmd-collection-corpus.json`; unmapped
means denied), plus every active collection in the index database, and refuses
to start on a denial, a missing gate or no `node`.
Local-only configs skip the gate. The shipped `.mcp.json` keeps its single
`qmd` entry; a second `qmd-salus` entry (port 8182) is added by the runbook, not
shipped always-on. Design: `docs/internals/egress-matrix.md`.

### OpenRouter for the non-salus index (HIMMEL-5756)

The fork pin carries the `openai:` provider (yotamleo/qmd @ cecc32a9). The gate
maps `https://openrouter.ai/...` to provider `openrouter` and accepts only the
pinned models, `openai:qwen/qwen3-embedding-8b` (embed) and
`openai:cohere/rerank-4-fast` (rerank); any other model, a `generate` role, an
unrecognised host, a missing or unparseable base URL, or a `models.openai_api_key`
line is refused (the refusal never prints the key). A collection is also refused
by its path, not only its name: a path equal to, inside or containing a PHI root
(`phi-roots` / `egress-denylist` under `~/.config/claude-glm`, the path of a salus
collection in a sibling index config, or a `.salus` vault) cannot go remote, and a
collection with no `path:` cannot be checked.

```yaml
models:
  embed: openai:qwen/qwen3-embedding-8b
  rerank: openai:cohere/rerank-4-fast
  openai_base_url: https://openrouter.ai/api/v1
```

The provider key goes ONLY in the daemon's environment
(`QMD_OPENAI_API_KEY`, set in the shell that launches the daemon), never in
`index.yml`, a committed file or a leg's environment. The SessionStart hook
never forwards a session's `QMD_OPENAI_API_KEY`: for a remote config it reads
the key from `~/.himmel/state/qmd-daemon.env` (override: `QMD_DAEMON_ENV_FILE`;
a `QMD_OPENAI_API_KEY=...` line, mode 0600 or 0400, else the file is refused),
and it will not start a remote daemon without it. Salus keeps its own
local-only index (`QMD_INDEX_NAME=salus`, `salus.yml`, port 8182).

Keep generated and boilerplate paths out of a code collection with an
`ignore:` list in its `index.yml` entry (for example `graphify-out/**`,
`**/fixtures/**`, `marketplace/plugins/*/README*.md` on the `himmel`
collection); the next `qmd update` drops the matching documents. Measured on
12 fixed queries, this removed noise but did not change any top-5 hit.

Switching an existing index is copy-and-swap, never in place: the index must
never mix local and remote vectors (qmd checks no vector's model at query time).
`scripts/luna/qmd-embed-model.sh reembed|swap` builds the copy, holds the swap
lock across the rename and flips the config, but it only knows the `gemma` and
`qwen` local aliases today; remote support in it and the VM proof of the swap
are tracked on HIMMEL-5756.

## Turning the daemon off on purpose (HIMMEL-4494)

The SessionStart hook relaunches the daemon in every new session, so killing it
by hand does not stick. To keep it off (for example while gaming, since its
embed/expand/rerank models contend for the GPU):

```bash
bash marketplace/plugins/qmd/scripts/qmd-daemon-switch.sh off   # create the flag, stop the daemon
bash marketplace/plugins/qmd/scripts/qmd-daemon-switch.sh on    # remove the flag, run ensure-qmd-daemon.sh
```

While the flag file `~/.himmel/state/qmd-daemon.off` exists (override the path
with `QMD_DAEMON_OFF_FLAG`), or `QMD_DAEMON_DISABLED=1` is set in one shell,
`ensure-qmd-daemon.sh` prints one INFO line and exits 0 without probing or
launching. `himmel-doctor.sh` check `C40-qmd-vec` reads INFO "qmd off by
operator" in that state. The PowerShell twin (`scripts/qmd/ensure-qmd-daemon.ps1`)
does not carry the opt-out (Windows development is parked).

## Upstream watch

The standalone `qmd` CLI installs from a local clone of the carried fork
`yotamleo/qmd` until tobi/qmd#1029 is fixed upstream (pinned to an immutable commit SHA rather than a mutable branch — HIMMEL-911
— cloned + built with bun, then junctioned/symlinked onto the bun-global
`@tobilu/qmd` path — `scripts/lib/qmd-bin.sh`, HIMMEL-877), not
`bun add -g @tobilu/qmd` (that command EPERM-wedges on this project's
machines and bun blocks its postinstall script). The fork carries two
commits on top of `tobi/qmd` main that make the `bin/qmd` launcher forward
SIGINT/SIGTERM/SIGHUP to its bun child (HIMMEL-3956, upstream PR
tobi/qmd#1030). When that merges, HIMMEL-3982 pins back to `tobi/qmd` and
`qmd_install` re-points an existing clone's origin in place (HIMMEL-3045
dropped an earlier fork the same way). This
plugin's **manifest + skill** stay pinned separately and are low-churn.
Re-sync `skills/qmd/` from `tobi/qmd` if the upstream search skill changes
materially, keeping both skill deltas above; re-sync the CLI clone per
`docs/setup/new-machine.md`.
