export type BodyInput = { format: 'markdown'; body: string } | { format: 'adf'; body: unknown };
export type Diagnostic = { rule: string; field: string; severity: 'error' | 'warning'; message: string };
export type BodyContext = { issueType?: string; labels?: readonly string[] };
export type Validation = { valid: boolean; diagnostics: Diagnostic[] };
export type Block = { kind: 'heading' | 'list' | 'prose' | 'code'; text: string; level?: number; bold?: boolean };

export declare const SECTIONS: readonly ['Impact', 'What', 'Why', 'Plan', 'DoD', 'Proof', 'Agent detail'];
export declare const METRIC_LABEL: RegExp;
export declare function renderTicketSkeleton(): string;
export declare function isWarnOnlyType(type: string | undefined): boolean;
export declare function needsMetric(labels: readonly string[] | undefined): boolean;
export declare function isPlaceholder(value: string | undefined): boolean;
export declare function normalizeMarkdown(md: string | undefined): Block[];
export declare function normalizeAdf(doc: unknown): Block[];
export declare function normalizeBody(input: BodyInput): Block[];
export declare function validateTicketBody(input: BodyInput, context?: BodyContext): Validation;
export declare function shortName(d: Diagnostic): string;
export declare function labelsMismatch(given: readonly string[] | undefined, draftLine: readonly string[] | undefined, issueType?: string): Diagnostic | undefined;
export declare function draftLabels(md: string): string[] | undefined;
