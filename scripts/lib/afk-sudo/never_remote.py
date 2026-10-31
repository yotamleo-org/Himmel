"""never_remote — the floor of what an AFK `run` request may never name (HIMMEL-8067 §7).

Installed root-owned next to the helper, so a config cannot remove it; changing it
takes a himmel PR plus a re-install at the station. `/etc/himmel/afk-sudo.json`
may only ADD patterns (`never_remote_extra`).

One word set per request: every argv element and its whitespace-split words, the words
of each file argument and stdin, each also in its trimmed, `key=value`, path-normalised,
realpath'd and basename forms (links resolve before `..`, as the kernel opens a path).
A word that derives more than MAX_FORMS forms, or whose path the kernel cannot walk (`landing`: a strict realpath that
fails for any reason but a missing name), is refused as `oversize`. Every rule is a membership test on that set, so
there is no shell syntax or word order to model and no shape list to keep closing.
Co-occurrence over-blocks (an unrelated `main` next to `git push -f`); that cost
is accepted.

ponytail: word-set membership, not a semantic policy; blind to computed paths,
wrappers that fetch or assemble text, and files over 64 KiB; upgrade path is mode
allowlist with classes from suggest-allowlist (slice 3), which removes free-form runs.
"""
import fnmatch
import os
import re

TRIM = "\"'`;&|(){}<>,"
HOME_FORMS = ("~", "$HOME", "${HOME}")
MAX_FORMS = 64


def landing(p):
    """Where the kernel lands for the absolute path p, or None when the walk fails. A strict realpath asks the
    kernel at every step; non-strict realpath treats a link it cannot lstat (path past PATH_MAX, a name past
    NAME_MAX, EACCES) as a plain name (and pops it lexically on a later `..`), so its string is not where the
    kernel lands. A non-directory in the way is a path that is simply not there: its lexical form is its landing.
    A missing name is not: a later link that fails would be skipped by a plain realpath (`install -D` creates the
    missing name, then walks on), so the walk goes on past it with ALLOW_MISSING, which tolerates a missing name
    and fails on every other error, link targets included. A Python without ALLOW_MISSING (before 3.14, unless
    the tarfile CVE-2025-4517 fix was backported) cannot do that: it refuses a `..` after a missing name."""
    try:
        return os.path.realpath(p, strict=True)
    except FileNotFoundError:
        allow = getattr(os.path, "ALLOW_MISSING", None)
        if allow is not None:
            try:
                return os.path.realpath(p, strict=allow)
            except OSError:
                return None
        return None if ".." in p.split("/") else os.path.realpath(p)
    except NotADirectoryError:
        return os.path.realpath(p)
    except OSError:
        return None

DISK_CMDS = ("mkfs", "mkfs.*", "wipefs", "blkdiscard", "sgdisk", "sfdisk", "fdisk", "parted", "luksFormat", "luksErase")
DISK_DEVS = ("/dev/sd*", "/dev/hd*", "/dev/vd*", "/dev/xvd*", "/dev/nvme*", "/dev/mmcblk*", "/dev/md*", "/dev/dm-*",
             "/dev/mapper/*", "/dev/disk/*")
SECRETS = ("/etc/shadow", "/etc/gshadow", "*/.ssh/id_*", "*/.gnupg", "*/.gnupg/*", "*/.claude/.credentials.json",
           "*/.claude/channels/*/.env", ".env", "totp.seed")
FORCE = ("--force*", "--delete", "+*", ":*")
PROTECTED = ("main", "master", "*/main", "*/master", "*:main", "*:master", "refs/heads/main", "refs/heads/master")
HIMMEL_DIRS = ("/etc/himmel", "/usr/local/libexec/himmel", "/var/lib/himmel", "/var/log/himmel")
GUARD_FILES = ("*/.claude/settings*.json", "*/scripts/hooks", "*/scripts/hooks/*")
GUARD_FLAGS = ("--dangerously-skip-permissions", "bypassPermissions")


def _path_forms(w, cwd, home):
    """The absolute forms of a path-like word: ~ and $HOME expanded, joined to cwd, normalised, realpath'd if it exists.
    None when the kernel cannot walk the path (`landing`), so the caller fails closed."""
    p = w
    for pre in HOME_FORMS:
        if p == pre or p.startswith(pre + "/"):
            p = home + p[len(pre):]
            break
    if not p.startswith("/"):
        p = os.path.join(cwd, p)
    n = os.path.normpath(p)
    # A bare word (`rm`) only names a path under cwd if that path exists; else cwd `/` makes `/rm`.
    if "/" not in w and not w.startswith(HOME_FORMS) and not os.path.lexists(n):
        return set()
    try:
        r = landing(p)  # realpath of the joined path: `link/..` is the link target's parent
    except ValueError:  # a NUL in the word (a binary file's text): it names no path, the lexical form is all there is
        return {n}
    return None if r is None else {n, r}


