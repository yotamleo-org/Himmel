import type { Frame } from './frame.js';
import { type LabelAlign } from './labels.js';
/** Config counts, output style, and failing MCP servers. */
export declare function environmentLine(f: Frame): string | null;
export declare function promptCacheLine(f: Frame): string | null;
export declare function cacheHitRateLine(f: Frame): string | null;
/** `Started: 2026-10-01 11:00 │ Last reply: 1m ago`. */
export declare function sessionTimeLine(f: Frame): string | null;
/** Approximate system RAM (expanded only). */
export declare function memoryLine(f: Frame, align?: LabelAlign): string | null;
/** Added dirs on their own line, when addedDirsLayout is "line". */
export declare function addedDirsLine(f: Frame): string | null;
//# sourceMappingURL=lines.d.ts.map