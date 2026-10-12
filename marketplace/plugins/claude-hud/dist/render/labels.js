import { t } from '../i18n/index.js';
import { label } from './colors.js';
import { textWidth } from './ansi.js';
const BAR_LABELS = ['label.context', 'label.usage', 'label.weekly'];
/** A bar label, padded to the widest bar label in view when bars are stacked. */
export function barLabel(key, colors, options = {}) {
    const text = t(key);
    if (!options.align)
        return label(text, colors);
    const keys = options.includeMemoryInWidth ? [...BAR_LABELS, 'label.approxRam'] : BAR_LABELS;
    const pad = Math.max(...keys.map((k) => textWidth(t(k)))) - textWidth(text);
    return label(pad > 0 ? text + ' '.repeat(pad) : text, colors);
}
//# sourceMappingURL=labels.js.map