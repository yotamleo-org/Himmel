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
        while True:
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


def process_state(owner):
    """Absence is proof only for an exact local host/boot/start identity."""
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
        while True:
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


def receipt(record, outcome):
    path = Path.home() / '.himmel/launch-refusals.jsonl'
    path.parent.mkdir(parents=True, exist_ok=True)
    row = dict(v=2, kind='launch-attempt', source='fleet-runtime', ts=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
               attempt_id=record['attempt_id'], name=record['name'], doc=record['doc'],
               family=record['family'], owner=record['owner'], session=record.get('session'), outcome=outcome,
               cause=record.get('cause', 'runtime'), phase='runtime',
               committer=record.get('committer'), reservation=record.get('reservation'), manifest=record.get('manifest'))
    with path.open('a') as stream:
        stream.write(json.dumps(row) + '\n')
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
                or not settles(terminal_docs.get(row['doc'], {}), row)]
    return rows


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


def worker_state(doc, timeout=10):
    try:
        result = subprocess.run(['bash', '-c', '. "$1/ticket-status.sh"; ts_worker_state "$2"',
                                 'fleet-runtime', str(LIB), doc], capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip() if result.returncode == 0 else 'unknown'
    except (OSError, subprocess.SubprocessError):
        return 'unknown'


def marker(doc):
    try:
        lines = Path(doc).read_text().splitlines()
        return next((line for line in reversed(lines) if re.match(r'^- \d{1,2}:\d{2} [A-Z]', line)), '')
    except OSError:
        return ''


def worker_keys(doc):
    keys = re.findall(r'[A-Z]+-[0-9]+', Path(doc).name)
    try:
        for line in Path(doc).read_text().splitlines():
            if line.startswith('## Results'):
                break
            if line.startswith('# ') or re.match(r'^> \*\*(?:Ticket|Owns)(?: tickets)?:\*\*', line):
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


def reconcile(attempts, rows, history, deadline):
    """Run under manifest→anchor locks, before admission as well as ack."""
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
                receipt(record, 'launched')
        if not terminal and record.get('phase') == 'launched' and marker(record['doc']) != record.get('initial_marker') and session_ended(record, deadline) and time.monotonic() < deadline and worker_state(record['doc'], max(.01, deadline - time.monotonic())) == 'wrapped':
            terminal = 'complete'
        if terminal:
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
        return {'managed': False, 'administrative': bool(args.doc and (Path(args.doc).resolve().parent / 'fleet-control.json').exists())}
    anchor = manifest.parent / 'fleet-control.json'
    if args.op == 'resolve':
        value = snapshot(manifest)
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
            return dict(value, in_flight=inflight, unknown=unknown,
                        legacy_unknown=list(legacy.values()), quiescent=value['mode'] != 'active' and not attempts and not legacy,
                        launched=[r for r in attempts.values() if r['phase'] == 'launched'])
        if not re.fullmatch(r'[A-Za-z0-9-]{1,80}', args.attempt_id):
            raise Refused('invalid attempt id')
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
            if any(r['doc'] == doc or r['name'] == args.name or set(r['keys']) & set(keys) for r in attempts.values()):
                raise Refused('family already owns worker or ticket')
            legacy_deadline = time.monotonic() + 5
            for sibling in manifest.parent.glob('*.fleet.json'):
                for row in read(sibling).get('workers', []):
                    if row.get('registration') != 'pending' and (row.get('doc') == doc or set(worker_keys(row['doc'])) & set(keys)):
                        if time.monotonic() >= legacy_deadline or worker_state(row['doc'], max(.01, legacy_deadline - time.monotonic())) != 'wrapped':
                            raise Refused('unknown legacy family ownership')
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
            args.op = 'outcome'
            args.phase = 'refused' if record['phase'] == 'pending' and not record.get('handoff_started') else 'unknown'
        if args.op == 'outcome':
            if args.phase == 'complete' and not session_ended(record, time.monotonic() + 1):
                raise Refused('complete outcome still has possible session')
            if args.phase == 'launched' and record['phase'] == 'pending':
                raise Refused('launched receipt has no spawn commitment')
            if args.phase == 'refused' and record['phase'] != 'pending':
                raise Refused('committed attempt needs affirmative terminal evidence')
            if args.phase == 'refused':
                record['cause'] = 'fleet-paused' if value['mode'] != 'active' or value['generation'] != record['control_generation'] else 'prelaunch-refused'
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
    parser.add_argument('op', choices=['resolve', 'check', 'begin', 'handoff', 'commit', 'outcome', 'finish', 'ack', 'reconcile', 'run', 'release', 'stamp', 'protected', 'disposition', 'owners', 'reservation'])
    parser.add_argument('--doc', default='')
    parser.add_argument('--manifest', default='')
    parser.add_argument('--name', default='')
    parser.add_argument('--attempt-id', default='')
    parser.add_argument('--pid', type=int, default=os.getppid())
    parser.add_argument('--phase', choices=['refused', 'unknown', 'launched', 'complete'])
    parser.add_argument('--slot', default='')
    parser.add_argument('--lane', choices=['native', 'claudex', 'openrouter', 'deepseek', 'api'], default='native')
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
            proc = subprocess.Popen(command, env=child_env)
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
