import type { Frame, Layout } from './frame.js';
import { type LabelAlign } from './labels.js';
/**
 * The usage windows as separator-joined parts. Expanded joins them into one line;
 * compact lays them out with the rest of its line and leaves `Usage` off the
 * limit, weekly-only, and below-threshold parts.
 */
export declare function usageParts(f: Frame, layout: Layout, align?: LabelAlign): string[] | null;
//# sourceMappingURL=usage.d.ts.map