import type { Admission } from '../commands/admissions-ledger.js';

const KEY = /^[A-Z][A-Z0-9]*-\d+$/;

// The key's latest row decides: a deferral or removal after an admission withdraws it.
// A row keyed by a check id (a version-ready override) is not an admission.
// With `kinds`, only a row of one of those kinds admits (a gate row has no kind, so it never does).
export const admits = (row: Admission | undefined, kinds?: ReadonlySet<string>): boolean =>
  row !== undefined && row.kind !== 'deferral' && row.kind !== 'rm-remove' && KEY.test(row.key)
  && (kinds === undefined || (row.kind !== undefined && kinds.has(row.kind)));
