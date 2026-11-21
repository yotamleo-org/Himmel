// Offline real-route/outbox controls. Only the Telegram transport is replaced.
import { expect, mock, test } from 'bun:test';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, unlinkSync, chmodSync, existsSync, statSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { replyViaOutbox, flushOutboxes } from './poller';
import * as bus from './bus';
import { owedSendReceipt, owedReceiptSnapshot, rememberConsoleReply, awaitOwedReceipts, routeReply } from './chief-route';
import * as fsp from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import { dirname } from 'node:path';

const NAME = 'HIMMEL-nextleg-2026-09-21V-chief';
function fixture() {
  const root = mkdtempSync(join(tmpdir(), 't4-recheck-'));
  mkdirSync(join(root, 'consoles'), { recursive: true });
  const inbox = join(root, 'consoles', NAME + '.md');
  writeFileSync(inbox, '');
  writeFileSync(inbox + '.wait', `hb=${Math.floor(Date.now() / 1000)} pid=123 key=- tick=- state=waiting\n`);
  const doc = join(root, 'chief.md');
  writeFileSync(doc, '# chief\n');
  const access = join(root, 'access.json');
  writeFileSync(access, '{"allowFrom":[1]}');
  return { root, doc, inbox, access };
}
async function reply(f: ReturnType<typeof fixture>, key: string, text: string, env: Record<string, string> = {}, verb = 'reply') {
  const proc = Bun.spawn(['bun', join(import.meta.dir, 'chief-route.ts'), verb, '--chief', NAME,
    '--owed', key, '--doc', f.doc, '1', text], {
    env: { ...process.env, BRIDGE_ROOT: f.root, CHIEF_ROUTE_RECEIPT_WAIT_SEC: '0', ...env }, stdout: 'pipe', stderr: 'pipe',
  });
  const stdout = new Response(proc.stdout).text();
  const stderr = new Response(proc.stderr).text();
  return { code: await proc.exited, out: await stdout, err: await stderr };
}
const outbox = (f: ReturnType<typeof fixture>) => join(f.root, 'sessions', '__chat__', 'outbox.jsonl');
const rows = (f: ReturnType<typeof fixture>) => readFileSync(outbox(f), 'utf8').trim().split('\n').map(l => JSON.parse(l));

test('retitles freeze original parts before and after delivery; changed raw text is refused', async () => {
  const f = fixture();
  const mirror = join(f.root, 'mirror', 'HIMMEL'); mkdirSync(mirror, { recursive: true });
  const ticket = join(mirror, 'HIMMEL-77.md');
  writeFileSync(ticket, '# HIMMEL-77: ' + 'title '.repeat(1300) + '\n');
  const env = { HIMMEL_JIRA_MIRROR: mirror };
  const text = 'blocked word '.repeat(243) + 'please sign HIMMEL-77 today';
  await reply(f, 'k1', text, env);
  const original = rows(f);
  expect(original.length).toBeGreaterThan(1);
  writeFileSync(ticket, '# HIMMEL-77: short title\n');
  await reply(f, 'k1', text, env);
  expect(rows(f)).toEqual(original);
  let id = 7000;
  await flushOutboxes(f.root, async () => ++id);
  // The session file may now be reclaimed; the original frozen plan survives.
  await flushOutboxes(f.root, async () => { throw new Error('duplicate send'); });
  expect((await reply(f, 'k1', text, env)).code).toBe(0);
  expect(readFileSync(f.doc, 'utf8')).toContain(`DELIVERED k1 msg=${id}`);
  expect(existsSync(outbox(f)) ? readFileSync(outbox(f), 'utf8') : '').toBe('');
  const { sent, send } = collector();
  await flushOutboxes(f.root, send);
  expect(sent).toEqual([]);
  expect((await reply(f, 'k1', 'please sign a changed action', env)).err).toContain('owed content changed');
});

test('a retried reply re-queues the frozen parts after a crash while queuing, never a fresh rendering', async () => {
  const f = fixture();
  const mirror = join(f.root, 'mirror', 'HIMMEL'); mkdirSync(mirror, { recursive: true });
  const ticket = join(mirror, 'HIMMEL-77.md');
  const env = { HIMMEL_JIRA_MIRROR: mirror };
  const text = 'blocked word '.repeat(243) + 'please sign HIMMEL-77 today';
  writeFileSync(ticket, '# HIMMEL-77: ' + 'title '.repeat(1300) + '\n');
  await reply(f, 'k2', text, env);
  const original = rows(f);
  expect(original.length).toBeGreaterThan(1);
  expect(original.map(r => r.text).join('')).toContain('title title title');
  writeFileSync(outbox(f), JSON.stringify(original[0]) + '\n');
  writeFileSync(ticket, '# HIMMEL-77: title\n');
  expect((await reply(f, 'k2', text, env)).code).toBe(1);
  expect(rows(f)).toEqual(original);
  const { sent, send } = collector();
  await flushOutboxes(f.root, send);
  expect(sent).toEqual(original.map(r => r.text));
});

