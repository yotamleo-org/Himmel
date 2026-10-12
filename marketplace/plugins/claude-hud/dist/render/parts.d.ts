import type { FirstLineSegment } from '../config.js';
import type { Frame, Layout } from './frame.js';
/** A first-line part; `key` lets projectLineOrder move it, null keeps its slot. */
export interface Part {
    key: FirstLineSegment | null;
    text: string;
}
/** `[Opus 5.5 ◑ high | Bedrock]`, or with the provider first when showProvider is on. */
export declare function modelBadge(f: Frame): string;
/** Linked added-dir names, capped at five; `prefix` is the inline `+`. */
export declare function addedDirs(f: Frame, prefix: string, joiner: string): string | null;
/**
 * The project path with its VCS segment, as one part or, with
 * branchOverflow "wrap", two. Expanded links the path and inlines added dirs.
 */
export declare function projectParts(f: Frame, layout: Layout): string[];
export declare function advisorPart(f: Frame): string | null;
export declare function sessionNamePart(f: Frame): string | null;
export declare function versionPart(f: Frame): string | null;
export declare function durationPart(f: Frame): string | null;
export declare function extraPart(f: Frame): string | null;
/** `Cost $1.23 | Today $4.56 | Week $12.00`, one dim span. */
export declare function costPart(f: Frame): string | null;
export declare function speedPart(f: Frame): string | null;
export declare function authPart(f: Frame): string | null;
export declare function customLinePart(f: Frame, position: 'first' | 'last'): string | null;
/** `2 CLAUDE.md`, `3 rules`, `4 MCPs`, `1 hooks`, once their total reaches environmentThreshold. */
export declare function configCountParts(f: Frame, mcpSuffix?: string): string[];
/** `Tokens 262k (in: 6k, out: 2k, cache: 254k)` from the transcript's session totals. */
export declare function sessionTokensSummary(f: Frame, prefix: string): string | null;
export declare function compactionsPart(f: Frame): string | null;
//# sourceMappingURL=parts.d.ts.map