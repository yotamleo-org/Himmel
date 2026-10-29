#!/usr/bin/env bash
# Advisory per-edge single-writer check; no existing gate is flag-wrapped.
# Usage: chain-push-check.sh [--repo-dir DIR] [--repo OWNER/NAME] [--base origin/main]
#        chain-push-check.sh [--repo-dir DIR] [--repo OWNER/NAME] --pr N --peer M
# Per peer one line: CHECKED <pr> <verdict>, CONFLICT <pr> <files>, SKIPPED <pr> <reason> or
# TIMEOUT <pr> <what>; then PEERS checked=<n> skipped=<n> conflicting=<n>. A timeout counts as skipped.
# Exit 0: nothing skipped or conflicting; 1: a conflict (FINDING edge-upgraded); 3: some peer was
# skipped and none conflicts (unknown); 2: no peer could be checked, the peer list was unreadable,
# or the request was malformed (a usage error, never the conflict status 1).
# --pr/--peer reads both PRs' current heads, prints HEADS <n>=<sha> <m>=<sha>, reports that one
# pair, and runs even with the chain_push_check flag off (an explicit call wants a real answer).
# Every gh and git subprocess is bounded by CHAIN_PUSH_CHECK_TIMEOUT seconds (default 60).
# Only committed HEAD is checked. merge-tree changes neither index nor worktree.
# Peer objects must already be available locally; this check never fetches.
# Platform guard: no .ps1 twin, by design; bash, python3, git and gh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/flags.sh
. "$HERE/../../lib/flags.sh" || exit 2
himmel_flag chain_push_check
rc=$?
{ [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; } || exit 2
export CHAIN_PUSH_FLAG_RC="$rc"
# shellcheck source=../../lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh" || exit 2
git_env_scrub

exec python3 -I - "$@" <<'PY'
import argparse
import json
import os
import re
import signal
import subprocess
import sys


class Timeout(Exception):
    pass


try:
    LIMIT = float(os.environ.get('CHAIN_PUSH_CHECK_TIMEOUT', '60'))
except ValueError:
    LIMIT = 60.0
if not 0 < LIMIT < float('inf'):
    LIMIT = 60.0


def run(cmd, ok=(0,), cwd=None):
    proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=LIMIT)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
        raise Timeout('%s: no answer within %gs' % (' '.join(cmd[:5]), LIMIT))
    if proc.returncode not in ok:
        raise ValueError('%s: exit %d: %s' % (' '.join(cmd[:5]), proc.returncode, err.strip()))
    return subprocess.CompletedProcess(cmd, proc.returncode, out, err)


def git(*args, ok=(0,)):
    return run(['git', '-C', a.repo_dir, *args], ok=ok)


def gh(*args):
    return run([os.environ.get('GH_CMD', 'gh'), *args], cwd=a.repo_dir)


def pages(endpoint):
    data = json.loads(gh('api', endpoint, '--paginate', '--slurp').stdout)
    if not isinstance(data, list) or any(not isinstance(page, list) for page in data):
        raise ValueError('invalid paginated response: ' + endpoint)
    return [row for page in data for row in page]


def pr_paths(number, sha):
    """Paths PR `number` touches, read while its head is still `sha`."""
    files = pages('repos/%s/pulls/%d/files?per_page=100' % (repo, number))
    if gh('api', 'repos/%s/pulls/%d' % (repo, number), '--jq', '.head.sha').stdout.strip() != sha:
        raise ValueError('head changed during file read; retry on a fresh snapshot')
    if len(files) >= 3000:
        raise ValueError('reaches the GitHub files API cap; overlap is unknown')
    paths = {row['filename'] for row in files}
    paths.update(row['previous_filename'] for row in files if row.get('previous_filename'))
    return paths


def compare(head, peer, changed, paths):
    shared = sorted(changed & paths)
    if not shared:
        return 'disjoint', shared
    if git('cat-file', '-e', peer + '^{commit}', ok=(0, 1, 128)).returncode:
        raise ValueError('head %s is unavailable locally; chief must supply the object' % peer)
    # Compare pinned heads, not a mutable branch name or the working copy.
    merged = git('merge-tree', '--write-tree', head, peer, ok=(0, 1))
    return ('conflict' if merged.returncode == 1 else 'clean'), shared


tally = {'checked': 0, 'skipped': 0, 'conflicting': 0}


