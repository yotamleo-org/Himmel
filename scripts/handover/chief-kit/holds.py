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

Exit codes: 0 ok, 1 refused (the holder on stderr), 2 usage or a failure that is not a refusal, 3 unreadable.
Nothing in this slice wires holds.py anywhere.
"""
import argparse
import os
import re
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GRACE = 15 * 60          # a row this young is alive: the worker is still arming
RESUME_AGE = 24 * 3600   # ponytail: a RESUME doc younger than this keeps its key's rows; a successor parked longer loses them, upgrade path: the chief re-points or grants
GH_TIMEOUT = 5
QL_TIMEOUT = 15
SOURCES = ('brief', 'claim', 'pr')
KEY_RE = re.compile(r'^[A-Za-z][A-Za-z0-9]*-\d+$')
GRANT_RE = re.compile(r'\.grant\.[A-Za-z][A-Za-z0-9]*-\d+$')
TMP_PREFIX = '%00'       # escaping only ever makes %25 and %2F, so a name starting %00 is never a row
MAX_NAME = 255

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


# the variables that redirect git to another repository; a hook or a wrapper may have exported any of them
GIT_SCRUB = ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
             'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX', 'GIT_IMPLICIT_WORK_TREE', 'GIT_GRAFT_FILE',
             'GIT_REPLACE_REF_BASE', 'GIT_SHALLOW_FILE', 'GIT_CONFIG', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT')


def primary_of(repo):
    """The primary checkout's absolute path: git-common-dir minus /.git. One derivation for every verb."""
    repo = os.path.abspath(repo)
    env = {k: v for k, v in os.environ.items() if k not in GIT_SCRUB}
    try:
        r = subprocess.run(['git', '-C', repo, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                           capture_output=True, text=True, timeout=10, env=env)
        d = r.stdout.strip()
        if r.returncode == 0 and d:
            return d[:-len('/.git')] if d.endswith('/.git') else d
    except (OSError, subprocess.SubprocessError):
        pass  # swallow-ok: not a git repo or no git; the path as given is the identity
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
        prefix = repo.rstrip('/') + '/'
        if p.startswith(prefix):
            return escape(repo), canon(os.path.normpath(p[len(prefix):]), repo)
        return '_abs', os.path.normpath(p)
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
    if text.count('\n') > 1 or len(fields) != 5 or not KEY_RE.match(fields[0]) or fields[3] not in SOURCES:
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

    def __init__(self, repo):
        self.repo = repo
        self.ql_cache, self.pr_cache, self.scan_cache = {}, {}, {}
        self.root = None

    def lock_state(self, doc):
        """'free' | 'alive' | 'fault' from the queue-lock.sh status table."""
        if doc in self.ql_cache:
            return self.ql_cache[doc]
        ql = os.environ.get('HOLDS_QUEUE_LOCK') or os.path.join(HERE, '..', 'queue-lock.sh')
        res = run_bounded(['bash', ql, 'status', doc], QL_TIMEOUT) if os.path.isfile(ql) else None
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
        res = run_bounded([gh, 'pr', 'view', pr, '--json', 'state', '-q', '.state'], GH_TIMEOUT, cwd=self.repo if os.path.isdir(self.repo) else None)
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
        for dirpath, dirs, files in os.walk(bucket):
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
        for d in docs:
            if 'RESUME' not in os.path.basename(d):
                continue
            try:
                age = time.time() - os.path.getmtime(d)
                marks = [m.group(1) for m in (MARKER_RE.match(l) for l in open(d, encoding='utf-8', errors='replace').read().splitlines()) if m]
            except OSError:
                res = 'fault'
                continue
            if age < RESUME_AGE and not (marks and marks[-1] == 'WRAPPED'):
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
            docs = list(self.scan(self.bucket_of(doc), key))
            if os.path.isfile(doc) and doc not in docs:
                docs.append(doc)
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
    d = slug_dir(repo, slug)
    try:
        os.makedirs(d, exist_ok=True)
    except OSError as e:
        fault('register directory: %s' % (e.strerror or e), rel, key)
        return 'fault'
    mine = '\t'.join(clean(x) for x in (key, label, doc, source, pr)) + '\n'
    target = os.path.join(d, name)
    for _ in range(6):
        try:
            res = publish(d, name, mine)
        except OSError as e:
            fault('register write: %s' % (e.strerror or e), rel, key)
            return 'fault'
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
        # dead: take over by renaming the row aside, so a losing contender's rename fails
        _tmp_n[0] += 1
        moved = os.path.join(d, '%staken.%d.%d' % (TMP_PREFIX, os.getpid(), _tmp_n[0]))
        try:
            os.rename(target, moved)
        except FileNotFoundError:
            continue
        except OSError as e:
            fault('takeover rename: %s' % (e.strerror or e), rel, key)
            return 'fault'
        # ponytail: a third party can publish between this rename and the link-back below, in which case the moved row is dropped, upgrade path: rows carry a generation
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
            pass  # swallow-ok: someone published a newer row meanwhile; the next round reads it
        try:
            os.unlink(moved)
        except OSError:
            pass  # swallow-ok: as above
    fault('contention did not settle', rel, key)
    return 'fault'


def op_claim(a):
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


def op_seed(a):
    repo = primary_of(a.repo)
    try:
        text = open(a.doc, encoding='utf-8', errors='replace').read()
    except OSError as e:
        sys.stderr.write('holds: cannot read %s: %s\n' % (a.doc, e.strerror or e))
        return 3
    judge = Judge(repo)
    created = []
    for kind, p in parse_text(text, repo):
        if kind != 'file':
            continue
        r = claim_one(repo, judge, p, a.key, a.label, a.doc, 'brief', '', created)
        if r.startswith('refused:'):
            for target, mine in created:  # all or nothing: remove only the rows this seed made
                st, f = read_row(target)
                if st == 'ok' and '\t'.join(f) + '\n' == mine:
                    try:
                        os.unlink(target)
                    except OSError:
                        pass  # swallow-ok: a row that vanished needs no removal
            sys.stderr.write(r[len('refused:'):] + '\n')
            return 1
    return 0


def load_trust():
    path = os.path.join(HERE, '..', '..', 'ci', 'ci-trust-paths.txt')
    try:
        return [re.compile(l.strip()) for l in open(path, encoding='utf-8') if l.strip() and not l.startswith('#')]
    except OSError:
        return None


GRANT_PATH_REFUSED_RE = re.compile(r'(^|/)[^/]*settings[^/]*\.json$|^\.github/')  # copied from gen-briefs.py validate_grants; Task 2 moves it here
BAD_CHAR_RE = re.compile(r'[\x00-\x1f\x7f`]')


def worker_session():
    return bool(os.environ.get('HIMMEL_CONSOLE_LEG'))


def op_grant(a):
    if worker_session():
        sys.stderr.write('holds: grant is refused for a worker session (HIMMEL_CONSOLE_LEG is set); only the chief grants\n')
        return 1
    repo = primary_of(a.repo)
    p = a.path
    if (not p.strip() or p != p.strip() or BAD_CHAR_RE.search(p) or os.path.isabs(p) or p != os.path.normpath(p) or p == '.'
            or re.search(r'[*?\[]', p) or '..' in p.split('/') or os.path.isdir(os.path.join(repo, p))):
        sys.stderr.write('holds: %r must be a literal repo-relative file path\n' % p)
        return 2
    trust = load_trust()
    if trust is None:
        sys.stderr.write('holds: cannot read the trust paths; a grant cannot be checked against them\n')
        return 2
    if GRANT_PATH_REFUSED_RE.search(p) or any(r.search(p) for r in trust):
        sys.stderr.write('holds: %s is a settings, CI-workflow or trust path; only the operator can grant it\n' % p)
        return 1
    slug, rel = escape(repo), canon(p, repo)
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
    d = slug_dir(repo)
    try:
        names = os.listdir(d)
    except FileNotFoundError:
        return 0
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


def op_read(a):
    """TSV path key label source pr state. state is alive, dead, unknown or unparseable; only dead reads as free.
    --keys prints key state rows per holder instead, whatever --paths-from says. Exit 3 when unreadable."""
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
        sp.add_argument(o, required=True)
    sp.add_argument('--source', choices=SOURCES, default='claim')
    sp.add_argument('--pr', default='')
    sp.add_argument('paths', nargs='+', metavar='PATH')
    sp = add('seed', op_seed, help='claim every file in a doc\'s Writes lines, all or nothing')
    for o in ('--key', '--label', '--doc', '--repo'):
        sp.add_argument(o, required=True)
    sp = add('grant', op_grant, help='let a key write a held file (chief only)')
    sp.add_argument('--key', required=True)
    sp.add_argument('--repo', required=True)
    sp.add_argument('path', metavar='PATH')
    sp = add('off', op_off, help='write the sentinel that folds the barrier (chief only)')
    sp.add_argument('--reason', required=True)
    add('on', op_on, help='remove the sentinel (chief only)')
    sp = add('release', op_release, help='remove a doc\'s brief rows, for a launch that aborts')
    for o in ('--key', '--repo', '--doc'):
        sp.add_argument(o, required=True)
    sp = add('alive', op_alive, help='alive, dead or unknown for the holder of a path')
    sp.add_argument('--repo', required=True)
    sp.add_argument('path', metavar='PATH')
    sp = add('read', op_read, help='TSV of rows: path key label source pr state')
    sp.add_argument('--repo', required=True)
    sp.add_argument('--paths-from', metavar='FILE')
    sp.add_argument('--keys', action='store_true')
    return ap


def main(argv=None):
    a = build_parser().parse_args(argv)
    try:
        return a.fn(a)
    except BrokenPipeError:
        return 0


if __name__ == '__main__':
    sys.exit(main())
