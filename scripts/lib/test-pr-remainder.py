#!/usr/bin/env python3
"""One grammar across routing, owner recording and chief-only refusals."""
from pathlib import Path
import subprocess
import tempfile
import importlib.util
import json
import os
import unittest
from pr_remainder import pr_remainder_units

HERE = Path(__file__).resolve().parent


class Remainders(unittest.TestCase):
    def test_merge_writer_retains_actual_owners_replay_and_failed_partial_write(self):
        root = HERE.parents[1]
        text = (root / 'scripts/handover/merge-on-green.sh').read_text()
        start = text.index('_merge_owe_spool() {')
        function = text[start:text.index('\n}\n', start) + 3]
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            body = '## Ticket coverage\n- run proof: owed -> proof by 2026-11-20\n- rotate token: owed -> operator by 2026-11-21\n'
            command = ('. "$1/scripts/lib/ticket-status.sh"\n' + function
                       + '\nhimmel_repo=$1\npartial_body=$2\n_merge_owe_spool HIMMEL-10220 77 o/r\necho "OWE_RESULT=$OWE_RESULT"\n')
            env = {**os.environ, 'TICKET_STATUS_STATE_DIR': str(state)}
            for _ in range(2):
                result = subprocess.run(['bash', '-c', command, '_', str(root), body], env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('OWE_RESULT=spooled:2', result.stdout)
            spool = state / 'owe-spool.jsonl'
            rows = [json.loads(r) for r in spool.read_text().splitlines()]
            self.assertEqual([(r['who'], r['due']) for r in rows], [('proof', '2026-11-20'), ('operator', '2026-11-21')] * 2)
            self.assertEqual({r['metadata']['actor'] for r in rows}, {'proof', 'operator'})
            self.assertEqual(len({r['identity'] for r in rows}), 2)
            spool.unlink()
            spool.mkdir()
            result = subprocess.run(['bash', '-c', command, '_', str(root), body], env=env, text=True, capture_output=True)
            self.assertIn('OWE_RESULT=miss:2:write', result.stdout)
            self.assertIn('the owed lines of HIMMEL-10220 PR #77 were not spooled', result.stderr)

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

    MARKS = ['-', '*', '+', '1.', '1)', '12.']

    def test_every_list_marker_is_stripped_once_before_the_closed_chief_vocabulary(self):
        for mark in self.MARKS:
            with self.subTest(mark=mark, kind='valid sign-spec chief act'):
                answer = pr_remainder_units('## Ticket coverage\n' + mark + ' sign the spec: owed -> chief by 2026-11-20\n')
                self.assertEqual(answer['chief_invalid'], [])
                self.assertEqual(answer['chief_owed'], ['sign the spec: owed -> chief by 2026-11-20'])
                self.assertEqual(answer['owed_lines'][0]['ask'], 'sign the spec')
                self.assertEqual(answer['owed_lines'][0]['text'], 'sign the spec: owed -> chief by 2026-11-20')
            with self.subTest(mark=mark, kind='executable proof wrongly owed to chief'):
                answer = pr_remainder_units('## Ticket coverage\n' + mark + ' run the live proof on the station: owed -> chief by 2026-11-20\n')
                self.assertEqual(answer['chief_invalid'], ['run the live proof on the station: owed -> chief by 2026-11-20'])
            with self.subTest(mark=mark, kind='proof owner keeps its row'):
                answer = pr_remainder_units('## Ticket coverage\n' + mark + ' run the live proof: owed -> proof by 2026-11-20\n')
                self.assertEqual((answer['kind'], answer['handed']), ('owed', ['proof', '2026-11-20']))
                self.assertTrue(answer['nowrite'])
        # a marker is stripped once: a number that belongs to the text stays
        answer = pr_remainder_units('## Ticket coverage\n- 2. sign the spec: owed -> chief by 2026-11-20\n')
        self.assertEqual(answer['chief_invalid'], ['2. sign the spec: owed -> chief by 2026-11-20'])

    def test_shared_status_reader_strips_the_same_markers(self):
        for mark in self.MARKS:
            with self.subTest(mark=mark):
                body = '## Ticket coverage\n' + mark + ' sign the spec: owed -> chief by 2026-11-20\n'
                r = subprocess.run(['bash', '-c', '. "$1/ticket-status.sh"; ts_owed_lines', '_', str(HERE)],
                                   input=body, text=True, capture_output=True, check=True)
                self.assertEqual(r.stdout.splitlines(), ['chief\t2026-11-20\tsign the spec\tsign the spec: owed -> chief by 2026-11-20'])

    def test_shared_status_reader_keeps_owner_date_and_legacy_clauses(self):
        body = '## Ticket coverage\n- run proof: owed -> proof by 2026-11-20\n- rotate token: owed -> operator by 2026-11-21\n'
        r = subprocess.run(['bash', '-c', '. "$1/ticket-status.sh"; ts_owed_lines', '_', str(HERE)],
                           input=body, text=True, capture_output=True, check=True)
        self.assertEqual(r.stdout.splitlines(), ['proof\t2026-11-20\trun proof\trun proof: owed -> proof by 2026-11-20',
                                               'operator\t2026-11-21\trotate token\trotate token: owed -> operator by 2026-11-21'])
        self.assertEqual(pr_remainder_units('## Ticket coverage\n- x: deferred -> HIMMEL-99\n')['kind'], 'handed-off')

    SIGN = 'sign the spec: owed -> chief by 2026-11-20'
    PROOF = 'run proof with a guest credential: owed -> proof by 2026-11-18'
    A = '## Ticket coverage\n- ' + SIGN + '\n- ' + PROOF + '\n'
    A_REV = '## Ticket coverage\n- ' + PROOF + '\n- ' + SIGN + '\n'
    B = '## Ticket coverage\n- run sibling proof: owed -> proof by 2026-11-25\n'
    A_ROWS = [{'who': 'chief', 'due': '2026-11-20', 'text': SIGN, 'ask': 'sign the spec'},
              {'who': 'proof', 'due': '2026-11-18', 'text': PROOF, 'ask': 'run proof with a guest credential'}]
    OPER = 'rotate the token: owed -> operator by 2026-11-20'
    FULL = ('kind', 'handed', 'text', 'nowrite', 'chief_owed', 'chief_invalid', 'owed_lines')

    def cli(self, mode, body, key='HIMMEL-303'):
        args = ['python3', '-I', str(HERE / 'pr_remainder.py')] + ([mode] if mode else []) + [key]
        return subprocess.run(args, input=body.encode('utf-8'), capture_output=True, check=True).stdout.decode('utf-8')

    def staging(self):
        spec = importlib.util.spec_from_file_location('proof_staging', HERE.parent / 'handover/chief-kit/proof_staging.py')
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_mixed_chief_proof_both_line_orders(self):
        for body, rows in ((self.A, self.A_ROWS), (self.A_REV, self.A_ROWS[::-1])):
            with self.subTest(first=rows[0]['who']):
                a = pr_remainder_units(body)
                self.assertEqual((a['kind'], a['handed'], a['text']), ('owed', ['chief', '2026-11-20'], self.SIGN))
                self.assertFalse(a['nowrite'])
                self.assertEqual(a['owed_lines'], rows)
                self.assertEqual((a['chief_owed'], a['chief_invalid']), ([self.SIGN], []))

    def test_mixed_operator_proof_both_line_orders(self):
        for body in ('## Ticket coverage\n- ' + self.OPER + '\n- ' + self.PROOF + '\n',
                     '## Ticket coverage\n- ' + self.PROOF + '\n- ' + self.OPER + '\n'):
            with self.subTest(body=body):
                a = pr_remainder_units(body)
                self.assertEqual((a['kind'], a['handed'], a['text']), ('owed', ['operator', '2026-11-20'], self.OPER))
                self.assertFalse(a['nowrite'])
                self.assertEqual(a['chief_owed'], [])

    def test_non_proof_beats_earlier_proof_due(self):
        body = '## Ticket coverage\n- early proof: owed -> proof by 2026-11-01\n- late chief: owed -> chief by 2026-12-30\n'
        self.assertEqual(pr_remainder_units(body)['handed'], ['chief', '2026-12-30'])
        self.assertEqual(self.cli(None, body), 'owed\tchief\t2026-12-30\tlate chief: owed -> chief by 2026-12-30\n')

    def test_earliest_non_proof_wins_and_ties_keep_first(self):
        lines = ['c: owed -> chief by 2026-11-22', 'o: owed -> operator by 2026-11-21', 'p: owed -> proof by 2026-11-19']
        for order in (lines, lines[::-1]):
            self.assertEqual(pr_remainder_units('## Ticket coverage\n' + ''.join('- %s\n' % l for l in order))['handed'], ['operator', '2026-11-21'])
        tie = ['c: owed -> chief by 2026-11-21', 'o: owed -> operator by 2026-11-21', 'p: owed -> proof by 2026-11-19']
        for order, who in ((tie, 'chief'), ([tie[1], tie[0], tie[2]], 'operator')):
            with self.subTest(first=who):
                self.assertEqual(pr_remainder_units('## Ticket coverage\n' + ''.join('- %s\n' % l for l in order))['handed'], [who, '2026-11-21'])

    def test_pure_proof_unchanged(self):
        a = pr_remainder_units(self.B)
        self.assertEqual((a['kind'], a['handed'], a['nowrite']), ('owed', ['proof', '2026-11-25'], True))
        two = self.B + '- earlier proof: owed -> proof by 2026-11-24\n'
        self.assertEqual(pr_remainder_units(two)['handed'], ['proof', '2026-11-24'])
        self.assertTrue(pr_remainder_units(two)['nowrite'])
        self.assertFalse(pr_remainder_units(self.A)['nowrite'])

    def test_code_remaining_and_handoff_precedence(self):
        self.assertEqual(pr_remainder_units(self.A + '\nRemaining: S1 fix scripts/x.py\n')['kind'], 'remaining')
        self.assertEqual(pr_remainder_units(self.A + '- the rest: deferred -> HIMMEL-303\n', ['HIMMEL-303'])['kind'], 'remaining')
        self.assertEqual(pr_remainder_units(self.A + '- broken: owed -> chief by 2026-13-40\n')['kind'], 'remaining')
        a = pr_remainder_units(self.A + '- the rest: deferred -> HIMMEL-9\n')
        self.assertEqual((a['kind'], a['handed']), ('owed', ['chief', '2026-11-20']))
        self.assertEqual(pr_remainder_units('## Ticket coverage\n- the rest: deferred -> HIMMEL-9\n')['kind'], 'handed-off')

    def test_original_text_and_unit_metadata_unchanged(self):
        self.assertEqual(pr_remainder_units(self.A)['owed_lines'], self.A_ROWS)
        bad = pr_remainder_units('## Ticket coverage\n- run the live proof on the station: owed -> chief by 2026-11-20\n- ' + self.PROOF + '\n')
        self.assertEqual(bad['chief_invalid'], ['run the live proof on the station: owed -> chief by 2026-11-20'])
        self.assertEqual(bad['handed'], ['chief', '2026-11-20'])

    def test_full_units_cli_round_trip(self):
        tab_body = '## Ticket coverage\n- a\tb: owed -> chief by 2026-11-20\n'
        for body in (self.A, self.A_REV, self.B, 'nothing\n', 'Remaining: S1 no code\n', '## Ticket coverage\n- x: deferred -> HIMMEL-9\n', tab_body):
            with self.subTest(body=body):
                out = subprocess.run(['python3', '-I', str(HERE / 'pr_remainder.py'), '--full-units', 'HIMMEL-303'],
                                     input=body.encode('utf-8'), capture_output=True).stdout.decode('utf-8')
                self.assertTrue(out.endswith('\n') and out.count('\n') == 1, out)
                got = json.loads(out)
                a = pr_remainder_units(body, ['HIMMEL-303'])
                self.assertEqual(got, {'schema': 1, 'answer': {f: a[f] for f in self.FULL}})
                self.assertEqual(tuple(got['answer']), self.FULL)
        tab = json.loads(self.cli('--full-units', tab_body))['answer']
        self.assertEqual(tab['owed_lines'][0]['text'], 'a\tb: owed -> chief by 2026-11-20')
        self.assertEqual(tab['text'], 'a b: owed -> chief by 2026-11-20')
        self.assertEqual(self.cli(None, self.A), 'owed\tchief\t2026-11-20\t' + self.SIGN + '\n')
        self.assertEqual(self.cli('--units', self.A), 'owed\tchief\t2026-11-20\t' + self.SIGN + '\tnowrite=0\tchief-owed=' + self.SIGN + '\n')
        self.assertEqual(self.cli('--owed-lines', self.A).splitlines(),
                         ['\t'.join(r[f] for f in ('who', 'due', 'ask', 'text')) for r in self.A_ROWS])
        self.assertEqual(self.cli(None, self.B), 'owed\tproof\t2026-11-25\trun sibling proof: owed -> proof by 2026-11-25\n')

    def test_mixed_cli_merge_fields(self):
        root = HERE.parents[1]
        text = (root / 'scripts/handover/merge-on-green.sh').read_text()
        start = text.index('_pr_remainder_answer() {')
        block = text[start:text.index('\nlocal_commit_guard\n', start)]
        command = ('. "$1/scripts/lib/ticket-status.sh"\naudit() { :; }\n_merge_contract() { MERGE_ROW_CONTRACT=no; }\n' + block +
                   '\nprintf "%s|%s|%s" "$MERGE_ROW_REMAINDER" "$MERGE_ROW_OWED" "$MERGE_ROW_OWED_DUE"\n')
        with tempfile.TemporaryDirectory() as d:
            gh = Path(d) / 'gh'
            gh.write_text('#!/bin/sh\nprintf "%s" "$TEST_BODY"\n')
            gh.chmod(0o700)
            for body, want in ((self.A, 'owed|chief|2026-11-20'), (self.A_REV, 'owed|chief|2026-11-20'),
                               ('## Ticket coverage\n- ' + self.OPER + '\n- ' + self.PROOF + '\n', 'owed|operator|2026-11-20'),
                               ('## Ticket coverage\n- ' + self.PROOF + '\n- ' + self.OPER + '\n', 'owed|operator|2026-11-20')):
                with self.subTest(body=body):
                    env = dict(os.environ, TEST_BODY=body, himmel_repo=str(root), GH_READ_BIN=str(gh),
                               fresh_title='fix: [HIMMEL-10220] fixture', pr_num='77', nwo='fixture/repo')
                    r = subprocess.run(['bash', '-c', command, '_', str(root)], env=env, text=True, capture_output=True)
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertEqual(r.stdout, want)

    def test_live_proof_units_staging_all_answers(self):
        ps = self.staging()

        def names(answers):
            return [n[0] for n in ps.needs('', answers) if n[0] != 'unknown']
        a, a_rev, b = (pr_remainder_units(x) for x in (self.A, self.A_REV, self.B))
        for answers in ([a], [a_rev], [a, b], [b, a], [a_rev, b], [b, a_rev]):
            with self.subTest(owners=[x['handed'][0] for x in answers]):
                self.assertEqual(names(answers), ['guest-credential'])
        self.assertEqual(names([b]), [])
        second = pr_remainder_units(self.A + '- a throwaway repo PR check: owed -> proof by 2026-11-30\n')
        self.assertEqual(names([second, b]), ['guest-credential', 'throwaway-repo'])
        self.assertEqual(names([a, pr_remainder_units('nothing\n')]), ['guest-credential'])
        handed = pr_remainder_units('## Ticket coverage\n- the rest: deferred -> HIMMEL-9\n')
        old_code = pr_remainder_units('Remaining: S1 in a VM guest session, no code\n')
        self.assertEqual(names([old_code, handed]), [])
        self.assertEqual(names([pr_remainder_units('## Ticket coverage\n- sign the GO file: owed -> chief by 2026-11-20\n')]), ['go-file'])

    def test_missing_units_is_unknown(self):
        ps = self.staging()
        a, b = pr_remainder_units(self.A), pr_remainder_units(self.B)
        missing = {k: v for k, v in a.items() if k != 'owed_lines'}
        for bad in (missing, dict(a, owed_lines='x'), dict(a, owed_lines=[{'who': 'proof'}]), dict(a, owed_lines=[7])):
            with self.subTest(bad=bad.get('owed_lines', 'absent')):
                self.assertIn('unknown', [n[0] for n in ps.needs('', [bad, b])])
        thr = pr_remainder_units('## Ticket coverage\n- a throwaway repo PR check: owed -> proof by 2026-11-30\n')
        got = [n[0] for n in ps.needs('', [missing, thr])]
        self.assertIn('throwaway-repo', got)
        self.assertIn('unknown', got)
        self.assertNotIn('unknown', [n[0] for n in ps.needs('', [pr_remainder_units('## Ticket coverage\n- x: deferred -> HIMMEL-9\n')])])


if __name__ == '__main__':
    unittest.main()
