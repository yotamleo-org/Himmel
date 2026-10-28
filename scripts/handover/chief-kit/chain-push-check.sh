#!/usr/bin/env bash
# Advisory per-edge single-writer check; no existing gate is flag-wrapped.
# Usage: chain-push-check.sh [--repo-dir DIR] [--repo OWNER/NAME] [--base origin/main]
# Exit 0: off or no conflicts; 1: FINDING edge-upgraded; 2: a read failed.
# Only committed HEAD is checked. merge-tree changes neither index nor worktree.
# Peer objects must already be available locally; this check never fetches.
# Platform guard: no .ps1 twin, by design; bash, python3, git and gh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/flags.sh
. "$HERE/../../lib/flags.sh" || exit 2
himmel_flag chain_push_check
rc=$?
[ "$rc" -eq 1 ] && exit 0
[ "$rc" -eq 0 ] || exit 2
# shellcheck source=../../lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh" || exit 2
git_env_scrub

exec python3 -I - "$@" <<'PY'
import argparse
import json
import os
import re
import subprocess
import sys


def run(cmd, ok=(0,), cwd=None):
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)
    if p.returncode not in ok:
        raise ValueError('%s: exit %d: %s' % (' '.join(cmd[:5]), p.returncode, p.stderr.strip()))
    return p


def git(*args, ok=(0,)):
    return run(['git', '-C', a.repo_dir, *args], ok=ok)


def pages(endpoint):
    data = json.loads(run([os.environ.get('GH_CMD', 'gh'), 'api', endpoint, '--paginate', '--slurp'],
                          cwd=a.repo_dir).stdout)
    if not isinstance(data, list) or any(not isinstance(page, list) for page in data):
        raise ValueError('invalid paginated response: ' + endpoint)
    return [row for page in data for row in page]


a = argparse.ArgumentParser(description='Report conflicts against open PRs sharing a file.')
a.add_argument('--repo-dir', default='.')
a.add_argument('--repo')
a.add_argument('--base', default='origin/main')
a = a.parse_args()
env = os.environ.copy()
try:
    head = git('rev-parse', '--verify', 'HEAD^{commit}').stdout.strip()
    base = git('rev-parse', '--verify', '--end-of-options', a.base + '^{commit}').stdout.strip()
    branch = git('symbolic-ref', '--quiet', '--short', 'HEAD', ok=(0, 1)).stdout.strip()
    changed = set(git('diff', '--name-only', '--no-renames', '-z', base + '...' + head).stdout.split('\0')) - {''}
    if not changed:
        sys.exit(0)
    repo = a.repo or run([os.environ.get('GH_CMD', 'gh'), 'repo', 'view', '--json', 'nameWithOwner',
                         '--jq', '.nameWithOwner'], cwd=a.repo_dir).stdout.strip()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        raise ValueError('invalid repository: ' + repo)
    conflicts = []
    for pr in pages('repos/%s/pulls?state=open&per_page=100' % repo):
        number, peer = pr['number'], pr['head']['sha']
        if not isinstance(number, int) or number <= 0 or not re.fullmatch(r'[0-9a-f]{40}', peer):
            raise ValueError('invalid PR number or head')
        if pr['head']['repo'] is None:
            print('chain-push-check: WARN PR %d has a deleted head repository; skipping' % number, file=sys.stderr)
            continue
        if peer == head or (branch and pr['head']['ref'] == branch
                            and pr['head']['repo']['full_name'].lower() == repo.lower()):
            continue
        files = pages('repos/%s/pulls/%d/files?per_page=100' % (repo, number))
        current = run([os.environ.get('GH_CMD', 'gh'), 'api', 'repos/%s/pulls/%d' % (repo, number),
                       '--jq', '.head.sha'], cwd=a.repo_dir).stdout.strip()
        if current != peer:
            raise ValueError('PR %d head changed during file read; retry on a fresh snapshot' % number)
        if len(files) >= 3000:
            raise ValueError('PR %d reaches the GitHub files API cap; overlap is unknown' % number)
        paths = {row['filename'] for row in files}
        paths.update(row['previous_filename'] for row in files if row.get('previous_filename'))
        shared = sorted(changed & paths)
        if not shared:
            continue
        if git('cat-file', '-e', peer + '^{commit}', ok=(0, 1, 128)).returncode:
            raise ValueError('PR %d head %s is unavailable locally; chief must supply the object' % (number, peer))
        # Compare pinned heads, not a mutable branch name or the working copy.
        merged = git('merge-tree', '--write-tree', head, peer, ok=(0, 1))
        if merged.returncode == 1:
            finding = 'FINDING edge-upgraded %d H2 head=%s peer=%s files=%s' % (number, head, peer, json.dumps(shared))
            print(finding, flush=True)
            conflicts.append(number)
    sys.exit(1 if conflicts else 0)
except (OSError, ValueError, KeyError, TypeError) as error:
    print('chain-push-check: unreadable: %s' % error, file=sys.stderr)
    sys.exit(2)
PY
