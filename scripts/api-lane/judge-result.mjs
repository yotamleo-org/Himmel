// Reads a judge call's result and builds the bounded artifact the parent gets.
//   parse <raw-result.json> <requested-head> <evidence-out>
//     prints one JSON line: {status, reason, verdict, verdict_head, cost_usd}; status VERDICT means the
//     first line is a verdict naming the requested head and the evidence behind it is in <evidence-out>.
//   artifact <out.json> [key=value ...] [--excerpt <file>]
//     writes the artifact (mode 600): every field bounded, the excerpt cut to EXCERPT_MAX bytes.
import { readFileSync, writeFileSync } from 'node:fs';

const EXCERPT_MAX = 8192;
const EVIDENCE_MAX = 32768;
const REASON_MAX = 300;
const VERDICT_LINE = /^\*\*(GO|NO-GO)\*\*(?: for head `([0-9a-f]{40})`)?\.?$/;

const cut = (s, n) => (Buffer.byteLength(s) <= n ? s : Buffer.from(s).subarray(0, n).toString('utf8').replace(/�+$/, ''));

function parse(rawFile, head, evidenceOut) {
  const out = (status, reason, extra = {}) => console.log(JSON.stringify({ status, reason: cut(reason, REASON_MAX), verdict: null, verdict_head: null, cost_usd: null, ...extra }));
  let r;
  try { r = JSON.parse(readFileSync(rawFile, 'utf8')); } catch { return out('ERROR', 'the result is not JSON'); }
  const cost = r && typeof r.total_cost_usd === 'number' && Number.isFinite(r.total_cost_usd) && r.total_cost_usd >= 0
    ? r.total_cost_usd.toFixed(6) : null;
  if (!r || r.type !== 'result') return out('ERROR', 'the result is not a terminal result object', { cost_usd: cost });
  if (r.is_error !== false) return out('ERROR', `the call reported an error (${String(r.subtype ?? 'unknown')})`, { cost_usd: cost });
  // rc=0 with a refused tool means the judge ruled on less than it asked to read
  const denials = Array.isArray(r.permission_denials) ? r.permission_denials : [];
  if (denials.length > 0) {
    const names = [...new Set(denials.map((d) => String(d?.tool_name ?? 'unknown')))].join(',');
    return out('DENIED', `tool use was denied (${names}) although the call returned success`, { cost_usd: cost });
  }
  const text = typeof r.result === 'string' ? r.result.replace(/^\s*\n/, '') : '';
  const nl = text.indexOf('\n');
  const first = (nl < 0 ? text : text.slice(0, nl)).replace(/\r$/, '');
  const m = VERDICT_LINE.exec(first);
  if (!m) return out('MISSING', 'the first line is not **GO** or **NO-GO**', { cost_usd: cost });
  if (!m[2]) return out('MISSING', 'the verdict line names no head', { cost_usd: cost, verdict: m[1] });
  if (m[2] !== head) return out('STALE', `the verdict names head ${m[2]}, not the requested head`, { cost_usd: cost, verdict: m[1], verdict_head: m[2] });
  const evidence = nl < 0 ? '' : text.slice(nl + 1).trim();
  if (!evidence) return out('MISSING', 'a verdict with no evidence behind it', { cost_usd: cost, verdict: m[1], verdict_head: m[2] });
  const body = Buffer.byteLength(evidence) > EVIDENCE_MAX ? `${cut(evidence, EVIDENCE_MAX)}\n\n[evidence cut at ${EVIDENCE_MAX} bytes by the judge-call bridge]` : evidence;
  writeFileSync(evidenceOut, `${body}\n`, { mode: 0o600 });
  return out('VERDICT', 'verdict parsed', { cost_usd: cost, verdict: m[1], verdict_head: m[2] });
}

function artifact(outFile, rest) {
  const fields = {};
  let excerptFile = null;
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === '--excerpt') { excerptFile = rest[++i]; continue; }
    const eq = rest[i].indexOf('=');
    if (eq > 0) fields[rest[i].slice(0, eq)] = rest[i].slice(eq + 1);
  }
  let excerpt = '';
  if (excerptFile) { try { excerpt = readFileSync(excerptFile, 'utf8'); } catch { /* no evidence file: empty excerpt */ } }
  const orNull = (k) => (fields[k] === undefined || fields[k] === '' ? null : cut(fields[k], 512));
  const art = {
    status: orNull('status'), reason: fields.reason ? cut(fields.reason, REASON_MAX) : null,
    verdict: orNull('verdict'), head: orNull('head'), verdict_head: orNull('verdict_head'),
    qid: orNull('qid'), pr: orNull('pr'), model: orNull('model'), budget_usd: orNull('budget_usd'),
    cost_usd: orNull('cost_usd'), job_id: orNull('job_id'), verdict_path: orNull('verdict_path'),
    excerpt: cut(excerpt, EXCERPT_MAX), excerpt_truncated: Buffer.byteLength(excerpt) > EXCERPT_MAX,
  };
  writeFileSync(outFile, `${JSON.stringify(art, null, 2)}\n`, { mode: 0o600 });
}

const [cmd, ...args] = process.argv.slice(2);
if (cmd === 'parse' && args.length === 3) parse(...args);
else if (cmd === 'artifact' && args.length >= 1) artifact(args[0], args.slice(1));
else { console.error('usage: judge-result.mjs parse <raw> <head> <evidence-out> | artifact <out> [k=v ...] [--excerpt f]'); process.exit(2); }
