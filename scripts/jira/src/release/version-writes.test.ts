import { describe, it, expect } from 'vitest';
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), 'fixtures', 'repair');

const TOP_KEYS = new Set(['key', 'source', 'journalSynthesized', 'journal', 'changelog']);
const ENTRY_KEYS = new Set(['id', 'created', 'items']);
const FIX_ITEM_KEYS = new Set(['field', 'fromString', 'toString']);

const filesIn = (dir: string): string[] => readdirSync(dir).filter((n) => n.endsWith('.json')).sort();

// Names the first author-data hit in any file of `dir`, or null.
function authorData(dir: string): string | null {
  for (const name of filesIn(dir)) {
    const text = readFileSync(join(dir, name), 'utf8');
    for (const needle of ['@', 'emailAddress', 'accountId']) if (text.includes(needle)) return `${name}: ${needle}`;
  }
  return null;
}

// Names the first changelog key or item outside the allowlist in any file of `dir`, or null.
function outsideAllowlist(dir: string): string | null {
  for (const name of filesIn(dir)) {
    const f = JSON.parse(readFileSync(join(dir, name), 'utf8')) as Record<string, unknown>;
    for (const k of Object.keys(f)) if (!TOP_KEYS.has(k)) return `${name}: top-level ${k}`;
    for (const e of f.changelog as Array<Record<string, unknown>>) {
      for (const k of Object.keys(e)) if (!ENTRY_KEYS.has(k)) return `${name}: entry ${k}`;
      for (const item of e.items as Array<Record<string, unknown>>) {
        if (item.field === 'other') {
          if (Object.keys(item).length !== 1) return `${name}: other item carries ${Object.keys(item).join(',')}`;
        } else if (item.field === 'Fix Version') {
          for (const k of Object.keys(item)) if (!FIX_ITEM_KEYS.has(k)) return `${name}: Fix Version item ${k}`;
        } else return `${name}: item field ${String(item.field)}`;
      }
    }
  }
  return null;
}

describe('repair fixtures (HIMMEL-8724 S0)', () => {
  it('the six captured tickets are present', () => {
    expect(filesIn(FIXTURES)).toEqual(['HIMMEL-3084.json', 'HIMMEL-6691.json', 'HIMMEL-7044.json', 'HIMMEL-7804.json', 'HIMMEL-8231.json', 'HIMMEL-8706.json']);
  });

  it('fixtures carry no author data', () => {
    expect(authorData(FIXTURES)).toBeNull();
  });

  it('fixtures carry only allowed fields', () => {
    expect(outsideAllowlist(FIXTURES)).toBeNull();
  });

  it('the checks fail on a fixture that does carry author data or another field', () => {
    const dir = mkdtempSync(join(tmpdir(), 'repair-fixtures-'));
    writeFileSync(join(dir, 'HIMMEL-1.json'), JSON.stringify({
      key: 'HIMMEL-1', source: 's', journalSynthesized: false, journal: [],
      changelog: [{ id: '1', created: 'c', author: { emailAddress: 'a' + '@' + 'b.c' }, items: [{ field: 'summary', toString: 'free text' }] }],
    }));
    expect(authorData(dir)).toMatch(/HIMMEL-1\.json/);
    expect(outsideAllowlist(dir)).toBe('HIMMEL-1.json: entry author');
  });
});
