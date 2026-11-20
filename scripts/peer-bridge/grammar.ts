import { randomBytes } from "node:crypto";

export const KIND_LINE_RE = /^#(ask:question|status|info|answer) id=([0-9a-f]{8})$/;
export const TPL_LINE_RE = /^#tpl:(receipt|nudge|deferred|closing|declined-kind|busy) #([0-9]+) id=([0-9a-f]{8})(?: by=([0-9]{8}T[0-9]{6}Z))?$/;

export const ENV_LINE_RE = /^#env:v1 k=([0-9a-f]{8}) id=([0-9a-f]{8})$/;
export const SIG_LINE_RE = /^sig=[A-Za-z0-9_-]{86}$/;

export type Kind = "ask:question" | "status" | "info" | "answer";
export type Tpl = "receipt" | "nudge" | "deferred" | "closing" | "declined-kind" | "busy";

export type Control =
  | { addr: boolean; kind: Kind; id: string; body: string; untagged?: undefined; tpl?: undefined }
  | { addr: boolean; tpl: Tpl; root: number; id: string; by?: Date; body: string; untagged?: undefined; kind?: undefined }
  | { addr: boolean; untagged: true; body: string; kind?: undefined; tpl?: undefined };

export const mintId = (): string => randomBytes(4).toString("hex");

// `by=` is a UTC stamp, YYYYMMDDTHHMMSSZ. A stamp that is not a real date reads as absent.
function parseBy(s: string | undefined): Date | undefined {
  if (!s) return undefined;
  const [y, mo, d, h, mi, se] = [s.slice(0, 4), s.slice(4, 6), s.slice(6, 8), s.slice(9, 11), s.slice(11, 13), s.slice(13, 15)].map(Number);
  const date = new Date(Date.UTC(y, mo - 1, d, h, mi, se));
  const same = date.getUTCFullYear() === y && date.getUTCMonth() === mo - 1 && date.getUTCDate() === d && date.getUTCHours() === h && date.getUTCMinutes() === mi && date.getUTCSeconds() === se;
  return same ? date : undefined;
}

// Line 1 may be the root address `/peer@<ourUsername>`, which is stripped; the
// next line must then be a kind line or a template line. Anything else is untagged.
export function parseControl(text: string, ourUsername: string): Control {
  const lines = text.split("\n");
  const addr = lines[0] === `/peer@${ourUsername}`;
  const rest = addr ? lines.slice(1) : lines;
  const first = rest[0] ?? "";
  const body = rest.slice(1).join("\n");
  const k = KIND_LINE_RE.exec(first);
  if (k) return { addr, kind: k[1] as Kind, id: k[2], body };
  const t = TPL_LINE_RE.exec(first);
  if (t) return { addr, tpl: t[1] as Tpl, root: Number(t[2]), id: t[3], by: parseBy(t[4]), body };
  return { addr, untagged: true, body: rest.join("\n") };
}

const pad = (n: number, w = 2) => String(n).padStart(w, "0");
export const byStamp = (d: Date): string =>
  `${pad(d.getUTCFullYear(), 4)}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`;
