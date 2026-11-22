#!/usr/bin/env python3
"""Current managed launch ownership, serialized by fleet-manifest's locks.

The anchor is current state; launch-refusals.jsonl remains the receipt history.
No PID, elapsed-time, role or caller-supplied held flag proves an outcome.
"""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid

LIB = Path(__file__).resolve().parent
WRITER = LIB.parent / 'handover/chief-kit/fleet-manifest.sh'


class Refused(ValueError):
    pass


def read(path):
    if path.is_symlink():
        raise Refused('symlink state')
    return json.loads(path.read_text())


def publish(path, value):
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
        dfd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


@contextmanager
def lock(path):
    fd = os.open(str(path) + '.lock', os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        until = time.monotonic() + 30
        while True:  # t13b-ok: ends when the lock is taken, or raises Refused once the 30 s deadline has passed
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= until:
                    raise Refused('writer lock timeout')
                time.sleep(.02)
        yield
    finally:
        os.close(fd)


def identity(pid):
    stat = Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()
    return {'host': socket.gethostname(), 'boot': Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
            'pid': pid, 'start': stat[19]}


def ancestors():
    result = set()
    pid = os.getppid()
    while pid > 1 and pid not in result:
        result.add(pid)
        pid = int(Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()[1])
    return result


def caller(pid):
    if pid != os.getpid() and pid not in ancestors():
        raise Refused('launcher is not an ancestor of the writer')
    return identity(pid)


def live(owner):
    return process_state(owner) == 'live'


OWNER_FIELDS = {'host': str, 'boot': str, 'pid': int, 'start': str}


def process_state(owner):
    """Absence is proof only for an exact local host/boot/start identity; an owner that is not exactly those fields is unknown."""
    if not isinstance(owner, dict) or set(owner) != set(OWNER_FIELDS) or any(type(owner[key]) is not kind for key, kind in OWNER_FIELDS.items()):
        return 'unknown'
    try:
        local = identity(os.getpid())
        if any(owner[key] != local[key] for key in ('host', 'boot')):
            return 'unknown'
        try:
            found = identity(owner['pid'])
            state = Path('/proc', str(owner['pid']), 'stat').read_text().rsplit(')', 1)[1].split()[0]
        except FileNotFoundError:
            return 'dead'
        return 'dead' if found != owner or state in ('Z', 'X') else 'live'
    except (OSError, KeyError, ValueError):
        return 'unknown'


def authorized(record, pid):
    caller(pid)
    owner = record['owner']
    if not live(owner) or (owner['pid'] != os.getpid() and owner['pid'] not in ancestors()):
        raise Refused('attempt process identity conflict')


def slots_root():
    # Reuse the registered policy fixture seam; ordinary launch environment
    # cannot relocate the census or manufacture a resource admission proof.
    if os.environ.get('HIMMEL_POLICY_FOLLOWS_HOME') == '1':
        return Path(os.environ.get('HIMMEL_FLEET_SLOTS', str(Path(os.environ.get('XDG_RUNTIME_DIR', '/tmp')) / ('himmel-fleet-' + str(os.getuid()))))).absolute()
    runtime = Path('/run/user', str(os.getuid()))
    if not runtime.is_dir() or runtime.stat().st_uid != os.getuid():
        runtime = Path('/tmp')
    return runtime / ('himmel-fleet-' + str(os.getuid()))


def has_reservation(record, pid):
    authorized(record, pid)
    proof = record.get('reservation', {})
    path = Path(proof.get('path', '/'))
    if path.parent != slots_root() or path.is_symlink():
        return False
    expected = {'attempt_id': record['attempt_id'], 'owner': proof.get('owner')}
    if proof.get('owner') not in (record['owner'], caller(pid)):
        return False
    return ((path / 'managed.json').is_file() and read(path / 'managed.json') == expected
            and (path / 'name').read_text().rstrip('\n') == record['name'])


def release_reservation(record):
    slots = slots_root()
    allowed = [record['owner'], record.get('committer'), (record.get('reservation') or {}).get('owner')]
    if slots.exists():
        for slot in slots.iterdir():
            path = slot / 'managed.json'
            if not slot.is_symlink() and path.is_file():
                value = read(path)
                if value == {'attempt_id': record['attempt_id'], 'owner': value.get('owner')} and value.get('owner') in allowed and value.get('owner') is not None:
                    shutil.rmtree(slot)


def resolve(doc, manifest=''):
    """Worker registration/context is authoritative; bucket proximity is not."""
    intent = (os.environ.get('FLEET_LAUNCH_WORKER_INTENT') == '1'
              or os.environ.get('HIMMEL_CONSOLE_LEG') == '1'
              or bool(os.environ.get('WORKER_SESSION_PROFILE')))
    if not doc:
        if manifest or intent or os.environ.get('FLEET_LAUNCH_ATTEMPT'):
            raise Refused('managed launch missing doc locator')
        return None
    original = Path(doc).absolute()
    if original.is_symlink() and any((parent / 'fleet-control.json').exists() for parent in (original.parent, original.resolve().parent)):
        raise Refused('aliased managed doc locator')
    doc = str(Path(doc).resolve())
    bucket = Path(doc).parent
    intent = intent and (bucket / 'fleet-control.json').exists()
    paths = list(bucket.glob('*.fleet.json'))
    candidates = []
    for path in paths:
        data = read(path)
        rows = data.get('workers', data.get('legs', []))
        if any(row.get('doc') == doc for row in rows):
            candidates.append(path)
    if manifest:
        path = Path(manifest).absolute()
        if path.parent.resolve() != bucket or path.is_symlink():
            raise Refused('conflicting manifest locator')
        candidates = [path, *[p for p in candidates if p != path]]
    try:
        intent = intent or bool(re.search(r'^> \*\*(?:Chief|Leg kind|Proof leg):\*\*|^# .* — worker [A-Za-z0-9]+ ', Path(doc).read_text(), re.M))
    except FileNotFoundError:
        pass
    if not candidates and not intent:
        return None
    if not candidates:
        raise Refused('managed worker has no manifest reference')
    if not manifest and len(candidates) != 1:
        raise Refused('worker has multiple manifest references; explicit locator required')
    chosen = candidates[0]
    expected = {'family': read(bucket / 'fleet-control.json')['family'], 'anchor': str(bucket / 'fleet-control.json')}
    for path in candidates:
        if read(path).get('control') != expected:
            raise Refused('missing or conflicting family reference')
    return chosen


def snapshot(manifest):
    p = subprocess.run(['bash', '-c', '. "$1/fleet-control.sh"; fleet_control_show "$2"',
                        'fleet-runtime', str(LIB), str(manifest)], capture_output=True, text=True, timeout=10)
    value = json.loads(p.stdout)
    if p.returncode or value.get('state') != 'ok':
        raise Refused('invalid family control')
    return value


def receipts(wanted, docs=()):
    path = Path.home() / '.himmel/launch-refusals.jsonl'
    if not path.exists():
        return {}
    found = {}
    deadline = time.monotonic() + 3
    with path.open() as stream:
        while True:  # t13b-ok: ends at end of file, or raises Refused on the first line read after the 3 s deadline
            line = stream.readline(1048576)
            if not line:
                break
            if time.monotonic() > deadline or (len(line) == 1048576 and not line.endswith('\n')):
                raise Refused('receipt history exceeds bounded read')
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get('v') == 2 and row.get('kind') == 'launch-attempt' and (row.get('attempt_id') in wanted or row.get('doc') in docs or row.get('attempt_id') in found):
                merged = dict(found.pop(row['attempt_id'], {}), **row)
                found[row['attempt_id']] = merged
    return found


def attempt_outcomes(attempt_ids):
    """{attempt_id: every outcome the history holds for it}, from one bounded read; the merged row receipts() builds keeps only the last.
    A non-blank line that cannot be parsed could be any attempt's receipt, so it adds 'unknown-history' to every attempt."""
    found = {aid: set() for aid in attempt_ids}
    path = Path.home() / '.himmel/launch-refusals.jsonl'
    if not path.exists():
        return found
    deadline = time.monotonic() + 3
    with path.open() as stream:
        while True:  # t13b-ok: ends at end of file, or raises Refused on the first line read after the 3 s deadline
            line = stream.readline(1048576)
            if not line:
                break
            if time.monotonic() > deadline or (len(line) == 1048576 and not line.endswith('\n')):
                raise Refused('receipt history exceeds bounded read')
            try:
                row = json.loads(line)
            except ValueError:
                if line.strip():
                    for outcomes in found.values():
                        outcomes.add('unknown-history')
                continue
            if row.get('v') == 2 and row.get('kind') == 'launch-attempt' and row.get('attempt_id') in found:
                found[row['attempt_id']].add(row.get('outcome'))
    return found


def receipt(record, outcome, **extra):
    path = Path.home() / '.himmel/launch-refusals.jsonl'
    path.parent.mkdir(parents=True, exist_ok=True)
    row = dict(v=2, kind='launch-attempt', source='fleet-runtime', ts=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
               attempt_id=record['attempt_id'], name=record['name'], doc=record['doc'],
               family=record['family'], owner=record['owner'], session=record.get('session'), outcome=outcome,
               cause=record.get('cause', 'runtime'), phase='runtime',
               committer=record.get('committer'), reservation=record.get('reservation'), manifest=record.get('manifest'), **extra)
    line = (json.dumps(row) + '\n').encode()
    with path.open('ab+') as stream:
        if stream.seek(0, os.SEEK_END):
            stream.seek(-1, os.SEEK_END)
            if stream.read(1) != b'\n':
                line = b'\n' + line
        stream.write(line)
        stream.flush()
        os.fsync(stream.fileno())


def owned_rows(manifest):
    """Include unknown ownership even after legacy manifest removal."""
    manifest = Path(manifest)
    data = read(manifest)
    rows = data.get('workers', data.get('legs', []))
    anchor = manifest.parent / 'fleet-control.json'
    if anchor.exists():
        control = read(anchor)
        if read(manifest).get('control') != {'family': control['family'], 'anchor': str(anchor)}:
            print('fleet-runtime: unverified sibling family reference; preserving legacy ownership: ' + str(manifest), file=sys.stderr)
            return [dict(row, ownership='unverified') for row in rows]
        for record in control.get('attempts', {}).values():
            matching = [row for row in rows if row['doc'] == record['doc']]
            if matching:
                for row in matching:
                    row['attempt'] = record
            else:
                rows.append({'doc': record['doc'], 'label': record['name'], 'attempt': record})
        current = {record['doc'] for record in control.get('attempts', {}).values()}
        history = receipts({row.get('attempt', {}).get('attempt_id') for row in rows},
                           {row['doc'] for row in rows if row.get('registration') == 'pending'})
        terminal_docs = {}
        for row in history.values():
            if row.get('doc'):
                terminal_docs[row['doc']] = row
        rows = [row for row in rows if row['doc'] in current or row.get('registration') != 'pending'
                or not settles(terminal_docs.get(row['doc'], {}), row) or not reads_ended(row['doc'])]
    return rows


def reads_ended(doc):
    """True when the doc's newest marker is absent or an end marker, the only doc a terminal receipt releases.
    A SUCCESSION note after an end marker leaves the doc ended, as ts_marker_newest reads it."""
    newest = marker(doc)
    if re.match(r'- \d{1,2}:\d{2} SUCCESSION\b', newest):
        newest = marker(doc, skip=r'- \d{1,2}:\d{2} SUCCESSION\b') or newest
    return not newest or re.match(r'- \d{1,2}:\d{2} (?:WRAPPED|HALTED)\b', newest) is not None


def settles(receipt, row):
    """A terminal receipt ends the pending registration it settled, never one added after it.

    Receipts and registrations are stamped to the second; a tie reads as settled,
    which is the copied-before-begin manifest whose refusal landed the same second."""
    return receipt.get('outcome') in ('refused', 'complete') and not row.get('added', '') > receipt.get('ts', '')


def named_session_alive(name, doc, deadline):
    """True unless a full readable /proc pass finds no live `claude -n <name>` working on this doc."""
    if not name:
        return False
    for path in Path('/proc').iterdir():
        if time.monotonic() >= deadline:
            return True
        if not path.name.isdigit():
            continue
        try:
            if (path / 'comm').read_text().strip() != 'claude':
                continue
            args = (path / 'cmdline').read_bytes().split(b'\0')
            if not any(a == b'-n' and i + 1 < len(args) and args[i + 1].decode() == name for i, a in enumerate(args)):
                continue
            if path.joinpath('stat').read_text().rsplit(')', 1)[1].split()[0] in ('Z', 'X'):
                continue
            env = dict(pair.split(b'=', 1) for pair in (path / 'environ').read_bytes().split(b'\0') if b'=' in pair)
            if env.get(b'WORKER_SESSION_DOC') == doc.encode():
                return True
        except (OSError, ValueError, UnicodeError):
            if path.exists():
                return True  # an unreadable candidate cannot prove absence
    return False


def protected(doc):
    anchor = Path(doc).resolve().parent / 'fleet-control.json'
    if not anchor.exists():
        return any(row.get('doc') == str(Path(doc).resolve()) and row.get('attempt', {}).get('phase') in ('pending', 'committed', 'unknown')
                   for path in anchor.parent.glob('*.fleet.json') for row in read(path).get('workers', []))
    return any(r.get('doc') == str(Path(doc).resolve()) and r.get('phase') in ('pending', 'committed', 'unknown')
               for r in read(anchor).get('attempts', {}).values())


def disposition(doc):
    """The doc's current managed attempt phase, else its latest terminal receipt, else legacy.

    A terminal receipt is only the ended attempt's own word: it stands for neither a
    registration added after it nor a doc a live named session is working on. The
    caller still reads the queue lock and the newest marker before it ends ownership."""
    doc = str(Path(doc).resolve())
    anchor = Path(doc).parent / 'fleet-control.json'
    if anchor.exists():
        for record in read(anchor).get('attempts', {}).values():
            if record.get('doc') == doc:
                return record.get('phase', 'unknown')
        rows = [row for path in anchor.parent.glob('*.fleet.json') for row in read(path).get('workers', [])
                if row.get('doc') == doc]
        if all(row.get('registration') == 'pending' for row in rows):
            history = receipts(set(), {doc})
            matching = [row for row in history.values() if row.get('doc') == doc]
            if matching and matching[-1].get('outcome') in ('refused', 'complete') and all(settles(matching[-1], row) for row in rows):
                if named_session_alive(matching[-1].get('name'), doc, time.monotonic() + 2):
                    return 'unknown'
                return matching[-1]['outcome']
    return 'unknown' if protected(doc) else 'legacy'


def worker_state(doc, timeout=10, disposition=None, reading='ts_worker_state'):
    """The one ownership reading of a doc (ticket-status.sh ts_worker_state, or ts_worker_ownership, which also answers
    abandoned). A caller that already holds the doc's disposition, as WorkerStates does, passes it so the shell does not
    read every manifest again for it."""
    script, argv = '. "$1/ticket-status.sh"; %s "$2"' % reading, ['fleet-runtime', str(LIB), doc]
    if disposition is not None:
        script, argv = script + ' "$3"', argv + [json.dumps(disposition)]
    try:
        result = subprocess.run(['bash', '-c', script, *argv], capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip() if result.returncode == 0 else 'unknown'
    except (OSError, subprocess.SubprocessError):
        return 'unknown'


def read_directory(directory):
    """Everything disposition reads in one directory, each file once: the anchor's attempts and every manifest's rows by doc."""
    anchor = directory / 'fleet-control.json'
    anchored = anchor.exists()
    attempts = list(read(anchor).get('attempts', {}).values()) if anchored else []
    rows = {}
    for path in directory.glob('*.fleet.json'):
        for row in read(path).get('workers', []):
            rows.setdefault(row.get('doc'), []).append(row)
    return anchored, attempts, rows


def latest_receipts():
    """For every doc, the row receipts(set(), {doc}) ends with for it, from one read of the history: one found-map per doc,
    each attempt admitted for a doc by a row naming that doc or by an earlier row of an attempt already admitted for it."""
    path = Path.home() / '.himmel/launch-refusals.jsonl'
    if not path.exists():
        return {}
    found, holders = {}, {}
    deadline = time.monotonic() + 3
    with path.open() as stream:
        while True:  # t13b-ok: ends at end of file, or raises Refused on the first line read after the 3 s deadline
            line = stream.readline(1048576)
            if not line:
                break
            if time.monotonic() > deadline or (len(line) == 1048576 and not line.endswith('\n')):
                raise Refused('receipt history exceeds bounded read')
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get('v') == 2 and row.get('kind') == 'launch-attempt':
                doc, attempt = row.get('doc'), row.get('attempt_id')
                if any(value is not None and not isinstance(value, str) for value in (doc, attempt)):
                    raise Refused('receipt row cannot be placed')
                docs = set(holders.get(attempt, ())) | ({doc} if doc is not None else set())
                if docs and 'attempt_id' not in row:
                    raise Refused('receipt row has no attempt id')
                for name in docs:
                    found.setdefault(name, {})
                    found[name][attempt] = dict(found[name].pop(attempt, {}), **row)
                    holders.setdefault(attempt, set()).add(name)
    return {name: next((row for row in reversed(list(rows.values())) if row.get('doc') == name), None) for name, rows in found.items()}


class WorkerStates:
    """One run's worker states: worker_state(doc) at most once per doc, and every directory's manifests, anchor and the
    receipt history read once. The answer is still worker_state's own; this only hands it the disposition it would
    otherwise read doc by doc (batched). A directory or history that cannot be read gets None for every doc that needs it:
    worker_state then reads that doc the one-doc way and reports what that read reports. A doc a successfully read
    directory does not name is answered as the one-doc read answers it (legacy: no row, no attempt, no receipt)."""

    def __init__(self):
        self.states, self.directories, self.history = {}, {}, None

    def __call__(self, doc, timeout=10):
        if doc not in self.states:
            self.states[doc] = worker_state(doc, timeout, self.batched(doc))
        return self.states[doc]

    def batched(self, doc):
        try:
            return self._answer(str(Path(doc).resolve()))
        except Exception:  # noqa: BLE001 - whatever cannot be read or placed here is left to the one-doc read
            return None

    def _answer(self, doc):
        directory = Path(doc).parent
        if directory not in self.directories:
            try:
                self.directories[directory] = read_directory(directory)
            except Exception:  # noqa: BLE001 - the whole directory is left to the one-doc read
                self.directories[directory] = None
        if self.directories[directory] is None:
            return None
        anchored, attempts, rows = self.directories[directory]
        rows = rows.get(doc, [])
        if not anchored:
            return 'unknown' if any(row.get('attempt', {}).get('phase') in ('pending', 'committed', 'unknown') for row in rows) else 'legacy'
        for record in attempts:
            if record.get('doc') == doc:
                return record.get('phase', 'unknown')
        if all(row.get('registration') == 'pending' for row in rows):
            if self.history is None:
                try:
                    self.history = latest_receipts()
                except Exception:  # noqa: BLE001 - the history is left to the one-doc read
                    self.history = False
            if self.history is False:
                return None
            last = self.history.get(doc)
            if last and last.get('outcome') in ('refused', 'complete') and all(settles(last, row) for row in rows):
                if named_session_alive(last.get('name'), doc, time.monotonic() + 2):
                    return 'unknown'
                return last['outcome']
        return 'unknown' if any(r.get('doc') == doc and r.get('phase') in ('pending', 'committed', 'unknown') for r in attempts) else 'legacy'


def marker(doc, skip=None):
    try:
        lines = Path(doc).read_text().splitlines()
        return next((line for line in reversed(lines) if re.match(r'^- \d{1,2}:\d{2} [A-Z]', line) and not (skip and re.match(skip, line))), '')
    except OSError:
        return ''


TITLE_KEY_RE = re.compile(r'([A-Z]+)-(\d+)((?:\s*\(?\s*(?:[/+,&]\s*)+\(?\s*\d+\b)*)')


def title_keys(line):
    return [('%s-%s' % (p, n)) for p, n, _ in TITLE_KEY_RE.findall(line)] + \
           [('%s-%s' % (p, x)) for p, _, rest in TITLE_KEY_RE.findall(line) for x in re.findall(r'\d+', rest)]


def worker_keys(doc):
    keys = re.findall(r'[A-Z]+-[0-9]+', Path(doc).name)
    try:
        for line in Path(doc).read_text().splitlines():
            if line.startswith('## Results'):
                break
            if line.startswith('# '):
                keys.extend(title_keys(line))
            elif re.match(r'^> \*\*(?:Ticket|Owns)(?: tickets)?:\*\*', line):
                keys.extend(re.findall(r'[A-Z]+-[0-9]+', line))
    except OSError:
        pass  # missing remote docs retain the keys in their registered names
    return sorted(set(keys))


def session_scan(record, deadline):
    local = identity(os.getpid())
    if any(record['owner'][key] != local[key] for key in ('host', 'boot')):
        return None, False
    absent = True
    for path in Path('/proc').iterdir():
        if time.monotonic() >= deadline:
            return None, False
        if not path.name.isdigit():
            continue
        try:
            if (path / 'comm').read_text().strip() != 'claude':
                continue
            args = (path / 'cmdline').read_bytes().split(b'\0')
            if not any(a == b'-n' and i + 1 < len(args) and args[i + 1].decode() == record['name'] for i, a in enumerate(args)):
                continue
            if path.joinpath('stat').read_text().rsplit(')', 1)[1].split()[0] in ('Z', 'X'):
                continue
            absent = False
            env = dict(pair.split(b'=', 1) for pair in (path / 'environ').read_bytes().split(b'\0') if b'=' in pair)
            if env.get(b'WORKER_SESSION_DOC') != record['doc'].encode() or env.get(b'WORKER_SESSION_ATTEMPT_ID') != record['attempt_id'].encode():
                continue
            found = identity(int(path.name))
            if int(found['start']) >= record['began_ticks']:
                return found, False
        except (OSError, ValueError, UnicodeError):
            if path.exists():
                absent = False  # unreadable candidates cannot prove absence
    return None, absent


def session_evidence(record, deadline):
    return session_scan(record, deadline)[0]


def session_ended(record, deadline):
    if record.get('session') and process_state(record['session']) != 'dead':
        return False
    return session_scan(record, deadline)[1]


def same_receipt(record, row):
    return bool(record.get('attempt_id')) and all(row.get(key) == record.get(key) for key in ('attempt_id', 'name', 'doc', 'family', 'owner'))


def launch_candidates(record, deadline):
    """Processes that could still be this attempt's launch, whatever their name. (carrying, unreadable, complete):
    those whose environment or arguments carry its id (WORKER_SESSION_ATTEMPT_ID or FLEET_LAUNCH_ATTEMPT), and those of
    this user whose command line names the attempt or its doc but whose environment cannot be read. An unreadable candidate
    is not proof of absence: the rule session_scan applies to a named candidate it cannot read, refuse. A process of
    another user, or one that names neither the attempt nor its doc, is not a candidate."""
    wanted = {('%s=%s' % (key, record['attempt_id'])).encode() for key in ('WORKER_SESSION_ATTEMPT_ID', 'FLEET_LAUNCH_ATTEMPT')}
    mentions = (record['name'].encode(), record['doc'].encode())
    me, uid = os.getpid(), os.getuid()
    carrying, unreadable = [], []
    for path in Path('/proc').iterdir():
        if time.monotonic() >= deadline:
            return carrying, unreadable, False
        if not path.name.isdigit() or int(path.name) == me:
            continue
        try:
            if path.joinpath('stat').read_text().rsplit(')', 1)[1].split()[0] in ('Z', 'X'):
                continue
            who = (path.name, path.joinpath('comm').read_text().strip())
            args = path.joinpath('cmdline').read_bytes().split(b'\0')
            if wanted & set(args):
                carrying.append(who)
                continue
            try:
                environment = set(path.joinpath('environ').read_bytes().split(b'\0'))
            except OSError:
                real = int(next(line for line in path.joinpath('status').read_text().splitlines() if line.startswith('Uid:')).split()[1])
                if path.exists() and real == uid and any(m in a for m in mentions for a in args):
                    unreadable.append(who)
                continue
            if wanted & environment:
                carrying.append(who)
        except (OSError, ValueError, UnicodeError, StopIteration):
            if path.exists():
                unreadable.append((path.name, '?'))  # an existing process the scan cannot read at all cannot be ruled out
    return carrying, unreadable, True


def settle_blockers(record, outcomes, deadline):
    """Why a stuck attempt cannot be settled as refused with no session now; empty when every precondition holds.
    Evidence only: the committed or unknown phase, the process identity of the owner and the committer, one full readable
    session scan, and the attempt's history. It reads no age and no elapsed time; the deadline only bounds the scan."""
    blockers = []
    if record['phase'] not in ('committed', 'unknown'):
        blockers.append('phase is %s (settle takes a committed or unknown attempt)' % record['phase'])
    for who in ('owner', 'committer'):
        state = process_state(record[who]) if record.get(who) else 'dead'
        if state != 'dead':
            blockers.append('%s is not proven dead (%s)' % (who, state))
    seen = sorted(outcomes & {'launched', 'refused', 'complete'})
    if seen:
        blockers.append('a %s receipt exists (reconcile settles it)' % '/'.join(seen))
    if 'unknown-history' in outcomes:
        blockers.append('the receipt history has a line that cannot be read, so a launched receipt cannot be ruled out')
    if not session_ended(record, deadline):
        blockers.append('a session may exist (the scan did not prove absence)')
    carrying, unreadable, complete = launch_candidates(record, deadline)
    for pid, comm in carrying[:3]:
        blockers.append('a launch may still be starting: process %s (%s) carries the attempt id' % (pid, comm))
    for pid, comm in unreadable[:3]:
        blockers.append('a process of this user that could be the launch cannot be read: %s (%s)' % (pid, comm))
    if not complete:
        blockers.append('the process scan did not finish')
    return blockers


def settle_hint(record, outcomes, deadline):
    """Text for the chief that reads ack. Nothing runs it."""
    blockers = settle_blockers(record, outcomes, deadline)
    if blockers:
        return {'settleable': False, 'text': 'not settleable now: ' + '; '.join(blockers)}
    command = 'fleet-manifest.sh runtime settle --manifest %s --doc %s --name %s --attempt-id %s --reason %s --confirm-no-session' % (
        shlex.quote(record['manifest']), shlex.quote(record['doc']), shlex.quote(record['name']), shlex.quote(record['attempt_id']), shlex.quote('<why>'))
    return {'settleable': True, 'text': 'settleable now. Only after you have checked that no launch of this worker is still starting, and with <why> replaced by the reason in your own words, type: ' + command}


def settle_attempt(args, attempts, rows, doc, history):
    """The one explicit exit for a committed or unknown attempt whose launcher died with no session ever seen: refused,
    its reservation and family target slot released, its history kept. It runs only when the chief or the operator types
    it (nothing calls it, ack and reconcile only print the hint) and it needs every precondition of settle_blockers."""
    if not args.confirm_no_session:
        raise Refused('settle refused: --confirm-no-session is required')
    reason = (args.reason or '').strip()
    if not reason:
        raise Refused('settle refused: a non-empty --reason is required')
    if re.fullmatch(r'<[^<>]*>|\[[^\[\]]*\]|\{[^{}]*\}', reason):
        raise Refused('settle refused: --reason must give the reason in your own words, not a bracketed placeholder')
    record = attempts.get(args.attempt_id)
    if not record:
        row = history.get(args.attempt_id, {})
        if row.get('outcome') == 'refused' and row.get('cause') == 'settled-no-session' and row.get('doc') == doc:
            return {'replayed': True, 'phase': 'refused', 'cause': 'settled-no-session'}
        raise Refused('settle refused: unknown attempt')
    if record['doc'] != doc or record['name'] != args.name:
        raise Refused('settle refused: attempt locator conflict')
    blockers = settle_blockers(record, attempt_outcomes({args.attempt_id})[args.attempt_id], time.monotonic() + 5)
    if blockers:
        raise Refused('settle refused: ' + '; '.join(blockers))
    evidence = dict(phase=record['phase'], owner='dead', committer='dead' if record.get('committer') else None, scan='absent',
                    carriers='none', session=bool(record.get('session')))
    record['cause'] = 'settled-no-session'
    receipt(record, 'refused', reason=reason[:1000], evidence=evidence,
            settled_by=dict(host=socket.gethostname(), pid=os.getpid(), uid=os.getuid()))
    release_reservation(record)
    del attempts[args.attempt_id]
    rows[:] = [w for w in rows if not (w.get('doc') == doc and w.get('attempt', {}).get('attempt_id') == args.attempt_id)]
    return {'phase': 'refused', 'cause': 'settled-no-session'}


def reconcile(attempts, rows, history, deadline, effects=True):
    """Run under manifest→anchor locks, before admission as well as ack; effects=False settles in memory only (no receipt, no slot release)."""
    settled = set()
    for aid, record in list(attempts.items()):
        if time.monotonic() >= deadline:
            break
        row = history.get(aid, {})
        terminal = ''
        if same_receipt(record, row) and row.get('outcome') in ('refused', 'complete'):
            if row['outcome'] == 'refused' or session_ended(record, deadline):
                terminal = row['outcome']
        elif same_receipt(record, row) and row.get('outcome') == 'launched':
            record['phase'] = 'launched'
        if not terminal and record['phase'] == 'pending' and not record.get('handoff_started') and process_state(record['owner']) == 'dead':
            record['cause'] = 'launcher-lost-precommit'
            terminal = 'refused'
        elif not terminal and not live(record['owner']) and record['phase'] != 'launched':
            record['phase'] = 'unknown'
        if not terminal and record.get('phase') == 'unknown':
            session = session_evidence(record, min(deadline, time.monotonic() + 1))
            if session:
                record['session'], record['phase'] = session, 'launched'
                if effects:
                    receipt(record, 'launched')
        if not terminal and record.get('phase') == 'launched' and marker(record['doc']) != record.get('initial_marker') and session_ended(record, deadline) and time.monotonic() < deadline and worker_state(record['doc'], max(.01, deadline - time.monotonic())) == 'wrapped':
            terminal = 'complete'
        if terminal:
            if effects:
                receipt(record, terminal)
                release_reservation(record)
            del attempts[aid]
            settled.add(aid)
        # A copied manifest can retain an old attempt after another manifest
        # settled it. Its typed terminal receipt also removes that projection.
    rows[:] = [row for row in rows if row.get('attempt', {}).get('attempt_id') not in settled and not (row.get('registration') == 'pending'
        and row.get('attempt', {}).get('attempt_id') not in attempts
        and same_receipt(row.get('attempt', {}), history.get(row.get('attempt', {}).get('attempt_id'), {}))
        and history[row['attempt']['attempt_id']].get('outcome') in ('refused', 'complete'))]
    for row in rows:
        aid = row.get('attempt', {}).get('attempt_id')
        if aid in attempts:
            row['attempt'] = attempts[aid].copy()


def ownership_check(attempts, manifest, doc, name, keys):
    """begin's family ownership refusals, shared with the read-only admit a dry run uses."""
    if any(r['doc'] == doc or r['name'] == name or set(r['keys']) & set(keys) for r in attempts.values()):
        raise Refused('family already owns worker or ticket')
    legacy_deadline = time.monotonic() + 5
    for sibling in manifest.parent.glob('*.fleet.json'):
        listed = read(sibling)
        for row in listed.get('workers', []) + listed.get('legs', []):
            if row.get('registration') != 'pending' and (row.get('doc') == doc or set(worker_keys(row['doc'])) & set(keys)):
                if time.monotonic() >= legacy_deadline or worker_state(row['doc'], max(.01, legacy_deadline - time.monotonic()),
                                                                       reading='ts_worker_ownership') not in ('wrapped', 'abandoned'):
                    raise Refused('unknown legacy family ownership')


def joined_attempt(attempts, doc, attempt_id):
    record = attempts.get(attempt_id) if attempt_id else None
    if not record or record['doc'] != doc or record['phase'] not in ('committed', 'launched'):
        return None
    chain = ancestors()
    if any(isinstance(holder, dict) and holder.get('pid') in chain and live(holder) for holder in (record['owner'], record.get('session'))):
        return record
    return None


def admit_read_only(manifest, doc, name, join=''):
    """The admission a real launch's begin and check make, with no lock, no write and no receipt."""
    value = snapshot(manifest)
    if value['mode'] != 'active':
        raise Refused('fleet-paused')
    attempts = read(manifest.parent / 'fleet-control.json').get('attempts', {})
    reconcile(attempts, read(manifest).get('workers', []), receipts(set(attempts)), time.monotonic() + 5, effects=False)
    doc = str(Path(doc).resolve())
    joined = joined_attempt(attempts, doc, join)
    if not joined:
        ownership_check(attempts, manifest, doc, name, worker_keys(doc))
    return dict(value, joined=joined['attempt_id'] if joined else None)


def run(args):
    if args.op == 'disposition':
        return disposition(args.doc)
    if args.op == 'reservation':
        manifest = resolve(args.doc, args.manifest)
        if manifest is None:
            return False
        record = read(manifest.parent / 'fleet-control.json').get('attempts', {}).get(args.attempt_id)
        if not record:
            return False
        return has_reservation(record, args.pid)
    if args.op == 'protected':
        return protected(args.doc)
    if args.op == 'owners':
        return owned_rows(args.manifest)
    if args.op == 'release':
        caller(args.pid)
        terminal = receipts({args.attempt_id}).get(args.attempt_id, {})
        if terminal.get('outcome') not in ('refused', 'complete'):
            raise Refused('reservation has no definite terminal receipt')
        manifest = resolve(terminal['doc'], args.manifest or terminal.get('manifest', ''))
        if manifest is None:
            raise Refused('terminal reservation has no family reference')
        with lock(manifest), lock(manifest.parent / 'fleet-control.json'):
            control = read(manifest.parent / 'fleet-control.json')
            current = control.get('attempts', {}).get(args.attempt_id)
            if current and (not same_receipt(current, terminal) or terminal['outcome'] == 'complete' and not session_ended(current, time.monotonic() + 1)):
                raise Refused('terminal reservation still has possible session')
            release_reservation(terminal)
        return {'released': args.attempt_id}
    if args.op == 'stamp':
        argv = Path('/proc', str(os.getppid()), 'cmdline').read_bytes().split(b'\0')
        if len(argv) < 2 or Path(os.fsdecode(argv[1])).resolve() != LIB / 'usage-preflight.sh':
            raise Refused('only the real resource preflight stamps admission')
    manifest = Path(args.manifest).absolute() if args.op in ('ack', 'reconcile') and args.manifest else resolve(args.doc, args.manifest)
    if manifest is None:
        if args.op == 'settle':
            raise Refused('settle refused: the doc is not a managed worker')
        return {'managed': False, 'administrative': bool(args.doc and (Path(args.doc).resolve().parent / 'fleet-control.json').exists())}
    anchor = manifest.parent / 'fleet-control.json'
    if args.op in ('resolve', 'admit'):
        value = admit_read_only(manifest, args.doc, args.name, args.join_attempt) if args.op == 'admit' else snapshot(manifest)
        return dict(value, managed=True, manifest=str(manifest), slots=str(slots_root()))
    with lock(manifest), lock(anchor):
        value = snapshot(manifest)
        control = read(anchor)
        attempts = control.setdefault('attempts', {})
        data = read(manifest)
        rows = data.setdefault('workers', [])
        doc = str(Path(args.doc).resolve()) if args.doc else ''
        peer_rows = []
        if args.op in ('ack', 'reconcile'):
            for source in {manifest, *manifest.parent.glob('*.fleet.json')}:
                peer = read(source)
                for row in peer.get('workers', peer.get('legs', [])):
                    peer_rows.append(dict(row, ownership='unverified') if peer.get('control') != data.get('control') else row)
        history = receipts(set(attempts) | {args.attempt_id} | {row.get('attempt', {}).get('attempt_id') for row in peer_rows})
        if args.op in ('ack', 'reconcile', 'begin', 'check', 'commit'):
            deadline = time.monotonic() + 5
            reconcile(attempts, rows, history, deadline)
            publish(anchor, control)
            publish(manifest, data)
        if args.op == 'check':
            if value['mode'] != 'active':
                raise Refused('fleet-paused')
            return dict(value, managed=True, manifest=str(manifest), slots=str(slots_root()))
        if args.op in ('ack', 'reconcile'):
            inflight = [r for r in attempts.values() if r['phase'] in ('pending', 'committed')]
            unknown = [r for r in attempts.values() if r['phase'] == 'unknown']
            legacy = {}
            current_docs = {record['doc'] for record in attempts.values()}
            for row in peer_rows:
                if row['doc'] in current_docs or (row.get('ownership') != 'unverified' and row.get('registration') == 'pending' and not row.get('attempt')):
                    continue
                if row.get('ownership') != 'unverified' and row.get('registration') == 'pending' and history.get(row.get('attempt', {}).get('attempt_id'), {}).get('outcome') in ('refused', 'complete'):
                    continue
                if time.monotonic() >= deadline or worker_state(row['doc'], max(.01, deadline - time.monotonic())) != 'wrapped':
                    legacy[row['doc']] = dict(doc=row['doc'], label=row.get('label'),
                                              attempt_id=row.get('attempt', {}).get('attempt_id'), phase='legacy-unknown')
            hint_deadline, outcomes = time.monotonic() + 3, attempt_outcomes({r['attempt_id'] for r in unknown})
            return dict(value, in_flight=inflight,
                        unknown=[dict(r, settle_hint=settle_hint(r, outcomes[r['attempt_id']], hint_deadline)) for r in unknown],
                        legacy_unknown=list(legacy.values()), quiescent=value['mode'] != 'active' and not attempts and not legacy,
                        launched=[r for r in attempts.values() if r['phase'] == 'launched'])
        if not re.fullmatch(r'[A-Za-z0-9-]{1,80}', args.attempt_id):
            raise Refused('invalid attempt id')
        if args.op == 'settle':
            result = settle_attempt(args, attempts, rows, doc, history)
            if not result.get('replayed'):
                publish(anchor, control)
                publish(manifest, data)
            return result
        record = attempts.get(args.attempt_id)
        if args.op == 'begin':
            if record:
                authorized(record, args.pid)
                if record['doc'] != doc or record['phase'] != 'pending':
                    raise Refused('attempt replay')
                return record
            if args.attempt_id in history:
                raise Refused('attempt already has receipt history')
            keys = worker_keys(doc)
            joined = joined_attempt(attempts, doc, args.join_attempt)
            if joined:
                return {'joined': joined['attempt_id'], 'phase': joined['phase']}
            ownership_check(attempts, manifest, doc, args.name, keys)
            matches = [w for w in rows if w.get('doc') == doc]
            if not matches:
                result = subprocess.run(['bash', '-c', '. "$1/worker-identity.sh"; worker_label "$2"',
                                         'fleet-runtime', str(LIB), doc], capture_output=True, text=True, timeout=5, check=True)
                matches = [dict(doc=doc, label=result.stdout.strip(), lane=args.lane, registration='pending', added=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))]
                rows.extend(matches)
            if len(matches) != 1 or matches[0].get('attempt') or matches[0].get('registration') != 'pending':
                raise Refused('worker must have exactly one pending registration')
            record = dict(attempt_id=args.attempt_id, phase='pending', doc=doc, name=args.name, keys=keys,
                          manifest=str(manifest),
                          family=value['family'], control_generation=value['generation'], owner=caller(args.pid),
                          began_ticks=int(float(Path('/proc/uptime').read_text().split()[0]) * os.sysconf('SC_CLK_TCK')),
                          initial_marker=marker(doc),
                          receipt={'v': 2, 'kind': 'launch-attempt', 'attempt_id': args.attempt_id})
            attempts[args.attempt_id] = record
            matches[0]['attempt'] = record.copy()
            publish(anchor, control)
            publish(manifest, data)
            receipt(record, 'attempt-started')
            return record
        if not record:
            row = history.get(args.attempt_id, {})
            if (args.op == 'finish' or (args.op == 'outcome' and args.phase == 'refused')) and row.get('outcome') == 'refused' and row.get('doc') == doc:
                return {'replayed': True, 'phase': 'refused', 'cause': row.get('cause')}
            raise Refused('unknown attempt')
        if record['doc'] != doc or record['name'] != args.name:
            raise Refused('attempt locator conflict')
        authorized(record, args.pid)
        if args.op == 'stamp':
            owner = caller(args.pid)
            slot = Path(args.slot).absolute()
            if record['phase'] != 'pending' or slot.parent != slots_root() or slot.is_symlink() or (slot / 'name').read_text().rstrip('\n') != args.name:
                raise Refused('reservation worker or root conflict')
            if value['mode'] != 'active' or value['generation'] != record['control_generation']:
                raise Refused('fleet-paused or reservation generation changed')
            if (slots_root() / '.admit/pid').read_text().strip() != str(os.getppid()):
                raise Refused('reservation admission lock is not held by preflight')
            publish(slot / 'managed.json', {'attempt_id': args.attempt_id, 'owner': owner})
            record['reservation'] = {'path': str(slot), 'owner': owner}
            publish(anchor, control)
            return {'stamped': args.attempt_id}
        if args.op == 'handoff':
            if record['phase'] != 'pending' or value['mode'] != 'active' or value['generation'] != record['control_generation']:
                raise Refused('fleet-paused or handoff conflict')
            record['handoff_started'] = True
            publish(anchor, control)
            return record
        if args.op == 'commit':
            if value['mode'] != 'active' or value['generation'] != record['control_generation']:
                raise Refused('fleet-paused or generation changed')
            if record['phase'] != 'pending':
                raise Refused('attempt already committed or unknown')
            if not has_reservation(record, args.pid):
                raise Refused('attempt has no process-bound resource reservation')
            occupied = sum(r['phase'] in ('committed', 'unknown', 'launched') for r in attempts.values())
            if occupied >= value['target']:
                raise Refused('family target reached')
            record['phase'] = 'committed'
            record['committer'] = caller(args.pid)
            publish(anchor, control)
            return record
        if args.op == 'finish':
            if record['phase'] == 'launched':  # launched is terminal: finish never moves it back to unknown
                return {'phase': 'launched', 'cause': record.get('cause')}
            args.op = 'outcome'
            args.phase = 'refused' if record['phase'] == 'pending' and not record.get('handoff_started') else 'unknown'
        if args.op == 'outcome':
            if args.phase == 'complete' and not session_ended(record, time.monotonic() + 1):
                raise Refused('complete outcome still has possible session')
            if args.phase == 'launched' and record['phase'] == 'pending':
                raise Refused('launched receipt has no spawn commitment')
            if args.phase == 'refused' and record['phase'] != 'pending' and not args.spawn_failed:
                raise Refused('committed attempt needs affirmative terminal evidence')
            if args.phase == 'refused':
                record['cause'] = 'spawn-failed' if args.spawn_failed else 'fleet-paused' if value['mode'] != 'active' or value['generation'] != record['control_generation'] else 'prelaunch-refused'
            outcome = {'unknown': 'indeterminate', 'launched': 'launched', 'refused': 'refused', 'complete': 'complete'}[args.phase]
            receipt(record, outcome)
            if args.phase in ('refused', 'complete'):
                release_reservation(record)
                del attempts[args.attempt_id]
                rows[:] = [w for w in rows if not (w.get('doc') == doc and w.get('attempt', {}).get('attempt_id') == args.attempt_id)]
            else:
                record['phase'] = args.phase
                if args.phase == 'launched':
                    session = session_evidence(record, time.monotonic() + 1)
                    if session:
                        record['session'] = session
                for row in rows:
                    if row.get('attempt', {}).get('attempt_id') == args.attempt_id:
                        row['attempt'] = record.copy()
            publish(anchor, control)
            publish(manifest, data)
            return {'phase': args.phase, 'cause': record.get('cause')}
    raise Refused('unknown operation')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('op', choices=['resolve', 'admit', 'check', 'begin', 'handoff', 'commit', 'outcome', 'finish', 'ack', 'reconcile', 'run', 'release', 'stamp', 'protected', 'disposition', 'owners', 'reservation', 'settle'])
    parser.add_argument('--doc', default='')
    parser.add_argument('--manifest', default='')
    parser.add_argument('--name', default='')
    parser.add_argument('--attempt-id', default='')
    parser.add_argument('--join-attempt', default='')
    parser.add_argument('--pid', type=int, default=os.getppid())
    parser.add_argument('--phase', choices=['refused', 'unknown', 'launched', 'complete'])
    parser.add_argument('--slot', default='')
    parser.add_argument('--lane', choices=['native', 'claudex', 'openrouter', 'deepseek', 'api'], default='native')
    parser.add_argument('--reason', default='')
    parser.add_argument('--confirm-no-session', action='store_true')
    parser.set_defaults(spawn_failed=False)
    argv = sys.argv[1:]
    command = argv[argv.index('--') + 1:] if '--' in argv else []
    args = parser.parse_args(argv[:argv.index('--')] if '--' in argv else argv)
    try:
        if args.op == 'run':
            if not command:
                raise Refused('missing supervised command')
            os.environ['FLEET_LAUNCH_WORKER_INTENT'] = '1'
            args.op = 'begin'
            args.pid = os.getpid()
            args.attempt_id = str(uuid.uuid4())
            # This process supervises the child through its terminal outcome.
            result = run(args)
            if result.get('managed') is False:
                return subprocess.call(command)
            env = dict(os.environ, FLEET_LAUNCH_DOC=args.doc, FLEET_LAUNCH_ATTEMPT=args.attempt_id,
                       FLEET_LAUNCH_MANIFEST=str(resolve(args.doc, args.manifest)), CADENCE_USAGE_LAUNCH='1',
                       CADENCE_USAGE_WORKER=args.name, CADENCE_USAGE_CALLER_PID=str(os.getpid()))
            preflight = subprocess.run(['bash', str(LIB / 'usage-preflight.sh')], env=env, capture_output=True, text=True, timeout=60)
            if preflight.returncode or preflight.stdout.strip() not in ('PROCEED', 'BANK-STALE', 'BANK-UNKNOWN'):
                args.op, args.phase = 'outcome', 'refused'
                run(args)
                args.op = 'release'
                run(args)
                raise Refused('scheduled launch preflight refused: ' + preflight.stdout.strip())
            args.op = 'commit'
            try:
                run(args)
            except Refused:
                args.op, args.phase = 'outcome', 'refused'
                run(args)
                args.op = 'release'
                run(args)
                raise
            child_env = {key: value for key, value in os.environ.items() if not key.startswith('FLEET_LAUNCH_')}
            child_env.update(WORKER_SESSION_DOC=args.doc, WORKER_SESSION_ATTEMPT_ID=args.attempt_id)
            try:
                proc = subprocess.Popen(command, env=child_env)
            except OSError:
                args.op, args.phase, args.spawn_failed = 'outcome', 'refused', True
                run(args)
                args.op = 'release'
                run(args)
                raise
            rc = proc.wait()
            args.op, args.phase = 'outcome', 'complete'
            run(args)
            args.op = 'release'
            run(args)
            return rc
        print(json.dumps(run(args)))
    except (Refused, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('fleet-runtime: fleet-paused: ' + str(error), file=sys.stderr)
        return 10
    return 0


if __name__ == '__main__':
    sys.exit(main())
