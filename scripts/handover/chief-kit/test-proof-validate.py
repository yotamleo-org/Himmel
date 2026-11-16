#!/usr/bin/env python3
"""Record-only proof handoff, entirely scratch/offline."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class ProofRecord(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.b = Path(self.tmp.name)
        self.mirror = self.b / 'mirror'
        self.mirror.mkdir()
        self.doc = self.b / 'HIMMEL-9848-N42-proof.md'
        self.evidence = self.b / 'evidence.md'
        self.requirements = 'DoD\n- keep  two spaces\n```sh\n  echo yes\n```\nProof\nRun the positive control.\n'
        for key in ('HIMMEL-9848', 'HIMMEL-10220'):
            (self.mirror / (key + '.md')).write_text('## Description\n' + self.requirements + '\n## Comments\nnoise\n')
        self.write()

    def write(self, evidence=None, keys='HIMMEL-9848', tail=''):
        self.evidence.write_text(evidence or '| row | Result | Sha | Evidence |\n|---|---|---|---|\n| control | MET | main=' + 'a'*40 + ' | PASS yes |\nVERDICT CLOSE\n')
        self.doc.write_text('# proof worker\n> **Live test:** none — proof leg\n## Results\n- 10:00 WRAPPED — proof ' + keys + ' verdict=CLOSE evidence=' + str(self.evidence) + tail + '\n')

    def run_record(self, *args, ok=True, env=None):
        r = subprocess.run(['python3', str(HERE / 'proof-validate.py'), '--bucket', str(self.b), '--doc', str(self.doc), '--mirror', str(self.mirror), *args], capture_output=True, text=True, env={**os.environ, **(env or {})})
        if ok:
            self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def rows(self):
        return [json.loads(x) for x in (self.b / 'owed.jsonl').read_text().splitlines()]

    def test_close_is_pending_never_authority(self):
        self.run_record()
        row = self.rows()[0]
        self.assertEqual((row['kind'], row['actor'], row['action'], row['validation']), ('proof', 'chief', 'validate-proof', 'pending'))
        self.assertEqual(row['recommendation'], 'CLOSE')
        self.assertEqual(row['evidence_hash'], hashlib.sha256(self.evidence.read_bytes()).hexdigest())
        self.assertEqual(row['binding'], 'unknown')
        self.assertIn('positive-controls-unvalidated', row['issues'])
        self.assertIn('requirements-unbound', row['issues'])
        self.assertEqual(len(row['identity']), 64)

    def test_concurrent_replay_closed_and_lost_response(self):
        with concurrent.futures.ThreadPoolExecutor(8) as pool:
            list(pool.map(lambda _: self.run_record(), range(8)))
        self.assertEqual(len(self.rows()), 1)
        subprocess.run(['bash', str(HERE / 'owe.sh'), 'close', '--bucket', str(self.b), '--id', 'o1', '--key', 'HIMMEL-9848'], check=True)
        self.run_record(env={'OWE_NOW_EPOCH': '1900000000'})
        self.assertEqual(len(self.rows()), 2)

    def test_requirements_comment_and_whitespace_identity(self):
        self.run_record()
        p = self.mirror / 'HIMMEL-9848.md'
        p.write_text(p.read_text() + 'new comment\n')
        self.run_record()
        self.assertEqual(len(self.rows()), 1)
        p.write_text(p.read_text().replace('  echo yes', ' echo yes'))
        self.run_record()
        self.assertEqual(len(self.rows()), 2)
        self.evidence.write_text(self.evidence.read_text() + 'new real evidence\n')
        self.run_record()
        self.assertEqual(len(self.rows()), 3)

    def test_keep_errors_and_malformed_preserve_peers(self):
        self.write('| row | Result | Sha | Evidence |\n|---|---|---|---|\n| good | MET | station=' + 'b'*40 + ' | PASS |\n| bad | NOT MET | main=abc1234 | skipped error OWED |\n| malformed |\nVERDICT KEEP next slice\n', keys='HIMMEL-9848 HIMMEL-10220')
        self.run_record()
        self.assertEqual(len(self.rows()), 2)
        for row in self.rows():
            self.assertEqual(row['recommendation'], 'KEEP')
            self.assertEqual(row['validation'], 'pending')
            self.assertTrue(any('malformed' in x for x in row['issues']))
            self.assertTrue(any('NOT MET' in x for x in row['proof_rows']))
            self.assertIn({'basis': 'station', 'sha': 'b'*40}, row['executed_shas'])
            self.assertIn('sha-abbreviated', row['issues'])

    def test_missing_unreadable_and_dry_run(self):
        self.evidence.unlink()
        self.run_record('--dry-run')
        self.assertFalse((self.b / 'owed.jsonl').exists())
        self.run_record()
        self.run_record()
        self.assertEqual(len(self.rows()), 1)
        row = self.rows()[0]
        self.assertNotIn('evidence_hash', row)
        self.assertIn('evidence-unreadable', row['issues'])
        self.assertEqual(row['validation'], 'pending')
        self.evidence.mkdir()
        self.run_record()
        self.assertEqual(len(self.rows()), 1)

    def test_missing_requirements_and_writer_failure(self):
        (self.mirror / 'HIMMEL-9848.md').unlink()
        r = self.run_record(env={'PROOF_OWE_BIN': '/bin/false'}, ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.run_record()
        self.assertIn('requirements-unreadable', self.rows()[0]['issues'])

    def test_missing_evidence_recommendation_and_new_tail(self):
        self.evidence.unlink()
        self.run_record()
        self.assertEqual(self.rows()[0]['recommendation'], 'CLOSE')
        self.doc.write_text(self.doc.read_text().replace('10:00', '11:00'))
        self.run_record()
        self.assertEqual(len(self.rows()), 1)
        self.doc.write_text(self.doc.read_text().replace('verdict=CLOSE', 'verdict=KEEP'))
        self.run_record()
        self.assertEqual(len(self.rows()), 2)

    def test_requirement_line_endings_and_mismatch(self):
        self.run_record()
        p = self.mirror / 'HIMMEL-9848.md'
        p.write_bytes(p.read_bytes().replace(b'\n', b'\r\n'))
        self.run_record()
        self.assertEqual(len(self.rows()), 1)
        self.evidence.write_text('requirements-sha256 HIMMEL-9848=' + 'f'*64 + '\nVERDICT CLOSE\n')
        self.run_record()
        self.assertEqual(self.rows()[-1]['binding'], 'mismatch')
        self.assertIn('requirements-changed', self.rows()[-1]['issues'])

    def test_existing_handoff_render_keeps_pending_action(self):
        self.run_record()
        chief = (HERE.parent / 'chief/chief.sh').read_text()
        start = chief.index('owed_section() {')
        function = chief[start:chief.index('\n}\n', start) + 3]
        result = subprocess.run(['bash', '-c', function + '\nkit=$1\nowed_section "$2"', '_', str(HERE), str(self.b)], text=True, capture_output=True, check=True)
        self.assertIn('## Owed', result.stdout)
        self.assertIn('o1 proof', result.stdout)
        self.assertIn('pending chief validation/reconciliation', result.stdout)

    def test_replay_without_doc_or_manifest_keeps_missing_action(self):
        self.evidence.unlink()
        self.run_record()
        message = self.doc.read_text().splitlines()[-1] + ' N42'
        self.doc.unlink()
        result = subprocess.run(['python3', str(HERE / 'proof-validate.py'), '--bucket', str(self.b), '--label', 'N42', '--mirror', str(self.mirror), '--message-stdin'], input=message, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.rows()), 1)

    def test_peer_artifacts_one_malformed(self):
        other = self.b / 'HIMMEL-10220.md'
        other.write_text('broken row, no verdict\n')
        self.doc.write_text(self.doc.read_text().replace('verdict=CLOSE', 'HIMMEL-10220 verdict=CLOSE') + '- evidence=' + str(other) + '\n')
        # Both paths belong to the wrapped result, not an unrelated later note.
        self.doc.write_text(self.doc.read_text().replace('\n- evidence=', ' evidence='))
        self.run_record()
        rows = self.rows()
        self.assertTrue(any(r['evidence_path'] == str(self.evidence) and r['recommendation'] == 'CLOSE' for r in rows))
        self.assertTrue(any(r['evidence_path'] == str(other) and 'proof-rows-unreadable' in r['issues'] for r in rows))

    def test_generated_proof_header_keeps_all_keys_without_tail_metadata(self):
        self.doc.write_text('# proof\n> **Proof leg:** HIMMEL-9848, HIMMEL-10220\n## Results\n- 10:00 WRAPPED done\n')
        self.run_record()
        self.assertEqual({r['key'] for r in self.rows()}, {'HIMMEL-9848', 'HIMMEL-10220'})
        self.assertTrue(all('evidence-unreadable' in r['issues'] for r in self.rows()))

    def test_notes_do_not_replace_real_result(self):
        self.doc.write_text(self.doc.read_text() + '## Notes\n- WRAPPED — proof HIMMEL-10220 verdict=KEEP evidence=unrelated.md\n')
        self.run_record()
        self.assertEqual([r['key'] for r in self.rows()], ['HIMMEL-9848'])

    def test_requirement_fences_keep_heading_like_code(self):
        p = self.mirror / 'HIMMEL-9848.md'
        p.write_text('## Description\nDoD\n```md\n## Comments\n  exact code\n```\nProof\nCheck it.\n## Comments\nchurn\n')
        self.run_record()
        first = self.rows()[0]
        self.assertIn('requirements_digest', first)
        p.write_text(p.read_text().replace('  exact code', ' exact code'))
        self.run_record()
        self.assertNotEqual(self.rows()[-1]['requirements_digest'], first['requirements_digest'])

    def test_multiple_artifacts_are_one_action_per_key(self):
        extra = self.b / 'second.md'
        extra.write_text('| malformed |\nVERDICT KEEP\n')
        self.doc.write_text(self.doc.read_text().rstrip() + ' evidence=' + str(extra) + '\n')
        self.run_record()
        self.assertEqual(len(self.rows()), 1)
        row = self.rows()[0]
        self.assertEqual(len(row['evidence_records']), 2)
        self.assertEqual(row['recommendation'], 'unknown')
        self.assertIn('recommendation-conflict', row['issues'])
        self.assertTrue(any('PASS yes' in s for s in row['proof_rows']))
        self.run_record()
        self.assertEqual(len(self.rows()), 1)

    def test_sha_bases_and_explicit_binding(self):
        self.run_record()
        digest = self.rows()[0]['requirements_digest']
        self.write('requirements-sha256 HIMMEL-9848=' + digest + '\nrequired-sha main=' + 'c'*40 + '\n| row | MET | station=' + 'b'*40 + ' | PASS |\n| main | MET | main=' + 'a'*40 + ' | PASS |\nVERDICT CLOSE\n')
        self.run_record()
        row = self.rows()[-1]
        self.assertEqual(row['binding'], 'matched')
        self.assertEqual(row['required_shas'], [{'basis': 'main', 'sha': 'c'*40}])
        self.assertIn('candidate-ancestry-unvalidated', row['issues'])
        self.assertEqual({x['basis'] for x in row['executed_shas']}, {'main', 'station'})


if __name__ == '__main__':
    unittest.main()
