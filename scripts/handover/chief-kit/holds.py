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
import fcntl
import json
import os
import re
import signal
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
LEG_RE = re.compile(r'-(N\d+)[a-z]*-')  # the leg number in a handover doc's name

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
        self.ql_cache, self.pr_cache, self.scan_cache = {}, {}, {}
        self.scan_faulted = set()
        self.root = None

    def left(self, timeout):
        """The timeout for one call: its own, or what is left of the deadline; 0 once the deadline has passed."""
        if self.deadline is None:
            return timeout
        return max(0, min(timeout, self.deadline - time.time()))

    def lock_state(self, doc):
        """'free' | 'alive' | 'fault' from the queue-lock.sh status table."""
        if doc in self.ql_cache:
            return self.ql_cache[doc]
        ql = os.environ.get('HOLDS_QUEUE_LOCK') or os.path.join(HERE, '..', 'queue-lock.sh')
        t = self.left(QL_TIMEOUT)
        res = run_bounded(['bash', ql, 'status', doc], t) if t > 0 and os.path.isfile(ql) else None
        if res is None:
            s = 'fault'
        elif res[0] == 0:
            s = 'free'
        elif res[0] == 11:
            s = 'alive'
        elif res[0] == 12:
            s = 'free' if 'STALE-DEAD' in res[1] else 'alive'  # plain STALE: death not proven, kept
        else:
            s = 'fault'
        self.ql_cache[doc] = s
        return s

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
                if n.endswith('.md') and rx.search(n):
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
            # a worker that wraps writes WRAPPED into the doc it worked in, not the RESUME doc: that wrap consumes it,
            # when it is proven the doc's successor, and unless the wrap bullet hands off to this very doc.
            # ponytail: a different-leg successor that never names the doc holds for up to RESUME_AGE; a recorded parent link is the upgrade path.
            b = os.path.basename(d)
            if any(m2 == 'WRAPPED' and mt2 > mt and b not in l2 and successor_of(b, d2, r2)
                   for d2, mt2, m2, l2, r2 in info if d2 != d):
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
        r = self.resume_alive(docs)
        if r == 'alive':
            return 'alive'
        faulted = faulted or r == 'fault'
        if pr:
            p = self.pr_state(pr)
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


def successor_of(resume, other, rest):
    """A newer WRAPPED doc counts against a RESUME doc only through a proven link: it names the doc off its last
    bullet, or is the doc's stem, or shares its leg number."""
    if any(resume in l for l in rest) or os.path.basename(other) == resume.replace('-RESUME', ''):
        return True
    a, b = LEG_RE.search(resume), LEG_RE.search(os.path.basename(other))
    return bool(a and b and a.group(1) == b.group(1))


def refusal(path, fields, key):
    return ('holds: %s is held by %s (%s, %s). Keep working on other files, and ask your chief: HOLD-ASK %s %s'
            % (path, fields[0], fields[1], fields[3], path, key))


def claim_one(repo, judge, path, key, label, doc, source, pr, created=None):
    """-> 'claimed' | 'own' | 'granted' | 'skipped' | 'fault' | 'refused:<message>'."""
    norm = normalize(repo, path)
    if norm is None:
        return 'skipped'  # a tree is noted, not held
    slug, rel = norm
    if os.path.exists(os.path.join(holds_root(), 'OFF')):
        return 'skipped'
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
            log_event('deny', rel, key, fields[0])
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
            if st2 == 'ok' and f2 == fields:
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
    if not has_writes(text):
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
    if any(GRANT_PATH_REFUSED_RE.search(x) or any(r.search(x) for r in trust) for x in (p, rel)):
        sys.stderr.write('holds: %s is a settings, CI-workflow or trust path; only the operator can grant it\n' % p)
        return 1
    d = slug_dir(repo, slug)
    try:
        os.makedirs(d, exist_ok=True)
        publish(d, '%s.grant.%s' % (escape(rel), a.key), 'granted\t%s\n' % now_iso())
    except OSError as e:
        sys.stderr.write('holds: cannot write the grant: %s\n' % (e.strerror or e))
        return 2
    log_event('grant', rel, a.key, '')
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
    except FileNotFoundError:
        return 0
    except OSError as e:
        sys.stderr.write('holds: cannot remove the sentinel: %s\n' % (e.strerror or e))
        return 2
    log_event('on', '', '', '')
    return 0


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
    --keys prints key state rows per holder instead, whatever --paths-from says; a row it cannot read counts
    its key (? when the key is unreadable too) as unknown and is named on stderr, never dropped and never free (exit 0).
    Exit 3 when the register directory or the --paths-from file cannot be read."""
    repo = primary_of(a.repo)
    d = slug_dir(repo)
    try:
        names = sorted(os.listdir(d))
    except FileNotFoundError:
        return 0  # no directory is an empty register
    except OSError as e:
        sys.stderr.write('holds: cannot read %s: %s\n' % (d, e.strerror or e))
        return 3
    want = None
    if a.paths_from and not a.keys:
        try:
            want = set()
            for l in open(a.paths_from, encoding='utf-8'):
                l = l.strip()
                n = normalize(repo, l) if l else None
                if n:
                    want.add(n[1])
        except OSError as e:
            sys.stderr.write('holds: cannot read %s: %s\n' % (a.paths_from, e.strerror or e))
            return 3
    judge = Judge(repo)
    keys = {}
    unreadable = []
    for n in names:
        if n.startswith(TMP_PREFIX) or GRANT_RE.search(n):
            continue
        path = unescape(n)
        if want is not None and path not in want:
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
    sp = add('grant', op_grant, help='let a key write a held file (chief only)')
    sp.add_argument('--key', required=True)
    sp.add_argument('--repo', required=True)
    sp.add_argument('path', metavar='PATH')
    sp = add('off', op_off, help='write the sentinel that folds the barrier (chief only)')
    sp.add_argument('--reason', required=True)
    add('on', op_on, help='remove the sentinel (chief only)')
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
