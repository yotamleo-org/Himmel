export function createFrame(ctx, columns, now) {
    const maxWidth = ctx.config?.maxWidth ?? null;
    const width = ctx.config?.forceMaxWidth && maxWidth !== null ? maxWidth : columns ?? maxWidth;
    const barWidth = columns === null || columns >= 100 ? 10 : columns >= 60 ? 6 : 4;
    return { ...ctx, now, width, barWidth };
}
//# sourceMappingURL=frame.js.map