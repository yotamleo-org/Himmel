import type { HudColorOverrides } from '../config.js';
import type { MessageKey } from '../i18n/types.js';
export interface LabelAlign {
    align?: boolean;
    /** Count the memory label too, when its bar is on screen. */
    includeMemoryInWidth?: boolean;
}
/** A bar label, padded to the widest bar label in view when bars are stacked. */
export declare function barLabel(key: MessageKey, colors?: Partial<HudColorOverrides>, options?: LabelAlign): string;
//# sourceMappingURL=labels.d.ts.map