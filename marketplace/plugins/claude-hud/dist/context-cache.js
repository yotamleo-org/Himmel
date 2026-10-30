// himmel delta (HIMMEL-4578): write-only port of the v0.9.0 context snapshot writer.
// Upstream v0.10.0 deleted it, but scripts/context-fill.sh (the console handover
// trigger, the worker context guard and arm-resume) reads
// <config>/plugins/claude-hud/context-cache/<sha256(transcript)>.json, so the
// path, field names and types below must stay byte-compatible with that reader.
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { createHash } from 'node:crypto';
import { getHudPluginDir } from './claude-config-dir.js';
import { getTotalTokens } from './stdin.js';
const CACHE_DIRNAME = 'context-cache';
const WRITE_TTL_MS = 3_000;
const MAX_CACHE_AGE_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_CACHE_ENTRIES = 100;
const SWEEP_SAMPLE_RATE = 0.01;
function cacheDir(homeDir) {
    return path.join(getHudPluginDir(homeDir), CACHE_DIRNAME);
}
export function contextCachePath(homeDir, transcriptPath) {
    const hash = createHash('sha256').update(path.resolve(transcriptPath)).digest('hex');
    return path.join(cacheDir(homeDir), `${hash}.json`);
}
function isAllUsageZero(usage) {
    if (!usage)
        return true;
    return (usage.input_tokens ?? 0) === 0
        && (usage.output_tokens ?? 0) === 0
        && (usage.cache_creation_input_tokens ?? 0) === 0
        && (usage.cache_read_input_tokens ?? 0) === 0;
}
// The frame worth persisting: a genuine reading, or one derived from current_usage when
// Claude Code reports 0% mid-tick. Null for a fresh or just-compacted session.
function cacheableFrame(stdin, contextWindow) {
    const size = contextWindow.context_window_size ?? 0;
    const used = contextWindow.used_percentage;
    if (size > 0 && typeof used === 'number' && used > 0)
        return contextWindow;
    if ((used ?? 0) !== 0 || isAllUsageZero(contextWindow.current_usage) || size <= 0)
        return null;
    const derived = Math.min(100, Math.round((getTotalTokens(stdin) / size) * 100));
    return { ...contextWindow, used_percentage: derived, remaining_percentage: 100 - derived };
}
function sweep(dir, now) {
    try {
        const survivors = [];
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            if (!entry.isFile() || !entry.name.endsWith('.json'))
                continue;
            const file = path.join(dir, entry.name);
            try {
                const { mtimeMs } = fs.statSync(file);
                if (now - mtimeMs > MAX_CACHE_AGE_MS)
                    fs.unlinkSync(file);
                else
                    survivors.push({ file, mtimeMs });
            }
            catch { /* per-file failures never block a render */ }
        }
        survivors.sort((a, b) => a.mtimeMs - b.mtimeMs);
        for (const { file } of survivors.slice(0, Math.max(0, survivors.length - MAX_CACHE_ENTRIES))) {
            try {
                fs.unlinkSync(file);
            }
            catch { /* best effort */ }
        }
    }
    catch { /* directory missing or unreadable */ }
}
/** Persist this session's context snapshot. Never throws: rendering must not block on it. */
export function writeContextSnapshot(stdin, overrides = {}) {
    try {
        const contextWindow = stdin.context_window;
        const transcriptPath = stdin.transcript_path?.trim();
        if (!contextWindow || !transcriptPath)
            return;
        const frame = cacheableFrame(stdin, contextWindow);
        if (!frame)
            return;
        const homeDir = overrides.homeDir ?? os.homedir();
        const now = overrides.now ?? Date.now();
        const file = contextCachePath(homeDir, transcriptPath);
        try {
            if (now - fs.statSync(file).mtimeMs < WRITE_TTL_MS)
                return;
        }
        catch { /* no snapshot yet */ }
        const dir = path.dirname(file);
        fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
        const payload = {
            used_percentage: frame.used_percentage ?? 0,
            remaining_percentage: frame.remaining_percentage ?? null,
            current_usage: frame.current_usage ?? null,
            context_window_size: frame.context_window_size ?? null,
            saved_at: now,
            session_name: stdin.session_name ?? null,
        };
        fs.writeFileSync(file, JSON.stringify(payload), { encoding: 'utf8', mode: 0o600 });
        fs.utimesSync(file, now / 1000, now / 1000);
        if ((overrides.random ?? Math.random()) < SWEEP_SAMPLE_RATE)
            sweep(dir, now);
    }
    catch { /* best effort */ }
}
//# sourceMappingURL=context-cache.js.map