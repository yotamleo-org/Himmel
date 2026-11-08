#!/usr/bin/env python3
"""holds.py - the single-writer holds register (HIMMEL-8725, slice 1).

One hold is one small file: ~/.himmel/state/holds/<slug>/<escaped repo path>. <slug> is the primary
checkout's absolute path, escaped the same way, so a linked worktree and its primary share a directory.
A row is one tab-separated line: key, label, doc, source (brief | claim | pr), pr number. It is published
by writing a temp file and link(2)-ing it, so a row is never seen half written and one contender wins.
A grant is a sibling, <escaped path>.grant.<KEY>. The sentinel <holds>/OFF folds the barrier for the fleet.
Denies, takeovers, grants and faults append one line to <holds>/events.log.

The barrier is a coordination guard, not a security fence: it refuses only on a positive answer (a readable
row, another key, that key alive, no grant). Every other outcome passes and leaves a record.

Exit codes: 0 ok, 1 refused (the holder on stderr), 2 usage, a crash or any failure that is not a refusal, 3 unreadable
(seed and repoint also: a claim fault, or the launch deadline passed).
"""
import argparse
import calendar
import fcntl
import json
import os
import re
import shlex
import signal
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GRACE = 15 * 60          # a row this young is alive: the worker is still arming
RESUME_AGE = 24 * 3600   # ponytail: a RESUME doc younger than this keeps its key's rows; a successor parked longer loses them, upgrade path: the chief re-points or grants
SEED_BUDGET = 60         # seconds a launch gives repoint and seed together, under the 120 s claim window of headed-arm.sh
GH_TIMEOUT = 5
QL_TIMEOUT = 15
SOURCES = ('brief', 'claim', 'pr')
KEY_RE = re.compile(r'^[A-Za-z][A-Za-z0-9]*-\d+$')
GRANT_RE = re.compile(r'\.grant\.[A-Za-z][A-Za-z0-9]*-\d+$')
TMP_PREFIX = '%00'       # escaping only ever makes %25 and %2F, so a name starting %00 is never a row
MAX_NAME = 255
LOCK_WAIT = 5.0          # seconds a row write waits for the directory lock before it faults
SIDECARS = ('.worker-preface.md', '.worker-contract.md')  # a launch's sidecars carry the doc's name; they are not a doc of the key

# ---- copied from next-dispatchable.sh (inline python): Task 3 removes the originals ------------------------
FILE_RE = re.compile(r"(?<![\w./-])((?:scripts|docs|marketplace|plugins|templates|tools|\.claude|\.github|\.codex)/[\w.+@-]+(?:/[\w.+@-]+)*/?|CLAUDE\.md|AGENTS\.md|README\.md|package\.json|package-lock\.json|bun\.lock|uv\.lock|pyproject\.toml|\.gitignore|\.pre-commit-config\.yaml)")
ABS_RE = re.compile(r"(?<![\w./~-])(/(?:[\w.+@-]+/)+[\w.+@-]+/?)")  # a bucket file named by absolute path
MARKER_RE = re.compile(r'^- \d{1,2}:\d{2} (LIVE|FINDING|RESOLVED|READY|BLOCKED|HALTED|WRAPPED|PARKED-BANK|PARKED-USAGE|RESUMED)\b')
WRITES_LEAD = '> **Writes:**'
SENT_BREAK_RE = re.compile(r'(?<!\d)(?<!e\.g)(?<!i\.e)\.(?=\s|$)')
WRITING_RE = re.compile(r'\s-(?:delete|exec|execdir|ok)\b')
_RENAMES = {}


def renames(repo):
    # the directory rows of scripts/lib/rename-aliases.tsv, so a pre-rename spelling and its new one are one path
    if repo in _RENAMES:
        return _RENAMES[repo]
    out = []
    try:
        for rline in open(os.path.join(repo, 'scripts/lib/rename-aliases.tsv'), encoding='utf-8', errors='replace'):
            cols = rline.rstrip('\n').split('\t')
            if len(cols) >= 3 and cols[2] == 'directory' and not rline.startswith('#') and cols[0].strip() and cols[1].strip():
                out.append((cols[0].strip().rstrip('/'), cols[1].strip().rstrip('/')))
    except OSError:
        pass  # swallow-ok: no registry means no rename is resolved, so a pre-rename path compares as written
    _RENAMES[repo] = out
    return out


def canon(p, repo):
    slash = p.endswith('/')
    t = p.rstrip('/')
    for _ in range(3):
        for old, new in renames(repo):
            if t == old or t.startswith(old + '/'):
                t = new + t[len(old):]
                break
        else:
            break
    return t + ('/' if slash else '')


def files_in(text, repo):
    out = []
    for m in FILE_RE.finditer(text):
        f = re.sub(r'[.,;:)\]-]+$', '', m.group(1))
        if f and not f.endswith('/') and os.path.isdir(os.path.join(repo, f)):
            f += '/'  # a directory keeps its slash, whatever punctuation followed it in the text
        if f and f not in out:
            out.append(f)
    for m in ABS_RE.finditer(text):
        f = re.sub(r'[.,;:)\]-]+$', '', m.group(1))
        if f and not f.endswith('/') and os.path.isdir(f):
            f += '/'
        if f and f not in out:
            out.append(f)
    return out


def concrete(f, repo):
    # a file, not a tree: a directory a ticket names is context and holds nothing
    if f.endswith('/'):
        return False
    p = f if os.path.isabs(f) else os.path.join(repo, canon(f, repo))
    return os.path.isfile(p) or (not os.path.exists(p) and '.' in os.path.basename(f))


def write_scope(line):
    if line.startswith('> **Writes note:**'):
        return ''
    if line.startswith(WRITES_LEAD):
        text = line[len(WRITES_LEAD):]
        while re.search(r'\([^()]*\)', text):
            text = re.sub(r'\([^()]*\)', ' ', text)
        return text
    return ''


def scope_paths(line, repo):
    return files_in(write_scope(line), repo)


def block(lines, i):
    # a wrapped line continues on the "> " lines under it, up to the next "> **" field or a blank
    text = lines[i]
    for nxt in lines[i + 1:]:
        if not nxt.startswith('> ') or nxt.startswith('> **'):
            break
        text += ' ' + nxt[2:]
    return text


def parse_text(text, repo=None):
    """The (kind, path) pairs of a doc's `> **Writes:**` lines: kind file or tree, in order, no repeats."""
    repo = repo or os.getcwd()
    lines = text.splitlines()
    out = []
    for i, l in enumerate(lines):
        if not l.startswith(WRITES_LEAD):
            continue
        for f in scope_paths(block(lines, i), repo):
            pair = ('file' if concrete(f, repo) else 'tree', f)
            if pair not in out:
                out.append(pair)
    return out
# ---- end of the copied block --------------------------------------------------------------------------------


def holds_root():
    return os.path.join(os.environ.get('HOME') or os.path.expanduser('~'), '.himmel', 'state', 'holds')


def escape(p):
    return p.replace('%', '%25').replace('/', '%2F')


def unescape(n):
    return re.sub(r'%(25|2F)', lambda m: '%' if m.group(1) == '25' else '/', n)


def now_iso():
    return time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime()) + 'Z'


def clean(s):
    return re.sub(r'[\t\r\n]+', ' ', s or '')


def log_event(event, path='', key='', holder=''):
    """Append one events.log line. When the log cannot be written, say so on stderr: a fault is never silent."""
    line = '\t'.join([now_iso(), event, clean(path), clean(key), clean(holder)]) + '\n'
    try:
        os.makedirs(holds_root(), exist_ok=True)
        fd = os.open(os.path.join(holds_root(), 'events.log'), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, line.encode('utf-8', 'replace'))
        finally:
            os.close(fd)
    except OSError as e:
        sys.stderr.write('holds: cannot write events.log (%s): %s' % (e.strerror or e, line))


def fault(reason, path='', key=''):
    log_event('fault', path, key, reason)


ALT_ROOTS = set()  # linked-worktree roots named by --repo, longest matched first by normalize()

# the variables that redirect git to another repository; a hook or a wrapper may have exported any of them
GIT_SCRUB = ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
             'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX', 'GIT_IMPLICIT_WORK_TREE', 'GIT_GRAFT_FILE',
             'GIT_REPLACE_REF_BASE', 'GIT_SHALLOW_FILE', 'GIT_CONFIG', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT')


class RepoFault(Exception):
    """The repo identity cannot be derived: a fault, never a guess at another slug."""


def primary_of(repo):
    """The primary checkout's absolute path: git-common-dir minus /.git. One derivation for every verb."""
    repo = os.path.abspath(repo)
    env = {k: v for k, v in os.environ.items() if k not in GIT_SCRUB}
    try:
        r = subprocess.run(['git', '-C', repo, 'rev-parse', '--path-format=absolute', '--git-common-dir', '--show-toplevel'],
                           capture_output=True, text=True, timeout=10, env=env)
        out = r.stdout.split('\n')
        d = out[0].strip()
        if r.returncode == 0 and d:
            primary = d[:-len('/.git')] if d.endswith('/.git') else d
            top = out[1].strip() if len(out) > 1 else ''
            # the top of the checkout the caller named, when it is a linked worktree (never a plain subdirectory of
            # a checkout): an absolute path under it is a path of the primary
            ALT_ROOTS.update(x for x in (top, os.path.realpath(top) if top else '') if x and x != primary)
            return primary
    except (OSError, subprocess.SubprocessError):
        pass  # swallow-ok: git gave no answer; the walk below decides whether the path as given can be the identity
    # git gave no answer. The path as given is the identity only when it is a primary checkout's root (a .git
    # directory there) or sits in no checkout at all; a linked worktree or a subdirectory would get a second slug.
    top = repo
    while top:
        dot = os.path.join(top, '.git')
        if os.path.lexists(dot):
            if top == repo and os.path.isdir(dot):
                return repo
            raise RepoFault('git gave no repo identity for %s' % repo)
        parent = os.path.dirname(top)
        if parent == top:
            return repo
        top = parent
    return repo


def slug_dir(repo, slug=None):
    return os.path.join(holds_root(), slug if slug is not None else escape(repo))


def exempt_set():
    out = set()
    try:
        for l in open(os.path.join(HERE, 'holds-exempt.txt'), encoding='utf-8'):
            l = l.strip()
            if l and not l.startswith('#'):
                out.add(l)
    except OSError:
        pass  # swallow-ok: no list means nothing is exempt, which holds more, not less
    return out


_DONE = {}


