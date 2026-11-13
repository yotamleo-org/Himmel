import { existsSync, readFileSync, readlinkSync } from 'node:fs';
import { userInfo } from 'node:os';
import { join } from 'node:path';

export const FENCE_MARKERS = ['HIMMEL_CONSOLE_LEG', 'HIMMEL_RELEASE_MANAGER', 'HIMMEL_BRIDGE_SESSION'] as const;
export const MAX_HOPS = 64;

export function hostNsFile(): string {
  return join(passwdHome(), '.claude', 'handover', 'bridge', 'host-ns');
}

// node's userInfo() asks getpwuid; bun's follows HOME, so under bun read the root-owned passwd file.
function passwdHome(): string {
  if (!process.versions.bun) return userInfo().homedir;
  const uid = String(process.getuid?.());
  const row = read('/etc/passwd')?.split('\n').map((l) => l.split(':')).find((f) => f[2] === uid);
  if (!row?.[5]) throw new Error(`no /etc/passwd row for uid ${uid}, so bun cannot resolve host-ns without HOME; run this under node`);
  return row[5];
}

export const HOST_NS_REMEDY = 'restart the bridge, or run `bun scripts/telegram/poller.ts --write-host-ns` once on a station with no bridge';
const NS_LINE = /^pid:\[\d+\] user:\[\d+\]$/;

export function currentNs(procRoot = '/proc'): string {
  return `${readlinkSync(join(procRoot, 'self', 'ns', 'pid'))} ${readlinkSync(join(procRoot, 'self', 'ns', 'user'))}`;
}

export type FenceCheck = 'ns';

export interface WalkOpts {
  procRoot?: string;
  hostNsPath?: string;
  pid?: number;
  // Test-only: run once with a check removed to prove its row fails on that check.
  disable?: FenceCheck[];
}

export interface WalkResult {
  marker: string | null;
  stop: 'allow' | 'refuse';
  why?: string;
  farthest?: number;
}

interface Proc { uid: number | null; ppid: number | null; nspid: number; env: Map<string, string> | null }

function read(path: string): string | null {
  try {
    return readFileSync(path, 'utf8');
  } catch {
    return null;
  }
}

function field(status: string, name: string): string | null {
  const m = new RegExp(`^${name}:\\s*(.*)$`, 'm').exec(status);
  return m ? m[1].trim() : null;
}

function proc(procRoot: string, pid: number): Proc | null {
  const status = read(join(procRoot, String(pid), 'status'));
  if (status === null) return null;
  const uid = Number(field(status, 'Uid')?.split(/\s+/)[0] ?? NaN);
  const ppid = Number(field(status, 'PPid') ?? NaN);
  const raw = read(join(procRoot, String(pid), 'environ'));
  const env = raw === null ? null : new Map(raw.split('\0').filter((kv) => kv.includes('=')).map((kv) => [kv.slice(0, kv.indexOf('=')), kv.slice(kv.indexOf('=') + 1)] as [string, string]));
  return {
    uid: Number.isInteger(uid) ? uid : null,
    ppid: field(status, 'PPid') !== null && Number.isInteger(ppid) ? ppid : null,
    nspid: (field(status, 'NSpid') ?? '').split(/\s+/).filter(Boolean).length,
    env,
  };
}

const markedBy = (env: Map<string, string> | null) => FENCE_MARKERS.find((m) => env?.get(m) === '1') ?? null;

const userManagerHop = (p: Proc) => p.ppid === 1 && p.nspid === 1;

interface Trail { marker: string | null; farthest?: number; farthestEnv?: Map<string, string>; refuse?: string }

function climb(procRoot: string, start: number): Trail {
  const t: Trail = { marker: null };
  const stop = (why: string): Trail => ({ ...t, refuse: why });
  let uid: number | null = null;
  let pid = start;
  for (let hop = 0; ; hop++) {
    if (hop >= MAX_HOPS) return stop(`${MAX_HOPS} hops without reaching pid 1`);
    const p = proc(procRoot, pid);
    if (p === null) return stop(`process ${pid} cannot be read (gone mid-walk, or another uid)`);
    if (hop === 0) uid = p.uid;
    if (pid === 1) {
      const m = markedBy(p.env);
      if (m) Object.assign(t, { marker: m, farthest: 1, farthestEnv: p.env ?? undefined });
      if (p.nspid > 1) return stop('pid 1 is the root of a pid namespace');
      return t;
    }
    if (p.uid === null || p.uid !== uid) return stop(`ancestor ${pid} runs as another uid (sudo, or a root process other than pid 1); run under tmux or systemd-run --user`);
    if (p.env === null && !userManagerHop(p)) return stop(`the start-up env of ancestor ${pid} cannot be read`);
    const m = markedBy(p.env);
    if (m) Object.assign(t, { marker: m, farthest: pid, farthestEnv: p.env });
    if (p.ppid === null) return stop(`process ${pid} has no parseable PPid:`);
    if (p.ppid === 0) return stop(`the ancestry of ${start} ends at ${pid}, not at pid 1`);
    pid = p.ppid;
  }
}

function selfPid(procRoot: string): number {
  try {
    return Number(readlinkSync(join(procRoot, 'self')));
  } catch {
    return process.pid;
  }
}

export function walk(opts: WalkOpts = {}): WalkResult {
  const procRoot = opts.procRoot ?? '/proc';
  if (!existsSync(procRoot)) return { marker: null, stop: 'allow', why: `no ${procRoot}: the env check alone applies (named residual)` };
  const t = climb(procRoot, opts.pid ?? selfPid(procRoot));
  const res = (why: string): WalkResult => ({ marker: t.marker, stop: 'refuse', why, ...(t.farthest === undefined ? {} : { farthest: t.farthest }) });
  if (t.marker) return res(`${t.marker}=1 in the start-up env of ancestor ${t.farthest}${t.refuse ? `; ${t.refuse}` : ''}`);
  if (t.refuse) return res(t.refuse);
  if (opts.disable?.includes('ns')) return { marker: null, stop: 'allow' };
  const ref = read(opts.hostNsPath ?? hostNsFile())?.trim() ?? null;
  if (ref === null) return res(`host-ns is missing or unreadable; ${HOST_NS_REMEDY}`);
  if (!NS_LINE.test(ref)) return res(`host-ns is malformed; ${HOST_NS_REMEDY}`);
  let own: string;
  try {
    own = currentNs(procRoot);
  } catch {
    return res('this process\'s own namespace ids cannot be read');
  }
  if (own !== ref) return res(`this process runs in other namespaces (${own}) than the host reference (${ref}): a sandbox, an unshare or a container`);
  return { marker: null, stop: 'allow' };
}

export function ancestorValue(name: string, opts: Omit<WalkOpts, 'hostNsPath' | 'disable'> = {}): string | null {
  const procRoot = opts.procRoot ?? '/proc';
  if (!existsSync(procRoot)) return null;
  return climb(procRoot, opts.pid ?? selfPid(procRoot)).farthestEnv?.get(name) ?? null;
}
