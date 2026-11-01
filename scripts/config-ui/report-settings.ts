// the config UI's read and write of the `reports` section of ~/.himmel/config.json: the four numbers that shape the
// Morning report and the shifts it counts. report_day is the zone the report day is cut in (local midnight on the
// station, or UTC); the other three are the shift cut rule (shift.ts's Opts). The generator reads report_day,
// shift.ts's callers read the rest. Everything goes through luna-config.js: save() is atomic and keeps every other
// section of the document as inspect() loaded it.
import { inspect, save } from "../himmelctl/lib/luna-config.js";
import { DEFAULTS, type Opts } from "./shift";

export type Reports = { report_day: "local" | "utc"; shift_idle_min: number; shift_cuts: [string, string]; shift_min_run_h: number };
export type ReportsResult = { status: number; body: Reports | { error: string } };

export const REPORT_DEFAULTS: Reports = { report_day: "local", shift_idle_min: DEFAULTS.idleMin, shift_cuts: [DEFAULTS.cuts[0], DEFAULTS.cuts[1]], shift_min_run_h: DEFAULTS.minHours };

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
const CUT = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;

// A stored value that does not validate falls back to its default: a hand-edited file never breaks the page.
export function normalise(raw: unknown): Reports {
  const r = isObject(raw) ? raw : {};
  const d = REPORT_DEFAULTS;
  const cuts = Array.isArray(r.shift_cuts) && r.shift_cuts.length === 2 && r.shift_cuts.every((c) => typeof c === "string" && CUT.test(c)) && (r.shift_cuts[0] as string) < (r.shift_cuts[1] as string)
    ? [r.shift_cuts[0], r.shift_cuts[1]] as [string, string] : d.shift_cuts;
  return {
    report_day: r.report_day === "utc" ? "utc" : "local",
    shift_idle_min: Number.isInteger(r.shift_idle_min) && (r.shift_idle_min as number) >= 1 && (r.shift_idle_min as number) <= 1440 ? r.shift_idle_min as number : d.shift_idle_min,
    shift_cuts: cuts,
    shift_min_run_h: typeof r.shift_min_run_h === "number" && r.shift_min_run_h > 0 && r.shift_min_run_h <= 24 ? r.shift_min_run_h : d.shift_min_run_h,
  };
}

export const optsOf = (r: Reports): Opts => ({ idleMin: r.shift_idle_min, cuts: [...r.shift_cuts], minHours: r.shift_min_run_h });

export function readReports(): ReportsResult {
  try { return { status: 200, body: normalise(inspect().doc.reports) }; } catch (e) { return { status: 422, body: { error: (e as Error).message } }; }
}

// Strict on the way in: a value that is not valid is named, never coerced.
export function validate(b: Record<string, unknown>): { errors: string[]; value: Reports } {
  const errors: string[] = [];
  if (b.report_day !== "local" && b.report_day !== "utc") errors.push("report_day must be local or utc");
  const idle = typeof b.shift_idle_min === "string" && /^[0-9]+$/.test(b.shift_idle_min) ? Number(b.shift_idle_min) : b.shift_idle_min;
  if (!Number.isInteger(idle) || (idle as number) < 1 || (idle as number) > 1440) errors.push("shift_idle_min must be a whole number of minutes from 1 to 1440");
  const cuts = b.shift_cuts;
  if (!Array.isArray(cuts) || cuts.length !== 2 || !cuts.every((c) => typeof c === "string" && CUT.test(c))) errors.push("shift_cuts must be two times as HH:MM");
  else if ((cuts[0] as string) >= (cuts[1] as string)) errors.push("shift_cuts: the day cut must be earlier than the night cut");
  const hours = typeof b.shift_min_run_h === "string" && b.shift_min_run_h.trim() !== "" ? Number(b.shift_min_run_h) : b.shift_min_run_h;
  if (typeof hours !== "number" || !Number.isFinite(hours) || hours <= 0 || hours > 24) errors.push("shift_min_run_h must be hours above 0 and up to 24");
  return { errors, value: errors.length ? REPORT_DEFAULTS : { report_day: b.report_day as "local" | "utc", shift_idle_min: idle as number, shift_cuts: [cuts![0], cuts![1]] as [string, string], shift_min_run_h: hours as number } };
}

export function writeReports(b: Record<string, unknown>): ReportsResult {
  const { errors, value } = validate(b);
  if (errors.length > 0) return { status: 400, body: { error: errors.join("; ") } };
  try {
    const { doc } = inspect();
    doc.reports = value;
    save(doc);
  } catch (e) { return { status: 422, body: { error: (e as Error).message } }; }
  return readReports();
}