def mirror_done(key):
    """True when the local Jira mirror (HOLDS_MIRROR, else ~/.himmel/state/jira-mirror/<PROJECT>) reads the key's
    statusCategory as Done. A key with no mirror file is not Done: the row stays. No network call."""
    if key in _DONE:
        return _DONE[key]
    done = False
    if KEY_RE.fullmatch(key):
        d = os.environ.get('HOLDS_MIRROR') or os.path.join(os.path.expanduser('~'), '.himmel', 'state', 'jira-mirror', key.split('-')[0])
        try:
            with open(os.path.join(d, key + '.md'), encoding='utf-8', errors='replace') as fh:
                for i, l in enumerate(fh):
                    if i > 30:
                        break
                    if l.startswith('statusCategory:'):
                        done = l.split(':', 1)[1].strip().strip('"') == 'Done'
                        break
        except OSError:
            pass  # swallow-ok: no mirror file proves nothing, so the row is not called stale
    _DONE[key] = done
    return done


def normalize(repo, p):
    """(slug, repo-relative name) for a path; None for a tree (a tree never holds)."""
    if not p or p.endswith('/'):
        return None
    if os.path.isabs(p):
        p = os.path.normpath(p)  # before the prefix match: a ".." must not carry a path out of (or into) the repo unseen
        for root in sorted(ALT_ROOTS, key=len, reverse=True) + [repo]:  # a worktree sits inside the primary: match it first
            prefix = root.rstrip('/') + '/'
            if p.startswith(prefix):
                return escape(repo), canon(p[len(prefix):], repo)
        return '_abs', p
    return escape(repo), canon(os.path.normpath(p), repo)


def read_row(path):
    """('ok', fields) | ('bad', None) | ('gone', None) | ('err', exc)."""
    try:
        with open(path, encoding='utf-8') as f:
            text = f.read()
    except FileNotFoundError:
        return 'gone', None
    except (OSError, UnicodeDecodeError) as e:
        return 'err', e
    fields = text.rstrip('\n').split('\t')
    if text.count('\n') > 1 or len(fields) != 5 or not KEY_RE.fullmatch(fields[0]) or fields[3] not in SOURCES:
        return 'bad', None
    return 'ok', fields


_tmp_n = [0]


def publish(d, name, text):
    """Write a temp file, then link(2) it as <name>: 'ok', or 'exists' when another contender won."""
    _tmp_n[0] += 1
    tmp = os.path.join(d, '%s%s.%d.%d' % (TMP_PREFIX, 'tmp', os.getpid(), _tmp_n[0]))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        os.write(fd, text.encode('utf-8'))
    finally:
        os.close(fd)
    try:
        os.link(tmp, os.path.join(d, name))
        return 'ok'
    except FileExistsError:
        return 'exists'
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass  # swallow-ok: the temp file is already gone; the link, or its absence, is the answer


def run_bounded(cmd, timeout, cwd=None):
    """(rc, stdout) or None on a timeout or a launch failure. The whole process group dies on a timeout."""
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, cwd=cwd, start_new_session=True)
    except OSError:
        return None
    try:
        out, _ = p.communicate(timeout=timeout)
        return p.returncode, out
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass  # swallow-ok: the group already exited
        p.communicate()
        return None


def ql_slug(path, root):
    """queue-lock.sh _ql_slug_for_root: the path relative to the root, .md dropped, / as __, every other byte but [A-Za-z0-9_-] a -."""
    p = path.replace('\\', '/')
    if p.endswith('.md'):
        p = p[:-3]
    root = root.replace('\\', '/').rstrip('/')
    if root and p.startswith(root + '/'):
        p = p[len(root) + 1:]
    p = p.replace('/', '__')
    return ''.join(c if re.fullmatch(r'[A-Za-z0-9_-]', c) else '-' * len(c.encode('utf-8')) for c in p)


def handover_root():
    r = os.environ.get('HANDOVER_DIR')
    if r:
        return r
    res = run_bounded(['bash', '-c', '. "$1" && handover_root', '_', os.path.join(HERE, '..', '..', 'lib', 'handover-path.sh')], 10)
    return res[1].strip() if res and res[0] == 0 else ''


class Judge:
    """Is a row's holder alive? By key: a doc of the key with a held lock, its PR open, the arm grace, or an
    unwrapped RESUME doc under 24 hours. Answers are cached per run: one queue-lock call per doc, one gh call per PR."""

    def __init__(self, repo, deadline=None):
        self.repo = repo
        self.deadline = deadline  # epoch seconds: past it no call is spawned (answer fault), and each call is bounded by what is left
        self.ql_cache, self.pr_cache, self.scan_cache, self.resume_cache = {}, {}, {}, {}
        self.sweep_rows = None  # the one queue-lock status --sweep of this run: a list of (slug, status), or 'fault'
        self.scan_faulted = set()
        self.root = None

    def left(self, timeout):
        """The timeout for one call: its own, or what is left of the deadline; 0 once the deadline has passed."""
        if self.deadline is None:
            return timeout
        return max(0, min(timeout, self.deadline - time.time()))

    def ql_path(self):
        return os.environ.get('HOLDS_QUEUE_LOCK') or os.path.join(HERE, '..', 'queue-lock.sh')

    def sweep(self):
        """The held locks as [(slug, status)], or 'fault': ONE queue-lock.sh status --sweep serves every doc of the run."""
        if self.sweep_rows is None:
            ql = self.ql_path()
            t = self.left(QL_TIMEOUT)
            res = run_bounded(['bash', ql, 'status', '--sweep'], t) if t > 0 and os.path.isfile(ql) else None
            if res is None or res[0] not in (0, 20):
                self.sweep_rows = 'fault'
            else:
                self.sweep_rows = []
                for l in res[1].splitlines():
                    m = re.match(r'slug=(\S+)\s.*?\bstatus=(\S+)', l)
                    if m:
                        self.sweep_rows.append((m.group(1), m.group(2)))
                    elif l.strip() == 'sweep: no held locks':
                        pass  # queue-lock.sh's stated empty sweep (rc 0), not a record
                    elif l.strip():
                        self.sweep_rows = 'fault'  # a record this reader cannot parse must not read as no lock
                        break
        return self.sweep_rows

    def lock_state(self, doc):
        """'free' | 'alive' | 'fault'. A sweep line names the doc when its slug is the doc's slug under the handover root, or
        ends __<the doc's basename slug>: no such line is free, STALE-DEAD is free, any other status (IDLE-HELD?, CORRUPT,
        UNKNOWN, INDETERMINATE too) is alive. A slug the sweep's 200-char cap could cut is put to one `status <doc>`."""
        if doc in self.ql_cache:
            return self.ql_cache[doc]
        if self.root is None:
            self.root = handover_root().rstrip('/')
        full, base = ql_slug(doc, self.root), ql_slug(os.path.basename(doc), '')
        if len(full) >= 200 or len(base) >= 200:
            st = self.lock_state_single(doc)
        else:
            rows = self.sweep()
            if rows == 'fault':
                st = 'fault'
            else:
                hits = [x for slug, x in rows if slug == full or slug == base or slug.endswith('__' + base)]
                st = 'alive' if any(x != 'STALE-DEAD' for x in hits) else 'free'
        self.ql_cache[doc] = st
        return st

    def lock_state_single(self, doc):
        ql = self.ql_path()
        t = self.left(QL_TIMEOUT)
        res = run_bounded(['bash', ql, 'status', doc], t) if t > 0 and os.path.isfile(ql) else None
        if res is None:
            return 'fault'
        if res[0] == 0:
            return 'free'
        if res[0] == 11:
            return 'alive'
        if res[0] == 12:
            return 'free' if 'STALE-DEAD' in res[1] else 'alive'  # plain STALE: death not proven, kept
        return 'fault'

    def pr_state(self, pr):
        """'open' | 'done' | 'fault' from one gh pr view, 5 s."""
        if pr in self.pr_cache:
            return self.pr_cache[pr]
        gh = os.environ.get('HOLDS_GH') or 'gh'
        t = self.left(GH_TIMEOUT)
        res = run_bounded([gh, 'pr', 'view', pr, '--json', 'state', '-q', '.state'], t, cwd=self.repo if os.path.isdir(self.repo) else None) if t > 0 else None
        if res is None or res[0] != 0:
            s = 'fault'
        else:
            v = res[1].strip().upper()
            s = 'open' if v == 'OPEN' else 'done' if v in ('MERGED', 'CLOSED') else 'fault'
        self.pr_cache[pr] = s
        return s

    def bucket_of(self, doc):
        if self.root is None:
            self.root = handover_root().rstrip('/')
        if self.root and doc.startswith(self.root + '/'):
            parts = doc[len(self.root) + 1:].split('/')
            if len(parts) >= 3:
                return os.path.join(self.root, parts[0], parts[1])
        return os.path.dirname(doc)

    def scan(self, bucket, key):
        """Docs named for the key under the bucket, at most 2 levels down, never specs/ or a dot directory."""
        ck = (bucket, key)
        if ck in self.scan_cache:
            return self.scan_cache[ck]
        rx = re.compile(r'(?<![A-Za-z0-9])' + re.escape(key) + r'(?!\d)')
        found = []
        base_depth = bucket.rstrip('/').count('/')

        def walk_error(e):
            if not isinstance(e, FileNotFoundError):
                self.scan_faulted.add(ck)  # an unreadable subtree may hold a live successor doc: unknown, not dead

        for dirpath, dirs, files in os.walk(bucket, onerror=walk_error):
            if dirpath.count('/') - base_depth >= 2:
                dirs[:] = []
            else:
                dirs[:] = [d for d in dirs if not d.startswith('.') and d != 'specs']
            for n in files:
                if n.endswith('.md') and not n.endswith(SIDECARS) and rx.search(n):
                    found.append(os.path.join(dirpath, n))
        self.scan_cache[ck] = sorted(found)
        return self.scan_cache[ck]

    def resume_alive(self, docs):
        """'alive' | 'none' | 'fault': an unwrapped RESUME doc of the key under 24 hours old."""
        res = 'none'
        info = []  # (doc, mtime, last mark, the line of that mark, the doc's other lines)
        for d in docs:
            try:
                mt = os.path.getmtime(d)
                last = ('', '')
                lines = open(d, encoding='utf-8', errors='replace').read().splitlines()
                for l in lines:
                    m = MARKER_RE.match(l)
                    if m:
                        last = (m.group(1), l)
            except FileNotFoundError:
                continue  # a doc that is gone holds nothing; its lock is still asked by row_state
            except OSError:
                res = 'fault'
                continue
            rest = [l for l in lines if l != last[1]]
            info.append((d, mt, last[0], last[1], rest))
        for d, mt, mark, _line, _rest in info:
            if 'RESUME' not in os.path.basename(d) or time.time() - mt >= RESUME_AGE or mark == 'WRAPPED':
                continue
            # a WRAPPED doc that names the RESUME doc outside its last bullet consumes it; a last bullet that names it hands
            # off to it. The file mtime, the leg number and the stem are no link: a RESUME doc made after its stem doc wrapped is live work.
            # ponytail: a successor that never names the doc holds for up to RESUME_AGE, a stem-named wrapped doc included; a recorded parent link is the upgrade path.
            b = os.path.basename(d)
            if any(m2 == 'WRAPPED' and b not in l2 and successor_of(b, r2)
                   for d2, _mt2, m2, l2, r2 in info if d2 != d):
                continue
            return 'alive'
        return res

    def row_state(self, fields, mtime):
        """'alive' | 'dead' | 'unknown' for a parsed row: alive beats a fault, a fault beats dead."""
        key, _label, doc, _source, pr = fields
        if mtime >= time.time() - GRACE:
            return 'alive'  # a future mtime counts as inside the grace
        faulted = False
        docs = []
        if doc:
            bucket = self.bucket_of(doc)
            docs = list(self.scan(bucket, key))
            faulted = (bucket, key) in self.scan_faulted or not self.root  # no handover root: the bucket is a guess
            if doc not in docs:
                docs.append(doc)  # a doc that is gone still has a lock to ask
        p = self.pr_state(pr) if pr else None
        if p == 'done':
            return 'dead'  # the row's own PR merged or closed: its work is over, whatever RESUME doc of the key is fresh
        ck = tuple(docs)
        if ck not in self.resume_cache:
            self.resume_cache[ck] = self.resume_alive(docs)  # once per doc set in a read, not once per row
        r = self.resume_cache[ck]
        if r == 'alive':
            return 'alive'
        faulted = faulted or r == 'fault'
        if p == 'open':
            return 'alive'
        faulted = faulted or p == 'fault'
        for d in docs:
            s = self.lock_state(d)
            if s == 'alive':
                return 'alive'
            faulted = faulted or s == 'fault'
        return 'unknown' if faulted else 'dead'


