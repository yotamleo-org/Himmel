#!/usr/bin/env bun
// DEPRECATED forwarder, kept so old callers keep working: use usage-status.ts.
// It prints one stderr line, then runs usage-status.ts in this process, so argv,
// env, stdout and the exit code are that script's.
process.stderr.write("bank-status.ts is deprecated: use 'usage-status.ts' instead\n");
await import("./usage-status.ts");
