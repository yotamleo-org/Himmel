import type { StdinData } from './types.js';
export interface EffortInfo {
    level: string;
    symbol: string;
}
export declare function resolveEffortLevel(effort: StdinData['effort'], ultracodeActive?: boolean): EffortInfo | null;
//# sourceMappingURL=effort.d.ts.map