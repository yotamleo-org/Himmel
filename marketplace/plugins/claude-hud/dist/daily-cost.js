import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { getHudPluginDir } from './claude-config-dir.js';
import { getNativeCostUsd } from './cost.js';
import { createDebug } from './debug.js';
import { SEVEN_DAY_WINDOW_MS } from './usage-pace.js';
const debug = createDebug('daily-cost');
// Content changes always write; renders that only refresh last-seen times are throttled.
export const DAILY_COST_WRITE_THROTTLE_MS = 30_000;
const SESSION_MAX_AGE_MS = 24 * 60 * 60 * 1000;
// An update takes a few milliseconds, so a lock older than this belongs to a crashed process.
const LOCK_STALE_MS = 2_000;
const LOCK_WAIT_MS = 500;
const LOCK_RETRY_MS = 10;
const defaultDeps = {
    homeDir: () => os.homedir(),
    now: () => Date.now(),
};
export function getDailyCostLedgerPath(homeDir) {
    return path.join(getHudPluginDir(homeDir), 'daily-cost.json');
}
function localDateKey(now) {
    const date = new Date(now);
    return `${date.getFullYear()}${String(date.getMonth() + 1).padStart(2, '0')}${String(date.getDate()).padStart(2, '0')}`;
}
const isAmount = (value) => typeof value === 'number' && Number.isFinite(value) && value >= 0;
const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
function readLedger(ledgerPath) {
    try {
        const value = JSON.parse(fs.readFileSync(ledgerPath, 'utf8'));
        if (!isObject(value) || typeof value.date !== 'string' || !/^\d{8}$/.test(value.date) || !isObject(value.sessions)) {
            return null;
        }
        const sessions = {};
        for (const [id, raw] of Object.entries(value.sessions)) {
            if (!isObject(raw) || !isAmount(raw.baseline) || !isAmount(raw.total) || !isAmount(raw.ts) || raw.ts === 0)
                continue;
            // Ledgers written before weekly totals have no weekBaseline.
            const weekBaseline = isAmount(raw.weekBaseline) ? raw.weekBaseline : raw.baseline;
            sessions[id] = { baseline: raw.baseline, weekBaseline, total: raw.total, ts: raw.ts };
        }
        const week = isObject(value.week) ? value.week : {};
        return {
            date: value.date,
            sessions,
            week: { start: isAmount(week.start) ? week.start : 0, carry: isAmount(week.carry) ? week.carry : 0 },
        };
    }
    catch (err) {
        if (err.code !== 'ENOENT') {
            debug('Failed to read ledger (starting fresh):', err instanceof Error ? err.message : err);
        }
        return null;
    }
}
function isThrottled(ledgerPath, now) {
    try {
        return now - fs.statSync(ledgerPath).mtimeMs <= DAILY_COST_WRITE_THROTTLE_MS;
    }
    catch {
        return false;
    }
}
function writeLedger(ledgerPath, ledger, now) {
    const tmpPath = `${ledgerPath}.${process.pid}.${now}.tmp`;
    try {
        fs.mkdirSync(path.dirname(ledgerPath), { recursive: true, mode: 0o700 });
        fs.writeFileSync(tmpPath, `${JSON.stringify(ledger, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
        fs.renameSync(tmpPath, ledgerPath);
        // The throttle reads mtime, so stamp it with the caller's clock.
        fs.utimesSync(ledgerPath, new Date(now), new Date(now));
    }
    catch (err) {
        debug('Failed to write ledger:', err instanceof Error ? err.message : err);
        try {
            fs.rmSync(tmpPath, { force: true });
        }
        catch {
            // Nothing left to clean up.
        }
    }
}
// Renders run in separate processes that share one ledger. The rename in writeLedger keeps
// the file whole, but two overlapping read-modify-write cycles still drop the earlier
// writer's changes, including a whole new session and its baseline. A lock file taken with
// O_EXCL makes each cycle run alone. The clock here is the real one, since `deps.now` is
// the caller's logical time. If the lock can't be taken, the update goes ahead without it.
function withLedgerLock(ledgerPath, update) {
    const lockPath = `${ledgerPath}.lock`;
    const deadline = Date.now() + LOCK_WAIT_MS;
    let held = false;
    try {
        fs.mkdirSync(path.dirname(ledgerPath), { recursive: true, mode: 0o700 });
        while (!held) {
            try {
                fs.closeSync(fs.openSync(lockPath, 'wx', 0o600));
                held = true;
            }
            catch (err) {
                if (err.code !== 'EEXIST')
                    throw err;
                try {
                    if (Date.now() - fs.statSync(lockPath).mtimeMs > LOCK_STALE_MS)
                        fs.rmSync(lockPath, { force: true });
                }
                catch {
                    // The holder released it between the two calls; try again.
                }
                if (Date.now() >= deadline)
                    throw new Error('timed out waiting for the ledger lock');
                Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, LOCK_RETRY_MS);
            }
        }
    }
    catch (err) {
        debug('Updating the ledger without a lock:', err instanceof Error ? err.message : err);
    }
    try {
        return update();
    }
    finally {
        if (held)
            fs.rmSync(lockPath, { force: true });
    }
}
// Folds the session's native cost into the ledger and returns today's and this
// week's spend across sessions, or null when nothing has been recorded.
export function getCostTotals(stdin, options, deps = defaultDeps) {
    const ledgerPath = getDailyCostLedgerPath(deps.homeDir());
    return withLedgerLock(ledgerPath, () => updateLedger(ledgerPath, stdin, options, deps));
}
function updateLedger(ledgerPath, stdin, options, deps) {
    const now = deps.now();
    const today = localDateKey(now);
    const stored = readLedger(ledgerPath);
    const ledger = stored ?? { date: today, sessions: {}, week: { start: now, carry: 0 } };
    let changed = stored === null;
    // Sessions unseen for a day leave the ledger, but their spend stays inside the week.
    for (const [id, session] of Object.entries(ledger.sessions)) {
        if (now - session.ts > SESSION_MAX_AGE_MS) {
            ledger.week.carry += Math.max(0, session.total - session.weekBaseline);
            delete ledger.sessions[id];
            changed = true;
        }
    }
    // At midnight, active sessions carry over so that only today's part of their spend counts.
    if (ledger.date !== today) {
        ledger.date = today;
        for (const session of Object.values(ledger.sessions))
            session.baseline = session.total;
        changed = true;
    }
    // Restart the week when the quota window behind the Weekly bar opened after accumulation began.
    const resetAt = options?.sevenDayResetAt?.getTime();
    const windowStart = resetAt !== undefined && Number.isFinite(resetAt) ? resetAt - SEVEN_DAY_WINDOW_MS : null;
    if (windowStart !== null && ledger.week.start < windowStart) {
        for (const session of Object.values(ledger.sessions))
            session.weekBaseline = session.total;
        ledger.week = { start: now, carry: 0 };
        changed = true;
    }
    const sessionId = typeof stdin.session_id === 'string' ? stdin.session_id.trim() : '';
    const nativeCost = getNativeCostUsd(stdin, options);
    if (sessionId && nativeCost !== null) {
        const session = ledger.sessions[sessionId];
        if (!session) {
            ledger.sessions[sessionId] = { baseline: nativeCost, weekBaseline: nativeCost, total: nativeCost, ts: now };
            changed = true;
        }
        else {
            if (nativeCost > session.total) {
                session.total = nativeCost;
                changed = true;
            }
            session.ts = now;
        }
    }
    const sessions = Object.values(ledger.sessions);
    if (sessions.length === 0 && ledger.week.carry === 0) {
        return null;
    }
    if (changed || !isThrottled(ledgerPath, now)) {
        writeLedger(ledgerPath, ledger, now);
    }
    const sum = (pick) => sessions.reduce((total, s) => total + Math.max(0, s.total - pick(s)), 0);
    return {
        todayUsd: sum((s) => s.baseline),
        weekUsd: windowStart !== null ? ledger.week.carry + sum((s) => s.weekBaseline) : null,
    };
}
//# sourceMappingURL=daily-cost.js.map