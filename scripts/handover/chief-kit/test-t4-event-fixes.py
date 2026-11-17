"""Offline regressions for collector isolation and persisted waiter recovery."""
import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('stream_tests', HERE / 'test-chief-wait-stream.py')
stream_tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stream_tests)


class Collector(stream_tests.StreamFixture):
    def collect(self):
        return subprocess.run(['python3', '-I', str(HERE / 'pending-events.py'),
                               str(self.fleet), str(self.inbox), ''], capture_output=True, text=True)

    def workers(self, texts):
        rows = []
        for i, text in enumerate(texts, 1):
            doc = self.root / f'N{i}.md'
            doc.write_bytes(text)
            rows.append(dict(label=f'N{i}', doc=str(doc)))
        self.fleet.write_text(json.dumps(dict(workers=rows)))

    def test_bad_worker_does_not_stall_healthy_peers(self):
        self.workers([b'- WRAPPED first\n', b'- LIVE truncated \xe2\x80', b'- READY #3 abc\n'])
        result = self.collect()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['N1 WRAPPED 1', 'N3 READY 1'])
        # An actual unreadable document still leaves healthy workers available.
        (self.root / 'N2.md').unlink()
        (self.root / 'N2.md').mkdir()
        result = self.collect()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('N2', result.stderr)
        self.assertIn('WARN N2', result.stdout)
        self.assertEqual(self.collect().stdout.splitlines(), ['N1 WRAPPED 1', 'N3 READY 1'])

    def test_unread_worker_warns_once_per_streak_while_peer_relay_progresses(self):
        self.workers([b'- READY #101 a\n', b'- LIVE work\n'])
        (self.root / 'N2.md').unlink()
        self.env['CHIEF_WAIT_WORKER_EVENT'] = self.script('event', 'cat >> "$TEST_ROOT/events"\necho HANDLED auto-go\n')
        proc, output = self.start()
        self.until(lambda: 'worker-doc-unread' in output.read_text())
        self.until(lambda: (self.root / 'events').exists())
        import time
        time.sleep(.4)
        self.assertEqual(output.read_text().count('worker-doc-unread'), 1)
        (self.root / 'N2.md').write_text('- LIVE repaired\n')
        self.until(lambda: not json.loads(self.path('ready-docs').read_text()).get('N2', {}).get('unread'))
        (self.root / 'N2.md').unlink()
        self.until(lambda: output.read_text().count('worker-doc-unread') == 2)
        self.stop(proc)

    def test_handled_ready_survives_prose_edits_and_atomic_rewrite(self):
        self.workers([b'# title\n- READY #101 a\n- note\n'])
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 2')
        self.path('ready').write_text('N1\t2\n')
        self.assertEqual(self.collect().stdout, '')
        replacement = self.root / 'replacement'
        replacement.write_text('# renamed\nextra prose\n- READY #101 a\n- edited note\n')
        replacement.replace(self.root / 'N1.md')
        self.assertEqual(self.collect().stdout, '')
        with (self.root / 'N1.md').open('a') as f:
            f.write('- READY #102 b\n- READY #103 c\n')
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 5')

    def test_first_ready_is_newest_then_appends_and_replacement(self):
        self.workers([b'- READY #101 a\n- READY #102 b\n- READY #103 c\n'])
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 3')
        self.path('ready').write_text('N1\t3\n')
        with (self.root / 'N1.md').open('a') as f:
            f.write('- READY #104 d\n- READY #105 e\n')
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 4')
        self.path('ready').write_text('N1\t4\n')
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 5')
        replacement = self.root / 'new.md'
        replacement.write_text('- READY #201 a\n- READY #202 b\n- READY #203 c\n- READY #204 d\n- READY #205 e\n')
        replacement.replace(self.root / 'N1.md')
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 5')

    def test_collector_failure_wakes_once_then_resets_after_recovery(self):
        self.path('ready').write_text('malformed cursor\n')
        self.env['CHIEF_WAIT_STREAM_MAX_PER_MIN'] = '100'
        p, out = self.start()
        self.until(lambda: 'waiter-error pending-events' in out.read_text())
        self.until(lambda: self.path('pending-error').exists())
        import time
        time.sleep(.5)
        self.assertEqual(out.read_text().count('waiter-error pending-events'), 1)
        self.path('ready').write_text('')
        self.until(lambda: not self.path('pending-error').exists())
        self.fleet.write_text('{')
        self.until(lambda: out.read_text().count('waiter-error pending-events') == 2)
        self.fleet.write_text('{"workers":[]}')
        self.stop(p)

    def test_truncated_and_unreadable_workers_allow_real_healthy_relays(self):
        self.workers([b'- WRAPPED first\n', b'- LIVE truncated \xe2\x80', b'- READY #3 abc\n'])
        self.env['CHIEF_WAIT_WORKER_EVENT'] = self.script('event', 'cat >> "$TEST_ROOT/events"\necho HANDLED close-wrapped\n')
        p, _ = self.start()
        self.until(lambda: (self.root / 'events').exists() and
                   len((self.root / 'events').read_text().splitlines()) == 2)
        self.stop(p)
        events = (self.root / 'events').read_text()
        self.assertIn('N1 WRAPPED', events)
        self.assertIn('N3 READY', events)


