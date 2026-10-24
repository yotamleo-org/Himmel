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
// The prompt is graphify's stdin plus, when GRAPHIFY_SEMANTIC_ADDENDUM names a file, the requirements addendum the
// claude-api path appends; the hash is over exactly the text the batch request carries.
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
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

let prompt = readFileSync(0, 'utf8');
if (process.env.GRAPHIFY_SEMANTIC_ADDENDUM) prompt += `\n\n---\n${readFileSync(process.env.GRAPHIFY_SEMANTIC_ADDENDUM, 'utf8')}`;
const sha = createHash('sha256').update(prompt).digest('hex');

if (mode === 'record') {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `${sha}.txt`), prompt, { mode: 0o600 });
  const placeholder = { nodes: [{ id: 'batch_record_placeholder', label: 'placeholder', file_type: 'document', source_file: 'placeholder.md' }], edges: [] };
  console.log(JSON.stringify({ type: 'result', subtype: 'success', is_error: false, result: JSON.stringify(placeholder), usage: {}, total_cost_usd: 0 }));
} else {
  const file = join(dir, `${sha}.json`);
  if (!existsSync(file)) { console.error(`batch shim: the batch holds no answer for prompt ${sha}`); process.exit(1); }
  process.stdout.write(readFileSync(file, 'utf8'));
}
