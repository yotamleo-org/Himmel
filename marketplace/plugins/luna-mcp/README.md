# luna-mcp

A read-only MCP server and JSON API in front of the local QMD index. It lets an outside assistant
(Grokbot, Dots) search and read the indexed collections over private HTTPS with a scoped,
expiring, revocable key, and it logs every call. It is a standalone `systemd --user` service, not a
Claude plugin: it has no skills, commands or hooks, and it is not listed in the marketplace.

Stage 1 ships the `reader` role only. The role list, the role-path gate and the key schema already
carry the seams for writer, manager, admin and salus, but none of those exist yet and a key that
names one is refused.

## What it serves

| Route | Purpose |
|---|---|
| `GET /luna/health` | No key needed. Reports `{"status":"ok","qmd":"up"}` or `{"status":"degraded","qmd":"down"}`. |
| `POST /luna/mcp` | Streamable-HTTP MCP, built on `createMcpHandler` from `@modelcontextprotocol/server` (v2). |
| `POST /luna/v1/ops/<op>` | The same operations as plain JSON. |

Operations (one table feeds both surfaces):

| Operation | Alias | Notes |
|---|---|---|
| `list_collections` | | The key's own collections only. |
| `qmd_search` | `luna_search` | Typed `lex` / `vec` / `hyde` sub-queries, optional `collections`, `limit` up to 25. |
| `read_doc` | `luna_read_note` | `{collection?, path}`; returns content, sha256, size, mtime. 512 KiB cap. |
| `multi_read` | | Up to 10 entries, 1 MiB in total. Each entry succeeds or fails alone. |
| `list_dir` | | Paginated; follow `nextCursor`. |
| `recent_docs` | | Newest markdown notes, at most 50. |

## How a request is judged

1. Host and Origin must match `LUNA_MCP_PUBLIC_URL`. Anything else is a 403.
2. The bearer key is checked by `requireBearerAuth` with `expectedResource` set to
   `LUNA_MCP_PUBLIC_URL`. Keys are stored as SHA-256 hashes and compared in constant time. A key needs
   a finite `expiresAt`. The key file is re-read as soon as its size, inode or timestamps change, so a
   revocation applies on the very next call.
3. The requested collections are intersected with the key's `allowedCollections`. `salus` is never
   served, and an empty list is never sent to QMD (QMD would treat it as "search everything").
4. Egress: the collection must map to corpora in `scripts/qmd/qmd-collection-corpus.json`, and for
   every one of them `scripts/guardrails/egress-matrix.json` must hold a literal
   `(corpus, provider, luna-mcp-read)` row whose verdict is `allow+log`, and
   `egress-matrix-eval.mjs` must also answer `allow+log`. A wildcard row, an unmapped collection or an
   unreadable `HIMMEL_REPO` all refuse.
5. Path jail, shared by search, read, multi-read, list and recent: every segment is decoded and
   checked (no `%2f`, `%5c`, NUL or `..`, NFC only, no control or zero-width characters), no segment may
   start with a dot at any depth, and the vault's `scripts/`, `marketplace/`, `graphify-out/` and
   `to_be_deleted/` are closed. On a Luna collection `sessions/**` and `chats/**` need the `manager`
   role and `handovers/**` needs `manager` plus `allowHandoversRead`; a Stage 1 reader has neither.
6. Disk check: the file is opened with `O_NOFOLLOW`, its real path must stay inside the collection
   root, and its own YAML frontmatter is read. `repo: salus` means refused.
7. Search hits are never trusted as QMD sent them. Each `qmd://` URI is decoded per segment, run
   through the same jail and disk check, and the returned `title` and `snippet` are rebuilt from the
   verified file. QMD's `metadata` and `context` are not forwarded. Legacy slugs that no longer
   resolve to a file are dropped.
8. One audit line per call, allowed or denied.

A refusal caused by the shape of a path answers 403; anything that depends on what is on disk (a
missing file, a symlink, a salus note) answers the same 404, so the API does not confirm what exists.
QMD down answers 503 for search while reads keep working; the search timeout answers 504 and the
per-key search rate cap answers 429.

## Configuration

Everything comes from the environment. Nothing is hard-coded.

| Variable | Meaning | Default |
|---|---|---|
| `HIMMEL_REPO` | Checkout that holds the egress evaluator, matrix and corpus map. Required. | none |
| `LUNA_MCP_PUBLIC_URL` | The canonical public URL, an `https://` address ending in `/luna/mcp`. Required. | none |
| `QMD_CONFIG_FILE` | QMD `index.yml`, read for each collection's root. | `$XDG_CONFIG_HOME/qmd/index.yml` |
| `LUNA_MCP_COLLECTION_ROOTS` | Optional JSON file `{ "<collection>": "/absolute/root" }`; wins over `QMD_CONFIG_FILE`. | unset |
| `LUNA_MCP_KEYS_FILE` | The key file (mode 0600). | `$XDG_CONFIG_HOME/himmel/luna-mcp-keys.json` |
| `LUNA_MCP_AUDIT_FILE` | The audit log (mode 0600, rotated at 10 MiB, five files kept). | `$XDG_STATE_HOME/himmel/luna-mcp-audit.jsonl` |
| `QMD_URL` | The local QMD HTTP daemon. | `http://localhost:8181` |
| `QMD_HTTP_TOKEN_FILE` | The daemon's bearer token (mode 0600 or 0400). Never sent to a client. | `$XDG_CONFIG_HOME/qmd/http-token` |
| `LUNA_MCP_HOST` | Bind address; loopback only (`127.0.0.1`, `::1`, `localhost`). | `127.0.0.1` |
| `LUNA_MCP_PORT` | Bind port. | `8190` |
| `LUNA_MCP_SEARCH_RATE_PER_MIN` | Searches per key per minute. | `10` |
| `LUNA_MCP_SEARCH_TIMEOUT_MS` | QMD search timeout. | `15000` |

