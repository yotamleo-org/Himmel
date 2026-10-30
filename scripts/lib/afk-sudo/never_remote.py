"""never_remote — the floor of what an AFK `run` request may never name (HIMMEL-8067 §7).

Installed root-owned next to the helper, so a config cannot remove it; changing it
takes a himmel PR plus a re-install at the station. `/etc/himmel/afk-sudo.json`
may only ADD patterns (`never_remote_extra`).

One word set per request: every argv element, the words of each `-c` string, file
argument and stdin, each also in its trimmed, `key=value`, path-normalised,
realpath'd and basename forms. Every rule is a membership test on that set, so
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

DISK_CMDS = ("mkfs", "mkfs.*", "wipefs", "blkdiscard", "sgdisk", "sfdisk", "fdisk", "parted", "luksFormat", "luksErase")
DISK_DEVS = ("/dev/sd*", "/dev/hd*", "/dev/vd*", "/dev/xvd*", "/dev/nvme*", "/dev/mmcblk*", "/dev/md*", "/dev/dm-*",
             "/dev/mapper/*", "/dev/disk/*")
SECRETS = ("/etc/shadow", "/etc/gshadow", "*/.ssh/id_*", "*/.gnupg", "*/.gnupg/*", "*/.claude/.credentials.json",
           "*/.claude/channels/*/.env", ".env", "totp.seed")
FORCE = ("-f", "--force*", "--delete", "+*", ":*")
PROTECTED = ("main", "master", "*/main", "*/master", "*:main", "*:master", "refs/heads/main", "refs/heads/master")
HIMMEL_DIRS = ("/etc/himmel", "/usr/local/libexec/himmel", "/var/lib/himmel", "/var/log/himmel")
GUARD_FILES = ("*/.claude/settings*.json", "*/scripts/hooks", "*/scripts/hooks/*")
GUARD_FLAGS = ("--dangerously-skip-permissions", "bypassPermissions")


def _path_forms(w, cwd, home):
    """The absolute forms of a path-like word: ~ and $HOME expanded, joined to cwd, normalised, realpath'd if it exists."""
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
    out = {n}
    if os.path.lexists(n):
        out.add(os.path.realpath(n))
    return out


def word_set(argv, texts, cwd, home):
    raw = list(argv)
    for i, a in enumerate(argv[:-1]):
        if re.fullmatch(r"-[A-Za-z]*c", a):
            raw += argv[i + 1].split()
    for t in texts:
        raw += t.split()
    ws = set()

    def add(w, pathy):
        for v in {w, w.strip(TRIM)}:
            if not v:
                continue
            ws.add(v)
            if "=" in v[1:]:
                add(v.split("=", 1)[1], False)
            if v[0] in "+:" and len(v) > 1:  # a refspec: +main forces main, :main deletes it
                add(v[1:], False)
            if pathy or "/" in v or v.startswith(HOME_FORMS):
                for f in _path_forms(v, cwd, home):
                    ws.add(f)
                    if os.path.basename(f):
                        ws.add(os.path.basename(f))

    for w in argv:
        add(w, True)
    for w in raw[len(argv):]:
        add(w, False)
    return ws


def _any(ws, pats):
    return any(fnmatch.fnmatchcase(w, p) for w in ws for p in pats)


def _top(w, home):
    """A word that is `/`, a top-level directory, or the operator's home itself."""
    if w in ("/*", "~", "~/", "~/*", "$HOME", "${HOME}", "$HOME/", "$HOME/*"):
        return True
    if os.path.normpath(w) in ("/", home):
        return True
    return bool(re.fullmatch(r"/[^/]+/?", w)) and not os.path.isfile(w)


def _disk_wipe(ws, home):
    if _any(ws, DISK_CMDS) or _any(ws, DISK_DEVS):
        return True
    if "rm" in ws and any(_top(w, home) for w in ws):
        return True
    return "btrfs" in ws and "delete" in ws and any(w == "/" or fnmatch.fnmatchcase(w, "/@*") for w in ws)


def _secret_read(ws, home):
    return (_any(ws, SECRETS) or {"secret-tool", "lookup"} <= ws or {"gh", "auth", "token"} <= ws
            or {"himmel-secrets", "get"} <= ws)


def _main_history(ws, home):
    if "push" in ws and _any(ws, FORCE) and _any(ws, PROTECTED):
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
    for name, rule in RULES:
        if rule(ws, home):
            return name
    if any(isinstance(p, str) and p and _any(ws, (p,)) for p in extra):
        return "extra"
    return None
