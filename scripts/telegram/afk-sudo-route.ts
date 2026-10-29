import { existsSync } from "node:fs";
import { GROUP_ANONYMOUS_BOT_ID, isAllowed, type Access } from "./gate";

// Operator `approve <id> <code>` / `deny <id>` -> the root afk-sudo helper.
// The helper (scripts/lib/afk-sudo/afk_sudo.py, installed
// root-owned by install.sh) checks the TOTP code and runs the one allowlisted
// command; this route only decides whether a line may reach it.
//
// Off by default: while the helper is not installed, nothing is consumed and the
// bridge behaves as before. Once installed, every afk-sudo-shaped line is
// CONSUMED, eligible or not, so a code never lands in a session inbox or a run
// prompt. Only a whole typed (not forwarded, not a caption or voice transcript)
// message from the global allowFrom operator in the operator's private chat
// reaches the helper. The code goes to the helper on stdin, never argv, so a
// same-uid process cannot read it from /proc/<pid>/cmdline. The helper runs up
// to its own timeout, so the call is fired, not awaited, like autoFire.

export const AFK_SUDO_HELPER = "/usr/local/libexec/himmel/afk-sudo";
const LINE = /^\s*(approve|deny)\s+([a-z2-7]{8})\b(.*)$/is;
// An approve with a malformed id but a code-shaped run of six digits.
const MALFORMED = /^\s*approve\s+\S+\s.*(?<!\d)\d{3}[ -]?\d{3}(?!\d)/is;

export type AfkSudoLine = { verb: "approve" | "deny"; id: string; code: string };
export type AfkSudoMsg = { from: number; chat_id: number; text: string; forwarded?: boolean; caption?: boolean };
export type HelperRun = (args: string[], stdin: string) => Promise<{ code: number; stdout: string }>;
export type AfkSudoDeps = {
  access: () => Access;
  installed: () => boolean;
  runHelper: HelperRun;
  reply: (chat_id: number, text: string) => Promise<void>;
  log: (line: string) => void;
};

export function parseAfkSudo(text: string): AfkSudoLine | null {
  const m = LINE.exec(text);
  if (!m) return null;
  // Anything after the id is the code; the helper refuses one that is not six digits.
  const rest = m[3].replace(/\s+/g, "");
  return { verb: m[1].toLowerCase() as "approve" | "deny", id: m[2].toLowerCase(), code: m[1].toLowerCase() === "approve" ? rest : "" };
}

function eligible(access: Access, msg: AfkSudoMsg): boolean {
  return msg.forwarded === false && msg.caption === false
    && String(msg.from) !== String(GROUP_ANONYMOUS_BOT_ID)
    && msg.chat_id === msg.from && isAllowed(access, msg.from);
}

// The gate poller.ts calls first in handleInbound: true = consumed.
export function makeAfkSudoGate(deps: AfkSudoDeps): (msg: AfkSudoMsg) => boolean {
  return (msg) => {
    if (!deps.installed()) return false;
    const line = parseAfkSudo(msg.text);
    if (!line) {
      if (!MALFORMED.test(msg.text)) return false;
      deps.log("[afk-sudo] approve with a malformed id consumed");
      if (eligible(deps.access(), msg)) {
        void deps.reply(msg.chat_id, "⚠️ afk-sudo: the id is not 8 letters, nothing ran").catch(() => {});
      }
      return true;
    }
    if (!eligible(deps.access(), msg)) {
      deps.log(`[afk-sudo] ${line.verb} ${line.id} refused: not a typed message in the operator's private chat`);
      return true;
    }
    const args = [line.verb, line.id, "--from", String(msg.from), "--chat", String(msg.chat_id)];
    void deps.runHelper(args, line.verb === "approve" ? `${line.code}\n` : "")
      .then((res) => {
        const first = res.stdout.split("\n")[0]?.trim() || `exit ${res.code}`;
        return deps.reply(msg.chat_id, `${res.code === 0 ? "✅" : "⚠️"} afk-sudo ${line.verb} ${line.id}: ${first}`);
      })
      .catch((e) => deps.log(`[afk-sudo] ${line.verb} ${line.id} failed: ${e}`));
    return true;
  };
}

// Production helper call: `sudo -n` to the installed copy, a minimal env.
export const spawnHelper: HelperRun = async (args, stdin) => {
  const p = Bun.spawn(["sudo", "-n", AFK_SUDO_HELPER, ...args], {
    stdin: new Blob([stdin]), stdout: "pipe", stderr: "pipe", env: { PATH: "/usr/bin:/bin" },
  });
  const [stdout, code] = await Promise.all([new Response(p.stdout).text(), p.exited]);
  return { code, stdout };
};

export const helperInstalled = (): boolean => existsSync(AFK_SUDO_HELPER);