def dir_lock(d):
    """The directory's row-write lock as an fd, or None after LOCK_WAIT: the caller faults, it never hangs.
    The flock is on the directory itself, so the lock adds no file among the rows."""
    try:
        fd = os.open(d, os.O_RDONLY)
    except OSError:
        return None
    deadline = time.monotonic() + LOCK_WAIT
    while time.monotonic() < deadline:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            time.sleep(0.02)
        except OSError:
            break
    os.close(fd)
    return None


def dir_unlock(fd):
    os.close(fd)  # closing the only descriptor releases the flock


def successor_of(resume, rest):
    """A WRAPPED doc consumes a RESUME doc only through an explicit mention of it off its last bullet. A file mtime, a
    shared leg number and a shared stem are no link: a stale hold costs a 24 h wait, a wrong release a double launch."""
    return any(resume in l for l in rest)


GRANT_EXITS = 'Otherwise wait for its release, or the operator launches with WRITE_HOLD_OK=1.'


def refusal(path, fields, key):
    head = 'holds: %s is held by %s (%s, %s). Keep working on other files. This deny is logged' % (path, fields[0], fields[1], fields[3])
    try:
        trust = load_trust() or []
    except (re.error, UnicodeError):
        trust = []  # callers read rc 1 as a deny and pass on a crash, so a bad list costs the wording, never the deny
    route = grant_route(path, path, trust)
    if route == 'chief':
        return ('%s: this is a trust path, your chief sees it on its tick (hreg=) and can stamp a grant with --chief-doc, and '
                'the operator is paged with the grant command. %s' % (head, GRANT_EXITS))
    if route == 'operator':
        return ('%s: this is a settings or CI-workflow path, your chief sees it on its tick (hreg=), and only the operator '
                'grants it, paged with the command for a real terminal. %s' % (head, GRANT_EXITS))
    return '%s. Message your chief: HOLD-ASK %s %s' % (head, path, key)


def sync_denied_name(repo):
    return 'sync-denied.%s' % escape(repo)


def sync_denied_read(repo):
    try:
        with open(os.path.join(holds_root(), sync_denied_name(repo)), encoding='utf-8') as f:
            return set(f.read().splitlines())
    except FileNotFoundError:
        return set()
    except (OSError, UnicodeDecodeError) as e:
        sys.stderr.write('holds: cannot read %s: %s\n' % (sync_denied_name(repo), getattr(e, 'strerror', None) or e))
        return set()


def sync_denied_write(repo, lines):
    root = holds_root()
    try:
        os.makedirs(root, exist_ok=True)
        tmp = os.path.join(root, '%s%d.sync-denied' % (TMP_PREFIX, os.getpid()))
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(''.join(l + '\n' for l in sorted(lines)))
        os.replace(tmp, os.path.join(root, sync_denied_name(repo)))
    except OSError as e:
        sys.stderr.write('holds: cannot write %s: %s\n' % (sync_denied_name(repo), e.strerror or e))


def claim_one(repo, judge, path, key, label, doc, source, pr, created=None, seen=None):
    """-> 'claimed' | 'own' | 'granted' | 'skipped' | 'fault' | 'refused:<message>'."""
    norm = normalize(repo, path)
    if norm is None:
        return 'skipped'  # a tree is noted, not held
    slug, rel = norm
    if slug != '_abs' and os.path.exists(os.path.join(holds_root(), 'OFF')):
        return 'skipped'  # the barrier folded off drops every repo-file hold; a bucket file (_abs) cannot be merged forward, so it stays held
    if slug != '_abs' and rel in exempt_set():
        return 'skipped'
    name = escape(rel)
    if len(name.encode('utf-8')) > MAX_NAME:
        fault('path name over %d bytes' % MAX_NAME, rel, key)
        return 'fault'
    if GRANT_RE.search(name):
        fault('path name looks like a grant sibling', rel, key)  # a row by that name would read as a grant
        return 'fault'
    d = slug_dir(repo, slug)
    try:
        os.makedirs(d, exist_ok=True)
    except OSError as e:
        fault('register directory: %s' % (e.strerror or e), rel, key)
        return 'fault'
    mine = '\t'.join(clean(x) for x in (key, label, doc, source, pr)) + '\n'
    target = os.path.join(d, name)
    for _ in range(6):
        lock = dir_lock(d)
        if lock is None:
            fault('register lock not free', rel, key)
            return 'fault'
        try:
            res = publish(d, name, mine)
        except OSError as e:
            fault('register write: %s' % (e.strerror or e), rel, key)
            return 'fault'
        finally:
            dir_unlock(lock)
        if res == 'ok':
            if created is not None:
                created.append((target, mine))
            return 'claimed'
        st, fields = read_row(target)
        if st == 'gone':
            continue
        if st == 'err':
            fault('row unreadable: %s' % (getattr(fields, 'strerror', None) or fields), rel, key)
            return 'fault'
        if st == 'bad':
            fault('row unparseable, left in place', rel, key)
            return 'fault'
        if fields[0] == key:
            return 'own'
        if os.path.exists('%s.grant.%s' % (target, key)):
            return 'granted'
        try:
            mtime = os.path.getmtime(target)
        except OSError:
            continue
        state = judge.row_state(fields, mtime)
        if state == 'alive':
            if seen is None:
                log_event('deny', rel, key, fields[0])
            else:
                sig = '\t'.join(clean(x) for x in [rel, key] + fields)
                if sig not in seen[0] and sig not in seen[1]:
                    log_event('deny', rel, key, fields[0])
                seen[1].add(sig)
            return 'refused:' + refusal(rel, fields, key)
        if state == 'unknown':
            fault('holder liveness unproven', rel, key)
            return 'fault'
        # dead: take over by renaming the row aside, so a losing contender's rename fails. The judge above ran unlocked:
        # the compare below is what proves this is the row it judged, and no row is published while the lock is held.
        lock = dir_lock(d)
        if lock is None:
            fault('register lock not free', rel, key)
            return 'fault'
        try:
            _tmp_n[0] += 1
            moved = os.path.join(d, '%staken.%d.%d' % (TMP_PREFIX, os.getpid(), _tmp_n[0]))
            try:
                os.rename(target, moved)
            except FileNotFoundError:
                continue
            except OSError as e:
                fault('takeover rename: %s' % (e.strerror or e), rel, key)
                return 'fault'
            st2, f2 = read_row(moved)
            if st2 == 'ok' and f2 == fields and os.path.getmtime(moved) == mtime:  # a row freshened since it was judged dead is live again
                try:
                    os.unlink(moved)
                except OSError:
                    pass  # swallow-ok: a leftover %00taken file is skipped by every reader
                log_event('takeover', rel, key, fields[0])
                continue
            try:
                os.link(moved, target)  # the row moved was not the one judged: put it back and judge again
            except OSError:
                pass  # swallow-ok: the next round reads what is there
            try:
                os.unlink(moved)
            except OSError:
                pass  # swallow-ok: as above
        finally:
            dir_unlock(lock)
    fault('contention did not settle', rel, key)
    return 'fault'


def bad_key(key):
    if KEY_RE.fullmatch(key):
        return False
    sys.stderr.write('holds: %r is not a ticket key (PROJECT-123)\n' % key)
    return True


def op_claim(a):
    if bad_key(a.key):
        return 2
    repo = primary_of(a.repo)
    judge = Judge(repo)
    refused = []
    for p in a.paths:
        r = claim_one(repo, judge, p, a.key, a.label, a.doc, a.source, a.pr)
        if r.startswith('refused:'):
            refused.append(r[len('refused:'):])
    for m in refused:
        sys.stderr.write(m + '\n')
    return 1 if refused else 0


def has_writes(text):
    return any(l.startswith(WRITES_LEAD) for l in text.splitlines())


def fallback_text(judge, doc, key):
    """The text of the newest doc of the key (under the bucket of doc) that carries a Writes line, else None."""
    best = None
    for d in judge.scan(judge.bucket_of(doc), key):
        if d == doc:
            continue
        try:
            t = open(d, encoding='utf-8', errors='replace').read()
            m = os.path.getmtime(d)
        except OSError:
            continue  # swallow-ok: a doc that cannot be read is not a fallback; the next one is tried
        if has_writes(t) and (best is None or m > best[0]):
            best = (m, t)
    return best[1] if best else None


def seed_budget(a):
    return a.deadline if getattr(a, 'deadline', None) else time.time() + SEED_BUDGET


