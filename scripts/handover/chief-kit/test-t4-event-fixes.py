"""Offline regressions for collector isolation and persisted waiter recovery."""
import importlib.util
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import time
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
        self.assertEqual(self.collect().stdout, '')
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 5')
        self.assertEqual(self.path('ready').read_text(), 'N1\t4\n')
        # A candidate is not an acknowledgement: a refused relay must retry.
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 5')

    def test_torn_document_keeps_handled_ready_history(self):
        full = ''.join(f'- READY #{n} head-{n}\n' for n in range(1, 6))
        for temporary in ('', ''.join(full.splitlines(keepends=True)[:2])):
            with self.subTest(temporary=temporary):
                self.workers([full.encode()])
                self.collect()
                self.path('ready').write_text('N1\t5\n')
                self.assertEqual(self.collect().stdout, '')
                observed = json.loads(self.path('ready-docs').read_text())['N1']['ready']
                (self.root / 'N1.md').write_text(temporary)
                for _ in range(2):
                    self.assertEqual(self.collect().stdout, '')
                    self.assertEqual(self.path('ready').read_text(), 'N1\t5\n')
                    self.assertEqual(json.loads(self.path('ready-docs').read_text())['N1']['ready'], observed)
                (self.root / 'N1.md').write_text(full)
                for _ in range(3):
                    self.assertEqual(self.collect().stdout, '')

    def test_editing_older_ready_does_not_relay_handled_latest(self):
        self.workers([b'- READY #1 old\n- READY #2 latest\n'])
        self.collect()
        self.path('ready').write_text('N1\t2\n')
        self.assertEqual(self.collect().stdout, '')
        (self.root / 'N1.md').write_text('- READY #1 edited old\n- READY #2 latest\n')
        self.assertEqual(self.collect().stdout, '')
        (self.root / 'N1.md').write_text('- READY #2 latest\n')
        self.assertEqual(self.collect().stdout, '')
        with (self.root / 'N1.md').open('a') as output:
            output.write('- READY #3 new\n')
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 2')

    def test_stable_replacement_waits_for_actual_relay_receipt(self):
        self.workers([b'- READY #1 old\n'])
        self.collect()
        self.path('ready').write_text('N1\t1\n')
        self.assertEqual(self.collect().stdout, '')
        replacement = '- READY #2 new\n'
        (self.root / 'N1.md').write_text(replacement)
        self.assertEqual(self.collect().stdout, '')
        for _ in range(2):
            self.assertEqual(self.collect().stdout.strip(), 'N1 READY 1')
            self.assertEqual(self.path('ready').read_text(), 'N1\t1\n')
        received = subprocess.run(['cksum'], input=replacement, capture_output=True,
                                  text=True, check=True).stdout.split()[0]
        self.path('r0').write_text(f'N1 READY {received}\n')
        self.assertEqual(self.collect().stdout, '')
        self.assertEqual(self.collect().stdout, '')
        with (self.root / 'N1.md').open('a') as output:
            output.write('- READY #3 later\n')
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 2')

    def test_escalation_heads_block_when_a_peer_document_is_unreadable(self):
        self.workers([b'- LIVE unread\n', b'- READY #101 a\n'])
        (self.root / 'N1.md').unlink()
        self.env['CHIEF_WAIT_WORKER_EVENT'] = self.script('event', 'cat >/dev/null\necho "ESCALATE actual-failure"\nexit 10\n')
        proc, output = self.start()
        self.until(lambda: 'worker-event' in output.read_text())
        self.stop(proc)
        wakes = [line for line in output.read_text().splitlines() if line.startswith('WAKE#')]
        self.assertTrue(wakes, output.read_text())
        self.assertIn('worker-event', wakes[0])
        self.assertNotIn('waiter-error', wakes[0])
        self.assertIn('worker-doc-unread', ''.join(p.read_text() for p in
                      self.inbox.parent.glob(self.inbox.name + '.wait.wake-*')))

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

    # A worker's own cleanup bullet must not hide its READY.
    def relayed(self, label, marker, line):
        """Record what r0_relay records after a handled relay of one bullet."""
        digest = subprocess.run(['cksum'], input=line + '\n', capture_output=True,
                                text=True, check=True).stdout.split()[0]
        with self.path('r0').open('a') as f:
            f.write(f'{label} {marker} {digest}\n')

    def append(self, name, *lines):
        with (self.root / name).open('a') as f:
            f.write(''.join(line + '\n' for line in lines))

    def test_ready_after_a_handled_merged_is_still_offered(self):
        self.workers([b'- 10:00 READY #1 h1\n'])
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 1')
        self.path('ready').write_text('N1\t1\n')
        self.append('N1.md', '- 10:05 MERGED #1')
        self.assertEqual(self.collect().stdout.strip(), 'N1 MERGED 2')
        self.relayed('N1', 'MERGED', '- 10:05 MERGED #1')
        self.assertEqual(self.collect().stdout, '')
        self.append('N1.md', '- 10:10 READY #2 h2')
        for _ in range(2):
            self.assertEqual(self.collect().stdout.strip(), 'N1 READY 3')

    def test_ready_behind_an_unhandled_merged_is_offered_not_the_stale_merged(self):
        self.workers([b'- 10:00 READY #1 h1\n'])
        self.collect()
        self.path('ready').write_text('N1\t1\n')
        self.append('N1.md', '- 10:05 MERGED #1')
        self.assertEqual(self.collect().stdout.strip(), 'N1 MERGED 2')
        self.append('N1.md', '- 10:10 READY #2 h2')
        for _ in range(2):
            self.assertEqual(self.collect().stdout.strip(), 'N1 READY 3')

    def test_wrapped_is_live_only_while_it_is_the_newest_marker(self):
        self.workers([b'- 10:00 READY #1 h1\n- 10:05 WRAPPED no PR\n'])
        self.assertEqual(self.collect().stdout.strip(), 'N1 WRAPPED 2')
        self.relayed('N1', 'WRAPPED', '- 10:05 WRAPPED no PR')
        self.assertEqual(self.collect().stdout, '')
        self.append('N1.md', '- 10:10 READY #2 h2')
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 3')

    def test_a_live_cleanup_is_still_the_only_event_for_its_worker(self):
        self.workers([b'- 10:00 READY #1 h1\n'])
        self.collect()
        self.path('ready').write_text('N1\t1\n')
        self.append('N1.md', '- 10:05 MERGED #1')
        for _ in range(3):
            self.assertEqual(self.collect().stdout.strip(), 'N1 MERGED 2')
        self.relayed('N1', 'MERGED', '- 10:05 MERGED #1')
        for _ in range(3):
            self.assertEqual(self.collect().stdout, '')

    def test_ready_before_a_handled_cleanup_is_moot_and_never_replayed(self):
        self.workers([b'- 10:00 READY #1 h1\n'])
        self.collect()
        self.path('ready').write_text('N1\t1\n')
        self.append('N1.md', '- 10:01 READY #2 h2', '- 10:02 MERGED #2')
        self.assertEqual(self.collect().stdout.strip(), 'N1 MERGED 3')
        self.relayed('N1', 'MERGED', '- 10:02 MERGED #2')
        self.assertEqual(self.collect().stdout, '')
        self.append('N1.md', '- 10:10 READY #3 h3')
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 4')

    def test_first_seen_ready_after_an_old_cleanup_is_the_event(self):
        self.workers([b'- 10:00 READY #1 h1\n- 10:05 MERGED #1\n- 10:10 READY #2 h2\n'])
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 3')

    def test_peer_events_and_rotation_survive_a_stacked_worker(self):
        self.workers([b'- 10:00 READY #1 h1\n- 10:05 MERGED #1\n- 10:10 READY #2 h2\n',
                      b'- 10:00 WRAPPED no PR\n'])
        self.assertEqual(self.collect().stdout.splitlines(), ['N1 READY 3', 'N2 WRAPPED 1'])

    # A label that returns with a different doc must not have its READY marked handled.
    def test_label_returning_with_a_shorter_document_keeps_its_unhandled_ready(self):
        long = ''.join(f'- 09:{n:02d} LIVE step {n}\n' for n in range(39)) + '- 10:00 READY #1 h1\n'
        self.workers([long.encode()])
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 40')
        self.path('ready').write_text('N1\t40\n')
        self.assertEqual(self.collect().stdout, '')
        self.fleet.write_text(json.dumps(dict(workers=[])))
        self.assertEqual(self.collect().stdout, '')
        (self.root / 'N1.md').write_text('- 10:30 LIVE restarted\n- 10:31 READY #9 h9\n')
        self.fleet.write_text(json.dumps(dict(workers=[dict(label='N1', doc=str(self.root / 'N1.md'))])))
        for _ in range(3):
            self.assertEqual(self.collect().stdout.strip(), 'N1 READY 2')

    def test_label_returning_with_a_longer_different_document_keeps_its_unhandled_ready(self):
        self.workers([b'- 09:00 LIVE a\n- 10:00 READY #1 h1\n'])
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 2')
        self.path('ready').write_text('N1\t2\n')
        self.assertEqual(self.collect().stdout, '')
        self.fleet.write_text(json.dumps(dict(workers=[])))
        self.assertEqual(self.collect().stdout, '')
        (self.root / 'N1.md').write_text('- 10:31 READY #9 h9\n- 10:32 LIVE a\n- 10:33 LIVE b\n')
        self.fleet.write_text(json.dumps(dict(workers=[dict(label='N1', doc=str(self.root / 'N1.md'))])))
        for _ in range(3):
            self.assertEqual(self.collect().stdout.strip(), 'N1 READY 1')

    def test_snapshotless_cursor_past_the_document_end_restarts_the_worker(self):
        self.workers([b'- 10:00 LIVE restarted\n- 10:01 READY #9 h9\n'])
        self.path('ready').write_text('N1\t40\n')
        for _ in range(3):
            self.assertEqual(self.collect().stdout.strip(), 'N1 READY 2')

    def test_retired_label_keeps_no_cursor(self):
        self.workers([b'- 10:00 READY #1 h1\n', b'- 10:00 READY #2 h2\n'])
        self.collect()
        self.path('ready').write_text('N1\t1\nN2\t1\n')
        self.assertEqual(self.collect().stdout, '')
        self.fleet.write_text(json.dumps(dict(workers=[dict(label='N2', doc=str(self.root / 'N2.md'))])))
        self.assertEqual(self.collect().stdout, '')
        self.assertEqual(self.path('ready').read_text(), 'N2\t1\n')

    def test_an_ask_row_that_stops_being_ask_meets_none_of_its_old_readys_as_new(self):
        doc = self.root / 'N1.md'
        for later in ({'t3_kind': 'task'}, {}):
            with self.subTest(later=later):
                for state in ('ready', 'ready-docs'):
                    self.path(state).unlink(missing_ok=True)
                doc.write_text('- 10:00 READY #1 h1\n- 10:01 READY #2 h2\n')
                row = dict(label='N1', doc=str(doc), lane='t3', lockless=True, t3_thread='thr1')
                self.fleet.write_text(json.dumps(dict(workers=[dict(row, t3_kind='ask')])))
                for _ in range(2):
                    self.assertEqual(self.collect().stdout, '')
                self.fleet.write_text(json.dumps(dict(workers=[dict(row, **later)])))
                for _ in range(2):
                    self.assertEqual(self.collect().stdout, '')
                self.append('N1.md', '- 10:10 READY #3 h3')
                self.assertEqual(self.collect().stdout.strip(), 'N1 READY 3')

    def test_unchanged_document_keeps_its_handled_ready_across_passes(self):
        self.workers([b'- 10:00 READY #1 h1\n'])
        self.collect()
        self.path('ready').write_text('N1\t1\n')
        for _ in range(3):
            self.assertEqual(self.collect().stdout, '')

    # The relay addresses a line with `sed -n Np`, which splits on newline only.
    def sed_line(self, name, number):
        return subprocess.run(['sed', '-n', f'{number}p', str(self.root / name)], capture_output=True,
                              text=True, errors='replace').stdout.rstrip('\n')

    def test_lines_are_numbered_the_way_the_relay_addresses_them(self):
        ready = f'- 10:00 READY #1 {"1" * 40}'
        for name, separator in (('lone CR', '\r'), ('form feed', '\x0c'), ('U+2028', ' '),
                                ('vertical tab', '\x0b'), ('NEL', '\x85'), ('file separator', '\x1c')):
            with self.subTest(separator=name):
                self.workers([f'# N1\n- 09:00 LIVE progress{separator}more\n{ready}\n- 10:01 LIVE after\n'.encode()])
                for state in ('ready', 'ready-docs'):
                    self.path(state).unlink(missing_ok=True)
                event = self.collect().stdout.split()
                self.assertEqual(event[:2], ['N1', 'READY'])
                self.assertEqual(self.sed_line('N1.md', event[2]), ready)

    def test_crlf_document_keeps_its_line_numbers(self):
        ready = f'- 10:00 READY #1 {"1" * 40}'
        self.workers([f'# N1\r\n- 09:00 LIVE a\r\n{ready}\r\n'.encode()])
        self.assertEqual(self.collect().stdout.split(), ['N1', 'READY', '3'])

    def test_a_torn_read_ending_at_a_handled_merged_does_not_offer_a_relayed_ready_again(self):
        self.workers([b'- 10:00 READY #1 h1\n'])
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 1')
        self.path('ready').write_text('N1\t1\n')
        self.append('N1.md', '- 10:05 MERGED #1')
        self.assertEqual(self.collect().stdout.strip(), 'N1 MERGED 2')
        self.relayed('N1', 'MERGED', '- 10:05 MERGED #1')
        self.append('N1.md', '- 10:10 READY #2 h2')
        self.assertEqual(self.collect().stdout.strip(), 'N1 READY 3')
        self.path('ready').write_text('N1\t3\n')
        full = (self.root / 'N1.md').read_text()
        (self.root / 'N1.md').write_text('- 10:00 READY #1 h1\n- 10:05 MERGED #1\n')
        for _ in range(2):
            self.assertEqual(self.collect().stdout, '')
        (self.root / 'N1.md').write_text(full)
        for _ in range(3):
            self.assertEqual(self.collect().stdout, '')
        self.assertEqual(self.path('ready').read_text(), 'N1\t3\n')


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
        def service(doc=None, chief='chief'):
            with patch.dict(os.environ, env), contextlib.redirect_stdout(io.StringIO()):
                return mod.run(str(self.inbox), doc or self.doc, chief)
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

    def test_successor_chief_closes_the_row_from_the_predecessor_receipt_and_sends_nothing(self):
        service, flush, ledger, outbox, retry = self.operator_fixture()
        service()
        flush()
        original = outbox.read_text() if outbox.exists() else ''
        successor = self.doc.parent / 'chief-b.md'
        successor.write_text('# successor\n')
        (self.root / 'bridge/consoles/chief-b.md').touch()
        self.assertFalse(service(successor, 'chief-b'))
        self.assertIn('DELIVERED t2-notify msg=9876', successor.read_text())
        self.assertIn('"ref":"notify"', ledger.read_text())
        self.assertEqual(outbox.read_text() if outbox.exists() else '', original, 'a successor must not enqueue a second send')

    def test_operator_send_names_its_kind(self):
        ledger = self.root / 'owed.jsonl'
        ledger.write_text(json.dumps(dict(op='add', id='kind', ts='2026-11-17T00:00:00Z', epoch=1,
                          chief='chief', kind='ruling', text='pending', actor='operator', action='notify')) + '\n')
        self.env['CHIEF_WAIT_OWED_SEND'] = self.script('send', r'''echo "$*" > "$TEST_ROOT/send-args"
echo queued
''')
        subprocess.run(['python3', '-I', str(HERE / 'owed-service.py'), '--inbox', str(self.inbox),
                        '--doc', str(self.doc), '--chief', 'chief'], env=self.env, capture_output=True, timeout=3)
        self.assertIn('--kind chief-reply', (self.root / 'send-args').read_text())

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

