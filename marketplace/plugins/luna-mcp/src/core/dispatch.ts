import type { Audit, AuditInput } from "../audit.js";
import type { Principal } from "../auth.js";
import { PURPOSE } from "../egress.js";
import { findOperation, OpError, type Access, type OpDeps } from "./operations.js";

export interface DispatchDeps extends OpDeps {
  audit: Audit;
}

export interface DispatchResult {
  status: number;
  body: { ok: true; result: unknown } | { ok: false; error: { code: string; message: string; issues?: { path: string; message: string }[] } };
}

const SAFE_TOOL = /^[a-z_]{1,32}$/;

export const fail = (status: number, code: string, message: string, issues?: { path: string; message: string }[]): DispatchResult => ({
  status,
  body: { ok: false, error: { code, message, ...(issues ? { issues } : {}) } },
});

export async function dispatch(
  deps: DispatchDeps,
  principal: Principal,
  opName: string,
  rawArgs: unknown,
  reqId: string,
  signal?: AbortSignal,
): Promise<DispatchResult> {
  const entry = (tool: string, access: Partial<Access>, verdict: "allow" | "deny", reason: string | null): AuditInput => ({
    reqId,
    principal: principal.principal,
    keyId: principal.keyId,
    role: principal.roles.join(","),
    collection: access.collection ?? null,
    corpus: access.corpus ?? null,
    provider: principal.provider,
    purpose: PURPOSE,
    path: access.path ?? null,
    tool,
    verdict,
    reason,
  });
  const denied = async (tool: string, status: number, code: string, message: string, access: Partial<Access>, reason: string, issues?: { path: string; message: string }[]): Promise<DispatchResult> => {
    try {
      await deps.audit.write(entry(tool, access, "deny", reason));
    } catch {
      process.stderr.write("luna-mcp: audit write failed for a denied call\n");
    }
    return fail(status, code, message, issues);
  };

  const op = findOperation(opName);
  if (!op) return denied(SAFE_TOOL.test(opName) ? opName : "invalid", 404, "unknown_operation", "unknown operation", {}, "unknown-operation");
  if (!principal.roles.includes("reader")) return denied(op.name, 403, "role_required", "the reader role is required", {}, "role-required");
  const parsed = op.input.safeParse(rawArgs ?? {});
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i) => ({ path: i.path.join("."), message: i.message }));
    return denied(op.name, 400, "invalid_arguments", "arguments rejected", {}, "invalid-arguments", issues);
  }
  let outcome;
  try {
    outcome = await op.run(deps, principal, parsed.data, signal);
  } catch (e) {
    if (e instanceof OpError) return denied(op.name, e.status, e.code, e.message, e.access, e.access.reason ?? e.code);
    process.stderr.write(`luna-mcp: ${op.name} failed: ${e instanceof Error ? e.name : "error"}\n`);
    return denied(op.name, 500, "internal_error", "internal error", {}, "internal");
  }
  try {
    for (const access of outcome.accesses) {
      await deps.audit.write(entry(op.name, access, access.verdict, access.reason));
    }
  } catch {
    process.stderr.write("luna-mcp: audit write failed, result withheld\n");
    return fail(503, "audit_unavailable", "the audit log is unavailable");
  }
  return { status: 200, body: { ok: true, result: outcome.data } };
}