def seed_rows(repo, judge, key, label, doc, text, deadline):
    """-> (0 | 1 refused | 3 fault, refusal message). Refused: no row of this seed stays. A claim fault or a
    deadline passed: the rows made stay and the answer is 3."""
    if not has_writes(text) and 'RESUME' in os.path.basename(doc):
        text = fallback_text(judge, doc, key) or text  # a RESUME doc with no Writes line: the predecessor's
    created = []
    faulted = False
    claimed = False
    for kind, p in parse_text(text, repo):
        if kind != 'file':
            continue
        if deadline is not None and time.time() >= deadline:
            fault('seed deadline passed', p, key)
            return 3, 'holds: the seed deadline passed before %s' % p
        r = claim_one(repo, judge, p, key, label, doc, 'brief', '', created)
        if r.startswith('refused:'):
            for target, mine in created:  # all or nothing: remove only the rows this seed made
                st, f = read_row(target)
                if st == 'ok' and '\t'.join(f) + '\n' == mine:
                    try:
                        os.unlink(target)
                    except OSError:
                        pass  # swallow-ok: a row that vanished needs no removal
            return 1, r[len('refused:'):]
        faulted = faulted or r == 'fault'
        claimed = True
    if claimed and deadline is not None and time.time() >= deadline:
        fault('seed deadline passed', '', key)  # the last claim ran past it
        return 3, 'holds: the seed deadline passed during the last claim'
    return (3, 'holds: a claim faulted; see events.log') if faulted else (0, '')


def op_seed(a):
    if bad_key(a.key):
        return 2
    repo = primary_of(a.repo)
    try:
        text = open(a.doc, encoding='utf-8', errors='replace').read()
    except OSError as e:
        sys.stderr.write('holds: cannot read %s: %s\n' % (a.doc, e.strerror or e))
        return 3
    deadline = seed_budget(a)
    rc, msg = seed_rows(repo, Judge(repo, deadline), a.key, a.label, a.doc, text, deadline)
    if msg:
        sys.stderr.write(msg + '\n')
    return rc


def repoint_row(d, n, key, label, doc):
    """'repointed' | 'same' | 'skip' | 'fault': rewrite one row of key to doc and label, under the directory lock so a claimant cannot publish in the gap."""
    lock = dir_lock(d)
    if lock is None:
        fault('register lock not free', unescape(n), key)
        return 'fault'
    try:
        return repoint_locked(d, n, key, label, doc)
    finally:
        dir_unlock(lock)


def repoint_locked(d, n, key, label, doc):
    target = os.path.join(d, n)
    st, f = read_row(target)
    if st == 'gone' or st == 'bad' or (st == 'ok' and f[0] != key):
        return 'skip'  # a junk row names no holder, so it is no row of this key
    if st != 'ok':
        fault('row unreadable', unescape(n), key)
        return 'fault'
    if f[1] == label and f[2] == doc:
        return 'same'
    _tmp_n[0] += 1
    moved = os.path.join(d, '%smoved.%d.%d' % (TMP_PREFIX, os.getpid(), _tmp_n[0]))
    try:
        os.rename(target, moved)
    except FileNotFoundError:
        return 'skip'
    except OSError as e:
        fault('repoint rename: %s' % (e.strerror or e), unescape(n), key)
        return 'fault'
    st2, f2 = read_row(moved)
    res = 'skip'
    if st2 == 'ok' and f2 == f:
        try:
            publish(d, n, '\t'.join(clean(x) for x in (key, label, doc, f[3], f[4])) + '\n')  # 'exists': a fresher holder published in the gap and keeps its row
            res = 'repointed'
        except OSError as e:
            fault('repoint write: %s' % (e.strerror or e), unescape(n), key)
            res = 'fault'
            try:
                os.link(moved, target)  # keep the old row: a failed write must not erase the hold
            except OSError:
                pass  # swallow-ok: a fresher holder published meanwhile and keeps its row
    else:
        try:
            os.link(moved, target)  # the row moved was not the one judged (another key's): put it back
        except OSError:
            pass  # swallow-ok: someone published a newer row meanwhile; the next reader sees it
    try:
        os.unlink(moved)
    except OSError:
        pass  # swallow-ok: a leftover %00moved file is skipped by every reader
    return res


def op_repoint(a):
    if bad_key(a.key):
        return 2
    repo = primary_of(a.repo)
    deadline = seed_budget(a)
    rc = 0
    repointed = False
    for d in (slug_dir(repo), slug_dir(repo, '_abs')):
        try:
            names = sorted(os.listdir(d))
        except FileNotFoundError:
            continue
        except OSError as e:
            sys.stderr.write('holds: cannot read %s: %s\n' % (d, e.strerror or e))
            return 3
        for n in names:
            if n.startswith(TMP_PREFIX) or GRANT_RE.search(n):
                continue
            if time.time() >= deadline:
                fault('repoint deadline passed', '', a.key)
                sys.stderr.write('holds: the repoint deadline passed\n')
                return 3
            if repoint_row(d, n, a.key, a.label, a.doc) == 'fault':
                rc = 3
            repointed = True
    if repointed and time.time() >= deadline:
        fault('repoint deadline passed', '', a.key)  # the last row ran past it
        sys.stderr.write('holds: the repoint deadline passed during the last row\n')
        return 3
    return rc


def op_backfill(a):
    """Seed rows for every manifest worker not WRAPPED, with that worker's doc and label. One line per worker."""
    repo = primary_of(a.repo)
    try:
        with open(a.manifest, encoding='utf-8') as fh:
            m = json.load(fh)
        workers = m.get('workers') or m.get('legs') or []
    except (OSError, ValueError, AttributeError) as e:
        sys.stderr.write('holds: cannot read the manifest %s: %s\n' % (a.manifest, getattr(e, 'strerror', None) or e))
        return 3
    judge = Judge(repo)
    rc = 0
    for w in workers:
        doc, label = w.get('doc') or '', w.get('label') or ''
        km = re.search(r'[A-Z][A-Z0-9]*-[0-9]+', os.path.basename(doc))
        try:
            text = open(doc, encoding='utf-8', errors='replace').read()
        except OSError:
            print('backfill: %s nodoc' % label)
            continue
        marks = [x.group(1) for x in (MARKER_RE.match(l) for l in text.splitlines()) if x]
        if marks and marks[-1] == 'WRAPPED':
            print('backfill: %s wrapped' % label)
            continue
        if not km:
            print('backfill: %s nokey' % label)
            continue
        r, msg = seed_rows(repo, judge, km.group(0), label, doc, text, None)
        print('backfill: %s %s' % (label, 'seeded' if r == 0 else 'overlap' if r == 1 else 'fault'))
        if msg:
            sys.stderr.write(msg + '\n')
        if r == 3:
            rc = 3
    return rc


def load_trust():
    path = os.path.join(HERE, '..', '..', 'ci', 'ci-trust-paths.txt')
    try:
        return [re.compile(l.strip()) for l in open(path, encoding='utf-8') if l.strip() and not l.startswith('#')]
    except OSError:
        return None


GRANT_PATH_REFUSED_RE = re.compile(r'(^|/)[^/]*settings[^/]*\.json$|^\.github/')  # gen-briefs.py validate_grants reads this one
BAD_CHAR_RE = re.compile(r'[\x00-\x1f\x7f`]')


def literal_repo_path(p, repo):
    """A grant path is one literal repo-relative file path, normalised: the anchored refusals below only see that spelling."""
    return not (not isinstance(p, str) or not p.strip() or p != p.strip() or BAD_CHAR_RE.search(p) or os.path.isabs(p)
                or p != os.path.normpath(p) or p == '.' or re.search(r'[*?\[]', p) or '..' in p.split('/')
                or os.path.isdir(os.path.join(repo, p)))


def worker_session():
    return bool(os.environ.get('HIMMEL_CONSOLE_LEG'))


def grant_route(p, rel, trust):
    """Who may grant a path: 'operator' (settings or CI workflow), 'chief' (a trust path) or 'any' (every other path)."""
    if any(GRANT_PATH_REFUSED_RE.search(x) for x in (p, rel)):
        return 'operator'
    if any(r.search(x) for r in trust for x in (p, rel)):
        return 'chief'
    return 'any'


CHIEF_DOC_RE = re.compile(r'-(chief|console)\.md$', re.I)  # the role test of arm-resume.sh and append-results.sh: *-chief.md / *-console.md


def lock_dir_for(doc, session):
    """The queue-lock dir whose owner.json names doc and session: <handover root>/.locks/queue/*.lock, root found by
    walking up from doc. None when there is none."""
    d = os.path.dirname(doc)
    for _ in range(64):
        q = os.path.join(d, '.locks', 'queue')
        if os.path.isdir(q):
            for n in sorted(os.listdir(q)):
                try:
                    with open(os.path.join(q, n, 'owner.json')) as f:
                        o = json.load(f)
                except (OSError, ValueError):
                    continue
                if isinstance(o, dict) and o.get('handover') == doc and o.get('session') == session:
                    return os.path.join(q, n)
            return None
        up = os.path.dirname(d)
        if up == d:
            return None
        d = up
    return None


def caller_session():
    """The Claude session id of the caller's nearest ancestor with a <claude config>/sessions/<pid>.json naming that
    pid, or ''. Only the nearest: a Claude session nested under the chief is not the chief."""
    sdir = os.path.join(os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(os.path.expanduser('~'), '.claude'), 'sessions')
    pid, seen = os.getppid(), 0
    while pid > 1 and seen < 64:
        seen += 1
        try:
            with open(os.path.join(sdir, '%d.json' % pid)) as f:
                s = json.load(f)
            if isinstance(s, dict) and s.get('pid') == pid and s.get('sessionId'):
                return str(s['sessionId'])
        except (OSError, ValueError):
            pass  # swallow-ok: an ancestor with no readable session file is no Claude session; the walk goes on up
        res = run_bounded(['ps', '-o', 'ppid=', '-p', str(pid)], QL_TIMEOUT)
        try:
            pid = int(res[1].strip()) if res and res[0] == 0 else 0
        except ValueError:
            pid = 0
    return ''