## Install

Build once, then run as a user service. The unit binds loopback only, mounts the home directory
read-only and leaves only the himmel state directory writable.

```bash
cd marketplace/plugins/luna-mcp
npm ci && npm run build

mkdir -p ~/.config/himmel ~/.local/state/himmel ~/.local/share/himmel
ln -sfn "$PWD" ~/.local/share/himmel/luna-mcp
cp systemd/luna-mcp.service ~/.config/systemd/user/luna-mcp.service
```

Create `~/.config/himmel/luna-mcp.env` (mode 0600) with the variables you need, for example:

```bash
HIMMEL_REPO=/path/to/your/himmel/checkout
LUNA_MCP_PUBLIC_URL=https://example-node.example-tailnet.ts.net/luna/mcp
```

The unit starts `/usr/bin/node`; point `ExecStart` at your node binary if it lives elsewhere. Then:

```bash
systemctl --user daemon-reload
systemctl --user enable --now luna-mcp.service
systemctl --user status luna-mcp.service
curl -sS http://127.0.0.1:8190/luna/health -H 'Host: example-node.example-tailnet.ts.net'
```

Expose it on the tailnet only (Funnel stays off):

```bash
tailscale serve --bg --set-path /luna http://127.0.0.1:8190/luna
tailscale funnel status
```

## Keys

`luna-mcp-keys` writes the key file (mode 0600, directory 0700). The plaintext key is printed once,
on `mint` and `rotate`, and is never stored; only its SHA-256 hash is.

```bash
npm run --silent keys -- mint --principal grokbot --provider xai-grokbot \
  --collections all --ttl 90d
npm run --silent keys -- mint --principal dots --provider openai-chatgpt \
  --collections luna-pa --ttl 90d
npm run --silent keys -- list
npm run --silent keys -- rotate <keyId> --ttl 90d --overlap 24h
npm run --silent keys -- revoke <keyId>
```

* `--collections all` expands to every collection in the QMD config except `salus`; a list such as
  `luna-pa` makes a Luna-only key. A name that is not in the QMD config is refused.
* `--resource` defaults to `LUNA_MCP_PUBLIC_URL`; the key only works on that URL.
* `--roles` defaults to `reader`, the only role Stage 1 supports.
* `rotate` mints a successor with the same scope and shortens the old key to `--overlap`, so both work
  until the old one expires. `revoke` takes effect on the next call.

Each record in the file has `keyId`, `hash`, `principal`, `egressProvider` (`xai-grokbot` or
`openai-chatgpt`), `resource`, `roles`, `allowedCollections`, `createdAt`, `expiresAt` and `revoked`.
A record that does not parse is ignored, so a bad row can never widen access. A key file that is
missing, unreadable, malformed or group or world readable makes every request fail with 500.

## Audit log

One JSON line per call, allowed or denied, with `ts`, `reqId`, `principal`, `keyId`, `role`,
`collection`, `corpus`, `provider`, `purpose`, `path`, `tool`, `verdict` and `reason`. It never holds a
key, a hash, a query or a document body. If a line cannot be written, the call is refused.

```bash
npm run --silent audit -- --tail 20
npm run --silent audit -- --verdict deny --principal grokbot
npm run --silent audit -- --tool read_doc --json
```

## Live smoke test (run on the station after install)

Use a real key from `mint`, and your own public URL in place of the placeholder.

```bash
BASE=https://example-node.example-tailnet.ts.net/luna
curl -sS "$BASE/health"

call() { curl -sS -X POST "$BASE/v1/ops/$1" -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' -d "$2"; echo; }

call list_collections '{}'
call qmd_search '{"searches":[{"type":"lex","query":"qmd"}],"collections":["luna","himmel","jira-himmel"]}'
call read_doc '{"collection":"luna","path":"CLAUDE.md"}'
call read_doc '{"collection":"luna","path":".obsidian/plugins/x"}'
call list_dir '{"collection":"luna","dir":"sessions"}'
```

Expect: the three collections searched, the document read, then `403` for the dotfile and for
`sessions`. With a Luna-only key, `read_doc` on `himmel` must answer `collection_forbidden`. Then run
`npm run --silent audit -- --tail 10` to see the lines, `revoke` the key and repeat a call to see `401`.
For the MCP surface, send a JSON-RPC `tools/list` to `$BASE/mcp` with the same bearer key and an
`Accept: application/json, text/event-stream` header.

## Development

```bash
npm ci
npm test          # builds, runs the behaviour suites, then the static suite
```

`tests/*.test.ts` run against a fake QMD server on an ephemeral port and temporary vaults, with an
injected clock for expiry, rotation and rate limits and an injected abort signal for the timeout.
`tests/test-luna-mcp.sh` pins the dependency policy (v2 SDK only, exact pins), the systemd hardening
lines and the no-hard-coded-paths rule. The live QMD daemon is never contacted.
