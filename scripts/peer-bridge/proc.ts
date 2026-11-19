import * as cp from "node:child_process";

export const procHooks = {
  spawn: cp.spawn as typeof cp.spawn,
  spawnSync: cp.spawnSync as typeof cp.spawnSync,
};

export type ProcResult = { code: number | null; stdout: string; stderr: string; timedOut: boolean };

// Runs argv[0] with the rest as arguments (never through a shell), feeds `input`
// on stdin and caps captured output. A run past timeoutMs is killed.
export function runProc(argv: string[], opts: { input?: string; env?: NodeJS.ProcessEnv; cwd?: string; timeoutMs?: number; maxBytes?: number } = {}): Promise<ProcResult> {
  return new Promise(resolve => {
    const child = procHooks.spawn(argv[0], argv.slice(1), { env: opts.env, cwd: opts.cwd, stdio: ["pipe", "pipe", "pipe"] });
    const max = opts.maxBytes ?? 65536;
    let stdout = "", stderr = "", timedOut = false, done = false;
    const finish = (code: number | null) => { if (done) return; done = true; clearTimeout(timer); resolve({ code, stdout, stderr, timedOut }); };
    const timer = setTimeout(() => { timedOut = true; child.kill("SIGKILL"); }, opts.timeoutMs ?? 15_000);
    child.stdout?.on("data", d => { if (stdout.length < max) stdout += d; });
    child.stderr?.on("data", d => { if (stderr.length < max) stderr += d; });
    child.once("error", () => finish(null));
    child.once("close", code => finish(code));
    child.stdin?.on("error", () => {});
    child.stdin?.end(opts.input ?? "");
  });
}
