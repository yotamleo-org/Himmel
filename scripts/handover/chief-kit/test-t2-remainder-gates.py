#!/usr/bin/env python3
"""Focused real gate code, with optional immutable-base RED fixture sources."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
BASE = os.environ.get('T2_REMAINDER_BASE')
GIT_ENV = {key: value for key, value in os.environ.items() if key not in {
    'GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
    'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX', 'GIT_IMPLICIT_WORK_TREE', 'GIT_GRAFT_FILE',
    'GIT_REPLACE_REF_BASE', 'GIT_SHALLOW_FILE', 'GIT_CONFIG', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT'}}


def source(path):
    return subprocess.check_output(['git', 'show', BASE + ':' + path], cwd=ROOT, text=True, env=GIT_ENV) if BASE else (ROOT / path).read_text()


class Gates(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        lib = self.root / 'scripts/lib'
        lib.mkdir(parents=True)
        (self.root / 'scripts/handover/chief-kit').mkdir(parents=True)
        for path in (ROOT / 'scripts/lib').iterdir():
            if path.is_file():
                (lib / path.name).symlink_to(path)
        for path in ('scripts/lib/ticket-status.sh', 'scripts/lib/pr_remainder.py'):
            (self.root / path).unlink()
            (self.root / path).write_text(source(path))
        gh = self.root / 'gh'
        gh.write_text('#!/bin/sh\nprintf "%s" "$TEST_BODY"\n')
        gh.chmod(0o700)

    def gate(self, which, ask, owner):
        body = '## Ticket coverage\n- ' + ask + ': owed -> ' + owner + ' by 2026-11-20\n'
        if which == 'merge':
            text = source('scripts/handover/merge-on-green.sh')
            start = text.index('_pr_remainder_answer() {')
            block = text[start:text.index('\nlocal_commit_guard\n', start)]
            command = '. "$1/scripts/lib/ticket-status.sh"\naudit() { :; }\n_merge_contract() { MERGE_ROW_CONTRACT=no; }\n' + block + '\nprintf "%s/%s" "$MERGE_ROW_REMAINDER" "$MERGE_ROW_OWED"\n'
        else:
            text = source('scripts/handover/chief-kit/ready-check.sh')
            start = text.index('check_partial_remainder() {')
            block = text[start:text.index('\n}\n', start) + 3]
            command = 'fails=0\nmark_fail() { fails=$((fails+1)); }\n' + block + '\ncheck_partial_remainder\nexit "$fails"\n'
        env = {**os.environ, 'TEST_BODY': body, 'cov_body': body, 'himmel_repo': str(self.root),
               'GH_READ_BIN': str(self.root / 'gh'), 'fresh_title': 'fix: [HIMMEL-10220] fixture', 'pr_num': '77', 'nwo': 'fixture/repo',
               'ONLY7': '0', 'SELF_DIR': str(self.root / 'scripts/handover/chief-kit'), 'READY_CHECK_ANCHOR': str(self.root),
               'snapshot': '[{"title":"fix: [HIMMEL-10220] fixture"}]', 'REQUIRE_CONTRACT': '1', 'CONTRACT': 'no', 'PR': '77'}
        return subprocess.run(['bash', '-c', command, '_', str(self.root)], env=env, text=True, capture_output=True)

    def test_merge_refuses_chief_routed_proof(self):
        r = self.gate('merge', 'run the live proof on the station', 'chief')
        self.assertEqual(r.returncode, 26, r.stdout + r.stderr)
        self.assertIn('owed → proof', r.stderr)

    def test_ready_refuses_chief_routed_proof(self):
        r = self.gate('ready', 'run the live proof on the station', 'chief')
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn('owed → proof', r.stdout)

    def test_chief_signature_negative_controls(self):
        for which in ('merge', 'ready'):
            r = self.gate(which, 'sign the spec', 'chief')
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_merge_preserves_executable_proof_owner(self):
        r = self.gate('merge', 'run the live proof', 'proof')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, 'owed/proof')

    def test_ready_accepts_proof_as_an_owned_step(self):
        r = self.gate('ready', 'run the live proof', 'proof')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('(owed)', r.stdout)


if __name__ == '__main__':
    unittest.main()
