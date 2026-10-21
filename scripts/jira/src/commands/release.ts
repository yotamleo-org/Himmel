import type { Command } from 'commander';
import { projectKey, request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { markdownToAdf } from '../adf.js';
import { readBodyFile } from './body-file.js';
import { defaultRoot } from './mirror.js';
import { setFixVersion } from './versions.js';
import {
  apply, claim, declare, freeze, leaseAcquire, leaseRelease, operatorDecision, request as releaseRequest, rule, state, takeover,
  type Ctx, type JiraPort, type StateOut,
} from '../release/engine.js';
import { releaseDir, releaseKeyPath } from '../release/paths.js';
import type { Authority, Op, Verb } from '../release/types.js';

// `jira release <sub>`: the CLI face of the release engine.
// Callers in other languages read `jira release state <R> --json`.

export const liveJira: JiraPort = {
  async fixVersions(key) {
    const got = await request<{ fields?: { fixVersions?: Array<{ name?: string }> } }>('GET', `/issue/${key}?fields=fixVersions`);
    return (got.fields?.fixVersions ?? []).map((v) => v.name ?? '');
  },
  async setFixVersion(key, op, version) {
    await setFixVersion(key, op, version);
    writeJiraBreadcrumb(key);
  },
  async findComment(key, marker) {
    for (let startAt = 0; ; startAt += 100) {
      const page = await request<{ comments?: Array<{ id: string; body: unknown }>; total?: number }>(
        'GET', `/issue/${key}/comment?startAt=${startAt}&maxResults=100`,
      );
      const hit = (page.comments ?? []).find((c) => JSON.stringify(c.body).includes(marker));
      if (hit) return hit.id;
      if (!page.comments?.length || startAt + page.comments.length >= (page.total ?? 0)) return null;
    }
  },
  async addComment(key, markdown) {
    const got = await request<{ id: string }>('POST', `/issue/${key}/comment`, { body: markdownToAdf(markdown) });
    writeJiraBreadcrumb(key);
    return got.id;
  },
};

function ctxFor(release: string, mirrorRoot?: string): Ctx {
  return {
    release, dir: releaseDir(release), keyPath: releaseKeyPath(release), env: process.env, now: () => new Date(),
    jira: liveJira, mirrorRoot: mirrorRoot ?? (process.env.JIRA_PROJECT_KEY ? defaultRoot(process.env.JIRA_PROJECT_KEY) : null),
  };
}

const list = (s?: string) => (s ?? '').split(',').map((x) => x.trim()).filter(Boolean);
const ver = (s?: string) => (!s || s === 'backlog' ? null : s);

function op(kind: string, from?: string, to?: string): Op {
  const kinds: Op['kind'][] = ['add', 'remove', 'move', 'keep', 'discharge', 'none'];
  if (!kinds.includes(kind as Op['kind'])) throw new Error(`release: --op is one of ${kinds.join('|')}`);
  return { kind: kind as Op['kind'], from_v: ver(from), to_v: ver(to) };
}

export function renderState(s: StateOut): string {
  const out = [`release ${s.release}: ${s.status}${s.mode ? ` (${s.mode})` : ''}`];
  out.push(`inputs: ${Object.entries(s.inputs).map(([k, v]) => `${k}=${v}`).join(' ')}`);
  if (s.lease) out.push(`lease: epoch ${s.lease.epoch} ${s.lease.released ? 'released' : `held by ${s.lease.owner_doc}`}`);
  for (const [v, b] of Object.entries(s.burndown)) {
    out.push(`${v}: baseline ${b.baseline} (open ${b.baseline_open}), admitted open ${b.admitted_open}, emergency open ${b.emergency_open}, deferred out ${b.deferred_out}`);
  }
  out.push(`leaks: unauthorized ${s.leaks.unauthorized.join(', ') || 'none'}; ruled-in non-member ${s.leaks.ruled_in_non_member.join(', ') || 'none'}`);
  out.push(`requests: open ${s.requests.open.join(', ') || 'none'}; claimed ${s.requests.claimed.join(', ') || 'none'}`);
  for (const i of s.integrity) out.push(`integrity: ${i}`);
  return out.join('\n');
}

export function registerRelease(program: Command): void {
  const rel = program.command('release').description('Release ledger: placement rulings, lease and burn-down state (HIMMEL-6796)');

  rel.command('state <release>')
    .description('Effective release state from the one reducer (never a clean result on unknown input)')
    .option('--json', 'Print the full state as JSON')
    .option('--mirror-root <dir>', 'Jira mirror directory (default: the JIRA_PROJECT_KEY mirror)')
    .action((release: string, o: { json?: boolean; mirrorRoot?: string }) => {
      const s = state(ctxFor(release, o.mirrorRoot));
      console.log(o.json ? JSON.stringify(s, null, 2) : renderState(s));
      if (s.status !== 'OK') process.exitCode = 3;
    });

  rel.command('request <release>')
    .description('Queue a placement request for the release manager (the console writes these)')
    .requiredOption('--verb <verb>', 'INTAKE | REVERSION | DISCHARGE')
    .requiredOption('--key <key>', 'Issue key')
    .option('--from <version>', 'Source version, or backlog', 'backlog')
    .option('--to <version>', 'Target version, or backlog', 'backlog')
    .requiredOption('--why <text>', 'One line: why the request exists')
    .option('--evidence <json>', 'Evidence object as JSON', '{}')
    .action((release: string, o: { verb: string; key: string; from: string; to: string; why: string; evidence: string }) => {
      if (!['INTAKE', 'REVERSION', 'DISCHARGE'].includes(o.verb)) throw new Error('release request: --verb is INTAKE, REVERSION or DISCHARGE');
      const r = releaseRequest(ctxFor(release), {
        verb: o.verb as Verb, key: o.key, from_v: ver(o.from), to_v: ver(o.to), why: o.why,
        evidence: JSON.parse(o.evidence) as Record<string, unknown>, from: 'console',
      });
      console.log(`REQ ${r.req}`);
    });

  rel.command('claim <release>')
    .description('Claim the open requests for this lease epoch (the release manager)')
    .action((release: string) => {
      for (const r of claim(ctxFor(release))) {
        console.log(`${r.req} ${r.verb} ${r.key} ${r.from_v ?? 'backlog'}→${r.to_v ?? 'backlog'} — ${r.why}`);
      }
    });

  rel.command('rule <release>')
    .description('Write a ruling intent for a claimed request (the release manager)')
    .requiredOption('--req <id>', 'Request id (Q-<R>-NNNN)')
    .requiredOption('--outcome <outcome>', 'ADMIT | BACKLOG | AD-HOC | MOVE | KEEP | ACCEPT | REJECT')
    .requiredOption('--op <kind>', 'add | remove | move | keep | discharge | none')
    .option('--from <version>', 'Source version, or backlog', 'backlog')
    .option('--to <version>', 'Target version, or backlog', 'backlog')
    .requiredOption('--sector <sector>', 'The ticket sector')
    .requiredOption('--ground <ground>', 'The ground of the ruling (e.g. regression, frozen-set, found-work)')
    .option('--reason <text>', 'One-line reason')
    .option('--reason-file <path>', 'Read the reason from a file')
    .option('--supersedes <ids>', 'Comma-separated rulings (or baseline-<v>-g<n>) this replaces', '')
    .option('--authority <kind>', 'rm | operator | import', 'rm')
    .option('--ref <id>', 'The O- record (operator) or source (import)')
    .action((release: string, o: Record<string, string | undefined>) => {
      const reason = o.reasonFile ? readBodyFile(o.reasonFile, '--reason-file').trim() : o.reason ?? '';
      const r = rule(ctxFor(release), {
        req: o.req as string, outcome: o.outcome as string, op: op(o.op as string, o.from, o.to), sector: o.sector as string,
        ground: o.ground as string, reason, supersedes: list(o.supersedes),
        authority: { kind: o.authority as Authority['kind'], ref: o.ref ?? null },
      });
      console.log(`${r.id} intent (${r.class}); run: jira release apply ${release} ${r.id}`);
    });

  rel.command('apply <release> <ruling>')
    .description('Apply a ruling to Jira, read it back and post its receipt comment (idempotent)')
    .action(async (release: string, id: string) => {
      console.log((await apply(ctxFor(release), id)).line);
    });

  const lease = rel.command('lease').description('The release-manager ownership lease');
  lease.command('acquire <release>')
    .requiredOption('--expect-epoch <n>', 'The epoch the brief names')
    .requiredOption('--doc <path>', 'This session\'s absolute handover doc (HIMMEL_RM_DOC)')
    .requiredOption('--session <name>', 'This session\'s name')
    .action((release: string, o: { expectEpoch: string; doc: string; session: string }) => {
      const l = leaseAcquire(ctxFor(release), { expectEpoch: Number(o.expectEpoch), doc: o.doc, session: o.session });
      console.log(`LEASE ${release} epoch ${l.epoch} held by ${l.owner_doc}`);
    });
  lease.command('release <release>').action((release: string) => {
    const l = leaseRelease(ctxFor(release));
    console.log(`LEASE ${release} epoch ${l.epoch} released`);
  });

  const operator = rel.command('operator').description('Record an operator decision (the console, never a leg)');
  operator.command('declare <release>')
    .requiredOption('--versions <list>', 'Comma-separated versions; the first is current')
    .requiredOption('--decision <n>', 'Operator decision number')
    .requiredOption('--verbatim-file <path>', 'The operator\'s words, verbatim')
    .option('--mode <mode>', 'observe | live', 'observe')
    .action((release: string, o: { versions: string; decision: string; verbatimFile: string; mode: string }) => {
      if (o.mode !== 'observe' && o.mode !== 'live') throw new Error('release operator declare: --mode is observe or live');
      const d = declare(ctxFor(release), {
        project: projectKey(), versions: list(o.versions), decision: o.decision,
        verbatim: readBodyFile(o.verbatimFile, '--verbatim-file').trim(), mode: o.mode,
      });
      console.log(`DECLARED ${release} = ${d.versions.join(' + ')} (current ${d.current}, ${d.mode})`);
    });
  operator.command('freeze <release>')
    .requiredOption('--version <v>', 'The version whose baseline this freezes')
    .requiredOption('--keys <list>', 'Comma-separated keys')
    .requiredOption('--decision <n>', 'Operator decision number')
    .requiredOption('--verbatim-file <path>', 'The operator\'s words, verbatim')
    .action((release: string, o: { version: string; keys: string; decision: string; verbatimFile: string }) => {
      const b = freeze(ctxFor(release), {
        version: o.version, keys: list(o.keys), decision: o.decision, verbatim: readBodyFile(o.verbatimFile, '--verbatim-file').trim(),
      });
      console.log(`FROZEN baseline-${b.version}-g${b.gen} (${b.keys.length} keys)`);
    });
  operator.command('decision <release>')
    .requiredOption('--decision <n>', 'Operator decision number')
    .requiredOption('--keys <list>', 'Comma-separated keys the decision covers')
    .requiredOption('--op <kind>', 'add | remove | move | keep | discharge')
    .option('--from <version>', 'Source version, or backlog', 'backlog')
    .option('--to <version>', 'Target version, or backlog', 'backlog')
    .requiredOption('--verbatim-file <path>', 'The operator\'s words, verbatim')
    .action((release: string, o: { decision: string; keys: string; op: string; from: string; to: string; verbatimFile: string }) => {
      const r = operatorDecision(ctxFor(release), {
        decision: o.decision, keys: list(o.keys), op: o.op, from_v: ver(o.from), to_v: ver(o.to),
        verbatim: readBodyFile(o.verbatimFile, '--verbatim-file').trim(),
      });
      console.log(`${r.id} recorded; cite it as --authority operator --ref ${r.id}`);
    });
  operator.command('takeover <release>')
    .requiredOption('--epoch <n>', 'The epoch being taken over')
    .requiredOption('--doc <path>', 'The successor\'s absolute handover doc')
    .action((release: string, o: { epoch: string; doc: string }) => {
      const r = takeover(ctxFor(release), { epoch: Number(o.epoch), doc: o.doc });
      console.log(`${r.id} takeover of epoch ${o.epoch} for ${o.doc}`);
    });
}
