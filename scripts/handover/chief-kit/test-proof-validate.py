#!/usr/bin/env python3
"""Record-only proof handoff, entirely scratch/offline."""
import concurrent.futures
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import stat
from types import SimpleNamespace
import time
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
HANG_GUARD_SECS = 60


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

    def write(self, evidence=None, keys='HIMMEL-9848', tail='', stamp=None, results_extra=''):
        # `stamp` is the producer's frozen original requirement line: it lives in the generated brief above `## Results`,
        # where gen-briefs writes it. Anything under Results or in the artifact is worker-written.
        self.evidence.write_text(evidence or '| row | Result | Sha | Evidence |\n|---|---|---|---|\n| control | MET | main=' + 'a'*40 + ' | PASS yes |\nVERDICT CLOSE\n')
        frozen = '' if stamp is None else 'requirements-sha256 HIMMEL-9848=' + stamp + '\n'
        self.doc.write_text('# proof worker\n> **Live test:** none — proof leg\n' + frozen + '## Results\n- 10:00 WRAPPED — proof ' + keys + ' verdict=CLOSE evidence=' + str(self.evidence) + tail + '\n' + results_extra)

    def run_record(self, *args, ok=True, env=None):
        r = subprocess.run(['python3', str(HERE / 'proof-validate.py'), '--bucket', str(self.b), '--doc', str(self.doc), '--mirror', str(self.mirror), *args], capture_output=True, text=True, env={**os.environ, **(env or {})}, timeout=HANG_GUARD_SECS)
        if ok:
            self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def rows(self):
        return [json.loads(x) for x in (self.b / 'owed.jsonl').read_text().splitlines()]

    def module(self):
        spec = importlib.util.spec_from_file_location('proof_validate', HERE / 'proof-validate.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def options(self):
        return SimpleNamespace(bucket=str(self.b), doc=str(self.doc), mirror=str(self.mirror),
                               label='', message_stdin=False, dry_run=False)

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

    def test_non_utf8_evidence_retains_hash_and_changed_identity(self):
        first = b'\xff\xfeproof bytes'
        self.evidence.write_bytes(first)
        self.run_record()
        row = self.rows()[0]
        self.assertEqual(row.get('evidence_hash'), hashlib.sha256(first).hexdigest())
        self.assertIn('evidence-unreadable', row['issues'])
        self.assertEqual(row['validation'], 'pending')
        self.run_record()
        self.assertEqual(len(self.rows()), 1)

        changed = b'\xff\xfechanged proof bytes'
        self.evidence.write_bytes(changed)
        self.run_record()
        rows = self.rows()
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[1].get('evidence_hash'), hashlib.sha256(changed).hexdigest())
        self.assertNotEqual(rows[0]['identity'], rows[1]['identity'])
        self.assertIn('evidence-unreadable', rows[1]['issues'])
        self.assertEqual(rows[1]['validation'], 'pending')

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
        self.write('VERDICT CLOSE\n', stamp='f'*64)
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

    def test_every_declared_artifact_of_a_single_ticket_is_kept_whatever_its_name(self):
        named, other = self.b / 'HIMMEL-9848-proof.md', self.b / 'station-control.md'
        other.write_text('| row | Result | Sha | Evidence |\n|---|---|---|---|\n| station check | NOT MET | main=' + 'a'*40 + ' | timed out |\nVERDICT KEEP\n')
        self.evidence = named
        for order in ('named first', 'named last'):
            with self.subTest(order=order):
                (self.b / 'owed.jsonl').unlink(missing_ok=True)
                self.write(tail=' evidence=' + str(other))
                if order == 'named last':
                    self.doc.write_text(self.doc.read_text().replace('evidence=' + str(named) + ' evidence=' + str(other), 'evidence=' + str(other) + ' evidence=' + str(named)))
                self.run_record()
                self.assertEqual(len(self.rows()), 1)
                row = self.rows()[0]
                self.assertEqual(sorted(r['path'] for r in row.get('evidence_records', [])), sorted([str(named), str(other)]))
                self.assertEqual(row['recommendation'], 'unknown')
                self.assertIn('recommendation-conflict', row['issues'])
                self.assertTrue(any(str(other) in s and 'NOT MET' in s for s in row['proof_rows']))
                self.assertTrue(any(str(named) in s and 'PASS yes' in s for s in row['proof_rows']))
                # the declaration of one ticket is the attribution of every artifact it names
                self.assertNotIn('artifact-attribution-unvalidated', row['issues'])

    def test_every_audit_path_a_single_ticket_brief_writes_is_kept_whatever_its_name(self):
        audits = self.b / 'specs' / 'audits'
        audits.mkdir(parents=True)
        named, other = audits / 'HIMMEL-9848-proof.md', audits / 'station-control.md'
        named.write_text(self.evidence.read_text())
        other.write_text('| row | Result | Sha | Evidence |\n|---|---|---|---|\n| station check | NOT MET | main=' + 'a'*40 + ' | timed out |\nVERDICT KEEP\n')
        self.doc.write_text('# proof\n> **Proof leg:** HIMMEL-9848\n> **Writes:** `' + str(named) + '`, `' + str(other) + '`\n## Results\n- 10:00 WRAPPED done\n')
        self.run_record()
        row = self.rows()[0]
        self.assertEqual(sorted(r['path'] for r in row.get('evidence_records', [])), sorted([str(named), str(other)]))
        self.assertEqual(row['recommendation'], 'unknown')

    def test_an_unnamed_artifact_beside_a_ticket_named_one_is_an_issue_when_several_tickets_are_declared(self):
        named, other = self.b / 'HIMMEL-9848-proof.md', self.b / 'summary.md'
        named.write_text(self.evidence.read_text())
        other.write_text(self.evidence.read_text())
        self.evidence = named
        self.write(keys='HIMMEL-9848 HIMMEL-10220', tail=' evidence=' + str(other))
        self.run_record()
        row = next(r for r in self.rows() if r['key'] == 'HIMMEL-9848')
        self.assertEqual(sorted(r['path'] for r in row.get('evidence_records', [])), sorted([str(named), str(other)]))
        self.assertIn('artifact-attribution-unvalidated', row['issues'])
        # a ticket-named artifact of each ticket needs no such attribution
        (self.b / 'owed.jsonl').unlink()
        second = self.b / 'HIMMEL-10220-proof.md'
        second.write_text(self.evidence.read_text())
        self.write(keys='HIMMEL-9848 HIMMEL-10220', tail=' evidence=' + str(second))
        self.run_record()
        for row in self.rows():
            self.assertNotIn('artifact-attribution-unvalidated', row['issues'])
            self.assertNotIn('evidence_records', row)

    def test_sha_bases_and_explicit_binding(self):
        self.run_record()
        digest = self.rows()[0]['requirements_digest']
        self.write('required-sha main=' + 'c'*40 + '\n| row | MET | station=' + 'b'*40 + ' | PASS |\n| main | MET | main=' + 'a'*40 + ' | PASS |\nVERDICT CLOSE\n', stamp=digest)
        self.run_record()
        row = self.rows()[-1]
        self.assertEqual(row['binding'], 'matched')
        self.assertEqual(row['required_shas'], [{'basis': 'main', 'sha': 'c'*40}])
        self.assertIn('candidate-ancestry-unvalidated', row['issues'])
        self.assertEqual({x['basis'] for x in row['executed_shas']}, {'main', 'station'})

    def current_digest(self):
        return self.module().requirements(self.mirror / 'HIMMEL-9848.md')

    def test_original_stamp_is_read_from_the_producer_brief_not_from_the_worker(self):
        current = self.current_digest()
        claim = 'requirements-sha256 HIMMEL-9848=' + current + '\n'
        cases = {
            'no frozen original, the worker adds the current hash to its artifact': dict(evidence=claim + 'VERDICT CLOSE\n'),
            'no frozen original, the worker adds the current hash under Results': dict(results_extra=claim),
            'the brief could not freeze one (unknown), the worker adds the current hash': dict(evidence=claim + 'VERDICT CLOSE\n', results_extra='requirements-binding HIMMEL-9848=unknown; reconcile before CLOSE\n'),
        }
        for name, kwargs in cases.items():
            with self.subTest(name):
                (self.b / 'owed.jsonl').unlink(missing_ok=True)
                self.write(**kwargs)
                self.run_record()
                row = self.rows()[-1]
                self.assertEqual(row['binding'], 'unknown')
                self.assertNotIn('original_requirements_digest', row)
                self.assertIn('requirements-stamp-untrusted', row['issues'])
                self.assertIn('requirements-unbound', row['issues'])

    def test_a_frozen_original_decides_and_a_conflicting_worker_claim_blocks(self):
        current = self.current_digest()
        for name, stamp, evidence, binding, issue in [
            ('matching frozen original', current, None, 'matched', None),
            ('frozen original, requirements since changed', 'f' * 64, None, 'mismatch', 'requirements-changed'),
            ('frozen original and an agreeing worker line', current, 'requirements-sha256 HIMMEL-9848=' + current + '\nVERDICT CLOSE\n', 'matched', None),
            ('frozen original and a worker line that disagrees', current, 'requirements-sha256 HIMMEL-9848=' + 'e' * 64 + '\nVERDICT CLOSE\n', 'unknown', 'requirements-stamp-conflict'),
        ]:
            with self.subTest(name):
                (self.b / 'owed.jsonl').unlink(missing_ok=True)
                self.write(evidence, stamp=stamp)
                self.run_record()
                row = self.rows()[-1]
                self.assertEqual(row['binding'], binding)
                if issue:
                    self.assertIn(issue, row['issues'])
                if binding == 'matched':
                    self.assertEqual(row['original_requirements_digest'], current)
                    self.assertNotIn('requirements-stamp-untrusted', row['issues'])

    def test_fifo_evidence_returns_prompt_reconciliation(self):
        self.evidence.unlink()
        os.mkfifo(self.evidence)
        started = time.monotonic()
        self.run_record()
        self.assertLess(time.monotonic() - started, 2)
        self.assertNotIn('evidence_hash', self.rows()[0])
        self.assertIn('evidence-unreadable', self.rows()[0]['issues'])
        self.run_record()
        self.assertEqual(len(self.rows()), 1)

    def test_symlink_and_oversize_are_not_hashed(self):
        target = self.b / 'target'
        target.write_text('VERDICT CLOSE\n')
        self.evidence.unlink()
        self.evidence.symlink_to(target)
        self.run_record()
        self.assertNotIn('evidence_hash', self.rows()[0])
        self.evidence.unlink()
        with self.evidence.open('wb') as stream:
            stream.truncate(8 * 1024 * 1024 + 1)
        self.run_record()
        self.assertNotIn('evidence_hash', self.rows()[-1])
        self.assertIn('evidence-unreadable', self.rows()[-1]['issues'])

    def test_shared_primary_named_artifact_keeps_secondary_hash(self):
        primary, secondary = 'HIMMEL-' + '9975', 'HIMMEL-' + '9800'
        for key in (primary, secondary):
            (self.mirror / (key + '.md')).write_text('## Description\n' + self.requirements)
        artifact = self.b / (primary + '-proof.md')
        self.evidence.rename(artifact)
        self.doc.write_text('# proof\n## Results\n- 10:00 WRAPPED — proof ' + primary + ', ' + secondary +
                            ' verdict=CLOSE evidence=' + str(artifact) + '\n')
        self.run_record()
        rows = self.rows()
        self.assertEqual({r['key'] for r in rows}, {primary, secondary})
        expected = hashlib.sha256(artifact.read_bytes()).hexdigest()
        for row in rows:
            self.assertEqual(row['evidence_path'], str(artifact))
            self.assertEqual(row['evidence_hash'], expected)
            self.assertEqual(row['validation'], 'pending')
        self.assertIn('artifact-attribution-unvalidated', next(r for r in rows if r['key'] == secondary)['issues'])

    def test_large_artifact_bounds_observations_without_argv_failure(self):
        self.evidence.write_text(('| row | MET | ' + 'x' * 120 + ' |\n') * 3000 +
                                 ('| malformed ' + 'Ω' * 2000 + '\n') * 100 + 'VERDICT KEEP\n')
        expected = hashlib.sha256(self.evidence.read_bytes()).hexdigest()
        self.run_record()
        row = self.rows()[0]
        self.assertEqual(row['evidence_hash'], expected)
        self.assertEqual(row['recommendation'], 'KEEP')
        self.assertLessEqual(len(row['proof_rows']), 64)
        self.assertLessEqual(len(row['issues']), 32)
        self.assertLessEqual(max(map(len, row['proof_rows'])), 512)
        self.assertGreater(row['observation_counts']['proof_rows']['omitted'], 0)
        self.assertGreater(row['observation_counts']['issues']['omitted'], 0)
        self.run_record()
        self.assertEqual(len(self.rows()), 1)

    def test_nonproof_prose_and_loose_leg_kind_do_not_create_debt(self):
        for text in ('A proof leg could check this next.', '> **Leg kind:** proof'):
            self.doc.write_text('# ordinary worker\n' + text + '\n## Results\n- 10:00 WRAPPED implementation done\n')
            self.run_record()
            self.assertFalse((self.b / 'owed.jsonl').exists())

    def test_device_shaped_descriptor_is_rejected_before_read(self):
        module = self.module()
        with mock.patch.object(module.os, 'fstat', return_value=SimpleNamespace(st_mode=stat.S_IFCHR, st_size=0)), \
                mock.patch.object(module.os, 'read', side_effect=AssertionError('device read attempted')) as read:
            with self.assertRaises(ValueError):
                module.regular_bytes(self.evidence)
        read.assert_not_called()

    def test_changed_or_replaced_file_has_no_accepted_hash(self):
        for replacement in (False, True):
            with self.subTest(replacement=replacement):
                self.write()
                ledger = self.b / 'owed.jsonl'
                ledger.unlink(missing_ok=True)
                module = self.module()
                original_read = os.read
                evidence_inode = self.evidence.stat().st_ino
                changed = False
                def changing_read(fd, amount):
                    nonlocal changed
                    chunk = original_read(fd, amount)
                    if not changed and os.fstat(fd).st_ino == evidence_inode:
                        changed = True
                        if replacement:
                            self.evidence.rename(self.b / 'old-artifact')
                            self.evidence.write_bytes(chunk)
                        else:
                            with self.evidence.open('ab') as stream:
                                stream.write(b'changed')
                    return chunk
                with mock.patch.object(module.os, 'read', side_effect=changing_read):
                    module.record(self.options())
                self.assertTrue(changed)
                self.assertNotIn('evidence_hash', self.rows()[0])
                self.assertIn('evidence-unreadable', self.rows()[0]['issues'])

    def test_artifact_allocation_or_io_error_preserves_reconciliation(self):
        module = self.module()
        original = module.regular_bytes
        for failure in (MemoryError, OSError):
            (self.b / 'owed.jsonl').unlink(missing_ok=True)
            def failed_read(path):
                if str(path) == str(self.evidence):
                    raise failure('fixture read failure')
                return original(path)
            with mock.patch.object(module, 'regular_bytes', side_effect=failed_read):
                module.record(self.options())
            self.assertNotIn('evidence_hash', self.rows()[0])
            self.assertIn('evidence-unreadable', self.rows()[0]['issues'])

    def test_exact_size_boundary_is_accepted_then_oversize_reconciles(self):
        raw = b'#' * (8 * 1024 * 1024 - 14) + b'\nVERDICT KEEP\n'
        self.evidence.write_bytes(raw)
        self.run_record()
        self.assertEqual(self.rows()[0]['evidence_hash'], hashlib.sha256(raw).hexdigest())
        with self.evidence.open('ab') as stream:
            stream.write(b'overflow')
        self.run_record()
        self.assertNotIn('evidence_hash', self.rows()[-1])

    def test_text_and_sha_observations_expose_exact_omission_counts(self):
        self.write(''.join('| row | MET | main=' + format(n, '040x') + ' |\nrequired-sha main=' + format(n, '040x') + '\n' for n in range(70)) +
                   'next-action: ' + 'x' * 5000 + '\nwake: ' + 'y' * 5000 + '\nVERDICT KEEP\n')
        self.run_record()
        row = self.rows()[0]
        for field in ('executed_shas', 'required_shas'):
            self.assertEqual(len(row[field]), 64)
            self.assertEqual(row['observation_counts'][field]['total'], 70)
            self.assertEqual(row['observation_counts'][field]['omitted'], 6)
        for field in ('next_action', 'wake'):
            self.assertEqual(len(row[field]), 1024)
            self.assertEqual(row['observation_counts'][field]['omitted'], 3976)

    def test_message_requires_a_real_wrapped_proof_key_tail(self):
        self.doc.write_text('# ordinary worker\n## Results\n- 10:00 WRAPPED implementation done\n')
        result = subprocess.run(['python3', str(HERE / 'proof-validate.py'), '--bucket', str(self.b), '--doc', str(self.doc),
                                 '--mirror', str(self.mirror), '--message-stdin'],
                                input='Discussed WRAPPED proof HIMMEL-9848 as an example.', capture_output=True, text=True, timeout=HANG_GUARD_SECS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.b / 'owed.jsonl').exists())
        result = subprocess.run(['python3', str(HERE / 'proof-validate.py'), '--bucket', str(self.b), '--doc', str(self.doc),
                                 '--mirror', str(self.mirror), '--message-stdin'],
                                input='N42 HIMMEL-9848 WRAPPED — proof HIMMEL-9848 verdict=KEEP evidence=' + str(self.evidence), capture_output=True, text=True, timeout=HANG_GUARD_SECS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.rows()[0]['recommendation'], 'CLOSE')

    def test_shared_status_shapes_and_legacy_proof_tail_remain_positive(self):
        for heading, marker in [('## Results\n', '- WRAPPED'), ('## Results\n', '- 10:00 **WRAPPED**'), ('', '- 10:00 WRAPPED')]:
            (self.b / 'owed.jsonl').unlink(missing_ok=True)
            self.doc.write_text('# worker\n' + heading + marker + ' — proof HIMMEL-9848 verdict=CLOSE evidence=' + str(self.evidence) + '\n')
            self.run_record()
            self.assertEqual(self.rows()[0]['evidence_hash'], hashlib.sha256(self.evidence.read_bytes()).hexdigest())

    def test_old_wrapped_proof_is_not_the_current_tail(self):
        self.doc.write_text(self.doc.read_text() + '- 11:00 LIVE ordinary implementation\n')
        self.run_record()
        self.assertFalse((self.b / 'owed.jsonl').exists())


if __name__ == '__main__':
    unittest.main()
