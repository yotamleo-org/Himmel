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
    try:
        return identity(owner['pid']) == owner
    except (OSError, KeyError, ValueError):
        return False


def authorized(record, pid):
    caller(pid)
    owner = record['owner']
    if not live(owner) or (owner['pid'] != os.getpid() and owner['pid'] not in ancestors()):
        raise Refused('attempt process identity conflict')


def has_reservation(record, pid):
    authorized(record, pid)
    allowed = (record['owner'], caller(pid))
    slots = Path(os.environ.get('HIMMEL_FLEET_SLOTS', str(Path(os.environ.get('XDG_RUNTIME_DIR', '/tmp')) / ('himmel-fleet-' + str(os.getuid())))))
    if slots.exists():
        for slot in slots.iterdir():
            path = slot / 'managed.json'
            if path.is_file():
                value = read(path)
                if value.get('attempt_id') == record['attempt_id'] and value.get('owner') in allowed:
                    return True
    return False


def resolve(doc, manifest=''):
    """Physical bucket configuration is authoritative even without --fleet."""
    if not doc:
        configured_bucket = any((parent / 'fleet-control.json').exists() for parent in [Path.cwd(), *list(Path.cwd().parents)[:3]])
        if manifest or configured_bucket or os.environ.get('HIMMEL_CONSOLE_LEG') == '1' or os.environ.get('WORKER_SESSION_PROFILE'):
            raise Refused('managed launch missing doc locator')
        return None
    original = Path(doc).absolute()
    if original.is_symlink() and any((parent / 'fleet-control.json').exists() for parent in (original.parent, original.resolve().parent)):
        raise Refused('aliased managed doc locator')
    doc = str(Path(doc).resolve())
    bucket = Path(doc).parent
    paths = sorted(bucket.glob('*.fleet.json'))
    managed = (bucket / 'fleet-control.json').exists()
    candidates = []
    for path in paths:
        data = read(path)
        rows = data.get('workers', data.get('legs', []))
        if any(row.get('doc') == doc for row in rows):
            managed = True
            candidates.append(path)
    if manifest:
        path = Path(manifest).absolute()
        if path.parent.resolve() != bucket or path.is_symlink():
            raise Refused('conflicting manifest locator')
        managed = True
        candidates.insert(0, path)
    if not managed:
        try:
            managed = bool(re.search(r'^> \*\*Chief:\*\*', Path(doc).read_text(), re.M))
        except FileNotFoundError:
            pass
    if not managed:
        return None
    if not candidates:
        candidates = paths
    if not candidates:
        raise Refused('managed bucket has no worker manifest reference')
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
               cause=record.get('cause', 'runtime'), phase='runtime')
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
            raise Refused('owner family mismatch')
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
                terminal_docs[row['doc']] = row.get('outcome')
        rows = [row for row in rows if row['doc'] in current or row.get('registration') != 'pending'
                or terminal_docs.get(row['doc']) not in ('refused', 'complete')]
    return rows


def protected(doc):
    anchor = Path(doc).resolve().parent / 'fleet-control.json'
    if not anchor.exists():
        return any(row.get('doc') == str(Path(doc).resolve()) and row.get('attempt', {}).get('phase') in ('pending', 'committed', 'unknown')
                   for path in anchor.parent.glob('*.fleet.json') for row in read(path).get('workers', []))
    return any(r.get('doc') == str(Path(doc).resolve()) and r.get('phase') in ('pending', 'committed', 'unknown')
               for r in read(anchor).get('attempts', {}).values())


def disposition(doc):
    doc = str(Path(doc).resolve())
    anchor = Path(doc).parent / 'fleet-control.json'
    if anchor.exists():
        for record in read(anchor).get('attempts', {}).values():
            if record.get('doc') == doc:
                return record.get('phase', 'unknown')
        legacy = [row for path in anchor.parent.glob('*.fleet.json') for row in read(path).get('workers', [])
                  if row.get('doc') == doc and row.get('registration') != 'pending']
        if not legacy:
            history = receipts(set(), {doc})
            matching = [row for row in history.values() if row.get('doc') == doc]
            if matching and matching[-1].get('outcome') in ('refused', 'complete'):
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