class RelayWindows(stream_tests.StreamFixture):
    """The service relay's re-read, kill windows and inherited descriptors.

    The waiter runs directly with CHIEF_WAIT_STREAM_SERVICE=1, the way the supervisor starts
    it. A PATH shim is the controlled seam: it kills the waiter at one named command, so a
    "kill" lands in a window no timed kill can hit."""
    H1 = '1' * 40

    def setUp(self):
        super().setUp()
        self.shim = self.root / 'shim'
        self.shim.mkdir()
        self.real = {name: subprocess.run(['bash', '-c', f'command -v {name}'], capture_output=True,
                                          text=True).stdout.strip() for name in ('grep', 'mv', 'awk', 'python3')}
        self.env.update(HIMMEL_FLAG_AUTO_GO='1', CHIEF_WAIT_STREAM_SERVICE='1', T4_INBOX=str(self.inbox),
                        PATH=str(self.shim) + ':' + self.env['PATH'], CHIEF_WAIT_STREAM_MAX_PER_MIN='100')
        self.n1 = self.root / 'N1.md'
        self.n1.write_text(f'# N1\n- 09:00 LIVE start\n- 10:00 READY #1 {self.H1}\n')
        self.fleet.write_text(json.dumps(dict(workers=[dict(label='N1', doc=str(self.n1))])))

    def shim_for(self, name, body):
        path = self.shim / name
        path.write_text('#!/usr/bin/env bash\n' + body)
        path.chmod(0o755)

    def kill_waiter(self):
        return ('pid=$(sed -n \'s/.* pid=\\([0-9][0-9]*\\) .*/\\1/p\' "$T4_INBOX.wait" | head -n 1)\n'
                'kill -KILL -- "-$pid"\nsleep 5\nexit 1\n')  # the whole service session, like a killed arm

    def direct(self, name):
        out = self.root / name
        with out.open('w') as f:
            p = subprocess.Popen(['bash', str(HERE / 'chief-wait.sh'), str(self.inbox), '--doc', str(self.doc),
                                  '--workers-from', str(self.fleet)], env=self.env, stdout=f,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        self.procs.append((p, out))
        return p, out

    def calls(self):
        path = self.root / 'events'
        return path.read_text().splitlines() if path.exists() else []

    # (a) the line the relay re-reads must still be a READY
    def test_relay_skips_a_line_that_stopped_being_a_ready_and_self_heals(self):
        self.env['CHIEF_WAIT_WORKER_EVENT'] = self.script('event', r'''line=$(cat)
echo "$line" >> "$TEST_ROOT/events"
case "$line" in N1\ READY\ *) echo 'HANDLED auto-go N1'; exit 0;; esac
echo 'ESCALATE marker-LIVE'; exit 10
''')
        self.shim_for('python3', 'out=$(' + self.real['python3'] + ' "$@"); rc=$?\n'
                      'case "$*" in *pending-events.py*)\n'
                      '  if [ -n "$out" ] && [ ! -e "$TEST_ROOT/inserted" ]; then\n'
                      '    : > "$TEST_ROOT/inserted"; sed -i "1i - 09:59 LIVE inserted above the READY" "$TEST_ROOT/N1.md"\n'
                      '  fi;; esac\n'
                      '[ -z "$out" ] || printf "%s\\n" "$out"\nexit $rc\n')
        p, out = self.direct('out')
        self.until(lambda: any(' READY ' in c for c in self.calls()) or p.poll() is not None)
        time.sleep(.5)
        self.assertIsNone(p.poll(), out.read_text())
        self.assertEqual(self.calls(), [f'N1 READY #1 {self.H1}'])
        self.assertNotIn('WAKE worker-event', out.read_text())
        self.until(lambda: self.path('ready').exists() and self.path('ready').read_text() == 'N1\t4\n')

    # (b) a kill at any point leaves the wake printed or the READY still unhandled
    def run_killed(self, at):
        self.env['CHIEF_WAIT_WORKER_EVENT'] = self.script('event', r'''cat >> "$TEST_ROOT/events"
echo 'ESCALATE auto-go 3 not-ready'; exit 10
''')
        body = self.kill_waiter()
        if at == 'grep':
            self.shim_for('grep', f'if [ "$T4_KILL_AT" = grep ] && [ "$1" = -m ] && [ -e "$T4_INBOX.wait.le-N1" ]; then\n{body}fi\nexec {self.real["grep"]} "$@"\n')
        if at == 'mv':
            self.shim_for('mv', f'if [ "$T4_KILL_AT" = mv ]; then case "${{@: -1}}" in *.wait.ready) {self.real["mv"]} "$@"\n{body};; esac; fi\nexec {self.real["mv"]} "$@"\n')
        if at == 'awk':
            self.shim_for('awk', f'if [ "$T4_KILL_AT" = awk ] && [ "$4" = \'$1 != l\' ]; then\n{body}fi\nexec {self.real["awk"]} "$@"\n')
        self.env['T4_KILL_AT'] = at
        first, first_out = self.direct('out1')
        self.assertEqual(first.wait(timeout=10), -9, first_out.read_text())
        self.env.pop('T4_KILL_AT')
        second, second_out = self.direct('out2')
        time.sleep(2.5)
        second.terminate()
        second.wait(timeout=6)
        wakes = first_out.read_text().count('WAKE worker-event') + second_out.read_text().count('WAKE worker-event')
        self.detail = f'first={first_out.read_text()!r} second={second_out.read_text()!r} calls={self.calls()}'
        self.assertFalse((self.root / 'audit').exists(), 'no GO record on a refused READY')
        return wakes, len(self.calls())

    def test_kill_after_the_cursor_write_before_the_wake_never_loses_the_wake(self):
        wakes, calls = self.run_killed('mv')
        self.assertEqual((wakes, calls), (1, 1), self.detail)

    def test_kill_before_the_wake_is_printed_replays_the_ready_once(self):
        wakes, calls = self.run_killed('grep')
        self.assertEqual((wakes, calls), (1, 2), self.detail)

    def test_kill_after_the_wake_before_the_cursor_never_loses_it(self):
        wakes, calls = self.run_killed('awk')
        self.assertIn(wakes, (1, 2), self.detail)
        self.assertIn(calls, (1, 2), self.detail)
        self.assertEqual(wakes, calls, 'every relay that ran shows its wake: replayed at most once; ' + self.detail)

    # U4: a helper that outlives the waiter must not keep its one-waiter lock
    def test_helpers_do_not_inherit_the_waiters_lock_descriptor(self):
        for name in ('python3',):
            self.shim_for(name, 'case "$*" in *pending-events.py*|*wake-rules.py*)\n'
                          '  for f in /proc/$$/fd/*; do t=$(readlink "$f"); case "$t" in *.wait.lock)\n'
                          '    echo "$* holds $t" >> "$TEST_ROOT/fdlog";; esac; done;; esac\n'
                          f'exec {self.real["python3"]} "$@"\n')
        self.env['CHIEF_WAIT_WORKER_EVENT'] = self.script('event', 'cat >/dev/null\necho "HANDLED auto-go N1"\n')
        self.env.update(CHIEF_WAIT_INTERVAL='1')
        self.script('tick', 'echo "TICK workers=0 livestate=0 prs=none tails=none acts=none workerset=0 board=ok tracker=ok denials=0 capacity=FULL station=BEHIND:pending"\n')
        p, out = self.direct('out')
        self.until(lambda: 'WAKE station' in out.read_text() or p.poll() is not None, seconds=8)
        p.wait(timeout=6)
        log = (self.root / 'fdlog').read_text() if (self.root / 'fdlog').exists() else ''
        self.assertEqual(log, '', 'a helper holding fd 9 would keep the lock past a killed waiter')

    def helper_pids(self):
        found = []
        for entry in Path('/proc').iterdir():
            if entry.name.isdigit():
                try:
                    cmd = (entry / 'cmdline').read_bytes()
                except OSError:
                    continue
                if b'pending-events.py' in cmd and str(self.inbox).encode() in cmd:
                    found.append(int(entry.name))
        return found

    def lock_holders(self):
        lock = str(self.path('lock'))
        found = []
        for entry in Path('/proc').iterdir():
            if entry.name.isdigit():
                try:
                    for fd in (entry / 'fd').iterdir():
                        if os.readlink(fd) == lock:
                            found.append((int(entry.name), fd.name,
                                          (entry / 'cmdline').read_bytes().replace(b'\0', b' ')[:100].decode()))
                except OSError:
                    continue
        return found

    def hang_on_a_fifo(self):
        (self.root / 'N1.md').unlink()
        os.mkfifo(self.root / 'N1.md')

    def test_a_blocked_helper_does_not_keep_a_killed_waiters_lock(self):
        self.hang_on_a_fifo()
        self.env['CHIEF_WAIT_PENDING_TIMEOUT'] = '30'
        p, _ = self.direct('out')
        try:
            self.until(self.helper_pids)
            os.kill(p.pid, signal.SIGKILL)
            p.wait(timeout=5)
            probe = subprocess.run(['flock', '-n', str(self.path('lock')), 'true'])
            self.assertEqual(probe.returncode, 0, f'the one-waiter lock must die with the waiter: {self.lock_holders()}')
        finally:
            for pid in self.helper_pids():
                os.kill(pid, signal.SIGKILL)

    def test_a_hung_pending_pass_is_no_events_this_pass_and_the_waiter_retries(self):
        self.hang_on_a_fifo()
        self.env['CHIEF_WAIT_PENDING_TIMEOUT'] = '1'
        self.env['CHIEF_WAIT_WORKER_EVENT'] = self.script('event', 'cat >> "$TEST_ROOT/events"\necho "HANDLED auto-go N1"\n')
        # state that a wrong "nothing exists" answer would erase
        digest = hashlib.sha256(f'- 10:00 READY #1 {self.H1}'.encode()).hexdigest()
        self.path('ready').write_text('N1\t3\n')
        self.path('ready-docs').write_text(json.dumps(dict(N1=dict(ready=[[3, digest]]))))
        before =(self.path('ready').read_text(), self.path('ready-docs').read_text())
        p, out = self.direct('out')
        self.until(lambda: self.path('pending-diagnostic').exists() and
                   'no events this pass' in self.path('pending-diagnostic').read_text(), seconds=8)
        time.sleep(.2)  # the document is repaired before a third timeout in a row wakes the chief
        self.assertIsNone(p.poll(), out.read_text())
        self.assertNotIn('waiter-error', out.read_text())
        self.assertFalse(self.path('pending-error').exists())
        self.assertEqual((self.path('ready').read_text(), self.path('ready-docs').read_text()), before)
        (self.root / 'N1.md').unlink()
        (self.root / 'N1.md').write_text(f'# N1\n- 09:00 LIVE start\n- 10:00 READY #1 {self.H1}\n'
                                         f'- 10:30 READY #2 {"2" * 40}\n')
        self.until(lambda: any('READY #2' in c for c in self.calls()), seconds=8)
        self.assertEqual([c for c in self.calls() if 'READY' in c], [f'N1 READY #2 {"2" * 40}'])

    def test_repeated_pending_timeouts_wake_once_and_again_only_after_recovery(self):
        self.hang_on_a_fifo()
        self.env.update(CHIEF_WAIT_PENDING_TIMEOUT='1', CHIEF_WAIT_PENDING_DOC_TIMEOUT='30')
        first, first_out = self.direct('out1')
        self.assertEqual(first.wait(timeout=12), 0, first_out.read_text())  # three timeouts in a row wake the chief
        wakes = [line for line in first_out.read_text().splitlines() if line.startswith('WAKE waiter-error pending-events')]
        self.assertEqual(len(wakes), 1, first_out.read_text())
        self.assertIn('passes=3', wakes[0])
        self.assertEqual(self.path('pending-timeouts').read_text().splitlines()[0], '3')
        second, second_out = self.direct('out2')  # re-armed over the same hang: quiet
        time.sleep(4.5)
        self.assertIsNone(second.poll(), second_out.read_text())
        self.assertNotIn('WAKE', second_out.read_text())
        (self.root / 'N1.md').unlink()  # a pass that answers ends the streak
        (self.root / 'N1.md').write_text('# N1\n- 09:00 LIVE start\n')
        self.until(lambda: not self.path('pending-timeouts').exists(), seconds=8)
        (self.root / 'N1.md').unlink()  # and a new hang wakes again
        os.mkfifo(self.root / 'N1.md')
        self.assertEqual(second.wait(timeout=12), 0, second_out.read_text())
        self.assertEqual(second_out.read_text().count('WAKE waiter-error pending-events'), 1)

    def test_one_blocked_document_neither_stops_a_peers_events_nor_goes_unreported(self):
        n2 = self.root / 'N2.md'
        n2.write_text(f'# N2\n- 10:00 READY #2 {"2" * 40}\n')
        self.fleet.write_text(json.dumps(dict(workers=[dict(label='N1', doc=str(self.n1)), dict(label='N2', doc=str(n2))])))
        self.hang_on_a_fifo()
        self.env.update(CHIEF_WAIT_PENDING_TIMEOUT='20', CHIEF_WAIT_PENDING_DOC_TIMEOUT='1')
        self.env['CHIEF_WAIT_WORKER_EVENT'] = self.script('event', 'cat >> "$TEST_ROOT/events"\necho "HANDLED auto-go N2"\n')
        p, out = self.direct('out')
        self.until(lambda: any('READY #2' in c for c in self.calls()), seconds=8)
        self.assertEqual(p.wait(timeout=8), 0, out.read_text())  # the unread warning is a wake, once
        self.assertEqual(out.read_text().count('WAKE waiter-error worker-doc-unread worker=N1'), 1, out.read_text())
        self.assertEqual([c for c in self.calls() if 'READY' in c], [f'N2 READY #2 {"2" * 40}'])
        again, again_out = self.direct('out-rearmed')  # the streak persists across a re-arm: no second warning
        time.sleep(3.0)
        self.assertIsNone(again.poll(), again_out.read_text())
        self.assertNotIn('WAKE', again_out.read_text())

    def test_a_ready_after_a_lone_cr_is_relayed_not_stalled(self):
        self.env['CHIEF_WAIT_WORKER_EVENT'] = self.script('event', 'cat >> "$TEST_ROOT/events"\necho "HANDLED auto-go N1"\n')
        self.n1.write_bytes(f'# N1\n- 09:00 LIVE progress 10%\r100%\n- 10:00 READY #1 {self.H1}\n- 10:01 LIVE after\n'.encode())
        p, out = self.direct('out')
        self.until(lambda: self.path('ready').exists() and self.path('ready').read_text() == 'N1\t3\n')
        p.terminate()
        p.wait(timeout=6)
        self.assertEqual(self.calls(), [f'N1 READY #1 {self.H1}'])
        self.assertNotIn('WAKE', out.read_text())


def load_collector():
    spec = importlib.util.spec_from_file_location('pending_events', HERE / 'pending-events.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class IdleCost(stream_tests.StreamFixture):
    """The collector's idle pass: its checksum, the unchanged-document skip and the state it writes."""
    LINES = [b'- 10:00 READY #12 ' + b'a' * 40 + b' GREEN', b'', b'x' * 200000, b'- READY \xff\xfe not utf-8',
             b'- LIVE \xe2\x80', b'- LIVE progress 10%\r100%', b'- LIVE ends with a CR\r', b'- LIVE trailing   ',
             b'- LIVE tab\t', b'   ', b'\r', '- MERGED #7 → abcdef01 (ticket)'.encode(), b'-n',
             b'-e \\n \\x41 %s %d', b'- READY nul\x00inside', b'\x00', b'\xff' * 5000,
             b'- WRAPPED \'quoted\' "double" $HOME `tick`', b'a\x80b\xc3(c']

    def setUp(self):
        super().setUp()
        self.module = load_collector()
        self.reads = []
        real = self.module.read_lines

        def counting(doc, bound):
            self.reads.append(Path(doc).name)
            return real(doc, bound)
        self.module.read_lines = counting

    def aged(self):
        # a document counts as old enough after 50 ms here, not after the real margin
        self.module.RACY_NS = 50_000_000

    def worker_doc(self, text):
        path = self.root / 'N1.md'
        path.write_bytes(text)
        self.fleet.write_text(json.dumps(dict(workers=[dict(label='N1', doc=str(path))])))
        return path

    def collect(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            self.module.candidates(str(self.fleet), str(self.inbox), '')
        return out.getvalue().splitlines()

    def shell_sums(self, lines):
        """What r0_relay records for line n: `sed -n Np` held in a variable, printed with printf, through cksum."""
        doc = self.root / 'parity.txt'
        doc.write_bytes(b''.join(line + b'\n' for line in lines))
        script = ('for n in $(seq 1 %d); do bullet="$(sed -n "${n}p" "$1")"; '
                  'printf "%%s\\n" "$bullet" | cksum | cut -d" " -f1; done' % len(lines))
        return subprocess.run(['bash', '-c', script, 'parity', str(doc)], capture_output=True, text=True,
                              check=True).stdout.split()

    def test_the_checksum_equals_the_shell_cksum_of_the_line_the_relay_holds(self):
        import random
        rng = random.Random(1234)
        lines = list(self.LINES) + [bytes(rng.choice([c for c in range(256) if c != 10])
                                          for _ in range(rng.randint(0, 300))) for _ in range(150)]
        self.assertEqual([self.module.checksum(line) for line in lines], self.shell_sums(lines))

    def test_a_handled_cleanup_bullet_with_non_utf8_bytes_is_not_offered_again(self):
        line = b'- 11:00 MERGED #7 \xff\xfe done'
        self.worker_doc(b'# N1\n' + line + b'\n')
        self.path('r0').write_text(f'N1 MERGED {self.shell_sums([line])[0]}\n')
        self.assertEqual(self.collect(), [])

    def test_the_collector_spawns_no_cksum(self):
        import shutil
        line ='- 11:00 MERGED #7 → abcdef01 (N1, ticket)'
        self.worker_doc(f'# N1\n{line}\n'.encode())
        digest = subprocess.run(['cksum'], input=line + '\n', capture_output=True, text=True, check=True).stdout.split()[0]
        self.path('r0').write_text(f'N1 MERGED {digest}\n')
        real = shutil.which('cksum')
        shim = self.root / 'shim'
        shim.mkdir()
        (shim / 'cksum').write_text(f'#!/bin/sh\necho spawned >> "$TEST_ROOT/cksum-calls"\nexec {real} "$@"\n')
        (shim / 'cksum').chmod(0o755)
        env = dict(os.environ, PATH=f'{shim}:{os.environ["PATH"]}', TEST_ROOT=str(self.root))
        result = subprocess.run(['python3', '-I', str(HERE / 'pending-events.py'), str(self.fleet), str(self.inbox), ''],
                                env=env, capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout), (0, ''), result.stderr)
        self.assertFalse((self.root / 'cksum-calls').exists(), 'the collector computes the sum itself')

    def test_an_unchanged_document_is_not_read_again(self):
        self.aged()
        self.worker_doc(b'# N1\n- 10:00 LIVE a\n')
        time.sleep(.1)
        self.collect()
        first = len(self.reads)
        for _ in range(3):
            self.assertEqual(self.collect(), [])
        self.assertEqual(len(self.reads), first, 'a document whose stamp did not move is not read again')

    def test_a_skipped_document_still_offers_its_pending_event_until_it_is_handled(self):
        self.aged()
        self.worker_doc(f'# N1\n- 10:00 LIVE a\n- 10:01 READY #1 {"1" * 40}\n- 10:02 MERGED #1 done\n'
                 f'- 10:03 READY #2 {"2" * 40}\n'.encode())
        time.sleep(.1)
        self.assertEqual(self.collect(), ['N1 READY 5'])
        reads = len(self.reads)
        self.assertEqual(self.collect(), ['N1 READY 5'])
        self.path('ready').write_text('N1\t5\n')
        self.assertEqual(self.collect(), [])
        self.assertEqual(len(self.reads), reads, 'the cached summary answers; the file is not read')

    def test_an_appended_bullet_is_seen_on_the_next_pass(self):
        self.aged()
        path = self.worker_doc(b'# N1\n- 10:00 LIVE a\n')
        time.sleep(.1)
        self.collect()
        self.collect()
        with path.open('a') as f:
            f.write('- 10:01 MERGED #1 done\n')
        self.assertEqual(self.collect(), ['N1 MERGED 3'])

    def test_a_rewrite_of_the_same_size_with_the_same_modification_time_is_seen(self):
        self.aged()
        path = self.worker_doc(b'- 10:00 LIVE start\n- 10:01 LIVE aaaaa\n')
        time.sleep(.1)
        self.collect()
        self.collect()
        before = path.stat()
        path.write_bytes(b'- 10:00 LIVE start\n- 10:01 MERGED #12\n')
        os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
        after = path.stat()
        self.assertEqual((after.st_size, after.st_mtime_ns), (before.st_size, before.st_mtime_ns))
        self.assertEqual(self.collect(), ['N1 MERGED 2'])

    def test_a_file_replaced_by_another_with_an_older_or_the_same_stamp_is_seen(self):
        self.aged()
        path = self.worker_doc(b'- 10:00 LIVE start\n- 10:01 LIVE aaaaa\n')
        time.sleep(.1)
        self.collect()
        self.collect()
        old = path.stat()
        other = self.root / 'other.md'
        other.write_bytes(b'- 10:00 LIVE start\n- 10:01 MERGED #12\n')
        os.utime(other, ns=(old.st_atime_ns, old.st_mtime_ns - 5_000_000_000))
        os.replace(other, path)
        self.assertEqual(self.collect(), ['N1 MERGED 2'])
        self.collect()
        cached = path.stat()
        other.write_bytes(b'- 10:00 LIVE start\n- 10:01 WRAPPED #1\n')
        os.utime(other, ns=(cached.st_atime_ns, cached.st_mtime_ns))
        os.replace(other, path)
        replaced = path.stat()
        self.assertEqual((replaced.st_size, replaced.st_mtime_ns), (cached.st_size, cached.st_mtime_ns))
        self.assertEqual(self.collect(), ['N1 WRAPPED 2'])

    def test_a_document_written_just_now_is_read_again_until_it_is_older_than_the_margin(self):
        self.worker_doc(b'# N1\n- 10:00 LIVE a\n')
        self.collect()
        reads = len(self.reads)
        self.collect()
        self.assertEqual(len(self.reads), reads + 1, 'a stamp inside the timestamp resolution is not trusted')

    def test_the_skip_trusts_a_stamp_only_when_every_part_matches_and_it_is_old_enough(self):
        unchanged, margin = self.module.unchanged, self.module.RACY_NS
        stamp = [1, 2, 100, 5_000_000_000, 6_000_000_000]
        record = dict(stamp=stamp, at=6_000_000_000 + margin)
        self.assertTrue(unchanged(record, stamp))
        self.assertFalse(unchanged(dict(record, at=record['at'] - 1), stamp), 'changed within the margin of the read')
        for part in range(5):
            other = list(stamp)
            other[part] += 1
            self.assertFalse(unchanged(record, other), f'stamp part {part}')
        for bad in (None, {}, dict(stamp=stamp), dict(at=record['at']), dict(stamp='x', at=1), dict(stamp=stamp, at='x')):
            self.assertFalse(unchanged(bad, stamp), repr(bad))

    def test_state_files_are_written_only_when_their_content_changes(self):
        self.aged()
        path = self.worker_doc(f'# N1\n- 10:00 LIVE a\n- 10:01 READY #1 {"1" * 40}\n'.encode())
        time.sleep(.1)
        self.collect()

        def marks():
            return [(s.st_ino, s.st_mtime_ns, s.st_ctime_ns) for s in
                    (self.path('ready').stat(), self.path('ready-docs').stat())]
        settled = marks()
        for _ in range(3):
            time.sleep(.02)
            self.collect()
            self.assertEqual(marks(), settled, 'an idle pass rewrites nothing')
        with path.open('a') as f:
            f.write('- 10:02 READY #2 ' + '2' * 40 + '\n')
        self.collect()
        self.assertNotEqual(marks(), settled, 'a change is still written')


class RetryPace(stream_tests.StreamFixture):
    """How long the collector holds a refused cleanup back: the ladder's steps and what starts it over."""
    STEPS = (5, 10, 30, 120, 300)  # the retry window (5 s) times 1, 2, 6, 24 and 60
    REFUSED = 'ESCALATE wrap-merged-failed rc=4 close-wrapped-worker: refusing - not WRAPPED\n'

    def setUp(self):
        super().setUp()
        self.page = self.root / 'N1.md'
        self.page.write_text('# N1\n- 10:00 MERGED #1 done\n')
        self.fleet.write_text(json.dumps(dict(workers=[dict(label='N1', doc=str(self.page))])))

    def collect(self, **env):
        done = subprocess.run(['python3', '-I', str(HERE / 'pending-events.py'), str(self.fleet), str(self.inbox), ''],
                              capture_output=True, text=True, env=dict(os.environ, **env))
        self.assertEqual(done.returncode, 0, done.stderr)  # a crashed collector must not read as "nothing offered"
        return done.stdout.splitlines()

    def refused(self, age, text=REFUSED):
        out = self.path('le-N1')
        out.write_text(text)
        stamp = time.time() - age
        os.utime(out, (stamp, stamp))

    BULLET = '- 10:00 MERGED #1 done'

    def key(self, line):
        # the relay's key for an event: the cksum of its bullet
        return subprocess.run(['cksum'], input=line + '\n', capture_output=True, text=True, check=True).stdout.split()[0]

    def tries(self, count, line=BULLET):
        self.path('le-N1.tries').write_text(f'{count} {self.key(line)} -\n')

    def test_the_hold_grows_in_fixed_steps_and_stops_at_the_top(self):
        for count in range(1, 9):
            step = self.STEPS[min(count, len(self.STEPS)) - 1]
            self.tries(count)
            self.refused(step - 1)
            self.assertEqual(self.collect(), [], f'refusal {count}: held for {step} s')
            self.refused(step + 1)
            self.assertEqual(self.collect(), ['N1 MERGED 2'], f'refusal {count}: offered again after {step} s')

    def test_it_only_paces_the_event_is_always_offered_again(self):
        self.tries(5)
        self.refused(100_000)
        self.assertEqual(self.collect(), ['N1 MERGED 2'])

    def test_a_refusal_dated_in_the_future_is_offered_not_held(self):
        # a clock stepped back leaves the refusal record ahead of now: that proves nothing about how recent it is
        for ahead in (3600, 86400):
            with self.subTest(ahead=ahead):
                self.path('le-N1.tries').unlink(missing_ok=True)
                self.refused(-ahead)
                self.assertEqual(self.collect(), ['N1 MERGED 2'])
                self.tries(5)
                self.refused(-ahead)
                self.assertEqual(self.collect(), ['N1 MERGED 2'], 'even at the top step')
        self.path('le-N1.tries').unlink(missing_ok=True)
        self.refused(1)
        self.assertEqual(self.collect(), [], 'a young refusal is still held')
        self.refused(100)
        self.assertEqual(self.collect(), ['N1 MERGED 2'], 'an old one is still offered')

    def test_a_changed_event_starts_the_ladder_over(self):
        self.tries(5)
        with self.page.open('a') as f:
            f.write('- 10:01 WRAPPED all done\n')  # a newer cleanup bullet: another event
        self.refused(4)
        self.assertEqual(self.collect(), [], 'back at the first step, 5 s')
        self.refused(6)
        self.assertEqual(self.collect(), ['N1 WRAPPED 3'])

    def test_an_unrelated_document_change_keeps_the_step(self):
        self.tries(5)
        with self.page.open('a') as f:
            f.write('- 10:01 LIVE still working\n- 10:02 FINDING a note\n')
        self.refused(100)
        self.assertEqual(self.collect(), [], 'still the top step, 300 s')
        self.refused(301)
        self.assertEqual(self.collect(), ['N1 MERGED 2'])

    def test_the_oldest_of_several_pending_ready_bullets_is_paced_by_its_own_bullet(self):
        old, new = f'- 10:00 READY #1 {"1" * 40}', f'- 10:01 READY #2 {"2" * 40}'
        self.page.write_text(f'# N1\n{old}\n{new}\n')
        self.path('ready').write_text('N1\t1\n')  # the cursor is above both: both are pending, the oldest is offered
        text = 'ESCALATE series-find-failed rc=3 the ledger is locked\n'
        self.tries(5, old)
        self.refused(100, text)
        self.assertEqual(self.collect(), [], 'its own count: the top step')
        self.tries(5, new)  # the newest bullet's count is not the oldest's
        self.refused(6, text)
        self.assertEqual(self.collect(), ['N1 READY 2'])

    def test_a_refused_ready_is_paced_by_its_own_bullet(self):
        ready = f'- 10:00 READY #1 {"1" * 40}'
        self.page.write_text(f'# N1\n{ready}\n')
        text = 'ESCALATE series-find-failed rc=3 the ledger is locked\n'
        self.tries(5, ready)
        self.refused(100, text)
        self.assertEqual(self.collect(), [], 'the top step, 300 s')
        self.tries(5, '- 10:00 READY #1 ' + '2' * 40)  # the count belongs to another bullet
        self.refused(6, text)
        self.assertEqual(self.collect(), ['N1 READY 2'])

    def test_no_count_or_a_torn_one_means_the_first_step(self):
        for text in (None, 'garbage', '3\n', '3 17 100 -\n', f'0 {self.key(self.BULLET)} -\n', f'-2 {self.key(self.BULLET)} -\n'):
            with self.subTest(text=text):
                if text is not None:
                    self.path('le-N1.tries').write_text(text)
                self.refused(4)
                self.assertEqual(self.collect(), [])
                self.refused(6)
                self.assertEqual(self.collect(), ['N1 MERGED 2'])

    def test_the_steps_follow_the_retry_window_setting(self):
        self.tries(3)  # 6 times the window
        self.refused(5)
        self.assertEqual(self.collect(CHIEF_WAIT_SERVICE_RETRY_SEC='1'), [])
        self.refused(7)
        self.assertEqual(self.collect(CHIEF_WAIT_SERVICE_RETRY_SEC='1'), ['N1 MERGED 2'])

    def test_a_log_or_board_failure_after_the_close_is_not_held_back_but_a_refused_close_is(self):
        for text, held in (('ESCALATE wrap-merged-failed rc=6 wrap-merged: step log failed: append-results.sh\n', False),
                           ('ESCALATE wrap-merged-failed rc=7 wrap-merged: step board failed: board.mjs --doc x --changed\n', False),
                           ('ESCALATE wrap-merged-failed rc=6 wrap-merged: step close-wrapped-worker failed: '
                            'close-wrapped-worker.sh exited 6\n', True),
                           ('ESCALATE close-wrapped-failed rc=7 close-wrapped-worker: refusing - subagent alive\n', True)):
            with self.subTest(text=text):
                self.refused(0, text)
                self.assertEqual(self.collect(), [] if held else ['N1 MERGED 2'])


if __name__ == '__main__':
    unittest.main()
