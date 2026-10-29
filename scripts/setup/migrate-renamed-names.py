#!/usr/bin/env python3
"""Move an install's own files to the renamed names of slice W (the console to chief, leg to worker rename).

  migrate-renamed-names.py [--check | --dry-run | --apply] [--registry FILE] FILE...

A settings file (*.json) has every slice W `path` row rewritten in its hook commands: an old script or hook
path becomes its new path, matched as a whole path run (the rule of move-renamed-dirs.sh). A permissions rule
naming an old path stays and gains the renamed rule beside it. A script name the registry marks for
removal (remove-at X) whose file is gone from this checkout is renamed the same way. Any other FILE is an env file: a line
that assigns an old slice W `env` name (`NAME=` or `export NAME=`) is renamed to the new name, value kept.
  --check    print "<count>\t<file>" for each file with old names; exit 1 when any is pending.
  --dry-run  print the unified diff it would make; change nothing. (default)
  --apply    copy FILE to FILE.bak-renamed-names first, then rewrite it in place.
A missing FILE is skipped. Exit 0 done or nothing pending, 1 --check found work, 2 usage or a bad registry.
"""
import difflib
import json
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT_EXT = (".sh", ".ts", ".mjs", ".js", ".py")
SKIP_DIRS = {"fixtures", "node_modules", "testdata", "dist", ".git"}


def live_names(root):
    """File names under root/scripts: a retired name still in use there is not retired."""
    names = set()
    for _, dirs, files in os.walk(os.path.join(root, "scripts")):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        names.update(files)
    return names


def rows(registry):
    paths, envs, scripts = [], [], []
    with open(registry, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            c = line.rstrip("\n").split("\t")
            if len(c) < 6 or not c[0] or not c[1]:
                continue
            if c[4] == "W" and c[2] == "path":
                paths.append((c[0], c[1]))
            elif c[4] == "W" and c[2] == "env":
                envs.append((c[0], c[1]))
            elif c[5] == "X" and c[2] == "identifier" and c[0].endswith(SCRIPT_EXT):
                scripts.append((c[0], c[1]))
    root = os.path.realpath(os.path.join(HERE, "..", ".."))
    live = live_names(root)
    paths += [(old, new, root) for old, new in scripts if old not in live]
    paths.sort(key=lambda p: len(p[0]), reverse=True)
    return paths, envs


def rename_paths(s, paths):
    n = 0
    for old, new, *anchored in paths:
        # A bare script name is renamed only inside this checkout's scripts/ path: relative, under its root, or under $HIMMEL_REPO.
        if anchored:
            prefix = "(?:" + re.escape(anchored[0] + "/") + r"|\$HIMMEL_REPO/|\$\{HIMMEL_REPO\}/|\./)?"
            head = r"(?<![A-Za-z0-9_./+-])(" + prefix + r"scripts/(?:(?!\.\./)[A-Za-z0-9_.-]+/)*)"
        else:
            head = r"(?<![A-Za-z0-9_.-])()"
        rx = re.compile(head + re.escape(old) + r"(?![A-Za-z0-9_-])(?!\.[A-Za-z0-9_])")
        s, c = rx.subn(lambda m, new=new: m.group(1) + new, s)
        n += c
    return s, n


def rewrite_settings(text, paths):
    """Hook commands under "hooks" are rewritten; a permissions rule naming an old path keeps its place and
    gains the renamed rule beside it (forwarders at the old paths still need the old rule)."""
    data = json.loads(text)
    n = 0

    def walk(v):
        nonlocal n
        if isinstance(v, str):
            s, c = rename_paths(v, paths)
            n += c
            return s
        if isinstance(v, list):
            return [walk(x) for x in v]
        if isinstance(v, dict):
            return {k: walk(x) for k, x in v.items()}
        return v
    if "hooks" in data:
        data["hooks"] = walk(data["hooks"])
    perms = data.get("permissions")
    if isinstance(perms, dict):
        for key in ("allow", "ask", "deny"):
            rules = perms.get(key)
            if not isinstance(rules, list):
                continue
            out = []
            for r in rules:
                out.append(r)
                if isinstance(r, str):
                    s, c = rename_paths(r, paths)
                    if c and s not in rules and s not in out:
                        out.append(s)
                        n += 1
            perms[key] = out
    return (json.dumps(data, indent=2, ensure_ascii=False) + "\n" if n else text), n


def rewrite_env(text, envs):
    n = 0
    for old, new in envs:
        rx = re.compile(r"^(\s*(?:export\s+)?)" + re.escape(old) + r"=", re.M)
        text, c = rx.subn(lambda m, new=new: m.group(1) + new + "=", text)
        n += c
    return text, n


def main(argv):
    usage = "usage: migrate-renamed-names.py [--check | --dry-run | --apply] [--registry FILE] FILE..."
    mode, registry, files = "dry-run", os.path.join(HERE, "..", "lib", "rename-aliases.tsv"), []
    it = iter(argv)
    for a in it:
        if a in ("--check", "--dry-run", "--apply"):
            mode = a[2:]
        elif a == "--registry":
            registry = next(it, "")
        elif a.startswith("-"):
            print(usage, file=sys.stderr)
            return 2
        else:
            files.append(a)
    if not files:
        print(usage, file=sys.stderr)
        return 2
    try:
        paths, envs = rows(registry)
    except OSError as e:
        print(f"migrate-renamed-names: registry: {e}", file=sys.stderr)
        return 2
    if not paths or not envs:
        print(f"migrate-renamed-names: no slice W rows in {registry}", file=sys.stderr)
        return 2
    pending = 0
    for f in files:
        if not os.path.isfile(f) or os.path.islink(f):
            continue
        with open(f, encoding="utf-8") as fh:
            before = fh.read()
        try:
            after, n = (rewrite_settings(before, paths) if f.endswith(".json") else rewrite_env(before, envs))
        except ValueError as e:
            print(f"migrate-renamed-names: {f}: not valid JSON ({e}); skipped", file=sys.stderr)
            continue
        if not n:
            continue
        pending = 1
        if mode == "check":
            print(f"{n}\t{f}")
        elif mode == "dry-run":
            sys.stdout.writelines(difflib.unified_diff(before.splitlines(True), after.splitlines(True), f, f + " (renamed)"))
        else:
            shutil.copy2(f, f + ".bak-renamed-names")
            with open(f, "w", encoding="utf-8") as fh:
                fh.write(after)
            print(f"rewrote {n} old names in {f} (backup {f}.bak-renamed-names)")
    return 1 if (mode == "check" and pending) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
