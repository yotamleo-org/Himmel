#!/usr/bin/env python3
"""Distinct accepted due clocks and durable acknowledgements, scratch only."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

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


if __name__ == '__main__':
    unittest.main()