test('part failure holds only its successors; ordinary and unrelated owed rows send once', async () => {
  const f = fixture();
  await reply(f, 'split', 'blocked word '.repeat(600));
  await replyViaOutbox(f.root, 1, 'ordinary reply', NAME);
  await reply(f, 'other', 'other owed');
  const sent: string[] = [];
  let fail = true;
  const send = async (_chat: number, text: string) => {
    if (text.startsWith('(1/') && fail) return undefined;
    sent.push(text.startsWith('(') ? text.slice(0, 5) : text);
    return 7100 + sent.length;
  };
  await flushOutboxes(f.root, send);
  await flushOutboxes(f.root, send);
  expect(sent).toEqual(['ordinary reply', 'other owed']);
  fail = false;
  for (const name of readdirSync(join(f.root, 'sessions', '__chat__'))) {
    if (name.includes('.retry-')) writeFileSync(join(f.root, 'sessions', '__chat__', name), '{"next":0,"attempts":1}');
  }
  await flushOutboxes(f.root, send);
  await flushOutboxes(f.root, send);
  expect(sent).toEqual(['ordinary reply', 'other owed', '(1/3)', '(2/3)', '(3/3)']);
  expect(readdirSync(join(f.root, 'sessions', '__chat__')).filter(n => n.includes('.sent-'))).toEqual([]);
});

test('corrupt request retry and receipt index are contained and retained for repair', async () => {
  for (const corrupt of ['retry', 'receipt']) {
    const f = fixture();
    await reply(f, 'bad', 'bad owed');
    await reply(f, 'good', 'good owed');
    await replyViaOutbox(f.root, 1, 'ordinary reply', NAME);
    const id = rows(f)[0].request_id;
    const broken = corrupt === 'retry' ? outbox(f) + '.retry-' + id : join(f.root, 'consoles', 'owed-receipts', `1_${id}.json`);
    mkdirSync(join(f.root, 'consoles', 'owed-receipts'), { recursive: true });
    writeFileSync(broken, '{');
    const sent: string[] = [];
    await flushOutboxes(f.root, async (_c, text) => { sent.push(text); return 7200 + sent.length; });
    expect(sent).toEqual(['good owed', 'ordinary reply']);
    expect(readFileSync(broken, 'utf8')).toBe('{');
    expect(readFileSync(f.doc, 'utf8')).not.toContain('DELIVERED bad');
    // Explicit scratch-state repair; production never overwrites the damage.
    unlinkSync(broken);
    await flushOutboxes(f.root, async (_c, text) => { sent.push(text); return 7200 + sent.length; });
    expect(sent).toEqual(['good owed', 'ordinary reply', 'bad owed']);
  }
});

test('receipt-only pass cannot enqueue absent requests or claim an unrelated receipt', async () => {
  const f = fixture();
  await rememberConsoleReply(f.root, 1, 7300, NAME);
  expect((await reply(f, 'absent', 'please sign', {}, 'receipt')).code).toBe(1);
  expect(readdirSync(join(f.root, 'consoles'))).not.toContain('owed-requests');
  expect(readFileSync(f.doc, 'utf8')).not.toContain('DELIVERED');
});

test('concurrent same-key callers enqueue each frozen part once', async () => {
  const f = fixture();
  await Promise.all(Array.from({ length: 6 }, () => reply(f, 'concurrent', 'please sign')));
  expect(rows(f)).toHaveLength(1);
});

test('indexed receipts and one shared legacy snapshot bound repeated retained-store scans', async () => {
  const f = fixture();
  const replies = join(f.root, 'consoles', 'replies'); mkdirSync(replies);
  for (let i = 1; i <= 5000; i++) writeFileSync(join(replies, `1_${i}.json`), JSON.stringify({ name: NAME }));
  const id = 'a'.repeat(64) + '-0';
  await rememberConsoleReply(f.root, 1, 9000, NAME, id, 'raw-hash');
  const started = performance.now();
  for (let i = 0; i < 10; i++) expect(await owedSendReceipt(f.root, 1, id, 'raw-hash')).toBe(9000);
  console.log(`10 indexed lookups with 5000 retained replies: ${(performance.now() - started).toFixed(1)} ms`);
  let scans = 0;
  let snapshot: ReturnType<typeof owedReceiptSnapshot> | undefined;
  const get = () => (snapshot ??= (scans++, owedReceiptSnapshot(f.root, 1)));
  for (let i = 0; i < 10; i++) expect(await owedSendReceipt(f.root, 1, 'b'.repeat(64) + `-${i}`, 'raw-hash', get)).toBeNull();
  expect(scans).toBe(1);
});

