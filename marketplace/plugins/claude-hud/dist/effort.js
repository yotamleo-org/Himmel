import { stdinText } from './stdin.js';
const SYMBOLS = {
    low: '○',
    medium: '◔',
    high: '◑',
    xhigh: '◕',
    max: '●',
};
// stdin reports ultracode as an ordinary level, so the transcript marker is what
// distinguishes it; the reported level is wrapped rather than assumed.
export function resolveEffortLevel(effort, ultracodeActive) {
    const level = stdinText(effort?.level, 32)?.toLowerCase();
    if (!level) {
        return null;
    }
    const symbol = SYMBOLS[level] ?? '';
    return ultracodeActive === true ? { level: `ultracode(${level})`, symbol } : { level, symbol };
}
//# sourceMappingURL=effort.js.map