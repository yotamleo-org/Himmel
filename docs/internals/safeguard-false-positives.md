# Safeguard false-positive mitigations

Lean-invoke reference: three named mitigations, from Anthropic's Fable 5.1
prompting guide's "Reduce safeguard false positives" section, audited against
himmel in
`handovers/yotamleo/himmel/specs/eval/HIMMEL-fable51-prompting-audit-2026-09-05.md`.
The auto-memory topic file `claude-invocation-traps.md`
(`~/.claude/projects/<project>/memory/`) records refusal *symptoms*
(content-filter 400, Fable refusal drops `[1m]`) — these are the three
specific triggers/mitigations, not covered there.

## The three triggers

- **Phrase code-quality asks as "are there bugs" not "does this compile."**
  A compile/syntax framing reads closer to an adversarial probe than a
  correctness question and raises false-positive refusal risk on legitimate
  review requests.
- **Give context for lesser-known languages.** A safeguard is more likely to
  misread unfamiliar syntax as suspicious; naming the language and its
  purpose up front reduces that risk.
- **Keep base64 out of `tool_result` content reaching a Claude lane.**
  Relevant to any dispatcher piping binary/encoded payloads to a Claude lane
  (image tools, hermes payloads) — base64 blobs in tool output are a known
  content-filter trigger (see the `claude-invocation-traps.md` auto-memory
  topic file's "content-filter 400" entry).

## Fable 5.2 refusal categories

On Fable 5.2 a declined request returns `stop_reason: "refusal"`, and
`stop_details.category` names one of five categories
([Prompting Claude Fable 5.2](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-2#safeguard-refusals)):

- `cyber`: the request could enable cyber harm, such as malware or exploit
  development.
- `bio`: the request could enable biological harm, such as dangerous lab
  methods.
- `frontier_llm`: the request could help develop competing AI models.
- `reasoning_extraction`: the request asks the model to reproduce its
  internal reasoning in the reply text.
- `general_harms`: another usage-policy area.

Benign security and life-science work can also trip `cyber` and `bio`, and
himmel's guard, hook and secret-scan work is security work. The three triggers
above come from the Fable 5.1 guide. The Fable 5.2 guide does not repeat them
and does not withdraw them, so they stay.

The guide asks for one prompt change: remove any instruction in a prompt,
skill or tool description that asks the model to write its reasoning in the
reply. No himmel prompt does. The judge agents write what they checked, why,
and what is out of scope to an evidence file; that is a record of checks, not
the model's internal reasoning. To read the reasoning itself, use thinking
blocks with `display: "summarized"`.

## Deliberately not adopted

Verbatim from the audit report's "What the guide recommends that would
CONFLICT with a himmel safety rail" section (listed for operator decision,
not resolved here — so nobody re-proposes them without reading why):

- **"Finish the whole task" autonomy block** ("the user is not watching...
  proceed without asking... stop only for destructive actions") is close to
  but broader than himmel's own Auto Mode framing, and broader than the
  `coordinator-halt-cannot-be-reasoned-away` incident memory, which exists
  precisely because a worker once talked itself out of honoring a stand-down
  as "not genuine user input." Adopting the guide's block verbatim, without
  keeping himmel's narrower carve-outs (destructive/hard-to-reverse actions,
  explicit halts from any source), could reintroduce that failure mode.
  The Fable 5.2 guide's version of the block keeps that line: it tells the
  model to leave a deliberate blocker alone, and it keeps confirmation for
  risky or destructive actions.
  [`afk-mode.md`](../handover/afk-mode.md#launch-preamble) § Launch preamble
  adopts it with one himmel sentence that names a halt, a hook or classifier
  refusal and a `GO` hold as deliberate blockers.
- **Formatting-in-chat's "lean toward less structure"** could conflict with
  himmel artifacts that require structured Markdown for machine/human
  parsing — automated review reports, gap tables, ledger-shaped output. Blanket-adopting
  the guide's under-formatting correction without scoping it to
  conversational replies (vs. deliverables) would degrade those.
- **RETASK channel's synchronous-dispatch assumption** vs. the guide's
  "subagent starts, returns later via async user message" pattern — not a
  hard conflict, but the two documents don't share a threat model; adopting
  the guide's async pattern more heavily without re-examining
  `retask-channel.md` §1's threat model leaves an unreviewed edge.
