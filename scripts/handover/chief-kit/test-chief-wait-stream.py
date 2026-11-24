"""Exercise the real supervisor/child/control routes using offline dependencies."""
import io
import json
import os
from pathlib import Path
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
safe_point = mod.safe_point
publish = mod.Supervisor.publish


def after_one_wake(self):
    acknowledge(self)
    if not armed and self.wakes >= 1 and self.proc is not None and self.proc.poll() is None:
        armed.append(self)
        self.started -= float(os.environ['CHIEF_WAIT_STREAM_HARD_SEC']) + 1


def touched_after_the_sample(data, inbox):
    if armed and not fired.exists():
        stop.touch()
        armed[0].proc.wait(timeout=30)
        fired.write_text(str(data['child']))
        return ''
    return safe_point(data, inbox)


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
    mod.safe_point = touched_after_the_sample
else:
    mod.Supervisor.publish = honoured_during_adoption
sys.exit(mod.main())
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
        root, found = str(self.root).encode(), []
        for entry in Path('/proc').iterdir():
            if entry.name.isdigit():
                try:
                    fields = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
                    named = root in (entry / 'cmdline').read_bytes()
                except (OSError, IndexError):
                    continue
                if fields[0] != 'Z' and (named or int(fields[3]) in sessions):
                    found.append(int(entry.name))
                    if named:
                        sessions.add(int(fields[3]))
        sessions.discard(os.getsid(0))
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

    def test_repeat_and_flood_limits_keep_full_blocks(self):
        child = self.script('chief-wait-stub', "echo 'WAKE fixture repeat'\necho 'full detail retained'\n")
        env = dict(self.env, CHIEF_WAIT_STREAM_CHILD=child)
        p, out = self.start(env=env)
        self.assertEqual(p.wait(timeout=5), 0)
        self.assertEqual(out.read_text().count('WAKE#'), 2)
        self.assertIn('reason=repeat', out.read_text())
        self.assertIn('full detail retained', self.path('wake-2').read_text())
        self.assertNotIn('full detail retained', out.read_text())
        env['CHIEF_WAIT_STREAM_REPEAT_SEC'] = '0'
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
        env = dict(self.env, CHIEF_WAIT_STREAM_PAUSE_LOG='1')
        p, _ = self.start(env=env)
        self.armed()
        self.inbox.write_text('record before print\n')
        self.until(lambda: bool(list(self.root.glob('consoles/*.wait.part-*'))) and
                   any('WAKE telegram' in part.read_text() for part in self.root.glob('consoles/*.wait.part-*')))
        p.kill()
        p.wait(timeout=3)
        time.sleep(.5)
        again, out = self.start(('--since', '0'))
        self.until(lambda: 'REPLAY seqs=1-1 n=1' in out.read_text())
        self.assertNotIn('live-supervisor', out.read_text())
        self.stop(again)

    def test_pid_reuse_is_never_adopted_or_signalled(self):
        unrelated = subprocess.Popen(['sleep', '30'])
        try:
            self.path('stream').write_text(f'child={unrelated.pid} child_start=wrong host={socket.gethostname()} boot={Path("/proc/sys/kernel/random/boot_id").read_text().strip()} seq=0\n')
            p, _ = self.start()
            self.until(lambda: self.state().get('sup') == str(p.pid) and self.state().get('child') != str(unrelated.pid))
            self.stop(p)
            self.assertIsNone(unrelated.poll())
        finally:
            unrelated.terminate()
            unrelated.wait()

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
        self.env['CHIEF_WAIT_OWED_SEND'] = self.script('send', 'echo queued\n')
        self.env['CHIEF_WAIT_OPERATOR_RETRY_SEC'] = '1'
        p, out = self.start()
        self.until(lambda: 'owed-actions' in out.read_text())
        self.assertIn('operator-delivery-pending', self.path('wake-1').read_text())
        self.assertEqual(len(ledger.read_text().splitlines()), 1)
        # Simulate the existing sender's real receipt arriving after its caller
        # lost the response; the service must reconcile rather than resend.
        with self.doc.open('a') as f:
            f.write('- DELIVERED t2-o1 msg=42 chat=123\n')
        self.until(lambda: '"op":"close"' in ledger.read_text())
        self.assertIn('telegram-msg-42', ledger.read_text())
        self.stop(p)

    def test_busy_consumer_fifteen_simulated_minutes_without_ack(self):
        # Advance the child's wall clock while the consumer remains busy and
        # sends no receipt/ack. This does not simulate native Monitor delivery.
        clock = self.root / 'clock'
        clock.write_text('1794800000')
        bindir = self.root / 'bin'
        bindir.mkdir()
        self.script('date', 'if [ "${1:-}" = +%s ]; then cat "$TEST_ROOT/clock"; else /bin/date "$@"; fi\n')
        (bindir / 'date').symlink_to(self.root / 'date')
        self.env.update(PATH=str(bindir) + ':' + self.env['PATH'], CHIEF_WAIT_STREAM_MAX_PER_MIN='100')
        p, out = self.start()
        self.armed()
        for minute in range(15):
            clock.write_text(str(1794800000 + minute * 60))
            with self.inbox.open('a') as f:
                f.write(f'busy consumer event {minute}\n')
            self.until(lambda: f'WAKE#{minute + 1} telegram' in out.read_text())
            self.assertIsNone(p.poll())
        self.stop(p)
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
                        CHIEF_WAIT_STREAM_REPEAT_SEC='0',
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
                   CHIEF_WAIT_STREAM_ADOPT_SEC='0', CHIEF_WAIT_STREAM_REAP_MAX_SEC='1')
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


# Worker-event stand-in that keeps auto-go's exact-head audit rule: the first READY of a
# (pr, head) records one GO-SENT row, a replay of the same pair records none, and a
# cleanup event never records a GO. TEST_ROOT/refuse-cleanup makes cleanup refuse with the
# retryable `-failed rc=4`; TEST_ROOT/slow-N<k> makes that worker's event slow.
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
                        CHIEF_WAIT_STREAM_MAX_PER_MIN='100', CHIEF_WAIT_STREAM_REPEAT_SEC='0')
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

    def test_successor_chief_replays_each_worker_once_and_never_sends_a_second_go(self):
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
        # the successor starts every worker over: one replay of the newest READY, nothing older,
        # nothing twice, and the exact-head audit still shows one GO per head.
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
                unittest.TestSuite([Loaded('test_successor_chief_replays_each_worker_once_and_never_sends_a_second_go')]))
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
        return [arg for ts, arg in rows if float(ts) > after and arg in ('0.05', '0.5', '0.01', '1', '1.2.3')]

    def slow(self, count):
        return lambda: self.sleeps().count('0.5') >= count

    def post_ready(self):
        with self.doc1.open('a') as f:
            f.write('- 10:00 READY #1 ' + '1' * 40 + '\n')

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
        wrote = time.time()
        self.post_ready()
        self.until(lambda: (self.root / 'events').exists())
        self.stop(p)
        served = float((self.root / 'events').read_text().split()[0]) - wrote
        self.assertLess(served, 0.5 + 0.7, 'one idle interval at most, plus the pass')

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
