// HIMMEL-5433: operator snapshot refresh for one account from a Console reading.
// Usage: node grant-snapshot.mjs <A|B> <remaining-usd> [<grant-usd> <starts YYYY-MM-DD> <expires YYYY-MM-DD>]
// The short form refreshes an existing row; the long form (re)writes the grant itself,
// dates read as 00:00 UTC (the earlier side of the Console's local date). Secret-free.
import { dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const { refreshSnapshot } = await import(pathToFileURL(`${HERE}/../lib/api-credit-state.mjs`).href);
const [account, remaining, grant, starts, expires] = process.argv.slice(2);
if (![2, 5].includes(process.argv.length - 2)) {
  console.error('usage: grant-snapshot.mjs <A|B> <remaining-usd> [<grant-usd> <starts YYYY-MM-DD> <expires YYYY-MM-DD>]');
  process.exit(2);
}
const result = refreshSnapshot(process.env, account, { remaining, grant, starts, expires });
console.log(JSON.stringify(result));
process.exit(result.verdict === 'PROCEED' ? 0 : 1);
