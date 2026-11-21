#!/usr/bin/env python3
"""Scratch chief checks and durable outcomes, paired with denied controls."""
import importlib.util
import json
import os
import re
import shlex
import shutil
from pathlib import Path
import subprocess
import time
import unittest
from unittest import mock

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

    def pending_artifacts(self, artifacts, keys='HIMMEL-9848'):
        """Record one proof leg that declares every artifact ({file name: text}, in order; None declares a file that does not exist) and return the new HIMMEL-9848 row."""
        paths = [self.b / name for name in artifacts]
        for path, text in zip(paths, artifacts.values()):
            if text is None:
                path.unlink(missing_ok=True)
            else:
                path.write_text(text)
        self.evidence = paths[0]
        self.write(evidence=next(iter(artifacts.values())), keys=keys, tail=''.join(' evidence=' + str(path) for path in paths[1:]),
                   stamp=self.module().requirements(self.mirror / 'HIMMEL-9848.md'))
        self.run_record()
        new = [r for r in self.rows() if r['op'] == 'add' and r.get('key') == 'HIMMEL-9848'][-1]
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

    # A failed list item is unmet whatever marks its status word: the first item, with double asterisks, is the control the others agree with.
    EMPHASISED_FAILED_ITEMS = ['- **NOT MET** control two',
                               '- *NOT MET* station check timed out', '- _NOT MET_ station check timed out', '- `NOT MET` station check timed out',
                               '- __NOT MET__ control two', '- ***NOT MET*** control two', '* *NOT MET* control two',
                               '- *FAIL* control two', '- _FAIL_ control two', '- `FAILED` control two',
                               '- *OWED* control two: needs the operator', '1. `OWED` control two: needs the operator', '- _OWED_ control two',
                               '- *SKIPPED* control two (no vm)', '1. *SKIPPED* control two', '+ `SKIPPED` control two',
                               '- *ERROR* control two timed out', '- _ERRORS_ control two', '- `ERROR` control two']

    def test_a_failed_list_item_blocks_the_close_whatever_emphasis_or_code_marks_its_status_word(self):
        good = self.evidence.read_text()
        self.write(stamp=self.module().requirements(self.mirror / 'HIMMEL-9848.md'))
        for item in self.EMPHASISED_FAILED_ITEMS:
            with self.subTest(item=item):
                row = self.pending_with(good + item + '\n')
                self.assertEqual(row['binding'], 'matched')
                r = self.check(row)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn('unmet/skipped/error proof row', r.stderr)

    # The three spellings of a status that stands after a label and a colon, for each unmet word.
    LABELLED_UNMET_ITEMS = [spelling % word for word in ('NOT MET', 'OWED', 'FAIL', 'SKIPPED', 'ERROR')
                            for spelling in ('- control two: %s', '- **Result:** %s', '- Result: *%s*')]
    LABELLED_UNMET_ITEMS += ['1. control two: OWED (needs the operator)', '* Result: `SKIPPED` - no vm', '+ **Result**: _ERRORS_ timed out', '- __Result:__ **NOT MET** - no RED',
                             '- a: b: Result: FAILED (exit 26)', '- Result:NOT MET']

    def test_an_unmet_word_first_after_the_last_colon_of_a_list_item_blocks_the_close(self):
        good = self.evidence.read_text()
        self.write(stamp=self.module().requirements(self.mirror / 'HIMMEL-9848.md'))
        for item in self.LABELLED_UNMET_ITEMS:
            with self.subTest(item=item):
                row = self.pending_with(good + item + '\n')
                self.assertEqual(row['binding'], 'matched')
                r = self.check(row)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn('unmet/skipped/error proof row', r.stderr)

    def test_a_met_word_or_a_colon_with_no_status_after_it_in_a_list_item_stays_closable(self):
        good = self.evidence.read_text()
        self.write(stamp=self.module().requirements(self.mirror / 'HIMMEL-9848.md'))
        for item in ('- control two: MET', '- control two: *MET*', '- **Result:** MET', '- Result: `MET` (cited)', '1. Result: _MET_', '- Notes: all controls ran and none was skipped',
                     '- ran at 12:30: MET', '- see http://x/y: ok', '- path C:\\dir is fine', '- ERROR_CODE: documented', '- Result: ERROR_CODE documented', '- Result: OWED_ITEMS none'):
            with self.subTest(item=item):
                row = self.pending_with(good + item + '\n')
                self.assertEqual(row['binding'], 'matched')
                r = self.check(row)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(json.loads(r.stdout)['semantic_coverage'], 'chief-owned')

    def test_a_met_list_item_or_prose_beside_those_words_stays_closable_through_any_emphasis_or_code(self):
        good = self.evidence.read_text()
        self.write(stamp=self.module().requirements(self.mirror / 'HIMMEL-9848.md'))
        for item in ('- MET control two', '- *MET* control two', '- _MET_ control two', '- `MET` control two', '- **MET** control two', '- __MET__ control two',
                     '1. `MET` control two', '- control two ran; *nothing* was skipped, no `errors`, nothing _failed_ and nothing OWED',
                     '- ERROR_CODE is documented', '- OWED_ITEMS: none'):
            with self.subTest(item=item):
                row = self.pending_with(good + item + '\n')
                self.assertEqual(row['binding'], 'matched')
                r = self.check(row)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(json.loads(r.stdout)['semantic_coverage'], 'chief-owned')

    # A list item that starts with MET is read by that word alone: the words of its detail after a colon are not read.
    MET_ITEMS_WITH_DETAIL = ['- MET main=aaaa: failures 0', '- MET: skipped 0 tests', '- **MET**: errors.md attached', '- MET control two: errors none', '- MET evidence: ERRORS=0',
                             '- MET evidence=/tmp/x: errors.md', '- MET evidence: skip_validation honoured', '- MET main=aaaa: FAIL-CLOSED verified', '- MET (see log: errors) ok',
                             '- *MET*: FAILED 0', '- `MET` main=aaaa: owed none', '1. _MET_: skipped 0', '* __MET__ control two: errors none']

    def test_a_list_item_that_starts_with_met_is_read_by_that_word_alone_through_the_real_check(self):
        good = self.evidence.read_text()
        self.write(stamp=self.module().requirements(self.mirror / 'HIMMEL-9848.md'))
        for item in self.MET_ITEMS_WITH_DETAIL:
            with self.subTest(met=item):
                row = self.pending_with(good + item + '\n')
                self.assertEqual(row['binding'], 'matched')
                r = self.check(row)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(json.loads(r.stdout)['semantic_coverage'], 'chief-owned')
        # an item that starts with an unmet word is unmet whatever follows it; a word that only begins with MET, or a PASS, does not decide the item
        for item in ('- NOT MET: x', '- **NOT MET**: failures 0', '- Metrics: FAILED 2', '- METHOD: FAIL x', '- MET-based check: NOT MET', '- MET_RUN: NOT MET', '- PASS: FAILED 1'):
            with self.subTest(unmet=item):
                row = self.pending_with(good + item + '\n')
                r = self.check(row)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn('unmet/skipped/error proof row', r.stderr)

    # An unmet word that is the first thing after any colon of an item that does not start with MET counts: the label colon need not be the last one.
    FURTHER_COLON_UNMET_ITEMS = ['- Result: NOT MET: no RED', '- **Result:** NOT MET (x): y', '- Result: *NOT MET*: no RED', '- **Result:** `OWED`: needs the operator',
                                 '- a: b: Result: FAILED: exit 26', '1. Result: SKIPPED: no vm', '* Result: ERROR: boom: more', '- ran at 12:30: NOT MET: no RED',
                                 '- see http://x/y: FAIL: exit 26']

    def test_an_unmet_word_first_after_any_colon_of_a_list_item_blocks_the_close(self):
        good = self.evidence.read_text()
        self.write(stamp=self.module().requirements(self.mirror / 'HIMMEL-9848.md'))
        # the labelled task item and the labelled struck-through item are read as the item's own text, so they are unmet too
        for item in self.FURTHER_COLON_UNMET_ITEMS + ['- [ ] Result: NOT MET', '- ~~Result: NOT MET~~']:
            with self.subTest(item=item):
                row = self.pending_with(good + item + '\n')
                self.assertEqual(row['binding'], 'matched')
                r = self.check(row)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn('unmet/skipped/error proof row', r.stderr)

    def test_a_status_that_is_not_the_first_thing_after_a_colon_stays_closable_through_the_real_check(self):
        good = self.evidence.read_text()
        self.write(stamp=self.module().requirements(self.mirror / 'HIMMEL-9848.md'))
        for item in ('- Result: ok: then NOT MET later', '- Result: ok, then NOT MET: no RED', '- ran at 12:30 FAIL', '- 12:30 FAIL', '- time: 12:30 FAIL', '- see http://x/y NOT MET',
                     '- ran at 12:30: MET', '- see http://x/y: ok', '- path C:\\dir OWED', '- Result: MET (pending review)', '- Result: ERROR_CODE: documented'):
            with self.subTest(item=item):
                row = self.pending_with(good + item + '\n')
                self.assertEqual(row['binding'], 'matched')
                r = self.check(row)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(json.loads(r.stdout)['semantic_coverage'], 'chief-owned')

    def test_an_unmet_word_after_a_colon_is_read_whole_through_the_real_check(self):
        good = self.evidence.read_text()
        self.write(stamp=self.module().requirements(self.mirror / 'HIMMEL-9848.md'))
        for item in ('- Result: failures 0', '- Note: failed-over to the standby', '- Result: skipping nothing', '- Result: FAILURES 0', '- Result: Failures: none',
                     '- Note: FAIL-CLOSED behaviour verified', '- Note: SKIP_CR is unset', '- Note: failover was tested'):
            with self.subTest(other_word=item):
                row = self.pending_with(good + item + '\n')
                self.assertEqual(row['binding'], 'matched')
                r = self.check(row)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(json.loads(r.stdout)['semantic_coverage'], 'chief-owned')
        for item in ('- Result: FAIL', '- Result: FAILED', '- Result: SKIPPED (no vm)', '- Result: failed', '- Result: Skipped', '- Result: SKIP', '- Result: FAILS', '- Result: FAILURE',
                     '- Result: FAILING', '- Result: SKIPS', '- Result: ERROR', '- Result: ERRORS', '- Result: OWED', '- Result: NOT MET'):
            with self.subTest(unmet_word=item):
                row = self.pending_with(good + item + '\n')
                r = self.check(row)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn('unmet/skipped/error proof row', r.stderr)

    def test_a_word_at_the_start_of_an_item_or_in_a_table_cell_is_still_read_by_its_beginning_through_the_real_check(self):
        sha = 'main=' + 'a'*40
        good = self.evidence.read_text()
        self.write(stamp=self.module().requirements(self.mirror / 'HIMMEL-9848.md'))
        for item in ('- failures 3', '- skipping 2', '- FAILURES: 3', '- FAILURE x', '- failed-over to the standby'):
            with self.subTest(item=item):
                row = self.pending_with(good + item + '\n')
                r = self.check(row)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn('unmet/skipped/error proof row', r.stderr)
        for shape, header in self.NO_STATUS_TABLES:
            for cell in ('FAILURE', 'FAILURES', 'SKIPPING', 'failed-over', 'FAIL-CLOSED'):
                with self.subTest(shape=shape, cell=cell):
                    row = self.pending_with(good + '\n' + header + '| station check | ' + cell + ' | ' + sha + ' | ok |\n')
                    r = self.check(row)
                    self.assertNotEqual(r.returncode, 0, r.stdout)
                    self.assertIn('unmet/skipped/error proof row', r.stderr)

    def test_a_second_declared_artifact_is_judged_beside_the_ticket_named_one(self):
        good = self.evidence.read_text()
        table = '| row | Result | Sha | Evidence |\n|---|---|---|---|\n| station check | %s | main=' + 'a'*40 + ' | timed out |\n'
        for name, other, refusal in (('a failed row and a KEEP verdict', table % 'NOT MET' + 'VERDICT KEEP\n', 'unbound/unresolved proof'),
                                     ('a failed row under a CLOSE verdict', table % 'NOT MET' + 'VERDICT CLOSE\n', 'unmet/skipped/error proof row'),
                                     ('a failed list item under a CLOSE verdict', good + '- **OWED** station check: needs the operator\n', 'unmet/skipped/error proof row'),
                                     ('an artifact that does not exist', None, 'No such file or directory')):
            with self.subTest(name):
                row = self.pending_artifacts({'HIMMEL-9848-proof.md': good, 'station-control.md': other})
                self.assertEqual(row['binding'], 'matched')
                r = self.check(row)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn(refusal, r.stderr)
                self.assertEqual(len(row.get('evidence_records', [])), 2)

    def test_a_second_declared_artifact_that_passes_leaves_the_close_to_the_chief(self):
        good = self.evidence.read_text()
        row = self.pending_artifacts({'HIMMEL-9848-proof.md': good, 'station-control.md': good.replace('| control |', '| station check |').replace('PASS yes', 'PASS station')})
        self.assertEqual(row['binding'], 'matched')
        self.assertNotIn('artifact-attribution-unvalidated', row['issues'])
        r = self.check(row)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_an_artifact_that_names_no_ticket_is_an_issue_that_refuses_when_several_tickets_are_declared(self):
        good = self.evidence.read_text()
        tickets = 'HIMMEL-9848 HIMMEL-10220'
        row = self.pending_artifacts({'HIMMEL-9848-proof.md': good, 'summary.md': good.replace('| control |', '| summary |')}, keys=tickets)
        self.assertEqual(row['binding'], 'matched')
        r = self.check(row)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('unbound/unresolved proof', r.stderr)
        self.assertIn('artifact-attribution-unvalidated', row['issues'])
        # an artifact named after each ticket needs no attribution
        row = self.pending_artifacts({'HIMMEL-9848-proof.md': good.replace('| control |', '| named control |'), 'HIMMEL-10220-proof.md': good}, keys=tickets)
        self.assertNotIn('artifact-attribution-unvalidated', row['issues'])
        r = self.check(row)
        self.assertEqual(r.returncode, 0, r.stderr)

    # The first cell is the control: the bare word is refused in any table; each marked spelling must be refused as it is.
    MARKED_UNMET_CELLS = ['NOT MET', '**NOT MET**', '*NOT MET*', '_NOT MET_', '`NOT MET`', '__NOT MET__', '**FAIL**', '*FAILED*', '*OWED*', '`OWED`', '_SKIPPED_',
                          '**SKIPPED**', '`ERROR`', '_ERRORS_']

    def test_an_unmet_word_in_emphasis_or_inline_code_blocks_the_close_in_a_table_with_no_status_column(self):
        sha = 'main=' + 'a'*40
        good = self.evidence.read_text()
        self.write(stamp=self.module().requirements(self.mirror / 'HIMMEL-9848.md'))
        for shape, header in self.NO_STATUS_TABLES:
            for cell in self.MARKED_UNMET_CELLS:
                with self.subTest(shape=shape, cell=cell):
                    row = self.pending_with(good + '\n' + header + '| station check | ' + cell + ' | ' + sha + ' | timed out |\n')
                    self.assertEqual(row['binding'], 'matched')
                    r = self.check(row)
                    self.assertNotEqual(r.returncode, 0, r.stdout)
                    self.assertIn('unmet/skipped/error proof row', r.stderr)

    def test_a_met_word_or_a_words_own_underscore_in_a_table_with_no_status_column_stays_closable_through_the_real_check(self):
        sha = 'main=' + 'a'*40
        good = self.evidence.read_text()
        self.write(stamp=self.module().requirements(self.mirror / 'HIMMEL-9848.md'))
        for shape, header in self.NO_STATUS_TABLES:
            for cell in ('MET', '**MET**', '*MET*', '_MET_', '`MET`', '__MET__', 'ERROR_CODE', '_ERROR_CODE_', '`ERROR_CODE`', 'OWED_ITEMS'):
                with self.subTest(shape=shape, cell=cell):
                    row = self.pending_with(good + '\n' + header + '| control two | ' + cell + ' | ' + sha + ' | PASS yes |\n')
                    self.assertEqual(row['binding'], 'matched')
                    r = self.check(row)
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertEqual(json.loads(r.stdout)['semantic_coverage'], 'chief-owned')

    def test_a_table_with_a_status_column_is_judged_by_its_status_column_through_the_real_check(self):
        sha = 'main=' + 'a'*40
        good = self.evidence.read_text()
        self.write(stamp=self.module().requirements(self.mirror / 'HIMMEL-9848.md'))
        for name, cell_status, cell_evidence, allowed in (('an emphasised unmet word in the status cell', '**NOT MET**', 'timed out', False),
                                                          ('a bare unmet word in the status cell', 'NOT MET', 'timed out', False),
                                                          ('an emphasised word in the evidence cell of a met row', 'MET', '**NOT MET** in the evidence text', True)):
            with self.subTest(name):
                row = self.pending_with(good.replace('VERDICT CLOSE\n', '| control two | ' + cell_status + ' | ' + sha + ' | ' + cell_evidence + ' |\nVERDICT CLOSE\n'))
                self.assertEqual(row['binding'], 'matched')
                r = self.check(row)
                if allowed:
                    self.assertEqual(r.returncode, 0, r.stderr)
                else:
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
        r = self.decide('--settle', status='To Do', action_id=record['id'])  # the open code part refuses the CLOSE: nothing is discharged or erased
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
                for mode, status in (('--check', 'Done'), ('--settle', 'To Do')):  # a settle on a Done ticket reconciles instead (below)
                    r = self.decide(mode, status=status)
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
               'The run reported nothing pending and no one waiting.\n')  # the rows sit in the result table; a list item starts with its status
        row = self.pending_with(good.replace('VERDICT CLOSE\n', met + 'VERDICT CLOSE\n'))
        r = self.check(row)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)['semantic_coverage'], 'chief-owned')

    # The live pull-request remainder at CLOSE: the dispatcher's own sources, stubbed through the dispatcher's own seams
    # (TICKET_STATUS_STATE_DIR for the status log, NEXT_DISPATCH_GH_CMD for `gh pr view`, MERGE_ROWS_GH for the merged-on-GitHub check).
    CODE = 'Remaining: implement X (scripts/x.sh)'
    NO_CODE = 'Remaining: S7 (chief-run, no code)'
    OWED_PROOF = '## Ticket coverage\n- run the live proof: owed -> proof by 2026-11-30\n'
    OWED_OPERATOR = '## Ticket coverage\n- rotate the token: owed -> operator by 2026-11-30\n'
    OWED_CHIEF = '## Ticket coverage\n- sign the release: owed -> chief by 2026-11-30\n'
    HANDED_OFF = '## Ticket coverage\n- the rest: deferred -> OTHER-1\n'
    NO_REMAINDER = '## Ticket coverage\n- the whole ask: done\n'

    def world(self):
        root = self.b / 'live'
        (root / 'state').mkdir(parents=True, exist_ok=True)
        (root / 'bodies').mkdir(exist_ok=True)
        (root / 'gh.log').write_text('')
        gh = root / 'gh'
        gh.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$GH_LOG"\ncase "$1 $2" in\n'
                      '  "pr view") [ "$4" = --repo ] && [ "$6" = --json ] && [ "$7" = body ] || exit 64; cat "$PR_BODY_DIR/$3" 2>/dev/null || exit 1; exit 0 ;;\n'
                      '  "pr list") exit 0 ;;\nesac\nexit 64\n')
        merged = root / 'merged-on-github'
        merged.write_text('#!/bin/sh\nprintf "merged-on-github %s\\n" "$*" >> "$GH_LOG"\nexit 1\n')
        for stub in (gh, merged):
            stub.chmod(0o755)
        self.live = root
        return {'TICKET_STATUS_STATE_DIR': str(root / 'state'), 'NEXT_DISPATCH_GH_CMD': str(gh), 'MERGE_ROWS_GH': str(merged),
                'GH_LOG': str(root / 'gh.log'), 'PR_BODY_DIR': str(root / 'bodies'), 'HOME': str(root / 'home')}

    def merge(self, pr, contract='no', key='HIMMEL-9848', **extra):
        row = {'ts': 't', 'event': 'merge', 'key': key, 'pr': str(pr), 'result': 'noop', **({'contract': contract} if contract else {}), **extra}
        with open(self.live / 'state' / 'status-events.jsonl', 'a') as log:
            log.write(json.dumps(row) + '\n')

    def body(self, pr, text):
        (self.live / 'bodies' / str(pr)).write_text(text)

    def gh_calls(self):
        return (self.live / 'gh.log').read_text().splitlines()

    def partial(self, pr, text):
        self.merge(pr)
        self.body(pr, text)

    def test_a_live_code_remainder_refuses_the_close_and_writes_nothing(self):
        env = self.world()
        self.partial(77, self.CODE)
        before = (self.b / 'owed.jsonl').read_bytes()
        for mode, status in (('--check', 'Done'), ('--settle', 'To Do')):  # a settle on a Done ticket reconciles instead (below)
            r = self.decide(mode, status=status, env=env)
            self.assertNotEqual(r.returncode, 0, r.stdout)
            self.assertIn('PR #77', r.stderr)
            self.assertIn('implement X', r.stderr)
            self.assertEqual((self.b / 'owed.jsonl').read_bytes(), before)
        self.assertTrue(any(c.startswith('pr view 77 ') for c in self.gh_calls()))
        self.assertEqual(len(self.rows()), 1)

    def test_a_body_that_now_owes_only_proof_settles_once(self):
        env = self.world()
        self.partial(77, self.CODE)
        self.assertNotEqual(self.decide('--check', env=env).returncode, 0)
        self.body(77, self.OWED_PROOF)
        for _ in range(2):
            r = self.decide('--settle', env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len([row for row in self.rows() if row['op'] == 'close' and row['ref'] == 'o1']), 1)

    def test_a_remainder_that_writes_no_code_does_not_block_but_a_mixed_one_does(self):
        env = self.world()
        self.partial(77, self.NO_CODE)
        r = self.decide('--check', env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.body(77, 'Remaining: S1 (edit scripts/x.sh); S2 (chief-run, no code)')
        r = self.decide('--check', env=env)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('PR #77', r.stderr)

    def test_an_owed_chief_or_operator_line_blocks_without_any_ledger_row_and_proof_or_handoff_does_not(self):
        env = self.world()
        self.merge(77)
        for name, text, blocks in (('operator', self.OWED_OPERATOR, True), ('chief', self.OWED_CHIEF, True),
                                   ('proof', self.OWED_PROOF, False), ('handed off', self.HANDED_OFF, False),
                                   ('proof first, operator later', '## Ticket coverage\n- a: owed -> proof by 2026-11-29\n- b: owed -> operator by 2026-11-30\n', True)):
            with self.subTest(owed=name):
                self.body(77, text)
                r = self.decide('--check', env=env)
                self.assertEqual(r.returncode != 0, blocks, r.stdout + r.stderr)
                if blocks:
                    self.assertIn('PR #77', r.stderr)
                    self.assertIn('owed', r.stderr)
        self.assertEqual(len(self.rows()), 1)  # none of them was ever a ledger row

    def test_the_newest_partial_pull_request_decides(self):
        env = self.world()
        self.partial(77, self.CODE)
        self.partial(78, self.OWED_PROOF)
        self.assertEqual(self.decide('--check', env=env).returncode, 0)
        (self.live / 'state' / 'status-events.jsonl').unlink()
        self.partial(77, self.OWED_PROOF)
        self.partial(78, self.CODE)
        r = self.decide('--check', env=env)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('PR #78', r.stderr)

    def test_a_body_that_records_no_remainder_blocks_like_the_dispatcher_note(self):
        env = self.world()
        self.partial(77, self.NO_REMAINDER)
        r = self.decide('--check', env=env)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('PR #77', r.stderr)
        self.assertIn('no remainder', r.stderr)

    def test_an_unreadable_body_or_log_refuses_naming_what_could_not_be_read_and_an_absent_log_is_no_partials(self):
        env = self.world()
        self.merge(77)  # no body file: the stub gh exits 1
        r = self.decide('--check', env=env)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('unreadable', r.stderr)
        self.assertIn('PR #77', r.stderr)
        self.assertEqual(len(self.rows()), 1)
        self.body(77, self.NO_CODE)
        self.assertEqual(self.decide('--settle', env=env).returncode, 0)
        self.assertEqual(len([row for row in self.rows() if row['op'] == 'close']), 1)

    def test_an_unreadable_status_log_refuses_and_a_missing_one_means_no_partials(self):
        env = self.world()
        self.assertEqual(self.decide('--check', env=env).returncode, 0)  # no log at all
        (self.live / 'state' / 'status-events.jsonl').mkdir()  # a directory: unreadable
        r = self.decide('--check', env=env)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('status-events.jsonl', r.stderr)
        self.assertIn('unreadable', r.stderr)

    def test_a_completing_merge_clears_the_partials_and_an_unmerged_pre_merge_row_is_ignored(self):
        env = self.world()
        self.partial(77, self.CODE)
        self.merge(80, contract='yes')
        self.assertEqual(self.decide('--check', env=env).returncode, 0)
        (self.live / 'state' / 'status-events.jsonl').unlink()
        self.body(79, self.CODE)
        self.merge(79, stage='pre-merge', result='pending', head='abc')
        self.merge(79, contract=None, result='not-merged', head='abc')  # merge-on-green writes this row with no contract
        self.assertEqual(self.decide('--check', env=env).returncode, 0)
        self.assertFalse(any(c.startswith('pr view 79 ') for c in self.gh_calls()))

    def test_a_ticket_with_no_partial_pull_request_or_only_another_tickets_closes_as_before(self):
        env = self.world()
        r = self.decide('--check', env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.body(90, self.CODE)
        (self.live / 'state' / 'status-events.jsonl').write_text(
            '{"event":"merge","key":"OTHER-1","pr":"90","contract":"no","result":"noop"}\nnot json\n')
        self.assertEqual(self.decide('--settle', env=env).returncode, 0)
        self.assertEqual(self.gh_calls(), [])

    def test_a_keep_is_not_subject_to_the_remainder_reader(self):
        env = self.world()
        self.partial(77, self.CODE)
        self.change_decision(verdict='KEEP', next={'actor': 'worker', 'capability': 'code worker', 'text': 'Implement X',
                                                   'due': '2026-11-20', 'wake': 'worker available'})
        r = self.decide('--settle', status='To Do', env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.gh_calls(), [])
        self.assertIn('o1', self.closed_refs())

    def test_a_remainder_that_appears_between_check_and_settle_writes_one_reconciliation_and_discharges_nothing(self):
        env = self.world()
        self.assertEqual(self.decide('--check', env=env).returncode, 0)
        self.partial(77, self.CODE)  # a partial merge lands after the check
        # a ticket that is not actually Done is a plain refusal: nothing moved, nothing to reconcile
        self.assertNotEqual(self.decide('--settle', status='To Do', env=env).returncode, 0)
        self.assertEqual(len(self.rows()), 1)
        for _ in range(3):  # the settle and its replays: ONE owned step, the validation stays pending
            r = self.decide('--settle', env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
            body = json.loads(r.stdout)
            self.assertFalse(body['closed'])
        steps = [row for row in self.rows() if row.get('capability') == 'remainder reconciliation']
        self.assertEqual(len(steps), 1)
        step = steps[0]
        self.assertEqual((step['kind'], step['actor'], step['key'], step['source_id'], step['actual_status']), ('step', 'chief', 'HIMMEL-9848', 'o1', 'Done'))
        self.assertEqual(body['reconciliation'], step['id'])
        self.assertIn('PR #77', step['text'])
        self.assertIn('implement X', step['text'])
        self.assertEqual(self.closed_refs(), set())
        self.assertEqual(len(self.rows()), 2)
        # the remainder done (a completing merge), the step still owns the decision until it is closed
        self.merge(80, contract='yes')
        r = self.decide('--settle', env=env)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('open code/chief step ' + step['id'], r.stderr)
        self.close_row(step['id'])
        r = self.decide('--settle', env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.closed_refs(), {step['id'], 'o1'})

    DISPATCH_CASES = (
        ('older code, newer owed proof', ((77, CODE), (78, OWED_PROOF))),
        ('older owed proof, newer code', ((77, OWED_PROOF), (78, CODE))),
        ('a code remainder', ((77, CODE),)),
        ('a remainder that writes no code', ((77, NO_CODE),)),
        ('code and no code in one line', ((77, 'Remaining: S1 (edit scripts/x.sh); S2 (chief-run, no code)'),)),
        ('owed operator', ((77, OWED_OPERATOR),)),
        ('owed chief', ((77, OWED_CHIEF),)),
        ('owed proof only', ((77, OWED_PROOF),)),
        ('handed off', ((77, HANDED_OFF),)),
        ('older owed chief, newer handed off', ((77, OWED_CHIEF), (78, HANDED_OFF))),
        ('older code, newer handed off', ((77, CODE), (78, HANDED_OFF))),
        ('records no remainder', ((77, NO_REMAINDER),)),
        ('a file named beside a no-code phrase', ((77, 'Remaining: implement the retry loop in scripts/x.sh (there is no code owner yet)'),)),
        ('the same unit with no file named', ((77, 'Remaining: implement the retry loop (there is no code owner yet)'),)),
        ('a file named beside chief-run', ((77, 'Remaining: update scripts/x.sh (chief-run)'),)),
        ('chief-run with no file named', ((77, 'Remaining: update the notes (chief-run)'),)),
        ('a file named beside the state repo', ((77, 'Remaining: edit docs/x.md (state repo)'),)),
        ('the state repo with no file named', ((77, 'Remaining: edit the notes in the state repo'),)),
    )

    def dispatcher_says_work_remains(self, env, prs):
        """The real next-dispatchable.sh over the SAME status log and gh stub: True when it lists the ticket as work to do or to ask."""
        nd = self.b / 'nd'
        mirror = nd / 'jira-mirror' / 'HIMMEL'
        mirror.mkdir(parents=True, exist_ok=True)
        (nd / 'jira-mirror' / 'HIMMEL.versions.tsv').write_text('v1.0.1\tfalse\t\n')
        (mirror / 'HIMMEL-9848.md').write_text(
            '---\nkey: "HIMMEL-9848"\ntype: "Task"\nstatus: "In Progress"\nstatusCategory: "x"\npriority: "Medium"\nlabels: []\nfixVersions: []\n'
            'parent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-9848: parity fixture\n\n## Description\n\n'
            'Edit scripts/lib/o1.sh.\n\nDoD\n- the row is green\n\nProof\n- a RED row that fails before the change\n')
        # git-env-ok: the fixture repository's git calls run with every GIT_* name dropped
        (nd / 'git').mkdir(exist_ok=True)
        for cmd in (['init', '-q', '-b', 'main'], ['-c', 'user.name=t', '-c', 'user.email=t@example.com', '-c', 'commit.gpgsign=false',
                                                   '-c', 'core.hooksPath=/dev/null', 'commit', '-q', '--allow-empty', '-m', 'init']):
            subprocess.run(['git', '-C', str(nd / 'git'), *cmd], check=True, capture_output=True,
                           env={k: v for k, v in os.environ.items() if not k.startswith('GIT_')})
        (nd / 'stub.js').write_text("const a = process.argv.slice(2);\nif (a[0] === 'release' && a[1] === 'core-check') "
                                    "for (const k of a.slice(a.indexOf('--key') + 1)) console.log('NOT-CORE ' + k);\nelse process.exit(2);\n")
        classify = nd / 'classify'
        classify.write_text('#!/usr/bin/env bash\nfor k in "$@"; do printf \'%s\\tLOCAL-NATIVE\\tstub\\n\' "$k"; done\n')
        classify.chmod(0o755)
        leg = nd / 'HIMMEL-399-N1-live.md'
        leg.write_text('> **Writes:** none named\n# live\n')
        (nd / 'fleet.json').write_text(json.dumps({'schema': 1, 'legs': [{'doc': str(leg), 'label': 'N1'}]}))
        (Path(env['TICKET_STATUS_STATE_DIR']) / 'workers').mkdir(exist_ok=True)
        run_env = {**os.environ, **env, 'HANDOVER_DIR': str(nd / 'h'), 'HIMMEL_ADMISSIONS_LEDGER': str(nd / 'ledger.jsonl'),
                   'NEXT_DISPATCH_GIT_DIR': str(nd / 'git'), 'NEXT_DISPATCH_MAIN_REF': 'main', 'NEXT_DISPATCH_MIRROR': str(mirror),
                   'NEXT_DISPATCH_JIRA_CLI': str(nd / 'stub.js'), 'NEXT_DISPATCH_CLASSIFY_CMD': str(classify), 'NEXT_DISPATCH_BODY_CACHE': 'off'}
        (nd / 'h').mkdir(exist_ok=True)
        r = subprocess.run(['bash', str(HERE / 'next-dispatchable.sh'), '--workers-dir', str(Path(env['TICKET_STATUS_STATE_DIR']) / 'workers'),
                            '--workers-from', str(nd / 'fleet.json')], capture_output=True, text=True, env=run_env, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = [line for line in r.stdout.splitlines() if 'HIMMEL-9848' in line and not line.startswith('#')]
        return rows, r.stdout

    def test_the_close_decision_and_the_dispatcher_agree_on_the_same_pull_requests(self):
        for name, prs in self.DISPATCH_CASES:
            with self.subTest(case=name):
                env = self.world()
                (self.live / 'state' / 'status-events.jsonl').write_text('')
                for pr, text in prs:
                    self.partial(pr, text)
                close = self.decide('--check', env=env)
                rows, out = self.dispatcher_says_work_remains(env, prs)
                # the dispatcher keeps the ticket as work or a question (a RESUME row that is not routed to proof, an OWED or
                # NEEDS-CHIEF-NOTE row) unless it routes the remainder to proof (a RESUME row ending in `proof`) or hands it off
                dispatcher_blocks = any(row.startswith(('OWED ', 'NEEDS-CHIEF-NOTE ')) for row in rows) or \
                    any(row.startswith('RESUME') and not row.endswith('\tproof') for row in rows)
                self.assertEqual(close.returncode != 0, dispatcher_blocks, close.stderr + '\n' + out)

    def close_command(self, step_id, key='HIMMEL-9848'):
        return 'bash ' + str(HERE / 'owe.sh') + ' close --bucket ' + str(self.b) + ' --id ' + step_id + ' --key ' + key

    def test_the_refusal_names_each_open_step_with_its_actor_and_text_and_both_remedies(self):
        first = self.add_row('Finish the first slice', actor='worker')
        second = self.add_row('Sign the release', actor='chief')
        for mode, status in (('--check', 'Done'), ('--settle', 'To Do')):
            r = self.decide(mode, status=status)
            self.assertNotEqual(r.returncode, 0, r.stdout)
            self.assertIn(first + ' (worker: Finish the first slice)', r.stderr)
            self.assertIn(second + ' (chief: Sign the release)', r.stderr)
            self.assertIn(self.close_command(first), r.stderr)
            self.assertIn(self.close_command(second), r.stderr)
            self.assertIn('KEEP', r.stderr)

    def test_a_keep_then_a_new_proof_then_a_close_needs_the_finished_step_closed_first(self):
        self.change_decision(verdict='KEEP', next={'actor': 'worker', 'capability': 'code worker',
            'text': 'Implement the missing accepted case', 'due': '2026-11-20', 'wake': 'worker available'})
        self.assertEqual(self.decide('--settle', status='To Do').returncode, 0)
        step = next(r['id'] for r in self.rows() if r.get('source_id') == 'o1')
        # the worker finished; a second proof run is recorded and the chief decides to close
        row = self.pending_with(self.evidence.read_text() + '| second pass | MET | main=' + 'a'*40 + ' | PASS yes |\n')
        self.change_decision(verdict='CLOSE')
        before = self.rows()
        r = self.decide('--check', action_id=row['id'])
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn(step + ' (worker: Implement the missing accepted case)', r.stderr)
        self.assertIn(self.close_command(step), r.stderr)
        self.assertIn('KEEP', r.stderr)
        self.assertEqual(self.rows(), before)
        self.close_row(step)  # nothing closes it for the chief
        r = self.decide('--settle', action_id=row['id'])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len([x for x in self.rows() if x['op'] == 'close' and x['ref'] == row['id']]), 1)

    def result_table(self, status='MET', evidence='PASS yes', header='| row | Result | Sha | Evidence |'):
        return header + '\n|---|---|---|---|\n| obs | ' + status + ' | main=' + 'a'*40 + ' | ' + evidence + ' |\n'

    def unmet(self, text):
        return self.module().has_unmet_rows(text)

    def test_a_not_yet_due_word_in_the_status_position_is_unmet_in_any_case_and_through_emphasis(self):
        for status in ('PENDING', 'Pending 24h', 'Pending review', 'Pending 2026-11-25', 'pending the 24h window', 'Waiting 24h', 'WAITING until 2026-11-25',
                       'tbd after window', 'TBD', 'Not yet due 2026-11-25', 'not-yet-due', 'NOT-YET-DUE', 'NOT  YET DUE', '**PENDING**', '*pending*',
                       '`PENDING`', '__Waiting__ for CI'):
            with self.subTest(status=status):
                self.assertTrue(self.unmet(self.result_table(status=status)))
        for name in ('Result', 'Status', 'Verdict', 'Outcome', 'Requirement status', 'Overall result'):
            with self.subTest(status_column=name):
                header = '| row | ' + name + ' | Sha | Evidence |'
                self.assertTrue(self.unmet(self.result_table(status='Pending 24h', header=header)))
                self.assertFalse(self.unmet(self.result_table(evidence='pending: none', header=header)))
        for item in ('- Pending review', '- Not yet due control two', '1. tbd control two', '* **WAITING** for the window', '- not-yet-due control two'):
            with self.subTest(item=item):
                self.assertTrue(self.unmet(item + '\n'))

    def test_a_failed_list_item_is_unmet_in_any_case_and_through_emphasis_and_inline_code(self):
        for word in ('NOT MET', 'not met', 'Not  Met', 'OWED', 'owed', 'FAIL', 'Failed', 'SKIPPED', 'skip', 'ERROR', 'Errors'):
            for mark in ('%s', '**%s**', '*%s*', '_%s_', '`%s`', '__%s__', '***%s***', '_**%s**_', '*`%s`*'):
                with self.subTest(word=word, mark=mark):
                    self.assertTrue(self.unmet('- ' + mark % word + ' control two\n'))
        for bullet in ('-', '*', '+', '1.', '12)'):
            for mark in ('*%s*', '_%s_', '`%s`'):
                with self.subTest(bullet=bullet, mark=mark):
                    self.assertTrue(self.unmet(bullet + ' ' + mark % 'NOT MET' + ': no RED\n'))
                    self.assertTrue(self.unmet('  ' + bullet + ' ' + mark % 'NOT MET' + '\n'))
        # the met word, a failure word that does not start the item and a failure word with an underscore of its own are not unmet rows
        for item in ('- *MET* control two', '- _MET_ control two', '- `MET` control two', '- the run was *not* skipped; nothing _failed_', '- control two ran and `FAIL` is expected',
                     '- ERROR_CODE is documented', '- OWED_ITEMS: none', '- _ERROR_CODE_ is documented'):
            with self.subTest(item=item):
                self.assertFalse(self.unmet(item + '\n'))

    def test_an_unmet_word_first_after_the_last_colon_of_a_list_item_is_unmet_through_emphasis_and_inline_code(self):
        unmet = self.module().has_unmet_rows
        for word in ('NOT MET', 'not met', 'OWED', 'owed', 'FAIL', 'Failed', 'SKIPPED', 'skip', 'ERROR', 'Errors'):
            for mark in ('%s', '**%s**', '*%s*', '_%s_', '`%s`', '__%s__', '***%s***'):
                with self.subTest(word=word, mark=mark):
                    self.assertTrue(unmet('- control two: ' + mark % word + '\n'))
                    self.assertTrue(unmet('- **Result:** ' + mark % word + ' (timed out)\n'))
                    self.assertTrue(unmet('- Result: ' + mark % word + ' - no RED\n'))
        for label in ('**Result:**', '*Result:*', '__Result:__', '`Result:`', '**Result**:', 'Result :', 'control two:', 'a: b: c:', '[Result]:', 'Result (main=aaaa):'):
            with self.subTest(label=label):
                self.assertTrue(unmet('- ' + label + ' NOT MET\n'))
                self.assertTrue(unmet('- ' + label + '*FAIL*\n'))
        for bullet in ('-', '*', '+', '1.', '12)'):
            with self.subTest(bullet=bullet):
                self.assertTrue(unmet(bullet + ' control two: NOT MET\n'))
                self.assertTrue(unmet('  ' + bullet + ' **Result:** OWED\n'))
        # a time or a URL in the item: the status counts when it is the first thing after one of the item's colons
        for item in ('- ran at 12:30: NOT MET', '- see http://x/y: NOT MET', '- see http://x/y: *FAIL*', '- C:\\dir: OWED', '- control two: `FAIL` is expected', '- Note: FAIL fast is used',
                     '- Result: NOT MET: no RED'):
            with self.subTest(item=item):
                self.assertTrue(unmet(item + '\n'))
        # unchanged: the met word, a colon with no unmet word first after it, a word's own underscore, a status that is not first after a colon
        for item in ('- control two: MET', '- **Result:** *MET*', '- Notes: all controls ran', '- ran at 12:30: MET', '- see http://x/y: ok', '- path C:\\dir is fine',
                     '- ERROR_CODE: documented', '- Result: ERROR_CODE documented', '- Result: OWED_ITEMS none', '- ran at 12:30 FAIL',
                     '- see http://x/y NOT MET', '- Result: ok, then NOT MET', '- Result: MET (pending review)'):
            with self.subTest(item=item):
                self.assertFalse(unmet(item + '\n'))
        # a colon in a paragraph, a table row or a heading is not a list item
        for text in ('Result: NOT MET\n', '**Result:** NOT MET\n', '| Result: NOT MET | x |\n', '# Result: FAIL\n'):
            with self.subTest(text=text):
                self.assertFalse(unmet(text))

    def test_a_list_item_is_read_by_its_met_start_then_by_any_colon_with_the_unmet_word_read_whole(self):
        unmet = self.module().has_unmet_rows
        marks = ('%s', '**%s**', '*%s*', '_%s_', '`%s`', '__%s__')
        # an item that starts with MET, in any case and through any mark or bullet, is read by that word alone
        for bullet in ('-', '*', '+', '1.', '12)'):
            for mark in marks:
                for met in ('MET', 'Met', 'met'):
                    with self.subTest(bullet=bullet, mark=mark, met=met):
                        self.assertFalse(unmet(bullet + ' ' + mark % met + ' main=aaaa: failures 0\n'))
                        self.assertFalse(unmet(bullet + ' ' + mark % met + ': skipped 0 tests\n'))
                        self.assertFalse(unmet(bullet + ' ' + mark % met + ' evidence: FAILED 0, NOT MET 0\n'))
        # a word that only begins with MET or joins a continuation, a PASS, a task item and a struck-through, bracketed or quoted MET do not decide the item
        for item in ('- Metrics: FAILED 2', '- METHOD: FAIL x', '- MET-based: FAIL x', '- MET_RUN: NOT MET', '- PASS: FAIL fast is used', '- PASSED: NOT MET', '- [x] MET: FAILED',
                     '- ~~MET~~: FAILED', '- (MET): FAILED'):
            with self.subTest(item=item):
                self.assertTrue(unmet(item + '\n'))
        # an item that starts with an unmet or a not yet due word is unmet whatever follows it
        for item in ('- NOT MET: failures 0', '- **FAIL**: failures 0', '- PENDING: failures 0', '- Pending review: skipping 2'):
            with self.subTest(item=item):
                self.assertTrue(unmet(item + '\n'))
        # after a colon an unmet word is the whole word, in any case and through emphasis and inline code, whichever colon of the item it follows
        for word in ('NOT MET', 'not met', 'OWED', 'owed', 'FAIL', 'Failed', 'FAILS', 'FAILURE', 'FAILING', 'SKIP', 'skip', 'SKIPS', 'SKIPPED', 'ERROR', 'Errors'):
            for mark in marks:
                with self.subTest(word=word, mark=mark):
                    self.assertTrue(unmet('- Result: ' + mark % word + ': no RED\n'))
                    self.assertTrue(unmet('- **Result:** ' + mark % word + ' (x): y: z\n'))
                    self.assertTrue(unmet('- a: b: ' + mark % word + ' x: y\n'))
        for word in ('failures', 'Failures', 'FAILURES', 'skipping', 'SKIPPING', 'failed-over', 'FAILED-OVER', 'FAIL-CLOSED', 'failure-rate', 'fail_fast', 'SKIP_CR', 'failover', 'FAILSAFE',
                     'skipper', 'ERRORED', 'ERROR_CODE', 'OWED_ITEMS'):
            for mark in ('%s', '*%s*', '`%s`'):
                with self.subTest(other_word=word, mark=mark):
                    self.assertFalse(unmet('- Result: ' + mark % word + ' x\n'))
                    self.assertFalse(unmet('- Result: ' + mark % word + ': ok\n'))
        # only a FAIL joined by a hyphen is another word: the other unmet words stay unmet before a hyphen and its continuation
        for word in ('OWED-operator', 'SKIPPED-no-vm', 'NOT MET-x', 'ERROR-CODE', 'SKIP-CI'):
            with self.subTest(hyphen_joined=word):
                self.assertTrue(unmet('- Result: ' + word + ' x\n'))
        # a word at the start of an item or of a table cell is still read by its beginning
        for text in ('- failures 3\n', '- skipping 2\n', '- failed-over x\n', '| station check | FAILURE | main=aaaa | ok |\n', '| station check | failures 0 | main=aaaa | ok |\n'):
            with self.subTest(text=text):
                self.assertTrue(unmet(text))

    def test_the_evidence_of_a_met_row_never_reads_as_not_yet_due(self):
        for evidence in ('TBD field removed', 'WAITING room test passed', 'PENDING count was 0', 'PENDING rows: none', 'pending: none', 'pending (0)',
                         'pending.', 'pending, none', 'pending-count 0', 'waiting-list empty', 'waiting for 0 items', 'waiting on nobody',
                         'pending by design', 'tbd.', 'TBD-free', 'not yet due: none', 'no pending rows', 'waiting list is empty', 'tbd items: none',
                         'Pending count was 0', 'not-yet-due items: none'):
            with self.subTest(evidence=evidence):
                self.assertFalse(self.unmet(self.result_table(evidence=evidence)))
        self.assertTrue(self.unmet(self.status_table('MET', 'Pendingly done')))  # not MET in a proof column, so unmet (a status is exactly MET)
        self.assertFalse(self.unmet('- Pendingly done\n- Waitingroom closed\n'))  # a word of its own, not the status word
        self.assertFalse(self.unmet('| row | Expected | Result |\n|---|---|---|\n| obs | PENDING | MET |\n'))  # an Expected column is test input
        self.assertFalse(self.unmet('| row | Expected | Sha | Evidence |\n|---|---|---|---|\n| obs | PENDING | main=aaa | ok |\n'))  # also with no status column
        self.assertFalse(self.unmet('The run reported nothing pending, no one waiting and no tbd.\n- the run reported nothing pending\n'))

    def test_a_row_with_no_status_column_to_read_fails_closed_for_the_not_yet_due_words(self):
        # the row forms with no status position distinct from the evidence text: an unsure row is unmet
        for name, text in (('a header with no status column', '| row | Sha | Evidence |\n|---|---|---|\n| obs | main=aaa | pending count was 0 |\n'),
                           ('a row with no header', '| obs | MET | main=aaa | pending count was 0 |\n'),
                           ('a ragged row under a header', '| row | Result | Sha | Evidence |\n|---|---|---|---|\n| obs | MET | pending: none |\n')):
            with self.subTest(form=name):
                self.assertTrue(self.unmet(text))

    NO_STATUS_TABLES = (('a headerless table', ''), ('a header with no status column', '| check | Observed | Sha | Note |\n|---|---|---|---|\n'))

    def test_an_unmet_word_in_emphasis_or_inline_code_is_unmet_in_a_table_with_no_status_column(self):
        sha = 'main=' + 'a'*40
        unmet = self.module().has_unmet_rows
        for shape, header in self.NO_STATUS_TABLES:
            for word in ('NOT MET', 'not met', 'Not  Met', 'OWED', 'owed', 'FAIL', 'Failed', 'SKIPPED', 'skip', 'ERROR', 'Errors'):
                for mark in ('%s', '**%s**', '*%s*', '_%s_', '`%s`', '__%s__', '***%s***', '_**%s**_', '*`%s`*'):
                    with self.subTest(shape=shape, word=word, mark=mark):
                        self.assertTrue(unmet(header + '| station check | ' + mark % word + ' | ' + sha + ' | ok |\n'))
            for mark in ('**%s**', '*%s*', '_%s_', '`%s`'):  # in the first and in the last cell of the row
                with self.subTest(shape=shape, mark=mark, position='first'):
                    self.assertTrue(unmet(header + '| ' + mark % 'NOT MET' + ' | ' + sha + ' | ok | ok |\n'))
                with self.subTest(shape=shape, mark=mark, position='last'):
                    self.assertTrue(unmet(header + '| station check | ' + sha + ' | ok | ' + mark % 'OWED' + ' |\n'))

    def test_what_is_not_an_unmet_word_in_a_cell_stays_closable_in_a_table_with_no_status_column(self):
        sha = 'main=' + 'a'*40
        unmet = self.module().has_unmet_rows
        for shape, header in self.NO_STATUS_TABLES:
            for mark in ('%s', '**%s**', '*%s*', '_%s_', '`%s`', '__%s__'):
                with self.subTest(shape=shape, met=mark):
                    self.assertFalse(unmet(header + '| control two | ' + mark % 'MET' + ' | ' + sha + ' | PASS yes |\n'))
            # a word's own underscore is not emphasis
            for cell in ('ERROR_CODE', '_ERROR_CODE_', '`ERROR_CODE`', 'OWED_ITEMS', '*OWED_ITEMS*'):
                with self.subTest(shape=shape, cell=cell):
                    self.assertFalse(unmet(header + '| control two | ' + cell + ' | ' + sha + ' | documented |\n'))
        # an Expected column is test input, with or without emphasis, and so is the prose around a table
        for mark in ('%s', '**%s**', '*%s*', '`%s`'):
            with self.subTest(expected=mark):
                self.assertFalse(unmet('| row | Expected | Observed | Note |\n|---|---|---|---|\n| obs | ' + mark % 'FAIL' + ' | refused | ok |\n'))
        self.assertFalse(unmet('a pipe | in prose, then **NOT MET** and `FAIL` in the text\n'))

    def test_a_table_with_a_status_column_is_read_by_its_status_column(self):
        # the status cell decides: anything but exactly MET is unmet; the other cells of the row are not read for emphasised words
        self.assertTrue(self.unmet(self.result_table(status='**NOT MET**')))
        self.assertTrue(self.unmet(self.result_table(status='`FAIL`')))
        self.assertFalse(self.unmet(self.result_table(evidence='**NOT MET** in the evidence text')))
        self.assertFalse(self.unmet(self.result_table(evidence='_OWED_ in the evidence text')))
        self.assertTrue(self.unmet(self.result_table(evidence='NOT MET in the evidence text')))  # a bare word that starts a cell is unmet in any table

    def test_the_not_yet_due_status_word_closes_nothing_through_the_real_check(self):
        sha = 'main=' + 'a'*40
        good = '| row | Result | Sha | Evidence |\n|---|---|---|---|\n| control | MET | ' + sha + ' | PASS yes |\n'
        row = self.pending_with(good + '| obs | Pending 24h | ' + sha + ' | window open |\nVERDICT CLOSE\n')
        r = self.check(row)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('unmet/skipped/error proof row', r.stderr)
        row = self.pending_with(good + '| obs | MET | ' + sha + ' | TBD field removed; pending: none |\nVERDICT CLOSE\n')
        r = self.check(row)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_a_step_of_another_key_never_blocks_whatever_its_relation_to_this_one(self):
        steps = [self.add_row('Implement an unrelated ticket', key=other) for other in ('HIMMEL-98', 'HIMMEL-98480', 'HIMMEL-9848X', 'HIMMEL-984', 'XHIMMEL-9848')]
        r = self.decide('--settle')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.open_ids(), set(steps))

    def test_a_step_of_the_same_ticket_under_a_lower_case_key_blocks(self):
        step = self.add_row('Implement the missing accepted case', key='himmel-9848')
        r = self.decide('--check')
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn(step + ' (worker: Implement the missing accepted case)', r.stderr)

    def test_a_step_that_appears_between_check_and_settle_writes_one_reconciliation_like_a_remainder(self):
        self.assertEqual(self.decide('--check').returncode, 0)
        step = self.add_row('Implement the missing accepted case')
        self.assertNotEqual(self.decide('--settle', status='To Do').returncode, 0)  # not Done: nothing moved, a plain refusal
        self.assertEqual(len(self.rows()), 2)
        for _ in range(3):  # the settle and its replays: ONE owned step, the validation stays pending
            r = self.decide('--settle')
            self.assertEqual(r.returncode, 0, r.stderr)
            body = json.loads(r.stdout)
            self.assertFalse(body['closed'])
        steps = [row for row in self.rows() if row.get('capability') == 'remainder reconciliation']
        self.assertEqual(len(steps), 1)
        self.assertEqual((steps[0]['kind'], steps[0]['actor'], steps[0]['key'], steps[0]['source_id']), ('step', 'chief', 'HIMMEL-9848', 'o1'))
        self.assertEqual(body['reconciliation'], steps[0]['id'])
        self.assertIn(step, steps[0]['text'])
        self.assertIn('Implement the missing accepted case', steps[0]['text'])
        self.assertEqual((self.closed_refs(), len(self.rows())), (set(), 3))
        # the finished step closed, the reconciliation still owns the decision until it is closed
        self.close_row(step)
        r = self.decide('--settle')
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('open code/chief step ' + steps[0]['id'], r.stderr)
        self.close_row(steps[0]['id'])
        self.assertEqual(self.decide('--settle').returncode, 0)
        self.assertEqual(self.closed_refs(), {step, steps[0]['id'], 'o1'})

    def test_a_step_and_a_remainder_together_write_one_reconciliation_that_names_both(self):
        env = self.world()
        self.assertEqual(self.decide('--check', env=env).returncode, 0)
        step = self.add_row('Implement the missing accepted case')
        self.partial(77, self.CODE)
        for _ in range(2):
            r = self.decide('--settle', env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
        steps = [row for row in self.rows() if row.get('capability') == 'remainder reconciliation']
        self.assertEqual(len(steps), 1)
        for name in (step, 'Implement the missing accepted case', 'PR #77', 'implement X'):
            self.assertIn(name, steps[0]['text'])

    def test_the_path_rule_is_the_dispatchers_own_pattern(self):
        holds = importlib.util.spec_from_file_location('holds', HERE / 'holds.py')
        module = importlib.util.module_from_spec(holds)
        holds.loader.exec_module(module)
        dispatcher = (HERE / 'next-dispatchable.sh').read_text()
        self.assertIn('FILE_RE = re.compile(r"' + module.FILE_RE.pattern + '")', dispatcher)
        env = self.world()
        self.partial(77, 'Remaining: implement the retry loop in scripts/x.sh (there is no code owner yet)')
        r = self.decide('--check', env=env)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('PR #77', r.stderr)
        self.assertIn('scripts/x.sh', r.stderr)

    def test_a_pre_merge_only_row_is_seen_when_github_confirms_it_and_the_close_agrees_with_the_dispatcher(self):
        for name, body, blocks in (('code', self.CODE, True), ('no code', self.NO_CODE, False)):
            with self.subTest(case=name):
                env = self.world()
                (self.live / 'merged-on-github').write_text('#!/bin/sh\nprintf "MERGED abc\\n"\n')
                (self.live / 'state' / 'status-events.jsonl').write_text('')
                self.merge(77, stage='pre-merge', result='pending', head='abc')
                self.body(77, body)
                close = self.decide('--check', env=env)
                rows, out = self.dispatcher_says_work_remains(env, ())
                dispatcher_blocks = any(row.startswith(('OWED ', 'NEEDS-CHIEF-NOTE ')) for row in rows) or \
                    any(row.startswith('RESUME') and not row.endswith('\tproof') for row in rows)
                self.assertEqual((close.returncode != 0, dispatcher_blocks), (blocks, blocks), close.stderr + '\n' + out)

    def test_a_warning_from_the_status_log_helper_is_could_not_read_not_no_partial_merge(self):
        env = self.world()  # the stubbed GitHub read fails, so the pre-merge-only row cannot be confirmed
        self.merge(77, stage='pre-merge', result='pending', head='abc')
        self.body(77, self.CODE)
        before = (self.b / 'owed.jsonl').read_bytes()
        for mode in ('--check', '--settle'):
            r = self.decide(mode, status='To Do', env=env)
            self.assertNotEqual(r.returncode, 0, r.stdout)
            self.assertIn('unreadable', r.stderr)
            self.assertIn('PR 77', r.stderr)
            self.assertEqual((self.b / 'owed.jsonl').read_bytes(), before)
        # a spent GitHub budget is the same: the helper says it did not count the PR
        (self.live / 'merged-on-github').write_text('#!/bin/sh\nprintf "MERGED abc\\n"\n')
        r = self.decide('--check', env={**env, 'MERGE_ROWS_BUDGET_SECS': '0'})
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('unreadable', r.stderr)
        self.assertIn('budget', r.stderr)
        # confirmed merged, the same row is a partial PR and its remainder blocks as any other
        r = self.decide('--check', env=env)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('PR #77 Remaining', r.stderr)

    def test_a_merge_row_with_no_usable_pull_request_number_is_could_not_read(self):
        env = self.world()
        for number in ('', 'abc', None):
            with self.subTest(pr=number):
                (self.live / 'state' / 'status-events.jsonl').write_text(
                    json.dumps({'event': 'merge', 'key': 'HIMMEL-9848', 'contract': 'no', 'result': 'noop', **({} if number is None else {'pr': number})}) + '\n')
                r = self.decide('--check', env=env)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn('unreadable', r.stderr)
                self.assertIn('no PR number', r.stderr)
        # another ticket's malformed row and a completing merge's missing number are not this ticket's partial merge
        (self.live / 'state' / 'status-events.jsonl').write_text(
            '{"event":"merge","key":"OTHER-1","contract":"no","result":"noop"}\n{"event":"merge","key":"HIMMEL-9848","contract":"yes","result":"noop"}\n')
        self.assertEqual(self.decide('--check', env=env).returncode, 0)

    def test_a_reconciliation_step_closed_with_the_remainder_open_is_replaced_by_a_new_open_one(self):
        env = self.world()
        self.assertEqual(self.decide('--check', env=env).returncode, 0)
        self.partial(77, self.CODE)
        first = json.loads(self.decide('--settle', env=env).stdout)['reconciliation']
        for _ in range(2):  # while a step is open, a settle writes nothing new
            self.assertEqual(json.loads(self.decide('--settle', env=env).stdout)['reconciliation'], first)
        self.close_row(first)  # the chief closes it without clearing the remainder
        r = self.decide('--settle', env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        second = json.loads(r.stdout)['reconciliation']
        self.assertNotEqual(second, first)
        self.assertIn(second, self.open_ids())
        steps = [row for row in self.rows() if row.get('capability') == 'remainder reconciliation' and row['id'] in self.open_ids()]
        self.assertEqual([row['id'] for row in steps], [second])
        text = steps[0]['text']
        self.assertIn(first + ' was closed with the blockers still open', text)
        self.assertLess(text.index('Clear'), text.index('close this step'))
        self.assertLess(text.index('close this step'), text.index('record the decision again'))
        self.assertEqual(self.closed_refs(), {first})
        self.assertEqual(json.loads(self.decide('--settle', env=env).stdout)['reconciliation'], second)

    def test_a_failed_reconciliation_write_is_an_error_that_names_the_blockers(self):
        env = self.world()
        self.assertEqual(self.decide('--check', env=env).returncode, 0)
        self.partial(77, self.CODE)
        writer = self.b / 'refuse-add.sh'
        writer.write_text('#!/bin/bash\n[ "$1" != add ] || { echo "disk full" >&2; exit 4; }\nexec bash ' + str(HERE / 'owe.sh') + ' "$@"\n')
        r = self.decide('--settle', env={**env, 'PROOF_OWE_BIN': str(writer)})
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('could not write the reconciliation step', r.stderr)
        self.assertIn('disk full', r.stderr)
        self.assertIn('PR #77', r.stderr)
        self.assertIn('implement X', r.stderr)
        self.assertEqual(len(self.rows()), 1)

    def test_the_status_log_row_key_is_compared_in_any_case_and_a_slow_helper_is_could_not_read(self):
        env = self.world()
        self.merge(77, key='himmel-9848')
        self.body(77, self.CODE)
        r = self.decide('--check', env=env)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('PR #77', r.stderr)
        module = self.module()
        os.environ['TICKET_STATUS_STATE_DIR'] = env['TICKET_STATUS_STATE_DIR']
        with mock.patch.object(module.subprocess, 'run', side_effect=subprocess.TimeoutExpired('merge-rows-effective', 1)):
            blocking, unreadable = module.live_remainder('HIMMEL-9848')
        self.assertEqual(blocking, [])
        self.assertIn('status log', unreadable[0])
        self.assertIn('unreadable', unreadable[0])

    def test_a_slow_pull_request_read_ends_in_the_unreadable_refusal_inside_the_callers_wait(self):
        env = self.world()
        self.partial(77, self.CODE)
        slow = self.live / 'slow-gh'
        slow.write_text('#!/bin/sh\nsleep 20\n')
        slow.chmod(0o755)
        started = time.monotonic()
        r = self.decide('--check', env={**env, 'NEXT_DISPATCH_GH_CMD': str(slow), 'PROOF_REMAINDER_BUDGET_SECS': '2'})
        self.assertLess(time.monotonic() - started, 10)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('live pull-request remainder unreadable', r.stderr)
        self.assertIn('PR #77', r.stderr)

    # The default read of live_remainder, with NEXT_DISPATCH_GH_CMD and ND_GH_READ unset: scripts/lib/gh-read.sh beside the validator when that is an
    # executable file, else `gh` on PATH. The validator finds the helper from its own resolved path, so these rows run a copy of it in a scratch tree
    # whose scripts/lib holds a stub helper (the other files it loads are copies from the tree under test) and put a stub `gh` first on PATH: the real
    # helper and the real `gh` never run.
    ROUTED_ARGV = ['pr', 'view', '77', '--repo', 'yotamleo-org/Himmel', '--json', 'body', '--jq', '.body']
    HELPER_BODY = 'Remaining: from the helper (scripts/helper.sh)'
    PATH_BODY = 'Remaining: from gh on PATH (scripts/path-gh.sh)'
    SEAM_BODY = 'Remaining: from the seam (scripts/seam.sh)'
    ROUTED_DRIVER = ('import importlib.util, json, sys\n'
                     'spec = importlib.util.spec_from_file_location("proof_validate", sys.argv[1])\n'
                     'module = importlib.util.module_from_spec(spec)\n'
                     'spec.loader.exec_module(module)\n'
                     'print(json.dumps(module.live_remainder(sys.argv[2])))\n')

    def stub(self, path, body='', exit_code=0):
        # appends its arguments to <path>.calls (one per line, then `--`), prints the body and exits with exit_code
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/sh\nprintf "%s\\n" "$@" -- >> ' + shlex.quote(str(path) + '.calls') + '\nprintf "%s\\n" ' + shlex.quote(body) + '\nexit ' + str(exit_code) + '\n')
        path.chmod(0o755)

    def calls(self, path):
        log = Path(str(path) + '.calls')
        calls, current = [], []
        for line in log.read_text().splitlines() if log.exists() else []:
            if line == '--':
                calls.append(current)
                current = []
            else:
                current.append(line)
        return calls

    def routed(self, seam=None, helper_exit=0):
        env = {k: v for k, v in {**os.environ, **self.world()}.items() if k not in ('NEXT_DISPATCH_GH_CMD', 'ND_GH_READ')}
        env['PATH'] = str(self.live / 'bin') + os.pathsep + os.environ.get('PATH', '/usr/bin:/bin')
        if seam:
            env[seam] = str(self.live / 'gh')  # the world's stub gh: it logs to gh.log and serves bodies/77
        self.partial(77, self.SEAM_BODY)
        lib = HERE.parent.parent / 'lib'
        scripts = self.b / 'kit' / 'scripts'
        for source, folder in ((HERE / 'proof-validate.py', 'handover/chief-kit'), (HERE / 'holds.py', 'handover/chief-kit'),
                               (lib / 'status_marker.py', 'lib'), (lib / 'pr_remainder.py', 'lib'), (lib / 'merge-rows-effective.py', 'lib')):
            (scripts / folder).mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, scripts / folder / source.name)
        self.validator = scripts / 'handover' / 'chief-kit' / 'proof-validate.py'
        self.helper = scripts / 'lib' / 'gh-read.sh'
        self.path_gh = self.live / 'bin' / 'gh'
        self.stub(self.helper, self.HELPER_BODY, helper_exit)
        self.stub(self.path_gh, self.PATH_BODY)
        return env

    def routed_remainder(self, env):
        r = subprocess.run(['python3', '-I', '-c', self.ROUTED_DRIVER, str(self.validator), 'HIMMEL-9848'], capture_output=True, text=True, timeout=30, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def routed_check(self, env):
        data = {'key': 'HIMMEL-9848', 'description': self.requirements + '\n', 'status': 'Done', 'category': 'done'}
        return subprocess.run(['python3', '-I', str(self.validator), '--bucket', str(self.b), '--check', 'o1', '--decision', str(self.decision), '--current-stdin'],
                              input=json.dumps(data), text=True, capture_output=True, timeout=30, env={**env, 'PROOF_OWE_BIN': str(HERE / 'owe.sh')})

    def test_the_routed_default_reads_the_body_through_the_helper_beside_the_validator(self):
        env = self.routed()
        result = self.routed_remainder(env)
        self.assertEqual(self.calls(self.path_gh), [])
        self.assertEqual(self.calls(self.helper), [self.ROUTED_ARGV])
        self.assertEqual(result, [['PR #77 Remaining: from the helper (scripts/helper.sh)'], []])

    def test_a_routed_helper_that_fails_is_unreadable_and_the_close_is_refused_with_no_retry_on_gh(self):
        env = self.routed(helper_exit=7)  # the failing helper still prints a body: it is not judged
        result = self.routed_remainder(env)
        self.assertEqual(self.calls(self.path_gh), [])
        self.assertEqual(self.calls(self.helper), [self.ROUTED_ARGV])
        self.assertEqual(result, [[], ['PR #77 body unreadable (gh exit 7)']])
        before = (self.b / 'owed.jsonl').read_bytes()
        r = self.routed_check(env)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('live pull-request remainder unreadable: PR #77 body unreadable (gh exit 7)', r.stderr)
        self.assertEqual((self.b / 'owed.jsonl').read_bytes(), before)
        self.assertEqual((self.calls(self.helper), self.calls(self.path_gh)), ([self.ROUTED_ARGV] * 2, []))
        self.stub(self.helper, self.NO_CODE)  # the same check passes once the helper reads a body that owes no code
        r = self.routed_check(env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.calls(self.helper), self.calls(self.path_gh)), ([self.ROUTED_ARGV] * 3, []))

    def test_a_routed_helper_without_its_executable_bit_falls_back_to_gh_on_path(self):
        env = self.routed()
        self.helper.chmod(0o644)
        result = self.routed_remainder(env)
        self.assertEqual(self.calls(self.path_gh), [self.ROUTED_ARGV])
        self.assertEqual(self.calls(self.helper), [])
        self.assertEqual(result, [['PR #77 Remaining: from gh on PATH (scripts/path-gh.sh)'], []])

    def test_an_absent_routed_helper_falls_back_to_gh_on_path(self):
        env = self.routed()
        self.helper.unlink()
        result = self.routed_remainder(env)
        self.assertEqual(self.calls(self.path_gh), [self.ROUTED_ARGV])
        self.assertEqual(result, [['PR #77 Remaining: from gh on PATH (scripts/path-gh.sh)'], []])

    def seam_wins(self, seam):
        env = self.routed(seam=seam)
        result = self.routed_remainder(env)
        self.assertEqual(self.gh_calls(), [' '.join(self.ROUTED_ARGV)])
        self.assertEqual((self.calls(self.helper), self.calls(self.path_gh)), ([], []))
        self.assertEqual(result, [['PR #77 Remaining: from the seam (scripts/seam.sh)'], []])

    def test_a_set_next_dispatch_gh_cmd_wins_over_the_routed_default(self):
        self.seam_wins('NEXT_DISPATCH_GH_CMD')

    def test_a_set_nd_gh_read_wins_over_the_routed_default(self):
        self.seam_wins('ND_GH_READ')

    def test_the_callers_wait_covers_the_readers_whole_budget(self):
        # else a slow read ends in the CLI's exec timeout (and, after the move, in a settle that never ran) instead of the unreadable refusal
        caller = int(re.search(r'timeout: (\d[\d_]*)', (HERE.parents[1] / 'jira' / 'src' / 'commands' / 'transition.ts').read_text())[1].replace('_', ''))
        reader = float(re.search(r"PROOF_REMAINDER_BUDGET_SECS'\) or '(\d+)'", (HERE / 'proof-validate.py').read_text())[1])
        self.assertLess(reader * 1000 + 5000, caller)

    def test_a_proof_row_is_met_only_when_its_status_is_exactly_met(self):
        for status in ('MET (pending review)', 'MET, pending 24h', 'PASS (pending)', 'Awaiting 24h', 'NOT RUN', 'BLOCKED', 'MET (with a naming note)',
                       'MET; run r informational', 'MET.', 'PASS'):
            with self.subTest(status=status):
                self.assertTrue(self.unmet(self.result_table(status=status)))
        for status in ('CONTROL RAN', 'METx', '', 'DONE'):  # no proof word of their own: unmet beside a MET (a proof column), not a proof column alone
            with self.subTest(status=status):
                self.assertTrue(self.unmet(self.status_table('MET', status)))
                self.assertFalse(self.unmet(self.status_table(status)))
        for status in ('MET', 'met', 'Met', ' MET ', '**MET**', '*met*', '`MET`', '__MET__'):
            with self.subTest(status=status):
                self.assertFalse(self.unmet(self.result_table(status=status)))
        # the rule is for the status column; the evidence column, an Expected column and the prose around the table are not read for it
        self.assertFalse(self.unmet(self.result_table(evidence='MET (pending review)')))
        self.assertFalse(self.unmet('| row | Expected | Result |\n|---|---|---|\n| obs | CONTROL RAN | MET |\n'))
        for item in ('- Awaiting 24h', '- NOT RUN control two', '1. BLOCKED control two'):
            with self.subTest(item=item):
                self.assertTrue(self.unmet(item + '\n'))
        self.assertFalse(self.unmet('- the run was not blocked by anything\n- no one is awaiting\n'))

    def status_table(self, *statuses, header='| item | Status | Note |'):
        return header + '\n|---|---|---|\n' + ''.join('| row %d | %s | note |\n' % (n, status) for n, status in enumerate(statuses))

    def test_a_status_column_is_read_strictly_only_when_it_uses_the_proof_vocabulary(self):
        # no cell starts with a proof word: a ticket-status column, not a proof-row column, and nothing in it refuses
        self.assertFalse(self.unmet(self.status_table('To Do', 'In Progress', 'Done', 'context', '')))
        # one proof word and the column is a proof column: every cell must be exactly MET, so a ticket status among them refuses
        self.assertTrue(self.unmet(self.status_table('To Do', 'MET', 'In Progress')))
        for column in (('PASS', 'PASS'), ('MET', 'MET (cited)'), ('met', 'Met', 'MET.'), ('MET', 'CONTROL RAN'), ('MET', ''), ('MET', 'Done')):
            with self.subTest(column=column):
                self.assertTrue(self.unmet(self.status_table(*column)))
        self.assertFalse(self.unmet(self.status_table('MET', 'met', '**MET**', ' MET ')))
        # each word of the one trigger list makes a column strict (a ticket status beside it refuses)
        for word in ('MET', 'NOT MET', 'OWED', 'PASS', 'FAIL', 'SKIPPED', 'ERROR', 'PENDING', 'WAITING', 'TBD', 'NOT YET DUE', 'AWAITING', 'NOT RUN', 'BLOCKED', '**pass**'):
            with self.subTest(trigger=word):
                self.assertTrue(self.unmet(self.status_table('In Progress', word)))

    def test_a_document_with_a_proof_table_and_a_ticket_status_table_is_read_table_by_table(self):
        sha = 'main=' + 'a'*40
        proof = '| row | Result | Sha | Evidence |\n|---|---|---|---|\n| one | MET | ' + sha + ' | PASS yes |\n| two | MET | ' + sha + ' | ok |\n'
        tickets = '| ticket | Status |\n|---|---|\n| HIMMEL-1 | To Do |\n| HIMMEL-2 | In Progress |\n| HIMMEL-3 | Done |\n'
        self.assertFalse(self.unmet(proof + '\nThe tickets named above:\n\n' + tickets + 'VERDICT CLOSE\n'))
        self.assertTrue(self.unmet(proof.replace('| two | MET |', '| two | MET (cited) |') + '\n' + tickets))
        self.assertTrue(self.unmet(proof + '\n' + tickets.replace('| HIMMEL-2 | In Progress |', '| HIMMEL-2 | MET |')))

    def test_a_table_written_without_leading_pipes_is_read_as_a_table(self):
        sha = 'main=' + 'a'*40
        for status in ('MET (pending review)', 'Pending 24h', 'NOT RUN'):
            with self.subTest(status=status):
                self.assertTrue(self.unmet('row | Result | Sha | Evidence\n--- | --- | --- | ---\nobs | ' + status + ' | ' + sha + ' | ok\n'))
        self.assertFalse(self.unmet('row | Result | Sha | Evidence\n--- | --- | --- | ---\nobs | MET | ' + sha + ' | pending: none\n'))
        self.assertFalse(self.unmet('a horizontal rule follows\n\n---\n\nand then text with a pipe | in it\n'))

    def reconciliation_steps(self):
        return [row for row in self.rows() if row.get('capability') == 'remainder reconciliation']

    def test_a_settle_that_cannot_read_the_remainder_after_the_move_writes_the_one_owned_step(self):
        env = self.world()
        self.assertEqual(self.decide('--check', env=env).returncode, 0)
        self.merge(77)  # a partial merge landed after the check; its body cannot be read (the stub gh exits 1)
        for _ in range(2):  # the settle and a re-run with the read still failing: the same one step
            r = self.decide('--settle', env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
            body = json.loads(r.stdout)
            self.assertFalse(body['closed'])
        steps = self.reconciliation_steps()
        self.assertEqual(len(steps), 1)
        self.assertEqual(body['reconciliation'], steps[0]['id'])
        self.assertIn('could not read', steps[0]['text'])
        self.assertIn('PR #77', steps[0]['text'])
        self.assertEqual((self.closed_refs(), len(self.rows())), (set(), 2))
        self.assertNotEqual(self.decide('--settle', status='To Do', env=env).returncode, 0)  # not Done: a plain refusal, nothing moved
        # the read works again and nothing is open: the open step still owns the decision until the chief closes it
        self.body(77, self.NO_CODE)
        r = self.decide('--settle', env=env)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('open code/chief step ' + steps[0]['id'], r.stderr)
        self.close_row(steps[0]['id'])
        self.assertEqual(self.decide('--settle', env=env).returncode, 0)
        self.assertEqual(self.closed_refs(), {steps[0]['id'], 'o1'})

    def test_blockers_that_change_between_settles_leave_exactly_one_open_step(self):
        env = self.world()
        self.assertEqual(self.decide('--check', env=env).returncode, 0)
        self.partial(77, self.CODE)
        ids = [json.loads(self.decide('--settle', env=env).stdout)['reconciliation']]
        self.body(77, 'Remaining: implement Y instead (scripts/y.sh)')  # the text changes
        ids.append(json.loads(self.decide('--settle', env=env).stdout)['reconciliation'])
        self.partial(78, self.OWED_OPERATOR)  # a second blocker
        ids.append(json.loads(self.decide('--settle', env=env).stdout)['reconciliation'])
        self.assertEqual(len(set(ids)), 1)
        steps = self.reconciliation_steps()
        self.assertEqual([row['id'] for row in steps], ids[:1])
        self.assertIn('implement X', steps[0]['text'])  # the blockers as they were when it was written
        self.assertIn('is the authority', steps[0]['text'])
        self.assertEqual(self.open_ids(), {'o1', ids[0]})
        # a step closed while a blocker is open is still followed by a new one
        self.close_row(ids[0])
        again = json.loads(self.decide('--settle', env=env).stdout)['reconciliation']
        self.assertNotEqual(again, ids[0])
        self.assertEqual(len([row for row in self.reconciliation_steps() if row['id'] in self.open_ids()]), 1)

    def test_a_status_log_line_that_names_the_key_and_is_not_json_is_could_not_read(self):
        env = self.world()
        log = self.live / 'state' / 'status-events.jsonl'
        log.write_text('{"event":"merge","key":"HIMMEL-9848","pr":"77","contract":"no","res')  # torn by a killed writer
        self.body(77, self.CODE)
        r = self.decide('--check', env=env)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('status-events.jsonl', r.stderr)
        self.assertIn('not JSON', r.stderr)
        log.write_text('garbage that names no ticket\n')  # a line that does not name this ticket is nobody's partial merge
        self.assertEqual(self.decide('--check', env=env).returncode, 0)

    def test_a_pull_request_left_unread_because_the_budget_is_spent_is_named_and_refused(self):
        env = self.world()
        self.partial(77, self.CODE)
        self.partial(78, self.OWED_PROOF)  # the newest says proof only: a silent skip of 77 or 78 would pass
        slow = self.live / 'slow-gh'
        slow.write_text('#!/bin/sh\nsleep 3\n')
        slow.chmod(0o755)
        r = self.decide('--check', env={**env, 'NEXT_DISPATCH_GH_CMD': str(slow), 'PROOF_REMAINDER_BUDGET_SECS': '2'})
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('PR #77 body unreadable', r.stderr)
        self.assertIn('PR #78 body unreadable (the 2 s read budget is spent)', r.stderr)

    def test_a_helper_that_fails_and_a_helper_that_runs_past_the_budget_are_could_not_read(self):
        env = self.world()
        self.partial(77, self.NO_CODE)
        r = self.decide('--check', env={**env, 'MERGE_ROWS_BUDGET_SECS': 'abc'})  # the helper dies at import: a traceback and exit 1
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('status log', r.stderr)
        self.assertIn('unreadable', r.stderr)
        # a real slow helper (a pre-merge row it must confirm through a slow GitHub read) is killed at the reader's budget, not at 120 s
        (self.live / 'state' / 'status-events.jsonl').write_text('')
        self.merge(79, stage='pre-merge', result='pending', head='abc')
        slow = self.live / 'merged-on-github'
        slow.write_text('#!/bin/sh\nsleep 30\n')
        started = time.monotonic()
        r = self.decide('--check', env={**env, 'PROOF_REMAINDER_BUDGET_SECS': '3'})
        self.assertLess(time.monotonic() - started, 5)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('the log helper ran past the read budget', r.stderr)

    def test_a_reconciliation_step_closed_by_the_race_is_refused_and_another_validations_steps_are_not_earlier_ones(self):
        env = self.world()
        self.assertEqual(self.decide('--check', env=env).returncode, 0)
        # another validation's closed step of the same ticket is not an earlier step of this one
        other = self.owe_add_step('Reconcile close: an old close', source_id='o99')
        self.close_row(other)
        self.partial(77, self.CODE)
        first = json.loads(self.decide('--settle', env=env).stdout)['reconciliation']
        self.assertNotIn('Earlier reconciliation step', [row for row in self.rows() if row.get('id') == first][0]['text'])
        # the chief closes the step between the validator's read and its add: the closed id is never returned as the owner
        flag = self.b / 'armed'
        writer = self.b / 'close-on-add.sh'
        writer.write_text('#!/bin/bash\nif [ "$1" = add ] && [ -e ' + str(flag) + ' ] && [ ! -e ' + str(flag) + '.done ]; then : > ' + str(flag) + '.done\n'
                          '  bash ' + str(HERE / 'owe.sh') + ' close --bucket ' + str(self.b) + ' --id ' + first + ' --key HIMMEL-9848 >/dev/null\nfi\n'
                          'exec bash ' + str(HERE / 'owe.sh') + ' "$@"\n')
        flag.write_text('')
        r = self.decide('--settle', env={**env, 'PROOF_OWE_BIN': str(writer)})
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('is already closed', r.stderr)
        self.assertIn('PR #77', r.stderr)

    def owe_add_step(self, text, source_id):
        return subprocess.check_output(['bash', str(HERE / 'owe.sh'), 'add', '--bucket', str(self.b), '--chief', 'chief', '--kind', 'step', '--key', 'HIMMEL-9848',
            '--text', text, '--metadata', json.dumps({'actor': 'chief', 'action': 'next-step', 'capability': 'remainder reconciliation', 'source_id': source_id})],
            text=True, env={**os.environ, 'OWE_NOW_EPOCH': '1794860000'}).strip()

    def test_a_path_that_appears_late_in_a_long_remainder_still_makes_it_code(self):
        env = self.world()
        self.partial(77, 'Remaining: ' + 'chief-run notes about the station ' * 14 + 'and edit scripts/x.sh (chief-run)')
        r = self.decide('--check', env=env)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('PR #77', r.stderr)


def setUpModule():
    # The decision reads the status log and GitHub: never the station's real ones, in any test of this file.
    global _saved_env, _fixture_home
    import tempfile
    _fixture_home = tempfile.mkdtemp(prefix='proof-decision-')
    stub = Path(_fixture_home) / 'refuse'
    stub.write_text('#!/bin/sh\nexit 1\n')
    stub.chmod(0o755)
    _saved_env = {name: os.environ.get(name) for name in ('HOME', 'TICKET_STATUS_STATE_DIR', 'NEXT_DISPATCH_GH_CMD', 'ND_GH_READ', 'MERGE_ROWS_GH')}
    os.environ.update(HOME=_fixture_home, TICKET_STATUS_STATE_DIR=_fixture_home, NEXT_DISPATCH_GH_CMD=str(stub), MERGE_ROWS_GH=str(stub))
    os.environ.pop('ND_GH_READ', None)


def tearDownModule():
    for name, value in _saved_env.items():
        os.environ.pop(name, None) if value is None else os.environ.__setitem__(name, value)
    shutil.rmtree(_fixture_home, ignore_errors=True)


if __name__ == '__main__':
    unittest.main()
