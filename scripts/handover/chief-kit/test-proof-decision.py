#!/usr/bin/env python3
"""Scratch chief checks and durable outcomes, paired with denied controls."""
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('records', HERE / 'test-proof-validate.py')
records = importlib.util.module_from_spec(spec)
spec.loader.exec_module(records)


def save_fixture(case, suite):
    destination = os.environ.get('T2_PROOF_EVIDENCE')
    if not destination:
        return
    destination = Path(destination) / suite / case._testMethodName
    destination.mkdir(parents=True, exist_ok=True)
    for name in ('owed.jsonl', 'decision.json', 'evidence.md'):
        path = case.b / name
        if path.is_file():
            shutil.copy2(path, destination / name)
    (destination / 'trace.json').write_text(json.dumps(getattr(case, 'requests', []), indent=2) + '\n')


class ChiefDecision(unittest.TestCase):
    write = records.ProofRecord.write
    module = records.ProofRecord.module
    run_record = records.ProofRecord.run_record
    rows = records.ProofRecord.rows

    def tearDown(self):
        save_fixture(self, 'chief-decision')

    def setUp(self):
        records.ProofRecord.setUp(self)
        stamp = self.module().requirements(self.mirror / 'HIMMEL-9848.md')
        self.evidence.write_text(self.evidence.read_text() + 'requirements-sha256 HIMMEL-9848=' + stamp + '\n')
        self.run_record()
        self.decision = self.b / 'decision.json'
        self.decision.write_text(json.dumps({'identity': self.rows()[0]['identity'], 'verdict': 'CLOSE',
            'coverage': [{'obligation': 'DoD and Proof', 'evidence': 'PASS yes'}],
            'controls': [{'obligation': 'accepted control', 'evidence': 'PASS yes'}],
            'ancestry': 'main=' + 'a'*40 + ' includes the candidate; station is not applicable',
            'rationale': 'Chief reviewed each actual requirement and three empty reads.'}))

    def decide(self, mode='--check', status='Done', env=None, action_id='o1', **extra):
        data = {'key': 'HIMMEL-9848', 'description': self.requirements + '\n', 'status': status,
                'category': 'done' if status == 'Done' else 'new', **extra}
        return subprocess.run(['python3', str(HERE / 'proof-validate.py'), '--bucket', str(self.b), mode, action_id,
            '--decision', str(self.decision), '--current-stdin'], input=json.dumps(data), text=True,
            capture_output=True, timeout=5, env={**os.environ, **(env or {})})

    def change_decision(self, **extra):
        self.decision.write_text(json.dumps({**json.loads(self.decision.read_text()), **extra}))

    def test_check_is_read_only_and_settle_closes_once(self):
        r = self.decide()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.rows()), 1)
        for _ in range(2):
            r = self.decide('--settle')
            self.assertEqual(r.returncode, 0, r.stderr)
        close = [r for r in self.rows() if r['op'] == 'close']
        self.assertEqual(len(close), 1)
        self.assertEqual(close[0]['outcome']['status'], 'Done')
        self.assertEqual(close[0]['outcome']['decision_hash'], self.module().hashlib.sha256(self.decision.read_bytes()).hexdigest())
        self.assertEqual(close[0]['outcome']['decision_json'], self.decision.read_text())
        projected = json.loads(subprocess.check_output(['bash', str(HERE / 'owe.sh'), 'list', '--bucket', str(self.b), '--all', '--json'], text=True))
        self.assertEqual(projected[0]['outcome'], close[0]['outcome'])
        self.run_record()
        self.assertEqual(len(self.rows()), 2)

    def test_dry_run_never_settles_an_action(self):
        result = subprocess.run(['python3', str(HERE / 'proof-validate.py'), '--bucket', str(self.b),
            '--settle', 'o1', '--decision', str(self.decision), '--current-stdin', '--dry-run'],
            input=json.dumps({'key': 'HIMMEL-9848', 'description': self.requirements + '\n', 'status': 'Done', 'category': 'done'}),
            text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.rows()), 1)

    def test_stale_requirements_evidence_or_identity_cannot_close(self):
        original = self.evidence.read_text()
        for which in ('description', 'artifact', 'identity'):
            with self.subTest(which=which):
                extra = {}
                if which == 'description':
                    extra['description'] = self.requirements.replace('two spaces', 'different obligation')
                elif which == 'artifact':
                    self.evidence.write_text(original + 'changed evidence\n')
                else:
                    self.change_decision(identity='f'*64)
                r = self.decide('--settle', **extra)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertEqual(len(self.rows()), 1)
                self.evidence.write_text(original)
                self.change_decision(identity=self.rows()[0]['identity'])

    def test_unconfirmed_or_uncovered_stays_pending(self):
        self.assertNotEqual(self.decide('--settle', status='To Do').returncode, 0)
        for field in ('coverage', 'controls', 'ancestry'):
            saved = json.loads(self.decision.read_text())[field]
            self.change_decision(**{field: [] if field != 'ancestry' else ''})
            self.assertNotEqual(self.decide('--settle').returncode, 0)
            self.change_decision(**{field: saved})
        self.change_decision(coverage=[{'obligation': 'proof', 'evidence': 'unquoted assertion'}])
        self.assertNotEqual(self.decide('--settle').returncode, 0)
        self.assertEqual(len(self.rows()), 1)

    def test_keep_persists_capable_next_owner_before_close_and_replays(self):
        self.change_decision(verdict='KEEP', next={'actor': 'proof', 'capability': 'read-only proof worker',
            'text': 'Run the missing positive control', 'due': '2026-11-20', 'wake': 'after station update'})
        r = self.decide('--settle', status='To Do')
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = self.rows()
        self.assertEqual((rows[1]['actor'], rows[1]['due'], rows[1]['wake']), ('proof', '2026-11-20', 'after station update'))
        self.assertEqual(rows[2]['ref'], 'o1')
        self.assertEqual(self.decide('--settle', status='To Do').returncode, 0)
        self.assertEqual(len(self.rows()), 3)

    def test_keep_failed_next_append_retains_validation(self):
        self.change_decision(verdict='KEEP', next={'actor': 'proof', 'capability': 'worker',
            'text': 'retry control', 'due': 'bad-date', 'wake': 'station updated'})
        r = self.decide('--settle', status='To Do')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(len(self.rows()), 1)

    def test_actual_failed_next_write_cannot_discharge_validation(self):
        self.change_decision(verdict='KEEP', next={'actor': 'worker', 'capability': 'code worker',
            'text': 'Implement missing accepted case', 'due': '2026-11-20', 'wake': 'worker available'})
        writer = self.b / 'refuse-add.sh'
        writer.write_text('#!/bin/bash\n[ "$1" != add ] || exit 4\nexec bash ' + str(HERE / 'owe.sh') + ' "$@"\n')
        result = self.decide('--settle', status='To Do', env={'PROOF_OWE_BIN': str(writer)})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.rows()), 1)

    def test_keep_known_missing_artifact_preserves_a_reconciliation_owner(self):
        self.evidence.unlink()
        self.run_record()
        missing = self.rows()[-1]
        self.change_decision(identity=missing['identity'], verdict='KEEP', next={'actor': 'proof',
            'capability': 'read-only proof worker', 'text': 'Regenerate the missing proof artifact',
            'due': '2026-11-20', 'wake': 'artifact available'})
        result = self.decide('--settle', status='To Do', action_id=missing['id'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.rows()[-2]['actor'], 'proof')
        self.assertEqual(self.rows()[-1]['ref'], missing['id'])

    def test_discharge_covers_only_steps_bound_when_recorded(self):
        ledger = self.b / 'owed.jsonl'
        ledger.unlink()
        def step(text):
            return subprocess.check_output(['bash', str(HERE / 'owe.sh'), 'add', '--bucket', str(self.b),
                '--chief', 'chief', '--kind', 'step', '--key', 'HIMMEL-9848', '--text', text,
                '--metadata', '{"actor":"proof","action":"next-step"}'], text=True,
                env={**os.environ, 'OWE_NOW_EPOCH': '1794860000'}).strip()
        before = step('proof already dispatched')
        self.run_record(env={'OWE_NOW_EPOCH': '1794860000'})
        record = self.rows()[-1]
        self.change_decision(identity=record['identity'])
        later = step('later proof scope in the same clock second')
        r = self.decide('--settle', action_id=record['id'])
        self.assertEqual(r.returncode, 0, r.stderr)
        closed = {row['ref'] for row in self.rows() if row['op'] == 'close'}
        self.assertIn(before, closed)
        self.assertNotIn(later, closed)

    def test_skipped_or_denied_result_rows_cannot_be_closed(self):
        for result in ('OWED', 'SKIPPED', 'ERROR', 'NOT MET'):
            self.evidence.write_text(self.evidence.read_text().replace('| MET |', '| ' + result + ' |'))
            self.run_record()
            new = self.rows()[-1]
            self.change_decision(identity=new['identity'])
            # The exact new pending action is reviewed; no status string can
            # make an unmet control count as successful evidence.
            data = {'key': 'HIMMEL-9848', 'description': self.requirements + '\n', 'status': 'Done', 'category': 'done'}
            response = subprocess.run(['python3', str(HERE / 'proof-validate.py'), '--bucket', str(self.b), '--settle', new['id'],
                '--decision', str(self.decision), '--current-stdin'], input=json.dumps(data), capture_output=True, text=True)
            self.assertNotEqual(response.returncode, 0)
            self.assertFalse(any(r['op'] == 'close' for r in self.rows()))
            self.evidence.write_text(self.evidence.read_text().replace('| ' + result + ' |', '| MET |'))

    def test_done_with_version_pending_keeps_owned_reconciliation(self):
        r = self.decide('--settle', unstamped='frozen version requires placement')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.rows()[1]['action'], 'version-reconciliation')
        self.assertEqual(self.rows()[1]['actor'], 'chief')
        self.assertEqual(self.rows()[2]['outcome']['status'], 'Done')
        self.assertTrue(self.rows()[2]['outcome']['version_pending'])


if __name__ == '__main__':
    unittest.main()
