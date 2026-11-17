import { createHash } from 'node:crypto';
import { closeSync, constants, fstatSync, openSync, readSync } from 'node:fs';

const PINNED_MAX = 16 * 1024 * 1024;
export type Pinned = { bytes: Buffer; sha256: string } | { missing: true } | { unreadable: true };

// A pinned file is read once from one non-blocking fd: a FIFO, a device, a directory or a file over 16 MiB
// is unreadable, so a planted path never blocks the reader nor costs it more than 16 MiB.
export function pinnedSha(path: string): Pinned {
  let fd: number;
  try {
    fd = openSync(path, constants.O_RDONLY | constants.O_NONBLOCK);
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === 'ENOENT' ? { missing: true } : { unreadable: true };
  }
  try {
    const st = fstatSync(fd);
    if (!st.isFile() || st.size > PINNED_MAX) return { unreadable: true };
    const buf = Buffer.alloc(st.size + 1);
    let n = 0;
    for (let r = 1; r > 0 && n < buf.length; n += r) r = readSync(fd, buf, n, buf.length - n, null);
    if (n > st.size) return { unreadable: true };
    const bytes = buf.subarray(0, n);
    return { bytes, sha256: createHash('sha256').update(bytes).digest('hex') };
  } catch {
    return { unreadable: true };
  } finally {
    closeSync(fd);
  }
}

const REVIEWED = /^Reviewed: spec ([0-9a-f]{64})\b/gm;

export function reviewedSpecHashes(text: string): string[] {
  return [...text.matchAll(REVIEWED)].map((m) => m[1]);
}
