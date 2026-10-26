/** Untrusted text made safe to print: no escape sequences, controls, or bidi overrides. */
export declare function sanitizeDisplayText(input: string): string;
/** An untrusted value as a printable label: sanitized, trimmed, and cut on a grapheme boundary. '' if not a string. */
export declare function displayLabel(value: unknown, maxLength: number, suffix?: string): string;
//# sourceMappingURL=sanitize.d.ts.map