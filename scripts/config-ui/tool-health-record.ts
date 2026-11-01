// tool-health-record.ts — writes one finished UTC day of the Tool health page's counts as a tool-health eval-runs row.
// Same roll-up, same wiring scan and same chain logs as GET /api/tool-health; tool_health_record.py appends it once per day.
// Run by bun, by hand (nothing schedules it): `bun tool-health-record.ts [--day YYYY-MM-DD] [--ledger PATH] [--dry-run]`.
// The day defaults to yesterday (UTC); a day that has not finished is refused, because the record of a day is final.
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { buildRecord } from "../eval/worker-digest/tool-health-record.mjs";
import { eligibleFromInventory, readToolInventory } from "./tool-inventory";
import { readToolHealth } from "./health-sources";
import { stationRoot } from "./server";

const env = process.env as Record<string, string | undefined>;
const args = process.argv.slice(2);
const flag = (name: string) => { const i = args.indexOf(name); return i < 0 ? undefined : args[i + 1]; };
const now = Date.now(), today = new Date(now).toISOString().slice(0, 10);
const day = flag("--day") ?? new Date(now - 86400000).toISOString().slice(0, 10);
if (!/^\d{4}-\d{2}-\d{2}$/.test(day) || Number.isNaN(Date.parse(day))) { console.error("tool-health-record: --day must be YYYY-MM-DD"); process.exit(2); }
if (day >= today) { console.error(`tool-health-record: ${day} has not finished (UTC today is ${today}); its record would be final too early`); process.exit(2); }

const repo = env.HIMMEL_REPO || stationRoot(dirname(import.meta.dir));
const scanEnv = { ...env, HIMMEL_REPO: repo };
const rollup = readToolHealth(env, new URLSearchParams({ since: day }), Date.parse(`${day}T23:59:59.999Z`), { eligible: eligibleFromInventory(readToolInventory(scanEnv, now)), repoRoot: repo });
const body = buildRecord(rollup, { day });
if (!body) { console.log(`tool-health-record: no session ran on ${day}; nothing recorded`); process.exit(0); }
if (args.includes("--dry-run")) { console.log(JSON.stringify(body)); process.exit(0); }

const writer = join(dirname(import.meta.dir), "eval", "worker-digest", "tool_health_record.py");
const ledger = flag("--ledger");
const out = spawnSync("python3", [writer, "write", "--body", "-", ...(ledger ? ["--ledger", ledger] : [])], { input: JSON.stringify(body), encoding: "utf8", env });
process.stdout.write(out.stdout ?? "");
process.stderr.write(out.stderr ?? "");
process.exit(out.status ?? 2);
