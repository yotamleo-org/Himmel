import type { Frame } from './frame.js';
import { type LabelAlign } from './labels.js';
/** The context bar (when shown) and value, e.g. `█████░░░░░ 45%`. */
export declare function contextBarAndValue(f: Frame): {
    bar: string | null;
    value: string;
};
/** ` (in: 12k, cache: 180k)` once context reaches the critical threshold. */
export declare function tokenBreakdown(f: Frame): string;
export declare function contextLine(f: Frame, align?: LabelAlign): string;
//# sourceMappingURL=context.d.ts.map