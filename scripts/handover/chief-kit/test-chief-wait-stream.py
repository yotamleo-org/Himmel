"""Exercise the real supervisor/child/control routes using offline dependencies."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent


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


if __name__ == '__main__':
    unittest.main()
