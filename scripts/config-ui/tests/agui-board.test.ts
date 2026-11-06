// GET /api/agui/board (the himmel.board/1 JSON from board.mjs --json) and GET /api/agui/brief (a worker doc, read-only).
// The route serves the board file board.mjs writes beside the chief doc; these rows write that file themselves (the real board.mjs needs gh and Jira).
import { test, expect, afterEach } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applySection } from "../../handover/chief-kit/board-section.mjs";
import { findDoc } from "../agui/board";
import { startServer } from "../server";
import { stubKeyring } from "./keyring-stub";

const TOKEN = "t".repeat(64);
const STUB = join(import.meta.dir, "stub-himmelctl.js");
const CHIEF = "HIMMEL-nextleg-2026-10-16BE-roadmap-chief";
const WORKER = "HIMMEL-5968-N2368-agui-fleet-board-2026-10-16";
const NONCE = "BE-N2368-8eba92e8", LOCK = "cachyos-x8664-pid392282";
const cleanups: (() => void)[] = [];
afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

function boot(readOnly = false) {
  const dir = mkdtempSync(join(tmpdir(), "agui-board-"));
  const handovers = join(dir, "handovers");
  const bucket = join(handovers, "op", "himmel");
  mkdirSync(bucket, { recursive: true });
  writeFileSync(join(bucket, `${CHIEF}.md`), "# console\n");
  writeFileSync(join(bucket, `${WORKER}.md`), `# worker\n- 10:00 LIVE — token ${NONCE} and lock ${LOCK}\n`);
  // the chief's board file, as board.mjs writes it beside the doc; its bullet still carries a nonce, to prove the route redacts on its own
  writeFileSync(join(bucket, `${CHIEF}.board.json`), JSON.stringify({ schema: "himmel.board/1", console: { name: CHIEF },
    workers: [{ worker: WORKER, timeline: [{ text: `RETASK ${NONCE} lock ${LOCK}` }] }] }));
  const s = startServer({ port: 0, token: TOKEN, readOnly, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HANDOVER_DIR: handovers, HOME: dir } });
  cleanups.push(() => { s.stop(); rmSync(dir, { recursive: true, force: true }); });
  return Object.assign(s, { bucket });
}
const get = (port: number, path: string, headers: Record<string, string> = { "X-Himmel-Token": TOKEN }, method = "GET") =>
  fetch(`http://127.0.0.1:${port}${path}`, { headers, method });

test("board: token-gated, read-only, console must be a known doc", async () => {
  const { port } = boot();
  expect((await get(port, `/api/agui/board?console=${CHIEF}`, {})).status).toBe(401);
  expect((await get(port, `/api/agui/board?console=${CHIEF}`, { "X-Himmel-Token": TOKEN }, "POST")).status).toBe(405);
  expect((await get(port, `/api/agui/board`)).status).toBe(400);
  expect((await get(port, `/api/agui/board?console=..%2F..%2Fetc%2Fpasswd`)).status).toBe(400);
  expect((await get(port, `/api/agui/board?console=HIMMEL-nope-chief`)).status).toBe(404);
});

test("board: serves the model of the named console's doc, with no nonce and no lock token", async () => {
  const { port } = boot();
  const r = await get(port, `/api/agui/board?console=${CHIEF}`);
  expect(r.status).toBe(200);
  const b = await r.json();
  expect(b.schema).toBe("himmel.board/1");
  expect(b.console.name).toBe(CHIEF);
  const text = JSON.stringify(b);
  expect(text).not.toContain(NONCE);
  expect(text).not.toContain(LOCK);
});

