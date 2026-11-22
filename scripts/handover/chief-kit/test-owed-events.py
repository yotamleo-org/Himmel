#!/usr/bin/env python3
"""Distinct accepted due clocks and durable acknowledgements, scratch only."""
import datetime
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent


class DueEvents(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.b = Path(self.tmp.name)
        self.now = 1794873600  # 2026-11-17 00:00 UTC, hand-checked by-date boundary

    def owe(self, *args):
        return subprocess.check_output(['bash', str(HERE / 'owe.sh'), *args, '--bucket', str(self.b)], text=True).strip()

    def step(self, due):
        return self.owe('add', '--chief', 'old-chief', '--kind', 'step', '--key', 'HIMMEL-10210',
                        '--text', 'run the accepted action' + ((' by ' + due) if due else ''))

    def run_events(self, readiness=(), now=None):
        r = subprocess.run(['python3', str(HERE / 'owed-events.py'), '--bucket', str(self.b), '--now', str(now or self.now)],
            input=json.dumps(list(readiness)), text=True, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def rows(self):
        return json.loads(self.owe('list', '--all', '--json'))

    def test_keyed_due_boundary_future_and_ack_after_restart(self):
        past = self.step('2026-11-16')
        self.step('2026-11-17')
        self.assertEqual(self.run_events(now=self.now - 1)['stale_ids'], [])
        event = self.run_events()
        self.assertEqual(event['stale_ids'], [past])
        notification = next(r for r in self.rows() if r.get('event') == 'step-due')
        self.owe('close', '--id', notification['id'], '--key', 'delivered')
        self.assertEqual(self.run_events()['stale_ids'], [])
        self.assertEqual(len(self.rows()), 3)

    def test_invalid_or_missing_due_is_reconciliation_not_done(self):
        bad = self.step('2026-02-30')
        missing = self.step(None)
        event = self.run_events()
        self.assertEqual(event['invalid_ids'], [bad, missing])
        self.assertTrue(all(not r['closed'] for r in self.rows()))

    def test_readiness_23h_24h_intervening_and_further_interval(self):
        row = dict(version='v1', key='HIMMEL-10011', stamp='s1:1234567890123456', since='2026-11-16T00:00:00Z', age_s=23*3600)
        self.assertEqual(self.run_events([row])['reminders'], [])
        row['age_s'] = 24*3600
        result = self.run_events([row])
        self.assertEqual(len(result['reminders']), 1)
        self.assertEqual(len(result['operator_digest']), 1)
        for notification in self.rows():
            self.owe('close', '--id', notification['id'], '--key', 'delivered')
        row['age_s'] += 3600
        self.assertEqual(self.run_events([row])['reminders'], [])
        row['age_s'] = 48*3600
        result = self.run_events([row])
        self.assertEqual(len(result['reminders']), 1)
        self.assertEqual(result['operator_digest'], [])

    def owed_step(self, text, actor, due='2026-11-16'):
        return self.owe('add', '--chief', 'old-chief', '--kind', 'step', '--key', 'HIMMEL-10210', '--text', text,
                        '--metadata', json.dumps({'actor': actor, 'action': 'next-step', 'due': due,
                                                  'capability': actor + ' capability', 'wake': 'when due'}))

    def step_due(self):
        return [r for r in self.rows() if r.get('event') == 'step-due']

    def settle_notification(self, step, expect_pending):
        """Evaluate three times with nothing changed: no new notification row, and the unacknowledged one stays pending."""
        before = len(self.rows())
        for _ in range(3):
            result = self.run_events()
            self.assertEqual(result['pending'], expect_pending, 'evaluation with step ' + step + ' unchanged')
            self.assertEqual(len(self.rows()), before, 'no new row for step ' + step)
        return before

    def test_an_overdue_step_notifies_once_and_acknowledgement_silences_it(self):
        step = self.owed_step('run the accepted action', 'worker')
        first = self.run_events()
        notes = self.step_due()
        self.assertEqual(len(notes), 1, 'an overdue step notifies once')
        self.assertEqual((notes[0]['source_id'], first['pending'], first['stale_ids']), (step, [notes[0]['id']], [step]))
        # NOT acknowledged: no second notification row, but the one notification stays pending on every evaluation (the consumer's
        # re-wake interval, not this projection, decides how often it is delivered again)
        self.settle_notification(step, [notes[0]['id']])
        self.assertEqual(len(self.step_due()), 1)
        # acknowledged: the same unchanged step is silent on every later evaluation
        self.owe('close', '--id', notes[0]['id'], '--key', 'delivered')
        for _ in range(3):
            result = self.run_events()
            self.assertEqual((result['pending'], result['stale_ids']), ([], []))
        self.assertEqual(len(self.step_due()), 1)
        self.assertEqual(len(self.rows()), 2)

    def test_a_changed_owner_or_action_notifies_exactly_once_each(self):
        step = self.owed_step('run the accepted action', 'worker')
        self.run_events()
        first = self.step_due()[0]
        self.owe('close', '--id', first['id'], '--key', 'delivered')
        self.settle_notification(step, [])
        # the owed ledger cannot edit a row: a changed owner is a new row that replaces the old one
        self.owe('close', '--id', step, '--key', 'HIMMEL-10210')
        owner = self.owed_step('run the accepted action', 'proof')
        result = self.run_events()
        notes = self.step_due()
        self.assertEqual(len(notes), 2, 'a changed owner produces exactly one new notification')
        self.assertEqual((notes[1]['source_id'], result['pending']), (owner, [notes[1]['id']]))
        self.settle_notification(owner, [notes[1]['id']])  # repeated evaluations in between add none
        self.assertEqual(len(self.step_due()), 2)
        self.owe('close', '--id', notes[1]['id'], '--key', 'delivered')
        self.settle_notification(owner, [])
        self.owe('close', '--id', owner, '--key', 'HIMMEL-10210')
        action = self.owed_step('run the replacement action', 'proof')
        result = self.run_events()
        notes = self.step_due()
        self.assertEqual(len(notes), 3, 'a changed action produces exactly one new notification')
        self.assertEqual((notes[2]['source_id'], result['pending']), (action, [notes[2]['id']]))
        self.settle_notification(action, [notes[2]['id']])
        self.assertEqual(len(self.step_due()), 3)
        self.owe('close', '--id', notes[2]['id'], '--key', 'delivered')
        self.settle_notification(action, [])
        self.assertEqual(len(self.step_due()), 3)

    def test_a_replacement_beside_an_acknowledged_old_row_notifies_only_the_new_row(self):
        old = self.owed_step('run the accepted action', 'worker')
        self.run_events()
        self.owe('close', '--id', self.step_due()[0]['id'], '--key', 'delivered')
        new = self.owed_step('run the accepted action', 'chief')  # the old row is left open and overdue
        result = self.run_events()
        notes = self.step_due()
        self.assertEqual([n['source_id'] for n in notes], [old, new])
        self.assertEqual(result['pending'], [notes[1]['id']])
        self.assertEqual(result['stale_ids'], [new])  # the acknowledged old row is silent, though it stays open and overdue
        self.settle_notification(new, [notes[1]['id']])

    def test_stale_ids_split_by_kind_and_their_union_keeps_the_order(self):
        step = self.step('2026-11-16')
        ticket = subprocess.check_output(
            ['bash', str(HERE / 'owe.sh'), 'add', '--chief', 'old-chief', '--kind', 'ticket', '--text', 'file the lost bug',
             '--bucket', str(self.b)], text=True, env={**os.environ, 'OWE_NOW_EPOCH': str(self.now - 5 * 3600)}).strip()
        event = self.run_events()
        self.assertEqual(event['stale_step_ids'], [step])
        self.assertEqual(event['stale_ticket_ids'], [ticket])
        self.assertEqual(event['stale_ids'], [step, ticket])


C1_LINE = 'chief\t2026-11-27\tProof of Part 1 on a fresh Linux test VM\tProof of Part 1 on a fresh Linux test VM: owed → chief by 2026-11-27'
C1_IDENTITY = '3f3f4ec150b23a8663fcf2697a4bc338be1d1388a434b4e144c3e27bcb616cd7'


class SpoolDrain(unittest.TestCase):
    """The station spool a merge writes and the tick drains into its own ledger, scratch only."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = Path(self.tmp.name)
        self.root = t / 'handover root'
        self.a = self.root / 'chief-a'
        self.b = self.root / 'chief-b'
        for d in (self.a, self.b):
            d.mkdir(parents=True)
        self.spool = t / 'state dir' / 'owe-spool.jsonl'
        self.now = 1794873600
        self.tool = HERE / 'owed-events.py'

    def owe(self, bucket, *args):
        return subprocess.check_output(['bash', str(HERE / 'owe.sh'), *args, '--bucket', str(bucket)], text=True).strip()

    def ledger(self, bucket):
        return json.loads(self.owe(bucket, 'list', '--all', '--json'))

    def steps(self, bucket):
        return [r for r in self.ledger(bucket) if r['kind'] == 'step']

    def put(self, lines, key='HIMMEL-10441', pr=5614, unread=False):
        args = ['python3', '-I', str(self.tool), 'spool', '--spool', str(self.spool), '--key', key, '--pr', str(pr),
                '--repo', 'owner/repo'] + (['--unread'] if unread else [])
        return subprocess.run(args, input=''.join(line + '\n' for line in lines), text=True, capture_output=True)

    def drain(self, bucket=None, root=None, project='HIMMEL', chief='chief-a', now=None, tool=None, env=None):
        args = ['python3', '-I', str(tool or self.tool), '--bucket', str(bucket or self.a), '--now', str(now or self.now),
                '--spool', str(self.spool), '--project', project, '--chief', chief,
                '--handover-root', str(self.root) if root is None else str(root)]
        r = subprocess.run(args, input='[]', text=True, capture_output=True, env={**os.environ, **(env or {})})
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def spooled(self):
        return [json.loads(line) for line in self.spool.read_text().splitlines() if line.strip()]

    def claims(self, bucket=None):
        return [r for r in self.spooled() if r['kind'] == 'claim'
                and (bucket is None or r['bucket'] == os.path.realpath(bucket))]

    def claim(self, identity, bucket):
        with open(self.spool, 'a') as f:
            f.write(json.dumps(dict(kind='claim', schema=1, ts='2026-11-17T00:00:00Z', identity=identity,
                                    bucket=os.path.realpath(bucket))) + '\n')

    def past_step(self, bucket):
        return self.owe(bucket, 'add', '--chief', 'chief-a', '--kind', 'step', '--key', 'HIMMEL-10210',
                        '--text', 'run the accepted action by 2026-11-16')

    def two_lines(self):
        return ['proof\t2026-11-16\tthe live proof\tthe live proof: owed → proof by 2026-11-16',
                'operator\t2026-11-20\trotate the key\trotate the key: owed -> operator by 2026-11-20']

    def test_the_drain_adds_spooled_rows_claims_them_and_projects_them_in_the_same_run(self):
        self.assertEqual(self.put(self.two_lines()).returncode, 0)
        owed = [r for r in self.spooled() if r['kind'] == 'owed']
        self.assertEqual([(r['who'], r['due'], r['schema']) for r in owed], [('proof', '2026-11-16', 1), ('operator', '2026-11-20', 1)])
        result = self.drain()
        rows = self.steps(self.a)
        self.assertEqual([r['identity'] for r in rows], [r['identity'] for r in owed])
        self.assertEqual({r['chief'] for r in rows}, {'chief-a'})
        self.assertEqual(rows[0]['text'], 'HIMMEL-10441 PR #5614: the live proof: owed → proof by 2026-11-16')
        self.assertEqual((rows[0]['actor'], rows[0]['due'], rows[0]['action'], rows[0]['capability'], rows[0]['wake']),
                         ('proof', '2026-11-16', 'next-step', 'read-only proof worker', 'complete the accepted PR #5614 remainder'))
        self.assertEqual(sorted(c['identity'] for c in self.claims(self.a)), sorted(r['identity'] for r in owed))
        self.assertEqual(result['stale_step_ids'], [rows[0]['id']])
        self.assertEqual(result['invalid_ids'], [])
        self.assertTrue(result['summary'].startswith('2:'), result['summary'])
        self.assertEqual(result['spool_bad'], [])

    def test_an_unread_row_drains_into_one_step_due_the_day_before_the_merge(self):
        self.assertEqual(self.put([], unread=True).returncode, 0)
        merged = datetime.datetime.now(datetime.timezone.utc).date()
        result = self.drain(now=int(time.time()))
        rows = self.steps(self.a)
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]['due'], rows[0]['actor']), (str(merged - datetime.timedelta(days=1)), 'chief'))
        self.assertTrue(rows[0]['text'].startswith('HIMMEL-10441 PR #5614: the owed lines of this partial merge could not be read'))
        self.assertEqual(result['stale_step_ids'], [rows[0]['id']])

    def test_a_second_drain_adds_nothing_and_a_closed_row_stays_closed(self):
        self.put(self.two_lines())
        self.drain()
        before = (len(self.steps(self.a)), len(self.claims()))
        self.drain()
        self.assertEqual((len(self.steps(self.a)), len(self.claims())), before)
        first = self.steps(self.a)[1]
        self.owe(self.a, 'close', '--id', first['id'], '--key', 'done-elsewhere')
        self.drain()
        rows = self.steps(self.a)
        self.assertEqual((len(rows), len(self.claims())), before)
        self.assertTrue(next(r for r in rows if r['id'] == first['id'])['closed'])

    def test_two_buckets_of_one_project_the_first_drain_keeps_the_rows(self):
        self.put(self.two_lines())
        self.drain()
        self.drain(bucket=self.b, chief='chief-b')
        self.assertEqual(len(self.steps(self.a)), 2)
        self.assertEqual((self.steps(self.b), self.claims(self.b)), ([], []))

    def test_a_claim_by_this_bucket_with_no_ledger_row_is_added_next_run_and_another_bucket_skips_it(self):
        self.put(self.two_lines()[:1])
        identity = self.spooled()[0]['identity']
        self.claim(identity, self.a)
        self.drain(bucket=self.b, chief='chief-b')
        self.assertEqual(self.steps(self.b), [])
        self.drain()
        self.assertEqual([r['identity'] for r in self.steps(self.a)], [identity])
        self.assertEqual(len(self.claims(self.a)), 1)

    def test_a_claim_by_a_deleted_bucket_is_no_claim(self):
        self.put(self.two_lines()[:1])
        gone = self.root / 'gone'
        gone.mkdir()
        self.claim(self.spooled()[0]['identity'], gone)
        gone.rmdir()
        self.drain()
        self.assertEqual(len(self.steps(self.a)), 1)

    def test_a_bucket_outside_the_handover_root_drains_nothing_and_still_projects(self):
        outside = Path(self.tmp.name) / 'elsewhere' / 'chief-x'
        outside.mkdir(parents=True)
        step = self.past_step(outside)
        self.put(self.two_lines())
        result = self.drain(bucket=outside)
        self.assertEqual([r['id'] for r in self.steps(outside)], [step])
        self.assertEqual(self.claims(), [])
        self.assertEqual(result['stale_step_ids'], [step])

    def test_a_handover_root_reached_through_a_symlink_drains_and_claims_with_the_real_path(self):
        link = Path(self.tmp.name) / 'linked root'
        link.symlink_to(self.root)
        self.put(self.two_lines()[:1])
        self.drain(bucket=link / 'chief-a', root=link)
        self.assertEqual(len(self.steps(self.a)), 1)
        self.assertEqual([c['bucket'] for c in self.claims()], [os.path.realpath(self.a)])

    def test_an_empty_handover_root_drains_nothing_and_still_projects(self):
        step = self.past_step(self.a)
        self.put(self.two_lines())
        result = self.drain(root='')
        self.assertEqual([r['id'] for r in self.steps(self.a)], [step])
        self.assertEqual(self.claims(), [])
        self.assertEqual(result['stale_step_ids'], [step])

    def test_a_row_of_another_project_is_not_drained(self):
        self.put(self.two_lines(), key='SALUS-12')
        self.drain()
        self.assertEqual((self.steps(self.a), self.claims()), ([], []))

    def test_a_torn_last_line_then_a_valid_row_drains_the_valid_one_and_reports_the_torn_line(self):
        self.spool.parent.mkdir(parents=True)
        self.spool.write_text('{"kind":"owed","schema":1,"key":"HIMM')
        self.assertEqual(self.put(self.two_lines()[:1]).returncode, 0)
        self.assertEqual(self.spool.read_text().splitlines()[0], '{"kind":"owed","schema":1,"key":"HIMM')
        result = self.drain()
        rows = self.steps(self.a)
        self.assertEqual(len(rows), 1)
        self.assertEqual(result['spool_bad'], [1])
        self.assertEqual(result['stale_ids'], [rows[0]['id']])

    def test_an_add_the_ledger_refuses_is_reported_claimed_first_and_drained_later(self):
        self.put(self.two_lines())
        refused = self.spooled()[1]['identity']
        kit = Path(self.tmp.name) / 'kit'
        kit.mkdir()
        shutil.copy(self.tool, kit / 'owed-events.py')
        record = Path(self.tmp.name) / 'adds.log'
        (kit / 'owe.sh').write_text(
            '#!/usr/bin/env bash\n'
            'if [ "$1" = add ]; then\n'
            '  id=""; prev=""; for a in "$@"; do [ "$prev" = --identity ] && id=$a; prev=$a; done\n'
            '  if grep -F \'"kind":"claim"\' "$STUB_SPOOL" | grep -F "\\"identity\\":\\"$id\\"" | grep -qF "$STUB_BUCKET"; then c=yes; else c=no; fi\n'
            '  printf \'%s %s\\n\' "$id" "$c" >> "$STUB_RECORD"\n'
            '  [ "$id" != "$STUB_REFUSE" ] || { echo "owe: refused" >&2; exit 2; }\n'
            'fi\n'
            'exec bash "$STUB_REAL" "$@"\n')
        env = dict(STUB_SPOOL=str(self.spool), STUB_BUCKET='"bucket":' + json.dumps(os.path.realpath(self.a)),
                   STUB_RECORD=str(record), STUB_REFUSE=refused, STUB_REAL=str(HERE / 'owe.sh'))
        result = self.drain(tool=kit / 'owed-events.py', env=env)
        self.assertEqual(result['spool_bad'], [2])
        self.assertEqual([r['identity'] for r in self.steps(self.a)], [self.spooled()[0]['identity']])
        spooled = {r['identity'] for r in self.spooled() if r['kind'] == 'owed'}
        adds = [line for line in record.read_text().splitlines() if line.split()[0] in spooled]
        self.assertEqual([line.split()[1] for line in adds], ['yes', 'yes'], adds)
        result = self.drain()
        self.assertEqual(result['spool_bad'], [])
        self.assertEqual(len(self.steps(self.a)), 2)
        self.assertEqual(sorted(c['identity'] for c in self.claims(self.a)), sorted(r['identity'] for r in self.steps(self.a)))

    def test_no_spool_file_is_an_empty_spool(self):
        step = self.past_step(self.a)
        result = self.drain()
        self.assertEqual(result['spool_bad'], [])
        self.assertFalse(self.spool.parent.exists())
        self.assertEqual(result['stale_step_ids'], [step])

    def test_a_spool_lock_held_past_the_wait_is_reported_and_the_ledger_is_still_projected(self):
        step = self.past_step(self.a)
        self.put(self.two_lines())
        with open(self.spool, 'a') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            started = time.monotonic()
            result = self.drain(env=dict(OWE_SPOOL_LOCK_WAIT='1'))
            self.assertLess(time.monotonic() - started, 8)
        self.assertEqual(result['spool_bad'], ['file'])
        self.assertEqual(result['stale_step_ids'], [step])
        self.assertTrue(result['summary'].startswith('1:'), result['summary'])
        self.assertEqual(self.claims(), [])

    def test_an_unreadable_spool_is_reported_and_the_ledger_is_still_projected(self):
        step = self.past_step(self.a)
        self.spool.mkdir(parents=True)
        result = self.drain()
        self.assertEqual(result['spool_bad'], ['file'])
        self.assertEqual(result['stale_step_ids'], [step])

    def test_a_short_write_exits_4_and_leaves_the_spool_byte_for_byte(self):
        self.put(self.two_lines()[:1])
        before = self.spool.read_bytes()
        spec = importlib.util.spec_from_file_location('owed_events', self.tool)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        real = os.write

        def short(fd, data):
            real(fd, bytes(data)[:7])
            raise OSError(28, 'No space left on device')
        argv = ['spool', '--spool', str(self.spool), '--key', 'HIMMEL-10441', '--pr', '5615', '--repo', 'owner/repo']
        with mock.patch('os.write', short), mock.patch.object(sys, 'stdin', io.StringIO(self.two_lines()[1] + '\n')), \
                mock.patch.object(sys, 'stderr', io.StringIO()):
            rc = mod.main(argv)
        self.assertEqual(rc, 4)
        self.assertEqual(self.spool.read_bytes(), before)

    def test_check_lists_bad_lines_and_drop_removes_exactly_those(self):
        self.put(self.two_lines())
        good = self.spool.read_text().splitlines(keepends=True)
        self.spool.write_text(good[0] + 'not json\n' + good[1] + '{"kind":"owed","schema":9}\n' + good[0])
        before = self.spool.read_bytes().split(b'\n')
        check = subprocess.run(['python3', '-I', str(self.tool), 'spool', '--check', '--spool', str(self.spool)],
                               text=True, capture_output=True)
        self.assertEqual((check.returncode, check.stdout), (0, '2\n4\n'), check.stderr)
        drop = subprocess.run(['python3', '-I', str(self.tool), 'spool', '--drop', '2,4', '--spool', str(self.spool)],
                              text=True, capture_output=True)
        self.assertEqual(drop.returncode, 0, drop.stderr)
        self.assertEqual(self.spool.read_bytes(), b'\n'.join([before[0], before[2], before[4], b'']))
        self.drain()
        rows = len(self.steps(self.a))
        self.put(self.two_lines())
        self.drain()
        self.assertEqual(len(self.steps(self.a)), rows)
        self.assertEqual(len(self.claims(self.a)), 2)

    def test_a_row_with_an_unhashable_kind_or_deep_nesting_is_a_bad_line_and_the_rest_drains(self):
        self.put(self.two_lines())
        good = self.spool.read_text().splitlines(keepends=True)
        self.spool.write_text(good[0] + '{"schema":1,"kind":[]}\n' + '[' * 100000 + '\n' + good[1])
        check = subprocess.run(['python3', '-I', str(self.tool), 'spool', '--check', '--spool', str(self.spool)],
                               text=True, capture_output=True)
        self.assertEqual((check.returncode, check.stdout), (0, '2\n3\n'), check.stderr)
        self.assertEqual(self.drain()['spool_bad'], [2, 3])
        self.assertEqual(len(self.steps(self.a)), 2)

    def test_drop_replaces_the_spool_and_never_rewrites_the_file_in_place(self):
        self.put(self.two_lines())
        self.spool.write_text(self.spool.read_text() + 'not json\n')
        before = self.spool.read_bytes()
        with open(self.spool, 'rb') as old:
            drop = subprocess.run(['python3', '-I', str(self.tool), 'spool', '--drop', '3', '--spool', str(self.spool)],
                                  text=True, capture_output=True)
            self.assertEqual(drop.returncode, 0, drop.stderr)
            self.assertEqual(old.read(), before)
        self.assertEqual(self.spool.read_bytes(), before[:before.index(b'not json')])
        self.assertEqual(oct(self.spool.stat().st_mode & 0o777), '0o600')

    def test_an_append_that_waited_on_a_replaced_spool_lands_in_the_new_file(self):
        self.put(self.two_lines()[:1])
        spec = importlib.util.spec_from_file_location('owed_events', self.tool)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        real_lock, waiting, result = mod.spool_lock, threading.Event(), {}

        def lock(fd):
            waiting.set()
            real_lock(fd)
        argv = ['spool', '--spool', str(self.spool), '--key', 'HIMMEL-10441', '--pr', '5615', '--repo', 'owner/repo']
        replacement = self.spool.with_name('replacement')
        replacement.write_bytes(self.spool.read_bytes())
        with open(self.spool, 'rb') as held, mock.patch.object(mod, 'spool_lock', lock), \
                mock.patch.object(sys, 'stdin', io.StringIO(self.two_lines()[1] + '\n')):
            fcntl.flock(held, fcntl.LOCK_EX)
            worker = threading.Thread(target=lambda: result.update(rc=mod.main(argv)))
            worker.start()
            self.assertTrue(waiting.wait(10))
            os.replace(replacement, self.spool)
            fcntl.flock(held, fcntl.LOCK_UN)
            worker.join(20)
        self.assertEqual(result.get('rc'), 0)
        self.assertEqual([r['pr'] for r in self.spooled()], [5614, 5615])

    def test_a_ledger_already_holding_a_backfilled_identity_takes_only_the_claim(self):
        self.owe(self.a, 'add', '--chief', 'chief', '--kind', 'step', '--key', 'HIMMEL-10441', '--identity', C1_IDENTITY,
                 '--text', 'HIMMEL-10441 PR #5614: Proof of Part 1 on a fresh Linux test VM: owed → chief by 2026-11-27')
        self.assertEqual(self.put([C1_LINE]).returncode, 0)
        self.assertEqual(self.spooled()[0]['identity'], C1_IDENTITY)
        self.drain()
        self.assertEqual(len(self.ledger(self.a)), 1)
        self.assertEqual([c['identity'] for c in self.claims(self.a)], [C1_IDENTITY])


if __name__ == '__main__':
    unittest.main()
