// Offline real-route/outbox controls. Only the Telegram transport is replaced.
import { expect, test } from 'bun:test';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { replyViaOutbox, flushOutboxes } from './poller';
import { owedSendReceipt, owedReceiptSnapshot, rememberConsoleReply } from './chief-route';

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
  expect((await reply(f, 'k1', 'please sign a changed action', env)).err).toContain('owed content changed');
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
  for (let i = 0; i < 10; i++) expect(await owedSendReceipt(f.root, 1, NAME, id)).toBe(9000);
  console.log(`10 indexed lookups with 5000 retained replies: ${(performance.now() - started).toFixed(1)} ms`);
  let scans = 0;
  let snapshot: ReturnType<typeof owedReceiptSnapshot> | undefined;
  const get = () => (snapshot ??= (scans++, owedReceiptSnapshot(f.root, 1)));
  for (let i = 0; i < 10; i++) expect(await owedSendReceipt(f.root, 1, NAME, 'b'.repeat(64) + `-${i}`, undefined, get)).toBeNull();
  expect(scans).toBe(1);
});
