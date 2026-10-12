import type { RenderContext } from '../types.js';
import { type ContextUsage } from '../stdin.js';
import { type EffortInfo } from '../effort.js';
export declare const contextUsage: (ctx: RenderContext) => ContextUsage;
export declare const sessionName: (ctx: RenderContext) => string | undefined;
export declare const claudeCodeVersion: (ctx: RenderContext) => string | undefined;
export declare const outputStyle: (ctx: RenderContext) => string | undefined;
export declare const sessionDuration: (ctx: RenderContext) => string;
export declare const effort: (ctx: RenderContext) => EffortInfo | null;
export declare const sessionCostUsd: (ctx: RenderContext) => number | null;
//# sourceMappingURL=derive.d.ts.map