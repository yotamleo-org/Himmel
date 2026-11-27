import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { ReadinessFixture } from '../readiness.js';

/** The dispatcher every unit test gets unless it names another: it passes each ticket and records nothing. */
export function makePassingNdStub(): string {
  const path = join(mkdtempSync(join(tmpdir(), 'jira-test-readiness-')), 'next-dispatchable.sh');
  writeFileSync(path, 'exit 0\n');
  return path;
}

/** This checkout's own dispatcher, for the rows that read its verdict with no stub. */
export const DISPATCHER = fileURLToPath(new URL('../../../handover/chief-kit/next-dispatchable.sh', import.meta.url));

/** What the real dispatcher needs to answer offline: a repo with scripts/lib/a.sh on main, a mirror and a silent gh. */
export function makeNdFixture(): ReadinessFixture {
  const root = mkdtempSync(join(tmpdir(), 'jira-test-nd-fixture-'));
  const gitDir = join(root, 'repo');
  const mirror = join(root, 'mirror');
  mkdirSync(join(gitDir, 'scripts', 'lib'), { recursive: true });
  writeFileSync(join(gitDir, 'scripts', 'lib', 'a.sh'), 'true\n');
  const git = (...args: string[]) => execFileSync('git', ['-C', gitDir, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid',
    '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', ...args], { stdio: 'ignore' });
  git('init', '-q', '-b', 'main');
  git('add', '-A');
  git('commit', '-q', '-m', 'fixture');
  mkdirSync(mirror);
  writeFileSync(join(mirror, 'ZZ-1.md'), '---\nkey: "ZZ-1"\ntype: "Task"\nstatus: "Done"\n---\n\n# ZZ-1: done\n');
  const gh = join(root, 'gh');
  writeFileSync(gh, '#!/usr/bin/env bash\nexit 0\n', { mode: 0o755 });
  return { gitDir, mainRef: 'main', mirror, seams: { NEXT_DISPATCH_GH_CMD: gh } };
}

export interface NdCall {
  argv: string[];
  env: Record<string, string>;
  body: string | null;
  lockHeld: boolean;
}

const quote = (s: string): string => `'${s.replaceAll("'", `'\\''`)}'`;

/** A stand-in for next-dispatchable.sh: records each call, may sleep, prints `lines` and exits `exit`. */
export function makeNdStub(o: { lines?: string[]; exit?: number; sleepMs?: number; lockPath?: string } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'jira-test-nd-stub-'));
  const calls = join(root, 'calls');
  mkdirSync(calls);
  const out = join(root, 'lines');
  writeFileSync(out, (o.lines ?? []).map((l) => `${l}\n`).join(''));
  const pidFile = join(root, 'pid');
  const path = join(root, 'next-dispatchable.sh');
  writeFileSync(path, [
    'n=0',
    `until mkdir ${quote(calls)}/$n 2>/dev/null; do n=$((n+1)); done`,
    `c=${quote(calls)}/$n`,
    `echo $$ > ${quote(pidFile)}`,
    'printf \'%s\\0\' "$@" > "$c/argv"',
    'env -0 > "$c/env"',
    'prev=; for a in "$@"; do [ "$prev" != --body-file ] || cp "$a" "$c/body"; prev="$a"; done',
    ...(o.lockPath !== undefined ? [`[ ! -e ${quote(o.lockPath)} ] || : > "$c/lock"`] : []),
    ': > "$c/ready"',
    ...(o.sleepMs !== undefined ? [`sleep ${o.sleepMs / 1000}`] : []),
    `cat ${quote(out)}`,
    `exit ${o.exit ?? 0}`,
    '',
  ].join('\n'));
  const read = (file: string): string[] => readFileSync(file, 'utf8').split('\0').filter((s) => s !== '');
  return {
    path,
    calls(): NdCall[] {
      return readdirSync(calls).map(Number).sort((a, b) => a - b).map((n) => join(calls, String(n)))
        .filter((c) => existsSync(join(c, 'ready')))
        .map((c) => ({
          argv: read(join(c, 'argv')),
          env: Object.fromEntries(read(join(c, 'env')).map((e) => [e.slice(0, e.indexOf('=')), e.slice(e.indexOf('=') + 1)])),
          body: existsSync(join(c, 'body')) ? readFileSync(join(c, 'body'), 'utf8') : null,
          lockHeld: existsSync(join(c, 'lock')),
        }));
    },
    /** True while any process of the last call's process group still runs. */
    alive(): boolean {
      if (!existsSync(pidFile)) return false;
      try {
        process.kill(-Number(readFileSync(pidFile, 'utf8').trim()), 0);
        return true;
      } catch {
        return false;
      }
    },
  };
}
