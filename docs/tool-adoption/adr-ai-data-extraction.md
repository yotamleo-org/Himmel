# ADR: sybil-solutions/ai-data-extraction (HIMMEL-4941)

**Decision: REJECT** (2026-10-11). Nothing is vendored and no parser is
borrowed. Method: [rubric](rubric.md), trust tier `source-read-mandatory`
(it reads transcripts that hold secrets and private paths).

No transcript content appears here, only field names, record-type names and
counts.

## Goal (rubric §1)

- **Problem:** `leg-digest`, the friction ledger (HIMMEL-4926) and the failure
  loop read only Claude Code journals. Claudex legs and codex consoles
  (HIMMEL-4940 role C) leave Codex rollouts we cannot measure.
- **Desired outcome:** Codex denial and turn counts as evidence for
  HIMMEL-4940, with no new egress.
- **KPI:** outcome per session. The tool must produce measurable Codex
  evidence, not just a uniform schema.

## What was run

- Upstream: <https://github.com/sybil-solutions/ai-data-extraction>, MIT,
  pinned at `9176c2dd81c8a101b52debd4cec88573284e2b30` (2026-10-07).
- Only `extract_codex.py` and `extract_claude_code.py` were considered.
  `filter_privacy.py` and `corpus_to_skills.py` were never run.
- Where: test VM `himmel-ar-3` (baseline snapshot `suite-ready-v4`), a throwaway
  `HOME`, `python3 -I`. Samples stayed on the VM.

## Findings

### 1. No network egress (source read + strace)

- Both extractors import only `json`, `sqlite3`, `pathlib`, `datetime`,
  `hashlib`, `platform`, `os`. No socket, HTTP or subprocess use.
- Control: a plain Python `socket.connect` under
  `strace -f -e trace=network` logged 2 network syscalls (socket, connect), so
  a zero result is not vacuous.
- `extract_codex.py` over the copied Codex sample under the same strace: rc 0,
  **0** network syscalls.
- **Not verified:** `extract_claude_code.py` was not executed on the VM (the
  Claude samples were not copied). Its no-network claim rests on the source
  read only.

### 2. The Codex parser is stale against current Codex rollouts

Across the 163 local rollouts, `(type, payload.type)` counts for the record
kinds that carry the evidence we want:

| Record | Count | Read by `extract_codex.py`? |
|---|---|---|
| `event_msg/item_completed` | 6123 | no |
| `event_msg/token_count` | 1840 | no |
| `token_usage_record` | 1814 | no |
| `response_item/custom_tool_call` + `_output` | 1588 each | no |
| `response_item/function_call` + `_output` | 91 each | no |
| `event_msg/turn_aborted` | 3 | no |
| `event_msg/user_message` | 1 | yes |
| `event_msg/agent_message` | 1 | yes |

The extractor accepts only `event_msg` payloads `user_message`,
`agent_message`, `tool_use`, `tool_result` and `diff`. Current Codex writes
messages as `response_item/message` and tool calls as `function_call` and
`custom_tool_call`. A session with no recognized message returns nothing:
**1 of 163 rollouts yields a conversation**, and that one has no tool
records. Denials, turn counts and token usage are all dropped.

### 3. Field comparison with leg-digest

- Upstream output per conversation: `messages` (role, content, timestamp,
  model on assistant), `session_id`, `cwd` / `project_path`, `source`,
  `source_file`, `installation`, plus raw `tool_uses` / `tool_results`.
  Content is verbatim.
- Not carried for Claude Code: `message.usage` (present on every assistant
  record in the two host-side samples) and `system` records; only `user`,
  `assistant` and `tool_result` record types are read. The extractor also
  looks for top-level `toolUse` / `toolResult` keys that current journals do
  not write (tool results arrive as content blocks of `user` records and are
  kept as raw content).
- `leg-digest` emits closed-vocabulary class keys, denial join, trajectory
  metrics and lane, and by design never emits transcript text (egress-matrix
  corpus `leg-failure-metadata`). Upstream's output is the opposite shape:
  full text, secrets and private paths, which would be a new
  `handover-state`-class corpus we would have to fence.

## Why REJECT, not borrow

- The one feature we wanted (Codex tool, denial and turn counts) is exactly
  what the Codex parser does not read. Borrowing it means rewriting it.
- A uniform schema of raw text does not feed a closed-vocabulary ledger; we
  would still write our own reducer on top.
- Adopting would add a vendored tree under the drift guard for a parser that
  already lags the format it targets.

## Re-open trigger

Upstream's Codex extractor reads `response_item` function and custom tool
records and `token_count`, or a Codex-rollout fixture of ours shows the
upstream output matching our counts.

## Suggested follow-up (not filed)

A small in-house Codex rollout reader that emits closed-vocabulary counts
(`function_call`, `custom_tool_call`, `turn_aborted`, `token_count` totals) in
`leg-digest`'s shape, as HIMMEL-4940 evidence. Roughly the size of the part
of `extract_codex.py` we would otherwise have to rewrite.
