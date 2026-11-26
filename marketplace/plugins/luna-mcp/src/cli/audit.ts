#!/usr/bin/env node
import { realpathSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { defaultAuditFile, type AuditEntry } from "../audit.js";

export interface AuditIo {
  env: NodeJS.ProcessEnv;
  stdout: (text: string) => void;
  stderr: (text: string) => void;
}

const USAGE = "usage: luna-mcp-audit [--file <path>] [--tail <n>] [--verdict allow|deny] [--principal <name>] [--tool <name>] [--json]";

function format(e: AuditEntry): string {
  const where = [e.collection ?? "-", e.path ?? "-"].join(" ");
  return `${e.ts} ${e.verdict} ${e.tool} ${e.principal ?? "-"} ${where}${e.reason ? ` (${e.reason})` : ""}\n`;
}

export async function runAudit(argv: string[], io: AuditIo): Promise<number> {
  let values;
  try {
    ({ values } = parseArgs({
      args: argv,
      strict: true,
      options: {
        file: { type: "string" },
        tail: { type: "string" },
        verdict: { type: "string" },
        principal: { type: "string" },
        tool: { type: "string" },
        json: { type: "boolean" },
      },
    }));
  } catch (e) {
    io.stderr(`luna-mcp-audit: ${e instanceof Error ? e.message : "bad arguments"}\n${USAGE}\n`);
    return 2;
  }
  if (values.tail !== undefined && !/^\d{1,6}$/.test(values.tail)) {
    io.stderr(`luna-mcp-audit: --tail needs a number\n${USAGE}\n`);
    return 2;
  }
  if (values.verdict !== undefined && values.verdict !== "allow" && values.verdict !== "deny") {
    io.stderr(`luna-mcp-audit: --verdict must be allow or deny\n${USAGE}\n`);
    return 2;
  }
  const file = values.file ?? io.env["LUNA_MCP_AUDIT_FILE"] ?? defaultAuditFile(io.env);
  let text: string;
  try {
    text = await readFile(file, "utf8");
  } catch {
    io.stderr("luna-mcp-audit: cannot read the audit log\n");
    return 1;
  }
  const rows: { entry: AuditEntry; line: string }[] = [];
  let skipped = 0;
  for (const line of text.split("\n")) {
    if (line === "") continue;
    try {
      const entry = JSON.parse(line) as AuditEntry;
      if (!entry || typeof entry !== "object" || typeof entry.tool !== "string") throw new Error("shape");
      rows.push({ entry, line });
    } catch {
      skipped++;
    }
  }
  let shown = rows.filter(
    (r) =>
      (values.verdict === undefined || r.entry.verdict === values.verdict) &&
      (values.principal === undefined || r.entry.principal === values.principal) &&
      (values.tool === undefined || r.entry.tool === values.tool),
  );
  if (values.tail !== undefined) shown = shown.slice(Math.max(0, shown.length - Number(values.tail)));
  for (const r of shown) io.stdout(values.json ? `${r.line}\n` : format(r.entry));
  if (skipped > 0) io.stderr(`luna-mcp-audit: skipped ${skipped} unreadable line(s)\n`);
  return 0;
}

function isMain(): boolean {
  try {
    return Boolean(process.argv[1]) && realpathSync(process.argv[1] as string) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isMain()) {
  void runAudit(process.argv.slice(2), {
    env: process.env,
    stdout: (s) => void process.stdout.write(s),
    stderr: (s) => void process.stderr.write(s),
  }).then((code) => {
    process.exitCode = code;
  });
}