test('legacy-only receipts: one real read of the replies folder per pass across a multipart flush, wait and requeue', async () => {
  const f = fixture();
  await reply(f, 'multi', 'blocked word '.repeat(600));
  const parts = rows(f);
  expect(parts).toHaveLength(3);
  const { sent, send } = collector();
  await flushOutboxes(f.root, send);
  expect(sent).toHaveLength(3);
  rmSync(join(f.root, 'consoles', 'owed-receipts'), { recursive: true });
  const ids = parts.map(r => r.request_id as string);
  const real = { ...fsp };
  let reads = 0;
  mock.module('node:fs/promises', () => ({ ...real, default: real, readdir: (...a: any[]) => { if (String(a[0]).endsWith(join('consoles', 'replies'))) reads++; return (real.readdir as any)(...a); } }));
  try {
    writeFileSync(outbox(f) + '.cursor', '0');
    await flushOutboxes(f.root, send);
    expect(reads).toBe(1);
    reads = 0;
    expect(await awaitOwedReceipts(f.root, 1, parts[0].request_hash, ids, 0)).toEqual([7001, 7002, 7003]);
    expect(reads).toBe(1);
    reads = 0;
    writeFileSync(outbox(f), '');
    writeFileSync(outbox(f) + '.cursor', '0');
    await routeReply(f.root, 1, 'blocked word '.repeat(600), { consoleName: NAME, dest: 'operator', owedIdentity: `${realpathSync(dirname(f.doc))}\0multi` });
    expect(reads).toBe(1);
  } finally { mock.module('node:fs/promises', () => ({ ...real, default: real })); }
  expect(sent).toHaveLength(3);
  expect(readFileSync(outbox(f), 'utf8')).toBe('');
});

const NAME_B = 'HIMMEL-nextleg-2026-09-22W-chief';
const dirOf = (f: ReturnType<typeof fixture>) => join(f.root, 'sessions', '__chat__');
const indexOf = (f: ReturnType<typeof fixture>, id: string) => join(f.root, 'consoles', 'owed-receipts', `1_${id}.json`);
async function replyAs(f: ReturnType<typeof fixture>, name: string, doc: string, key: string, text: string, verb = 'reply') {
  const proc = Bun.spawn(['bun', join(import.meta.dir, 'chief-route.ts'), verb, '--chief', name, '--owed', key, '--doc', doc, '1', text],
    { env: { ...process.env, BRIDGE_ROOT: f.root, CHIEF_ROUTE_RECEIPT_WAIT_SEC: '0' }, stdout: 'pipe', stderr: 'pipe' });
  const stdout = new Response(proc.stdout).text(); const stderr = new Response(proc.stderr).text();
  return { code: await proc.exited, out: await stdout, err: await stderr };
}
const collector = () => { const sent: string[] = []; return { sent, send: async (_c: number, t: string) => { sent.push(t); return 7000 + sent.length; } }; };

test('X13-6: a successor chief finds the predecessor receipt and sends nothing again', async () => {
  const f = fixture();
  writeFileSync(join(f.root, 'consoles', NAME_B + '.md'), '');
  const docB = join(f.root, 'chief-b.md'); writeFileSync(docB, '# successor\n');
  await reply(f, 'k1', 'the digest');
  const { sent, send } = collector();
  await flushOutboxes(f.root, send);
  expect(sent).toEqual(['the digest']);
  const again = await replyAs(f, NAME_B, docB, 'k1', 'the digest');
  expect(again.code).toBe(0);
  await flushOutboxes(f.root, send);
  expect(sent).toEqual(['the digest']);
  expect(existsSync(outbox(f)) ? readFileSync(outbox(f), 'utf8') : '').toBe('');
  expect(readFileSync(docB, 'utf8')).toContain('DELIVERED k1 msg=7001');
});

test('X01-4 / X02-3a: a receipt index with a different or missing request hash is held, never delivered, never sent again', async () => {
  for (const hash of ['f'.repeat(64), undefined]) {
    const f = fixture();
    await reply(f, 'k4', 'please sign HIMMEL-77 today');
    const row = rows(f)[0];
    mkdirSync(join(f.root, 'consoles', 'owed-receipts'), { recursive: true });
    writeFileSync(indexOf(f, row.request_id), JSON.stringify({ name: NAME, message: 9999, request_id: row.request_id, ...(hash ? { request_hash: hash } : {}) }));
    const { sent, send } = collector();
    await flushOutboxes(f.root, send);
    expect(sent).toEqual([]);
    const r = await reply(f, 'k4', 'please sign HIMMEL-77 today', {}, 'receipt');
    expect(r.code).not.toBe(0);
    expect(readFileSync(f.doc, 'utf8')).not.toContain('DELIVERED');
  }
});