// A board string can carry a credential (a tail quoting a failure). The value has no token shape: only the literal list masks it.
test("board: a board file's text is masked with the keyring's secrets too", async () => {
  const dir = mkdtempSync(join(tmpdir(), "agui-board-kr-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const handovers = join(dir, "handovers");
  mkdirSync(join(handovers, "op", "himmel"), { recursive: true });
  writeFileSync(join(handovers, "op", "himmel", `${CHIEF}.md`), "# console\n");
  const kr = "kr-only-" + "q7x2".repeat(2);
  writeFileSync(join(handovers, "op", "himmel", `${CHIEF}.board.json`), JSON.stringify({ schema: "himmel.board/1", console: { name: CHIEF }, workers: [{ worker: WORKER, timeline: [{ text: `jira auth failed for ${kr}` }] }] }));
  const k = stubKeyring(dir);
  k.put("JIRA_API_TOKEN", kr);
  const s = startServer({ port: 0, token: TOKEN, env: { PATH: process.env.PATH, ...k.env, HIMMEL_SECRETS_KEYRING: "", JIRA_API_TOKEN: "", CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HANDOVER_DIR: handovers, HOME: dir } });
  cleanups.push(() => s.stop());
  const r = await get(s.port, `/api/agui/board?console=${CHIEF}`);
  expect(r.status).toBe(200);
  const text = await r.text();
  expect(text).toContain("jira auth failed");
  expect(text).not.toContain(kr);
});

test("brief: a worker doc, token-gated, read-only, redacted, names only", async () => {
  const { port } = boot();
  expect((await get(port, `/api/agui/brief?leg=${WORKER}`, {})).status).toBe(401);
  expect((await get(port, `/api/agui/brief?leg=${WORKER}`, { "X-Himmel-Token": TOKEN }, "POST")).status).toBe(405);
  expect((await get(port, `/api/agui/brief?leg=..%2F..%2Fetc%2Fpasswd`)).status).toBe(400);
  expect((await get(port, `/api/agui/brief?leg=HIMMEL-0-N1-none`)).status).toBe(404);
  const r = await get(port, `/api/agui/brief?leg=${WORKER}`);
  expect(r.status).toBe(200);
  const t = await r.text();
  expect(t).toContain("LIVE");
  expect(t).not.toContain(NONCE);
  expect(t).not.toContain(LOCK);
  const w = await get(port, `/api/agui/brief?worker=${WORKER}`);
  expect(w.status).toBe(200);
  expect(await w.text()).toBe(t);
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
    expect(await findDoc(root, "alias")).toBe(realpathSync(join(bucket, "real.md"))); // the validated target, not the symlink
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// ---- the chief's sections: the route reads the sidecar through board-section.mjs's readSections ----
// These rows never spell the sidecar's file name (only board-section.mjs and its tests may, I9): the command writes it, and sidecarOf finds it.
const chiefDoc = (bucket: string) => join(bucket, `${CHIEF}.md`);
const seed = (bucket: string, id = "next-up", body = "ship the route") => applySection(chiefDoc(bucket), { kind: "set", id, title: "Next up", body });
const sidecarOf = (bucket: string) => join(bucket, readdirSync(bucket).find((f) => f.startsWith(CHIEF) && f.includes(".sections") && !f.includes(".tmp"))!);
const board = async (port: number) => { const r = await get(port, `/api/agui/board?console=${CHIEF}`); return { r, b: await r.json() }; };

test("sections: a sidecar beside the doc comes back under sections, in the stored order", async () => {
  const { port, bucket } = boot();
  await seed(bucket, "b-second", "two");
  await applySection(chiefDoc(bucket), { kind: "set", id: "a-first", title: "First", body: "one", order: 1 });
  const { r, b } = await board(port);
  expect(r.status).toBe(200);
  expect(b.schema).toBe("himmel.board/1"); // the board itself is still served
  expect(b.sections.map((s: { id: string }) => s.id)).toEqual(["a-first", "b-second"]);
  expect(b.sections[0]).toMatchObject({ id: "a-first", title: "First", body: "one", tone: "info", order: 1 });
  expect(b.sections_error).toBeUndefined();
});

test("sections: no sidecar gives [] and no error; an unparseable one and a 70 KB one give [] and a sections_error (size bound)", async () => {
  const { port, bucket } = boot();
  const none = (await board(port)).b;
  expect(none.sections).toEqual([]);
  expect(none.sections_error).toBeUndefined();
  await seed(bucket);
  const p = sidecarOf(bucket);
  writeFileSync(p, "{ not json");
  const bad = (await board(port)).b;
  expect(bad.sections).toEqual([]);
  expect(bad.sections_error).toContain("does not parse");
  writeFileSync(p, JSON.stringify({ sections: [{ id: "x", title: "t", body: "y".repeat(70_000) }] }));
  const big = (await board(port)).b;
  expect(big.sections).toEqual([]);
  expect(big.sections_error).toContain("over");
});

test("sections: a rewrite with the same mtime and a new size is re-read", async () => {
  const { port, bucket } = boot();
  await seed(bucket, "note", "short");
  const p = sidecarOf(bucket), at = new Date("2026-01-01T00:00:00Z");
  utimesSync(p, at, at);
  expect((await board(port)).b.sections[0].body).toBe("short");
  const next = JSON.parse(readFileSync(p, "utf8"));
  next.sections[0].body = "a much longer body than before";
  writeFileSync(p, JSON.stringify(next));
  utimesSync(p, at, at);
  expect((await board(port)).b.sections[0].body).toBe("a much longer body than before");
});

test("sections: a section string holding a nonce or a lock token is served redacted", async () => {
  const { port, bucket } = boot();
  await seed(bucket);
  writeFileSync(sidecarOf(bucket), JSON.stringify({ schema: "himmel.board-sections/1", rev: 1, sections: [{ id: "leak", title: `lock ${LOCK}`, body: `RETASK ${NONCE}`, tone: "warn", order: 10 }] }));
  const { b } = await board(port);
  expect(b.sections).toHaveLength(1);
  const text = JSON.stringify(b);
  expect(text).not.toContain(NONCE);
  expect(text).not.toContain(LOCK);
});

for (const readOnly of [false, true]) {
  test(`sections: no accepted request changes the sidecar (${readOnly ? "read-only" : "normal"} start)`, async () => {
    const { port, bucket } = boot(readOnly);
    await seed(bucket);
    const p = sidecarOf(bucket), before = statSync(p), bytes = readFileSync(p, "utf8");
    for (const method of ["GET", "POST", "PUT", "DELETE"]) {
      const r = await get(port, `/api/agui/board?console=${CHIEF}`, { "X-Himmel-Token": TOKEN }, method);
      expect(r.status).toBe(method === "GET" ? 200 : readOnly ? 403 : 405);
    }
    const after = statSync(p);
    expect([after.ino, after.mtimeMs, after.size]).toEqual([before.ino, before.mtimeMs, before.size]);
    expect(readFileSync(p, "utf8")).toBe(bytes);
    expect(readdirSync(bucket).filter((f) => f.includes(".tmp"))).toEqual([]);
  });
}

test("sections: an unknown console is 404 with no sections, and a start with no HANDOVER_DIR is 404 too", async () => {
  const { port, bucket } = boot();
  await seed(bucket);
  const unknown = await get(port, `/api/agui/board?console=HIMMEL-nope-chief`);
  expect(unknown.status).toBe(404);
  expect(await unknown.text()).not.toContain("sections");
  const dir = mkdtempSync(join(tmpdir(), "agui-board-nohd-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const s = startServer({ port: 0, token: TOKEN, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HOME: dir } });
  cleanups.push(() => s.stop());
  const none = await get(s.port, `/api/agui/board?console=${CHIEF}`);
  expect(none.status).toBe(404);
  expect(await none.text()).not.toContain("sections");
});

test("sections: a chief with no board file (503) still carries the sections that were read", async () => {
  const dir = mkdtempSync(join(tmpdir(), "agui-board-503-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const bucket = join(dir, "handovers", "op", "himmel");
  mkdirSync(bucket, { recursive: true });
  writeFileSync(chiefDoc(bucket), "# console\n");
  await seed(bucket);
  const s = startServer({ port: 0, token: TOKEN, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HANDOVER_DIR: join(dir, "handovers"), HOME: dir } });
  cleanups.push(() => s.stop());
  const { r, b } = await board(s.port);
  expect(r.status).toBe(503);
  expect(b.error).toBe("no board file for this console");
  expect(b.sections.map((x: { id: string }) => x.id)).toEqual(["next-up"]);
});

// The route serves only a board file that exists. RED control (pre-fix server): the missing file ran the boardScript stub, which left the marker.
test("board: with no board file the route answers no-board and never runs a build", async () => {
  const dir = mkdtempSync(join(tmpdir(), "agui-board-nofile-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const bucket = join(dir, "handovers", "op", "himmel");
  mkdirSync(bucket, { recursive: true });
  writeFileSync(chiefDoc(bucket), "# console\n");
  const marker = join(dir, "build-ran");
  const script = join(dir, "board.mjs");
  writeFileSync(script, `import { writeFileSync } from "node:fs";\nwriteFileSync(${JSON.stringify(marker)}, "x");\n`);
  const opts = { port: 0, token: TOKEN, boardScript: script, env: { PATH: process.env.PATH, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000", HANDOVER_DIR: join(dir, "handovers"), HOME: dir } };
  const s = startServer(opts);
  cleanups.push(() => s.stop());
  const { r, b } = await board(s.port);
  expect(r.status).toBe(503);
  expect(b.error).toBe("no board file for this console");
  expect(existsSync(marker)).toBe(false);
});