def _forms(w, pathy, cwd, home):
    """Every form of one word, or None when it derives more than MAX_FORMS (a crafted word)."""
    out, seen, todo = set(), set(), [(w, pathy)]
    while todo:
        w, pathy = todo.pop()
        for v in {w, w.strip(TRIM)}:
            if not v or (v, pathy) in seen:
                continue
            seen.add((v, pathy))
            if len(seen) > MAX_FORMS:
                return None
            out.add(v)
            if v[0] == "=":  # a leading = run derives the word after it once, not one form per =
                todo.append((v.lstrip("="), False))
            elif "=" in v:
                todo.append((v.split("=", 1)[1], False))
            if v[0] in "+:" and len(v) > 1:  # a refspec: +main forces main, :main deletes it
                todo.append((v[1:], False))
            if len(v) <= 4096 and (pathy or "/" in v or v.startswith(HOME_FORMS)):
                forms = _path_forms(v, cwd, home)
                if forms is None:
                    return None
                for f in forms:
                    out.add(f)
                    if os.path.basename(f):
                        out.add(os.path.basename(f))
    return out


def word_set(argv, texts, cwd, home):
    """The word set of a request, or None when one word derives too many forms."""
    todo = [(w, True) for w in argv]
    for a in argv:
        todo += [(w, False) for w in a.split()]
    for t in texts:
        todo += [(w, False) for w in t.split()]
    ws, done = set(), set()
    for item in todo:
        if item in done:
            continue
        done.add(item)
        forms = _forms(item[0], item[1], cwd, home)
        if forms is None:
            return None
        ws |= forms
    return ws


def _any(ws, pats):
    return any(fnmatch.fnmatchcase(w, p) for w in ws for p in pats)


def _top(w, home):
    """A word that is `/`, a top-level directory, or the operator's home itself, or a glob of one."""
    if w in ("~", "~/", "~/*", "$HOME", "${HOME}", "$HOME/", "${HOME}/", "$HOME/*", "${HOME}/*"):
        return True
    base = w[:-2] if w.endswith("/*") else w
    n = re.sub(r"^/+", "/", os.path.normpath(base)) if base else "/"
    return n in ("/", home) or (bool(re.fullmatch(r"/[^/]+", n)) and not os.path.isfile(n))


def _disk_wipe(ws, home):
    if _any(ws, DISK_CMDS) or _any(ws, DISK_DEVS):
        return True
    if "rm" in ws and any(_top(w, home) for w in ws):
        return True
    return "btrfs" in ws and "delete" in ws and any(w == "/" or fnmatch.fnmatchcase(w, "/@*") for w in ws)


def _secret_read(ws, home):
    return (_any(ws, SECRETS) or {"secret-tool", "lookup"} <= ws or {"gh", "auth", "token"} <= ws
            or {"himmel-secrets", "get"} <= ws)


def _short_force(w):
    """-f, -d and a short-flag cluster carrying one (-fu, -df). No regex: a backtracking one is quadratic on a 64 KiB word."""
    return w[:1] == "-" and w[1:].isascii() and w[1:].isalnum() and ("f" in w or "d" in w)


def _main_history(ws, home):
    force = _any(ws, FORCE) or any(_short_force(w) for w in ws)
    if "push" in ws and force and _any(ws, PROTECTED):
        return True
    if "gh" in ws and "DELETE" in ws and any("refs/heads/main" in w for w in ws):
        return True
    return {"gh", "repo", "delete"} <= ws


def _approval_system(ws, home):
    if any(w == d or w.startswith(d + "/") for w in ws for d in HIMMEL_DIRS):
        return True
    return _any(ws, ("/etc/sudoers*", "*/afk-sudo/install.sh")) or "visudo" in ws


def _guards_off(ws, home):
    # A worktree copy is the worker's own to change; the primary checkout and the live settings are not.
    main = {w for w in ws if "/.claude/worktrees/" not in w}
    if _any(main, GUARD_FILES) or "hooks.json" in ws or _any(ws, GUARD_FLAGS):
        return True
    if any(re.fullmatch(r"HIMMEL_\w*_OK=1|\w*_BYPASS\w*=1", w) for w in ws):
        return True
    return any(fnmatch.fnmatchcase(w, "telegram-bridge*") for w in ws) and bool({"stop", "disable", "mask", "kill"} & ws)


RULES = (("disk-wipe", _disk_wipe), ("secret-read", _secret_read), ("main-history", _main_history),
         ("approval-system", _approval_system), ("guards-off", _guards_off))


def check(argv, texts, cwd, home, extra=()):
    """The name of the first rule the request trips, else None. `extra` only adds patterns."""
    ws = word_set(argv, texts, cwd, home)
    if ws is None:
        return "oversize"
    for name, rule in RULES:
        if rule(ws, home):
            return name
    if any(isinstance(p, str) and p and _any(ws, (p,)) for p in extra):
        return "extra"
    return None
