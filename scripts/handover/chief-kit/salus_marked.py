#!/usr/bin/env python3
# salus_marked.py: is a directory salus-marked (PHI), and is it an adopted repo? One classifier for gen-briefs.py (import) and brief-lint.sh (CLI).
# Marked = a .salus or .salus-profile marker on the directory or an ancestor, or the directory inside (or holding) a phi-roots / egress-denylist
# entry: the check scripts/claude-codex runs (its own lists and claude-glm's), and the salus cell of scripts/guardrails/egress-matrix.json. The same
# test runs on the directory and on the primary checkout of its repo (a linked worktree can sit outside a marked primary). Anything that cannot be
# read or run fails closed (marked): a list that exists but is unreadable, a git that fails on a directory holding .git, any exception.
# CLI: python3 salus_marked.py salus|adapter <dir>   exit 0 = yes, 10 = no; any other code is a crash and the caller refuses.
# git-env-ok: _primary drops every GIT_* name from the environment it hands git
import os
import pathlib
import subprocess
import sys

YES, NO = 0, 10


def _lists():
    home = os.path.expanduser('~')
    glm = os.environ.get('CLAUDE_GLM_CONFIG_DIR') or os.path.join(home, '.config', 'claude-glm')
    codex = os.path.join(home, '.config', 'claude-codex')
    return ((codex, 'phi-roots'), (codex, 'egress-denylist'), (glm, 'phi-roots'), (glm, 'egress-denylist'))


def _chain(d):
    # d and each ancestor up to the root: bounded by the path's depth.
    return [d] + [str(p) for p in pathlib.Path(d).parents]


def _dir_marked(d):
    for top in _chain(d):
        if os.path.lexists(os.path.join(top, '.salus')) or os.path.lexists(os.path.join(top, '.salus-profile')):
            return True
    for cfg, name in _lists():
        f = os.path.join(cfg, name)
        if not os.path.lexists(f):
            continue
        try:
            with open(f, encoding='utf-8') as fh:
                lines = fh.read().splitlines()
        except Exception:
            return True
        for root in lines:
            root = root.strip()
            if not root or root.startswith('#'):
                continue
            root = os.path.expanduser(root)
            if not os.path.isabs(root):
                continue  # a relative line would resolve against whatever directory the classifier runs in
            root = os.path.realpath(root).rstrip('/')
            if root and ((d + '/').startswith(root + '/') or (root + '/').startswith(d + '/')):
                return True
    return False


def _holds_git(d):
    return any(os.path.lexists(os.path.join(top, '.git')) for top in _chain(d))


def _primary(d):
    # The parent of the repo's common git dir, as block-agent-native-egress.sh derives it. None = not a git directory.
    # A git that fails on a directory holding .git raises, and the caller answers marked.
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    e = d
    while not os.path.isdir(e) and os.path.dirname(e) != e:
        e = os.path.dirname(e)  # a directory not made yet: ask git about the nearest one that exists
    try:
        r = subprocess.run(['git', '-C', e, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                           capture_output=True, text=True, env=env, timeout=20)
        common = r.stdout.strip() if r.returncode == 0 else ''
    except Exception:
        common = ''
    if common:
        return os.path.realpath(os.path.join(common, '..'))
    if _holds_git(d):
        raise RuntimeError('git failed in a directory that holds .git')
    return None


def _salus_marked(path):
    d = os.path.realpath(path)
    if _dir_marked(d):
        return True
    primary = _primary(d)
    return primary is not None and primary != d and _dir_marked(primary)


def salus_marked(path):
    try:
        return _salus_marked(path)
    except Exception:
        return True


def is_adapter(repo):
    # An adopted repo is a git checkout with no chief-kit of its own: himmel's scripts must run for it.
    return os.path.exists(os.path.join(repo, '.git')) and not os.path.exists(os.path.join(repo, 'scripts', 'handover', 'chief-kit', 'headed-arm-worker.sh'))


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] not in ('salus', 'adapter'):
        sys.exit(2)
    fn = salus_marked if sys.argv[1] == 'salus' else is_adapter
    sys.exit(YES if fn(sys.argv[2]) else NO)
