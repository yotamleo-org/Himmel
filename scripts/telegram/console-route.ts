// DEPRECATED forwarder, kept so old callers keep working: use chief-route.ts.
// Imported, it re-exports chief-route.ts. Run, it prints one stderr line and runs
// chief-route.ts with the same argv; with legacy names off it exits 127.
import { spawnSync } from "node:child_process";
import { join } from "node:path";

export * from "./chief-route";

if (import.meta.main) {
  if (/^(0|false|no|off)$/i.test(process.env.HIMMEL_LEGACY_NAMES ?? "")) {
    console.error("console-route.ts was renamed to chief-route.ts; legacy names are off");
    process.exit(127);
  }
  console.error("console-route.ts is deprecated: use 'chief-route.ts' instead");
  const r = spawnSync(process.execPath, [join(import.meta.dir, "chief-route.ts"), ...process.argv.slice(2)], { stdio: "inherit" });
  process.exit(r.status ?? 1);
}
