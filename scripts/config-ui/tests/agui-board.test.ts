// GET /api/agui/board (the himmel.board/1 JSON from board.mjs --json) and GET /api/agui/brief (a leg doc, read-only).
// board.mjs is replaced by a stub through the `boardScript` seam; the real one needs gh and Jira.
import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findDoc } from "../agui/board";
import { startServer } from "../server";

const TOKEN = "t".repeat(64);
const STUB = join(import.meta.dir, "stub-himmelctl.js");
const CONSOLE = "HIMMEL-nextleg-2026-10-16BE-roadmap-console";
const LEG = "HIMMEL-5968-N2368-agui-fleet-board-2026-10-16";
const NONCE = "BE-N2368-8eba92e8", LOCK = "cachyos-x8664-pid392282";
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

function boot() {
  const dir = mkdtempSync(join(tmpdir(), "agui-board-"));
  const handovers = join(dir, "handovers");
  const bucket = join(handovers, "op", "himmel");
  mkdirSync(bucket, { recursive: true });
  writeFileSync(join(bucket, `${CONSOLE}.md`), "# console\n");
  writeFileSync(join(bucket, `${LEG}.md`), `# leg\n- 10:00 LIVE — token ${NONCE} and lock ${LOCK}\n`);
  // the stub writes a board whose bullet still carries a nonce, to prove the route redacts on its own
  const script = join(dir, "board.mjs");
  writeFileSync(script, `import { writeFileSync } from "node:fs";
const a = process.argv.slice(2);
const at = (f) => a[a.indexOf(f) + 1];
writeFileSync(at("--json"), JSON.stringify({ schema: "himmel.board/1", console: { name: "seen:" + at("--doc").split("/").pop() },
  legs: [{ leg: "${LEG}", timeline: [{ text: "RETASK ${NONCE} lock ${LOCK}" }] }] }));
`);
  const s = startServer({ port: 0, token: TOKEN, boardScript: script, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HANDOVER_DIR: handovers, HOME: dir } });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  return s;
}
const get = (port: number, path: string, headers: Record<string, string> = { "X-Himmel-Token": TOKEN }, method = "GET") =>
  fetch(`http://127.0.0.1:${port}${path}`, { headers, method });

test("board: token-gated, read-only, console must be a known doc", async () => {
  const { port } = boot();
  expect((await get(port, `/api/agui/board?console=${CONSOLE}`, {})).status).toBe(401);
  expect((await get(port, `/api/agui/board?console=${CONSOLE}`, { "X-Himmel-Token": TOKEN }, "POST")).status).toBe(405);
  expect((await get(port, `/api/agui/board`)).status).toBe(400);
  expect((await get(port, `/api/agui/board?console=..%2F..%2Fetc%2Fpasswd`)).status).toBe(400);
  expect((await get(port, `/api/agui/board?console=HIMMEL-nope-console`)).status).toBe(404);
});

test("board: serves the model of the named console's doc, with no nonce and no lock token", async () => {
  const { port } = boot();
  const r = await get(port, `/api/agui/board?console=${CONSOLE}`);
  expect(r.status).toBe(200);
  const b = await r.json();
  expect(b.schema).toBe("himmel.board/1");
  expect(b.console.name).toBe(`seen:${CONSOLE}.md`);
  const text = JSON.stringify(b);
  expect(text).not.toContain(NONCE);
  expect(text).not.toContain(LOCK);
});

test("board: a build still running when the TTL has passed is shared, not started twice", async () => {
  const dir = mkdtempSync(join(tmpdir(), "agui-board-slow-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const runs = join(dir, "runs");
  const script = join(dir, "board.mjs");
  writeFileSync(script, `import { appendFileSync, writeFileSync } from "node:fs";
const a = process.argv.slice(2);
appendFileSync(${JSON.stringify(runs)}, "x");
await new Promise((r) => setTimeout(r, 300));
writeFileSync(a[a.indexOf("--json") + 1], "{}");
`);
  const { readBoard } = await import("../agui/board");
  const o = { script, doc: join(dir, "slow-doc.md"), checkout: dir, env: { PATH: process.env.PATH } };
  const first = readBoard({ ...o, now: 0, ttlMs: 50 });
  const second = readBoard({ ...o, now: 100, ttlMs: 50 }); // past the TTL, but the first build is still pending
  await Promise.all([first, second]);
  expect(Bun.file(runs).size).toBe(1);
});

test("board: a build that fails before it starts is not cached", async () => {
  const dir = mkdtempSync(join(tmpdir(), "agui-board-fail-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const { readBoard } = await import("../agui/board");
  const o = { script: join(dir, "board.mjs"), doc: join(dir, "fail-doc.md"), checkout: dir, ttlMs: 60_000 };
  const saved = process.env.TMPDIR;
  process.env.TMPDIR = join(dir, "no-such-dir"); // mkdtemp cannot create its dir
  try { expect("error" in (await readBoard({ ...o, env: { PATH: process.env.PATH }, now: 0 }))).toBe(true); }
  finally { if (saved === undefined) delete process.env.TMPDIR; else process.env.TMPDIR = saved; }
  writeFileSync(o.script, `import { writeFileSync } from "node:fs";\nconst a = process.argv.slice(2);\nwriteFileSync(a[a.indexOf("--json") + 1], "{}");\n`);
  expect("body" in (await readBoard({ ...o, env: { PATH: process.env.PATH }, now: 1 }))).toBe(true); // the next poll retries
});

test("brief: a leg doc, token-gated, read-only, redacted, names only", async () => {
  const { port } = boot();
  expect((await get(port, `/api/agui/brief?leg=${LEG}`, {})).status).toBe(401);
  expect((await get(port, `/api/agui/brief?leg=${LEG}`, { "X-Himmel-Token": TOKEN }, "POST")).status).toBe(405);
  expect((await get(port, `/api/agui/brief?leg=..%2F..%2Fetc%2Fpasswd`)).status).toBe(400);
  expect((await get(port, `/api/agui/brief?leg=HIMMEL-0-N1-none`)).status).toBe(404);
  const r = await get(port, `/api/agui/brief?leg=${LEG}`);
  expect(r.status).toBe(200);
  const t = await r.text();
  expect(t).toContain("LIVE");
  expect(t).not.toContain(NONCE);
  expect(t).not.toContain(LOCK);
});

test("findDoc: a doc symlinked outside the handover root is null; one that resolves inside the root is found", async () => {
  const dir = mkdtempSync(join(tmpdir(), "agui-finddoc-"));
  try {
    const root = join(dir, "root"), bucket = join(root, "u", "b");
    mkdirSync(bucket, { recursive: true });
    writeFileSync(join(dir, "secret.md"), "outside");
    writeFileSync(join(bucket, "real.md"), "inside");
    symlinkSync(join(dir, "secret.md"), join(bucket, "escape.md"));
    symlinkSync(join(bucket, "real.md"), join(bucket, "alias.md"));
    expect(await findDoc(root, "escape")).toBeNull();
    expect(await findDoc(root, "alias")).toBe(join(bucket, "alias.md"));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
