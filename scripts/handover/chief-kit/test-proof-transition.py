#!/usr/bin/env python3
"""Run the normal Jira CLI against loopback fixtures, never a live service."""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import threading
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('decisions', HERE / 'test-proof-decision.py')
decisions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(decisions)


class TransitionFlow(unittest.TestCase):
    write = decisions.ChiefDecision.write
    module = decisions.ChiefDecision.module
    run_record = decisions.ChiefDecision.run_record
    rows = decisions.ChiefDecision.rows
    change_decision = decisions.ChiefDecision.change_decision

    def setUp(self):
        decisions.ChiefDecision.setUp(self)
        (self.b / 'owed.jsonl').unlink()
        self.requirements = 'DoD\n- control stays accepted\nProof\nRun the positive control.'
        mirror = self.mirror / 'HIMMEL-9848.md'
        mirror.write_text('## Description\n\n' + self.requirements + '\n\n## Comments\n')
        self.write()
        self.evidence.write_text(self.evidence.read_text() + 'requirements-sha256 HIMMEL-9848=' + self.module().requirements(mirror) + '\n')
        self.run_record()
        self.change_decision(identity=self.rows()[0]['identity'])
        self.status = 'To Do'
        self.posts = 0
        self.deny = False
        self.lost = False
        self.requests = []
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                owner.requests.append(dict(method='GET', path=self.path))
                if self.path == '/rest/api/3/project/HIMMEL/versions':
                    body = [{'id': '1', 'name': 'v1', 'released': False, 'description': 'frozen: 2026-11-16\nfrozen-keys: HIMMEL-1'}]
                elif self.path == '/rest/api/3/issue/HIMMEL-9848/transitions':
                    body = {'transitions': [] if owner.status == 'Done' else [{'id': '31', 'name': 'Done', 'to': {'name': 'Done'}}]}
                elif self.path.startswith('/rest/api/3/issue/HIMMEL-9848?fields='):
                    body = {'key': 'HIMMEL-9848', 'fields': {'description': {'type': 'doc', 'version': 1,
                        'content': [{'type': 'paragraph', 'content': [{'type': 'text', 'text': owner.requirements}]}]},
                        'status': {'name': owner.status, 'statusCategory': {'key': 'done' if owner.status == 'Done' else 'new'}}, 'labels': [], 'fixVersions': []}}
                else:
                    self.send_error(500, 'unexpected fixture GET'); return
                self.send_response(200); self.end_headers(); self.wfile.write(json.dumps(body).encode())

            def do_POST(self):
                data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                owner.requests.append(dict(method='POST', path=self.path, body=data))
                if self.path != '/rest/api/3/issue/HIMMEL-9848/transitions' or data != {'transition': {'id': '31'}}:
                    self.send_error(500, 'unexpected fixture POST'); return
                owner.posts += 1
                if not owner.deny:
                    owner.status = 'Done'
                if owner.lost:
                    self.connection.close(); return
                self.send_response(403 if owner.deny else 204); self.end_headers()

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def tearDown(self):
        decisions.save_fixture(self, 'jira-cli-loopback')

    def cli(self, stamp=False):
        env = {**os.environ, 'HOME': str(self.b), 'HIMMEL_CONFIG_DIR': str(self.b),
               'JIRA_BASE_URL': 'http://127.0.0.1:' + str(self.server.server_port), 'JIRA_EMAIL': 'fixture@example.invalid',
               'JIRA_API_TOKEN': 'fixture-only', 'JIRA_PROJECT_KEY': 'HIMMEL', 'HIMMEL_ADMISSIONS_LEDGER': str(self.b / 'admissions.jsonl')}
        return subprocess.run(['node', str(HERE.parents[1] / 'jira/dist/index.js'), 'transition', 'HIMMEL-9848', 'Done',
            *([] if stamp else ['--no-version']), '--proof', 'o1', '--proof-bucket', str(self.b), '--proof-decision', str(self.decision)],
            env=env, text=True, capture_output=True, timeout=15)

    def test_actual_cli_lost_response_restart_discharge_once(self):
        self.lost = True
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status, 'Done')
        self.assertEqual(len([r for r in self.rows() if r['op'] == 'close']), 1)
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.posts, 1)

    def test_actual_cli_restart_after_moved_before_discharge(self):
        self.status = 'Done'
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.posts, 0)
        self.assertEqual(self.rows()[-1]['outcome']['status'], 'Done')

    def test_actual_cli_denied_or_changed_requirements_remain_pending(self):
        self.deny = True
        result = self.cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.rows()), 1)
        self.requirements += '\nA new obligation.'
        result = self.cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.posts, 1)
        self.assertEqual(len(self.rows()), 1)

    def test_actual_cli_exit3_retains_done_and_owned_version_debt(self):
        (self.b / 'admissions.jsonl').write_text(json.dumps(dict(ts='t', version='v1', key='HIMMEL-9848', kind='deferral', actor='fixture')) + '\n')
        result = self.cli(stamp=True)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(self.status, 'Done')
        self.assertEqual(self.rows()[1]['action'], 'version-reconciliation')
        self.assertEqual(self.rows()[-1]['outcome']['status'], 'Done')
        self.assertTrue(self.rows()[-1]['outcome']['version_pending'])


if __name__ == '__main__':
    unittest.main()