def chief_session(doc):
    """(session, '') when doc is a chief doc whose queue lock is held, fresh, on this host, by the caller's own
    (nearest) Claude session; else (None, why). The real queue-lock.sh, never HOLDS_QUEUE_LOCK: this check loosens
    the barrier, so a test seam must not stand in for it."""
    if not os.path.isfile(doc):
        return None, 'the chief doc %s does not exist' % doc
    if not CHIEF_DOC_RE.search(os.path.basename(doc)):
        return None, '%s is not a chief doc (a chief doc is named *-chief.md or *-console.md)' % doc
    res = run_bounded(['bash', os.path.join(HERE, '..', 'queue-lock.sh'), 'status', doc], QL_TIMEOUT)
    if res is None or res[0] != 11:
        return None, 'the queue lock on %s is not held (status rc %s)' % (doc, res[0] if res else 'timeout')
    owner = None
    for l in res[1].splitlines():
        if l.startswith('{'):
            try:
                owner = json.loads(l)
            except ValueError:
                pass  # swallow-ok: an unparsable owner is no proof of a holder; owner stays None and the grant is refused
            break
    if not isinstance(owner, dict) or not owner.get('session'):
        return None, 'the queue lock on %s names no owner' % doc
    if owner.get('host') != socket.gethostname():
        return None, 'the queue lock on %s is held on another host (%s)' % (doc, owner.get('host'))
    try:
        time.strptime(str(owner.get('heartbeat')), '%Y-%m-%dT%H:%M:%SZ')
    except ValueError:
        # queue-lock.sh reads an unparsable heartbeat as FRESH so it never steals a lock; a grant cannot lean on that
        return None, 'the queue lock on %s has an unparsable heartbeat' % doc
    lk = lock_dir_for(doc, owner['session'])
    holder = ''
    try:
        with open(os.path.join(lk, 'liveness')) as f:
            for l in f:
                if l.startswith('transcript='):
                    holder = os.path.basename(l[len('transcript='):].strip())
                    holder = holder[:-len('.jsonl')] if holder.endswith('.jsonl') else ''
    except (OSError, TypeError):
        pass  # swallow-ok: no liveness marker names no holder session; holder stays '' and the grant is refused
    if not holder:
        return None, 'the queue lock on %s names no holder Claude session (no liveness marker)' % doc
    # ponytail: the liveness marker and ~/.claude/sessions/<pid>.json are files of this user, so a same-user process can
    # forge either; this binds a session that uses the kit's own paths, upgrade path: the lock records the holder claude pid
    if holder != caller_session():
        return None, 'the queue lock on %s is held by Claude session %s, which is not this caller' % (doc, holder)
    return clean(owner['session']), ''


def operator_confirm(p):
    """The operator route: a human at a terminal types the path back. ('ok' | 'no-tty' | 'mismatch', session)."""
    # ponytail: a terminal plus a typed-back path proves a human only as far as an agent cannot fake a pty with the Claude
    # Code markers unset; the barrier is a coordination guard and a trust-path PR still needs a trust judge, upgrade path: a TOTP-confirmed operator approval
    marked = any(k == 'CLAUDECODE' or k.startswith('CLAUDE_CODE_') for k in os.environ)  # the marker set of chokepoint-seam-guard.sh
    if marked or not (sys.stdin.isatty() and sys.stderr.isatty()):
        return 'no-tty', ''
    sys.stderr.write('holds: grant a hold on %s. To confirm you are the operator, type the path back: ' % p)
    sys.stderr.flush()
    typed = sys.stdin.readline().strip()
    try:
        tty = os.ttyname(0)
    except OSError:
        tty = 'tty'
    return ('ok' if typed == p else 'mismatch'), clean('%s@%s:%s' % (os.environ.get('USER', '?'), socket.gethostname(), tty))


def op_grant(a):
    if worker_session():
        sys.stderr.write('holds: grant is refused for a worker session (HIMMEL_CONSOLE_LEG is set); only the chief grants\n')
        return 1
    if bad_key(a.key):
        return 2
    repo = primary_of(a.repo)
    p = a.path
    if not literal_repo_path(p, repo):
        sys.stderr.write('holds: %r must be a literal repo-relative file path\n' % p)
        return 2
    trust = load_trust()
    if trust is None:
        sys.stderr.write('holds: cannot read the trust paths; a grant cannot be checked against them\n')
        return 2
    slug, rel = escape(repo), canon(p, repo)  # the grant is written on rel, so rel is what the trust test must see too
    route = grant_route(p, rel, trust)
    own_doc = os.environ.get('HIMMEL_CONSOLE_DOC') or ''
    chief_doc = a.chief_doc or own_doc
    grantor, session = 'unchecked', ''  # a path off every list: any non-worker caller grants it, as before
    if route == 'chief' and chief_doc:
        # a chief session launched by headed-arm.sh names its own doc in HIMMEL_CONSOLE_DOC; chief_session binds the rest
        if own_doc and os.path.abspath(own_doc) != os.path.abspath(chief_doc):
            sys.stderr.write('holds: --chief-doc %s is not this chief session\'s own doc (HIMMEL_CONSOLE_DOC=%s); no grant\n' % (chief_doc, own_doc))
            return 1
        session, why = chief_session(os.path.abspath(chief_doc))
        if session is None:
            sys.stderr.write('holds: %s is a trust path; the chief grant is refused: %s\n' % (p, why))
            return 1
        grantor = 'chief'
    elif route != 'any':
        st, session = operator_confirm(p)
        if st != 'ok':
            line = 'python3 -I %s grant --key %s --repo %s' % (os.path.abspath(__file__), a.key, a.repo)
            if route == 'chief':
                sys.stderr.write('holds: %s is a trust path. The chief stamps it from its own session, naming its own doc (its '
                                 'queue lock held on this host): %s --chief-doc CHIEF_DOC %s . The operator grants it only in a real '
                                 'terminal, not a ! line in a Claude window: %s %s . From a Claude window, the operator asks the '
                                 'chief, who stamps the grant. Otherwise wait for its release, or the operator launches with '
                                 'WRITE_HOLD_OK=1.\n' % (p, line, p, line, p))
            else:
                sys.stderr.write('holds: %s is a settings or CI-workflow path; only the operator grants it, and only in a real '
                                 'terminal, not a ! line in a Claude window (the chief cannot stamp it): %s %s . Otherwise wait for '
                                 'its release, or the operator launches with WRITE_HOLD_OK=1.\n' % (p, line, p))
            if st == 'mismatch':
                sys.stderr.write('holds: the path typed back did not match; no grant\n')
            return 1
        grantor = 'operator'
    d = slug_dir(repo, slug)
    try:
        os.makedirs(d, exist_ok=True)
        publish(d, '%s.grant.%s' % (escape(rel), a.key), 'granted\t%s\t%s\t%s\n' % (now_iso(), grantor, session))
    except OSError as e:
        sys.stderr.write('holds: cannot write the grant: %s\n' % (e.strerror or e))
        return 2
    log_event('grant', rel, a.key, 'grantor=%s session=%s' % (grantor, session))
    return 0


def op_grant_route(a):
    repo = primary_of(a.repo)
    trust = load_trust()
    if trust is None or not literal_repo_path(a.path, repo):
        return 2
    print(grant_route(a.path, canon(a.path, repo), trust))
    return 0


def op_off(a):
    if worker_session():
        sys.stderr.write('holds: off is refused for a worker session (HIMMEL_CONSOLE_LEG is set); only the chief switches the barrier off\n')
        return 1
    root = holds_root()
    try:
        os.makedirs(root, exist_ok=True)
        tmp = os.path.join(root, '%s%d.off' % (TMP_PREFIX, os.getpid()))
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write('%s\t%s\n' % (now_iso(), clean(a.reason)))
        os.replace(tmp, os.path.join(root, 'OFF'))
    except OSError as e:
        sys.stderr.write('holds: cannot write the sentinel: %s\n' % (e.strerror or e))
        return 2
    log_event('off', '', '', a.reason)
    return 0


def op_on(a):
    if worker_session():
        sys.stderr.write('holds: on is refused for a worker session (HIMMEL_CONSOLE_LEG is set)\n')
        return 1
    try:
        os.unlink(os.path.join(holds_root(), 'OFF'))
        log_event('on', '', '', '')
    except FileNotFoundError:
        pass  # swallow-ok: the barrier was already on; a backfill below still seeds the workers launched meanwhile
    except OSError as e:
        sys.stderr.write('holds: cannot remove the sentinel: %s\n' % (e.strerror or e))
        return 2
    # workers launched while the barrier was off hold no rows: seed them from the chief's fleet manifest
    manifest = a.workers_from
    doc = os.environ.get('HIMMEL_CONSOLE_DOC') or ''
    if not manifest and doc.endswith('.md') and os.path.isfile(doc[:-3] + '.fleet.json'):
        manifest = doc[:-3] + '.fleet.json'
    if not manifest:
        return 0
    a.manifest, a.repo = manifest, a.repo or os.getcwd()
    return op_backfill(a)


def op_release(a):
    repo = primary_of(a.repo)
    for d in (slug_dir(repo), slug_dir(repo, '_abs')):  # _abs holds the rows a seed made for bucket files
        try:
            names = os.listdir(d)
        except FileNotFoundError:
            continue
        except OSError as e:
            sys.stderr.write('holds: cannot read %s: %s\n' % (d, e.strerror or e))
            return 3
        for n in names:
            if n.startswith(TMP_PREFIX) or GRANT_RE.search(n):
                continue
            st, f = read_row(os.path.join(d, n))
            if st == 'ok' and f[0] == a.key and f[2] == a.doc and f[3] == 'brief':
                try:
                    os.unlink(os.path.join(d, n))
                except OSError:
                    pass  # swallow-ok: already removed
    return 0


def op_alive(a):
    repo = primary_of(a.repo)
    norm = normalize(repo, a.path)
    if norm is None:
        print('dead')
        return 0
    target = os.path.join(slug_dir(repo, norm[0]), escape(norm[1]))
    st, f = read_row(target)
    if st == 'gone':
        print('dead')
    elif st != 'ok':
        print('unknown')
    else:
        print(Judge(repo).row_state(f, os.path.getmtime(target)))
    return 0


def row_key(path):
    """The key of a row that does not parse, when its first field is still a ticket key; else '?'."""
    try:
        with open(path, 'rb') as f:
            first = f.read().split(b'\t')[0].decode('utf-8')  # only the first field is decoded: junk after it keeps the key
    except (OSError, UnicodeDecodeError):
        return '?'
    return first if KEY_RE.fullmatch(first) else '?'