class Acknowledgements(stream_tests.StreamFixture):
    def setUp(self):
        super().setUp()
        spec = importlib.util.spec_from_file_location('supervisor', HERE / 'chief-wait-stream.py')
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        self.sup = self.mod.Supervisor(str(self.inbox), [])
        # error() uses normal durable wake writes; publish only needs ownership
        # during an actual supervisor run, tested separately below.
        self.sup.publish = lambda: None
        self.path('wakes').write_text('')

    def queue(self, seq, ids='missing'):
        block = self.path('wake-' + seq)
        block.write_text(f'WAKE owed-actions chief-notify={ids}\nowed-bucket={self.root}\n')
        self.sup.append('W', seq, 1, 1, 'owed-actions', block)
        self.sup.seq = max(self.sup.seq, int(seq))
        self.path('ack-' + seq + '.json').write_text(json.dumps(dict(seq=seq, receipt='received-' + seq)))

    def add(self, ident, actor='chief', action='notify', **more):
        row = dict(op='add', id=ident, ts='2026-11-17T00:00:00Z', epoch=1,
                   chief='chief', kind='proof' if action == 'validate-proof' else 'step' if action == 'next-step' else 'ruling',
                   text='pending ' + ident, actor=actor, action=action, **more)
        with (self.root / 'owed.jsonl').open('a') as f:
            f.write(json.dumps(row) + '\n')

    def test_corrupt_retry_is_isolated_preserved_and_repair_recovers(self):
        self.add('valid')
        self.queue('1', 'valid')
        self.queue('2', 'valid')
        retry = self.path('ack-1.json.retry')
        retry.write_text('garbage{')
        with contextlib.redirect_stdout(io.StringIO()):
            self.sup.acknowledge()
        self.assertEqual(retry.read_text(), 'garbage{')
        self.assertTrue(self.path('ack-1.json').exists())
        self.assertFalse(self.path('ack-2.json').exists())
        retry.write_text('{"next":0,"attempts":0}')
        self.sup.acknowledge()
        self.assertFalse(self.path('ack-1.json').exists())

    def test_retry_read_write_and_schema_faults_are_local_to_the_ack(self):
        for failure in ('read', 'write', 'shape', 'next', 'attempts'):
            with self.subTest(failure=failure):
                self.queue('1', 'none')
                self.queue('2', 'none')
                retry = self.path('ack-1.json.retry')
                if failure == 'read':
                    retry.mkdir()
                elif failure != 'write':
                    retry.write_text({'shape': '[]', 'next': '{"next":"later"}',
                                      'attempts': '{"attempts":null}'}[failure])
                real_atomic = self.mod.atomic
                def atomic(path, data):
                    if failure == 'write' and Path(path) == retry:
                        raise OSError('fixture retry write denied')
                    return real_atomic(path, data)
                with patch.object(self.mod, 'atomic', side_effect=atomic), contextlib.redirect_stdout(io.StringIO()):
                    self.sup.acknowledge()
                self.assertTrue(self.path('ack-1.json').exists())
                self.assertFalse(self.path('ack-2.json').exists())
                self.assertIn('K\t2\t', self.path('wakes').read_text())
                for path in self.path('stream').parent.glob(self.inbox.name + '.wait.ack-*'):
                    if path.is_dir():
                        path.rmdir()
                    else:
                        path.unlink()
                self.sup.ack_faults.clear()
                self.path('wakes').write_text('')

    def test_malformed_wake_repeated_arm_stops_then_repair_recovers(self):
        self.path('wakes').write_text('W\tnot-a-number\n')
        for expected in ('REARM', 'STOPPED'):
            proc, output = self.start()
            self.assertEqual(proc.wait(timeout=5), 1)
            self.assertIn(expected + ' since=', output.read_text())
        self.assertIn('reason=supervisor-repeat', output.read_text())
        self.path('wakes').write_text('')
        proc, output = self.start()
        self.until(lambda: self.path('stream').exists() and self.state().get('sup') == str(proc.pid))
        self.inbox.write_text('healthy after repair\n')
        self.until(lambda: 'telegram' in output.read_text())
        self.stop(proc)

    def test_missing_ack_backoff_survives_restart_other_ack_and_repair(self):
        self.add('valid')
        self.add('proof', action='validate-proof', validation='pending')
        self.add('source', action='next-step')
        self.queue('1')
        self.queue('2', 'valid')
        real_run = subprocess.run
        calls = []
        def run(cmd, **kw):
            calls.append(cmd)
            return real_run(cmd, **kw)
        with patch.object(self.mod.subprocess, 'run', side_effect=run):
            for _ in range(10):
                self.sup.acknowledge()
            restarted = self.mod.Supervisor(str(self.inbox), [])
            restarted.publish = lambda: None
            restarted.seq = self.sup.seq
            for _ in range(10):
                restarted.acknowledge()
        self.assertLessEqual(len(calls), 3)
        ledger = (self.root / 'owed.jsonl').read_text()
        self.assertIn('"ref":"valid"', ledger)
        self.assertNotIn('"ref":"proof"', ledger)
        self.assertNotIn('"ref":"source"', ledger)
        self.assertTrue(self.path('ack-1.json').exists())
        self.assertFalse(self.path('ack-2.json').exists())
        errors = [p for p in self.path('stream').parent.glob(self.inbox.name + '.wait.wake-*')
                  if 'kind=ack-stuck' in p.read_text()]
        self.assertEqual(len(errors), 1)
        retry = self.path('ack-1.json.retry')
        state = json.loads(retry.read_text())
        self.assertEqual(state['attempts'], 1)
        state['next'] = 0
        retry.write_text(json.dumps(state))
        restarted.acknowledge()
        state = json.loads(retry.read_text())
        self.assertEqual(state['attempts'], 2)
        import time
        self.assertGreater(state['next'] - time.time(), 55)
        self.add('missing')
        state = json.loads(retry.read_text())
        state['next'] = 0
        retry.write_text(json.dumps(state))
        restarted.acknowledge()
        self.assertFalse(self.path('ack-1.json').exists())
        self.assertFalse(retry.exists())
        self.assertIn('K\t1\t', self.path('wakes').read_text())

    def test_per_ack_timeout_bad_json_and_failed_close_do_not_block_valid_ack(self):
        for failure in ('timeout', 'request-json', 'owe-json', 'close'):
            with self.subTest(failure=failure):
                self.add('bad-' + failure)
                self.add('good-' + failure)
                self.queue('1', 'bad-' + failure)
                if failure == 'request-json':
                    self.path('ack-1.json').write_text('{')
                real_run = subprocess.run
                first_list = True
                def run(cmd, **kw):
                    nonlocal first_list
                    if cmd[2] == 'list' and first_list:
                        first_list = False
                        if failure == 'timeout':
                            return real_run(['bash', '-c', 'sleep .2'], capture_output=True, timeout=.02)
                        if failure == 'owe-json':
                            return subprocess.CompletedProcess(cmd, 0, stdout='{', stderr='')
                    if failure == 'close' and 'bad-close' in cmd:
                        return subprocess.CompletedProcess(cmd, 1, stdout='', stderr='close refused')
                    return real_run(cmd, **kw)
                with patch.object(self.mod.subprocess, 'run', side_effect=run):
                    self.sup.acknowledge()
                    self.queue('2', 'good-' + failure)
                    self.sup.acknowledge()
                self.assertTrue(self.path('ack-1.json').exists())
                self.assertFalse(self.path('ack-2.json').exists())
                self.assertIn('K\t2\t', self.path('wakes').read_text())
                # Fresh request/state between independent failure cases.
                for path in self.path('stream').parent.glob(self.inbox.name + '.wait.ack-*'):
                    path.unlink()
                self.path('wakes').write_text('')

    def test_uncaught_supervisor_exception_emits_error_and_rearm_stdout(self):
        self.script('tick', 'sleep 2\necho "TICK workers=0 livestate=0 prs=none tails=none acts=none workerset=0 board=ok tracker=ok denials=0 capacity=FULL"\n')
        runner = self.root / 'runner.py'
        runner.write_text('import importlib.util, sys\n'
                          f's = importlib.util.spec_from_file_location("sup", {str(HERE / "chief-wait-stream.py")!r})\n'
                          'm = importlib.util.module_from_spec(s); s.loader.exec_module(m)\n'
                          'def boom(self):\n'
                          '    if self.data.get("child"): raise RuntimeError("fixture uncaught")\n'
                          'm.Supervisor.acknowledge = boom\n'
                          'sys.exit(m.main())\n')
        result = subprocess.run(['python3', str(runner), str(self.inbox), '--stream',
                                 '--workers-from', str(self.fleet)], env=self.env,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn('waiter-error kind=supervisor', result.stdout)
        self.assertIn('REARM since=', result.stdout)
        self.assertIn('child=busy', result.stdout)
        self.assertIn('waiter-error', self.path('wakes').read_text())
        child = self.state()['child']
        repeated = subprocess.run(['python3', str(runner), str(self.inbox), '--stream',
                                   '--workers-from', str(self.fleet)], env=self.env,
                                  capture_output=True, text=True, timeout=5)
        self.assertEqual(repeated.returncode, 1)
        self.assertIn('STOPPED since=', repeated.stdout)
        self.assertIn('reason=supervisor-repeat', repeated.stdout)
        again, _ = self.start()
        self.until(lambda: self.state().get('sup') == str(again.pid))
        self.assertEqual(self.state()['child'], child)
        self.stop(again)

    def process_failure(self, mode):
        self.add('bad')
        self.add('good')
        self.queue('1', 'bad')
        self.queue('2', 'good')
        if mode == 'request':
            self.path('ack-1.json').write_text('{')
        if mode == 'retry':
            self.path('ack-1.json.retry').write_text('{')
        runner = self.root / 'runner.py'
        runner.write_text('import importlib.util, subprocess, sys\n'
                          f's = importlib.util.spec_from_file_location("sup", {str(HERE / "chief-wait-stream.py")!r})\n'
                          'm = importlib.util.module_from_spec(s); s.loader.exec_module(m)\n'
                          f'mode = {mode!r}\n'
                          'real_run = subprocess.run\n'
                          'first = True\n'
                          'def run(cmd, **kw):\n'
                          '    global first\n'
                          '    if cmd[2] == "list" and first:\n'
                          '        first = False\n'
                          '        if mode == "timeout": return real_run(["bash", "-c", "sleep .2"], capture_output=True, timeout=.02)\n'
                          '        if mode == "owe-json": return subprocess.CompletedProcess(cmd, 0, stdout="{", stderr="")\n'
                          '    if mode == "close" and "bad" in cmd: return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="refused")\n'
                          '    return real_run(cmd, **kw)\n'
                          'm.subprocess.run = run\n'
                          'sys.exit(m.main())\n')
        output = self.root / 'process-out'
        with output.open('w') as out:
            proc = subprocess.Popen(['python3', str(runner), str(self.inbox), '--stream',
                                     '--workers-from', str(self.fleet), '--doc', str(self.doc)],
                                    env=self.env, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        self.procs.append((proc, output))
        self.until(lambda: 'kind=ack-stuck' in output.read_text() and 'K\t2\t' in self.path('wakes').read_text())
        self.assertIsNone(proc.poll())
        self.assertTrue(self.path('ack-1.json').exists())
        self.stop(proc)
        self.assertIn('STOPPED since=', output.read_text())

    def test_process_timeout_does_not_kill_supervisor(self):
        self.process_failure('timeout')

    def test_process_owe_json_does_not_kill_supervisor(self):
        self.process_failure('owe-json')

    def test_process_request_json_does_not_kill_supervisor(self):
        self.process_failure('request')

    def test_process_retry_json_does_not_kill_supervisor(self):
        self.process_failure('retry')

    def test_process_failed_close_does_not_kill_supervisor(self):
        self.process_failure('close')

    def test_disappearing_proc_child_is_an_absent_safe_point(self):
        with patch.object(self.mod, 'child_alive', return_value=True), \
                patch.object(self.mod, 'load', return_value=dict(pid='123', state='waiting')), \
                patch.object(Path, 'read_text', side_effect=['456', ProcessLookupError('task exited')]):
            self.assertEqual(self.mod.safe_point(dict(child='123'), str(self.inbox)), '')


class Replay(stream_tests.StreamFixture):
    def test_consecutive_replay_advances_rearm_and_prunes_only_obsolete_indexes(self):
        self.path('wake-1').write_text('WAKE fixture recover\n')
        self.path('wakes').write_text(f'W\t1\t1\t1\tfixture\t{self.path("wake-1")}\n')
        self.env.update(CHIEF_WAIT_STREAM_SOFT_SEC='.1', CHIEF_WAIT_STREAM_HARD_SEC='.5')
        for n in range(5):
            p, out = self.start(('--since', '0'))
            p.wait(timeout=5)
            self.assertIn('REPLAY seqs=1-1', out.read_text())
            self.assertIn('REARM since=1', out.read_text())
        indexes = list(self.path('stream').parent.glob(self.inbox.name + '.wait.replay-*'))
        self.assertLessEqual(len(indexes), 2)
        self.assertTrue(Path(out.read_text().split('index=')[1].split()[0]).exists())
        again, output = self.start(('--since', '1'))
        again.wait(timeout=5)
        self.assertNotIn('REPLAY', output.read_text())
        self.assertIn('REARM since=1', output.read_text())


class OperatorService(stream_tests.StreamFixture):
    def operator_fixture(self):
        spec = importlib.util.spec_from_file_location('owed_recheck', os.getenv('T4_SERVICE_SOURCE', str(HERE / 'owed-service.py')))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.HERE = HERE
        row = dict(op='add', id='notify', ts='2026-11-17T00:00:00Z', epoch=1,
                   chief='chief', kind='ruling', text='please sign', actor='operator', action='notify')
        ledger = self.root / 'owed.jsonl'
        ledger.write_text(json.dumps(row) + '\n')
        access = self.root / 'access.json'
        access.write_text('{"allowFrom":[1]}')
        bridge = self.root / 'bridge'
        (bridge / 'consoles').mkdir(parents=True)
        (bridge / 'consoles/chief.md').touch()
        env = dict(BRIDGE_ROOT=str(bridge), TELEGRAM_ACCESS_PATH=str(access),
                   CHIEF_WAIT_OPERATOR_RETRY_SEC='1800', CHIEF_WAIT_OPERATOR_GRACE_SEC='30')
        env.update(HIMMEL_TEST_FIXTURE='0', CHIEF_WAIT_OWED_SEND='')
        def service():
            with patch.dict(os.environ, env), contextlib.redirect_stdout(io.StringIO()):
                return mod.run(str(self.inbox), self.doc, 'chief')
        def flush():
            tg = HERE / '../../telegram/poller.ts'
            script = self.root / 'flush.ts'
            script.write_text(f'const {{flushOutboxes}} = await import({str(tg.resolve())!r});\n'
                              f'await flushOutboxes({str(bridge)!r}, async () => 9876);\n')
            subprocess.run(['bun', str(script)], check=True, capture_output=True, timeout=5)
        return service, flush, ledger, bridge / 'sessions/__chat__/outbox.jsonl', self.path('operator-notify')

    def test_healthy_enqueue_is_quiet_and_delayed_receipt_closes_during_backoff(self):
        service, flush, ledger, outbox, retry = self.operator_fixture()
        self.assertFalse(service(), 'healthy asynchronous enqueue must not wake chief')
        original = outbox.read_text()
        state = json.loads(retry.read_text())
        state['first'] = 1
        retry.write_text(json.dumps(state))
        self.assertTrue(service(), 'genuine outage after grace must wake')
        self.assertFalse(service(), 'same pending debt must not hot-loop')
        self.assertEqual(outbox.read_text(), original)
        flush()
        self.assertFalse(service())
        self.assertIn('DELIVERED t2-notify msg=9876', self.doc.read_text())
        self.assertIn('"ref":"notify"', ledger.read_text())
        self.assertFalse(retry.exists())
        self.assertEqual(outbox.read_text(), original, 'receipt-only reconciliation cannot enqueue')

    def test_exact_delayed_receipt_closes_even_with_send_retry_not_due(self):
        service, flush, ledger, outbox, retry = self.operator_fixture()
        service()
        original = outbox.read_text()
        import time
        self.assertGreater(json.loads(retry.read_text())['next'], time.time() + 1700)
        flush()
        service()
        self.assertIn('"ref":"notify"', ledger.read_text(), 'receipt must close before send retry is due')
        self.assertEqual(outbox.read_text(), original)

    def test_bad_operator_retry_is_visible_and_does_not_block_later_owed_row(self):
        service, _, ledger, _, retry = self.operator_fixture()
        bad = json.loads(ledger.read_text())
        good = dict(bad, id='good')
        ledger.write_text(json.dumps(bad) + '\n' + json.dumps(good) + '\n')
        retry.write_text('{')
        self.assertTrue(service())
        self.assertEqual(retry.read_text(), '{')
        self.assertIn('operator-state-unread', self.path('owed-service').read_text())
        self.assertTrue(self.path('operator-good').exists())

    def test_chief_observation_reminds_without_closing_source_or_proof_debt(self):
        spec = importlib.util.spec_from_file_location('owed_service', os.getenv('T4_SERVICE_SOURCE', str(HERE / 'owed-service.py')))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.HERE = HERE
        rows = [dict(op='add', id='notify', ts='2026-11-17T00:00:00Z', epoch=1,
                     chief='chief', kind='ruling', text='step due', actor='chief', action='notify'),
                dict(op='add', id='source', ts='2026-11-17T00:00:00Z', epoch=1,
                     chief='chief', kind='step', text='source action', actor='chief', action='next-step'),
                dict(op='add', id='proof', ts='2026-11-17T00:00:00Z', epoch=1,
                     chief='chief', kind='proof', text='proof action', actor='chief', action='validate-proof', validation='pending')]
        ledger = self.root / 'owed.jsonl'
        ledger.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        original = ledger.read_text()
        def service():
            with contextlib.redirect_stdout(io.StringIO()):
                return mod.run(str(self.inbox), self.doc, 'chief')
        self.assertTrue(service())
        for _ in range(5):
            self.assertFalse(service())
        stamp = self.path('owed-service')
        os.utime(stamp, (1, 1))
        self.assertTrue(service())
        self.assertEqual(ledger.read_text(), original)
        rows[0]['text'] = 'changed notification'
        ledger.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        self.assertTrue(service())
        self.assertFalse(service())

    def test_failed_first_operator_row_does_not_hide_or_block_later_delivery(self):
        rows = [dict(op='add', id=ident, ts='2026-11-17T00:00:00Z', epoch=1, chief='chief',
                     kind='ruling', text=ident, actor='operator', action='notify', event='operator-digest')
                for ident in ('bad', 'good')]
        ledger = self.root / 'owed.jsonl'
        ledger.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        self.env['CHIEF_WAIT_OWED_SEND'] = self.script('send', r'''echo "$*" >> "$TEST_ROOT/sends"
case "$*" in *t2-good*) echo '- DELIVERED t2-good msg=91 chat=123' >> "$TEST_ROOT/chief.md";; esac
exit 0
''')
        command = ['python3', '-I', str(HERE / 'owed-service.py'), '--inbox', str(self.inbox),
                   '--doc', str(self.doc), '--chief', 'chief']
        for _ in range(3):
            subprocess.run(command, env=self.env, capture_output=True, timeout=5)
        sends = (self.root / 'sends').read_text().splitlines()
        self.assertEqual(len(sends), 2)
        self.assertIn('t2-bad', sends[0])
        self.assertIn('t2-good', sends[1])
        self.assertIn('"ref":"good"', ledger.read_text())
        self.assertNotIn('"ref":"bad"', ledger.read_text())

    def test_actual_queued_transport_is_prompt_and_does_not_close_on_unrelated_receipt(self):
        # Service passes the existing route's zero-wait receipt mode. This seam
        # checks the actual subprocess environment without contacting Telegram.
        ledger = self.root / 'owed.jsonl'
        ledger.write_text(json.dumps(dict(op='add', id='bad', ts='2026-11-17T00:00:00Z', epoch=1,
                          chief='chief', kind='ruling', text='pending', actor='operator', action='notify')) + '\n')
        self.doc.write_text('# chief\n- DELIVERED unrelated msg=92 chat=123\n')
        self.env['CHIEF_WAIT_OWED_SEND'] = self.script('send', r'''echo "${CHIEF_ROUTE_RECEIPT_WAIT_SEC:-unset}" > "$TEST_ROOT/wait-mode"
echo queued
''')
        subprocess.run(['python3', '-I', str(HERE / 'owed-service.py'), '--inbox', str(self.inbox),
                        '--doc', str(self.doc), '--chief', 'chief'], env=self.env, capture_output=True, timeout=3)
        self.assertEqual((self.root / 'wait-mode').read_text().strip(), '0')
        self.assertNotIn('"op":"close"', ledger.read_text())

if __name__ == '__main__':
    unittest.main()
