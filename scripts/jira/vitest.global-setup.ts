import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const pkg = dirname(fileURLToPath(import.meta.url));

const sources = (): string[] =>
  (readdirSync(join(pkg, 'src'), { recursive: true }) as string[])
    .filter((f) => f.endsWith('.ts') && !f.endsWith('.test.ts'));

const srcNewest = (files: string[]): number =>
  Math.max(statSync(join(pkg, 'tsconfig.json')).mtimeMs, ...files.map((f) => statSync(join(pkg, 'src', f)).mtimeMs));

const current = (): boolean => {
  const files = sources();
  const newest = srcNewest(files);
  return files.every((f) => {
    const out = join(pkg, 'dist', f.replace(/\.ts$/, '.js'));
    return existsSync(out) && statSync(out).mtimeMs >= newest;
  });
};

export default function setup(): void {
  if (current()) return;
  try {
    execFileSync(process.execPath, [join(pkg, 'node_modules', 'typescript', 'bin', 'tsc'), '-p', pkg, '--noEmitOnError'],
      { cwd: pkg, stdio: 'pipe', timeout: 120_000 });
  } catch (e) {
    const err = e as { stdout?: Buffer; stderr?: Buffer; message: string };
    throw new Error(`jira vitest: dist/ is missing or older than src/, and tsc failed:\n${err.stdout?.toString() ?? ''}${err.stderr?.toString() ?? ''}${err.message}`);
  }
}
