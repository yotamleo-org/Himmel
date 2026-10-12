import { DEFAULT_PROJECT_LINE_ORDER } from '../config.js';
import { t } from '../i18n/index.js';
import { activityLine } from './activity.js';
import { separatorLine, visibleWidth } from './ansi.js';
import { contextBarAndValue, tokenBreakdown } from './context.js';
import { cacheHitRateLine, promptCacheLine, sessionTimeLine } from './lines.js';
import { orderParts } from './order.js';
import { advisorPart, authPart, compactionsPart, configCountParts, costPart, customLinePart, durationPart, extraPart, modelBadge, projectParts, sessionNamePart, sessionTokensSummary, speedPart, versionPart, } from './parts.js';
import { usageParts } from './usage.js';
const ACTIVITY = ['tools', 'skills', 'mcp', 'agents', 'todos'];
// The context bar rides with the model badge, so the cluster moves as the 'model' segment.
function modelCluster(f) {
    const display = f.config?.display;
    const { bar, value } = contextBarAndValue(f);
    return [display?.showModel !== false ? modelBadge(f) : null, bar, value].filter(Boolean).join(' ');
}
function sessionLine(f) {
    const parts = [];
    const add = (text, key = null) => {
        if (text)
            parts.push({ key, text });
    };
    add(customLinePart(f, 'first'));
    add(modelCluster(f), 'model');
    for (const part of projectParts(f, 'compact'))
        add(part, 'project');
    add(sessionNamePart(f), 'sessionName');
    add(versionPart(f), 'version');
    configCountParts(f).forEach((part) => add(part));
    (usageParts(f, 'compact') ?? []).forEach((part) => add(part));
    if (f.config?.display?.showSessionTokens)
        add(sessionTokensSummary(f, `${t('format.tok')}:`));
    add(compactionsPart(f));
    add(advisorPart(f), 'advisor');
    add(durationPart(f), 'duration');
    add(sessionTimeLine(f));
    add(promptCacheLine(f));
    add(cacheHitRateLine(f));
    add(costPart(f), 'cost');
    add(speedPart(f), 'speed');
    add(extraPart(f), 'extra');
    add(authPart(f), 'auth');
    add(customLinePart(f, 'last'));
    const line = orderParts(parts, f.config?.projectLineOrder ?? DEFAULT_PROJECT_LINE_ORDER).join(' | ');
    return line + tokenBreakdown(f);
}
/** The compact layout: one session line, then the activity lines. */
export function compactLines(f) {
    const header = sessionLine(f);
    const activity = ACTIVITY.map((element) => activityLine(f, element)).filter((line) => !!line);
    const lines = [header];
    if (f.config?.showSeparators && activity.length > 0) {
        const widest = Math.max(visibleWidth(header), 20);
        lines.push(separatorLine(f.width ? Math.min(widest, f.width) : widest));
    }
    // himmel delta: display.customLineCommand's multiline stdout, appended last.
    return [...lines, ...activity, ...(f.customLines ?? [])];
}
//# sourceMappingURL=compact.js.map