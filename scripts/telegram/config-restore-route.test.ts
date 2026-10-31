import { afterAll, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { makeConfigRestoreGate, parseConfigLine, runConfigWatch, spawnConfigRestore, type ConfigRestoreDeps } from "./config-restore-route";
import { GROUP_ANONYMOUS_BOT_ID } from "./gate";

const OP = 4242;
const access = { allowFrom: [String(OP)] };
const BID = "20261031T120000Z-ab12";

function fake(enrolled = true) {
  const calls: { args: string[]; stdin: string }[] = [];
  const replies: string[] = [];
  const logs: string[] = [];
  const deps: ConfigRestoreDeps = {
    access: () => access,
    enrolled: () => enrolled,
    run: async (args, stdin) => { calls.push({ args, stdin }); return { code: 0, stdout: `result=restored id=${BID}\n` }; },
    reply: async (_chat, text) => { replies.push(text); },
    log: (l) => { logs.push(l); },
  };
  return { deps, calls, replies, logs };
}
const dm = (text: string, extra: Record<string, unknown> = {}) => ({ from: OP, chat_id: OP, text, forwarded: false, caption: false, ...extra });
const settle = () => new Promise((r) => setTimeout(r, 5));

test("parse: backups, a restore with a spaced code, a bot-suffixed command, and lines that are not /config", () => {
  expect(parseConfigLine("/config backups")).toEqual({ verb: "backups" });
  expect(parseConfigLine(`/config restore ${BID} 123456`)).toEqual({ verb: "restore", id: BID, code: "123456" });
  expect(parseConfigLine(`/config@himmel_bot Restore ${BID.toUpperCase()} 123 456`)).toEqual({ verb: "restore", id: BID, code: "123456" });
  expect(parseConfigLine("please restore the config")).toBeNull();
  expect(parseConfigLine("/configure backups")).toBeNull();
});

test("an eligible restore reaches the helper with the code on stdin, never in argv", async () => {
  const { deps, calls, replies } = fake();
  expect(makeConfigRestoreGate(deps)(dm(`/config restore ${BID} 123456`))).toBe(true);
  await settle();
  expect(calls).toEqual([{ args: ["restore", BID, "--from", String(OP), "--chat", String(OP)], stdin: "123456\n" }]);
  expect(calls[0].args.join(" ")).not.toContain("123456");
  expect(replies[0]).toContain(`result=restored id=${BID}`);
});

test("/config backups runs list with no stdin", async () => {
  const { deps, calls } = fake();
  expect(makeConfigRestoreGate(deps)(dm("/config backups"))).toBe(true);
  await settle();
  expect(calls).toEqual([{ args: ["list"], stdin: "" }]);
});

test("a forwarded, captioned, group, anonymous-bot or non-operator line is consumed and never runs", async () => {
  for (const extra of [
    { forwarded: true },
    { caption: true },
    { chat_id: -100123 },
    { from: Number(GROUP_ANONYMOUS_BOT_ID), chat_id: Number(GROUP_ANONYMOUS_BOT_ID) },
    { from: 999, chat_id: 999 },
  ]) {
    const { deps, calls, replies, logs } = fake();
    expect(makeConfigRestoreGate(deps)(dm(`/config restore ${BID} 123456`, extra))).toBe(true);
    await settle();
    expect(calls).toEqual([]);
    expect(replies).toEqual([]);
    expect(logs.join("\n")).not.toContain("123456");
  }
});

test("not enrolled: consumed, the enroll hint, nothing runs", async () => {
  const { deps, calls, replies } = fake(false);
  expect(makeConfigRestoreGate(deps)(dm(`/config restore ${BID} 123456`))).toBe(true);
  await settle();
  expect(calls).toEqual([]);
  expect(replies[0]).toContain("config-restore.py enroll");
});

test("a malformed backup id: consumed, a usage reply, nothing runs", async () => {
  const { deps, calls, replies } = fake();
  expect(makeConfigRestoreGate(deps)(dm("/config restore ../../etc 123456"))).toBe(true);
  await settle();
  expect(calls).toEqual([]);
  expect(replies[0]).toContain("usage: /config restore");
});

test("a line that is not /config is not consumed", () => {
  const { deps, calls } = fake();
  expect(makeConfigRestoreGate(deps)(dm("restore the backup please"))).toBe(false);
  expect(calls).toEqual([]);
});

// End to end: the real helper and config-audit.sh in a fixture HOME and a fixture .env.
const REPO = join(import.meta.dir, "..", "..");
const T = mkdtempSync(join(tmpdir(), "config-restore-route-"));
afterAll(() => rmSync(T, { recursive: true, force: true }));

test("e2e: a wrong code restores nothing, the right code restores config.json, writes an audit row and replies with no value", async () => {
  const home = join(T, "home");
  mkdirSync(join(home, ".himmel"), { recursive: true });
  mkdirSync(join(T, "tg"));
  writeFileSync(join(T, "tg", "access.json"), JSON.stringify(access));
  writeFileSync(join(T, "env"), "");
  const T0 = 1800000000;
  const saved = { ...process.env };
  Object.assign(process.env, {
    HOME: home, HIMMEL_CONFIG_DIR: "", HIMMEL_CONFIG_AUDIT_ENV_FILE: join(T, "env"),
    TELEGRAM_ACCESS_PATH: join(T, "tg", "access.json"), HIMMEL_TEST_FIXTURE: "1", CONFIG_RESTORE_NOW: String(T0),
  });
  try {
    const sh = (cmd: string[]) => Bun.spawnSync(cmd, { env: process.env });
    expect(sh(["python3", "-I", join(REPO, "scripts/telegram/config-restore.py"), "enroll"]).exitCode).toBe(0);
    const cfg = join(home, ".himmel", "config.json");
    writeFileSync(cfg, JSON.stringify({ policy: { CR_FLOOR_FALLBACK: "planted-value-8401" } }));
    const ca = join(REPO, "scripts/lib/config-audit.sh");
    const bid = sh(["bash", ca, "pre", cfg, "--script", "test"]).stdout.toString().trim();
    expect(sh(["bash", ca, "post", bid, cfg, "write", "--script", "test"]).exitCode).toBe(0);
    unlinkSync(cfg);
    const seed = join(home, ".himmel", "secrets", "config-restore.seed");
    const codeAt = (t: number) => sh(["python3", "-I", "-c",
      "import sys; sys.path.insert(0, sys.argv[1]); import approval_broker as ab; print(ab.totp(open(sys.argv[2]).read().strip(), int(sys.argv[3]) // 30))",
      join(REPO, "scripts/lib/afk-sudo"), seed, String(t)]).stdout.toString().trim();
    const wrong = String((Number(codeAt(T0)) + 1) % 1000000).padStart(6, "0");

    const replies: string[] = [];
    const gate = makeConfigRestoreGate({ access: () => access, enrolled: () => existsSync(seed), run: spawnConfigRestore, reply: async (_c, t) => { replies.push(t); }, log: () => {} });
    const until = async (n: number) => { for (let i = 0; i < 200 && replies.length < n; i++) await new Promise((r) => setTimeout(r, 25)); };

    gate(dm(`/config restore ${bid} ${wrong}`));
    await until(1);
    expect(replies[0]).toContain("reason=wrong-code");
    expect(existsSync(cfg)).toBe(false);

    // A wrong try spends its time step (the approval_broker rule): the right code is the next step's.
    process.env.CONFIG_RESTORE_NOW = String(T0 + 60);
    gate(dm(`/config restore ${bid} ${codeAt(T0 + 60)}`));
    await until(2);
    expect(replies[1]).toContain(`result=restored id=${bid}`);
    expect(replies.join("\n")).not.toContain("planted-");
    expect(readFileSync(cfg, "utf8")).toContain("planted-value-8401");
    const audit = readFileSync(join(home, ".himmel", "state", "config-audit", "audit.jsonl"), "utf8");
    expect(audit).toContain('"script":"config-restore.py"');
    expect(audit).not.toContain("planted-");
  } finally {
    for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k];
    Object.assign(process.env, saved);
  }
}, 30_000);

test("runConfigWatch logs a non-zero exit and a missing script without throwing", async () => {
  const logs: string[] = [];
  const failing = join(T, "fail.sh");
  writeFileSync(failing, "echo boom-8401 >&2; exit 4\n");
  await runConfigWatch((l) => logs.push(l), failing);
  expect(logs[0]).toContain("exited 4");
  expect(logs[0]).toContain("boom-8401");
  await runConfigWatch((l) => logs.push(l), join(T, "absent.sh"));
  expect(logs.length).toBe(2);
});
