import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { earlierThan } from './door.js';
import { keyNewestDecision, releaseForProject, type DeclaredRelease } from './engine.js';
import { loadKey, readChain } from './ledger.js';
import { releaseKeyPath, releaseRoot } from './paths.js';
import { scopeOk } from './reducer.js';
import type { Op, OperatorRow } from './types.js';

export interface Leave { by: string; op?: Op }

export type LeaveVerdict = { ok: true } | { ok: false; reason: string };

const FOLDS = new Set(['rm-apply', 'transition-stamp', 'merge-stamp']);

export function leaveCheck(o: { key: string; before: string[]; after: string[] | null; mechanism: string;
  leave?: Leave; ownAdds: Set<string>; decls: DeclaredRelease[] | 'unreadable';
  ops: Map<string, Map<string, OperatorRow> | 'unreadable'>;
  released: Set<string> | 'unreadable' }): LeaveVerdict {
  const { key, after } = o;
  const refuse = (why: string): LeaveVerdict => ({ ok: false, reason: `${key}: the Fix Version write is refused, nothing was written: ${why}` });
  if (after !== null && o.before.every((v) => after.includes(v))) return { ok: true };
  if (o.decls === 'unreadable') {
    return refuse('the declared releases cannot be read (set USER_SLUG as the launcher does, or HIMMEL_RELEASE_STATE_DIR, and check that each release.json parses and verifies), so no version may be removed');
  }
  const decls = o.decls;
  const declared = (v: string) => decls.some((d) => d.versions.includes(v));
  const held = o.before.filter(declared);
  if (held.length === 0) return { ok: true };
  if (o.released === 'unreadable') return refuse(`the versions file cannot be read, so whether ${held.join(', ')} is released is unknown`);
  const released = o.released;
  const open = (v: string) => declared(v) && !released.has(v);
  const openHeld = held.filter(open);
  if (after === null) {
    return openHeld.length ? refuse(`the body names its versions in a shape this check cannot read while ${key} holds the open version ${openHeld.join(', ')}`) : { ok: true };
  }
  for (const v of openHeld.filter((x) => !after.includes(x))) {
    const why = exitRefusal(o, v, after, open);
    if (why) return refuse(why);
  }
  return { ok: true };
}

function exitRefusal(o: Parameters<typeof leaveCheck>[0], v: string, after: string[], open: (v: string) => boolean): string | null {
  if (o.ownAdds.has(v)) return null;
  const holders = (o.decls as DeclaredRelease[]).filter((d) => d.versions.includes(v));
  const targets = after.filter(open);
  const moves: Op[] = targets.map((t) => ({ kind: 'move', from_v: v, to_v: t }));
  const candidates: Op[] = targets.length ? moves : [{ kind: 'remove', from_v: v, to_v: null }, { kind: 'move', from_v: v, to_v: null }];
  if (FOLDS.has(o.mechanism) && targets.some((t) => holders.some((d) => t === d.current || (d.versions.includes(t) && earlierThan(d, t, v))))) return null;
  const ways = `pass --by <O-id> naming the operator record that takes ${o.key} out of ${v}, or ask for a move toward current with \`jira release request <R> --verb REVERSION --key ${o.key} --from ${v} --to <version> --why "<line>" --chief-reason "<reason>"\``;
  if (!o.leave) return `it takes ${o.key} out of the open version ${v} with no operator record; ${ways}`;
  const by = o.leave.by;
  const asked = o.leave.op && o.leave.op.from_v === v ? [o.leave.op] : candidates;
  for (const d of holders) {
    const ops = o.ops.get(d.release);
    if (ops === undefined || ops === 'unreadable') return `the operator chain of ${d.release} cannot be read, so --by ${by} cannot be checked`;
    if (!ops.has(by)) continue;
    const newest = keyNewestDecision([...ops.values()], o.key);
    if (newest?.id !== by) return `${by} is not the newest operator decision on ${o.key} (${newest ? newest.id : 'none'} is); ${ways}`;
    if (asked.some((op) => scopeOk({ authority: { kind: 'operator', ref: by }, key: o.key, op }, ops, d.current))) return null;
    return `${by} does not cover ${asked.map((op) => `${op.kind} ${op.from_v ?? 'backlog'}→${op.to_v ?? 'backlog'}`).join(' or ')} on ${o.key}; ${ways}`;
  }
  return `no declared release holding ${v} has the record ${by}; ${ways}`;
}

const mirrorVersions = (project: string): string => join(homedir(), '.himmel', 'state', 'jira-mirror', `${project}.versions.tsv`);

function releasedOf(project: string): Set<string> | 'unreadable' {
  const path = mirrorVersions(project);
  if (!existsSync(path)) return 'unreadable';
  try {
    return new Set(readFileSync(path, 'utf8').split('\n').map((l) => l.split('\t')).filter((p) => p.length >= 2 && p[1].trim() === 'true').map((p) => p[0]));
  } catch {
    return 'unreadable';
  }
}

function operatorOf(release: string, env: Record<string, string | undefined>): Map<string, OperatorRow> | 'unreadable' {
  try {
    const chain = readChain<OperatorRow>(join(releaseRoot(env), release, 'operator.jsonl'), loadKey(releaseKeyPath(release, env)));
    if (chain.bad.length) return 'unreadable';
    return new Map(chain.verified.map((r) => [r.id, r]));
  } catch {
    return 'unreadable';
  }
}

const projectOf = (key: string): string => key.slice(0, key.lastIndexOf('-'));

export const declsFor = (key: string, env: Record<string, string | undefined> = process.env): DeclaredRelease[] | 'unreadable' =>
  releaseForProject(env, projectOf(key));

export function leaveGate(o: { key: string; before: string[]; after: string[] | null; mechanism: string; leave?: Leave; ownAdds: Set<string> },
  decls: DeclaredRelease[] | 'unreadable', env: Record<string, string | undefined> = process.env): LeaveVerdict {
  if (o.after !== null && o.before.every((v) => (o.after as string[]).includes(v))) return { ok: true };
  const project = projectOf(o.key);
  const ops = new Map<string, Map<string, OperatorRow> | 'unreadable'>();
  if (o.leave && decls !== 'unreadable') for (const d of decls) ops.set(d.release, operatorOf(d.release, env));
  const released = decls === 'unreadable' || decls.length === 0 ? new Set<string>() : releasedOf(project);
  return leaveCheck({ ...o, decls, ops, released });
}
