import type { StdinData } from './types.js';
export type ContextCacheDeps = {
    homeDir: string;
    now: number;
    random: number;
};
export declare function contextCachePath(homeDir: string, transcriptPath: string): string;
/** Persist this session's context snapshot. Never throws: rendering must not block on it. */
export declare function writeContextSnapshot(stdin: StdinData, overrides?: Partial<ContextCacheDeps>): void;
//# sourceMappingURL=context-cache.d.ts.map