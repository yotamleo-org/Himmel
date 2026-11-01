import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { GROUP_ANONYMOUS_BOT_ID, isAllowed, type Access } from "./gate";
import { BASH_BIN } from "./run";

// Operator `/config backups` and `/config restore <id> <code>` -> config-restore.py.
// The helper checks the TOTP code (approval_broker, the AFK sudo rules) and runs scripts/lib/config-audit.sh restore, which backs up the live set
// first and writes an audit row. This route only decides whether a line may reach it.
//
// Every /config backups|restore line is CONSUMED, eligible or not, enrolled or not,
// so a code never lands in a session inbox or a run prompt. Only a whole typed (not
// forwarded, not a caption) message from the allowFrom operator in their own private
// chat reaches the helper. The code goes on stdin, never argv. Replies carry the
// helper's first lines: backup ids and key names, never a value.

const HERE = import.meta.dir;
export const CONFIG_RESTORE_HELPER = join(HERE, "config-restore.py");
const CONFIG_AUDIT = join(HERE, "..", "lib", "config-audit.sh");
const LINE = /^\s*\/config(?:@\w+)?\s+(backups|restore)\b(.*)$/is;
const BACKUP_ID = /^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$/;
const MAX_REPLY_LINES = 12;

export type ConfigLine = { verb: "backups" } | { verb: "restore"; id: string; code: string };
export type ConfigRestoreMsg = { from: number; chat_id: number; text: string; forwarded?: boolean; caption?: boolean };
export type ConfigHelperRun = (args: string[], stdin: string) => Promise<{ code: number; stdout: string }>;
export type ConfigRestoreDeps = {
  access: () => Access;
  enrolled: () => boolean;
  run: ConfigHelperRun;
  reply: (chat_id: number, text: string) => Promise<void>;
  log: (line: string) => void;
};

export function parseConfigLine(text: string): ConfigLine | null {
  const m = LINE.exec(text);
  if (!m) return null;
  if (m[1].toLowerCase() === "backups") return { verb: "backups" };
  const [id = "", ...rest] = m[2].trim().split(/\s+/);
  // The id is <stamp>Z-<hex>: an uppercase stamp, a lowercase suffix, whatever was typed.
  // Anything after the id is the code; the helper refuses one that is not six digits.
  return { verb: "restore", id: id.slice(0, 16).toUpperCase() + id.slice(16).toLowerCase(), code: rest.join("") };
}

function eligible(access: Access, msg: ConfigRestoreMsg): boolean {
  return msg.forwarded === false && msg.caption === false
    && String(msg.from) !== String(GROUP_ANONYMOUS_BOT_ID)
    && msg.chat_id === msg.from && isAllowed(access, msg.from);
}

const firstLines = (s: string) => s.split("\n").map((l) => l.trimEnd()).filter(Boolean).slice(0, MAX_REPLY_LINES).join("\n");

// The gate poller.ts calls in handleInbound: true = consumed.
export function makeConfigRestoreGate(deps: ConfigRestoreDeps): (msg: ConfigRestoreMsg) => boolean {
  return (msg) => {
    const line = parseConfigLine(msg.text);
    if (!line) return false;
    if (!eligible(deps.access(), msg)) {
      deps.log(`[config-restore] /config ${line.verb} refused: not a typed message in the operator's private chat`);
      return true;
    }
    const say = (text: string) => void deps.reply(msg.chat_id, text).catch(() => deps.log("[config-restore] reply failed"));
    if (!deps.enrolled()) {
      say("⚠️ config restore is not enrolled: at the station, in a terminal, run python3 scripts/telegram/config-restore.py enroll");
      return true;
    }
    if (line.verb === "restore" && !BACKUP_ID.test(line.id)) {
      say("⚠️ usage: /config restore <backup id> <6-digit code>; /config backups lists the ids. Nothing ran");
      return true;
    }
    const args = line.verb === "backups" ? ["list"] : ["restore", line.id, "--from", String(msg.from), "--chat", String(msg.chat_id)];
    void deps.run(args, line.verb === "restore" ? `${line.code}\n` : "")
      .then((res) => {
        const body = firstLines(res.stdout) || `exit ${res.code}`;
        return deps.reply(msg.chat_id, `${res.code === 0 ? "✅" : "⚠️"} config ${line.verb}:\n${body}`);
      })
      .catch((e) => deps.log(`[config-restore] ${line.verb} failed: ${e}`));
    return true;
  };
}

const stationDir = () => process.env.HIMMEL_CONFIG_DIR || join(homedir(), ".himmel");
export const configRestoreEnrolled = (): boolean => existsSync(join(stationDir(), "secrets", "config-restore.seed"));

// Production helper call: the bridge's own process, the code on stdin.
export const spawnConfigRestore: ConfigHelperRun = async (args, stdin) => {
  const p = Bun.spawn(["python3", "-I", CONFIG_RESTORE_HELPER, ...args], { env: process.env, stdin: new Blob([stdin]), stdout: "pipe", stderr: "pipe" });
  const [stdout, code] = await Promise.all([new Response(p.stdout).text(), p.exited]);
  return { code, stdout };
};

// One watcher pass (the poller's 60 s timer): config-audit.sh watch alerts the chief
// inboxes and the operator DM itself. A failure is logged, never thrown.
export async function runConfigWatch(log: (line: string) => void, script = CONFIG_AUDIT): Promise<void> {
  try {
    const p = Bun.spawn([BASH_BIN, script, "watch"], { env: process.env, stdout: "ignore", stderr: "pipe" });
    const [err, code] = await Promise.all([new Response(p.stderr).text(), p.exited]);
    if (code !== 0) log(`[config-watch] config-audit watch exited ${code}: ${err.split("\n")[0] ?? ""}`);
  } catch (e) {
    log(`[config-watch] config-audit watch failed to start: ${e}`);
  }
}
