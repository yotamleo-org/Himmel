import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { bridgeRoot } from "./bus";
import { defaultAccessPath, loadAccess, operatorChatId } from "./gate";

const UPDATE_ID_FLOOR = 1_000_000;

export type Check = "floor" | "ambiguous" | "dm-policy" | "operator" | "forwarded" | "caption" | "text" | "metadata";

export type VerifiedLine = {
  update_id: number; from: number; chat_id: number; ts: number; message_id: number; text: string; reply_to_text?: string;
};

export type VerifyOptions = { root?: string; accessPath?: string; disable?: Check[] };

type LogRecord = Record<string, unknown>;

export class Refusal extends Error {}

const IDENTITY_FIELDS = ["text", "ts", "from", "chat_id", "forwarded", "caption", "message_id"] as const;
const identity = (r: LogRecord): string => JSON.stringify(IDENTITY_FIELDS.map((k) => r[k]));

async function recordsFor(root: string, updateId: number): Promise<LogRecord[]> {
  const found: LogRecord[] = [];
  for (const name of ["inbound.jsonl", "inbound.jsonl.1"]) {
    let body: string;
    try {
      body = await readFile(join(root, name), "utf8");
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "ENOENT") continue;
      throw new Refusal(`update ${updateId}: the poller's log cannot be read`);
    }
    for (const line of body.split("\n")) {
      if (!line.includes('"update_id"')) continue;
      let rec: unknown;
      try { rec = JSON.parse(line); } catch { continue; }
      if (rec !== null && typeof rec === "object" && (rec as LogRecord).update_id === updateId) found.push(rec as LogRecord);
    }
  }
  return found;
}

export async function verify(updateId: number, o: VerifyOptions = {}): Promise<VerifiedLine> {
  const off = new Set<Check>(o.disable ?? []);
  const refuse = (why: string): never => { throw new Refusal(why); };
  const id = String(updateId);

  if (!off.has("floor") && !(Number.isSafeInteger(updateId) && updateId >= UPDATE_ID_FLOOR)) refuse(`update ${id} is below the update-id floor`);

  const found = await recordsFor(o.root ?? bridgeRoot(), updateId);
  const first = found[0];
  if (first === undefined) return refuse(`update ${id} is not in the poller's log`);
  if (!off.has("ambiguous") && found.some((r) => identity(r) !== identity(first))) refuse(`update ${id} is ambiguous`);

  const access = await loadAccess(o.accessPath ?? defaultAccessPath());
  const operator = operatorChatId(access);
  const limited = access.dmPolicy === "allowlist" && Array.isArray(access.allowFrom) && access.allowFrom.length === 1 && operator !== null;
  if (!off.has("dm-policy") && !limited) refuse("the bridge's DMs are not limited to the operator");
  if (!off.has("operator") && (first.from !== operator || first.chat_id !== operator)) refuse(`update ${id} is not the operator's DM`);
  if (!off.has("forwarded") && first.forwarded !== false) refuse(`update ${id} is forwarded`);
  if (!off.has("caption") && first.caption !== false) refuse(`update ${id} is a caption or a voice transcript`);
  if (!off.has("text") && (typeof first.text !== "string" || first.text.trim() === "")) refuse(`update ${id} has no text`);
  if (!off.has("metadata") && !(Number.isFinite(first.ts) && Number.isSafeInteger(first.message_id))) refuse(`update ${id} has no timestamp or message id`);

  return {
    update_id: updateId, from: first.from as number, chat_id: first.chat_id as number, ts: first.ts as number,
    message_id: first.message_id as number, text: first.text as string,
    ...(typeof first.reply_to_text === "string" ? { reply_to_text: first.reply_to_text } : {}),
  };
}

if (import.meta.main) {
  const argv = process.argv.slice(2);
  const fail = (why: string): never => { process.stderr.write(`${why}\n`); process.exit(1); };
  if (argv.length !== 2 || argv[0] !== "--update" || !/^\d+$/.test(argv[1]!)) fail("usage: operator-words.ts --update <update_id>");
  try {
    process.stdout.write(`${JSON.stringify(await verify(Number(argv[1])))}\n`);
  } catch (e) {
    fail(e instanceof Refusal ? e.message : `operator-words failed: ${(e as Error).message}`);
  }
}
