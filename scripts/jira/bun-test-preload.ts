// Second preload for `bun test` (after vitest.setup.ts has pointed process.env.HOME at a temp dir).
// Under bun, reassigning process.env.HOME is not enough: os.homedir(), os.userInfo().homedir and
// a Bun.spawn child with no explicit env keep seeing the real home. Make all three follow it.
import osDefault from 'node:os';
import { mock } from 'bun:test';

const real = { ...osDefault };
const fake = {
  ...real,
  homedir: () => process.env.HOME as string,
  userInfo: (...a: unknown[]) => ({ ...(real.userInfo as (...x: unknown[]) => object)(...a), homedir: process.env.HOME }),
};
// Patch the module object itself (require() and default imports see it) and mock.module for the
// named, namespace and dynamic imports, which bun resolves separately.
osDefault.homedir = fake.homedir;
osDefault.userInfo = fake.userInfo as typeof osDefault.userInfo;
mock.module('node:os', () => ({ ...fake, default: osDefault }));
mock.module('os', () => ({ ...fake, default: osDefault }));

// A Bun.spawn / Bun.spawnSync child with no env inherits the startup environment, so hand it the
// current one. node:child_process children already follow process.env.
for (const name of ['spawn', 'spawnSync'] as const) {
  const orig = (Bun[name] as (...x: unknown[]) => unknown).bind(Bun);
  (Bun as unknown as Record<string, unknown>)[name] = (a: any, b?: any) =>
    Array.isArray(a)
      ? orig(a, { ...b, env: b?.env ?? { ...process.env } })
      : orig({ ...a, env: a?.env ?? { ...process.env } }, b);
}
