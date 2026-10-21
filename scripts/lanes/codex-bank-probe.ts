#!/usr/bin/env bun
// DEPRECATED forwarder, kept so old callers keep working: use codex-usage-probe.ts.
// It prints one stderr line, then runs codex-usage-probe.ts in this process, so
// argv, env, stdout and the exit code are that script's.
process.stderr.write("codex-bank-probe.ts is deprecated: use 'codex-usage-probe.ts' instead\n");
await import("./codex-usage-probe.ts");
