import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { goAnswer, type GoAnswerArgs, type GoAnswerDeps } from '../go-answer.js';
import type { Ctx } from '../engine-core.js';
import type { VerifiedLine } from '../operator-words-spawn.js';

interface Config {
  args: GoAnswerArgs; env: Record<string, string>; now: string; walk: NonNullable<GoAnswerDeps['walk']>;
  mirrorRoot: string; barrier: string; line: VerifiedLine;
}

const c = JSON.parse(readFileSync(process.argv[2], 'utf8')) as Config;

function meet(): void {
  writeFileSync(join(c.barrier, String(process.pid)), '');
  const end = Date.now() + 20_000;
  while (!existsSync(c.barrier) || readdirSync(c.barrier).length < 2) {
    if (Date.now() > end) throw new Error('the other child never reached the barrier');
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
  }
}

const deps: GoAnswerDeps = {
  env: c.env, now: () => new Date(c.now), platform: 'linux', walk: c.walk,
  ctxFor: (release, mirrorRoot): Ctx => ({
    release, dir: join(c.env.HIMMEL_RELEASE_STATE_DIR, release), keyPath: join(c.env.HIMMEL_RELEASE_KEY_DIR, `${release}.key`),
    env: c.env, now: () => new Date(c.now), jira: {} as Ctx['jira'], mirrorRoot,
  }),
  mirrorRoot: () => c.mirrorRoot,
  verify: (id) => {
    if (id === 0) throw new Error('the words verifier refused: update 0 is below the update-id floor');
    meet();
    return c.line;
  },
  gitleaks: () => 0,
};

try {
  process.stdout.write(`${JSON.stringify(goAnswer(c.args, deps))}\n`);
} catch (e) {
  process.stderr.write(`${(e as Error).message}\n`);
  process.exitCode = 2;
}
