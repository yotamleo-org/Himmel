#!/usr/bin/env python3
"""Distinct accepted due clocks and durable acknowledgements, scratch only."""
import json
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


if __name__ == '__main__':
    unittest.main()