def op_read(a):
    """TSV path key label source pr state. state is alive, dead, unknown or unparseable; only dead reads as free.
    --keys prints key state rows per holder instead, whatever --paths-from says, and walks the bucket-file rows (_abs) too;
    a row it cannot read counts its key (? when the key is unreadable too) as unknown and is named on stderr, never
    dropped and never free (exit 0). A --paths-from line ending in / selects every row under that directory.
    Exit 3 when a register directory or the --paths-from file cannot be read; a missing directory is no rows."""
    repo = primary_of(a.repo)
    dirs = [slug_dir(repo)] + ([slug_dir(repo, '_abs')] if a.keys else [])
    want, trees = None, []
    if a.paths_from and not a.keys:
        try:
            want = set()
            for l in open(a.paths_from, encoding='utf-8'):
                l = l.strip()
                if not l:
                    continue
                n = normalize(repo, l.rstrip('/')) if l.endswith('/') else normalize(repo, l)
                if n and l.endswith('/'):
                    trees.append(n[1] + '/')
                elif n:
                    want.add(n[1])
        except OSError as e:
            sys.stderr.write('holds: cannot read %s: %s\n' % (a.paths_from, e.strerror or e))
            return 3
    judge = Judge(repo)
    keys = {}
    unreadable = []
    for d in dirs:
        try:
            names = sorted(os.listdir(d))
        except FileNotFoundError:
            continue  # no directory is no rows
        except OSError as e:
            sys.stderr.write('holds: cannot read %s: %s\n' % (d, e.strerror or e))
            return 3
        for n in names:
            if n.startswith(TMP_PREFIX) or GRANT_RE.search(n):
                continue
            path = unescape(n)
            if want is not None and path not in want and not any(path.startswith(t) for t in trees):
                continue
            full = os.path.join(d, n)
            st, f = read_row(full)
            if st == 'gone':
                continue
            if st != 'ok':
                if not a.keys:
                    print('\t'.join([path, '?', '?', '?', '', 'unparseable']))
                else:
                    unreadable.append(path)  # never dropped and never free: its key (or ?) reads unknown
                    cur = keys.setdefault(row_key(full), ['unknown', 0])
                    cur[1] += 1
                    cur[0] = 'unknown' if cur[0] == 'dead' else cur[0]
                continue
            try:
                state = judge.row_state(f, os.path.getmtime(full))
            except OSError:
                continue
            if a.keys:
                cur = keys.setdefault(f[0], ['dead', 0])
                cur[1] += 1
                rank = {'alive': 0, 'unknown': 1, 'dead': 2}
                if rank[state] < rank[cur[0]]:
                    cur[0] = state
            else:
                print('\t'.join([path, f[0], f[1], f[3], f[4], state]))
    for k in sorted(keys):
        print('\t'.join([k, keys[k][0], str(keys[k][1])]))
    if unreadable:
        sys.stderr.write('holds: %d row(s) cannot be read, counted unknown: %s\n' % (len(unreadable), ', '.join(unreadable)))
    return 0


BOX = 10  # seconds a sync-prs or gc run may take; past it the run stops with exit 0, the rest waits for the next wake


def op_sync_prs(a):
    """Rows for the files of open PRs. --files-from is TSV pr head title-key path. A file with no live row gets a pr row
    (key = the title's key, else PR-<n>; label branch:<head>); a live row is left alone; every listed PR's rows are freshened."""
    repo = primary_of(a.repo)
    try:
        lines = open(a.files_from, encoding='utf-8').read().splitlines()
    except OSError as e:
        sys.stderr.write('holds: cannot read %s: %s\n' % (a.files_from, e.strerror or e))
        return 3
    deadline = time.time() + BOX
    judge = Judge(repo, deadline)
    prs = set()
    seen = (sync_denied_read(repo), set())
    cut = False
    for l in lines:
        f = (l.split('\t') + ['', '', '', ''])[:4]
        pr, head, tkey, path = [x.strip() for x in f]
        if not pr or not path:
            continue
        prs.add(pr)
        if time.time() >= deadline:
            cut = True
            break
        m = re.search(r'[A-Za-z][A-Za-z0-9]*-\d+', tkey)  # the field is the title or its key: the first ticket key in it
        key = m.group(0) if m else 'PR-%s' % pr
        claim_one(repo, judge, path, key, 'branch:%s' % head, '', 'pr', pr, seen=seen)
    if not cut and seen[1] != seen[0]:
        sync_denied_write(repo, seen[1])
    for d in (slug_dir(repo), slug_dir(repo, '_abs')):
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            if n.startswith(TMP_PREFIX) or GRANT_RE.search(n):
                continue
            st, f = read_row(os.path.join(d, n))
            if st == 'ok' and f[3] == 'pr' and f[4] in prs:
                try:
                    os.utime(os.path.join(d, n))
                except OSError:
                    pass  # swallow-ok: the row went away; the next wake reads what is there
    return 0


def remove_dead(d, n, fields, mtime):
    """Take a row judged dead out under the directory lock: rename aside, compare, unlink; put it back when it changed. -> bool removed."""
    lock = dir_lock(d)
    if lock is None:
        return False
    target = os.path.join(d, n)
    try:
        _tmp_n[0] += 1
        moved = os.path.join(d, '%sgc.%d.%d' % (TMP_PREFIX, os.getpid(), _tmp_n[0]))
        try:
            os.rename(target, moved)
        except OSError:
            return False
        st, f2 = read_row(moved)
        if st == 'ok' and f2 == fields and os.path.getmtime(moved) == mtime:  # a row freshened since it was judged dead is live again
            try:
                os.unlink(moved)
            except OSError:
                pass  # swallow-ok: a leftover %00gc file is skipped by every reader
            return True
        try:
            os.link(moved, target)
        except OSError:
            pass  # swallow-ok: the next wake reads what is there
        try:
            os.unlink(moved)
        except OSError:
            pass  # swallow-ok: as above
        return False
    finally:
        dir_unlock(lock)


def op_gc(a):
    """Remove the rows whose holder is dead, with their grant siblings; a dead key's grants go too. A brief or pr row of a key
    the Jira mirror reads Done goes too, whatever its lock says. Rows inside the arm grace are not judged. A fault or a row it cannot read keeps the row. Stops at the BOX with exit 0."""
    repo = primary_of(a.repo)
    deadline = time.time() + BOX
    judge = Judge(repo, deadline)
    key_state = {}
    removed = 0
    for d in (slug_dir(repo), slug_dir(repo, '_abs')):
        try:
            names = sorted(os.listdir(d))
        except FileNotFoundError:
            continue
        except OSError as e:
            sys.stderr.write('holds: cannot read %s: %s\n' % (d, e.strerror or e))
            return 3
        for n in names:
            if n.startswith(TMP_PREFIX) or GRANT_RE.search(n):
                continue
            if time.time() >= deadline:
                return 0
            full = os.path.join(d, n)
            st, f = read_row(full)
            if st != 'ok':
                continue
            try:
                mt = os.path.getmtime(full)
            except OSError:
                continue
            if f[3] in ('brief', 'pr') and mt < time.time() - GRACE and mirror_done(f[0]):
                # a Done key holds nothing, whatever its worker's lock or RESUME doc still says
                key_state[f[0]] = 'dead'
                if remove_dead(d, n, f, mt):
                    removed += 1
                    log_event('gc', unescape(n), f[0], 'key Done')
                continue
            state = judge.row_state(f, mt)
            rank = {'alive': 0, 'unknown': 1, 'dead': 2}
            if f[0] not in key_state or rank[state] < rank[key_state[f[0]]]:
                key_state[f[0]] = state
            if state == 'dead' and remove_dead(d, n, f, mt):
                removed += 1
                log_event('gc', unescape(n), f[0], '')
        for n in names:
            m = GRANT_RE.search(n)
            if not m or time.time() >= deadline:
                continue
            gkey = m.group(0).rsplit('.', 1)[1]
            if not os.path.exists(os.path.join(d, n[:m.start()])) or key_state.get(gkey) == 'dead':
                try:
                    os.unlink(os.path.join(d, n))
                except OSError:
                    pass  # swallow-ok: already removed
    return 0


ASK_AGE = 24 * 3600      # a deny older than this is not an ask the chief still owes
ASK_TAIL = 256 * 1024    # bytes of events.log read for the asks: the log grows without bound, a day of denies is far under this


def pending_asks(repo):
    """[(key, path, holder)]: a trust-path (or settings or CI workflow) deny from the last day that no grant answers, whose
    holder's row still holds the path here, whose asker's key is not Done. Local files only."""
    trust = load_trust()
    if trust is None:
        return []
    asks = {}
    try:
        with open(os.path.join(holds_root(), 'events.log'), 'rb') as fh:
            size = fh.seek(0, os.SEEK_END)
            fh.seek(max(0, size - ASK_TAIL))
            data = fh.read().decode('utf-8', 'replace')
    except FileNotFoundError:
        return []  # no log, no denies; any other read error propagates as a fault (the tick shows hreg=?)
    lines = data.split('\n')
    if size > ASK_TAIL:
        lines = lines[1:]  # the first line of the tail is cut
    for l in lines:
        c = l.split('\t')
        if len(c) < 5 or c[1] not in ('deny', 'grant'):
            continue
        if c[1] == 'grant':
            asks.pop((c[2], c[3]), None)
            continue
        try:
            asks[(c[2], c[3])] = (c[4], calendar.timegm(time.strptime(c[0], '%Y-%m-%dT%H:%M:%SZ')))
        except ValueError:
            continue
    out = []
    d = slug_dir(repo)
    for (path, key), (holder, ts) in sorted(asks.items()):
        if time.time() - ts >= ASK_AGE or not KEY_RE.fullmatch(key) or mirror_done(key):
            continue
        if grant_route(path, canon(path, repo), trust) == 'any':
            continue
        name = escape(path)
        if os.path.exists(os.path.join(d, '%s.grant.%s' % (name, key))):
            continue
        st, f = read_row(os.path.join(d, name))
        if st == 'ok' and f[0] == holder:
            out.append((key, path, holder))
    return out


def op_asks(a):
    """TSV key path holder command, one per pending trust-path ask: the command is the paste-ready grant."""
    repo = primary_of(a.repo)
    kit = os.path.abspath(os.path.join(HERE, '..', '..', '..'))  # the checkout this holds.py runs from, whatever --repo names
    try:
        kit = primary_of(kit)
    except RepoFault:
        pass  # swallow-ok: no git identity for the kit checkout; its own path is the best command there is
    script = os.path.join(kit, 'scripts', 'handover', 'chief-kit', 'holds.py')
    for key, path, holder in pending_asks(repo):
        print('\t'.join([key, path, holder, 'python3 -I %s grant --key %s --repo %s %s'
                         % (shlex.quote(script), key, shlex.quote(repo), shlex.quote(path))]))
    return 0


