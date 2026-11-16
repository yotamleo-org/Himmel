#!/usr/bin/env python3
"""One grammar across routing, owner recording and chief-only refusals."""
from pathlib import Path
import subprocess
import tempfile
import json
import os
import unittest
from pr_remainder import pr_remainder_units

HERE = Path(__file__).resolve().parent


class Remainders(unittest.TestCase):
    def test_merge_writer_retains_actual_owners_replay_and_failed_partial_write(self):
        root = HERE.parents[1]
        text = (root / 'scripts/handover/merge-on-green.sh').read_text()
        start = text.index('_merge_owe_rows() {')
        function = text[start:text.index('\n}\n', start) + 3]
        with tempfile.TemporaryDirectory() as directory:
            bucket = Path(directory)
            doc = bucket / 'chief.md'
            doc.write_text('# chief\n')
            body = '## Ticket coverage\n- run proof: owed -> proof by 2026-11-20\n- rotate token: owed -> operator by 2026-11-21\n'
            command = '. "$1/scripts/lib/ticket-status.sh"\n' + function + '\nhimmel_repo=$1\npartial_body=$2\n_merge_owe_rows HIMMEL-10220 77\n'
            env = {**os.environ, 'HIMMEL_CONSOLE_DOC': str(doc), 'HIMMEL_CONSOLE_NAME': 'actual-chief'}
            for _ in range(2):
                result = subprocess.run(['bash', '-c', command, '_', str(root), body], env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            ledger = bucket / 'owed.jsonl'
            rows = [json.loads(r) for r in ledger.read_text().splitlines()]
            self.assertEqual([(r['actor'], r['due']) for r in rows], [('proof', '2026-11-20'), ('operator', '2026-11-21')])
            self.assertEqual(len(rows), 2)
            ledger.unlink()
            ledger.mkdir()
            result = subprocess.run(['bash', '-c', command, '_', str(root), body], env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('0 of 2 owed line(s)', result.stderr)

    def test_proof_owner_and_mixed_units(self):
        body = '## Ticket coverage\n- run the live proof: owed -> proof by 2026-11-20\n'
        answer = pr_remainder_units(body)
        self.assertEqual((answer['kind'], answer['handed']), ('owed', ['proof', '2026-11-20']))
        self.assertTrue(answer['nowrite'])
        answer = pr_remainder_units(body + 'Remaining: S1 fix code (scripts/x.py); S2 no code proof\n')
        self.assertEqual(answer['kind'], 'remaining')
        self.assertFalse(answer['nowrite'])

    def test_chief_only_is_closed_vocabulary_not_default_owner(self):
        for ask, invalid in [('sign the spec', False), ('release operator step', False),
                             ('run the live proof on the station', True), ('rerun the suite', True)]:
            with self.subTest(ask=ask):
                answer = pr_remainder_units('## Ticket coverage\n- ' + ask + ': owed -> chief by 2026-11-20\n')
                self.assertEqual(bool(answer.get('chief_invalid')), invalid)
        self.assertEqual(pr_remainder_units('## Ticket coverage\n- x: owed -> nobody by 2026-11-20\n')['kind'], 'remaining')

    def test_shared_status_reader_keeps_owner_date_and_legacy_clauses(self):
        body = '## Ticket coverage\n- run proof: owed -> proof by 2026-11-20\n- rotate token: owed -> operator by 2026-11-21\n'
        r = subprocess.run(['bash', '-c', '. "$1/ticket-status.sh"; ts_owed_lines', '_', str(HERE)],
                           input=body, text=True, capture_output=True, check=True)
        self.assertEqual(r.stdout.splitlines(), ['proof\t2026-11-20\trun proof\trun proof: owed -> proof by 2026-11-20',
                                               'operator\t2026-11-21\trotate token\trotate token: owed -> operator by 2026-11-21'])
        self.assertEqual(pr_remainder_units('## Ticket coverage\n- x: deferred -> HIMMEL-99\n')['kind'], 'handed-off')


if __name__ == '__main__':
    unittest.main()
