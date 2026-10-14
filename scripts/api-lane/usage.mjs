// HIMMEL-5570: reads the JSON result file of a launcher run and prints the usage split as
// "<input> <cache_creation> <cache_read>" (integers), or nothing when the result has no usable usage object.
// The launch record turns "nothing" into null, never into zero, so a run that reported no usage cannot read as a miss.
import { readFileSync } from 'node:fs';

try {
  const u = JSON.parse(readFileSync(process.argv[2], 'utf8')).usage;
  const n = [u.input_tokens, u.cache_creation_input_tokens, u.cache_read_input_tokens];
  if (n.every((v) => Number.isInteger(v) && v >= 0)) console.log(n.join(' '));
} catch { /* no usage: the record carries null */ }
