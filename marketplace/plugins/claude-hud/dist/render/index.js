import { getTerminalWidth } from '../utils/terminal.js';
import { RESET } from './colors.js';
import { wrapToWidth } from './ansi.js';
import { compactLines } from './compact.js';
import { expandedLines } from './expanded.js';
import { createFrame } from './frame.js';
/** The lines the HUD prints, wrapped to the terminal width when it is known. */
export function renderLines(ctx, columns, now) {
    const frame = createFrame(ctx, columns, now);
    const lines = (ctx.config?.lineLayout ?? 'expanded') === 'expanded' ? expandedLines(frame) : compactLines(frame);
    return lines
        .flatMap((line) => line.split('\n'))
        .flatMap((line) => wrapToWidth(line, frame.width ?? 0))
        .map((line) => `${RESET}${line}`);
}
export function render(ctx) {
    for (const line of renderLines(ctx, getTerminalWidth(), Date.now()))
        console.log(line);
}
//# sourceMappingURL=index.js.map