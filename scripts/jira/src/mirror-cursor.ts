import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export const CURSOR_FILE = '.cursor.json';

export interface Cursor {
  lastSync: string;
  total: number;
  project?: string;
  complete?: boolean;
  repair?: 'incremental' | 'full';
}

export interface MirrorState {
  complete: 'yes' | 'no' | 'none';
  repair: 'incremental' | 'full' | null;
  lastSync: string | null;
  project: string | null;
  next: 'incremental' | 'full';
  repairable: boolean;
}

export function readCursor(root: string | null): Cursor | null {
  if (!root) return null;
  try {
    const c = JSON.parse(readFileSync(join(root, CURSOR_FILE), 'utf8')) as Cursor;
    return c && typeof c.lastSync === 'string' && !Number.isNaN(Date.parse(c.lastSync)) ? c : null;
  } catch {
    return null;
  }
}

export function mirrorState(root: string | null, project?: string): MirrorState {
  const c = readCursor(root);
  if (!c) return { complete: 'none', repair: null, lastSync: null, project: null, next: 'full', repairable: false };
  const complete = c.complete === undefined ? 'yes' : 'no';
  const repair = complete === 'yes' ? null : c.repair === 'full' ? 'full' : 'incremental';
  const other = project !== undefined && c.project !== undefined && c.project !== project;
  const next = other || repair === 'full' ? 'full' : 'incremental';
  return { complete, repair, lastSync: c.lastSync, project: c.project ?? null, next, repairable: complete === 'no' && next === 'incremental' };
}
