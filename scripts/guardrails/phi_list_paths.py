#!/usr/bin/env python3
"""Python form of _guard_phi_list_paths (phi-egress-lib.sh).

The contract is pinned by phi-dir-cases.tsv and run by test-phi-list-paths.sh.
It never reads a list's content.
"""

import os
import stat
import sys


def phi_dirs(env=os.environ):
    home = env.get("HOME")
    if not home:
        return []
    old = home + "/.config/claude-glm"
    override = env.get("CLAUDE_GLM_CONFIG_DIR")
    dirs = [home + "/.config/himmel/phi"]
    if override:
        dirs.append(override)
    if override != old:
        dirs.append(old)
    return dirs


def phi_dir_provable(path):
    """Mirrors _guard_phi_dir_provable step for step.

    os.path.exists is not used: it is False on EACCES, so a locked dir would
    read as "no list here".
    """
    d = path
    while True:
        try:
            os.lstat(d)
            break
        except FileNotFoundError:
            pass
        except OSError:
            break
        if d == "/":
            return True
        if d == ".":
            return os.access(".", os.X_OK)
        if "/" in d:
            up = d.rsplit("/", 1)[0] or "/"
        else:
            up = "."
        if up == d:
            return True
        d = up
    try:
        st = os.stat(d)
    except OSError:
        return False
    if not stat.S_ISDIR(st.st_mode):
        return False
    return os.access(d, os.X_OK)


def _is_present(path):
    """Absent only on "no such file"; any other error counts as present."""
    try:
        os.lstat(path)
    except FileNotFoundError:
        return False
    except OSError:
        return True
    return True


def phi_list_paths(name, env=os.environ):
    """Return (rc, paths, unprovable): rc 0 found, 2 unprovable, 3 none."""
    dirs = phi_dirs(env)
    if not dirs:
        return 2, [], ""
    paths = []
    for d in dirs:
        if not phi_dir_provable(d):
            return 2, paths, d
        candidate = d + "/" + name
        if _is_present(candidate):
            paths.append(candidate)
    return (0 if paths else 3), paths, ""


def main(argv):
    rc, paths, unprovable = phi_list_paths(argv[1])
    for p in paths:
        print(p)
    if unprovable:
        print("unprovable: " + unprovable, file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
