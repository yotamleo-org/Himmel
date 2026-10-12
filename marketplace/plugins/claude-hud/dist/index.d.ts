import { type GitRepoIdentity, type GitStatus } from "./git.js";
import { type HudConfig } from "./config.js";
export declare function isHudDisabled(env?: NodeJS.ProcessEnv): boolean;
export declare function resolveVcsStatus(config: HudConfig, cwd?: string, repo?: GitRepoIdentity | null): Promise<GitStatus | null>;
export declare function main(): Promise<void>;
//# sourceMappingURL=index.d.ts.map