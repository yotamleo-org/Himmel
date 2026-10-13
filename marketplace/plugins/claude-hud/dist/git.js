import { createDebug } from './debug.js';
import { GitTimeoutError, runGit } from './git-runner.js';
const debug = createDebug('git');
const QUIET = ['-c', 'core.quotePath=false', '--no-optional-locks'];
/**
 * A repository's own config is as untrusted as its files, and git runs commands it names:
 * core.fsmonitor on every status, and filter drivers whenever it hashes a changed file. Both
 * are turned off for drivers that don't come from the user's global or system config, so
 * git-lfs keeps working. A driver name git can't take back in `-c` makes git refuse to run.
 * Callers also pass --ignore-submodules=dirty, since git inside a submodule reads its config.
 */
async function untrustedConfigOverrides(cwd) {
    const overrides = ['-c', 'core.fsmonitor=false'];
    let listed;
    try {
        listed = await runGit(cwd, ['config', '--show-scope', '-z', '--get-regexp', '^filter\\.'], 1000);
    }
    catch {
        return overrides; // exits 1 when no filter is configured
    }
    const drivers = new Set();
    const fields = listed.split('\0');
    for (let i = 0; i + 1 < fields.length; i += 2) {
        const [scope, entry] = [fields[i], fields[i + 1]];
        if (scope === 'global' || scope === 'system')
            continue;
        const key = entry.split('\n', 1)[0];
        const name = key.slice('filter.'.length, key.lastIndexOf('.'));
        if (name)
            drivers.add(name);
    }
    for (const name of drivers) {
        overrides.push('-c', `filter.${name}.clean=`, '-c', `filter.${name}.process=`, '-c', `filter.${name}.required=false`);
    }
    return overrides;
}
export async function getGitStatus(cwd, options = {}) {
    if (!cwd)
        return null;
    const safe = [...QUIET, ...await untrustedConfigOverrides(cwd)];
    let output;
    try {
        output = await runGit(cwd, [...safe, 'status', '--porcelain=v2', '--branch', '-z', '--ignore-submodules=dirty'], 1000);
    }
    catch (err) {
        debug('git status failed:', err instanceof Error ? err.message : err);
        return err instanceof GitTimeoutError ? getBranchOnly(cwd, options.repo) : null;
    }
    const parsed = parseStatus(output);
    const branch = parsed.head ?? await describeDetachedHead(cwd, parsed.oid);
    if (!branch)
        return null;
    const status = {
        branch,
        isDirty: parsed.dirty,
        ahead: parsed.ahead,
        behind: parsed.behind,
        branchUrl: githubRefUrl(options.repo, branch),
    };
    if (!parsed.dirty)
        return status;
    status.fileStats = parsed.fileStats;
    if (options.lineDiffs) {
        try {
            // diff-index, not diff: porcelain diff refreshes stale stat data into .git/index whatever
            // --no-optional-locks says, and a timeout mid-write leaves .git/index.lock behind.
            // -M keeps the rename detection diff turns on by default.
            const diffs = parseNumstat(await runGit(cwd, [...safe, 'diff-index', '-M', '--numstat', '-z', '--ignore-submodules=dirty', 'HEAD'], 2000));
            status.lineDiff = { added: 0, deleted: 0 };
            for (const diff of diffs.values()) {
                status.lineDiff.added += diff.added;
                status.lineDiff.deleted += diff.deleted;
            }
            for (const file of parsed.fileStats.trackedFiles) {
                const diff = diffs.get(file.fullPath);
                if (diff)
                    file.lineDiff = diff;
            }
        }
        catch (err) {
            debug('git diff-index --numstat failed:', err instanceof Error ? err.message : err);
        }
    }
    return status;
}
// A status that timed out in a large repo still leaves the branch worth showing.
async function getBranchOnly(cwd, repo) {
    try {
        const branch = (await runGit(cwd, ['rev-parse', '--abbrev-ref', 'HEAD'], 1000)).trim();
        if (!branch || branch === 'HEAD')
            return null;
        return { branch, isDirty: false, ahead: 0, behind: 0, branchUrl: githubRefUrl(repo, branch) };
    }
    catch {
        return null;
    }
}
async function describeDetachedHead(cwd, oid) {
    try {
        const tag = (await runGit(cwd, ['describe', '--tags', '--exact-match', 'HEAD'], 1000)).trim();
        if (tag)
            return tag;
    }
    catch {
        // Untagged commit.
    }
    return oid && /^[0-9a-f]{7,}$/.test(oid) ? `detached:${oid.slice(0, 7)}` : null;
}
const GITHUB_NAME = /^[A-Za-z0-9_.-]+$/;
function githubRefUrl(repo, ref) {
    if (repo?.host !== 'github.com' || !GITHUB_NAME.test(repo.owner ?? '') || !GITHUB_NAME.test(repo.name ?? '')) {
        return undefined;
    }
    const base = `https://github.com/${repo.owner}/${repo.name}`;
    const sha = /^detached:([0-9a-f]+)$/.exec(ref)?.[1];
    return sha ? `${base}/commit/${sha}` : `${base}/tree/${ref.split('/').map(encodeURIComponent).join('/')}`;
}
// Fields before the path in `git status --porcelain=v2` records, by record type.
const PATH_FIELD = { '1': 8, '2': 9, u: 10 };
export function parseStatus(output) {
    const parsed = {
        oid: null,
        head: null,
        ahead: 0,
        behind: 0,
        dirty: false,
        fileStats: { modified: 0, added: 0, deleted: 0, untracked: 0, trackedFiles: [] },
    };
    const stats = parsed.fileStats;
    const records = output.split('\0');
    for (let i = 0; i < records.length; i++) {
        const record = records[i];
        if (record.startsWith('# branch.oid ')) {
            parsed.oid = record.slice('# branch.oid '.length);
        }
        else if (record.startsWith('# branch.head ')) {
            const head = record.slice('# branch.head '.length);
            parsed.head = head === '(detached)' ? null : head;
        }
        else if (record.startsWith('# branch.ab ')) {
            const match = /^\+(\d+) -(\d+)$/.exec(record.slice('# branch.ab '.length));
            if (match) {
                parsed.ahead = Number(match[1]);
                parsed.behind = Number(match[2]);
            }
        }
        else if (record.startsWith('? ')) {
            parsed.dirty = true;
            stats.untracked++;
        }
        else if (record[1] === ' ' && record[0] in PATH_FIELD) {
            parsed.dirty = true;
            const fullPath = pathAfterFields(record, PATH_FIELD[record[0]]);
            if (record[0] === '2')
                i++; // A rename or copy is followed by its original path.
            const type = classify(record[2], record[3]);
            if (!type)
                continue;
            stats[type]++;
            stats.trackedFiles.push({ basename: fullPath.split('/').pop() ?? fullPath, fullPath, type });
        }
    }
    return parsed;
}
function pathAfterFields(record, fields) {
    let index = 0;
    for (let field = 0; field < fields; field++)
        index = record.indexOf(' ', index) + 1;
    return record.slice(index);
}
// Index (x) and worktree (y) status letters. Renames, copies, and UU conflicts count as modified.
function classify(x, y) {
    if (x === 'A' || (x === 'U' && y === 'A'))
        return 'added';
    if (x === 'D' || y === 'D')
        return 'deleted';
    if (x === 'M' || y === 'M' || x === 'R' || x === 'C' || x === 'U')
        return 'modified';
    return null;
}
// `git diff --numstat -z`: "added\tdeleted\tpath", or for a rename an empty
// path followed by the old and new paths as separate records.
export function parseNumstat(output) {
    const diffs = new Map();
    const records = output.split('\0');
    for (let i = 0; i < records.length; i++) {
        const record = records[i];
        const first = record.indexOf('\t');
        const second = record.indexOf('\t', first + 1);
        if (first === -1 || second === -1)
            continue;
        let filePath = record.slice(second + 1);
        if (filePath === '') {
            filePath = records[i + 2] ?? '';
            i += 2;
        }
        const added = Number.parseInt(record.slice(0, first), 10);
        const deleted = Number.parseInt(record.slice(first + 1, second), 10);
        if (Number.isNaN(added) || Number.isNaN(deleted))
            continue; // binary file
        diffs.set(filePath, { added, deleted });
    }
    return diffs;
}
//# sourceMappingURL=git.js.map