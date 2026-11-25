"""Bounded Monitor transport for the one-shot waiter."""
import contextlib
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
HOST = socket.gethostname()
BOOT = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
VALUE_OPTIONS = {'--doc', '--token', '--workers', '--workers-from', '--handover-dir',
                 '--repo', '--ready-dir', '--prior', '--succession', '--silent-min', '--since',
                 '--ack', '--receipt'}


def read(path):
    try:
        return Path(path).read_text()
    except (FileNotFoundError, ProcessLookupError):
        return ''


def atomic(path, data):
    path = Path(path)
    tmp = path.with_name(path.name + '.tmp-' + str(os.getpid()))
    with tmp.open('w') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def identity(pid):
    try:
        fields = Path(f'/proc/{int(pid)}/stat').read_text().rsplit(')', 1)[1].split()
        return '' if fields[0] == 'Z' else fields[19]
    except (OSError, ValueError, IndexError):
        return ''


def alive(pid, start, host=HOST, boot=BOOT):
    return host == HOST and boot == BOOT and bool(start) and identity(pid) == str(start)


def clock(real=time.time):
    path = os.getenv('CHIEF_WAIT_STREAM_TEST_CLOCK') if os.getenv('HIMMEL_TEST_FIXTURE') == '1' else None
    return float(Path(path).read_text()) if path else real()


class BadSetting(ValueError):
    pass


MONITOR_ARM_SEC, BASH_ARM_SEC, STOP_WAIT_SEC = 1800, 7200, 60
LIMITS = {
    'CHIEF_WAIT_STREAM_SOFT_SEC': (1440, MONITOR_ARM_SEC - STOP_WAIT_SEC),
    'CHIEF_WAIT_STREAM_HARD_SEC': (1680, MONITOR_ARM_SEC),
    'CHIEF_WAIT_STREAM_BUSY_MAX_SEC': (7200, BASH_ARM_SEC),
    'CHIEF_WAIT_STREAM_REAP_MAX_SEC': (1800, MONITOR_ARM_SEC),
    'CHIEF_WAIT_STREAM_ADOPT_SEC': (300, MONITOR_ARM_SEC),
    'CHIEF_WAIT_STREAM_KILL_GRACE_SEC': (10, STOP_WAIT_SEC),
    'CHIEF_WAIT_STREAM_REPEAT_SEC': (60, MONITOR_ARM_SEC),
}


def bound(name):
    default, longest = LIMITS[name]
    raw = os.getenv(name)
    if raw is None:
        return float(default)
    try:
        value = float(raw)
    except ValueError:
        value = 0.0
    if not 0 < value <= longest:
        raise BadSetting(f'bad-setting {name}={raw!r} (allowed: a number above 0 and at most {longest})')
    return value


def watchdog_life():
    return (LIMITS['CHIEF_WAIT_STREAM_HARD_SEC'][1]
            + max(LIMITS['CHIEF_WAIT_STREAM_ADOPT_SEC'][1], LIMITS['CHIEF_WAIT_STREAM_REAP_MAX_SEC'][1])
            + LIMITS['CHIEF_WAIT_STREAM_KILL_GRACE_SEC'][1])


def check_limits():
    for name in LIMITS:
        bound(name)
    soft, hard = 'CHIEF_WAIT_STREAM_SOFT_SEC', 'CHIEF_WAIT_STREAM_HARD_SEC'
    if bound(soft) >= bound(hard):
        shown = {name: os.getenv(name, str(LIMITS[name][0])) for name in (soft, hard)}
        raise BadSetting(f'bad-setting {soft}={shown[soft]!r} (must be below {hard}={shown[hard]!r})')


