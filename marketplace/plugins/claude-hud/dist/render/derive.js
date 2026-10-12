import { getContextUsage, stdinText } from '../stdin.js';
import { resolveEffortLevel } from '../effort.js';
import { getNativeCostUsd } from '../cost.js';
import { formatSessionDuration } from '../utils/format.js';
// Values computed from the render context alone, without I/O.
export const contextUsage = (ctx) => getContextUsage(ctx.stdin, ctx.config?.display?.autoCompactWindow, ctx.transcript?.contextTokens);
export const sessionName = (ctx) => stdinText(ctx.stdin.session_name);
export const claudeCodeVersion = (ctx) => stdinText(ctx.stdin.version, 32);
export const outputStyle = (ctx) => stdinText(ctx.stdin.output_style?.name, 40);
export const sessionDuration = (ctx) => formatSessionDuration(ctx.stdin.cost?.total_duration_ms);
export const effort = (ctx) => resolveEffortLevel(ctx.stdin.effort, ctx.transcript?.ultracodeActive);
export const sessionCostUsd = (ctx) => getNativeCostUsd(ctx.stdin, { allowRoutedCost: ctx.config?.display?.showRoutedCost === true });
//# sourceMappingURL=derive.js.map