"""Exercise the real supervisor/child/control routes using offline dependencies."""
import fcntl
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent

SCHEDULE_DRIVER = '''
import importlib.util, os, sys, time
from pathlib import Path

spec = importlib.util.spec_from_file_location('chief_wait_stream', os.environ['STREAM_PY'])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
stop = Path(sys.argv[1] + '.wait.stop')
fired = Path(sys.argv[1] + '.wait.schedule-fired')
armed = []
acknowledge = mod.Supervisor.acknowledge
child_alive = mod.child_alive
publish = mod.Supervisor.publish


def after_one_wake(self):
    acknowledge(self)
    if not armed and self.wakes >= 1 and self.proc is not None and self.proc.poll() is None:
        armed.append(self)
        self.began -= float(os.environ['CHIEF_WAIT_STREAM_HARD_SEC']) + 1


def touched_after_the_sample(data, inbox):
    live = child_alive(data, inbox)
    if armed and not fired.exists():
        stop.touch()
        armed[0].proc.wait(timeout=30)
        fired.write_text(str(data['child']))
    return live


def honoured_during_adoption(self):
    publish(self)
    if self.adopted and not fired.exists():
        Path(os.environ['TICK_GATE']).touch()
        stop.touch()
        os.utime(stop, (1, 1))
        end = time.monotonic() + 30
        while mod.child_alive(self.data, self.inbox) and time.monotonic() < end:
            time.sleep(.02)
        fired.write_text(str(self.data['child']))


if os.environ['SCHEDULE'] == 'touched-after-the-sample':
    mod.Supervisor.acknowledge = after_one_wake
    mod.child_alive = touched_after_the_sample
else:
    mod.Supervisor.publish = honoured_during_adoption
sys.exit(mod.main())
'''

LAUNCH_WINDOW = r'''
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location('cws', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
point = sys.argv[2]
sup = m.Supervisor(sys.argv[3], sys.argv[4:])
real_identity, real_atomic, real_publish = m.identity, m.atomic, m.Supervisor.publish
stalled = []


def identity(pid):
    if sup.proc is not None and pid == sup.proc.pid:
        if point == 'identity':
            os._exit(137)
        if point == 'stall' and not stalled:
            stalled.append(1)
            time.sleep(2.5)
    return real_identity(pid)


def atomic(path, data):
    if point == 'publish' and str(path).endswith('.wait.stream') and sup.proc is not None and f'child={sup.proc.pid} ' in data:
        os._exit(137)
    return real_atomic(path, data)


def publish(self):
    real_publish(self)
    if point == 'after-publish' and self.proc is not None and self.data.get('child') == self.proc.pid:
        os._exit(137)


real_record = m.Supervisor.record


def record(self, part, adopted=False, emit=True):
    if point == 'record':
        os._exit(137)
    return real_record(self, part, adopted, emit)


m.identity, m.atomic, m.Supervisor.publish, m.Supervisor.record = identity, atomic, publish, record
sys.exit(sup.run())
'''

WATCHDOG_RACE = r'''
import importlib.util, json, os, subprocess, sys, threading, time
from pathlib import Path
spec = importlib.util.spec_from_file_location('cws', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
inbox, when = sys.argv[2], int(sys.argv[3])
side = inbox + '.wait.stream'
os.environ['CHIEF_WAIT_STREAM_ADOPT_SEC'] = '0.001'
child = subprocess.Popen(['bash', '-c', 'sleep 300; :', 'chief-wait-x', inbox], start_new_session=True)
start = m.identity(child.pid)
Path(inbox + '.wait').write_text(f'hb={int(time.time())} pid={child.pid} key=- tick=ok state=waiting\n')
dead = subprocess.Popen(['true'])
dead.wait()
part = inbox + '.wait.part-1-1'
Path(side).write_text(f'sup={dead.pid} sup_start=1 host={m.HOST} boot={m.BOOT} child={child.pid} child_start={start} '
                      f'part={part} safe={time.monotonic() - 5} handoff={time.monotonic() - 10} seq=0\n')
end = time.monotonic() + 5
while not m.safe_point(m.load(side), inbox) and time.monotonic() < end:
    time.sleep(.05)
adopter = m.Supervisor(inbox, ['--doc', 'x', '--workers-from', 'y'])
adopter.data = dict(child=child.pid, child_start=start, part=part, safe=time.monotonic(), handoff='-')
real_load, real_kill, real_atomic = m.load, os.kill, m.atomic
reads, publishers, kills, requests = [], [], [], []


def load(path):
    out = real_load(path)
    if path == side:
        reads.append(1)
        if len(reads) == when:
            thread = threading.Thread(target=adopter.publish)
            thread.start()
            thread.join(.5)
            publishers.append(thread)
    return out


def kill(pid, sig):
    kills.append(dict(pid=pid, owner=real_load(side).get('sup')))
    real_kill(pid, sig)


def atomic(path, data):
    if path == inbox + '.wait.reap':
        requests.append(dict(data=data.strip(), owner=real_load(side).get('sup')))
    return real_atomic(path, data)


m.load, os.kill, m.atomic = load, kill, atomic
rc = m.watchdog(inbox, str(dead.pid), '1')
for thread in publishers:
    thread.join(10)
print(json.dumps(dict(rc=rc, kills=kills, requests=requests, reap_left=Path(inbox + '.wait.reap').exists(),
                      dead=dead.pid, me=os.getpid(), owner=real_load(side).get('sup'),
                      child_running=child.poll() is None, publishers_done=not any(t.is_alive() for t in publishers))))
os.killpg(child.pid, 9)
'''

class StreamFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='wait-stream-')
        self.root = Path(self.tmp.name)
        (self.root / 'consoles').mkdir()
        (self.root / 'home').mkdir()
        self.inbox = self.root / 'consoles/chief.md'
        self.inbox.touch()
        Path(str(self.inbox) + '.announced').touch()
        self.fleet = self.root / 'fleet.json'
        self.fleet.write_text('{"workers":[]}')
        self.doc = self.root / 'chief.md'
        self.doc.write_text('# chief\n## Results\n')
        self.procs = []
        self.env = dict(os.environ, CR_ANCHOR_HANDOFF='0', CHIEF_WAIT_STREAM_STDOUT_OK='1',
                        CHIEF_WAIT_STREAM_SOFT_SEC='60', CHIEF_WAIT_STREAM_HARD_SEC='65',
                        CHIEF_WAIT_POLL_SEC='0.05', CHIEF_WAIT_INTERVAL='180',
                        CHIEF_WAIT_STREAM_ADOPT_SEC='2', CHIEF_WAIT_STREAM_REAP_MAX_SEC='3',
                        CHIEF_WAIT_STREAM_KILL_GRACE_SEC='0.2', HOUSEKEEPING_DIGEST_SECS='0',
                        CHIEF_WAIT_FAIL_WAKE='1000', WAIT_SWEEP_SEC='99999',
                        HIMMEL_FLAG_AUTO_GO=os.environ.get('T4_STREAM_AUTO_GO', '0'), HIMMEL_FLAG_SILENT_GO='0',
                        CHIEF_WAIT_OPERATOR_GRACE_SEC='.2',
                        HIMMEL_TEST_FIXTURE='1')
        self.script('usage', 'echo PROCEED\n')
        self.script('tick', 'echo call >> "$TEST_ROOT/ticks"\necho "TICK workers=0 livestate=0 prs=none tails=none acts=none workerset=0 board=ok tracker=ok denials=0 capacity=FULL"\n')
        self.script('off', 'exit 0\n')
        self.env.update(TEST_ROOT=str(self.root), CHIEF_WAIT_TICK=str(self.root / 'tick'),
                        HOME=str(self.root / 'home'),
                        BRIDGE_ROOT=str(self.root / 'home/.claude/handover/bridge'),
                        CHIEF_WAIT_USAGE=str(self.root / 'usage'),
                        CHIEF_WAIT_BUDGET=str(self.root / 'off'),
                        WAIT_SWEEP_CMD=str(self.root / 'off'), WAIT_FOCUS_CMD=str(self.root / 'off'),
                        CHIEF_WAIT_DISPATCH=str(self.root / 'absent'))
        self.env['CHIEF_WAIT_SILENT_GO'] = self.script('silent-off', 'exit 1\n')
        self.env['CHIEF_WAIT_SIZE'] = self.root.joinpath('silent-off').as_posix()
        self.env['CHIEF_WAIT_RMLEASE'] = self.root.joinpath('silent-off').as_posix()
        self.env['CHIEF_WAIT_GH'] = self.root.joinpath('silent-off').as_posix()

    def script(self, name, body):
        p = self.root / name
        p.write_text('#!/usr/bin/env bash\n' + body)
        p.chmod(0o755)
        return str(p)

    def path(self, suffix):
        return Path(str(self.inbox) + '.wait.' + suffix)

    def start(self, extra=(), env=None, sock=False):
        output = self.root / ('out' + str(len(self.procs)))
        self.procs.append((None, output))
        args = ['bash', str(HERE / 'chief-wait.sh'), str(self.inbox), '--stream',
                '--doc', str(self.doc), '--workers-from', str(self.fleet), *extra]
        with output.open('w') as out:
            p = subprocess.Popen(args, env=env or self.env, stdout=out, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        self.procs[-1] = (p, output)
        return p, output

    def until(self, predicate, seconds=6):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(.04)
        details = '\n'.join(p.read_text() for _, p in self.procs)
        for part in self.root.glob('consoles/*'):
            if part.is_file() and part.stat().st_size < 5000:
                details += '\n' + part.name + ': ' + part.read_text()
        self.fail('deadline: ' + details)

    def armed(self):
        self.until(lambda: self.path('stream').exists())

    def state(self):
        return dict(v.split('=', 1) for v in self.path('stream').read_text().split())

    def stop(self, proc):
        self.path('stop').touch()
        proc.wait(timeout=6)

    def heartbeat(self):
        try:
            return Path(str(self.inbox) + '.wait').read_text()
        except OSError:
            return ''

    def gone(self, pid):
        try:
            return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[0] == 'Z'
        except (OSError, IndexError):
            return True

    def gated_tick(self):
        entered, gate = self.root / 'tick-entered', self.root / 'tick-gate'
        self.script('tick', f'touch "{entered}"\nn=0\nwhile [ ! -e "{gate}" ] && [ "$n" -lt 600 ]; do sleep .1; n=$((n + 1)); done\n'
                    'echo "TICK workers=0 livestate=0 prs=none tails=none acts=none workerset=0 board=ok tracker=ok denials=0 capacity=FULL"\n')
        return entered, gate

    def wake_rows(self):
        return [l for l in self.path('wakes').read_text().splitlines() if l.startswith('W\t')]

    def unsampleable_sleep_env(self, **extra):
        nap = self.root / 'nap'
        shutil.copy2(shutil.which('sleep'), nap)
        env = dict(self.env, **extra)
        env['BASH_FUNC_sleep%%'] = f'() {{  {nap} "$@"\n}}'
        kind = subprocess.run(['bash', '-c', 'type -t sleep'], env=env, capture_output=True, text=True).stdout.strip()
        self.assertEqual(kind, 'function', 'the sleep shim is not active')
        return env

    def driven(self, schedule, **extra):
        driver = self.root / 'schedule-driver.py'
        driver.write_text(SCHEDULE_DRIVER)
        env = dict(self.env, STREAM_PY=str(HERE / 'chief-wait-stream.py'), SCHEDULE=schedule, **extra)
        output = self.root / ('driven-out' + str(len(self.procs)))
        with output.open('w') as out:
            p = subprocess.Popen([sys.executable, '-I', str(driver), str(self.inbox), '--stream', '--doc', str(self.doc),
                                  '--workers-from', str(self.fleet)], env=env, stdout=out, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        self.procs.append((p, output))
        return p, output

    def session_members(self, sessions):
        root, found, own = str(self.root).encode(), [], os.getsid(0)
        sessions.discard(own)
        for entry in Path('/proc').iterdir():
            if entry.name.isdigit():
                try:
                    fields = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
                    named = root in (entry / 'cmdline').read_bytes()
                except (OSError, IndexError):
                    continue
                if fields[0] != 'Z' and (named or int(fields[3]) in sessions):
                    found.append(int(entry.name))
                    if named and int(fields[3]) != own:
                        sessions.add(int(fields[3]))
        return [pid for pid in found if pid != os.getpid()]

    def stop_fixture_sessions(self):
        sessions = {proc.pid for proc, _ in self.procs if proc}
        for stream in self.root.glob('consoles/*.wait.stream'):
            data = dict(v.split('=', 1) for v in stream.read_text().split() if '=' in v)
            sessions.update(int(data.get(key, '0')) for key in ('child', 'dog'))
        sessions.discard(0)
        end = time.monotonic() + 10
        while time.monotonic() < end:
            pids = self.session_members(sessions)
            if not pids:
                return
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            time.sleep(.02)
        self.fail(f'processes {self.session_members(sessions)} outlived the test')

    def tearDown(self):
        for proc, _ in self.procs:
            if proc and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
        # Only kill identities created in this fixture, never external processes.
        if self.path('stream').exists():
            data = dict(v.split('=', 1) for v in self.path('stream').read_text().split())
            for key in ('child', 'dog'):
                pid = int(data.get(key, '0'))
                if pid > 1:
                    try:
                        cmd = Path(f'/proc/{pid}/cmdline').read_bytes()
                        if str(self.inbox).encode() in cmd:
                            os.kill(pid, signal.SIGKILL)
                    except (ProcessLookupError, FileNotFoundError):
                        pass
        self.stop_fixture_sessions()
        self.tmp.cleanup()

class Stream(StreamFixture):
    def test_two_inbox_wakes_same_supervisor_and_safe_stop(self):
        p, out = self.start()
        self.armed()
        self.inbox.write_text('first\n')
        self.until(lambda: 'WAKE#1 telegram' in out.read_text())
        with self.inbox.open('a') as f:
            f.write('second\n')
        self.until(lambda: 'WAKE#2 telegram' in out.read_text())
        self.assertIsNone(p.poll())
        self.stop(p)
        self.assertIn('STOPPED since=2', out.read_text())
        self.assertEqual(len([l for l in self.path('wakes').read_text().splitlines() if l.startswith('W\t')]), 2)
        self.assertLessEqual(len((self.root / 'ticks').read_text().splitlines()), 1)

    def test_regular_stdout_refused_without_state(self):
        env = dict(self.env)
        env.pop('CHIEF_WAIT_STREAM_STDOUT_OK')
        p, out = self.start(env=env)
        self.assertEqual(p.wait(timeout=5), 2)
        self.assertIn('STREAM-REFUSED not-monitor', out.read_text())
        self.assertFalse(self.path('stream').exists())
        self.assertFalse(self.path('stream.lock').exists())

    def test_double_arm_and_replay_after_stop(self):
        p, out = self.start()
        self.armed()
        other, other_out = self.start()
        self.assertEqual(other.wait(timeout=5), 3)
        self.assertIn('live-supervisor', other_out.read_text())
        self.inbox.write_text('unacknowledged\n')
        self.until(lambda: 'WAKE#1' in out.read_text())
        self.stop(p)
        again, replay = self.start(('--since', '0'))
        self.until(lambda: 'REPLAY seqs=1-1 n=1' in replay.read_text())
        self.stop(again)
        self.assertEqual(sum(l.startswith('W\t') for l in self.path('wakes').read_text().splitlines()), 1)

    def test_fifty_pending_mixed_events_first_retry_fair(self):
        self.env.pop('CHIEF_WAIT_POLL_SEC')
        workers = []
        for n in range(1, 51):
            doc = self.root / f'N{n}.md'
            marker = 'WRAPPED no PR' if n % 2 else 'READY #123 ' + 'a' * 40
            doc.write_text(f'# N{n}\n## Results\n- {marker}\n')
            workers.append(dict(label=f'N{n}', doc=str(doc)))
        self.fleet.write_text(json.dumps(dict(workers=workers)))
        self.env['CHIEF_WAIT_WORKER_EVENT'] = self.script('event', r'''line=$(cat)
echo "$line" >> "$TEST_ROOT/events"
case "$line" in N1\ *)
    if [ ! -e "$TEST_ROOT/first-retry" ]; then
        touch "$TEST_ROOT/first-retry"
        echo 'ESCALATE close-wrapped-failed rc=3 queue lock held'
        exit 10
    fi;; esac
case "$line" in N3\ *) sleep .2;; esac
echo 'HANDLED close-wrapped'
''')
        started = time.monotonic()
        p, _ = self.start()
        self.until(lambda: self.path('r0').exists() and
                   len(self.path('r0').read_text().splitlines()) == 50, seconds=30)
        self.assertLess(time.monotonic() - started, 30)
        print(f'50 mixed pending events drained in {time.monotonic() - started:.2f}s at the default stream poll', flush=True)
        events = (self.root / 'events').read_text().splitlines()
        self.assertEqual(events[0].split()[0], 'N1')
        self.assertEqual(events[1].split()[0], 'N2')
        self.assertEqual(sum(line.startswith('N2 ') for line in events), 1)
        self.assertEqual(sum(line.startswith('N1 ') for line in events), 2)
        self.stop(p)
        again, _ = self.start()
        self.until(lambda: self.state().get('sup') == str(again.pid))
        time.sleep(.4)
        self.stop(again)
        events = (self.root / 'events').read_text().splitlines()
        self.assertEqual(sum(line.startswith('N2 ') for line in events), 1)

    def test_socket_stdout_real_adapter_control(self):
        env = dict(self.env)
        env.pop('CHIEF_WAIT_STREAM_STDOUT_OK')
        left, right = socket.socketpair()
        try:
            p = subprocess.Popen(['bash', str(HERE / 'chief-wait.sh'), str(self.inbox), '--stream',
                                  '--workers-from', str(self.fleet)], env=env, stdout=right,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
            self.procs.append((p, self.root / 'socket-out'))
            self.procs[-1][1].touch()
            right.close()
            self.armed()
            self.inbox.write_text('socket event\n')
            left.settimeout(5)
            self.assertIn(b'WAKE#1 telegram', left.recv(4096))
            self.assertIsNone(p.poll())
            self.stop(p)
        finally:
            left.close()
            right.close()

    def test_silent_helper_result_for_a_keyed_worker_rides_a_wake_line(self):
        worker = self.root / 'HIMMEL-1-N1-a.md'
        worker.write_text('# worker\n## Results\n')
        old = time.time() - 3 * 3600
        os.utime(worker, (old, old))
        self.fleet.write_text(json.dumps({'workers': [{'doc': str(worker), 'label': 'N1'}]}))
        self.script('tick', 'echo "TICK workers=N1:FRESH livestate=0 prs=none tails=none acts=none workerset=0 board=ok tracker=ok denials=0 capacity=FULL busedge=MISSING:N1 wakerstate=N1:capped"\n')
        act = self.script('act', 'n=$(cat "$TEST_ROOT/acts" 2>/dev/null || echo 0)\necho $((n + 1)) > "$TEST_ROOT/acts"\n'
                          'if [ -f "$TEST_ROOT/relaunch" ]; then rm -f "$TEST_ROOT/relaunch"; echo "SILENT-ACT N1 relaunched RESUME-N1"; exit 0; fi\n'
                          'if [ "$n" -eq 0 ]; then echo "SILENT-ACT N1 nudged"; else echo "SILENT-ACT N1 done"; fi\n')
        env = dict(self.env, CHIEF_WAIT_SILENT_ACT=act, CHIEF_WAIT_WORKER_SILENT_MIN='30', CHIEF_WAIT_INTERVAL='1',
                   CHIEF_WAIT_PAGE_CMD=str(self.root / 'off'))
        p, out = self.start(env=env)
        self.armed()
        self.until(lambda: 'WAKE#1 worker-silent N1' in out.read_text())
        (self.root / 'relaunch').touch()
        self.until(lambda: 'WAKE#2 worker-silent N1' in out.read_text())
        self.assertIn('SILENT-ACT N1 relaunched RESUME-N1', self.path('wake-2').read_text())
        self.stop(p)

    def test_repeat_and_flood_limits_keep_full_blocks(self):
        child = self.script('chief-wait-stub', "echo 'WAKE fixture repeat'\necho 'full detail retained'\n")
        env = dict(self.env, CHIEF_WAIT_STREAM_CHILD=child)
        p, out = self.start(env=env)
        self.assertEqual(p.wait(timeout=5), 0)
        self.assertEqual(out.read_text().count('WAKE#'), 2)
        self.assertIn('reason=repeat', out.read_text())
        self.assertIn('full detail retained', self.path('wake-2').read_text())
        self.assertNotIn('full detail retained', out.read_text())
        env['CHIEF_WAIT_STREAM_REPEAT_SEC'] = '0.001'
        again, flood = self.start(('--since', '0'), env=env)
        self.assertEqual(again.wait(timeout=5), 0)
        self.assertLessEqual(len(flood.read_text().splitlines()), 7)
        self.assertIn('reason=rate', flood.read_text())

    def test_busy_handoff_adoption_preserves_identity_and_safe_clock(self):
        self.script('tick', 'sleep 3\necho "TICK workers=0 livestate=0 prs=none tails=none acts=none workerset=0 board=ok tracker=ok denials=0 capacity=FULL"\n')
        env = dict(self.env, CHIEF_WAIT_STREAM_SOFT_SEC='.3', CHIEF_WAIT_STREAM_HARD_SEC='1')
        p, out = self.start(env=env)
        self.assertEqual(p.wait(timeout=5), 0)
        self.assertIn('child=busy', out.read_text())
        before = self.state()
        self.inbox.write_text('during handoff\n')
        again, adopted = self.start()
        self.until(lambda: self.state().get('sup') == str(again.pid))
        after = self.state()
        self.assertEqual(after['child'], before['child'])
        self.assertEqual(after['safe'], before['safe'])
        self.until(lambda: 'WAKE#1 telegram' in adopted.read_text())
        self.assertIn('adopted', self.path('wakes').read_text())
        self.stop(again)

    def test_stream_child_honours_a_stop_request_at_its_safe_point(self):
        self.path('stop').touch()
        out = self.root / 'child-out'
        with out.open('w') as f:
            child = subprocess.run(['bash', str(HERE / 'chief-wait.sh'), str(self.inbox), '--doc', str(self.doc),
                                    '--workers-from', str(self.fleet)], env=dict(self.env, CHIEF_WAIT_STREAM_SERVICE='1'),
                                   stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT, timeout=15)
        self.assertEqual(child.returncode, 143, out.read_text())
        self.assertIn('state=exited exit=stream-stop', Path(str(self.inbox) + '.wait').read_text())

    def test_foreground_waiter_ignores_a_stale_stop_request(self):
        self.path('stop').touch()
        env = dict(self.env)
        env.pop('CHIEF_WAIT_STREAM_SERVICE', None)
        out = self.root / 'foreground-out'
        heartbeat = Path(str(self.inbox) + '.wait')

        def beat():
            try:
                return heartbeat.read_text()
            except OSError:
                return ''
        with out.open('w') as f:
            p = subprocess.Popen(['bash', str(HERE / 'chief-wait.sh'), str(self.inbox), '--doc', str(self.doc),
                                  '--workers-from', str(self.fleet)], env=env, stdin=subprocess.DEVNULL,
                                 stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
        self.procs.append((p, out))
        self.until(lambda: 'state=waiting' in beat() or p.poll() is not None)
        time.sleep(1)
        self.assertIsNone(p.poll(), out.read_text())
        self.assertNotIn('exit=stream-stop', beat())
        p.terminate()
        p.wait(timeout=6)
        self.assertIn('state=exited exit=signal-TERM', beat())
        self.assertNotIn('stream-stop', beat())

    def test_adopted_child_stopped_by_request_is_not_a_waiter_error(self):
        entered, gate, expired = self.root / 'tick-entered', self.root / 'tick-gate', self.root / 'tick-expired'
        self.script('tick', f'touch "{entered}"\nn=0\nwhile [ ! -e "{gate}" ]; do\n'
                    f'    [ "$n" -lt 600 ] || {{ touch "{expired}"; exit 1; }}\n    sleep .1; n=$((n + 1))\ndone\n'
                    'echo "TICK workers=0 livestate=0 prs=none tails=none acts=none workerset=0 board=ok tracker=ok denials=0 capacity=FULL"\n')

        def sidecar():
            try:
                return self.state()
            except (OSError, ValueError):
                return {}

        def heartbeat():
            try:
                return Path(str(self.inbox) + '.wait').read_text()
            except OSError:
                return ''

        def alive(pid):
            try:
                return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[0] != 'Z'
            except (OSError, IndexError):
                return False
        seen = []

        def held():
            child, hb = sidecar().get('child', '0'), heartbeat()
            if entered.exists() and child.isdecimal() and int(child) > 0 and f'pid={child} ' in hb and 'state=sampling' in hb:
                seen.append(child)
            return bool(seen)
        env = dict(self.env, CHIEF_WAIT_STREAM_REAP_MAX_SEC='120')
        try:
            first, _ = self.start(env=env)
            self.until(held, seconds=30)
            child = seen[0]
            first.send_signal(signal.SIGTERM)
            self.assertEqual(first.wait(timeout=30), 0)
            self.assertTrue(alive(child), f'the held child {child} outlived its supervisor')
            again, adopted = self.start(env=env)
            self.until(lambda: sidecar().get('sup') == str(again.pid), seconds=30)
            self.assertEqual(sidecar().get('child'), child, 'the successor adopted the held child')
            self.assertFalse(gate.exists())
            self.path('stop').touch()
            gate.touch()
            rc = again.wait(timeout=60)
            self.assertNotIn('waiter-error', adopted.read_text())
            self.assertNotIn('child=busy', adopted.read_text(), 'the adopted child was reaped, not left busy')
            self.assertIn('STOPPED', adopted.read_text())
            final = heartbeat()
            self.assertIn(f'pid={child} ', final)
            self.assertIn('state=exited exit=stream-stop', final)
            after = sidecar()
            self.assertEqual(after.get('child'), '0', f'the normal reap clears the child: {after}')
            self.assertNotIn('part', after, f'the normal reap drops the live part: {after}')
            self.assertFalse(expired.exists(), 'the tick gate ran out before the test opened it')
            self.assertEqual(rc, 0)
        finally:
            gate.touch()

    def test_killed_after_output_replays_and_lock_is_not_inherited(self):
        p, _ = self.launch_window('record')
        self.armed()
        self.inbox.write_text('record before print\n')
        self.assertEqual(p.wait(timeout=10), 137)
        self.assertTrue(any('WAKE telegram' in part.read_text() for part in self.root.glob('consoles/*.wait.part-*')))
        time.sleep(.5)
        again, out = self.start(('--since', '0'))
        self.until(lambda: 'REPLAY seqs=1-1 n=1' in out.read_text())
        self.assertNotIn('live-supervisor', out.read_text())
        self.stop(again)

    def test_pid_reuse_is_never_adopted_or_signalled(self):
        unrelated = subprocess.Popen(['bash', '-c', 'sleep 30; :', 'chief-wait-reused', str(self.inbox)], start_new_session=True)
        try:
            self.path('stream').write_text(f'child={unrelated.pid} child_start=wrong host={socket.gethostname()} boot={Path("/proc/sys/kernel/random/boot_id").read_text().strip()} seq=0\n')
            p, _ = self.start()
            self.until(lambda: self.state().get('sup') == str(p.pid) and self.state().get('child') != str(unrelated.pid))
            self.stop(p)
            self.assertIsNone(unrelated.poll())
        finally:
            os.killpg(unrelated.pid, signal.SIGKILL)
            unrelated.wait()

    def waiters(self):
        found = []
        for entry in Path('/proc').iterdir():
            if entry.name.isdigit():
                try:
                    argv = (entry / 'cmdline').read_bytes().split(b'\0')
                except OSError:
                    continue
                if os.fsencode(str(self.inbox)) in argv and any(b'chief-wait.sh' in a for a in argv):
                    found.append(int(entry.name))
        return found

    def kill_waiters(self):
        for pid in self.waiters():
            try:
                os.killpg(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass

    def launch_window(self, point):
        wrapper = self.root / 'launch-window.py'
        wrapper.write_text(LAUNCH_WINDOW)
        output = self.root / ('launch-' + point)
        with output.open('w') as out:
            p = subprocess.Popen([sys.executable, '-I', str(wrapper), str(HERE / 'chief-wait-stream.py'), point, str(self.inbox),
                                  '--doc', str(self.doc), '--workers-from', str(self.fleet)],
                                 env=self.env, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        self.procs.append((p, output))
        self.addCleanup(self.kill_waiters)
        return p, output

    def check_a_supervisor_killed_in_the_launch_window_leaves_no_orphan_waiter(self, point):
        p, _ = self.launch_window(point)
        self.assertEqual(p.wait(timeout=10), 137)
        end = time.monotonic() + 5
        while self.waiters() and time.monotonic() < end:
            time.sleep(.05)
        self.assertEqual(self.waiters(), [], 'a waiter outlived the supervisor that was killed while launching it')
        again, out = self.start()
        self.until(lambda: self.state().get('sup') == str(again.pid))
        self.inbox.write_text('after the killed launch\n')
        self.until(lambda: 'WAKE#1 telegram' in out.read_text())
        self.assertNotIn('STREAM-REFUSED', out.read_text())
        self.assertIn('W\t1\t', self.path('wakes').read_text())
        self.stop(again)

    def test_killed_before_the_child_pid_is_known_leaves_no_orphan_waiter(self):
        self.check_a_supervisor_killed_in_the_launch_window_leaves_no_orphan_waiter('identity')

    def test_killed_while_publishing_the_child_pid_leaves_no_orphan_waiter(self):
        self.check_a_supervisor_killed_in_the_launch_window_leaves_no_orphan_waiter('publish')

    def test_killed_right_after_publishing_the_child_pid_leaves_no_orphan_waiter(self):
        self.check_a_supervisor_killed_in_the_launch_window_leaves_no_orphan_waiter('after-publish')

    def test_a_slow_live_supervisor_keeps_its_waiter_waiting_for_the_publish(self):
        p, out = self.launch_window('stall')
        self.armed()
        self.until(lambda: self.state().get('child', '0') != '0', seconds=10)
        child = self.state()['child']
        self.assertTrue(Path(f'/proc/{child}').exists(), 'the waiter gave up before its pid was published')
        self.inbox.write_text('after the slow publish\n')
        self.until(lambda: 'WAKE#1 telegram' in out.read_text())
        self.stop(p)

    def test_busy_bound_kills_owned_child_and_reports_hang(self):
        self.script('tick', 'sleep 3\n')
        env = dict(self.env, CHIEF_WAIT_STREAM_BUSY_MAX_SEC='1')
        p, out = self.start(env=env)
        self.armed()
        self.until(lambda: self.state().get('child', '0') != '0')
        child = self.state()['child']
        self.assertEqual(p.wait(timeout=5), 1)
        self.assertIn('waiter-error kind=hung', out.read_text())
        proc = Path(f'/proc/{child}/stat')
        self.assertTrue(not proc.exists() or proc.read_text().rsplit(')', 1)[1].split()[0] == 'Z')

    def test_rules_table_is_the_printed_contract(self):
        result = subprocess.run(['bash', str(HERE / 'chief-wait.sh'), '--rules'],
                                env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, (HERE / 'wake-rules.tsv').read_text())
        rows = [s.split('\t') for s in result.stdout.splitlines() if not s.startswith('#')]
        self.assertEqual(len(rows), len({r[0] for r in rows}))
        self.assertTrue({'residual-cap', 'open', 'station', 'repair', 'rm-queue', 'mon-down', 'owed'} <= {r[0] for r in rows})

    def test_station_repair_aged_queue_and_mon_wakes(self):
        prefix = 'TICK workers=0 livestate=0 prs=none tails=none acts=none workerset=0 board=ok tracker=ok denials=0 capacity=FULL '
        releases = self.root / 'release/R1'
        releases.mkdir(parents=True)
        (releases / 'repair-state.json').write_text(json.dumps(dict(operator_command='exact  persisted remedy --review R1')))
        self.doc.write_text('# chief\nrelease: R1\n## Results\n')
        cases = [('station=BEHIND:pending', 'station', 'BEHIND:pending'),
                 ('repair=off:unreviewed', 'repair', 'exact  persisted remedy --review R1'),
                 ('repair=off:lost', 'repair', 'exact  persisted remedy --review R1'),
                 ('repair=off:unavailable', 'repair', 'off:unavailable'),
                 ('repair=off:unread', 'repair', 'off:unread'),
                 ('rm-queue=1,31m', 'rm-queue', 'rm-queue=1,31m'),
                 ('mon-down=1234', 'mon', '1234')]
        self.env.update(CHIEF_WAIT_INTERVAL='1', HIMMEL_RELEASE_STATE_DIR=str(self.root / 'release'),
                        CHIEF_WAIT_STREAM_MAX_PER_MIN='100')
        for field, kind, detail in cases:
            with self.subTest(field=field):
                self.script('tick', "echo '" + prefix + field + "'\n")
                self.path('next-tick').unlink(missing_ok=True)
                p, out = self.start(('--since', '0'))
                try:
                    self.until(lambda: f' {kind} ' in out.read_text(), seconds=5)
                    self.assertIn(detail, self.path('wake-' + str(self.state()['seq'])).read_text())
                    self.assertIsNone(p.poll())
                finally:
                    self.stop(p)

    def test_owed_proof_stays_open_and_notification_requires_ack(self):
        rows = [dict(op='add', id='o1', ts='2026-11-17T00:00:00Z', epoch=1, chief='chief',
                     kind='proof', text='validate evidence', actor='chief', action='validate-proof', validation='pending'),
                dict(op='add', id='o2', ts='2026-11-17T00:00:00Z', epoch=1, chief='chief',
                     kind='ruling', text='overdue step', actor='chief', action='notify', event='step-due')]
        ledger = self.root / 'owed.jsonl'
        ledger.write_text(''.join(json.dumps(r) + '\n' for r in rows))
        p, out = self.start()
        self.until(lambda: 'owed-actions' in out.read_text())
        self.assertEqual(len(ledger.read_text().splitlines()), 2)
        seq = self.state()['seq']
        ack = subprocess.run(['bash', str(HERE / 'chief-wait.sh'), str(self.inbox), '--ack', seq,
                              '--receipt', 'fixture-delivery-123'], env=self.env, capture_output=True, text=True)
        self.assertEqual(ack.returncode, 0, ack.stderr)
        self.until(lambda: '"op":"close"' in ledger.read_text())
        self.until(lambda: 'K\t' + seq in self.path('wakes').read_text())
        closed = [json.loads(s)['ref'] for s in ledger.read_text().splitlines() if json.loads(s)['op'] == 'close']
        self.assertEqual(closed, ['o2'])
        self.assertIn('D\t' + seq, self.path('wakes').read_text())
        self.assertIn('K\t' + seq, self.path('wakes').read_text())
        self.stop(p)

    def test_operator_digest_queued_is_not_a_receipt_and_lost_response_reconciles(self):
        row = dict(op='add', id='o1', ts='2026-11-17T00:00:00Z', epoch=1, chief='chief',
                   kind='ruling', text='operator action overdue', actor='operator', action='notify', event='operator-digest')
        ledger = self.root / 'owed.jsonl'
        ledger.write_text(json.dumps(row) + '\n')
        self.env['CHIEF_WAIT_OWED_SEND'] = self.script('send', 'echo "$*" >> "$TEST_ROOT/sends"\necho queued\n')
        self.env['CHIEF_WAIT_OPERATOR_RETRY_SEC'] = '600'
        p, out = self.start()
        self.until(lambda: 'owed-actions' in out.read_text())
        self.assertIn('operator-delivery-pending', self.path('wake-1').read_text())
        self.assertEqual(len(ledger.read_text().splitlines()), 1)
        sends = self.root / 'sends'
        self.assertEqual(len(sends.read_text().splitlines()), 1, 'the first attempt is one send')
        # Simulate the existing sender's real receipt arriving after its caller
        # lost the response; the service must reconcile rather than resend.
        with self.doc.open('a') as f:
            f.write('- DELIVERED t2-o1 msg=42 chat=123\n')
        self.until(lambda: '"op":"close"' in ledger.read_text())
        self.assertIn('telegram-msg-42', ledger.read_text())
        self.assertEqual(len(sends.read_text().splitlines()), 1, 'the receipt was answered with another send')
        self.stop(p)

    def test_busy_consumer_fifteen_simulated_minutes_without_ack(self):
        clock = self.root / 'clock'
        clock.write_text('1794800000')

        def set_clock(epoch):
            tmp = self.root / 'clock.tmp'
            tmp.write_text(str(epoch))
            os.replace(tmp, clock)
        bindir = self.root / 'bin'
        bindir.mkdir()
        self.script('date', 'if [ "${1:-}" = +%s ]; then cat "$TEST_ROOT/clock"; else /bin/date "$@"; fi\n')
        (bindir / 'date').symlink_to(self.root / 'date')
        self.env.update(PATH=str(bindir) + ':' + self.env['PATH'], CHIEF_WAIT_STREAM_MAX_PER_MIN='100',
                        CHIEF_WAIT_STREAM_TEST_CLOCK=str(clock), CHIEF_WAIT_STREAM_SOFT_SEC='1440',
                        CHIEF_WAIT_STREAM_HARD_SEC='1680')
        p, out = self.start()
        self.armed()
        for minute in range(15):
            set_clock(1794800000 + minute * 60)
            with self.inbox.open('a') as f:
                f.write(f'busy consumer event {minute}\n')
            self.until(lambda: f'WAKE#{minute + 1} telegram' in out.read_text())
            self.assertIsNone(p.poll())
        self.assertNotIn('REARM', out.read_text())
        set_clock(1794800000 + 1440 + 60)
        self.until(lambda: 'REARM' in out.read_text())
        p.wait(timeout=6)
        self.assertNotIn('K\t', self.path('wakes').read_text())

    def test_rotation_gap_reset_and_monotonic_sequence(self):
        self.env['CHIEF_WAIT_STREAM_MAX_PER_MIN'] = '100'
        p, out = self.start()
        self.armed()
        for n in range(3):
            with self.inbox.open('a') as f:
                f.write(str(n) + '\n')
            self.until(lambda: f'WAKE#{n + 1} ' in out.read_text())
        self.stop(p)
        env = dict(self.env, CHIEF_WAIT_STREAM_KEEP='2')
        again, replay = self.start(('--since', '0'), env=env)
        self.until(lambda: 'REPLAY seqs=2-3 n=2' in replay.read_text())
        self.assertIn('GAP since=0 oldest=2', replay.read_text())
        self.stop(again)
        self.path('wakes').unlink()
        reset, reset_out = self.start(('--since', '3'))
        self.until(lambda: 'GAP since=3 log=reset' in reset_out.read_text())
        with self.inbox.open('a') as f:
            f.write('after reset\n')
        self.until(lambda: 'WAKE#4 telegram' in reset_out.read_text())
        self.stop(reset)

    def test_the_current_and_the_previous_replay_index_survive_with_their_blocks(self):
        p, out = self.start()
        self.armed()
        self.inbox.write_text('one\n')
        self.until(lambda: 'WAKE#1 telegram' in out.read_text())
        self.stop(p)
        advertised = []
        for _ in range(3):
            again, replay = self.start(('--since', '0'))
            self.until(lambda: 'REPLAY seqs=1-1' in replay.read_text())
            advertised.append(re.search(r'index=(\S+)', replay.read_text())[1])
            self.stop(again)
        self.assertEqual([Path(index).exists() for index in advertised], [False, True, True])
        wakes = [line.split('\t') for line in self.path('wakes').read_text().splitlines() if line.startswith('W\t')]
        for index in advertised[1:]:
            rows = [line.split('\t') for line in Path(index).read_text().splitlines()]
            self.assertTrue(rows, index)
            for row in rows:
                self.assertIn(row, wakes)
                self.assertTrue(Path(row[5]).exists(), row)

    def test_child_error_ends_arm_without_relaunch(self):
        stub = self.script('chief-wait-error', "echo call >> \"$TEST_ROOT/calls\"\necho 'WAKE fixture before-error'\nexit 1\n")
        p, out = self.start(env=dict(self.env, CHIEF_WAIT_STREAM_CHILD=stub))
        self.assertEqual(p.wait(timeout=5), 1)
        self.assertIn('WAKE#1 fixture before-error', out.read_text())
        self.assertIn('WAKE#2 waiter-error rc=1', out.read_text())
        self.assertEqual((self.root / 'calls').read_text().splitlines(), ['call'])

    def test_default_option_value_does_not_select_stream(self):
        self.inbox.write_text('default wake\n')
        out = self.root / 'default-out'
        with out.open('w') as f:
            p = subprocess.Popen(['bash', str(HERE / 'chief-wait.sh'), str(self.inbox), '--token', '--stream'],
                                 env=self.env, stdout=f, stderr=f)
        self.procs.append((p, out))
        self.assertEqual(p.wait(timeout=5), 0)
        self.assertIn('WAKE telegram', out.read_text())
        self.assertFalse(self.path('stream').exists())

    def test_rule_markers_reminder_unknown_and_recovery(self):
        def rule(line):
            return subprocess.run(['python3', '-I', str(HERE / 'wake-rules.py'), '--inbox', str(self.inbox)],
                                  input=line, env=self.env, text=True, capture_output=True)
        self.assertEqual(rule('TICK mon-down=123').returncode, 0)
        self.assertEqual(rule('TICK mon-down=456').returncode, 1)
        self.assertEqual(rule('TICK mon-down=?').returncode, 1)
        self.assertEqual(rule('TICK mon-down=123').returncode, 1)
        self.assertEqual(rule('TICK').returncode, 1)
        self.assertTrue(self.path('rule-mon').exists())
        monitor = self.root / 'home/.claude/handover/bridge/monitor/state'
        monitor.parent.mkdir(parents=True)
        monitor.write_text('ok\n')
        self.assertEqual(rule('TICK').returncode, 1)
        self.assertFalse(self.path('rule-mon').exists())
        self.assertEqual(rule('TICK mon-down=123').returncode, 0)
        self.assertEqual(rule('TICK station=BEHIND:pending').returncode, 0)
        self.assertEqual(rule('TICK station=BEHIND:pending').returncode, 1)
        os.utime(self.path('rule-station'), (time.time() - 3601,) * 2)
        self.assertEqual(rule('TICK station=BEHIND:pending').returncode, 0)
        self.assertEqual(rule('TICK station=?').returncode, 1)
        self.assertTrue(self.path('rule-station').exists())
        self.assertEqual(rule('TICK rm-queue=1,20m').returncode, 1)
        self.assertEqual(rule('TICK rm-queue=1,21m').returncode, 0)

    def test_persistent_underfill_reminds_with_unchanged_pool(self):
        self.script('tick', 'echo "TICK workers=0 livestate=0 prs=none tails=none acts=none workerset=0 board=ok tracker=ok denials=0 capacity=UNDERFILLED:1"\n')
        self.env.update(CHIEF_WAIT_INTERVAL='1', CHIEF_WAIT_UNDERFILL_REPOOL_SEC='1',
                        CHIEF_WAIT_STREAM_REPEAT_SEC='0.001',
                        CHIEF_WAIT_DISPATCH=self.script('pool', 'echo POOL-EMPTY\n'))
        p, out = self.start()
        self.until(lambda: out.read_text().count('underfilled') >= 2)
        self.assertIsNone(p.poll())
        self.stop(p)

    def test_inbox_runs_between_action_and_due_slow_tick(self):
        worker = self.root / 'N1.md'
        worker.write_text('- WRAPPED no PR\n')
        self.fleet.write_text(json.dumps(dict(workers=[dict(label='N1', doc=str(worker))])))
        self.env['TEST_INBOX'] = str(self.inbox)
        self.env['CHIEF_WAIT_WORKER_EVENT'] = self.script('event', 'cat >/dev/null\necho operator >> "$TEST_INBOX"\necho "HANDLED close-wrapped"\n')
        self.script('tick', 'sleep 3\n')
        p, out = self.start()
        self.until(lambda: 'WAKE#1 telegram' in out.read_text(), seconds=2)
        self.stop(p)

    def test_watchdog_bounds_unadopted_busy_child_and_replays_hang_once(self):
        self.script('tick', 'sleep 4\n')
        env = dict(self.env, CHIEF_WAIT_STREAM_SOFT_SEC='.2', CHIEF_WAIT_STREAM_HARD_SEC='.6',
                   CHIEF_WAIT_STREAM_ADOPT_SEC='0.001', CHIEF_WAIT_STREAM_REAP_MAX_SEC='1')
        p, out = self.start(env=env)
        self.assertEqual(p.wait(timeout=4), 0)
        self.assertIn('child=busy', out.read_text())
        child = self.state()['child']
        for fd in Path(f'/proc/{child}/fd').glob('*'):
            try:
                self.assertNotEqual(os.readlink(fd), str(self.path('stream.lock')))
            except FileNotFoundError:
                pass
        self.until(lambda: self.path('stream.hung').exists(), seconds=4)
        again, replay = self.start()
        self.assertEqual(again.wait(timeout=4), 1)
        self.assertIn('waiter-error kind=hung', replay.read_text())
        self.assertFalse(self.path('stream.hung').exists())
        self.script('tick', 'exit 1\n')
        final, final_out = self.start(('--since', str(self.state()['seq'])))
        self.until(lambda: self.state().get('sup') == str(final.pid))
        self.stop(final)
        self.assertNotIn('kind=hung', final_out.read_text())

    def test_operator_digest_receipt_closes_only_delivered_notification(self):
        ledger = self.root / 'owed.jsonl'
        row = dict(op='add', id='o1', ts='2026-11-17T00:00:00Z', epoch=1, chief='chief',
                   kind='ruling', text='operator owes step', actor='operator', action='notify', event='operator-digest')
        ledger.write_text(json.dumps(row) + '\n')
        self.env['TEST_DOC'] = str(self.doc)
        self.env['CHIEF_WAIT_OWED_SEND'] = self.script('send', 'echo "$*" >> "$TEST_ROOT/sends"\necho "- DELIVERED t2-o1 msg=77 chat=123" >> "$TEST_DOC"\necho "delivered msg=77"\n')
        p, _ = self.start()
        self.until(lambda: 'telegram-msg-77' in ledger.read_text())
        self.assertIn('--chief chief --owed t2-o1 --doc', (self.root / 'sends').read_text())
        self.assertEqual(len((self.root / 'sends').read_text().splitlines()), 1)
        self.stop(p)

    def test_unread_owed_wakes_and_preserves_source(self):
        ledger = self.root / 'owed.jsonl'
        ledger.write_text('unread ledger\n')
        p, out = self.start()
        self.until(lambda: 'owed-actions-unread' in out.read_text(), seconds=2)
        self.assertEqual(ledger.read_text(), 'unread ledger\n')
        self.stop(p)

    def test_a_stop_touched_after_the_marker_sample_and_honoured_before_the_hard_finish_ends_with_stopped(self):
        p, out = self.driven('touched-after-the-sample', CHIEF_WAIT_STREAM_MAX_PER_MIN='100')
        self.armed()
        self.inbox.write_text('first\n')
        self.until(lambda: 'WAKE#1 telegram' in out.read_text(), seconds=20)
        self.assertEqual(p.wait(timeout=30), 0, out.read_text())
        fired = Path(str(self.inbox) + '.wait.schedule-fired')
        self.assertTrue(fired.exists(), 'the schedule was not forced: ' + out.read_text())
        self.assertIn(f'pid={fired.read_text()} ', self.heartbeat())
        self.assertIn('state=exited exit=stream-stop', self.heartbeat(), 'the child did not honour the stop')
        self.assertIn('STOPPED since=1', out.read_text())
        self.assertNotIn('REARM', out.read_text())
        self.assertNotIn('child=busy', out.read_text())
        self.assertFalse(self.path('stop').exists())
        self.assertEqual(len(self.wake_rows()), 1)
        again, replay = self.start(('--since', '1'))
        self.until(lambda: self.state().get('sup') == str(again.pid), seconds=20)
        with self.inbox.open('a') as f:
            f.write('second\n')
        self.until(lambda: 'WAKE#2 telegram' in replay.read_text(), seconds=20)
        self.assertNotIn('WAKE#1', replay.read_text())
        self.stop(again)
        self.assertEqual(len(self.wake_rows()), 2)

    def test_a_stop_the_child_honoured_while_no_supervisor_ran_is_not_answered_with_a_new_child(self):
        entered, gate = self.gated_tick()
        env = dict(self.env, CHIEF_WAIT_STREAM_SOFT_SEC='.3', CHIEF_WAIT_STREAM_HARD_SEC='1',
                   CHIEF_WAIT_STREAM_ADOPT_SEC='120', CHIEF_WAIT_STREAM_REAP_MAX_SEC='240')
        p, out = self.start(env=env)
        self.until(entered.exists, seconds=20)
        self.assertEqual(p.wait(timeout=30), 0)
        self.assertIn('REARM since=0 wakes=0 child=busy', out.read_text())
        child = self.state()['child']
        self.path('stop').touch()
        gate.touch()
        self.until(lambda: self.gone(child), seconds=20)
        self.assertIn(f'pid={child} ', self.heartbeat())
        self.assertIn('state=exited exit=stream-stop', self.heartbeat())
        self.assertTrue(self.path('stop').exists())
        again, answer = self.start(env=env)
        self.until(lambda: 'STOPPED' in answer.read_text(), seconds=20)
        self.assertEqual(again.wait(timeout=30), 0)
        self.assertNotIn('REARM', answer.read_text())
        self.assertFalse(self.path('stop').exists())
        self.assertEqual(self.state().get('child'), '0', 'a new child was launched')
        third, wake = self.start(env=env)
        self.until(lambda: self.state().get('sup') == str(third.pid), seconds=20)
        self.inbox.write_text('after the stop\n')
        self.until(lambda: 'WAKE#1 telegram' in wake.read_text(), seconds=20)
        self.stop(third)
        self.assertEqual(wake.read_text().count('WAKE#'), 1)
        self.assertEqual(len(self.wake_rows()), 1)

    def test_a_stop_the_adopted_child_honours_before_the_stale_request_is_cleared_ends_with_stopped(self):
        entered, gate = self.gated_tick()
        env = dict(self.env, CHIEF_WAIT_STREAM_SOFT_SEC='.3', CHIEF_WAIT_STREAM_HARD_SEC='1',
                   CHIEF_WAIT_STREAM_ADOPT_SEC='120', CHIEF_WAIT_STREAM_REAP_MAX_SEC='240')
        first, out = self.start(env=env)
        self.until(entered.exists, seconds=20)
        self.assertEqual(first.wait(timeout=30), 0)
        self.assertIn('child=busy', out.read_text())
        child = self.state()['child']
        again, answer = self.driven('adopted', TICK_GATE=str(gate), CHIEF_WAIT_STREAM_SOFT_SEC='.3',
                                    CHIEF_WAIT_STREAM_HARD_SEC='1', CHIEF_WAIT_STREAM_ADOPT_SEC='120',
                                    CHIEF_WAIT_STREAM_REAP_MAX_SEC='240')
        self.assertEqual(again.wait(timeout=30), 0, answer.read_text())
        self.assertEqual(Path(str(self.inbox) + '.wait.schedule-fired').read_text(), child, 'the schedule was not forced')
        self.assertIn('state=exited exit=stream-stop', self.heartbeat())
        self.assertIn('STOPPED', answer.read_text())
        self.assertNotIn('REARM', answer.read_text())
        self.assertFalse(self.path('stop').exists())
        self.assertEqual(self.state().get('child'), '0', 'a new child was launched')
        self.assertEqual(len(self.wake_rows()), 0)

    def test_the_watchdog_ends_a_busy_child_that_no_sample_can_catch_asleep(self):
        entered, gate = self.gated_tick()
        env = self.unsampleable_sleep_env(CHIEF_WAIT_STREAM_SOFT_SEC='.3', CHIEF_WAIT_STREAM_HARD_SEC='1',
                                          CHIEF_WAIT_STREAM_ADOPT_SEC='.5', CHIEF_WAIT_STREAM_REAP_MAX_SEC='120')
        p, out = self.start(env=env)
        self.until(entered.exists, seconds=20)
        self.assertEqual(p.wait(timeout=30), 0)
        self.assertIn('child=busy', out.read_text())
        child = self.state()['child']
        self.until(lambda: time.time() > float(self.state()['handoff']) + 2, seconds=20)
        self.assertFalse(self.gone(child), 'the busy child was ended inside its step')
        self.assertFalse(self.path('stop').exists())
        gate.touch()
        self.until(lambda: self.gone(child), seconds=8)
        self.assertIn(f'pid={child} ', self.heartbeat())
        self.assertNotIn('exit=stream-stop', self.heartbeat())
        self.assertFalse(self.path('stream.hung').exists(), 'the child was killed by the reap bound, not ended at a safe point')
        self.assertFalse(self.path('stop').exists())

    def test_a_reap_request_for_the_watchdog_leaves_the_next_owner_an_unchanged_adoption(self):
        entered, gate = self.gated_tick()
        env = self.unsampleable_sleep_env(CHIEF_WAIT_STREAM_SOFT_SEC='.3', CHIEF_WAIT_STREAM_HARD_SEC='1',
                                          CHIEF_WAIT_STREAM_ADOPT_SEC='.5', CHIEF_WAIT_STREAM_REAP_MAX_SEC='120')
        p, out = self.start(env=env)
        self.until(entered.exists, seconds=20)
        self.assertEqual(p.wait(timeout=30), 0)
        child, dog = self.state()['child'], int(self.state()['dog'])
        self.until(lambda: self.path('reap').exists(), seconds=20)
        self.assertFalse(self.path('stop').exists())
        os.kill(dog, signal.SIGKILL)
        self.until(lambda: self.gone(dog), seconds=20)
        self.assertTrue(self.path('reap').exists(), 'the request outlives a watchdog that was killed')
        again, adopted = self.start(env=env)
        self.until(lambda: self.state().get('sup') == str(again.pid), seconds=20)
        self.until(lambda: not self.path('reap').exists(), seconds=20)
        self.assertEqual(self.state()['child'], child, 'the successor adopted the busy child')
        self.assertFalse(self.path('stop').exists())
        gate.touch()
        self.inbox.write_text('during adoption\n')
        self.until(lambda: 'WAKE#1 telegram' in adopted.read_text(), seconds=20)
        self.assertTrue(self.wake_rows()[0].endswith('\tadopted'), self.wake_rows())
        self.assertEqual(len(self.wake_rows()), 1)
        self.assertNotIn('waiter-error', adopted.read_text())
        self.stop(again)

    def test_a_stale_stop_nothing_honoured_is_cleared_by_the_next_arm(self):
        self.path('stop').touch()
        p, out = self.start()
        self.armed()
        self.until(lambda: not self.path('stop').exists(), seconds=20)
        self.inbox.write_text('runs on\n')
        self.until(lambda: 'WAKE#1 telegram' in out.read_text())
        self.assertIsNone(p.poll())
        self.assertNotIn('STOPPED', out.read_text())
        self.stop(p)
        self.assertEqual(len(self.wake_rows()), 1)


class AckRows(StreamFixture):

    def wake(self, seq, kind, text=None):
        if text is not None:
            self.path(f'wake-{seq}').write_text(text)
        return f'W\t{seq}\t{int(time.time())}\t77\t{kind}\t{self.path(f"wake-{seq}")}'

    def log(self, *rows):
        self.path('wakes').write_text(''.join(row + '\n' for row in rows))

    def rows(self):
        return [line.split('\t') for line in self.path('wakes').read_text().splitlines()]

    def ack(self, seq, receipt='rcpt-1'):
        done = subprocess.run([sys.executable, '-I', str(HERE / 'chief-wait-stream.py'), '--ack', str(self.inbox),
                               '--ack', str(seq), '--receipt', receipt], capture_output=True, text=True, env=self.env)
        self.assertEqual(done.returncode, 0, done.stderr)

    def served(self, out):
        self.until(lambda: 'kind=ack-stuck' in out.read_text() or ['K', '1'] in [row[:2] for row in self.rows()])

    def check_the_ack_is_held(self, *rows):
        self.log(*rows)
        self.ack(1)
        p, out = self.start()
        self.served(out)
        self.stop(p)
        self.assertEqual([row[:2] for row in self.rows() if row[0] == 'K'], [], 'acknowledged with no readable block')
        self.assertIn('kind=ack-stuck', out.read_text())
        self.assertTrue(self.path('ack-1.json').exists(), 'the request is kept for the retry')

    def test_an_ack_for_a_missing_owed_block_is_held(self):
        self.check_the_ack_is_held(self.wake(1, 'owed-actions'))

    def test_an_ack_for_an_owed_block_cut_before_its_bucket_is_held(self):
        self.check_the_ack_is_held(self.wake(1, 'owed-actions', 'WAKE owed-actions chief-notify=a1,a2\n'))

    def test_an_ack_for_a_block_of_another_kind_is_held(self):
        self.check_the_ack_is_held(self.wake(1, 'owed-actions', 'WAKE telegram a message\n'))

    def test_an_ack_for_a_missing_message_block_is_held(self):
        self.check_the_ack_is_held(self.wake(1, 'telegram'))

    def test_a_damaged_owed_list_is_held_for_retry(self):
        self.check_the_ack_is_held(self.wake(1, 'owed-actions', 'WAKE owed-actions chief-notify=a1\nowed-bucket=/nonexistent-bucket\n'))
        self.assertIn('owed list failed', self.path('ack-1.json.error').read_text())

    def test_an_ack_for_a_readable_block_of_its_kind_is_recorded(self):
        self.log(self.wake(1, 'telegram', 'WAKE telegram a message\n'))
        self.ack(1)
        p, out = self.start()
        self.served(out)
        self.stop(p)
        self.assertEqual([row[:2] for row in self.rows() if row[0] == 'K'], [['K', '1']])
        self.assertNotIn('ack-stuck', out.read_text())
        self.assertFalse(self.path('ack-1.json').exists())

    def test_rotation_keeps_what_a_pending_ack_needs(self):
        self.env['CHIEF_WAIT_STREAM_KEEP'] = '2'
        now = int(time.time())
        self.log(*[self.wake(n, 'telegram', f'WAKE telegram message {n}\n') for n in (1, 2, 3)],
                 f'D\t2\t{now}\trcpt-2', f'K\t2\t{now}\trcpt-2')
        self.ack(1)
        p, out = self.start(('--since', '0'))
        self.served(out)
        self.stop(p)
        kept = [row[:2] for row in self.rows()]
        self.assertNotIn('ack-stuck', out.read_text())
        self.assertIn(['K', '1'], kept, 'the accepted ack names a wake the rotation dropped')
        self.assertIn(['D', '2'], kept, 'a retained wake lost its delivery row')
        self.assertIn(['K', '2'], kept, 'a retained wake lost its acknowledgement row')
        again, _ = self.start(('--since', '0'))
        self.until(lambda: sum(row[0] == 'A' for row in self.rows()) >= 2)
        self.stop(again)
        kept = [row[:2] for row in self.rows()]
        self.assertNotIn(['W', '1'], kept)
        self.assertNotIn(['K', '1'], kept)
        self.assertFalse(self.path('wake-1').exists())

    def test_an_ack_and_a_rotation_take_turns_so_the_ack_is_never_lost(self):
        self.env['CHIEF_WAIT_STREAM_KEEP'] = '2'
        self.log(*[self.wake(n, 'telegram', f'WAKE telegram message {n}\n') for n in (1, 2, 3)])
        before = self.path('wakes').read_text()
        with self.path('ack.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            acking = subprocess.Popen([sys.executable, '-I', str(HERE / 'chief-wait-stream.py'), '--ack', str(self.inbox),
                                       '--ack', '1', '--receipt', 'rcpt-1'], stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT, text=True, env=self.env)
            p, out = self.start(('--since', '0'))
            time.sleep(1.5)
            self.assertIsNone(acking.poll(), 'an ack was written while a rotation could run')
            self.assertEqual(self.path('wakes').read_text(), before, 'a rotation ran while an ack could be written')
        said = acking.communicate(timeout=10)[0]
        if acking.returncode == 0:
            self.served(out)
            self.assertIn(['K', '1'], [row[:2] for row in self.rows()], 'an accepted ack lost its wake')
        else:
            self.assertEqual(acking.returncode, 2, said)
            self.assertIn('STREAM-REFUSED unknown-wake', said)
            self.assertFalse(self.path('ack-1.json').exists())
        self.stop(p)
        self.assertNotIn('ack-stuck', out.read_text())


class RefusedArm(StreamFixture):

    def setUp(self):
        super().setUp()
        self.lock = open(str(self.path('stream.lock')), 'a')
        self.addCleanup(self.lock.close)
        fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.path('wake-1').write_text('WAKE telegram ORIGINAL-WAKE-1\n')
        now = int(time.time())
        self.path('wakes').write_text(f'W\t1\t{now}\t77\ttelegram\t{self.path("wake-1")}\nP\t1\t{now}\t77\n')
        self.path('stream').write_text(f'sup={os.getpid()} sup_start=1 host=h boot=b seq=1\n')

    def snapshot(self):
        return {p.name: (p.read_bytes(), p.stat().st_mode) for p in sorted((self.root / 'consoles').iterdir()) if p.is_file()}

    def second_arm(self, hidden=None):
        before = self.snapshot()
        mode = hidden.stat().st_mode if hidden else None
        if hidden:
            hidden.chmod(0)
        try:
            done = subprocess.run([sys.executable, '-I', str(HERE / 'chief-wait-stream.py'), str(self.inbox), '--doc', str(self.doc),
                                   '--workers-from', str(self.fleet)], env=self.env, capture_output=True, text=True, timeout=30)
        finally:
            if hidden:
                hidden.chmod(mode)
        self.assertEqual(self.snapshot(), before, 'the refused arm changed the live supervisor files')
        self.assertEqual(done.returncode, 3, done.stdout + done.stderr)
        return done.stdout

    def test_a_second_arm_is_refused_and_writes_nothing(self):
        self.assertEqual(self.second_arm(), f'STREAM-REFUSED live-supervisor pid={os.getpid()}\n')

    @unittest.skipIf(os.geteuid() == 0, 'root reads a mode 000 file')
    def test_a_second_arm_is_refused_when_the_sidecar_is_unreadable(self):
        self.assertEqual(self.second_arm(self.path('stream')), 'STREAM-REFUSED live-supervisor pid=?\n')

    @unittest.skipIf(os.geteuid() == 0, 'root reads a mode 000 file')
    def test_a_second_arm_is_refused_when_the_lock_file_is_unreadable(self):
        self.assertEqual(self.second_arm(self.path('stream.lock')), 'STREAM-REFUSED before-lock PermissionError\n')


class WatchdogOwner(StreamFixture):

    def race(self, when):
        script = self.root / 'watchdog-race.py'
        script.write_text(WATCHDOG_RACE)
        done = subprocess.run([sys.executable, '-I', str(script), str(HERE / 'chief-wait-stream.py'), str(self.inbox), str(when)],
                              env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout.splitlines()[-1])

    def test_an_owner_that_publishes_before_the_final_check_is_never_signalled_for(self):
        seen = self.race(1)
        self.assertEqual((seen['kills'], seen['requests']), ([], []))
        self.assertTrue(seen['child_running'])
        self.assertEqual(seen['owner'], str(seen['me']))

    def test_an_owner_that_publishes_right_after_the_final_check_does_not_get_its_child_signalled(self):
        seen = self.race(2)
        self.assertEqual([request['owner'] for request in seen['requests']], [str(seen['dead'])],
                         'the watchdog requested a reap after the next owner had published itself')
        self.assertEqual(seen['kills'], [])
        self.assertFalse(seen['reap_left'], 'the reap request outlived the next owner')
        self.assertTrue(seen['publishers_done'])
        self.assertEqual(seen['owner'], str(seen['me']))


BOUNDS = {'CHIEF_WAIT_STREAM_SOFT_SEC': 1740, 'CHIEF_WAIT_STREAM_HARD_SEC': 1800,
          'CHIEF_WAIT_STREAM_BUSY_MAX_SEC': 7200, 'CHIEF_WAIT_STREAM_REAP_MAX_SEC': 1800,
          'CHIEF_WAIT_STREAM_ADOPT_SEC': 1800, 'CHIEF_WAIT_STREAM_KILL_GRACE_SEC': 60,
          'CHIEF_WAIT_STREAM_REPEAT_SEC': 1800}
WATCHDOG_BOUNDS = ('CHIEF_WAIT_STREAM_ADOPT_SEC', 'CHIEF_WAIT_STREAM_BUSY_MAX_SEC', 'CHIEF_WAIT_STREAM_REAP_MAX_SEC',
                   'CHIEF_WAIT_STREAM_KILL_GRACE_SEC')

SUPERVISOR_PROBE = r'''
import importlib.util, sys, threading, time
spec = importlib.util.spec_from_file_location('cws', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
mode = sys.argv[2]
if mode == 'unchecked':
    m.check_limits = lambda: None
if mode == 'step':
    real = time.time

    def step():
        time.sleep(1.0)
        time.time = lambda: real() - 3600
        m.clock.__defaults__ = (time.time,)
    threading.Thread(target=step, daemon=True).start()
sys.exit(m.Supervisor(sys.argv[3], sys.argv[4:]).run())
'''

WATCHDOG_AGE = r'''
import importlib.util, json, os, subprocess, sys, threading, time
from pathlib import Path
spec = importlib.util.spec_from_file_location('cws', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
inbox, mode = sys.argv[2], sys.argv[3]
side = inbox + '.wait.stream'
child = subprocess.Popen(['bash', '-c', 'sleep 600; :', 'chief-wait-x', inbox], start_new_session=True)
holder = subprocess.Popen(['bash', '-c', 'sleep 600; :', 'holder', inbox], start_new_session=True)
time.sleep(.3)
sup, start = (holder.pid, m.identity(holder.pid)) if mode in ('hung', 'alive') else (999999, 'x')
Path(side).write_text(f'sup={sup} sup_start={start} host={m.HOST} boot={m.BOOT} child={child.pid} '
                      f'child_start={m.identity(child.pid)} part={inbox}.wait.part-1-1 safe={time.time()} handoff=- seq=0\n')
limits = getattr(m, 'LIMITS', None)
if mode == 'hung' and limits is not None:
    for name in ('CHIEF_WAIT_STREAM_HARD_SEC', 'CHIEF_WAIT_STREAM_ADOPT_SEC', 'CHIEF_WAIT_STREAM_REAP_MAX_SEC'):
        limits[name] = (1, 1)
    limits['CHIEF_WAIT_STREAM_KILL_GRACE_SEC'] = (0.2, 0.2)
if mode == 'step':
    real = time.time

    def step():
        time.sleep(.5)
        time.time = lambda: real() - 3600
    threading.Thread(target=step, daemon=True).start()
began = time.monotonic()
rc = m.watchdog(inbox, str(sup), str(start))
took = round(time.monotonic() - began, 1)
try:
    child.wait(timeout=5)
except subprocess.TimeoutExpired:
    pass
print(json.dumps(dict(rc=rc, took=took, child_running=child.poll() is None,
                      hung=Path(inbox + '.wait.stream.hung').exists())))
'''


class StreamBounds(StreamFixture):

    def tearDown(self):
        for entry in Path('/proc').iterdir():
            if entry.name.isdigit() and int(entry.name) != os.getpid():
                try:
                    if os.fsencode(str(self.root)) in (entry / 'cmdline').read_bytes():
                        os.kill(int(entry.name), signal.SIGKILL)
                except OSError:
                    pass
        super().tearDown()

    def refusal(self, name, value):
        return f'STREAM-REFUSED bad-setting {name}={value!r} (allowed: a number above 0 and at most {BOUNDS[name]})\n'

    def fresh(self, n):
        inbox = self.root / f'consoles/bound{n}.md'
        inbox.touch()
        Path(str(inbox) + '.announced').touch()
        return inbox

    def arm(self, inbox, drop=(), **setting):
        out = self.root / (inbox.name + '.out')
        env = dict(self.env, **setting)
        for name in drop:
            env.pop(name, None)
        with out.open('w') as f:
            p = subprocess.Popen([sys.executable, '-I', str(HERE / 'chief-wait-stream.py'), str(inbox), '--doc', str(self.doc),
                                  '--workers-from', str(self.fleet)], env=env, stdout=f,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        self.procs.append((p, out))
        stream = Path(str(inbox) + '.wait.stream')
        end = time.monotonic() + 8
        while p.poll() is None and not stream.exists() and time.monotonic() < end:
            time.sleep(.05)
        started = p.poll() is None
        if started:
            Path(str(inbox) + '.wait.stop').touch()
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
        return p.returncode, out.read_text(), started

    def check_refused(self, n, name, value):
        inbox = self.fresh(n)
        code, text, started = self.arm(inbox, **{name: value})
        self.assertFalse(started, f'{name}={value!r} started the supervisor')
        self.assertEqual(code, 2)
        self.assertEqual(set(text.splitlines(keepends=True)), {self.refusal(name, value)})
        self.assertEqual([p.name for p in inbox.parent.glob(inbox.name + '.wait.*')], [], 'a refused start left state')

    def test_a_value_over_its_maximum_refuses(self):
        for n, (name, longest) in enumerate(BOUNDS.items()):
            for value in (str(longest + 1), '1e9', 'inf'):
                with self.subTest(setting=name, value=value):
                    self.check_refused(n, name, value)

    def test_zero_a_negative_an_empty_and_a_non_number_refuse(self):
        for n, name in enumerate(BOUNDS):
            for value in ('0', '-1', '-inf', 'abc', 'nan', '', '1,5'):
                with self.subTest(setting=name, value=value):
                    self.check_refused(n, name, value)

    def test_the_maximum_itself_starts(self):
        for n, (name, longest) in enumerate(BOUNDS.items()):
            with self.subTest(setting=name):
                extra = {'CHIEF_WAIT_STREAM_HARD_SEC': '1800'} if name == 'CHIEF_WAIT_STREAM_SOFT_SEC' else {}
                code, text, started = self.arm(self.fresh(n), **{name: str(longest)}, **extra)
                self.assertTrue(started, text)
                self.assertNotIn('STREAM-REFUSED', text)

    def test_unset_settings_start_on_their_defaults(self):
        code, text, started = self.arm(self.fresh(0), drop=BOUNDS)
        self.assertTrue(started, text)
        self.assertNotIn('STREAM-REFUSED', text)

    def test_soft_at_or_above_hard_refuses(self):
        soft, hard = 'CHIEF_WAIT_STREAM_SOFT_SEC', 'CHIEF_WAIT_STREAM_HARD_SEC'
        for n, (low, high) in enumerate((('100', '4'), ('4', '4'), ('1700', '1699.5'))):
            with self.subTest(soft=low, hard=high):
                inbox = self.fresh(n)
                code, text, started = self.arm(inbox, **{soft: low, hard: high})
                self.assertFalse(started, f'SOFT={low} HARD={high} started the supervisor')
                self.assertEqual(code, 2)
                self.assertEqual(set(text.splitlines(keepends=True)),
                                 {f'STREAM-REFUSED bad-setting {soft}={low!r} (must be below {hard}={high!r})\n'})
                self.assertEqual([p.name for p in inbox.parent.glob(inbox.name + '.wait.*')], [], 'a refused start left state')
        code, text, started = self.arm(self.fresh(9), **{soft: '4', hard: '4.5'})
        self.assertTrue(started, text)

    def watchdog(self, drop=(), **setting):
        inbox = self.fresh(0)
        fields = Path('/proc/self/stat').read_text().rsplit(')', 1)[1].split()
        err = self.root / 'watchdog.err'
        env = dict(self.env, **setting)
        for name in drop:
            env.pop(name, None)
        with err.open('w') as f:
            p = subprocess.Popen([sys.executable, '-I', str(HERE / 'chief-wait-stream.py'), '--watchdog', str(inbox),
                                  str(os.getpid()), fields[19]], env=env, stdout=subprocess.DEVNULL,
                                 stderr=f, start_new_session=True)
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            return None, err.read_text(), True
        return p.returncode, err.read_text(), False

    def test_the_watchdog_refuses_a_bound_that_is_too_long_zero_empty_or_not_finite(self):
        for name in WATCHDOG_BOUNDS:
            for value in (str(BOUNDS[name] + 1), '0', '-1', 'abc', '', 'nan', 'inf'):
                with self.subTest(setting=name, value=value):
                    code, text, running = self.watchdog(**{name: value})
                    self.assertFalse(running, f'a watchdog started with {name}={value!r}')
                    self.assertEqual(code, 2)
                    self.assertEqual(text, self.refusal(name, value))

    def test_the_watchdog_starts_at_the_maximum_and_on_the_defaults(self):
        for name in WATCHDOG_BOUNDS:
            with self.subTest(setting=name):
                code, text, running = self.watchdog(**{name: str(BOUNDS[name])})
                self.assertTrue(running, text)
        code, text, running = self.watchdog(drop=WATCHDOG_BOUNDS)
        self.assertTrue(running, text)

    def test_a_frozen_test_clock_does_not_skip_a_bound_outside_a_fixture(self):
        clock = self.root / 'frozen-clock'
        clock.write_text('1794800000')
        env = dict(self.env, CHIEF_WAIT_STREAM_TEST_CLOCK=str(clock), CHIEF_WAIT_STREAM_SOFT_SEC='.3',
                   CHIEF_WAIT_STREAM_HARD_SEC='1')
        env.pop('HIMMEL_TEST_FIXTURE')
        p, out = self.start(env=env)
        self.until(lambda: 'REARM' in out.read_text() or 'STOPPED' in out.read_text(), seconds=8)
        self.assertEqual(p.wait(timeout=6), 0)

    def ends_by_itself(self, env, seconds=8):
        p, out = self.start(env=env)
        try:
            return p.wait(timeout=seconds), out.read_text()
        except subprocess.TimeoutExpired:
            return None, out.read_text()

    def test_a_pause_setting_does_not_hold_the_supervisor(self):
        child = self.script('chief-wait-exit', 'exit 0\n')
        env = dict(self.env, CHIEF_WAIT_STREAM_CHILD=child, CHIEF_WAIT_STREAM_SOFT_SEC='1', CHIEF_WAIT_STREAM_HARD_SEC='2',
                   CHIEF_WAIT_STREAM_PAUSE_LOG='1')
        code, text = self.ends_by_itself(env)
        self.assertEqual(code, 0, 'PAUSE_LOG held the supervisor: ' + text)
        self.assertIn('REARM', text)

    def test_a_pause_setting_does_not_hold_the_supervisor_that_adopts_a_child(self):
        waiter = subprocess.Popen(['bash', '-c', 'sleep 60; :', 'chief-wait-adopted', str(self.inbox)], start_new_session=True)
        try:
            fields = Path(f'/proc/{waiter.pid}/stat').read_text().rsplit(')', 1)[1].split()
            boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
            self.path('stream').write_text(f'child={waiter.pid} child_start={fields[19]} host={socket.gethostname()} boot={boot} '
                                           f'part={self.path("part-9-1")} safe={time.monotonic()} handoff=- seq=0\n')
            env = dict(self.env, CHIEF_WAIT_STREAM_SOFT_SEC='1', CHIEF_WAIT_STREAM_HARD_SEC='2',
                       CHIEF_WAIT_STREAM_PAUSE_ADOPT='1')
            code, text = self.ends_by_itself(env)
            self.assertEqual(code, 0, 'PAUSE_ADOPT held the supervisor: ' + text)
            self.assertIn('child=busy', text)
        finally:
            os.killpg(waiter.pid, signal.SIGKILL)
            waiter.wait()

    def run_script(self, script, *args, seconds=10, **setting):
        path = self.root / 'bounds-probe.py'
        path.write_text(script)
        out = self.root / 'bounds-probe.out'
        env = {k: v for k, v in self.env.items() if not k.startswith('CHIEF_WAIT_STREAM_')}
        env.update(CHIEF_WAIT_STREAM_STDOUT_OK='1', CHIEF_WAIT_STREAM_KILL_GRACE_SEC='0.2', **setting)
        with out.open('w') as f:
            p = subprocess.Popen([sys.executable, '-I', str(path), str(HERE / 'chief-wait-stream.py'), *args], env=env,
                                 stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return p.wait(timeout=seconds), out.read_text()
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            return None, out.read_text()

    def supervisor_args(self, n):
        return (str(self.fresh(n)), '--doc', str(self.doc), '--workers-from', str(self.fleet))

    def test_the_hard_bound_is_checked_on_every_pass_of_the_loop(self):
        child = self.script('chief-wait-exit', 'exit 0\n')
        code, text = self.run_script(SUPERVISOR_PROBE, 'unchecked', *self.supervisor_args(0), seconds=12,
                                     CHIEF_WAIT_STREAM_CHILD=child, CHIEF_WAIT_STREAM_SOFT_SEC='100',
                                     CHIEF_WAIT_STREAM_HARD_SEC='4')
        self.assertEqual(code, 0, 'the supervisor ran past HARD: ' + text)
        self.assertIn('REARM', text)

    def test_a_backward_wall_clock_step_does_not_lengthen_the_supervisor(self):
        child = self.script('chief-wait-busy', 'sleep 600\n')
        code, text = self.run_script(SUPERVISOR_PROBE, 'step', *self.supervisor_args(0), seconds=12,
                                     CHIEF_WAIT_STREAM_CHILD=child, CHIEF_WAIT_STREAM_SOFT_SEC='2',
                                     CHIEF_WAIT_STREAM_HARD_SEC='3')
        self.assertEqual(code, 0, 'the supervisor outlived HARD after the wall clock stepped back: ' + text)
        self.assertIn('child=busy', text)

    def test_a_backward_wall_clock_step_does_not_lengthen_the_watchdog(self):
        code, text = self.run_script(WATCHDOG_AGE, str(self.fresh(0)), 'step', seconds=12, CHIEF_WAIT_STREAM_REAP_MAX_SEC='2')
        self.assertIsNotNone(code, 'the watchdog outlived its reap bound after the wall clock stepped back')
        seen = json.loads(text.splitlines()[-1])
        self.assertEqual((seen['rc'], seen['child_running'], seen['hung']), (0, False, True))

    def test_the_watchdog_ends_its_child_and_itself_when_its_supervisor_never_ends(self):
        code, text = self.run_script(WATCHDOG_AGE, str(self.fresh(0)), 'hung', seconds=12)
        self.assertIsNotNone(code, 'the watchdog is still waiting on a supervisor that never ends')
        seen = json.loads(text.splitlines()[-1])
        self.assertEqual((seen['rc'], seen['child_running'], seen['hung']), (0, False, True))
        self.assertLess(seen['took'], 8)

    def test_the_watchdog_keeps_waiting_while_its_supervisor_lives_inside_the_age_bound(self):
        inbox = self.fresh(0)
        code, text = self.run_script(WATCHDOG_AGE, str(inbox), 'alive', seconds=4)
        self.assertIsNone(code, 'the watchdog left a live supervisor early: ' + text)
        self.assertFalse(Path(str(inbox) + '.wait.stream.hung').exists())


GO_AUDIT_EVENT = r'''line=$(cat)
echo "$(date +%s.%N) $line" >> "$TEST_ROOT/events"
label=${line%% *}
[ ! -e "$TEST_ROOT/slow-$label" ] || exec sleep "$(cat "$TEST_ROOT/slow-$label")"
case "$line" in
*\ READY\ *)
    set -- $(printf '%s\n' "$line" | sed -nE 's/.* READY #?([0-9]+) ([0-9a-f]{40}).*/\1 \2/p')
    [ -n "${2:-}" ] || { echo 'ESCALATE marker-READY'; exit 10; }
    if ! grep -qx "GO-SENT $1 $2" "$TEST_ROOT/audit" 2>/dev/null; then echo "GO-SENT $1 $2" >> "$TEST_ROOT/audit"; fi
    echo 'HANDLED auto-go'; exit 0;;
*)
    if [ -e "$TEST_ROOT/refuse-cleanup" ]; then echo 'ESCALATE wrap-merged-failed rc=4 worker still alive'; exit 10; fi
    echo 'HANDLED wrap-merged'; exit 0;;
esac
'''

# A worker-event stand-in whose cleanup answers with the text in TEST_ROOT/refusal and rc 10.
REFUSAL_EVENT = r'''line=$(cat)
echo "$(date +%s.%N) $line" >> "$TEST_ROOT/events"
case "$line" in
*\ READY\ *) echo 'HANDLED auto-go'; exit 0;;
*) cat "$TEST_ROOT/refusal"; exit 10;;
esac
'''


class StackedWorker(StreamFixture):
    """Stacked-series and returning-worker service rows, with auto_go ON (the production setting of the relay)."""
    H = {n: str(n) * 40 for n in range(1, 10)}

    def setUp(self):
        super().setUp()
        self.env.update(HIMMEL_FLAG_AUTO_GO='1', CHIEF_WAIT_SERVICE_RETRY_SEC='1',
                        CHIEF_WAIT_STREAM_MAX_PER_MIN='100', CHIEF_WAIT_STREAM_REPEAT_SEC='0.001')
        self.env['CHIEF_WAIT_WORKER_EVENT'] = self.script('event', GO_AUDIT_EVENT)

    def worker(self, label, *lines):
        doc = self.root / f'{label}.md'
        doc.write_text(f'# {label}\n## Results\n' + ''.join(line + '\n' for line in lines))
        return doc

    def fleet_of(self, *labels):
        self.fleet.write_text(json.dumps(dict(workers=[
            dict(label=label, doc=str(self.root / f'{label}.md')) for label in labels])))

    def add(self, label, line):
        with (self.root / f'{label}.md').open('a') as f:
            f.write(line + '\n')

    def events(self):
        path = self.root / 'events'
        rows = [line.split(' ', 1) for line in path.read_text().splitlines()] if path.exists() else []
        return [(float(t), text) for t, text in rows]

    def rows(self, path):
        try:
            return path.read_text().splitlines()
        except FileNotFoundError:
            return []

    def seen(self, prefix):
        return [t for t, text in self.events() if text.startswith(prefix)]

    def audit(self):
        path = self.root / 'audit'
        return path.read_text().splitlines() if path.exists() else []

    def ready(self, label, pr):
        return f'- 10:{pr:02d} READY #{pr} {self.H[pr]}'

    def test_a_stacked_ready_after_a_handled_merged_is_relayed_in_order(self):
        self.worker('N1', self.ready('N1', 1))
        self.fleet_of('N1')
        p, _ = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.add('N1', '- 10:05 MERGED #1')
        self.until(lambda: self.seen('N1 MERGED #1') and 'N1 MERGED' in self.path('r0').read_text())
        self.add('N1', self.ready('N1', 2))
        self.until(lambda: self.seen(f'N1 READY #2 {self.H[2]}'), seconds=8)
        time.sleep(.6)
        self.stop(p)
        self.assertEqual([text for _, text in self.events()],
                         [f'N1 READY #1 {self.H[1]}', 'N1 MERGED #1', f'N1 READY #2 {self.H[2]}'])
        self.assertEqual(self.audit(), [f'GO-SENT 1 {self.H[1]}', f'GO-SENT 2 {self.H[2]}'])

    def test_a_refused_cleanup_is_retried_on_the_backoff_and_never_hides_the_next_ready(self):
        (self.root / 'refuse-cleanup').touch()
        self.worker('N1', self.ready('N1', 1))
        self.fleet_of('N1')
        p, _ = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.add('N1', '- 10:05 MERGED #1')
        self.until(lambda: len(self.seen('N1 MERGED #1')) >= 3, seconds=10)
        stamps = self.seen('N1 MERGED #1')
        # the existing retry window (CHIEF_WAIT_SERVICE_RETRY_SEC=1), never every 50 ms poll
        self.assertTrue(all(b - a >= .8 for a, b in zip(stamps, stamps[1:])), stamps)
        self.add('N1', self.ready('N1', 2))
        self.until(lambda: self.seen(f'N1 READY #2 {self.H[2]}'), seconds=8)
        settled = len(self.seen('N1 MERGED #1'))
        time.sleep(2.2)
        self.assertEqual(len(self.seen('N1 MERGED #1')), settled, 'a superseded MERGED is not retried')
        self.stop(p)
        self.assertEqual(self.audit(), [f'GO-SENT 1 {self.H[1]}', f'GO-SENT 2 {self.H[2]}'])

    def test_a_label_returning_with_a_shorter_document_gets_its_unhandled_ready_relayed(self):
        self.worker('N1', *[f'- 09:{n:02d} LIVE step {n}' for n in range(37)], self.ready('N1', 1))
        self.fleet_of('N1')
        p, _ = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.until(lambda: self.path('ready').exists() and self.path('ready').read_text() == 'N1\t40\n')
        self.fleet_of()
        self.until(lambda: 'N1' not in json.loads(self.path('ready-docs').read_text()))
        self.worker('N1', '- 10:30 LIVE restarted', self.ready('N1', 9))
        self.fleet_of('N1')
        self.until(lambda: self.seen(f'N1 READY #9 {self.H[9]}'), seconds=8)
        time.sleep(.6)
        self.stop(p)
        self.assertEqual(self.audit(), [f'GO-SENT 1 {self.H[1]}', f'GO-SENT 9 {self.H[9]}'])
        self.assertEqual(len(self.seen('N1 READY #9')), 1)

    def test_a_label_returning_with_a_longer_different_document_gets_its_unhandled_ready_relayed(self):
        self.worker('N1', '- 09:00 LIVE start', self.ready('N1', 1))
        self.fleet_of('N1')
        p, _ = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.until(lambda: self.path('ready').exists() and self.path('ready').read_text() == 'N1\t4\n')
        self.fleet_of()
        self.until(lambda: 'N1' not in json.loads(self.path('ready-docs').read_text()))
        # its READY sits on a line the old cursor already counted, and the document is not shorter
        self.worker('N1', self.ready('N1', 9), '- 10:31 LIVE a', '- 10:32 LIVE b', '- 10:33 LIVE c')
        self.fleet_of('N1')
        self.until(lambda: self.seen(f'N1 READY #9 {self.H[9]}'), seconds=8)
        time.sleep(.6)
        self.stop(p)
        self.assertEqual(self.audit(), [f'GO-SENT 1 {self.H[1]}', f'GO-SENT 9 {self.H[9]}'])
        self.assertEqual(len(self.seen('N1 READY #9')), 1)

    def test_a_torn_read_ending_at_a_handled_merged_never_relays_a_ready_twice(self):
        self.worker('N1', self.ready('N1', 1))
        self.fleet_of('N1')
        p, _ = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.add('N1', '- 10:05 MERGED #1')
        self.until(lambda: self.seen('N1 MERGED #1') and 'N1 MERGED' in self.path('r0').read_text())
        self.add('N1', self.ready('N1', 2))
        self.until(lambda: self.seen(f'N1 READY #2 {self.H[2]}'))
        self.until(lambda: self.path('ready').read_text() == 'N1\t5\n')
        # a read that shows only the first two bullets, then the whole document again
        torn = self.worker('N1', self.ready('N1', 1), '- 10:05 MERGED #1')
        time.sleep(.6)
        self.worker('N1', self.ready('N1', 1), '- 10:05 MERGED #1', self.ready('N1', 2))
        time.sleep(1.0)
        self.stop(p)
        self.assertEqual(len(self.seen('N1 READY #2')), 1)
        self.assertEqual(self.audit(), [f'GO-SENT 1 {self.H[1]}', f'GO-SENT 2 {self.H[2]}'])
        self.assertTrue(torn.exists())

    def test_a_refused_cleanup_is_retried_on_a_growing_ladder_and_holds_at_the_top(self):
        # Replaces the row that pinned the flat pace. Steps are the retry window times 1, 2, 6, 24, 60.
        self.env['CHIEF_WAIT_SERVICE_RETRY_SEC'] = '0.05'
        (self.root / 'refuse-cleanup').touch()
        self.worker('N1', self.ready('N1', 1))
        self.fleet_of('N1')
        p, _ = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.add('N1', '- 10:05 MERGED #1')
        self.until(lambda: len(self.seen('N1 MERGED #1')) >= 6, seconds=25)
        stamps = self.seen('N1 MERGED #1')[:6]
        gaps = [b - a for a, b in zip(stamps, stamps[1:])]
        self.stop(p)
        steps = [.05, .1, .3, 1.2, 3.0]
        for gap, step in zip(gaps, steps):
            self.assertGreaterEqual(gap, step * .85, gaps)
            self.assertLess(gap, step + 3.0, gaps)
        self.assertGreaterEqual(gaps[3], 1.0, gaps)
        self.assertGreaterEqual(gaps[4], 2.5, 'the top step holds')

    def test_a_changed_event_starts_the_ladder_over(self):
        self.env['CHIEF_WAIT_SERVICE_RETRY_SEC'] = '0.2'
        (self.root / 'refuse-cleanup').touch()
        self.worker('N1', self.ready('N1', 1))
        self.fleet_of('N1')
        p, _ = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.add('N1', '- 10:05 MERGED #1')
        self.until(lambda: len(self.seen('N1 MERGED #1')) >= 4, seconds=15)
        fourth = self.seen('N1 MERGED #1')[3]
        tries = self.path('le-N1.tries')  # the change must follow the relay's record of the fourth refusal
        self.until(lambda: tries.exists() and tries.read_text().split()[0] == '4', seconds=5)
        self.add('N1', '- 10:06 WRAPPED all done')  # the fifth gap would be 4.8 s on the ladder
        self.until(lambda: len(self.seen('N1 WRAPPED')) >= 2, seconds=15)
        stamps = self.seen('N1 WRAPPED')
        self.until(lambda: tries.read_text().split()[0] == '2', seconds=5)  # its own count: 1, then 2
        self.stop(p)
        self.assertLess(stamps[0] - fourth, 2.0, 'another event is tried again at the first step')
        self.assertLess(stamps[1] - stamps[0], 2.0, 'and its own climb starts over')

    def test_an_unrelated_document_change_does_not_start_the_ladder_over(self):
        # A live worker keeps appending LIVE bullets while the same refusal persists: the ladder still reaches
        # the top and wakes the chief, once.
        self.env['CHIEF_WAIT_SERVICE_RETRY_SEC'] = '0.05'
        (self.root / 'refuse-cleanup').touch()
        self.worker('N1', self.ready('N1', 1))
        self.fleet_of('N1')
        p, out = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.add('N1', '- 10:05 MERGED #1')
        end = time.monotonic() + 20
        n = 0
        while 'cleanup-still-refused' not in out.read_text() and time.monotonic() < end:
            n += 1
            self.add('N1', f'- 10:06 LIVE still working {n}')
            time.sleep(.1)
        self.assertIn('cleanup-still-refused', out.read_text(), f'{n} unrelated bullets, no wake')
        for _ in range(8):
            n += 1
            self.add('N1', f'- 10:06 LIVE still working {n}')
            time.sleep(.1)
        self.stop(p)
        text = out.read_text()
        self.assertEqual(text.count('cleanup-still-refused'), 1, text)
        self.assertGreaterEqual(len(self.seen('N1 MERGED #1')), 5)

    def test_the_top_step_wakes_the_chief_once_and_only_paces_after_it(self):
        self.env['CHIEF_WAIT_SERVICE_RETRY_SEC'] = '0.05'
        (self.root / 'refuse-cleanup').touch()
        self.worker('N1', self.ready('N1', 1))
        self.fleet_of('N1')
        p, out = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.add('N1', '- 10:05 MERGED #1')
        self.until(lambda: 'cleanup-still-refused' in out.read_text(), seconds=15)
        state = {name: self.path(name).read_text() for name in ('ready', 'ready-docs')}
        woke = len(self.seen('N1 MERGED #1'))
        self.until(lambda: len(self.seen('N1 MERGED #1')) > woke, seconds=12)  # the next try, at the top pace
        time.sleep(.6)
        self.stop(p)
        text = out.read_text()
        self.assertEqual(text.count('cleanup-still-refused'), 1, text)  # the wake itself, whatever its count: a repeat reads tries=6
        self.assertIn('cleanup-still-refused worker=N1 event=MERGED tries=5', text)
        self.assertIn('wrap-merged-failed rc=4', text)
        # nothing but pacing: the same bullet is offered again, and nothing is recorded as handled or moved
        self.assertEqual(set(row for _, row in self.events() if 'MERGED' in row), {'N1 MERGED #1'})
        self.assertNotIn('N1 MERGED', self.path('r0').read_text() if self.path('r0').exists() else '')
        self.assertEqual({name: self.path(name).read_text() for name in state}, state)

    def test_an_unrelated_change_after_the_top_wake_neither_restarts_the_ladder_nor_wakes_again(self):
        self.env['CHIEF_WAIT_SERVICE_RETRY_SEC'] = '0.05'
        (self.root / 'refuse-cleanup').touch()
        self.worker('N1', self.ready('N1', 1))
        self.fleet_of('N1')
        p, out = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.add('N1', '- 10:05 MERGED #1')
        self.until(lambda: 'cleanup-still-refused' in out.read_text(), seconds=15)
        woke = len(self.seen('N1 MERGED #1'))
        self.add('N1', '- 10:06 LIVE still working')
        self.until(lambda: len(self.seen('N1 MERGED #1')) > woke, seconds=12)
        stamps = self.seen('N1 MERGED #1')
        time.sleep(.6)
        self.stop(p)
        self.assertGreaterEqual(stamps[woke] - stamps[woke - 1], 2.5, 'the top pace holds: the climb did not start over')
        self.assertEqual(out.read_text().count('cleanup-still-refused'), 1, out.read_text())

    def test_a_new_event_after_the_top_wake_gets_a_wake_of_its_own(self):
        self.env['CHIEF_WAIT_SERVICE_RETRY_SEC'] = '0.05'
        (self.root / 'refuse-cleanup').touch()
        self.worker('N1', self.ready('N1', 1))
        self.fleet_of('N1')
        p, out = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.add('N1', '- 10:05 MERGED #1')
        self.until(lambda: 'cleanup-still-refused worker=N1 event=MERGED' in out.read_text(), seconds=15)
        self.add('N1', '- 10:06 WRAPPED all done')
        self.until(lambda: 'cleanup-still-refused worker=N1 event=WRAPPED' in out.read_text(), seconds=15)
        time.sleep(.6)
        self.stop(p)
        text = out.read_text()
        self.assertEqual(text.count('cleanup-still-refused worker=N1 event=MERGED'), 1, text)
        self.assertEqual(text.count('cleanup-still-refused worker=N1 event=WRAPPED'), 1, text)

    def test_a_success_ends_the_ladder(self):
        self.env['CHIEF_WAIT_SERVICE_RETRY_SEC'] = '0.05'
        (self.root / 'refuse-cleanup').touch()
        self.worker('N1', self.ready('N1', 1))
        self.fleet_of('N1')
        p, _ = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.add('N1', '- 10:05 MERGED #1')
        tries = self.path('le-N1.tries')
        self.until(lambda: tries.exists() and int(tries.read_text().split()[0]) >= 3, seconds=10)
        (self.root / 'refuse-cleanup').unlink()
        self.until(lambda: 'N1 MERGED' in (self.path('r0').read_text() if self.path('r0').exists() else ''), seconds=15)
        self.assertFalse(tries.exists())
        attempts = len(self.seen('N1 MERGED #1'))
        time.sleep(.8)
        self.assertEqual(len(self.seen('N1 MERGED #1')), attempts, 'a handled bullet is not offered again')
        (self.root / 'refuse-cleanup').touch()  # a later refusal starts at the first step
        self.add('N1', '- 10:07 MERGED #2')
        self.until(lambda: tries.exists(), seconds=10)
        self.assertEqual(tries.read_text().split()[0], '1')
        self.stop(p)

    def test_a_waiter_restart_keeps_the_step(self):
        self.env['CHIEF_WAIT_SERVICE_RETRY_SEC'] = '0.2'
        (self.root / 'refuse-cleanup').touch()
        self.worker('N1', self.ready('N1', 1))
        self.fleet_of('N1')
        p, _ = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.add('N1', '- 10:05 MERGED #1')
        self.until(lambda: len(self.seen('N1 MERGED #1')) >= 4, seconds=15)
        fourth = self.seen('N1 MERGED #1')[3]  # the next gap is 4.8 s
        self.stop(p)
        again, _ = self.start()
        self.until(lambda: len(self.seen('N1 MERGED #1')) >= 5, seconds=15)
        fifth = self.seen('N1 MERGED #1')[4]
        self.stop(again)
        self.assertGreaterEqual(fifth - fourth, 4.2, 'a restart does not climb down to the first step')

    def test_slow_cleanup_delays_only_itself_and_the_inbox_and_ready_follow_at_once(self):
        self.worker('N1', '- 10:00 WRAPPED no PR')
        self.worker('N2', self.ready('N2', 2))
        self.fleet_of('N1', 'N2')
        (self.root / 'slow-N1').write_text('1.5')
        self.env['CHIEF_WAIT_INTERVAL'] = '180'
        p, out = self.start()
        self.until(lambda: self.seen('N1 WRAPPED'))
        started = self.seen('N1 WRAPPED')[0]
        self.inbox.write_text('operator during the slow cleanup\n')
        self.until(lambda: self.seen(f'N2 READY #2 {self.H[2]}') and 'WAKE#1 telegram' in out.read_text(), seconds=8)
        gap = self.seen(f'N2 READY #2 {self.H[2]}')[0] - started
        self.assertGreaterEqual(gap, 1.4, 'the service is serial: N2 waits for the cleanup it started behind')
        self.assertLess(gap, 4.0, 'and is served right after it, not after another full tick')
        self.stop(p)
        self.assertEqual(len(self.seen('N1 WRAPPED')), 1)
        self.assertEqual(self.audit(), [f'GO-SENT 2 {self.H[2]}'])

    def test_cleanup_beyond_its_bound_is_killed_reported_once_and_does_not_starve_peers(self):
        shim = self.root / 'shim'
        shim.mkdir()
        real = subprocess.run(['bash', '-c', 'command -v timeout'], capture_output=True, text=True).stdout.strip()
        timeout = shim / 'timeout'
        timeout.write_text('#!/usr/bin/env bash\n'
                           'if [ "$#" -ge 5 ] && [ "$1" = -k ] && [ "$2" = 5 ] && [ "$3" = 240 ] && [ "$4" = bash ] '
                           '&& [ "$5" = "$CHIEF_WAIT_WORKER_EVENT" ]; then shift 3; exec ' + real + ' -k 1 2 "$@"; fi\n'
                           'exec ' + real + ' "$@"\n')
        timeout.chmod(0o755)
        self.env['PATH'] = str(shim) + ':' + self.env['PATH']
        self.worker('N1', '- 10:00 WRAPPED no PR')
        self.worker('N2', self.ready('N2', 2))
        self.fleet_of('N1', 'N2')
        (self.root / 'slow-N1').write_text('30')
        p, out = self.start()
        self.until(lambda: 'relay-timeout N1 rc=124' in out.read_text(), seconds=10)
        self.until(lambda: self.seen(f'N2 READY #2 {self.H[2]}'), seconds=10)
        time.sleep(.6)
        self.stop(p)
        self.assertEqual(out.read_text().count('relay-timeout N1'), 1)
        self.assertEqual(len(self.seen('N1 WRAPPED')), 1, 'a bounded-out cleanup is reported, not rerun')
        self.assertEqual(self.audit(), [f'GO-SENT 2 {self.H[2]}'])

    def test_successor_chief_replays_each_worker_once_through_the_relay(self):
        self.worker('N1', self.ready('N1', 1))
        self.worker('N2', self.ready('N2', 2))
        self.fleet_of('N1', 'N2')
        p, _ = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}') and self.seen(f'N2 READY #2 {self.H[2]}'))
        self.stop(p)
        self.assertEqual(self.audit(), [f'GO-SENT 1 {self.H[1]}', f'GO-SENT 2 {self.H[2]}'])
        self.add('N2', self.ready('N2', 3))
        successor = self.root / 'consoles/chief-b.md'
        successor.touch()
        Path(str(successor) + '.announced').touch()
        self.env['CHIEF_WAIT_TRACKER'] = self.script('tracker', 'echo "COMPLETE 2/2"\n')
        output = self.root / 'out-successor'
        with output.open('w') as out:
            q = subprocess.Popen(['bash', str(HERE / 'chief-wait.sh'), str(successor), '--stream',
                                  '--doc', str(self.doc), '--workers-from', str(self.fleet),
                                  '--succession', 'chief-b'], env=self.env, stdout=out,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        self.procs.append((q, output))
        self.until(lambda: self.seen(f'N2 READY #3 {self.H[3]}') and 'WAKE#' in output.read_text(), seconds=10)
        time.sleep(1.0)
        q.terminate()
        q.wait(timeout=6)
        self.assertEqual(len(self.seen(f'N1 READY #1 {self.H[1]}')), 2)
        self.assertEqual(len(self.seen(f'N2 READY #2 {self.H[2]}')), 1)
        self.assertEqual(len(self.seen(f'N2 READY #3 {self.H[3]}')), 1)
        self.assertEqual(self.audit(), [f'GO-SENT 1 {self.H[1]}', f'GO-SENT 2 {self.H[2]}',
                                        f'GO-SENT 3 {self.H[3]}'])
        self.assertEqual(output.read_text().count('succession complete'), 1)

    def test_the_successor_replay_leaves_no_writer_behind_for_tearDown_on_two_runs(self):
        writer = ('if [ ! -e "$TEST_ROOT/writer-started" ]; then touch "$TEST_ROOT/writer-started"\n'
                  '  ( n=0; while [ "$n" -lt 3000 ]; do echo x >> "$TEST_ROOT/consoles/late-$n"; n=$((n + 1)); sleep .002; done ) '
                  '>/dev/null 2>&1 &\nfi\n')

        class Loaded(StackedWorker):
            def setUp(self):
                super().setUp()
                body = Path(self.env['CHIEF_WAIT_WORKER_EVENT']).read_text().split('\n', 1)
                self.script('event', body[1].replace('line=$(cat)', 'line=$(cat)\n' + writer, 1))

        self.maxDiff = None
        for attempt in (1, 2):
            result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(
                unittest.TestSuite([Loaded('test_successor_chief_replays_each_worker_once_through_the_relay')]))
            self.assertEqual((result.testsRun, [e for _, e in result.errors], [f for _, f in result.failures]), (1, [], []), f'run {attempt}')

    def relay_rows(self):
        path = self.path('relaylog')
        lines = path.read_text().splitlines() if path.exists() else []
        return [dict(part.split('=', 1) for part in line.split()) for line in lines]

    def test_a_relayed_event_logs_how_long_it_was_pending_and_how_long_its_handler_took(self):
        self.worker('N1', self.ready('N1', 1))
        self.worker('N2', self.ready('N2', 2))
        self.fleet_of('N1', 'N2')
        (self.root / 'slow-N1').write_text('1.0')
        p, _ = self.start()
        self.until(lambda: len(self.relay_rows()) >= 2, seconds=10)
        time.sleep(.6)
        self.stop(p)
        rows = self.relay_rows()
        # once per relayed event, and the idle passes before and after wrote nothing
        self.assertEqual(sorted(r['label'] for r in rows), ['N1', 'N2'])
        n1, n2 = {r['label']: r for r in rows}['N1'], {r['label']: r for r in rows}['N2']
        self.assertEqual((n1['marker'], n1['rc'], n2['marker'], n2['rc']), ('READY', '0', 'READY', '0'))
        self.assertTrue(.9 <= float(n1['handler']) < 3.0, n1)
        self.assertLess(float(n2['handler']), .8)
        self.assertLess(float(n1['pending']), .8)
        self.assertGreaterEqual(float(n2['pending']), .9, 'N2 waited behind the slow handler of N1')

    def test_every_refused_attempt_is_logged_with_its_own_pending_age(self):
        (self.root / 'refuse-cleanup').touch()
        self.worker('N1', self.ready('N1', 1))
        self.fleet_of('N1')
        p, _ = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.add('N1', '- 10:05 MERGED #1')
        self.until(lambda: len([r for r in self.relay_rows() if r['marker'] == 'MERGED']) >= 3, seconds=10)
        self.stop(p)
        merged = [r for r in self.relay_rows() if r['marker'] == 'MERGED']
        self.assertTrue(all(r['rc'] == '10' for r in merged), merged)
        ages = [float(r['pending']) for r in merged]
        self.assertEqual(ages, sorted(ages))
        self.assertLess(ages[0], .5)
        self.assertGreater(ages[2] - ages[0], 1.5, 'each attempt carries the age of the event it retried')
        self.assertIn(len(merged), (len(self.seen('N1 MERGED #1')), len(self.seen('N1 MERGED #1')) - 1))

    def test_an_idle_pass_logs_nothing(self):
        self.worker('N1', '- 10:00 LIVE working')
        self.fleet_of('N1')
        p, _ = self.start()
        self.armed()
        time.sleep(1.5)
        self.stop(p)
        self.assertFalse(self.path('relaylog').exists())

    def test_the_first_wake_block_of_a_fresh_inbox_holds_no_shell_error(self):
        # the first worker-event call of an inbox runs before its relay log exists; probing the missing file must stay silent
        p, out = self.refused_with('ESCALATE wrap-merged-failed rc=4 worker still alive')
        self.until(lambda: 'cleanup-still-refused' in out.read_text(), seconds=15)
        self.stop(p)
        for name, text in (('the wake block', self.path('wake-1').read_text()), ('the stream output', out.read_text())):
            self.assertNotIn('No such file', text, name)
            self.assertNotIn('chief-wait.sh: line', text, name)

    def test_the_relay_log_is_bounded_by_size_with_one_rotated_copy(self):
        # the kit's other size-capped log (the classifier denial log) rotates to <log>.1 past 1 MiB
        import re
        row = re.compile(r'^start=\d+ label=\S+ marker=\S+ pending=\d+\.\d\d handler=\d+\.\d\d rc=\d+$')
        seed = lambda label: f'start=1 label={label} marker=READY pending=0.00 handler=0.00 rc=0\n' * 18000
        log, rotated = self.path('relaylog'), self.path('relaylog.1')
        first = seed('N8')
        self.assertGreater(len(first), 1048576)
        log.write_text(first)
        self.worker('N1', self.ready('N1', 1))
        self.fleet_of('N1')
        p, _ = self.start()
        self.until(lambda: rotated.exists() and log.exists(), seconds=10)
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.assertEqual(rotated.read_text(), first, 'the old generation is kept whole')
        live = log.read_text().splitlines()
        self.assertEqual(len(live), 1)
        self.assertEqual(live[0].split()[1:3], ['label=N1', 'marker=READY'])
        second = seed('N9')  # the next rotation replaces the copy: at most two files ever exist
        log.write_text(second)
        self.add('N1', '- 10:05 MERGED #1')
        self.until(lambda: rotated.read_text() == second and any(' marker=MERGED ' in r for r in self.rows(log)), seconds=10)
        self.stop(p)
        for path in (log, rotated):
            self.assertTrue(all(row.match(r) for r in path.read_text().splitlines()), f'a torn line in {path.name}')
        # only the log was trimmed: what the waiter decides from is as the two relays left it
        self.assertEqual(self.path('ready').read_text(), 'N1\t3\n')
        self.assertEqual(sorted(path.name for path in self.root.glob('consoles/*relaylog*')),
                         ['chief.md.wait.relaylog', 'chief.md.wait.relaylog.1'])


    def refused_with(self, text):
        (self.root / 'refusal').write_text(text + '\n')
        self.env['CHIEF_WAIT_WORKER_EVENT'] = self.script('event', REFUSAL_EVENT)
        self.env['CHIEF_WAIT_SERVICE_RETRY_SEC'] = '0.05'
        self.worker('N1', self.ready('N1', 1))
        self.fleet_of('N1')
        p, out = self.start()
        self.until(lambda: self.seen(f'N1 READY #1 {self.H[1]}'))
        self.add('N1', '- 10:05 MERGED #1')
        return p, out

    def check_a_failure_after_the_close_is_reported(self, rc, step):
        line = f'ESCALATE wrap-merged-failed rc={rc} wrap-merged: step {step}'
        p, out = self.refused_with(line)
        self.until(lambda: line in out.read_text(), seconds=10)
        time.sleep(1.0)
        self.stop(p)
        self.assertEqual(out.read_text().count(line), 1, out.read_text())
        self.assertEqual(len(self.seen('N1 MERGED #1')), 1, 'the window is already closed: nothing to retry')
        self.assertIn('N1 MERGED', self.path('r0').read_text(), 'reported once, then recorded')

    def test_a_log_failure_after_the_close_wakes_the_chief_and_is_not_retried(self):
        self.check_a_failure_after_the_close_is_reported(6, 'log failed: append-results.sh')

    def test_a_board_failure_after_the_close_wakes_the_chief_and_is_not_retried(self):
        self.check_a_failure_after_the_close_is_reported(7, 'board failed: board.mjs --doc chief.md --changed')

    def test_a_refused_close_inside_the_wrap_is_still_retried_quietly(self):
        p, out = self.refused_with('ESCALATE wrap-merged-failed rc=6 wrap-merged: step close-wrapped-worker failed: '
                                   'close-wrapped-worker.sh exited 6')
        self.until(lambda: len(self.seen('N1 MERGED #1')) >= 3, seconds=10)
        self.stop(p)
        self.assertNotIn('wrap-merged-failed', out.read_text())


    ASK = 'T3ASK-019e2c1a-2026-11-25'

    def t3_fleet(self, **extra):
        self.worker('N1', '- 09:00 LIVE — started')
        self.fleet.write_text(json.dumps(dict(workers=[
            dict(label='N1', doc=str(self.root / 'N1.md')),
            dict(label=self.ASK, doc=str(self.root / f'{self.ASK}.md'), lane='t3', lockless=True,
                 t3_thread='019e2c1a-1111', t3_notice='sent', **extra)])))

    def wake_text(self):
        return ''.join(f.read_text() for f in sorted(self.root.glob('consoles/*.wait.wake-*')))

    def test_a_ready_on_an_ask_row_wakes_ask_ready_and_calls_no_worker_event(self):
        self.worker(self.ASK, self.ready(self.ASK, 5))
        self.t3_fleet(t3_kind='ask')
        p, _ = self.start()
        self.until(lambda: f'WAKE t3-relay ask-ready {self.ASK}' in self.wake_text(), seconds=10)
        time.sleep(1.5)
        self.stop(p)
        self.assertEqual(self.wake_text().count(f'WAKE t3-relay ask-ready {self.ASK}'), 1, self.wake_text())
        self.assertEqual(self.events(), [], 'worker-event (and so auto-go) was called for an ask row')
        self.assertEqual(self.audit(), [])

    def test_a_blocked_resolve_on_an_ask_row_wakes_ask_resolve_and_no_resolve_wake(self):
        self.worker(self.ASK, '- 09:20 BLOCKED resolve 5999 PRRT_kwDOabc123')
        self.t3_fleet(t3_kind='ask')
        p, _ = self.start()
        self.until(lambda: f'WAKE t3-relay ask-resolve {self.ASK}' in self.wake_text(), seconds=10)
        time.sleep(1.5)
        self.stop(p)
        text = self.wake_text()
        self.assertEqual(text.count(f'WAKE t3-relay ask-resolve {self.ASK}'), 1, text)
        self.assertNotIn('WAKE resolve', text)
        self.assertEqual(self.events(), [])

    def test_a_ready_on_a_plain_t3_row_still_reaches_worker_event(self):
        self.worker(self.ASK, self.ready(self.ASK, 5))
        self.t3_fleet()
        p, _ = self.start()
        self.until(lambda: self.seen(f'READY #5 {self.H[5]} {self.ASK}'), seconds=10)
        self.stop(p)
        self.assertNotIn('WAKE t3-relay ask-ready', self.wake_text())


class IdlePoll(StreamFixture):
    """The service loop's idle backoff: after a run of empty passes it sleeps longer, and only that."""

    def setUp(self):
        super().setUp()
        import shutil
        shim = self.root / 'shim'
        shim.mkdir()
        (shim / 'sleep').write_text(f'#!/bin/sh\necho "$(date +%s.%N) $1" >> "$TEST_ROOT/sleeps"\nexec {shutil.which("sleep")} "$@"\n')
        (shim / 'sleep').chmod(0o755)
        self.env['PATH'] = f'{shim}:{self.env["PATH"]}'
        self.env.update(HIMMEL_FLAG_AUTO_GO='1', CHIEF_WAIT_POLL_SEC='0.05', CHIEF_WAIT_IDLE_POLL_SEC='0.5',
                        CHIEF_WAIT_IDLE_PASSES='5')
        self.env['CHIEF_WAIT_WORKER_EVENT'] = self.script('event', 'echo "$(date +%s.%N)" >> "$TEST_ROOT/events"\ncat > /dev/null\necho HANDLED auto-go\n')
        self.doc1 = self.root / 'N1.md'
        self.doc1.write_text('# N1\n## Results\n- 09:00 LIVE start\n')
        self.fleet.write_text(json.dumps(dict(workers=[dict(label='N1', doc=str(self.doc1))])))

    def sleeps(self, after=0.0):
        path = self.root / 'sleeps'
        rows = [line.split() for line in path.read_text().splitlines()] if path.exists() else []
        return [arg for ts, arg in rows if float(ts) > after]

    def slow(self, count):
        return lambda: self.sleeps().count('0.5') >= count

    def post_ready(self, pr=1):
        with self.doc1.open('a') as f:
            f.write(f'- 10:00 READY #{pr} ' + str(pr) * 40 + '\n')

    def test_the_poll_grows_only_after_a_run_of_empty_passes(self):
        p, _ = self.start()
        self.until(self.slow(3))
        self.stop(p)
        seen = self.sleeps()
        self.assertEqual(seen[:5], ['0.05'] * 5, 'five passes at the poll, the first of them the tick')
        self.assertTrue(all(arg == '0.5' for arg in seen[5:]), seen)

    def test_the_poll_returns_on_the_first_event(self):
        p, _ = self.start()
        self.until(self.slow(2))
        self.post_ready()
        self.until(lambda: (self.root / 'events').exists())
        at = float((self.root / 'events').read_text().split()[0])
        self.until(lambda: len(self.sleeps(at)) >= 8, seconds=10)
        self.stop(p)
        after = self.sleeps(at)
        # the pass that served the event, then the run of empty passes at the poll, then the idle poll again
        self.assertEqual(after[:6], ['0.05'] * 6, after)
        self.assertEqual(after[6], '0.5', after)

    def test_an_event_during_a_slow_interval_is_served_on_the_next_pass(self):
        p, _ = self.start()
        self.until(self.slow(2))
        self.post_ready(1)
        self.until(lambda: (self.root / 'events').exists())
        at = float((self.root / 'events').read_text().split()[0])
        self.until(lambda: self.sleeps(at).count('0.5') >= 1, seconds=10)
        began = float(next(line.split()[0] for line in (self.root / 'sleeps').read_text().splitlines()
                           if float(line.split()[0]) > at and line.split()[1] == '0.5'))
        self.post_ready(2)
        self.until(lambda: len((self.root / 'events').read_text().splitlines()) >= 2)
        self.stop(p)
        served = float((self.root / 'events').read_text().splitlines()[1].split()[0]) - began
        self.assertLess(served, 0.5 + 0.4, 'one idle interval, plus the pass')

    def test_the_idle_poll_is_never_shorter_than_the_poll(self):
        self.env['CHIEF_WAIT_IDLE_POLL_SEC'] = '0.01'
        p, _ = self.start()
        self.until(lambda: len(self.sleeps()) >= 14)
        self.stop(p)
        self.assertEqual(set(self.sleeps()), {'0.05'})

    def test_the_poll_backs_off_in_handover_mode_after_an_event(self):
        # a handover marker appears right after a service pass that offered an event; that offer was work of that
        # pass only, so the passes that follow (which skip the service) are empty and the poll must back off
        marker = self.inbox.parent / (self.inbox.name + '.handover')
        self.env['CHIEF_WAIT_WORKER_EVENT'] = self.script(
            'event', f'echo "$(date +%s.%N)" >> "$TEST_ROOT/events"\ncat > /dev/null\ntouch "{marker}"\necho HANDLED auto-go\n')
        p, _ = self.start()
        self.until(self.slow(2))
        self.post_ready()
        self.until(lambda: (self.root / 'events').exists())
        at = float((self.root / 'events').read_text().split()[0])
        self.until(lambda: self.sleeps(at).count('0.5') >= 2, seconds=10)
        self.stop(p)
        after = self.sleeps(at)
        self.assertEqual(after[:6], ['0.05'] * 6, after)
        self.assertEqual(after[6], '0.5', after)

    def test_a_malformed_idle_poll_falls_back_to_the_default_and_does_not_spin(self):
        self.env['CHIEF_WAIT_IDLE_POLL_SEC'] = '1.2.3'
        p, _ = self.start()
        self.until(lambda: any(arg in ('1', '1.2.3') for arg in self.sleeps()), seconds=10)
        time.sleep(1.2)
        self.stop(p)
        seen = self.sleeps()
        self.assertNotIn('1.2.3', seen, 'a value sleep rejects was used')
        self.assertIn('1', seen)
        self.assertLess(len(seen), 40, 'a rejected sleep would spin the loop')

    def test_a_due_tick_puts_the_poll_back(self):
        self.env['CHIEF_WAIT_INTERVAL'] = '3'
        p, _ = self.start()

        def runs():
            out = []
            for arg in self.sleeps():
                if out and out[-1][0] == arg:
                    out[-1][1] += 1
                else:
                    out.append([arg, 1])
            return out
        self.until(lambda: len(runs()) >= 4, seconds=15)
        self.stop(p)
        seen = runs()
        self.assertEqual(seen[0], ['0.05', 5])
        self.assertEqual(seen[1][0], '0.5')
        self.assertEqual(seen[2], ['0.05', 5], 'the tick that fell due: five passes at the poll again')
        self.assertEqual(seen[3][0], '0.5')

    def test_unusable_settings_fall_back_to_the_defaults(self):
        self.env.update(CHIEF_WAIT_IDLE_POLL_SEC='soon', CHIEF_WAIT_IDLE_PASSES='many')
        p, _ = self.start()
        self.until(lambda: '1' in self.sleeps(), seconds=10)
        self.stop(p)
        seen = self.sleeps()
        self.assertEqual(seen[:10], ['0.05'] * 10, 'ten empty passes by default')
        self.assertEqual(seen[10], '1')


if __name__ == '__main__':
    unittest.main()