@contextlib.contextmanager
def flocked(path):
    with open(path, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def ownership(inbox):
    return flocked(inbox + '.wait.stream.own')


def acks(inbox):
    return flocked(inbox + '.wait.ack.lock')


def load(path):
    return dict(item.split('=', 1) for item in read(path).split() if '=' in item)


def wake_rows(path):
    rows = [line.split('\t') for line in read(path).splitlines()]
    for row in rows:
        if row[0] == 'W' and (len(row) < 6 or not row[1].isdecimal() or
                              not row[2].isdecimal() or not row[3].isdecimal() or not row[5]):
            raise ValueError('malformed W row; reconcile ' + str(path))
    return rows


def child_alive(data, inbox):
    if not alive(data.get('child', 0), data.get('child_start', ''),
                 data.get('host', ''), data.get('boot', '')):
        return False
    try:
        cmd = Path(f"/proc/{data['child']}/cmdline").read_bytes().split(b'\0')
        return os.fsencode(inbox) in cmd and any(b'chief-wait' in a for a in cmd)
    except OSError:
        return False


def safe_point(data, inbox):
    pid = data.get('child', '0')
    if not child_alive(data, inbox):
        return ''
    hb = load(inbox + '.wait')
    if hb.get('pid') != str(pid) or hb.get('state') != 'waiting':
        return ''
    children = read(f'/proc/{pid}/task/{pid}/children').split()
    for child in children:
        if read(f'/proc/{child}/comm').strip() == 'sleep':
            return child
    return ''


def terminate(data, inbox, hard=False):
    if not child_alive(data, inbox):
        return
    pid = int(data['child'])
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    if hard:
        end = time.monotonic() + bound('CHIEF_WAIT_STREAM_KILL_GRACE_SEC')
        while child_alive(data, inbox) and time.monotonic() < end:
            time.sleep(.05)
        if child_alive(data, inbox):
            # Signal only the recorded leader of its own process group.
            try:
                if os.getpgid(pid) == pid:
                    os.killpg(pid, signal.SIGKILL)
                else:
                    os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def release(path, requested):
    if requested and read(path).strip() == requested:
        Path(path).unlink(missing_ok=True)


def watchdog(inbox, sup, start):
    adopt = bound('CHIEF_WAIT_STREAM_ADOPT_SEC')
    busy = bound('CHIEF_WAIT_STREAM_BUSY_MAX_SEC')
    reap_max = bound('CHIEF_WAIT_STREAM_REAP_MAX_SEC')
    bound('CHIEF_WAIT_STREAM_KILL_GRACE_SEC')
    life = watchdog_life()
    born = time.monotonic()
    side = inbox + '.wait.stream'
    reap = inbox + '.wait.reap'
    requested = ''
    dead_since = None
    last_sleep = ''
    last_safe = None
    while True:  # t13b-ok: ends the child and itself at its own age (the longest HARD, then the longer of the longest adoption and reap windows, then the longest kill grace: 3660 s, monotonic clock), whatever its supervisor does; earlier, once its supervisor process is gone, when a successor supervisor is alive, when its child is gone, or when the child honours its reap request at a safe point (requested at once, or CHIEF_WAIT_STREAM_ADOPT_SEC, 300 s default, after a hand-off), and it ends the child after CHIEF_WAIT_STREAM_BUSY_MAX_SEC (7200 s default) without a safe point or CHIEF_WAIT_STREAM_REAP_MAX_SEC (1800 s default) after the supervisor went, then up to CHIEF_WAIT_STREAM_KILL_GRACE_SEC (10 s default) more; a setting outside its range refuses the start
        data = load(side)
        expired = time.monotonic() - born >= life
        if alive(sup, start) and not expired:
            time.sleep(.2)
            continue
        if alive(data.get('sup', 0), data.get('sup_start', ''),
                 data.get('host', ''), data.get('boot', '')) and str(data.get('sup')) != str(sup):
            release(reap, requested)
            return 0
        if not child_alive(data, inbox):
            release(reap, requested)
            return 0
        now = time.monotonic()
        dead_since = dead_since or now
        sleep = safe_point(data, inbox)
        if sleep and sleep != last_sleep:
            last_safe, last_sleep = now, sleep
        safe = last_safe or float(data['safe'])
        age = now - safe
        handoff = data.get('handoff', '-')
        deadline = (float(handoff) + adopt
                    if handoff != '-' else dead_since)
        if now >= deadline and not requested and not expired:
            with ownership(inbox):
                current = load(side)
                if current.get('sup') != data.get('sup'):
                    continue
                requested = f"pid={data['child']}"
                atomic(reap, requested + '\n')
        if expired or age >= busy or now - dead_since >= reap_max:
            with ownership(inbox):
                current = load(side)
                if current.get('sup') != data.get('sup'):
                    continue
                terminate(data, inbox, hard=True)
            release(reap, requested)
            atomic(inbox + '.wait.stream.hung',
                   f"pid={data['child']} age={int(age)} part={data['part']} epoch={int(time.time())}\n")
            return 0
        time.sleep(.1)


def parse(args):
    flags, pairs, child = set(), {}, []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in VALUE_OPTIONS:
            if i + 1 == len(args):
                raise ValueError('missing-value')
            pairs[arg] = args[i + 1]
            if arg != '--since':
                child.extend(args[i:i + 2])
            i += 2
        else:
            flags.add(arg)
            if arg != '--stream':
                child.append(arg)
            i += 1
    return flags, pairs, child


class Supervisor:
    def __init__(self, inbox, args):
        self.inbox = inbox
        self.flags, self.pairs, self.args = parse(args)
        self.base = inbox + '.wait.'
        self.side = self.base + 'stream'
        self.log = self.base + 'wakes'
        self.data = {}
        self.proc = None
        self.adopted = False
        self.launches = 0
        self.lines = []
        self.wakes = 0
        self.seq = 0
        self.printed = 0
        self.last_sig = ''
        self.last_wake = 0
        self.stop_started = None
        self.reason = ''
        self.last_sleep = ''
        self.started = clock()
        self.began = clock(time.monotonic)
        self.arm = time.time_ns()
        self.owned = False
        self.dog = None
        self.ack_faults = set()
        self.args_hash = hashlib.sha256(repr(self.args).encode()).hexdigest()[:16]

    def path(self, name):
        return Path(self.base + name)

    def append(self, *items):
        with open(self.log, 'a') as f:
            f.write('\t'.join(map(str, items)) + '\n')
            f.flush()
            os.fsync(f.fileno())

    def publish(self):
        self.data.update(sup=os.getpid(), sup_start=identity(os.getpid()), host=HOST, boot=BOOT,
                         dog=self.dog.pid if self.dog else 0, seq=self.seq, arm=self.arm, args=self.args_hash,
                         started=self.started)
        with ownership(self.inbox):
            atomic(self.side, ' '.join(f'{k}={v}' for k, v in self.data.items()) + '\n')

    def emit(self, line):
        print(line, flush=True)
        self.lines.append(clock(time.monotonic))

    def record(self, part, adopted=False, emit=True):
        text = read(part)
        first = next((s for s in text.splitlines() if s.startswith('WAKE ')), '')
        if not first:
            if text:
                print(f'discard non-wake part {part}: {text}', file=sys.stderr)
            Path(part).unlink(missing_ok=True)
            return False
        self.seq += 1
        block = str(self.path(f'wake-{self.seq}'))
        with open(part, 'rb') as pending:
            os.fsync(pending.fileno())
        os.replace(part, block)
        directory = os.open(Path(block).parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        self.append('W', self.seq, int(time.time()), self.arm, first.split()[1], block,
                    *(['adopted'] if adopted else []))
        self.wakes += 1
        self.publish()
        if emit:
            self.emit(f'WAKE#{self.seq} {first[5:205]} out={block}')
            self.append('P', self.seq, int(time.time()), self.arm)
            self.printed = self.seq
            body = text.split('absorbed since last wake:')[0].split('look-only since last wake:')[0]
            sig = hashlib.sha256(body.encode()).hexdigest()
            now = clock(time.monotonic)
            repeat_sec = bound('CHIEF_WAIT_STREAM_REPEAT_SEC')
            if sig == self.last_sig and now - self.last_wake < repeat_sec:
                self.reason = 'repeat'
            self.last_sig, self.last_wake = sig, now
        if first.startswith('WAKE succession '):
            self.args = [v for pair in self.argument_pairs() if pair[0] not in ('--succession', '--silent-min') for v in pair]
        return True

    def argument_pairs(self):
        i = 0
        while i < len(self.args):
            size = 2 if self.args[i] in VALUE_OPTIONS else 1
            yield self.args[i:i + size]
            i += size

    def error(self, text):
        self.seq += 1
        block = str(self.path(f'wake-{self.seq}'))
        atomic(block, 'WAKE waiter-error ' + text + '\n')
        self.append('W', self.seq, int(time.time()), self.arm, 'waiter-error', block)
        self.publish()
        self.emit(f'WAKE#{self.seq} waiter-error {text} out={block}')
        self.append('P', self.seq, int(time.time()), self.arm)
        self.printed = self.seq

    def signal_stop(self, signum, frame):
        # Catchable standalone signals also leave an owned, bounded child.
        if self.adopted:
            terminate(self.data, self.inbox)
        raise SystemExit(0)

    def prepare(self):
        if '--workers' in self.pairs:
            return self.refuse('workers', 2)
        if not (self.pairs.get('--workers-from') or os.getenv('WORKERS_FROM')):
            return self.refuse('no-workers-from', 2)
        if os.getenv('CHIEF_WAIT_STREAM_STDOUT_OK') != '1' and not stat.S_ISSOCK(os.fstat(1).st_mode):
            return self.refuse('not-monitor', 2)
        if any(c.isspace() for c in self.inbox):
            return self.refuse('inbox-whitespace', 2)
        since = self.pairs.get('--since', 'prev-arm')
        if since != 'prev-arm' and not since.isdecimal():
            return self.refuse('since', 2)
        try:
            check_limits()
        except BadSetting as exc:
            return self.refuse(str(exc), 2)
        self.lock = open(self.base + 'stream.lock', 'a')
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            try:
                owner = load(self.side).get('sup', '?')
            except OSError:
                owner = '?'
            return self.refuse('live-supervisor pid=' + owner, 3)
        self.owned = True
        stderr = open(self.base + 'stream.log', 'a')
        os.dup2(stderr.fileno(), 2)
        self.data = load(self.side)
        self.seq = int(self.data.get('seq', 0))
        rows = wake_rows(self.log)
        self.seq = max([self.seq, *[int(r[1]) for r in rows if r[0] == 'W']])
        previous = next((r for r in reversed(rows) if r[0] == 'A'), None)
        since = int(previous[5]) if since == 'prev-arm' and previous else (0 if since == 'prev-arm' else int(since))
        self.seq = max(since, self.seq)
        self.printed = since
        self.args_hash = hashlib.sha256(repr(self.args).encode()).hexdigest()[:16]
        self.old_hash = self.data.get('args')
        self.adopted = child_alive(self.data, self.inbox)
        carried = not self.adopted and self.honoured(self.data.get('child'))
        if not self.adopted:
            self.data.update(child=0, child_start='')
        # close_fds prevents child/watchdog inheritance of the supervisor flock.
        self.dog = subprocess.Popen([sys.executable, '-I', str(Path(__file__)), '--watchdog',
                                     self.inbox, str(os.getpid()), identity(os.getpid())],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=stderr, start_new_session=True, close_fds=True)
        self.data['handoff'] = '-'
        self.publish()
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(sig, self.signal_stop)
        self.path('reap').unlink(missing_ok=True)
        stop = self.path('stop')
        if stop.exists() and stop.stat().st_mtime < self.started and not carried:
            stop.unlink()
        live_part = self.data.get('part') if self.adopted else None
        known = {r[5] for r in rows if r[0] == 'W'}
        # Recover rename-before-log crashes as well as completed child parts.
        orphan_blocks = [p for p in self.path('stream').parent.glob(Path(self.base).name + 'wake-*')
                         if p.name.rsplit('-', 1)[-1].isdecimal() and int(p.name.rsplit('-', 1)[-1]) > self.seq]
        for part in sorted(orphan_blocks, key=lambda p: int(p.name.rsplit('-', 1)[-1])) + sorted(self.path('stream').parent.glob(Path(self.base).name + 'part-*')):
            if str(part) != live_part and str(part) not in known:
                self.record(str(part), adopted=True, emit=False)
        rows = wake_rows(self.log)
        wakes = [r for r in rows if r[0] == 'W']
        keep = max(1, int(os.getenv('CHIEF_WAIT_STREAM_KEEP', '200')))
        retained = wakes[-keep:]
        if len(wakes) > keep:
            with acks(self.inbox):
                asked = {p.name[len(Path(self.base).name + 'ack-'):-len('.json')]
                         for p in self.path('stream').parent.glob(Path(self.base).name + 'ack-*.json')}
                kept = [r for r in wakes[:-keep] if r[1] in asked] + retained
                seqs = {r[1] for r in kept}
                arms = {r[3] for r in retained}
                newest = next((r[1] for r in reversed(rows) if r[0] == 'A'), '')
                rows = [r for r in rows if (r in kept or r[0] in ('D', 'K') and r[1] in seqs or
                                            r[0] == 'A' and (r[1] in arms or r[1] == newest))]
                atomic(self.log, ''.join('\t'.join(r) + '\n' for r in rows))
                for r in wakes:
                    if r not in kept:
                        Path(r[5]).unlink(missing_ok=True)
        oldest = int(retained[0][1]) if retained else 0
        if oldest and since < oldest - 1:
            self.emit(f'GAP since={since} oldest={oldest}')
            self.append('G', since, oldest, int(time.time()), self.arm)
        elif not wakes and since:
            self.emit(f'GAP since={since} log=reset')
            self.append('G', since, 'reset', int(time.time()), self.arm)
        replay = [r for r in retained if int(r[1]) > since]
        if replay:
            index = str(self.path(f'replay-{self.arm}'))
            atomic(index, ''.join('\t'.join(r) + '\n' for r in replay))
            self.emit(f'REPLAY seqs={replay[0][1]}-{replay[-1][1]} n={len(replay)} index={index}')
            self.printed = max(self.printed, int(replay[-1][1]))
            self.append('R', replay[0][1] + '-' + replay[-1][1], int(time.time()), self.arm)
        # The current arm and its predecessor keep their advertised indexes.
        # A new arm supersedes older indexes; retained W rows remain replayable.
        indexes = sorted(self.path('stream').parent.glob(Path(self.base).name + 'replay-*'),
                         key=lambda p: int(p.name.rsplit('-', 1)[-1]))
        for obsolete in indexes[:-2]:
            obsolete.unlink(missing_ok=True)
        self.append('A', self.arm, int(time.time()), since, os.getpid(), self.seq)
        hung = load(self.base + 'stream.hung')
        if hung:
            self.error(f"kind=hung pid={hung['pid']} age={hung['age']}")
            self.path('stream.hung').unlink()
            return 1
        return None

    @staticmethod
    def refuse(reason, code):
        line = 'STREAM-REFUSED ' + reason
        print(line, flush=True)
        print(line, file=sys.stderr, flush=True)
        return code

    def launch(self):
        self.launches += 1
        part = str(self.path(f'part-{self.arm}-{self.launches}'))
        env = dict(os.environ, CHIEF_WAIT_STREAM_SERVICE='1')
        env.setdefault('CHIEF_WAIT_POLL_SEC', '0.2')
        gate = 'read -r _ || exit 1; exec bash "$@" </dev/null'
        with open(part, 'a') as out:
            self.proc = subprocess.Popen(['bash', '-c', gate, 'chief-wait-gate',
                                          os.getenv('CHIEF_WAIT_STREAM_CHILD', str(HERE / 'chief-wait.sh')),
                                          self.inbox, *self.args], stdin=subprocess.PIPE,
                                         stdout=out, stderr=out, env=env, start_new_session=True, close_fds=True)
        self.adopted = False
        self.data.update(child=self.proc.pid, child_start=identity(self.proc.pid), part=part,
                         safe=clock(time.monotonic), handoff='-')
        self.publish()
        try:
            self.proc.stdin.write(b'go\n')
            self.proc.stdin.close()
        except BrokenPipeError:
            pass

    def run(self):
        result = self.prepare()
        if result is not None:
            return result
        soft = float(os.getenv('CHIEF_WAIT_STREAM_SOFT_SEC', '1440'))
        hard = float(os.getenv('CHIEF_WAIT_STREAM_HARD_SEC', '1680'))
        while True:  # t13b-ok: ends at the first pass after CHIEF_WAIT_STREAM_HARD_SEC (1680 s default, 1800 s at most, monotonic clock) or 60 s after a stop request, checked on every pass; earlier once the child is gone and CHIEF_WAIT_STREAM_SOFT_SEC (1440 s default, below HARD) has passed or a stop request or a recorded reason (repeat, rate limit) is set, or on a refusal or an error (a child busy past CHIEF_WAIT_STREAM_BUSY_MAX_SEC, 7200 s at most, is an error); a setting outside its range refuses the start
            self.acknowledge()
            now = clock(time.monotonic)
            self.lines = [t for t in self.lines if clock(time.monotonic) - t < 60]
            if len(self.lines) >= int(os.getenv('CHIEF_WAIT_STREAM_MAX_PER_MIN', '6')):
                self.reason = self.reason or 'rate'
            if self.path('stop').exists():
                self.stop_started = self.stop_started or now
            ending = self.reason or now - self.began >= soft or self.stop_started is not None
            live = child_alive(self.data, self.inbox)
            if self.proc is not None and self.proc.poll() is None:
                live = True
            if (self.stop_started is not None and now - self.stop_started >= 60) or now - self.began >= hard:
                return self.finish(live)
            if not live and self.data.get('part'):
                rc = self.proc.wait() if self.proc else self.adopted_rc()
                if self.honoured(self.data.get('child')):
                    self.stop_started = self.stop_started or now
                self.record(self.data['part'], self.adopted)
                self.data.pop('part', None)
                self.data['child'] = 0
                self.path('reap').unlink(missing_ok=True)
                self.proc = None
                self.publish()
                if rc == 3:
                    return self.refuse('live-waiter', 3)
                if rc not in (0, 143):
                    self.error(f'rc={rc}')
                    return rc if rc in (1, 2) else 1
                continue
            if ending and not live:
                return self.finish(False)
            if not live:
                self.launch()
                time.sleep(.05)
                continue
            sleep = safe_point(self.data, self.inbox)
            if sleep and sleep != self.last_sleep:
                self.last_sleep = sleep
                self.data['safe'] = now
                self.publish()
            if sleep and (ending or self.adopted and self.old_hash != self.args_hash):
                terminate(self.data, self.inbox)
            age = now - float(self.data['safe'])
            if age >= bound('CHIEF_WAIT_STREAM_BUSY_MAX_SEC'):
                terminate(self.data, self.inbox, hard=True)
                self.record(self.data['part'], self.adopted)
                self.error(f"kind=hung pid={self.data['child']} age={int(age)}")
                return 1
            time.sleep(.1)

    def acknowledge(self):
        rows = wake_rows(self.log)
        wakes = {r[1]: r[5] for r in rows if r[0] == 'W'}
        kinds = {r[1]: r[4] for r in rows if r[0] == 'W'}
        delivered = {r[1] for r in rows if r[0] == 'D'}
        known = {r[1] for r in rows if r[0] == 'K'}
        for request in sorted(self.path('stream').parent.glob(Path(self.base).name + 'ack-*.json')):
            retry_path = Path(str(request) + '.retry')
            diagnostic = Path(str(request) + '.error')
            retry = {}
            retry_valid = False
            try:
                retry = json.loads(read(retry_path) or '{}')
                if (not isinstance(retry, dict) or type(retry.get('attempts', 0)) is not int or
                        not 0 <= retry.get('attempts', 0) <= 7 or
                        type(retry.get('next', 0)) not in (int, float) or
                        not 0 <= retry.get('next', 0) < float('inf')):
                    raise ValueError('invalid retry state')
                retry_valid = True
                if time.time() < retry.get('next', 0):
                    continue
                attempts = min(retry.get('attempts', 0) + 1, 7)
                retry.update(attempts=attempts, next=time.time() + min(1800, 30 * 2 ** (attempts - 1)))
                # Persist the bound before invoking a helper, including crash/restart.
                atomic(retry_path, json.dumps(retry))
                ack = json.loads(request.read_text())
                seq, receipt_id = str(ack['seq']), ack['receipt']
                if not seq.isdecimal() or not isinstance(receipt_id, str) or not re.fullmatch(r'[A-Za-z0-9._:-]{1,200}', receipt_id):
                    raise ValueError('invalid acknowledgement')
                if seq in known:
                    request.unlink()
                    retry_path.unlink(missing_ok=True)
                    continue
                if seq not in wakes:
                    raise ValueError('wake no longer retained; reconcile owed ledger')
                if seq not in delivered:
                    self.append('D', seq, int(time.time()), receipt_id)
                    delivered.add(seq)
                text = read(wakes[seq])
                if not re.search(r'^WAKE ' + re.escape(kinds[seq]) + r'(?: |$)', text, re.M):
                    raise ValueError('wake block missing or not of its kind; reconcile owed ledger')
                ids = re.search(r'^WAKE owed-actions chief-notify=([^\n]+)', text, re.M)
                bucket = re.search(r'^owed-bucket=(.+)$', text, re.M)
                if kinds[seq] == 'owed-actions':
                    if not (ids and bucket):
                        raise ValueError('owed wake block cut before its notify list or bucket; reconcile owed ledger')
                    result = subprocess.run(['bash', str(HERE / 'owe.sh'), 'list', '--all', '--json',
                                             '--bucket', bucket[1]], capture_output=True, text=True, timeout=10)
                    if result.returncode:
                        raise ValueError('owed list failed')
                    actions = {row['id']: row for row in json.loads(result.stdout)}
                    for item in ids[1].split(','):
                        if item == 'none':
                            continue
                        action = actions.get(item, {})
                        if not (action.get('actor') == 'chief' and action.get('action') == 'notify'):
                            raise ValueError('missing/non-notify owed id=' + item)
                        if action.get('closed'):
                            continue
                        result = subprocess.run(['bash', str(HERE / 'owe.sh'), 'close', '--bucket', bucket[1],
                                                 '--id', item, '--key', receipt_id], capture_output=True, timeout=10)
                        if result.returncode:
                            raise ValueError('owed close failed id=' + item)
                self.append('K', seq, int(time.time()), receipt_id)
                request.unlink()
                retry_path.unlink(missing_ok=True)
                diagnostic.unlink(missing_ok=True)
                self.ack_faults.discard(str(request))
            except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as exc:
                # Preserve corrupt bytes for reconciliation; even a diagnostic
                # write failure is local to this ack, never the whole arm.
                if str(request) not in self.ack_faults:
                    self.ack_faults.add(str(request))
                    try:
                        reported = diagnostic.exists()
                        if not reported:
                            atomic(diagnostic, f'{type(exc).__name__}:{exc}\n')
                    except OSError:
                        reported = False
                    if not reported:
                        due = int(retry['next']) if retry_valid and 'next' in retry else 'repair-sidecar'
                        self.error(f'kind=ack-stuck request={request} retry-at={due} reconcile={type(exc).__name__}:{exc}')

    def adopted_rc(self):
        hb = load(self.inbox + '.wait')
        if hb.get('pid') != str(self.data.get('child')) or 'exit' not in hb:
            return 143
        reason = hb['exit']
        if reason.startswith('wake-'):
            return 0
        return {'signal-TERM': 143, 'stream-stop': 143, 'stream-reap': 143, 'signal-INT': 130, 'signal-HUP': 129}.get(reason, 1)

    def honoured(self, child):
        hb, child = load(self.inbox + '.wait'), str(child or 0)
        return child != '0' and hb.get('pid') == child and hb.get('exit') == 'stream-stop'

    def finish(self, busy):
        if busy and self.stop_started is None and self.honoured(self.data.get('child')):
            self.stop_started, busy = time.time(), False
            self.data['child'] = 0
        stopped = self.stop_started is not None
        self.data['handoff'] = clock(time.monotonic) if busy and not stopped else '-'
        self.publish()
        line = ('STOPPED' if stopped else 'REARM') + f' since={self.printed}'
        if not stopped:
            line += f' wakes={self.wakes}'
        if self.reason:
            line += ' reason=' + self.reason
        if busy:
            line += f" child=busy pid={self.data['child']}"
        self.emit(line)
        if stopped:
            self.path('stop').unlink(missing_ok=True)
        return 0


def main():
    if sys.argv[1:2] == ['--watchdog']:
        try:
            return watchdog(*sys.argv[2:])
        except BadSetting as exc:
            print('STREAM-REFUSED ' + str(exc), file=sys.stderr)
            return 2
    if sys.argv[1:2] == ['--ack']:
        inbox = sys.argv[2]
        _, pairs, _ = parse(sys.argv[3:])
        seq, receipt_id = pairs.get('--ack', ''), pairs.get('--receipt', '')
        if not seq.isdecimal() or not re.fullmatch(r'[A-Za-z0-9._:-]{1,200}', receipt_id):
            return Supervisor.refuse('ack-receipt', 2)
        with acks(inbox):
            rows = [line.split('\t') for line in read(inbox + '.wait.wakes').splitlines()]
            if not any(r[0] == 'W' and r[1] == seq for r in rows):
                return Supervisor.refuse('unknown-wake', 2)
            atomic(inbox + '.wait.ack-' + seq + '.json', json.dumps(dict(seq=seq, receipt=receipt_id)))
        print('ACK-RECORDED seq=' + seq)
        return 0
    if len(sys.argv) < 2:
        return 2
    try:
        supervisor = Supervisor(sys.argv[1], sys.argv[2:])
    except ValueError as exc:
        return Supervisor.refuse(str(exc), 2)
    try:
        return supervisor.run()
    except Exception as exc:
        if not supervisor.owned:
            if isinstance(exc, ValueError):
                return Supervisor.refuse(str(exc), 2)
            return Supervisor.refuse('before-lock ' + type(exc).__name__, 3)
        supervisor.reason = 'supervisor'
        try:
            fault_path = supervisor.path('supervisor-fault')
            fault = hashlib.sha256(f'{type(exc).__name__}:{exc}'.encode()).hexdigest()
            previous = load(fault_path)
            repeated = previous.get('fault') == fault and time.time() - float(previous.get('epoch', 0)) < 300
            atomic(fault_path, f'fault={fault} epoch={time.time()}\n')
            supervisor.error('kind=supervisor reconcile=' + type(exc).__name__ + ':' + str(exc).replace('\n', ' ')[:200])
            if repeated:
                supervisor.stop_started = time.time()
                supervisor.reason = 'supervisor-repeat'
            supervisor.finish(child_alive(supervisor.data, supervisor.inbox))
        except Exception as report_error:
            # Without persisted fault state a retry cannot be bounded safely.
            # Existing watchdog ownership checks remain responsible for the child.
            supervisor.emit('WAKE waiter-error kind=supervisor state-unwritable=' + type(report_error).__name__)
            supervisor.emit(f'STOPPED since={supervisor.printed} reason=supervisor-state-unwritable reconcile={supervisor.base}')
        return 1


if __name__ == '__main__':
    sys.exit(main())
