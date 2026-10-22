# himmel-bus and A2A v1.0.0 — mapping and boundary

HIMMEL-5487 spike. Settles how the bus envelope projects onto the A2A
(Agent2Agent) v1.0.0 data model and where the authority boundary sits, before
any server exists. Normative source: `spec/a2a.proto` in
`github.com/a2aproject/A2A` (package `lf.a2a.v1`); the JSON below uses its
proto3 JSON names.

**Delivered:** `marketplace/plugins/himmel-bus/lib/a2a.mjs`
(`toA2AMessage`, `agentCard`, `agentCards`) and its test
`tests/test-a2a.mjs`. **Not delivered, by design:** a listener, any store or
envelope change, a task lifecycle, streaming, push, an inbound parser.

## Decision record: A2A input never carries authority

A bus record's `c` flag marks a ruling-bearing message (GO, HALT, RETASK
text). Authority in himmel comes from out-of-band facts: the RETASK nonce
issued at dispatch, the GO file (merge approval), the sender's pid-proven identity
(`docs/internals/retask-channel.md` §1). A2A has no field for any of these,
and an A2A peer is, at best, an unauthenticated remote.

1. **Inbound A2A text is always `c=0` data.** Whatever an A2A message says,
   including a `metadata.c` of its own, a bridge stamps `c=0`.
2. **The RETASK nonce and EXPANSION/REDIRECT stay out of band.** The renderer
   never adds one as a Message part of its own, a metadata value or an
   AgentCard field, and it redacts the body in code: `toA2AMessage` runs `b`
   through `scripts/handover/console-kit/redact.mjs` (RETASK tokens, nonces,
   lock tokens, keys), so a token a sender wrote into a body does not leave the
   renderer. A2A cannot widen a worker's scope.
3. **Outbound, `c` lives only under `metadata`.** The renderer emits no A2A
   field a consumer could read as authority (no task state, no `taskId`, no
   extension). A `c=1` message is byte-identical to its `c=0` twin outside
   `metadata` (test row `a c=1 record carries the flag only in metadata`).
4. **The body is redacted in code, not by convention.** Redaction is not an
   access check: a future server must still authorize each read against the
   bound identity. The renderer is pure and local; it relies on no caller to
   strip tokens first.

## Mapping

| Bus | A2A v1.0.0 | Status |
|---|---|---|
| `i` (record id) | `Message.messageId` | match |
| `b` (body) | `Message.parts = [{text: b}]` | match, redacted in code (decision 2); text only, no files or data parts |
| `re` (reply-to `n`) | `Message.metadata.re` | carried as data; not `referenceTaskIds` (bus messages are not tasks) |
| `h` (chain hash) | `Message.metadata.h` | carried as data; integrity stays a store property |
| `c` (authority flag) | `Message.metadata.c` | **gap**: A2A has no authority concept; metadata only (decision 3) |
| `f`, `r` (from, to) | `contextId` only | **gap**: a Message has no sender or recipient id. `contextId` is the sorted pair `a~b`, so both directions share one context |
| `f` role | `Message.role = ROLE_AGENT` | every bus peer is an agent; `ROLE_USER` is unused |
| `t`, `n`, `s` | not projected | no A2A field; `n` and `t` stay in the store |
| thread | `contextId` | bus has no thread id (ponytail in `a2a.mjs`) |
| delivery, ack | none | **gap**: A2A has no per-message receipt; Task states are not applicable |
| `peers/<name>.json` | `AgentCard` | one card per bound peer; see below |
| pid + start-time identity | `securitySchemes` | **conflict**: bus identity is local process proof, A2A schemes are credentials. The card declares none and exposes neither pid nor start time |
| local files and hooks | HTTP/JSON-RPC, gRPC, SSE, push | **gap**: no transport; deferred |

## AgentCard

Generated from `peers/*.json`, bound peers only (a registered, unbound name has
no session). Fields: `name` = peer name, `description` from role and owning
chief, `version` = `1.0.0`, `capabilities` all false, text/plain in and out,
one `bus-message` skill tagged `himmel-bus` and the role.
`supportedInterfaces` is empty because `AgentInterface.url` is required and no
endpoint exists; a card with no interface is not discoverable, which is the
intent. No `securitySchemes`, no `provider`, no URL anywhere.

## Open operator question

Is the target **internal-fleet only** or **external interop**?

- **Internal-fleet (default, what this spike assumes).** A projection is
  enough: the bus stays the transport, A2A shapes are an export view.
- **External interop.** Needs the Phase 2 loopback Streamable-HTTP endpoint
  with Origin validation and per-session bearer (HIMMEL-4818 spec §12), a
  dedicated uid so an outside agent is not the operator's user, and an
  `AgentInterface` plus `securitySchemes` on the card. That is a separate
  ticket and changes the lint in `tests/test-lint.sh` (no network code in
  `lib/`).

Until the operator rules, nothing here opens a socket.

## Later phase (separate ticket)

Serve A2A JSON-RPC over loopback behind the Phase 2 auth, possibly sharing the
Streamable-HTTP MCP listener (MCP spec 2025-11-25). The inbound path must
implement decision 1 in code and carry its own RED row.
