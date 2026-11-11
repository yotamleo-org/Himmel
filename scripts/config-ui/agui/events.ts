// events.ts — the AG-UI events the journal mapper emits.
//
// Plain object types, pinned by hand to the @ag-ui/core 1.0.2 schemas
// (dist/schemas.mjs, PROTOCOL_VERSION "1.0"): the type names, the required
// fields, and `timestamp` as an integer of epoch milliseconds. Only the
// subset the mapper produces is declared. No runtime import of @ag-ui/core:
// the mapper stays dependency-free, and tests/agui-schema.ts checks every
// emitted event against these same required fields.

export const AGUI_PROTOCOL_VERSION = "1.0";

type Base = { timestamp?: number; metadata?: Record<string, unknown> };

// Extra fields (the schemas are loose). `agent` rides every START event and names who acted:
// the session's own agent (id "main") or a subagent (its journal agentId). `failure` classifies what went
// wrong: a guardrail or permission refusal, a failing suite, a BLOCKED report, or any other error.
export type AgentRole = "console" | "worker" | "judge" | "critic" | "subagent" | "agent";
export type AgentInfo = {
  id: string; name: string; role: AgentRole;
  model?: string; kind?: string; // kind: a subagent's subagent_type
  parentToolCallId?: string; // the Agent call that spawned a subagent
};
export type Failure = "denied" | "suite" | "blocked" | "error";
// One per issued call, a closed partition. ok: ran and reported success; ok_blocked: succeeded while reporting
// BLOCKED; error: the tool reported an error (a suite failure included; not proof the program ran); denied: a
// known refusal; no_verdict: the auto-mode classifier gave no verdict, so the call never ran; interrupted: cut off,
// may have partly run; unknown: no result, or legacy data whose meaning is not established. A call with no result
// event has no outcome on the stream: whoever folds the stream finalizes it (interrupted on a cancelled turn, else
// unknown), never ok.
export type ToolOutcome = "ok" | "ok_blocked" | "error" | "denied" | "no_verdict" | "interrupted" | "unknown";
export const TOOL_OUTCOMES: readonly ToolOutcome[] = ["ok", "ok_blocked", "error", "denied", "no_verdict", "interrupted", "unknown"];

export type RunStartedEvent = Base & { type: "RUN_STARTED"; threadId: string; runId: string };
export type RunFinishedEvent = Base & {
  type: "RUN_FINISHED";
  threadId: string;
  runId: string;
  outcome?: { type: "success" } | { type: "cancelled" };
};
// RUN_ERROR carries no threadId/runId in the 1.0 schema; the run it ends is the open one.
export type RunErrorEvent = Base & { type: "RUN_ERROR"; message: string; code?: string };

export type TextMessageStartEvent = Base & {
  type: "TEXT_MESSAGE_START";
  messageId: string;
  role: "assistant" | "user";
  agent?: AgentInfo;
  failure?: "blocked" | "error"; // the text reports a BLOCKED status, or is a subagent's API error
};
export type TextMessageContentEvent = Base & { type: "TEXT_MESSAGE_CONTENT"; messageId: string; delta: string };
export type TextMessageEndEvent = Base & { type: "TEXT_MESSAGE_END"; messageId: string };

export type ToolCallStartEvent = Base & {
  type: "TOOL_CALL_START";
  toolCallId: string;
  toolCallName: string;
  parentMessageId?: string;
  apiMessageId?: string; // extra field (the schema is loose): the API message this call came from; calls sharing it were issued together
  agent?: AgentInfo;
};
export type ToolCallArgsEvent = Base & { type: "TOOL_CALL_ARGS"; toolCallId: string; delta: string };
export type ToolCallEndEvent = Base & { type: "TOOL_CALL_END"; toolCallId: string };
export type ToolCallResultEvent = Base & {
  type: "TOOL_CALL_RESULT";
  messageId: string;
  toolCallId: string;
  content: string;
  role: "tool";
  isError?: true; // extra field (the schema is loose): the raw is_error flag, a detail field only
  failure?: Failure; // detail of an error or denied outcome, and of a call that reports BLOCKED; never on no_verdict or interrupted
  outcome?: ToolOutcome; // the canonical result: consumers count this, never re-derive it from isError/failure
  subagent?: AgentInfo; // an Agent call's result: the subagent it ran, when only the result named it
};

// RFC 6902 operations; the mapper only ever adds.
export type JsonPatchOp = { op: "add" | "replace"; path: string; value: unknown };
export type StateSnapshotEvent = Base & { type: "STATE_SNAPSHOT"; snapshot: unknown };
export type StateDeltaEvent = Base & { type: "STATE_DELTA"; delta: JsonPatchOp[] };

export type AguiEvent =
  | RunStartedEvent
  | RunFinishedEvent
  | RunErrorEvent
  | TextMessageStartEvent
  | TextMessageContentEvent
  | TextMessageEndEvent
  | ToolCallStartEvent
  | ToolCallArgsEvent
  | ToolCallEndEvent
  | ToolCallResultEvent
  | StateSnapshotEvent
  | StateDeltaEvent;

export type AguiEventType = AguiEvent["type"];
