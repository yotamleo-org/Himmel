// fixture: two identical unscrubbed git calls on ONE line. A baseline entry
// grandfathers one call, never both (HIMMEL-5393 codex-3: per-line dedup let
// the second ride along).
import { execFileSync } from 'node:child_process';

export function both(r) {
  return [execFileSync('git', ['-C', r, 'status']), execFileSync('git', ['-C', r, 'status'])];
}
