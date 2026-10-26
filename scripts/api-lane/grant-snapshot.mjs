// operator snapshot refresh for one account from a Console reading.
// Usage: node grant-snapshot.mjs <A|B> <remaining-usd> [<grant-usd> <starts YYYY-MM-DD> <expires YYYY-MM-DD>]
// The short form refreshes an existing row; the long form (re)writes the grant itself,
// dates read as 00:00 UTC (the earlier side of the Console's local date). Secret-free.
// `grant-snapshot.mjs --pull <A|B>` derives the remaining credit from the
// Admin API cost report instead (key ANTHROPIC_ORG_<A|B>_KEY, read inside the library only).
import { dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const { refreshSnapshot, pullSnapshot } = await import(pathToFileURL(`${HERE}/../lib/api-credit-state.mjs`).href);
const args = process.argv.slice(2);
let result;
if (args[0] === '--pull' && args.length === 2) {
  result = await pullSnapshot(process.env, args[1]);
} else if ([2, 5].includes(args.length) && args[0] !== '--pull') {
  const [account, remaining, grant, starts, expires] = args;
  result = refreshSnapshot(process.env, account, { remaining, grant, starts, expires });
} else {
  console.error('usage: grant-snapshot.mjs <A|B> <remaining-usd> [<grant-usd> <starts YYYY-MM-DD> <expires YYYY-MM-DD>]');
  console.error('       grant-snapshot.mjs --pull <A|B>');
  process.exit(2);
}
console.log(JSON.stringify(result));
process.exit(result.verdict === 'PROCEED' ? 0 : 1);