def session_evidence(record, deadline):
    local = identity(os.getpid())
    if any(record['owner'][key] != local[key] for key in ('host', 'boot')):
        return None
    for path in Path('/proc').iterdir():
        if time.monotonic() >= deadline:
            return None
        if not path.name.isdigit():
            continue
        try:
            if (path / 'comm').read_text().strip() != 'claude':
                continue
            args = (path / 'cmdline').read_bytes().split(b'\0')
            if not any(a == b'-n' and i + 1 < len(args) and args[i + 1].decode() == record['name'] for i, a in enumerate(args)):
                continue
            env = dict(pair.split(b'=', 1) for pair in (path / 'environ').read_bytes().split(b'\0') if b'=' in pair)
            if env.get(b'WORKER_SESSION_DOC') != record['doc'].encode() or env.get(b'WORKER_SESSION_ATTEMPT_ID') != record['attempt_id'].encode():
                continue
            found = identity(int(path.name))
            if int(found['start']) >= record['began_ticks']:
                return found
        except (OSError, ValueError, UnicodeError):
            continue  # a disappearing or unreadable candidate proves no session
    return None


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
        owner = caller(args.pid)
        terminal = receipts({args.attempt_id}).get(args.attempt_id, {})
        if terminal.get('outcome') not in ('refused', 'complete'):
            raise Refused('reservation has no definite terminal receipt')
        slots = Path(os.environ.get('HIMMEL_FLEET_SLOTS', str(Path(os.environ.get('XDG_RUNTIME_DIR', '/tmp')) / ('himmel-fleet-' + str(os.getuid())))))
        if slots.exists():
            for slot in slots.iterdir():
                slot_marker = slot / 'managed.json'
                if slot_marker.is_file():
                    value = read(slot_marker)
                    if value == {'attempt_id': args.attempt_id, 'owner': owner}:
                        shutil.rmtree(slot)
        return {'released': args.attempt_id}
    if args.op == 'stamp':
        argv = Path('/proc', str(os.getppid()), 'cmdline').read_bytes().split(b'\0')
        if len(argv) < 2 or Path(os.fsdecode(argv[1])).resolve() != LIB / 'usage-preflight.sh':
            raise Refused('only the real resource preflight stamps admission')
        owner = caller(args.pid)
        publish(Path(args.slot) / 'managed.json', {'attempt_id': args.attempt_id, 'owner': owner})
        return {'stamped': args.attempt_id}
    manifest = Path(args.manifest).absolute() if args.op in ('ack', 'reconcile') and args.manifest else resolve(args.doc, args.manifest)
    if manifest is None:
        return {'managed': False}
    anchor = manifest.parent / 'fleet-control.json'
    if args.op in ('resolve', 'check'):
        value = snapshot(manifest)
        if args.op == 'check' and value['mode'] != 'active':
            raise Refused('fleet-paused')
        return dict(value, managed=True, manifest=str(manifest))
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
                if peer.get('control') == data.get('control'):
                    peer_rows.extend(peer.get('workers', peer.get('legs', [])))
        history = receipts(set(attempts) | {args.attempt_id} | {row.get('attempt', {}).get('attempt_id') for row in peer_rows})
        if args.op in ('ack', 'reconcile'):
            deadline = time.monotonic() + 5
            for aid, record in list(attempts.items()):
                row = history.get(aid, {})
                if row.get('name') == record['name'] and row.get('outcome') in ('refused', 'complete'):
                    del attempts[aid]
                    rows[:] = [w for w in rows if not (w.get('doc') == record['doc'] and w.get('attempt', {}).get('attempt_id') == aid)]
                elif row.get('name') == record['name'] and row.get('outcome') == 'launched':
                    record['phase'] = 'launched'
                elif not live(record['owner']) and record['phase'] != 'launched':
                    record['phase'] = 'unknown'
                if record.get('phase') == 'unknown' and time.monotonic() < deadline:
                    session = session_evidence(record, min(deadline, time.monotonic() + 1))
                    if session:
                        record['session'], record['phase'] = session, 'launched'
                        receipt(record, 'launched')
                if record.get('phase') == 'launched' and marker(record['doc']) != record.get('initial_marker') and time.monotonic() < deadline and worker_state(record['doc'], max(.01, deadline - time.monotonic())) == 'wrapped':
                    receipt(record, 'complete')
                    attempts.pop(aid, None)
            publish(anchor, control)
            publish(manifest, data)
            inflight = [r for r in attempts.values() if r['phase'] in ('pending', 'committed')]
            unknown = [r for r in attempts.values() if r['phase'] == 'unknown']
            legacy = {}
            current_docs = {record['doc'] for record in attempts.values()}
            for row in peer_rows:
                if row['doc'] in current_docs or (row.get('registration') == 'pending' and not row.get('attempt')):
                    continue
                if row.get('registration') == 'pending' and history.get(row.get('attempt', {}).get('attempt_id'), {}).get('outcome') in ('refused', 'complete'):
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
            if args.phase == 'launched' and record['phase'] == 'pending':
                raise Refused('launched receipt has no spawn commitment')
            if args.phase == 'refused' and record['phase'] != 'pending':
                raise Refused('committed attempt needs affirmative terminal evidence')
            if args.phase == 'refused':
                record['cause'] = 'fleet-paused' if value['mode'] != 'active' or value['generation'] != record['control_generation'] else 'prelaunch-refused'
            outcome = {'unknown': 'indeterminate', 'launched': 'launched', 'refused': 'refused', 'complete': 'complete'}[args.phase]
            receipt(record, outcome)
            if args.phase in ('refused', 'complete'):
                del attempts[args.attempt_id]
                rows[:] = [w for w in rows if not (w.get('doc') == doc and w.get('attempt', {}).get('attempt_id') == args.attempt_id)]
            else:
                record['phase'] = args.phase
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
            proc = subprocess.Popen(command, env=dict(os.environ, WORKER_SESSION_DOC=args.doc,
                                                     WORKER_SESSION_ATTEMPT_ID=args.attempt_id))
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
