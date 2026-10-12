import type { Frame, Layout } from './frame.js';
/**
 * `git:(main* ↑2)` or `jj:(…)`, plus the worktree name. Expanded adds line diffs;
 * compact adds Starship-style file counts instead. jj never shows git-only details.
 */
export declare function vcsPart(f: Frame, layout: Layout): string | null;
/** Recently changed files, newest first, with per-file line diffs (expanded, gitStatus.showFileStats). */
export declare function gitFilesLine(f: Frame): string | null;
//# sourceMappingURL=vcs.d.ts.map