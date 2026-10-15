// fixture: two identical unscrubbed git calls on ONE line. A baseline entry
// grandfathers one call, never both (per-line dedup would let
// the second ride along).
import { execFileSync } from 'node:child_process';

export function both(r) {
  return [execFileSync('git', ['-C', r, 'status']), execFileSync('git', ['-C', r, 'status'])];
}