test('X02-3b: a receipt index with no string name is refused, not overwritten by a resend', async () => {
  const f = fixture();
  await reply(f, 'k3', 'please sign HIMMEL-78 today');
  const row = rows(f)[0];
  mkdirSync(join(f.root, 'consoles', 'owed-receipts'), { recursive: true });
  const body = JSON.stringify({ message: 9999, request_id: row.request_id, request_hash: row.request_hash });
  writeFileSync(indexOf(f, row.request_id), body);
  const { sent, send } = collector();
  await flushOutboxes(f.root, send);
  expect(sent).toEqual([]);
  expect(readFileSync(indexOf(f, row.request_id), 'utf8')).toBe(body);
});

test('X01-5: an unreadable replies folder is held for reconciliation, not read as no receipt', async () => {
  for (const control of [true, false]) {
    const f = fixture();
    await reply(f, 'k5', 'please sign HIMMEL-78 today');
    const { sent, send } = collector();
    await flushOutboxes(f.root, send);
    const id = rows(f)[0].request_id;
    unlinkSync(indexOf(f, id));
    writeFileSync(outbox(f) + '.cursor', '0');
    const replies = join(f.root, 'consoles', 'replies');
    if (!control) chmodSync(replies, 0o000);
    try { await flushOutboxes(f.root, send); } finally { chmodSync(replies, 0o755); }
    expect(sent).toHaveLength(1);
  }
});

test('X01-8: an owed row with a damaged id or no frozen hash is held, not sent as an ordinary reply', async () => {
  for (const damage of [{ request_id: 'damaged' }, { request_hash: undefined }]) {
    const f = fixture();
    await reply(f, 'k8', 'please sign HIMMEL-80 today');
    const line = JSON.stringify({ ...rows(f)[0], ...damage }) + '\n';
    writeFileSync(outbox(f), line);
    const { sent, send } = collector();
    await flushOutboxes(f.root, send);
    expect(sent).toEqual([]);
    expect(existsSync(outbox(f) + '.cursor') ? Number(readFileSync(outbox(f) + '.cursor', 'utf8')) : 0).toBe(0);
    expect(readFileSync(outbox(f), 'utf8')).toBe(line);
  }
});

test('X02-2a: the outbox reclaim waits for the owed-outbox lock', async () => {
  const f = fixture();
  await reply(f, 'k1', 'first owed');
  const { send } = collector();
  await flushOutboxes(f.root, send);
  expect(statSync(outbox(f)).size).toBeGreaterThan(0);
  const seen = join(f.root, 'size-at-release');
  const holder = Bun.spawn(['flock', '-x', join(f.root, 'owed-outbox.lock'), 'sh', '-c', `echo locked; sleep 1; wc -c < "${outbox(f)}" > "${seen}"`], { stdout: 'pipe' });
  const reader = holder.stdout.getReader();
  expect(new TextDecoder().decode((await reader.read()).value)).toContain('locked');
  await flushOutboxes(f.root, send);
  await holder.exited;
  expect(Number(readFileSync(seen, 'utf8'))).toBeGreaterThan(0);
  expect(statSync(outbox(f)).size).toBe(0);
});

test('X01-7 / X02-4: the completion marker outlives a failed cursor commit, so an ordinary row is sent once', async () => {
  const f = fixture();
  await reply(f, 'k7', 'owed text k7');
  await replyViaOutbox(f.root, 1, 'ordinary reply', NAME);
  const sent: string[] = [];
  let failOwed = true;
  const send = async (_c: number, t: string) => { if (t.startsWith('owed text') && failOwed) return undefined; sent.push(t); return 7300 + sent.length; };
  await flushOutboxes(f.root, send);
  expect(sent).toEqual(['ordinary reply']);
  failOwed = false;
  writeFileSync(join(dirOf(f), readdirSync(dirOf(f)).find(n => n.includes('.retry-'))!), '{"attempts":1,"next":0}');
  const real = { ...bus };
  let writes = 0;
  mock.module('./bus', () => ({ ...real, atomicWrite: async (path: string, data: string) => {
    if (path.endsWith('outbox.jsonl.cursor') && ++writes === 2) throw new Error('injected: cursor write failed');
    return real.atomicWrite(path, data);
  } }));
  try { await flushOutboxes(f.root, send); } finally { mock.module('./bus', () => real); }
  expect(writes).toBeGreaterThanOrEqual(2);
  await flushOutboxes(f.root, send);
  expect(sent.filter(t => t === 'ordinary reply')).toHaveLength(1);
});
