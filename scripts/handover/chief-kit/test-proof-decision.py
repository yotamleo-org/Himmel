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
        self.write(stamp=stamp)  # the producer's frozen original lives in the brief, not in the worker's artifact
        self.run_record()
        self.decision = self.b / 'decision.json'
        self.decision.write_text(json.dumps({'identity': self.rows()[0]['identity'], 'verdict': 'CLOSE',
            'coverage': [{'obligation': 'keep two spaces', 'evidence': 'PASS yes'}],
            'controls': [{'obligation': 'Run the positive control.', 'evidence': 'PASS yes'}],
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

    def test_expected_failure_column_is_not_an_unmet_status(self):
        original = self.evidence.read_text()
        header = '\n| Negative control | Expected | Observed | Requirement status |\n|---|---|---|---|\n'
        for name, extra, allowed in (
            ('expected refusal', header + '| malformed input is refused | FAIL (exit 26) | exit 26, refused as expected | MET |\n', True),
            ('actual failure', header + '| malformed input | FAIL (exit 26) | unexpected exit | FAIL (unexpected exit 26) |\n', False),
            ('separate unlabeled table', header + '| malformed input | FAIL | refused | MET |\n\n| actual result | FAIL |\n', False),
            ('no table separator', '\n| Negative control | Expected | Requirement status |\n| input | FAIL | MET |\n', False),
        ):
            with self.subTest(name=name):
                self.evidence.write_text(original + extra)
                self.run_record()
                action = self.rows()[-1]
                self.change_decision(identity=action['identity'])
                result = self.decide(action_id=action['id'])
                if allowed:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0)

    def test_dry_run_never_settles_an_action(self):
        result = subprocess.run(['python3', str(HERE / 'proof-validate.py'), '--bucket', str(self.b),
            '--settle', 'o1', '--decision', str(self.decision), '--current-stdin', '--dry-run'],
            input=json.dumps({'key': 'HIMMEL-9848', 'description': self.requirements + '\n', 'status': 'Done', 'category': 'done'}),
            text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.rows()), 1)

    def test_stale_requirements_evidence_or_identity_cannot_close(self):
        original = self.evidence.read_text()
        # Done plus changed requirements is not a refusal to lose: it keeps the validation open and persists an owned reconciliation
        # (test_done_then_changed_requirements_...); a ticket that is not actually Done still refuses with nothing written.
        r = self.decide('--settle', status='To Do', description=self.requirements.replace('two spaces', 'different obligation'))
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertEqual(len(self.rows()), 1)
        for which in ('artifact', 'identity'):
            with self.subTest(which=which):
                extra = {}
                if which == 'artifact':
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

    UNMET_FORMS = ['| NOT MET — no RED |', '| NOT MET |', '| FAIL |', '| FAILED (timeout) |', '| ERRORS |', '| ERROR: boom |', '| SKIPPED (no vm) |', '| OWED |']

    def pending_with(self, evidence):
        self.evidence.write_text(evidence)
        self.run_record()
        new = self.rows()[-1]
        self.change_decision(identity=new['identity'])
        return new

    def check(self, row):
        data = {'key': 'HIMMEL-9848', 'description': self.requirements + '\n', 'status': 'Done', 'category': 'done'}
        return subprocess.run(['python3', str(HERE / 'proof-validate.py'), '--bucket', str(self.b), '--check', row['id'],
            '--decision', str(self.decision), '--current-stdin'], input=json.dumps(data), capture_output=True, text=True)

    def test_every_qualified_unmet_or_error_format_blocks_the_mechanical_close_check(self):
        good = self.evidence.read_text()
        stamp = self.module().requirements(self.mirror / 'HIMMEL-9848.md')
        self.write(stamp=stamp)
        for form in self.UNMET_FORMS:
            with self.subTest(form=form):
                row = self.pending_with(good.replace('| MET |', form))
                self.assertEqual(row['binding'], 'matched')
                r = self.check(row)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn('unmet/skipped/error proof row', r.stderr)
        for item in ('- NOT MET: control two', '* ERROR control two timed out', '1. FAIL: control two', '+ SKIPPED control two'):
            with self.subTest(item=item):
                row = self.pending_with(good + item + '\n')
                r = self.check(row)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn('unmet/skipped/error proof row', r.stderr)

    def test_prose_that_mentions_a_word_is_not_an_unmet_row_and_unknown_coverage_stays_with_the_chief(self):
        good = self.evidence.read_text()
        row = self.pending_with(good + 'The run reported no errors, skipped nothing and nothing failed; every control is OWED nothing.\n| control two | MET | main=' + 'a'*40 + ' | PASS yes |\n')
        r = self.check(row)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)['semantic_coverage'], 'chief-owned')

    def test_a_citation_must_name_a_current_requirement_and_quote_the_evidence(self):
        for field, obligation in (('coverage', 'an obligation nobody wrote'), ('controls', 'a control invented in the decision')):
            with self.subTest(field=field):
                saved = json.loads(self.decision.read_text())[field]
                self.change_decision(**{field: [{'obligation': obligation, 'evidence': 'PASS yes'}]})
                r = self.decide('--check')
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn('names no current DoD/Proof requirement', r.stderr)
                self.change_decision(**{field: saved})
        # whitespace and case are folded; a real requirement quoted any way passes
        self.change_decision(coverage=[{'obligation': 'KEEP  two\nSPACES', 'evidence': 'PASS yes'}])
        self.assertEqual(self.decide('--check').returncode, 0)

    def changed(self):
        return self.requirements.replace('two spaces', 'three spaces')

    def reconciliations(self):
        return [r for r in self.rows() if r.get('action') == 'requirements-reconciliation']

    def test_done_then_changed_requirements_persists_one_owned_idempotent_reconciliation(self):
        old = self.rows()[0]['requirements_digest']
        new = self.module().requirement_text('## Description\n' + self.changed() + '\n')
        for _ in range(3):  # a replay, and a replay after a lost response, read the same facts and add nothing
            r = self.decide('--settle', description=self.changed() + '\n')
            self.assertEqual(r.returncode, 0, r.stderr)
            body = json.loads(r.stdout)
            self.assertFalse(body['closed'])
            self.assertEqual(body['reconciliation'], self.reconciliations()[0]['id'])
        rec = self.reconciliations()
        self.assertEqual(len(rec), 1)
        self.assertEqual((rec[0]['kind'], rec[0]['actor'], rec[0]['actual_status']), ('step', 'chief', 'Done'))
        self.assertEqual((rec[0]['original_requirements_digest'], rec[0]['requirements_digest']), (old, new))
        self.assertEqual(rec[0]['source_id'], 'o1')
        self.assertIn('Done', rec[0]['text'])
        self.assertIn('decide whether to reopen', rec[0]['text'])
        self.assertFalse(any(r['op'] == 'close' for r in self.rows()), 'the validation stays unresolved')
        # the original requirements, read again, still settle the same validation normally
        self.assertEqual(self.decide('--settle').returncode, 0)
        self.assertEqual(len([r for r in self.rows() if r['op'] == 'close' and r['ref'] == 'o1']), 1)

    def test_changed_requirements_without_an_actual_done_status_or_in_check_mode_write_nothing(self):
        for kwargs in (dict(status='To Do', description=self.changed() + '\n'),):
            r = self.decide('--settle', **kwargs)
            self.assertNotEqual(r.returncode, 0)
        r = self.decide('--check', description=self.changed() + '\n')
        self.assertNotEqual(r.returncode, 0)
        dry = subprocess.run(['python3', str(HERE / 'proof-validate.py'), '--bucket', str(self.b), '--settle', 'o1', '--decision', str(self.decision),
                              '--current-stdin', '--dry-run'], input=json.dumps({'key': 'HIMMEL-9848', 'description': self.changed() + '\n', 'status': 'Done', 'category': 'done'}),
                             text=True, capture_output=True)
        self.assertNotEqual(dry.returncode, 0)
        self.assertEqual(self.reconciliations(), [])
        self.assertEqual(len(self.rows()), 1)

    def test_a_replay_names_the_open_reconciliation_instead_of_silently_failing(self):
        self.assertEqual(self.decide('--settle', description=self.changed() + '\n').returncode, 0)
        r = self.decide('--check', description=self.changed() + '\n')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('requirements-reconciliation ' + self.reconciliations()[0]['id'], r.stderr)

    def test_done_with_version_pending_keeps_owned_reconciliation(self):
        r = self.decide('--settle', unstamped='frozen version requires placement')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.rows()[1]['action'], 'version-reconciliation')
        self.assertEqual(self.rows()[1]['actor'], 'chief')
        self.assertEqual(self.rows()[2]['outcome']['status'], 'Done')
        self.assertTrue(self.rows()[2]['outcome']['version_pending'])

    def step(self, text, actor):
        return subprocess.check_output(['bash', str(HERE / 'owe.sh'), 'add', '--bucket', str(self.b),
            '--chief', 'chief', '--kind', 'step', '--key', 'HIMMEL-9848', '--text', text,
            '--metadata', json.dumps({'actor': actor, 'action': 'next-step'})], text=True,
            env={**os.environ, 'OWE_NOW_EPOCH': '1794860000'}).strip()

    def closed_refs(self):
        return {row['ref'] for row in self.rows() if row['op'] == 'close'}

    def test_close_with_a_mixed_code_and_proof_remainder_discharges_only_the_proof_part(self):
        (self.b / 'owed.jsonl').unlink()
        code = self.step('Implement the missing accepted case', 'worker')
        proof = self.step('Run the live proof', 'proof')
        self.run_record(env={'OWE_NOW_EPOCH': '1794860000'})
        record = self.rows()[-1]
        self.assertEqual(record['owed_refs'], [proof])
        self.change_decision(identity=record['identity'])
        before = self.rows()
        r = self.decide('--settle', action_id=record['id'])  # the open code part refuses the CLOSE: nothing is discharged or erased
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('open code/chief step ' + code, r.stderr)
        self.assertEqual(self.rows(), before)
        self.close_row(code)
        for _ in range(2):  # the code part done, the CLOSE discharges only the proof step; a re-read cannot close twice
            r = self.decide('--settle', action_id=record['id'])
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(self.closed_refs(), {code, proof, record['id']})
        self.assertEqual([row for row in self.rows() if row.get('id') == code][0]['actor'], 'worker')
        self.assertEqual(len([row for row in self.rows() if row['op'] == 'close' and row['ref'] == record['id']]), 1)

    def test_an_observation_not_yet_due_cannot_close_and_keeps_its_wake(self):
        good = self.evidence.read_text()
        row = self.pending_with(good + '| 24-hour observation | OWED (due 2026-11-25) | window still open | PASS yes |\n')
        for mode in ('--check', '--settle'):
            r = self.decide(mode, action_id=row['id'])
            self.assertNotEqual(r.returncode, 0, r.stdout)
            self.assertIn('unmet/skipped/error proof row', r.stderr)
        self.assertEqual(len(self.rows()), 2)
        self.assertFalse(any(r['op'] == 'close' for r in self.rows()))
        # the only way forward is a KEEP that names the due wake; it discharges the validation exactly once
        self.change_decision(verdict='KEEP', next={'actor': 'proof', 'capability': 'read-only proof worker',
            'text': 'Read the 24-hour observation once its window closes', 'due': '2026-11-25', 'wake': 'observation window closed'})
        for _ in range(2):
            r = self.decide('--settle', status='To Do', action_id=row['id'])
            self.assertEqual(r.returncode, 0, r.stderr)
        nxt = [r for r in self.rows() if r.get('source_id') == row['id']]
        self.assertEqual([(r['actor'], r['due'], r['wake']) for r in nxt], [('proof', '2026-11-25', 'observation window closed')])
        self.assertEqual(len([r for r in self.rows() if r['op'] == 'close' and r['ref'] == row['id']]), 1)

    def test_close_after_cleanup_with_a_busy_chief_is_settled_once_by_a_successor_and_replays(self):
        code = self.step('Implement the missing accepted case', 'worker')
        # the busy chief reviewed once and never settled; the wrapped worker's brief is then cleaned up
        self.close_row(code)  # the worker finished the code part meanwhile: an open one refuses the CLOSE
        self.assertEqual(self.decide('--check').returncode, 0)
        self.doc.unlink()
        self.assertEqual(len(self.rows()), 3)
        self.assertFalse(any(r['op'] == 'close' and r['ref'] == 'o1' for r in self.rows()))
        # the successor reads the surviving action from the ledger alone and settles it; the predecessor's replay is a re-read
        listed = json.loads(subprocess.check_output(['bash', str(HERE / 'owe.sh'), 'list', '--bucket', str(self.b), '--json'], text=True))
        self.assertIn('o1', [r['id'] for r in listed])
        for _ in range(3):
            r = self.decide('--settle')
            self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len([r for r in self.rows() if r['op'] == 'close' and r['ref'] == 'o1']), 1)
        self.assertEqual(self.closed_refs(), {code, 'o1'})
        self.assertEqual(len(self.rows()), 4)

    def add_row(self, text, kind='step', actor='worker', key='HIMMEL-9848', action='next-step'):
        metadata = {'actor': actor, **({'action': action} if kind == 'step' else {})}
        return subprocess.check_output(['bash', str(HERE / 'owe.sh'), 'add', '--bucket', str(self.b),
            '--chief', 'chief', '--kind', kind, '--key', key, '--text', text, '--metadata', json.dumps(metadata)], text=True,
            env={**os.environ, 'OWE_NOW_EPOCH': '1794860000'}).strip()

    def close_row(self, row_id, key='HIMMEL-9848'):
        subprocess.check_call(['bash', str(HERE / 'owe.sh'), 'close', '--bucket', str(self.b), '--id', row_id, '--key', key])

    def open_ids(self):
        return {row['id'] for row in self.rows() if 'id' in row} - self.closed_refs()

    def test_a_close_is_refused_while_another_actor_owes_an_open_step_and_erases_nothing(self):
        for actor in ('worker', 'chief', 'operator'):
            with self.subTest(actor=actor):
                step = self.add_row('Finish the remaining ' + actor + ' slice', actor=actor)
                before = self.rows()
                for mode in ('--check', '--settle'):  # the check is as read-only as the settle that refuses
                    r = self.decide(mode)
                    self.assertNotEqual(r.returncode, 0, r.stdout)
                    self.assertIn('open code/chief step ' + step, r.stderr)
                    self.assertEqual(self.rows(), before)
                self.assertLessEqual({'o1', step}, self.open_ids())
                self.close_row(step)
        # the remainder done, the same decision now settles, once
        r = self.decide('--settle')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len([row for row in self.rows() if row['op'] == 'close' and row['ref'] == 'o1']), 1)

    def test_a_keep_is_not_blocked_by_an_open_code_step(self):
        step = self.add_row('Implement the missing accepted case')
        self.change_decision(verdict='KEEP', next={'actor': 'proof', 'capability': 'read-only proof worker',
            'text': 'Run the missing positive control', 'due': '2026-11-20', 'wake': 'after station update'})
        r = self.decide('--settle', status='To Do')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('o1', self.closed_refs())
        self.assertIn(step, self.open_ids())

    def test_rows_that_are_not_an_open_remainder_of_this_ticket_do_not_block_a_close(self):
        other_key = self.add_row('Implement an unrelated ticket', key='HIMMEL-10220')
        done = self.add_row('Implement the finished slice')
        self.close_row(done)
        proof_step = self.add_row('Run the live proof', actor='proof')
        ticket_row = self.add_row('File the follow-up ticket', kind='ticket', actor='operator')
        reconcile = self.add_row('Reconcile the changed requirements', actor='chief', action='requirements-reconciliation')
        version = self.add_row('Reconcile version placement', actor='chief', action='version-reconciliation')
        r = self.decide('--settle')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len([row for row in self.rows() if row['op'] == 'close' and row['ref'] == 'o1']), 1)
        # nothing else was discharged or erased: the other rows are exactly as open as they were
        self.assertEqual(self.open_ids(), {other_key, proof_step, ticket_row, reconcile, version})

    PENDING_CELLS = ['PENDING', 'PENDING (due 2026-11-25)', 'not yet due', 'NOT YET DUE — window open', 'WAITING until 2026-11-25',
                     'Waiting for the 24h window', 'TBD', 'pending: window open']
    PENDING_ITEMS = ['- PENDING: the 24h observation', '* Waiting for the observation window', '1. TBD control two', '- **PENDING** control two',
                     '+ NOT YET DUE control two']

    def test_an_observation_not_yet_due_blocks_the_close_whatever_word_the_worker_used(self):
        good = self.evidence.read_text()
        for cell in self.PENDING_CELLS:
            with self.subTest(cell=cell):
                row = self.pending_with(good + '| 24-hour observation | ' + cell + ' | window open | PASS yes |\n')
                r = self.check(row)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn('unmet/skipped/error proof row', r.stderr)
        for item in self.PENDING_ITEMS:
            with self.subTest(item=item):
                row = self.pending_with(good + item + '\n')
                r = self.check(row)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn('unmet/skipped/error proof row', r.stderr)
        # a labeled Expected column is test input, but an actual status of PENDING is not
        header = '\n| Observation | Expected | Observed | Requirement status |\n|---|---|---|---|\n'
        for actual, allowed in (('PENDING', False), ('MET', True)):
            with self.subTest(actual=actual):
                row = self.pending_with(good + header + '| 24h | PENDING | window open | ' + actual + ' |\n')
                self.assertEqual(self.check(row).returncode == 0, allowed)

    def test_a_met_row_that_only_mentions_those_words_stays_closable(self):
        good = self.evidence.read_text()
        met = ('| control two | MET | main=' + 'a'*40 + ' | pending count was 0, PASS yes |\n'
               '| control three | MET | main=' + 'a'*40 + ' | waiting list is empty; tbd none; PASS yes |\n'
               '| control four | MET | main=' + 'a'*40 + ' | PASS: nothing pending, none waiting, not yet due items: none |\n'
               '- pending count was 0 and waiting list is empty\n- tbd items: none\n')
        row = self.pending_with(good + met)
        r = self.check(row)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)['semantic_coverage'], 'chief-owned')


if __name__ == '__main__':
    unittest.main()
