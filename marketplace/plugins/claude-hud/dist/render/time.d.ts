import type { HourCycleMode, HudConfig, TimeFormatMode } from '../config.js';
import type { MessageKey } from '../i18n/types.js';
interface WallClockOptions {
    hourCycle: HourCycleMode;
    showSeconds: boolean;
}
export declare function wallClock(display: Partial<HudConfig['display']> | undefined): WallClockOptions;
/** Wall-clock time such as `at 14:30`, with the date when it isn't today. */
export declare function formatAbsoluteTime(at: Date, now: Date, opts: WallClockOptions, pattern?: MessageKey): string;
/** `2h 30m`, `at 14:30`, or both. Empty when the reset is unknown or already past. */
export declare function formatResetTime(resetAt: Date | null, mode: 'relative' | 'absolute' | 'both', opts: WallClockOptions, now: number): string;
/** A usage window's time in the configured format, including the elapsed-share modes. */
export declare function formatWindowTime(resetAt: Date | null, windowMs: number, timeFormat: TimeFormatMode, opts: WallClockOptions, now: number): string;
/** The reset format for a limit-reached notice, which has no elapsed share to show. */
export declare function limitTimeFormat(timeFormat: TimeFormatMode): 'relative' | 'absolute' | 'both';
/** `45s ago`, `2h 5m ago`, `3d 4h ago`. */
export declare function formatAgo(ms: number): string;
export {};
//# sourceMappingURL=time.d.ts.map