def op_summary(a):
    """live-no-rows/stale/pending-asks, from local state only (no gh, no network): the tick's hreg= field. Nothing is
    printed when this repo has no register directory. --live-docs names (one per line, - for stdin) the docs of the
    chief's live workers; one counts when it carries a Writes file and its key holds no row. A row is stale when its key
    is Done in the Jira mirror, or it is a pr row whose PR is not in --open-prs (a comma list; absent or ? skips that test)."""
    repo = primary_of(a.repo)
    d0 = slug_dir(repo)
    if not os.path.isdir(d0):
        return 0
    open_prs = None
    if a.open_prs and a.open_prs != '?':
        open_prs = {x.strip().lstrip('#') for x in a.open_prs.split(',') if x.strip()} - {'none'}
    have, stale = set(), 0
    for d in (d0, slug_dir(repo, '_abs')):
        try:
            names = os.listdir(d)
        except FileNotFoundError:
            continue
        except OSError as e:
            sys.stderr.write('holds: cannot read %s: %s\n' % (d, e.strerror or e))
            return 3  # an unreadable register is hreg=?, never a clean 0
        for n in names:
            if n.startswith(TMP_PREFIX) or GRANT_RE.search(n):
                continue
            full = os.path.join(d, n)
            st, f = read_row(full)
            if st == 'ok':
                have.add(f[0])
                if f[3] in ('brief', 'pr') and (mirror_done(f[0]) or (f[3] == 'pr' and f[4] and open_prs is not None and f[4] not in open_prs)):
                    stale += 1
            elif st == 'bad':
                have.add(row_key(full))
    docs = []
    if a.live_docs:
        try:
            docs = [l.strip() for l in (sys.stdin if a.live_docs == '-' else open(a.live_docs, encoding='utf-8')) if l.strip()]
        except OSError as e:
            sys.stderr.write('holds: cannot read %s: %s\n' % (a.live_docs, e.strerror or e))
            return 3
    norows, seen = 0, set()
    for doc in docs:
        km = re.search(r'[A-Z][A-Z0-9]*-[0-9]+', os.path.basename(doc))
        if not km or km.group(0) in have or km.group(0) in seen:
            continue
        seen.add(km.group(0))
        try:
            text = open(doc, encoding='utf-8', errors='replace').read()
        except OSError:
            continue  # swallow-ok: a worker doc that is gone or unreadable is no live worker to seed
        if any(kind == 'file' for kind, _p in parse_text(text, repo)):
            norows += 1
    print('%d/%d/%d' % (norows, stale, len(pending_asks(repo))))
    return 0


def op_parse(a):
    repo = os.path.abspath(a.repo) if a.repo else os.getcwd()
    try:
        text = open(a.doc, encoding='utf-8', errors='replace').read()
    except OSError as e:
        sys.stderr.write('holds: cannot read %s: %s\n' % (a.doc, e.strerror or e))
        return 3
    for kind, p in parse_text(text, repo):
        print('%s\t%s' % (kind, p))
    return 0


PR_STALE = 30 * 60       # a pr row not freshened by sync-prs for this long no longer holds a push
CHECK_BUDGET = 15        # seconds a git-check run may spend judging holders; past it a holder reads unknown and passes
BASE_RE = re.compile(r'^[A-Za-z0-9_][A-Za-z0-9._/-]*$')


def git_text(args, cwd):
    """The stdout of one git call in cwd with the caller's GIT_* kept (GIT_INDEX_FILE names the temporary index of
    `git commit -a` and `git commit <path>`), or None on any failure."""
    try:
        r = subprocess.run(['git'] + args, capture_output=True, timeout=10, cwd=cwd)
    except (OSError, subprocess.SubprocessError):
        return None
    return os.fsdecode(r.stdout) if r.returncode == 0 else None


def git_names(args, cwd):
    out = git_text(args, cwd)
    return None if out is None else [n for n in out.split('\0') if n]


def pr_base(cwd):
    """The base branch of this branch's open PR as HOLDS_GH reads it, else ''."""
    res = run_bounded([os.environ.get('HOLDS_GH') or 'gh', 'pr', 'view', '--json', 'baseRefName', '-q', '.baseRefName'], GH_TIMEOUT, cwd=cwd)
    b = res[1].strip() if res and res[0] == 0 else ''
    return b if BASE_RE.match(b) else ''


def pr_row_passes(fields, row, key, branch):
    """True for a pr row of another key that holds nothing against this branch: its own PR row (label branch:<branch>), or a
    row sync-prs stopped freshening more than PR_STALE ago. A row with a doc is a worker's narrowed claim (narrow --apply):
    it holds while its holder is alive, whatever its age, so it never passes; only sync-prs rows (no doc) get the exception."""
    if fields[3] != 'pr' or fields[0] == key or fields[2]:
        return False
    try:
        age = time.time() - os.path.getmtime(row)
    except OSError:
        age = 0
    return fields[1] == 'branch:%s' % branch or age > PR_STALE


def op_git_check(a):
    """Refuse (exit 1, the holder on stderr) when git's own list of staged files (--staged) or of files the branch adds over
    its base (--push) names a file another live holder holds. It reads no command text, so no shape of write dodges it.
    A file nobody holds is claimed. Every fault, and every worker the barrier does not know, exits 0."""
    key, doc, label = (os.environ.get(k) or '' for k in ('HIMMEL_HOLD_KEY', 'HIMMEL_HOLD_DOC', 'HIMMEL_HOLD_LABEL'))
    if os.environ.get('WRITE_HOLD_OK') == '1' or not KEY_RE.fullmatch(key) or not os.path.isabs(doc):
        return 0
    if os.path.exists(os.path.join(holds_root(), 'OFF')):
        return 0
    cwd = os.getcwd()
    repo = primary_of(cwd)
    if os.path.exists(os.path.join(repo, '.single-writer')):
        return 0
    branch = (git_text(['rev-parse', '--abbrev-ref', 'HEAD'], cwd) or '').strip()
    if a.staged:
        for n in ('rebase-merge', 'rebase-apply', 'MERGE_HEAD'):  # a replayed or merged-forward commit carries other workers' files
            p = (git_text(['rev-parse', '--git-path', n], cwd) or '').strip()
            if p and os.path.exists(os.path.join(cwd, p)):
                return 0
        files = git_names(['diff', '--cached', '--name-only', '--no-renames', '-z'], cwd)
    else:
        base = pr_base(cwd) or 'main'
        if base != 'main' and git_text(['rev-parse', '--verify', '-q', 'refs/remotes/origin/' + base], cwd) is None:
            base = 'main'
        if git_text(['rev-parse', '--verify', '-q', 'refs/remotes/origin/' + base], cwd) is None:
            return 0
        files = git_names(['diff', 'origin/%s...HEAD' % base, '--name-only', '--no-renames', '-z'], cwd)
    if not files:
        return 0
    judge = Judge(repo, time.time() + CHECK_BUDGET)
    refused = []
    for f in files:
        norm = normalize(repo, f)
        if norm is None:
            continue
        row = os.path.join(slug_dir(repo, norm[0]), escape(norm[1]))
        st, fields = read_row(row)
        if st == 'ok' and pr_row_passes(fields, row, key, branch):
            continue
        r = claim_one(repo, judge, f, key, label, doc, 'claim', '')
        if r.startswith('refused:'):
            refused.append(r[len('refused:'):])
    for m in refused:
        sys.stderr.write(m + '\n')
    if refused:
        sys.stderr.write('holds: refused by the %s check. Bypass: WRITE_HOLD_OK=1 in the launching shell\n' % ('commit' if a.staged else 'push'))
    return 1 if refused else 0


SERIES_LEAD = '> **Series:**'


class Unavailable(Exception):
    """The PR's files, its doc or its Writes cannot be read: narrow prints `unavailable (<reason>)` and changes nothing."""


def narrow_context(a):
    """-> (repo, files, pairs, text, branch): the primary checkout, the files this worktree's branch adds over origin/<base>
    (the three-dot diff, so a merge-forward adds none of main's), the doc's Writes pairs and its text."""
    if not KEY_RE.fullmatch(a.key) or not os.path.isabs(a.doc):
        raise Unavailable('no hold key')
    if not BASE_RE.match(a.base):
        raise Unavailable('bad base %r' % a.base)
    try:
        repo = primary_of(a.repo)
    except RepoFault as e:
        raise Unavailable(str(e))
    cwd = os.getcwd()
    if git_text(['rev-parse', '--verify', '-q', 'refs/remotes/origin/' + a.base], cwd) is None:
        raise Unavailable('origin/%s is not fetched' % a.base)
    files = git_names(['diff', 'origin/%s...HEAD' % a.base, '--name-only', '--no-renames', '-z'], cwd)
    if files is None:
        raise Unavailable('the diff against origin/%s failed' % a.base)
    if not files:
        raise Unavailable('empty diff')
    try:
        text = open(a.doc, encoding='utf-8', errors='replace').read()
    except OSError as e:
        raise Unavailable('cannot read the hold doc: %s' % (e.strerror or e))
    if not has_writes(text) and 'RESUME' in os.path.basename(a.doc):
        text = fallback_text(Judge(repo), a.doc, a.key) or text  # a RESUME doc with no Writes line: the predecessor's
    pairs = parse_text(text, repo)  # may be empty: the rival check and --apply still run, only the outside-writes line is lost
    branch = (git_text(['rev-parse', '--abbrev-ref', 'HEAD'], cwd) or '').strip()
    return repo, files, pairs, text, branch


def outside_of(files, pairs, repo):
    """The files no Writes entry covers: a file by its name, a tree by its prefix. A bucket file (absolute) covers none."""
    names, trees = set(), []
    for kind, p in pairs:
        if os.path.isabs(p):
            continue
        c = canon(p, repo).rstrip('/')
        if kind == 'file':
            names.add(c)
        else:
            trees.append(c)
    out = []
    for f in files:
        c = canon(f, repo)
        if c not in names and not any(c == t or c.startswith(t + '/') for t in trees):
            out.append(f)
    return out


def rival_message(repo, judge, path, key, branch):
    """None, 'fault' (the row cannot be read) or the refusal text for a file a live rival holds. Reads only: no row is made."""
    norm = normalize(repo, path)
    if norm is None:
        return None
    slug, rel = norm
    if slug != '_abs' and rel in exempt_set():
        return None
    if len(escape(rel).encode('utf-8')) > MAX_NAME:
        fault('path name over %d bytes' % MAX_NAME, rel, key)  # no row can exist for it: it passes, as claim_one lets it
        return None
    row = os.path.join(slug_dir(repo, slug), escape(rel))
    st, fields = read_row(row)
    if st == 'gone':
        return None
    if st == 'err':
        fault('row unreadable: %s' % (getattr(fields, 'strerror', None) or fields), rel, key)
        return 'fault'
    if st == 'bad':
        fault('row unparseable, left in place', rel, key)
        return 'fault'
    if fields[0] == key or os.path.exists('%s.grant.%s' % (row, key)) or pr_row_passes(fields, row, key, branch):
        return None
    try:
        mtime = os.path.getmtime(row)
    except OSError:
        return None
    state = judge.row_state(fields, mtime)
    if state == 'alive':
        log_event('deny', rel, key, fields[0])
        return refusal(rel, fields, key)
    if state == 'unknown':
        fault('holder liveness unproven', rel, key)
        return 'fault'
    return None


