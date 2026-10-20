// Service mode (`server.ts --service`): a token that survives restarts, no idle exit, and the board read from the
// JSON file the console writes beside its doc. Real server processes; the feed is the stub himmelctl.
import { test, expect, afterEach } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";

const SERVER = join(import.meta.dir, "..", "server.ts");
const STUB = join(import.meta.dir, "stub-himmelctl.js");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

function tmp() {
  const dir = mkdtempSync(join(tmpdir(), "agui-service-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

const spawnService = (home: string, extra: Record<string, string> = {}) =>
  Bun.spawn(["bun", SERVER, "--service", "--port", "0"], {
    env: { ...process.env, HOME: home, CONFIG_UI_HIMMELCTL: STUB, ...extra }, stdout: "pipe", stderr: "pipe",
  });

// The first stdout line of a child, however many chunks it arrives in.
async function readUrlLine(stream: ReadableStream<Uint8Array>, deadlineMs = 10_000) {
  const reader = stream.getReader();
  const dec = new TextDecoder();
  const end = Date.now() + deadlineMs;
  let buf = "";
  try {
    while (!buf.includes("\n")) {
      const left = end - Date.now();
      if (left <= 0) break;
      const r = await Promise.race([reader.read(), sleep(left).then(() => null)]);
      if (!r || r.done) break;
      buf += dec.decode(r.value, { stream: true });
    }
  } finally {
    reader.releaseLock();
  }
  return buf.split("\n")[0].trim();
}

async function launch(home: string, extra: Record<string, string> = {}) {
  const p = spawnService(home, extra);
  cleanups.push(() => p.kill());
  const url = await readUrlLine(p.stdout);
  const m = /^(http:\/\/127\.0\.0\.1:\d+)\/(?:agui\/)?#t=([0-9a-f]{64})$/.exec(url);
  expect(m).not.toBeNull();
  return { p, base: m![1], token: m![2] };
}

test("readUrlLine: a URL line split across stdout chunks is read whole", async () => {
  const line = `http://127.0.0.1:41873/agui/#t=${"0123456789abcdef".repeat(4)}\n`;
  const enc = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(c) {
      c.enqueue(enc.encode(line.slice(0, 20)));
      await sleep(20);
      c.enqueue(enc.encode(line.slice(20)));
    },
  });
  expect(await readUrlLine(stream)).toBe(line.trim());
});

test("service: two starts on one token file serve the same token, and the file is mode 600", async () => {
  const home = tmp();
  const a = await launch(home);
  a.p.kill(); await a.p.exited;
  const b = await launch(home);
  expect(b.token).toBe(a.token);
  const file = join(home, ".himmel", "state", "ui-token");
  expect(statSync(file).mode & 0o777).toBe(0o600);
  expect((await fetch(`${b.base}/api/feed`, { headers: { "X-Himmel-Token": a.token } })).status).toBe(200);
  expect((await fetch(`${b.base}/api/feed`)).status).toBe(401);
});

test("service: a token file that is group-readable or a symlink is refused, and the server does not start", async () => {
  const home = tmp();
  const dir = join(home, ".himmel", "state");
  mkdirSync(dir, { recursive: true });
  const file = join(dir, "ui-token");
  writeFileSync(file, "a".repeat(64) + "\n");
  chmodSync(file, 0o644);
  const loose = spawnService(home);
  expect(await loose.exited).not.toBe(0);
  expect(await new Response(loose.stderr).text()).toMatch(/mode 600/);
  rmSync(file);
  writeFileSync(join(home, "real"), "b".repeat(64) + "\n", { mode: 0o600 });
  symlinkSync(join(home, "real"), file);
  const link = spawnService(home);
  expect(await link.exited).not.toBe(0);
  expect(await new Response(link.stderr).text()).toMatch(/symlink/);
});

test("service: the idle window never shuts the server down", async () => {
  const { p } = await launch(tmp(), { CONFIG_UI_IDLE_MS: "300" });
  expect(await Promise.race([p.exited, sleep(1200).then(() => "alive")])).toBe("alive");
});

const CONSOLE = "HIMMEL-nextleg-2026-10-16BF-roadmap-console";
test("board: the JSON beside the console doc is served, and a rewrite reaches the next GET without a board.mjs run", async () => {
  const dir = tmp();
  const handovers = join(dir, "handovers");
  const bucket = join(handovers, "op", "himmel");
  mkdirSync(bucket, { recursive: true });
  writeFileSync(join(bucket, `${CONSOLE}.md`), "# console\n");
  const runs = join(dir, "runs");
  const script = join(dir, "board.mjs");
  writeFileSync(script, `import { appendFileSync } from "node:fs"; appendFileSync(${JSON.stringify(runs)}, "x"); process.exit(1);\n`);
  const token = "t".repeat(64);
  const s = startServer({ port: 0, token, boardScript: script, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HANDOVER_DIR: handovers, HOME: dir } });
  cleanups.push(() => s.stop());
  const get = () => fetch(`http://127.0.0.1:${s.port}/api/agui/board?console=${CONSOLE}`, { headers: { "X-Himmel-Token": token } });
  const file = join(bucket, `${CONSOLE}.board.json`);
  writeFileSync(file, JSON.stringify({ schema: "himmel.board/1", console: { name: "one" }, note: "RETASK BF-N2392-ff831841" }));
  const first = await get();
  expect(first.status).toBe(200);
  const one = await first.json();
  expect(one.console.name).toBe("one");
  expect(JSON.stringify(one)).not.toContain("BF-N2392-ff831841"); // the redaction still runs on the file's content
  writeFileSync(file, JSON.stringify({ schema: "himmel.board/1", console: { name: "two" } }));
  expect((await (await get()).json()).console.name).toBe("two");
  expect(await Bun.file(runs).exists()).toBe(false);
});
