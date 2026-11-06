#!/usr/bin/env node
// semantic-batch-shim.mjs — a `claude -p` stand-in for graphify's claude-cli backend, in two modes.
//
// graphify answers each chunk with one `claude -p` call: prompt on stdin, a result envelope on stdout. A batch
// cannot be answered in-line, so a run goes through graphify twice with the SAME inputs:
//   record  GRAPHIFY_BATCH_MODE=record: write each prompt to $GRAPHIFY_BATCH_DIR/<sha256>.txt and answer with a
//           one-node placeholder so graphify finishes without retrying. The result is discarded; semantic-batch.mjs
//           submit turns the recorded prompts into one batch.
//   replay  GRAPHIFY_BATCH_MODE=replay: answer from $GRAPHIFY_BATCH_DIR/<sha256>.json (semantic-batch.mjs results).
//           A prompt the batch did not answer exits 1, so graphify counts a failed chunk and the files stay unstamped.
//           A chunk is answered by its full-prompt hash, else by its chunk-body key (see bodyKey below).
// The prompt is graphify's stdin plus, when GRAPHIFY_SEMANTIC_ADDENDUM names a file, the requirements addendum the
// claude-api path appends; the hash is over exactly the text the batch request carries.
import { createHash } from 'node:crypto';
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2);
if (['--help', '-h'].includes(args[0])) {
  console.log('claude (himmel batch shim): -p [--model M] [--output-format json]; the prompt is read from stdin');
  process.exit(0);
}
for (let i = 0; i < args.length;) {
  if (['-p', '--no-session-persistence'].includes(args[i])) i += 1;
  else if (['--output-format', '--json-schema', '--model'].includes(args[i]) && i + 1 < args.length) i += 2;
  else { console.error(`batch shim: refusing unexpected argument '${args[i]}'`); process.exit(2); }
}
const mode = process.env.GRAPHIFY_BATCH_MODE;
const dir = process.env.GRAPHIFY_BATCH_DIR;
if (!['record', 'replay'].includes(mode) || !dir) { console.error('batch shim: GRAPHIFY_BATCH_MODE and GRAPHIFY_BATCH_DIR are required'); process.exit(2); }

// A batch is replayed days after it was recorded, when graphify's instruction text or the addendum may have changed
// and the whole-prompt hash then matches nothing. The chunk body (everything after graphify's "Now extract ..."
// paragraph: each file's path, sha256 and text, never the instructions or the addendum) is the second key: it
// changes only when the chunk's own content does. semantic-batch.mjs submit reads the <sha>.key sidecar written here
// and results hands the key map back as bodies.json. The same pattern is in semantic-batch.mjs (INSTRUCTION_END).
// ponytail: the boundary is graphify's current wording; a reworded boundary leaves no body key, so replay falls back
// to the whole-prompt hash alone, never a wrong answer. Upgrade path: a chunk id graphify itself would pass.
const INSTRUCTION_END = /^Now extract the knowledge graph from the following source file[^\n]*\n\n/m;
const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const input = readFileSync(0, 'utf8');
const end = INSTRUCTION_END.exec(input);
const bodyKey = end && input.length > end.index + end[0].length ? sha256(input.slice(end.index + end[0].length)) : '';
let prompt = input;
if (process.env.GRAPHIFY_SEMANTIC_ADDENDUM) prompt += `\n\n---\n${readFileSync(process.env.GRAPHIFY_SEMANTIC_ADDENDUM, 'utf8')}`;
const sha = sha256(prompt);

if (mode === 'record') {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `${sha}.txt`), prompt, { mode: 0o600 });
  if (bodyKey) writeFileSync(join(dir, `${sha}.key`), bodyKey, { mode: 0o600 });
  const placeholder = { nodes: [{ id: 'batch_record_placeholder', label: 'placeholder', file_type: 'document', source_file: 'placeholder.md' }], edges: [] };
  console.log(JSON.stringify({ type: 'result', subtype: 'success', is_error: false, result: JSON.stringify(placeholder), usage: {}, total_cost_usd: 0 }));
} else {
  // The match kind is never silent: one line per answered chunk, counted by semantic-update.sh into the run log.
  let file = join(dir, `${sha}.json`);
  let kind = 'full';
  if (!existsSync(file)) {
    kind = 'body';
    let id = '';
    try { id = bodyKey ? JSON.parse(readFileSync(join(dir, 'bodies.json'), 'utf8'))[bodyKey] ?? '' : ''; } catch { /* no map: whole-prompt hash only */ }
    file = /^[a-f0-9]{64}$/.test(id) ? join(dir, `${id}.json`) : '';
  }
  if (!file || !existsSync(file)) { console.error(`batch shim: the batch holds no answer for prompt ${sha}`); process.exit(1); }
  appendFileSync(join(dir, 'replay-matches.log'), `${kind}\n`);
  process.stdout.write(readFileSync(file, 'utf8'));
}
