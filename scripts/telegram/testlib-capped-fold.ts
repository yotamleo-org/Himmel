import { lstat, mkdir, readFile, realpath, stat, utimes, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { closureMarker, ledgerVerify, returnSha, roundOverride, roundReset, roundSeed, sealRound } from './chief-route.ts';
import { ledgerDirOf, ledgerEntryNames } from '../jira/src/release/pinned.ts';

type FixtureRead = string | { path: string; text: string };
export type FixtureStep =                                                          // runs after returns[after] (0-based) is sealed
  | { after: number; step: 'override'; findings: string[]; why: string; chief: string }   // roundOverride; HIMMEL_CONSOLE=1 only around the call
  | { after: number; step: 'reset'; decision: string; quote: string;                      // the new-stem history reset
      documents: { specStem: string; specText: string; planText: string } }
  | { after: number; step: 'reset-in-place'; decision: string; quote: string };          // the existing helpers' recipe: the N8 negative only
export type RoundFixtureRequest = {
  scratchRoot: string; key: string; specText: string; planText: string;
  specStem?: string;                          // spec and plan stem, default `${key}-fixture`
  declarations?: boolean;                     // default true: the `Key:` and `Reviewed:` lines are written
  steps?: FixtureStep[];
  returns: { kind: 'spec' | 'plan'; round: number; text: string; reads: FixtureRead[];
    quote?: 'sha-path' | 'sha-path-two-space' | 'legacy-path-sha';                // default 'sha-path', today's lines
    closure?: boolean;                        // the builder writes the real CLOSURE-CHECK marker of the previous round of this kind
    rewrite?: { spec?: string; plan?: string } }[];                               // file text written before this round is sealed
};
export type RoundFixture = { specsRoot: string; spec: string; plan: string; verdicts: string[]; ledgerPath: string };   // after a `reset` step, spec and plan are the new-stem documents
// The options are defined once: the typed builders and the JSON selector take these fields by these names.
export type GroupOptions = { reset?: 'new-stem' | 'in-place' | 'none'; citation?: string };   // reset defaults to 'new-stem'; citation: one path as a `## Fact ownership` row
export type KnownSingleVariant = 'refusedCap' | 'overrideAdmitted' | 'admittedNextRound';
export type KnownSingleOptions = { variant: KnownSingleVariant; citation?: string };
export type GroupFixture = RoundFixture & { keys: string[]; anchor: string; members: string[];
  earlier: string[];                          // the earlier-epoch return paths ('new-stem' only), else []
  decision: string | null };                  // the reset decision file; null for reset 'none'
export type SelectorRequest =                                                      // the JSON-stdin selector; no new helper file
  | ({ builder: 'group'; scratchRoot: string } & GroupOptions)
  | ({ builder: 'known-single'; scratchRoot: string } & KnownSingleOptions)
  | { builder: 'fresh-single'; scratchRoot: string };

const sha = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');
const kindOf = (verdict: string) => /\.critic-(spec|plan)-r\d+\.md$/.exec(verdict)![1] as 'spec' | 'plan';

// The real helper runs only under the chief's console marker; the builder sets it around that one call and restores it.
async function underConsole<T>(call: () => Promise<T>): Promise<T> {
  const prior = process.env.HIMMEL_CONSOLE;
  process.env.HIMMEL_CONSOLE = '1';
  try { return await call(); } finally { if (prior === undefined) delete process.env.HIMMEL_CONSOLE; else process.env.HIMMEL_CONSOLE = prior; }
}

export async function buildRoundFixture(request: RoundFixtureRequest): Promise<RoundFixture> {
  if (!isAbsolute(request.scratchRoot) || !await stat(request.scratchRoot).then(s => s.isDirectory(), () => false)) throw new Error('fixture scratch root must be an existing absolute directory');
  const scratch = await realpath(request.scratchRoot);
  if (!/^[A-Z][A-Z0-9]+-[0-9]+$/.test(request.key)) throw new Error('fixture needs a ticket key');
  const specsRoot = join(scratch, 'specs');
  const documentsOf = (stem: string) => ({ spec: join(specsRoot, 'designs', `${stem}.md`), plan: join(specsRoot, 'plans', `${stem}.md`) });
  let { spec, plan } = documentsOf(request.specStem ?? `${request.key}-fixture`);
  const steps = request.steps ?? [];
  for (const s of steps) if (!Number.isInteger(s.after) || s.after < 0 || s.after >= request.returns.length) throw new Error('fixture step needs a return to follow');
  const inside = (path: string) => {
    const abs = resolve(scratch, path);
    if (!abs.startsWith(scratch + '/')) throw new Error('fixture read must be inside the scratch root');
    return abs;
  };
  const write = async (path: string, text: string) => {
    let ancestor = dirname(path);
    while (!await lstat(ancestor).then(() => true, error => {
      if (error.code === 'ENOENT') return false;
      throw error;
    })) ancestor = dirname(ancestor);
    const existing = await realpath(ancestor);
    if (existing !== scratch && !existing.startsWith(scratch + '/')) throw new Error('fixture read must be inside the scratch root');
    await mkdir(dirname(path), { recursive: true });
    const parent = await realpath(dirname(path));
    if (!parent.startsWith(scratch + '/')) throw new Error('fixture read must be inside the scratch root');
    await writeFile(path, text, { flag: 'wx' });
  };
  if (await stat(join(ledgerDirOf(specsRoot), 'manifest.json')).then(() => true, () => false)) await roundSeed(specsRoot);
  await write(spec, request.specText); await write(plan, request.planText);
  const extras = new Map<string, string>();
  for (const r of request.returns) for (const read of r.reads) if (typeof read !== 'string') {
    const path = inside(read.path);
    if (extras.has(path) && extras.get(path) !== read.text) throw new Error(`conflicting fixture input ${path}`);
    extras.set(path, read.text);
  }
  for (const [path, text] of extras) await write(path, text);
  await roundSeed(specsRoot);
  const verdicts: string[] = [];
  const rounds = { spec: 0, plan: 0 };
  const previous: Record<'spec' | 'plan', string | null> = { spec: null, plan: null };   // the text of the latest return of each kind in the current epoch
  // One decision recipe for both resets (scratch only): the decision file names the key and holds the quote, and is strictly newer than the latest round row.
  const decide = async (decision: string, quote: string) => {
    const path = join(specsRoot, 'decisions', `verbatim-decision-${decision}-fixture.txt`);
    await write(path, `${request.key} ${quote}\n`);
    const later = new Date(Date.now() + 2000); await utimes(path, later, later);
  };
  for (const [index, r] of request.returns.entries()) {
    if ((r.kind !== 'spec' && r.kind !== 'plan') || r.round !== rounds[r.kind] + 1 || r.reads.length === 0) throw new Error('fixture rounds must be sequential with declared reads');
    if (r.closure && previous[r.kind] === null) throw new Error('fixture closure round needs a previous round of its kind');
    rounds[r.kind]++;
    if (r.rewrite?.spec !== undefined) await writeFile(spec, r.rewrite.spec);
    if (r.rewrite?.plan !== undefined) await writeFile(plan, r.rewrite.plan);
    const reads: string[] = [];
    for (const read of r.reads) {
      const path = typeof read === 'string' ? read === 'spec' ? spec : read === 'plan' ? plan : inside(read) : inside(read.path);
      const canonical = await realpath(path);
      if (!canonical.startsWith(scratch + '/')) throw new Error('fixture read must be inside the scratch root');
      reads.push(canonical);
    }
    if (new Set(reads).size !== reads.length) throw new Error('fixture reads must be distinct');
    const verdict = `${spec}.critic-${r.kind}-r${r.round}.md`;
    const body = r.text.trimEnd().split('\n'); const last = body.pop();
    if (!new RegExp(`^${r.kind.toUpperCase()} (CLEAN|FINDINGS [0-9]+)$`).test(last ?? '')) throw new Error('fixture return needs a final verdict');
    const seals = await Promise.all(reads.map(async path => ({ path, sha: sha(await readFile(path)), rel: relative(dirname(verdict), path) })));
    const quote = (s: { path: string; sha: string }) => r.quote === 'sha-path-two-space' ? `READ-SHA256 ${s.sha}  ${s.path}` : r.quote === 'legacy-path-sha' ? `READ-SHA256 ${s.path} ${s.sha}` : `READ-SHA256 ${s.sha} ${s.path}`;
    const lines = [...(request.declarations === false ? [] : [`Key: ${request.key}`, `Reviewed: spec ${sha(await readFile(spec))}`]), `Fixture: ${r.kind} round ${r.round}`,
      ...seals.map(quote), ...(r.closure ? [closureMarker(request.key, r.kind, r.round, returnSha(previous[r.kind]!))] : []), ...body, ...seals.map(s => `CONTENT-SHA256 ${s.sha} ${s.rel}`), last!, ''];
    await write(verdict, lines.join('\n'));
    for (const read of reads) await sealRound(verdict, read);
    await ledgerVerify(verdict, { spec });
    verdicts.push(verdict); previous[r.kind] = lines.join('\n');
    for (const s of steps.filter(x => x.after === index)) {
      if (s.step === 'override') { const quote = 'open one more review round for this ticket'; await decide('7311', quote); await underConsole(() => roundOverride(specsRoot, request.key, { findings: s.findings, why: s.why, chief: s.chief, decision: '7311', quote })); continue; }
      await decide(s.decision, s.quote);
      await underConsole(() => roundReset(specsRoot, request.key, { decision: s.decision, quote: s.quote }));
      rounds.spec = 0; rounds.plan = 0; previous.spec = null; previous.plan = null;
      if (s.step === 'reset') {
        ({ spec, plan } = documentsOf(s.documents.specStem));
        await write(spec, s.documents.specText); await write(plan, s.documents.planText);
      } else {
        for (const path of [...verdicts]) {                  // the existing recipe: each earlier return rewritten and sealed again, so its path is a current row's
          const text = (await readFile(path, 'utf8')).replace('Fixture:', 'New epoch Fixture:');
          await writeFile(path, text);
          for (const m of text.matchAll(/^CONTENT-SHA256 [0-9a-f]{64} (.+)$/gm)) await sealRound(path, resolve(dirname(path), m[1]));
          rounds[kindOf(path)]++; previous[kindOf(path)] = text;
        }
      }
    }
  }
  return { specsRoot, spec, plan, verdicts, ledgerPath: join(ledgerDirOf(specsRoot), ledgerEntryNames(request.key).file) };
}

// ---- typed builders: the real-shaped Family A group, the known single, the fresh single ----
const ESTIMATE = { path: 'specs/designs/estimate.json', text: '{"median_seq":1,"sigma":0.1,"dod":{"passed":true}}\n' };
const factOwnership = (citation?: string) => citation ? `\n## Fact ownership\n\n| Fact | Existing surfaces | Owner after | Non-owners |\n|---|---|---|---|\n| source | \`${citation}\` | source | n/a |\n` : '';
const specDocument = (tickets: string, title: string, line: string, citation?: string) =>
  `---\ntickets: ${tickets}\n---\n# ${title}\n\nEstimate record: estimate.json\n\n${line}\n\n## Alternatives considered\n\n- None better.\n\n## Definition of done\n\n- Fixture verifies.\n\n## Invariants\n\nnone\n${factOwnership(citation)}`;
const planDocument = (title: string, line: string) => `# ${title}\n\n- ${line}\n`;
type Return = RoundFixtureRequest['returns'][number];
const issue = (kind: 'spec' | 'plan', round: number, findings: string[], extra: Partial<Return> = {}): Return => ({
  kind, round, text: `${findings.map(f => `${f}\n`).join('')}${kind.toUpperCase()} ${findings.length ? `FINDINGS ${findings.length}` : 'CLEAN'}\n`,
  reads: kind === 'spec' ? ['spec', ESTIMATE] : ['spec', 'plan', ESTIMATE], ...extra });
const SPEC_LINE = 'The fixture contract names every member.';
const SPEC_CHANGED = 'The fixture contract names each member and its owner.';
// The real five-return spec run that reaches the cap: three full returns with a major in the last, a closure return holding a regression
// (its quoted line changed by the rewrite), one override that opens the next return, and a closure return that ends CLEAN. Its finding ids differ from the later epoch's.
const fiveReturnRun = (specOf: (line: string) => string, extra: Partial<Return> = {}) => ({
  returns: [
    issue('spec', 1, ['- **A1** (minor) a wording note'], extra), issue('spec', 2, ['- **A2** (minor) another wording note'], extra),
    issue('spec', 3, ['- **M1** (major) the contract omits a member'], extra),
    issue('spec', 4, [`- **R1** (major; regression) the line \`${SPEC_LINE}\` regressed`], { ...extra, closure: true, rewrite: { spec: specOf(SPEC_CHANGED) } }),
    issue('spec', 5, [], { ...extra, closure: true }),
  ],
  steps: [{ after: 3, step: 'override' as const, findings: ['R1'], why: 'fixture override of the closure round', chief: 'fixture-chief' }],
});
const RESET_QUOTE = 'start this ticket over from scratch';

const fixtureKey = (n: number) => `HIMMEL-${n}`;   // synthetic keys, built at runtime
const GROUP_KEYS = [9801, 9802, 9803, 9804, 9805, 9806, 9807].map(fixtureKey);
export async function buildGroupFixture(scratchRoot: string, opts: GroupOptions = {}): Promise<GroupFixture> {
  const reset = opts.reset ?? 'new-stem';
  if (reset !== 'new-stem' && reset !== 'in-place' && reset !== 'none') throw new Error(`fixture group reset must be new-stem, in-place or none: ${reset}`);
  const keys = [...GROUP_KEYS]; const anchor = keys[0]; const tickets = `[${keys.join(', ')}]`;
  const specOf = (title: string) => (line: string) => specDocument(tickets, title, line, opts.citation);
  const plan = planDocument(`${anchor} group plan`, 'Task 1: build the fixture.');
  const current = [1, 2, 3].flatMap(round => (['spec', 'plan'] as const).map(kind =>
    issue(kind, round, [kind === 'spec' ? '- **F1** (medium; Fact overlap) the group contract overlaps an owner' : '- **P1** (minor) a plan wording note'])));
  const base = { scratchRoot, key: anchor, specText: specOf(`${anchor} group fixture`)(SPEC_LINE), planText: plan, declarations: false };
  const decision = reset === 'none' ? null : join(await realpath(scratchRoot), 'specs', 'decisions', 'verbatim-decision-990-fixture.txt');
  if (reset === 'none') return { ...await buildRoundFixture({ ...base, returns: current }), keys, anchor, members: keys.slice(1), earlier: [], decision };
  if (reset === 'in-place') {
    // Reuse nonblocking returns so the negative isolates path reuse without an independently admitted closure.
    const returns = [...current.filter(r => r.kind === 'spec'), ...current.filter(r => r.kind === 'plan')];
    const f = await buildRoundFixture({ ...base, returns, steps: [{ after: 2, step: 'reset-in-place', decision: '990', quote: RESET_QUOTE }] });
    return { ...f, keys, anchor, members: keys.slice(1), earlier: [], decision };
  }
  const run = fiveReturnRun(specOf(`${anchor} group fixture`));
  const documents = { specStem: `${anchor}-group-epoch1`, specText: specOf(`${anchor} group fixture epoch 1`)(SPEC_LINE), planText: plan };
  const f = await buildRoundFixture({ ...base, returns: [...run.returns, ...current],
    steps: [...run.steps, { after: 4, step: 'reset', decision: '990', quote: RESET_QUOTE, documents }] });
  return { ...f, keys, anchor, members: keys.slice(1), earlier: f.verdicts.slice(0, 5), decision };
}

const PLAN_LINE = 'Task 1: build the known-single fixture.';
const PLAN_CHANGED = 'Task 1: build and verify the known-single fixture.';
const KNOWN_VARIANTS: KnownSingleVariant[] = ['refusedCap', 'overrideAdmitted', 'admittedNextRound'];
export async function buildKnownSingleFixture(scratchRoot: string, opts: KnownSingleOptions): Promise<RoundFixture> {
  if (!opts || !KNOWN_VARIANTS.includes(opts.variant)) throw new Error(`fixture known-single variant must be one of ${KNOWN_VARIANTS.join(', ')}`);
  const key = fixtureKey(9811);
  const specOf = (line: string) => specDocument(`${key} (a partial merge owes proof by default)`, `${key} known single`, line, opts.citation);
  const run = fiveReturnRun(specOf, { quote: 'sha-path-two-space' });                    // two-space quotes in the spec return, legacy quotes in the plan return
  const legacy = { quote: 'legacy-path-sha' as const };
  const plans = [1, 2, 3].map(round => issue('plan', round, [`- **P${round}** (minor) a plan note`], legacy));
  const four = opts.variant === 'refusedCap' ? [issue('plan', 4, ['- **P4** (minor) a closure note', '- **P5** (minor) another closure note'], { ...legacy, closure: true })]
    : opts.variant === 'overrideAdmitted' ? [issue('plan', 4, [`- **PR1** (major; regression) the line \`${PLAN_LINE}\` regressed`], { ...legacy, closure: true, rewrite: { plan: planDocument(`${key} known single plan`, PLAN_CHANGED) } })] : [];
  const admitted = opts.variant === 'overrideAdmitted';
  const returns = admitted ? [...run.returns.slice(0, 4), ...plans, ...four, run.returns[4]] : [...run.returns, ...plans, ...four];
  const steps = admitted ? [{ ...run.steps[0], after: 7, findings: ['R1', 'PR1'] }] : run.steps;
  return buildRoundFixture({ scratchRoot, key, specText: specOf(SPEC_LINE), planText: planDocument(`${key} known single plan`, PLAN_LINE),
    declarations: false, returns, steps });
}

export async function buildFreshSingleFixture(scratchRoot: string): Promise<RoundFixture> {
  const key = fixtureKey(9821);
  const returns = [1, 2, 3].flatMap(round => (['spec', 'plan'] as const).map(kind => issue(kind, round, [kind === 'spec' ? `- **F${round}** (minor) a wording note` : `- **P${round}** (minor) a plan note`])));
  return buildRoundFixture({ scratchRoot, key, specText: specDocument(key, `${key} fresh single`, SPEC_LINE), planText: planDocument(`${key} fresh single plan`, 'Task 1: build the fixture.'),
    declarations: false, returns });
}

if (import.meta.main) {
  const input = JSON.parse(await Bun.stdin.text()) as RoundFixtureRequest | SelectorRequest;
  const { builder, scratchRoot, ...options } = input as { builder?: string; scratchRoot: string };
  const fixture = builder === undefined ? await buildRoundFixture(input as RoundFixtureRequest)
    : builder === 'group' ? await buildGroupFixture(scratchRoot, options as GroupOptions)
    : builder === 'known-single' ? await buildKnownSingleFixture(scratchRoot, options as KnownSingleOptions)
    : builder === 'fresh-single' ? await buildFreshSingleFixture(scratchRoot)
    : (() => { throw new Error(`fixture selector: unknown builder ${builder}`); })();
  console.log(JSON.stringify(fixture));
}