def retag_row(repo, rel, key, label, doc, pr):
    """Make the key's own row for rel the PR's: source pr (a claim stays claim), this PR, doc and label. Under the directory
    lock; a row of another key or of another PR is left as it is. -> False on a fault (the register could not be written)."""
    d, name = slug_dir(repo), escape(rel)
    target = os.path.join(d, name)
    lock = dir_lock(d)
    if lock is None:
        fault('register lock not free', rel, key)
        return False
    try:
        st, f = read_row(target)
        if st == 'err':
            fault('row unreadable: %s' % (getattr(f, 'strerror', None) or f), rel, key)
            return False
        if st != 'ok' or f[0] != key or f[4] not in ('', pr):
            return True
        new = [key, label, doc, 'claim' if f[3] == 'claim' else 'pr', pr]
        if f == new:
            return True
        _tmp_n[0] += 1
        tmp = os.path.join(d, '%sretag.%d.%d' % (TMP_PREFIX, os.getpid(), _tmp_n[0]))
        try:
            with open(tmp, 'w', encoding='utf-8') as fh:
                fh.write('\t'.join(clean(x) for x in new) + '\n')
            os.replace(tmp, target)
        except OSError as e:
            fault('retag write: %s' % (e.strerror or e), rel, key)
            try:
                os.unlink(tmp)
            except OSError:
                pass  # swallow-ok: the temp file never existed or is gone
            return False
        return True
    finally:
        dir_unlock(lock)


def free_unchanged(repo, key, keep):
    """Remove the key's rows with no PR number whose file the PR does not change (rename-compare, under the directory lock)."""
    d = slug_dir(repo)
    try:
        names = sorted(os.listdir(d))
    except FileNotFoundError:
        return
    except OSError as e:
        fault('register directory: %s' % (e.strerror or e), '', key)
        return
    for n in names:
        if n.startswith(TMP_PREFIX) or GRANT_RE.search(n) or n in keep:
            continue
        full = os.path.join(d, n)
        st, f = read_row(full)
        if st != 'ok' or f[0] != key or f[4] != '':
            continue
        try:
            mtime = os.path.getmtime(full)
        except OSError:
            continue
        if remove_dead(d, n, f, mtime):
            log_event('narrow', unescape(n), key, 'freed')


def op_narrow(a):
    """--check: print `outside-writes: <files>`, `none` or `unavailable (<reason>)`; exit 1 (the holder on stderr) when a PR file
    is held by a live rival with no grant. It makes no row. --apply: the PR's files become the key's rows (source pr, a claim
    stays claim, each with the doc, label and PR number); the key's other rows with no PR number are freed, except for a doc
    with a Series line or after a fault. Every fault exits 0 and never fails the PR; a fault on one file stops the freeing but
    can leave the rows already made for the other files."""
    try:
        repo, files, pairs, text, branch = narrow_context(a)
    except Unavailable as e:
        if str(e) != 'no hold key':
            fault(str(e), '', a.key)
        if a.check:
            print('outside-writes: unavailable (%s)' % clean(str(e)))
        return 0
    bypass = (os.environ.get('WRITE_HOLD_OK') == '1' or os.path.exists(os.path.join(holds_root(), 'OFF'))
              or os.path.exists(os.path.join(repo, '.single-writer')))
    if a.check:
        outside = outside_of(files, pairs, repo)
        if not pairs:
            line = 'outside-writes: unavailable (no Writes line)'
        else:
            line = 'outside-writes: ' + (clean(', '.join(outside)) if outside else 'none')
        refused, faulted = [], False
        if not bypass:
            judge = Judge(repo, time.time() + CHECK_BUDGET)
            for f in files:
                m = rival_message(repo, judge, f, a.key, branch)
                if m == 'fault':
                    faulted = True
                elif m:
                    refused.append(m)
        if refused:
            print(line)
            for m in refused:
                sys.stderr.write(m + '\n')
            sys.stderr.write('holds: refused by the PR open. Bypass: WRITE_HOLD_OK=1 in the launching shell\n')
            return 1
        print('outside-writes: unavailable (register unreadable)' if faulted else line)
        return 0
    if bypass:
        return 0
    if not a.pr.isdigit():
        sys.stderr.write('holds: narrow --apply needs --pr N\n')
        return 2
    judge = Judge(repo, time.time() + CHECK_BUDGET)
    keep = set()
    faulted = False  # a file the PR changes that could not be registered: nothing is freed, so no hold is lost to a fault
    for f in files:
        norm = normalize(repo, f)
        if norm is None or norm[0] == '_abs':
            continue
        rel = norm[1]
        keep.add(escape(rel))
        st, row = read_row(os.path.join(slug_dir(repo), escape(rel)))
        if st == 'ok' and row[0] == a.key:
            faulted = not retag_row(repo, rel, a.key, a.label, a.doc, a.pr) or faulted
        else:
            faulted = claim_one(repo, judge, rel, a.key, a.label, a.doc, 'pr', a.pr) == 'fault' or faulted
    if not faulted and not any(l.startswith(SERIES_LEAD) for l in text.splitlines()):
        free_unchanged(repo, a.key, keep)
    return 0


def abs_doc(s):
    return os.path.abspath(s) if s else s


def build_parser():
    ap = argparse.ArgumentParser(prog='holds.py', description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='verb', required=True)

    def add(name, fn, **kw):
        sp = sub.add_parser(name, **kw)
        sp.set_defaults(fn=fn)
        return sp

    sp = add('parse', op_parse, help='file/tree lines from a doc\'s Writes lines')
    sp.add_argument('doc')
    sp.add_argument('--repo')
    sp = add('claim', op_claim, help='claim paths for a key; exit 1 names the holder')
    for o in ('--key', '--label', '--doc', '--repo'):
        sp.add_argument(o, required=True, type=abs_doc if o == '--doc' else str)
    sp.add_argument('--source', choices=SOURCES, default='claim')
    sp.add_argument('--pr', default='')
    sp.add_argument('paths', nargs='+', metavar='PATH')
    sp = add('seed', op_seed, help='claim every file in a doc\'s Writes lines, all or nothing')
    for o in ('--key', '--label', '--doc', '--repo'):
        sp.add_argument(o, required=True, type=abs_doc if o == '--doc' else str)
    sp.add_argument('--deadline', type=float, help='epoch seconds after which the seed stops between rows (default: 60 s from now)')
    sp = add('repoint', op_repoint, help='rewrite a key\'s rows to a new doc and label (a RESUME launch)')
    for o in ('--key', '--label', '--doc', '--repo'):
        sp.add_argument(o, required=True, type=abs_doc if o == '--doc' else str)
    sp.add_argument('--deadline', type=float, help='epoch seconds after which the repoint stops between rows (default: 60 s from now)')
    sp = add('backfill', op_backfill, help='seed rows for every manifest worker not WRAPPED')
    sp.add_argument('--manifest', required=True)
    sp.add_argument('--repo', required=True)
    sp = add('grant', op_grant, help='let a key write a held file: a trust path needs --chief-doc or the operator at a terminal')
    sp.add_argument('--key', required=True)
    sp.add_argument('--repo', required=True)
    sp.add_argument('--chief-doc', help='the chief\'s own doc, its queue lock held on this host (default: $HIMMEL_CONSOLE_DOC)')
    sp.add_argument('path', metavar='PATH')
    sp = add('grant-route', op_grant_route, help='who may grant a path: operator, chief or any')
    sp.add_argument('--repo', required=True)
    sp.add_argument('path', metavar='PATH')
    sp = add('off', op_off, help='write the sentinel that folds the barrier (chief only)')
    sp.add_argument('--reason', required=True)
    sp = add('on', op_on, help='remove the sentinel, then backfill the fleet manifest (chief only)')
    sp.add_argument('--workers-from', metavar='MANIFEST', help='the chief\'s fleet manifest (default: $HIMMEL_CONSOLE_DOC minus .md, plus .fleet.json, when it exists)')
    sp.add_argument('--repo', help='the repo the rows belong to (default: the current directory)')
    sp = add('release', op_release, help='remove a doc\'s brief rows, for a launch that aborts')
    for o in ('--key', '--repo', '--doc'):
        sp.add_argument(o, required=True, type=abs_doc if o == '--doc' else str)
    sp = add('alive', op_alive, help='alive, dead or unknown for the holder of a path')
    sp.add_argument('--repo', required=True)
    sp.add_argument('path', metavar='PATH')
    sp = add('read', op_read, help='TSV of rows: path key label source pr state')
    sp.add_argument('--repo', required=True)
    sp.add_argument('--paths-from', metavar='FILE')
    sp.add_argument('--keys', action='store_true')
    sp = add('sync-prs', op_sync_prs, help='pr rows for the files of open PRs (TSV pr head title-key path)')
    sp.add_argument('--repo', required=True)
    sp.add_argument('--files-from', required=True, metavar='TSV')
    sp = add('gc', op_gc, help='remove dead rows and their grants')
    sp.add_argument('--repo', required=True)
    sp = add('summary', op_summary, help='live-workers-with-no-rows/stale-rows/pending-asks (the tick\'s hreg= field)')
    sp.add_argument('--repo', required=True)
    sp.add_argument('--live-docs', metavar='FILE', help='live worker docs, one per line (- for stdin)')
    sp.add_argument('--open-prs', metavar='LIST', help='open PR numbers, comma separated (#12,#34 or none); absent or ? skips the PR test')
    sp = add('git-check', op_git_check, help='refuse a commit or push whose git file list holds a file another live holder holds')
    g = sp.add_mutually_exclusive_group(required=True)
    g.add_argument('--staged', action='store_true', help='the staged files (the commit hook)')
    g.add_argument('--push', action='store_true', help='the files the branch adds over its base (the push hook)')
    sp = add('narrow', op_narrow, help='a PR open: --check names the files outside Writes and refuses a rival\'s file; --apply makes the PR\'s files the key\'s rows')
    g = sp.add_mutually_exclusive_group(required=True)
    g.add_argument('--check', action='store_true', help='print the outside-writes line; exit 1 on a file a live rival holds; change nothing')
    g.add_argument('--apply', action='store_true', help='the PR\'s files become the key\'s rows, the rest of its unnumbered rows are freed')
    for o in ('--key', '--repo', '--doc', '--base'):
        sp.add_argument(o, required=True, type=abs_doc if o == '--doc' else str)
    sp.add_argument('--label', default='')
    sp.add_argument('--pr', default='', help='the PR number (--apply)')
    sp = add('asks', op_asks, help='TSV key path holder command: pending trust-path asks with the paste-ready grant')
    sp.add_argument('--repo', required=True)
    return ap


def main(argv=None):
    try:
        a = build_parser().parse_args(argv)  # inside the fault path: a type function (abs_doc) can raise too
        return a.fn(a)
    except BrokenPipeError:
        return 0
    except Exception as e:  # a crash is a fault (2), never a refusal (1): callers pass on 2 and refuse on 1
        reason = str(e) if isinstance(e, RepoFault) else 'crash %s: %s' % (type(e).__name__, e)
        fault(reason)
        sys.stderr.write('holds: fault: %s\n' % reason)
        return 2


if __name__ == '__main__':
    sys.exit(main())
