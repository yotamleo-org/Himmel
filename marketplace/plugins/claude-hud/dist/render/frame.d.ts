import type { RenderContext } from '../types.js';
export interface Frame extends RenderContext {
    now: number;
    /** Lines wrap to this width; null when the terminal width is unknown. */
    width: number | null;
    barWidth: number;
}
export type Layout = 'expanded' | 'compact';
export declare function createFrame(ctx: RenderContext, columns: number | null, now: number): Frame;
//# sourceMappingURL=frame.d.ts.map