def settle(label, work):
    """Run one peer's check and print its one outcome line; one bad peer never ends the run."""
    try:
        outcome = work()
    except Timeout as error:
        print('TIMEOUT %s %s' % (label, ' '.join(str(error).split())), flush=True)
        tally['skipped'] += 1
        return
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('SKIPPED %s %s' % (label, ' '.join(str(error).split()) or type(error).__name__), flush=True)
        tally['skipped'] += 1
        return
    if outcome is None:
        return
    verdict, shared, head, peer = outcome
    tally['checked'] += 1
    if verdict == 'conflict':
        print('FINDING edge-upgraded %s H2 head=%s peer=%s files=%s' % (label, head, peer, json.dumps(shared)))
        print('CONFLICT %s %s' % (label, json.dumps(shared)), flush=True)
        tally['conflicting'] += 1
    else:
        print('CHECKED %s %s' % (label, verdict), flush=True)


def finish():
    print('PEERS checked=%(checked)d skipped=%(skipped)d conflicting=%(conflicting)d' % tally, flush=True)
    if tally['conflicting']:
        sys.exit(1)
    if tally['skipped']:
        sys.exit(2 if not tally['checked'] else 3)
    sys.exit(0)


parser = argparse.ArgumentParser(description='Report conflicts against open PRs sharing a file.')
parser.add_argument('--repo-dir', default='.')
parser.add_argument('--repo')
parser.add_argument('--base', default='origin/main')
parser.add_argument('--pr', type=int)
parser.add_argument('--peer', type=int)
a = parser.parse_args()
if (a.pr is None) != (a.peer is None) or any(n is not None and n <= 0 for n in (a.pr, a.peer)):
    parser.error('--pr and --peer take positive PR numbers and go together')  # exit 2, never the conflict status 1
if os.environ.get('CHAIN_PUSH_FLAG_RC') == '1' and a.pr is None:
    sys.exit(0)
env = os.environ.copy()
try:
    repo = a.repo or gh('repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner').stdout.strip()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        raise ValueError('invalid repository: ' + repo)
    if a.pr is not None:
        heads = {n: gh('pr', 'view', str(n), '-R', repo, '--json', 'headRefOid', '--jq', '.headRefOid').stdout.strip()
                 for n in (a.pr, a.peer)}
        if not all(re.fullmatch(r'[0-9a-f]{40}', sha) for sha in heads.values()):
            raise ValueError('invalid head for PR %d or %d' % (a.pr, a.peer))
        print('HEADS %d=%s %d=%s' % (a.pr, heads[a.pr], a.peer, heads[a.peer]), flush=True)
        settle(str(a.peer), lambda: (
            *compare(heads[a.pr], heads[a.peer], pr_paths(a.pr, heads[a.pr]), pr_paths(a.peer, heads[a.peer])),
            heads[a.pr], heads[a.peer]))
        finish()
    head = git('rev-parse', '--verify', 'HEAD^{commit}').stdout.strip()
    base = git('rev-parse', '--verify', '--end-of-options', a.base + '^{commit}').stdout.strip()
    branch = git('symbolic-ref', '--quiet', '--short', 'HEAD', ok=(0, 1)).stdout.strip()
    changed = set(git('diff', '--name-only', '--no-renames', '-z', base + '...' + head).stdout.split('\0')) - {''}
    if not changed:
        finish()

    def peer_check(pr):
        number, peer = pr['number'], pr['head']['sha']
        if not isinstance(number, int) or number <= 0 or not re.fullmatch(r'[0-9a-f]{40}', peer):
            raise ValueError('invalid PR number or head')
        if pr['head']['repo'] is None:
            print('chain-push-check: WARN PR %d has a deleted head repository; skipping' % number, file=sys.stderr)
            raise ValueError('head repository was deleted; overlap is unknown')
        if peer == head or (branch and pr['head']['ref'] == branch
                            and pr['head']['repo']['full_name'].lower() == repo.lower()):
            return None
        return (*compare(head, peer, changed, pr_paths(number, peer)), head, peer)

    for pr in pages('repos/%s/pulls?state=open&per_page=100' % repo):
        settle(str(pr.get('number', '?')) if isinstance(pr, dict) else '?', lambda pr=pr: peer_check(pr))
    finish()
except (OSError, ValueError, KeyError, TypeError, Timeout) as error:
    print('chain-push-check: unreadable: %s' % error, file=sys.stderr)
    sys.exit(2)
PY
