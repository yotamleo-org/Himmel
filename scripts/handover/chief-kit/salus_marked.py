#!/usr/bin/env python3
# salus_marked.py: is a directory salus-marked (PHI), and is it an adopted repo? One classifier for gen-briefs.py (import) and brief-lint.sh (CLI).
# Marked = a .salus or .salus-profile marker on the directory or an ancestor, or the directory inside (or holding) a phi-roots / egress-denylist
# entry: the check scripts/claude-codex runs, and the salus cell of scripts/guardrails/egress-matrix.json. A list that exists but cannot be read
# fails closed (marked), as claude-codex does; a missing list is simply absent.
# CLI: python3 salus_marked.py salus|adapter <dir>   exit 0 = yes, 1 = no.
import os
import sys

LISTS = (('claude-codex', 'phi-roots'), ('claude-glm', 'phi-roots'), ('claude-glm', 'egress-denylist'))


def salus_marked(path):
    d = os.path.realpath(path)
    top = d
    while True:
        if os.path.lexists(os.path.join(top, '.salus')) or os.path.lexists(os.path.join(top, '.salus-profile')):
            return True
        up = os.path.dirname(top)
        if up == top:
            break
        top = up
    for cfg, name in LISTS:
        f = os.path.join(os.path.expanduser('~'), '.config', cfg, name)
        if not os.path.lexists(f):
            continue
        try:
            lines = open(f).read().splitlines()
        except OSError:
            return True
        for root in lines:
            root = root.strip().rstrip('/')
            if not root:
                continue
            root = os.path.realpath(root).rstrip('/')
            if root and ((d + '/').startswith(root + '/') or (root + '/').startswith(d + '/')):
                return True
    return False


def is_adapter(repo):
    # An adopted repo is a git checkout with no chief-kit of its own: himmel's scripts must run for it.
    return os.path.exists(os.path.join(repo, '.git')) and not os.path.exists(os.path.join(repo, 'scripts', 'handover', 'chief-kit', 'headed-arm-worker.sh'))


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] not in ('salus', 'adapter'):
        sys.exit(2)
    fn = salus_marked if sys.argv[1] == 'salus' else is_adapter
    sys.exit(0 if fn(sys.argv[2]) else 1)
