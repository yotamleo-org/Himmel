// shift-cli.ts — runs one shift poll from the command line, the helper the Morning report generator runs before it
// counts: a close pending since the last poll is written to shifts.jsonl first. Same poll, same writer and same
// settings as the Shift page route; it prints nothing on success. Run by bun: `bun shift-cli.ts`.
import { liveBoards, readMerged, shiftsFile, tick } from "./shift";
import { optsOf, readReports } from "./report-settings";

const env = process.env as Record<string, string | undefined>;
const handover = env.HANDOVER_DIR || "";
if (!handover) { console.error("shift-cli: no handover root is set (HANDOVER_DIR)"); process.exit(2); }
const reports = readReports();
const opts = "report_day" in reports.body ? optsOf(reports.body) : undefined; // an unreadable config polls with the defaults
await tick({ root: handover, file: shiftsFile(env), now: Date.now(), opts, merged: (a, b) => readMerged(env, process.cwd(), a, b), boards: (locks, spans) => liveBoards(handover, locks, spans) });
