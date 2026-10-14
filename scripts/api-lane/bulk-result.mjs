// Reads a bulk call's result and builds the bounded artifact the parent gets.
//   parse <raw-result.json> <paths-file> <sites-out>
//     prints one JSON line: {status, reason, cost_usd, site_count}; status OK means the reply was one JSON object
//     {"sites":[{"file","line","why"}]} whose every file is one of the paths asked about; the sites are in <sites-out>.
//   artifact <out.json> [key=value ...] [--sites <file>]
//     writes the artifact (mode 600): every field bounded, the sites list read back from <sites-out>.
import { readFileSync, writeFileSync } from 'node:fs';

const SITES_MAX = 200;
const WHY_MAX = 200;
const REASON_MAX = 300;

const cut = (s, n) => (Buffer.byteLength(s) <= n ? s : Buffer.from(s).subarray(0, n).toString('utf8').replace(/�+$/, ''));

function parse(rawFile, pathsFile, sitesOut) {
  const out = (status, reason, extra = {}) => console.log(JSON.stringify({ status, reason: cut(reason, REASON_MAX), cost_usd: null, site_count: null, ...extra }));
  let r;
  try { r = JSON.parse(readFileSync(rawFile, 'utf8')); } catch { return out('ERROR', 'the result is not JSON'); }
  const cost = r && typeof r.total_cost_usd === 'number' && Number.isFinite(r.total_cost_usd) && r.total_cost_usd >= 0
    ? r.total_cost_usd.toFixed(6) : null;
  if (!r || r.type !== 'result') return out('ERROR', 'the result is not a terminal result object', { cost_usd: cost });
  // a refused tool means the child answered on less than it asked to read, whatever else the result says
  const denials = Array.isArray(r.permission_denials) ? r.permission_denials : [];
  if (denials.length > 0) {
    const names = [...new Set(denials.map((d) => String(d?.tool_name ?? 'unknown')))].join(',');
    return out('DENIED', `tool use was denied (${names})`, { cost_usd: cost });
  }
  if (r.is_error !== false) return out('ERROR', `the call reported an error (${String(r.subtype ?? 'unknown')})`, { cost_usd: cost });
  let text = typeof r.result === 'string' ? r.result.trim() : '';
  const fence = /^```(?:json)?\n([\s\S]*)\n```$/.exec(text);
  if (fence) text = fence[1].trim();
  let body;
  try { body = JSON.parse(text); } catch { return out('INVALID', 'the reply is not one JSON object', { cost_usd: cost }); }
  if (!body || typeof body !== 'object' || !Array.isArray(body.sites)) return out('INVALID', 'the reply has no sites array', { cost_usd: cost });
  if (body.sites.length > SITES_MAX) return out('INVALID', `more than ${SITES_MAX} sites`, { cost_usd: cost });
  const asked = new Set(readFileSync(pathsFile, 'utf8').split('\n').filter(Boolean));
  const sites = [];
  for (const s of body.sites) {
    // a site outside the asked paths is a child that read what it was not given: fail closed, keep nothing
    if (!s || typeof s.file !== 'string' || !asked.has(s.file)) return out('INVALID', 'a site names a file that was not asked about', { cost_usd: cost });
    if (!Number.isInteger(s.line) || s.line < 1) return out('INVALID', 'a site has no positive integer line', { cost_usd: cost });
    sites.push({ file: s.file, line: s.line, why: cut(typeof s.why === 'string' ? s.why : '', WHY_MAX) });
  }
  writeFileSync(sitesOut, `${JSON.stringify(sites)}\n`, { mode: 0o600 });
  return out('OK', 'sites parsed', { cost_usd: cost, site_count: sites.length });
}

function artifact(outFile, rest) {
  const fields = {};
  let sitesFile = null;
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === '--sites') { sitesFile = rest[++i]; continue; }
    const eq = rest[i].indexOf('=');
    if (eq > 0) fields[rest[i].slice(0, eq)] = rest[i].slice(eq + 1);
  }
  let sites = [];
  if (sitesFile && fields.status === 'OK') {
    try { sites = JSON.parse(readFileSync(sitesFile, 'utf8')); } catch { fields.status = 'ERROR'; fields.reason = 'the validated sites could not be read back'; }
  }
  const orNull = (k) => (fields[k] === undefined || fields[k] === '' ? null : cut(fields[k], 512));
  const art = {
    status: orNull('status'), reason: fields.reason ? cut(fields.reason, REASON_MAX) : null,
    task_id: orNull('task_id'), class: orNull('class'), model: orNull('model'), budget_usd: orNull('budget_usd'),
    cost_usd: orNull('cost_usd'), job_id: orNull('job_id'), site_count: sites.length, sites,
  };
  writeFileSync(outFile, `${JSON.stringify(art, null, 2)}\n`, { mode: 0o600 });
}

const [cmd, ...args] = process.argv.slice(2);
if (cmd === 'parse' && args.length === 3) parse(...args);
else if (cmd === 'artifact' && args.length >= 1) artifact(args[0], args.slice(1));
else { console.error('usage: bulk-result.mjs parse <raw> <paths-file> <sites-out> | artifact <out> [k=v ...] [--sites f]'); process.exit(2); }
