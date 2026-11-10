// Runs one specCheck or specReview call from the built engine and prints its result as JSON, so a
// test can run a read that might block under spawnSync with a timeout.
// argv: <input JSON> <mode: check|review>
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const engine = await import(join(here, '..', '..', '..', 'dist', 'release', 'engine.js'));
const input = JSON.parse(process.argv[2]);
const mode = process.argv[3];

try {
  if (mode === 'check') {
    const r = engine.specCheck(input.env, input.keys, null, input.kinds ? { kinds: input.kinds } : undefined);
    process.stdout.write(JSON.stringify({ lines: r.lines, answer: r.answer ? Object.fromEntries(r.answer) : null }));
  } else if (mode === 'review') {
    const ctx = { ...input.ctx, env: input.env, now: () => new Date(input.ctx.now), jira: {}, mirrorRoot: null };
    const row = engine.specReview(ctx, input.review);
    process.stdout.write(JSON.stringify({ id: row.id }));
  } else {
    throw new Error(`unknown mode ${mode}`);
  }
} catch (e) {
  process.stdout.write(JSON.stringify({ error: e.message }));
}
