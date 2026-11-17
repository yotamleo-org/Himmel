import { lstat, mkdir, readFile, realpath, stat, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { ledgerVerify, roundSeed, sealRound } from './chief-route.ts';

type FixtureRead = string | { path: string; text: string };
export type RoundFixtureRequest = {
  scratchRoot: string; key: string; specText: string; planText: string;
  returns: { kind: 'spec' | 'plan'; round: number; text: string; reads: FixtureRead[] }[];
};
export type RoundFixture = { specsRoot: string; spec: string; plan: string; verdicts: string[]; ledgerPath: string };
const sha = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');

// Test-only: exercise the production seed/seal protocol with caller-owned scratch files.
export async function buildRoundFixture(request: RoundFixtureRequest): Promise<RoundFixture> {
  if (!isAbsolute(request.scratchRoot) || !await stat(request.scratchRoot).then(s => s.isDirectory(), () => false)) throw new Error('fixture scratch root must be an existing absolute directory');
  const scratch = await realpath(request.scratchRoot);
  if (!/^[A-Z][A-Z0-9]+-[0-9]+$/.test(request.key)) throw new Error('fixture needs a ticket key');
  const specsRoot = join(scratch, 'specs');
  const spec = join(specsRoot, 'designs', `${request.key}-fixture.md`);
  const plan = join(specsRoot, 'plans', `${request.key}-fixture.md`);
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
  // Refuse a reused fixture through the real seeder, before changing its documents.
  if (await stat(join(specsRoot, 'ledgers', 'spec-rounds', 'manifest.json')).then(() => true, () => false)) await roundSeed(specsRoot);
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
  for (const r of request.returns) {
    if ((r.kind !== 'spec' && r.kind !== 'plan') || r.round !== rounds[r.kind] + 1 || r.reads.length === 0) throw new Error('fixture rounds must be sequential with declared reads');
    rounds[r.kind]++;
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
    const lines = [`Key: ${request.key}`, `Reviewed: spec ${sha(await readFile(spec))}`, `Fixture: ${r.kind} round ${r.round}`,
      ...seals.map(s => `READ ${s.sha} ${s.rel}`), ...body, ...seals.map(s => `CONTENT-SHA256 ${s.sha} ${s.rel}`), last!, ''];
    await write(verdict, lines.join('\n'));
    for (const read of reads) await sealRound(verdict, read);
    await ledgerVerify(verdict, { spec });
    verdicts.push(verdict);
  }
  return { specsRoot, spec, plan, verdicts, ledgerPath: join(specsRoot, 'ledgers', 'spec-rounds', `${request.key}.jsonl`) };
}

if (import.meta.main) {
  const request = JSON.parse(await Bun.stdin.text()) as RoundFixtureRequest;
  console.log(JSON.stringify(await buildRoundFixture(request)));
}
