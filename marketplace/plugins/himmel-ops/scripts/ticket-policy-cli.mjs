#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { draftLabels, labelsMismatch, shortName, validateTicketBody } from './ticket-policy.mjs';

function fail(msg) {
  process.stderr.write(`ticket-policy-cli: ${msg}\n`);
  process.exit(2);
}

const args = process.argv.slice(2);
const opt = {};
for (let i = 0; i < args.length; i += 1) {
  const a = args[i];
  if (a === '--json') opt.json = true;
  else if (['--type', '--draft', '--labels'].includes(a) && i + 1 < args.length) opt[a.slice(2)] = args[++i];
  else fail(`unknown or incomplete argument '${a}'`);
}
if (!opt.type || !opt.draft) fail('usage: ticket-policy-cli.mjs --type T --draft FILE [--labels a,b] [--json]');
let md;
try {
  md = readFileSync(opt.draft, 'utf8');
} catch (e) {
  fail(`cannot read draft '${opt.draft}': ${e.message}`);
}
const given = opt.labels === undefined ? undefined : opt.labels.split(',').map((l) => l.trim()).filter(Boolean);
const fromDraft = draftLabels(md);
const result = validateTicketBody({ format: 'markdown', body: md }, { issueType: opt.type, labels: given ?? fromDraft ?? [] });
const mismatch = labelsMismatch(given?.filter((l) => l !== 'standalone'), fromDraft?.filter((l) => l !== 'standalone'), opt.type);
if (mismatch) {
  result.diagnostics.push(mismatch);
  if (mismatch.severity === 'error') result.valid = false;
}
if (opt.json) process.stdout.write(JSON.stringify(result) + '\n');
else process.stdout.write(result.diagnostics.map(shortName).join(', ') + '\n');
