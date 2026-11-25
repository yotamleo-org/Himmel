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


class LoopbackFlow(unittest.TestCase):
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
        self.write(stamp=self.module().requirements(mirror))
        self.run_record()
        self.change_decision(identity=self.rows()[0]['identity'],
                             coverage=[{'obligation': 'control stays accepted', 'evidence': 'PASS yes'}],
                             controls=[{'obligation': 'Run the positive control.', 'evidence': 'PASS yes'}])
        self.status = 'To Do'
        self.posts = 0
        self.deny = False
        self.lost = False  # the POST is applied, then the connection drops
        self.drop = False  # the connection drops and the POST is not applied
        self.after_post = None  # a concurrent edit that lands between the CLI's pre-read and its post-read
        self.TRANSITIONS = {'To Do': [('31', 'Done')], 'In Progress': [('11', 'To Do'), ('31', 'Done')], 'Done': []}
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
                    body = {'transitions': [{'id': i, 'name': n, 'to': {'name': n}} for i, n in owner.TRANSITIONS.get(owner.status, [])]}
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
                target = {'31': 'Done', '11': 'To Do'}.get(data.get('transition', {}).get('id'))
                if self.path != '/rest/api/3/issue/HIMMEL-9848/transitions' or target is None or target not in [n for _, n in owner.TRANSITIONS.get(owner.status, [])]:
                    self.send_error(500, 'unexpected fixture POST'); return
                owner.posts += 1
                if not owner.deny and not owner.drop:
                    owner.status = target
                    if owner.after_post:
                        owner.after_post()
                if owner.lost or owner.drop:
                    self.connection.close(); return
                if owner.deny:
                    self.send_response(403); self.end_headers()
                    self.wfile.write(json.dumps({'errorMessages': ['workflow validator refused the transition']}).encode()); return
                self.send_response(204); self.end_headers()

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def tearDown(self):
        decisions.save_fixture(self, 'jira-cli-loopback')

    def cli(self, stamp=False, status='Done', proof=True):
        env = {**os.environ, 'HOME': str(self.b), 'HIMMEL_CONFIG_DIR': str(self.b),
               'JIRA_BASE_URL': 'http://127.0.0.1:' + str(self.server.server_port), 'JIRA_ALLOW_HOST': '127.0.0.1:' + str(self.server.server_port), 'JIRA_EMAIL': 'fixture@example.invalid',
               'JIRA_API_TOKEN': 'fixture-only', 'JIRA_PROJECT_KEY': 'HIMMEL', 'HIMMEL_ADMISSIONS_LEDGER': str(self.b / 'admissions.jsonl')}
        return subprocess.run(['node', str(HERE.parents[1] / 'jira/dist/index.js'), 'transition', 'HIMMEL-9848', status,
            *([] if stamp else ['--no-version']),
            *(['--proof', 'o1', '--proof-bucket', str(self.b), '--proof-decision', str(self.decision)] if proof else [])],
            env=env, text=True, capture_output=True, timeout=15)

class TransitionFlow(LoopbackFlow):
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

    def test_actual_cli_requirements_changed_between_pre_and_post_read_keeps_done_and_an_owned_reconciliation(self):
        self.after_post = lambda: setattr(self, 'requirements', self.requirements + '\nA new obligation.')
        result = self.cli()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(self.status, 'Done')
        recs = [r for r in self.rows() if r.get('action') == 'requirements-reconciliation']
        self.assertEqual((len(recs), recs[0]['actor'], recs[0]['actual_status']), (1, 'chief', 'Done'))
        self.assertFalse(any(r['op'] == 'close' for r in self.rows()))
        posts = self.posts
        again = self.cli()  # a replay reads the real Done status: no POST, no new action, no close
        self.assertNotEqual(again.returncode, 0)
        self.assertIn('requirements-reconciliation ' + recs[0]['id'], again.stderr)
        self.assertEqual(self.posts, posts)
        self.assertEqual(len([r for r in self.rows() if r.get('action') == 'requirements-reconciliation']), 1)
        self.assertFalse(any(r['op'] == 'close' for r in self.rows()))

    def test_actual_cli_exit3_retains_done_and_owned_version_debt(self):
        (self.b / 'admissions.jsonl').write_text(json.dumps(dict(ts='t', version='v1', key='HIMMEL-9848', kind='deferral', actor='fixture')) + '\n')
        result = self.cli(stamp=True)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(self.status, 'Done')
        self.assertEqual(self.rows()[1]['action'], 'version-reconciliation')
        self.assertEqual(self.rows()[-1]['outcome']['status'], 'Done')
        self.assertTrue(self.rows()[-1]['outcome']['version_pending'])


class KeepFlow(LoopbackFlow):
    """A chief KEEP lands the ticket in To Do through the same CLI: from To Do, from In Progress and after a lost response."""

    NEXT = {'actor': 'proof', 'capability': 'read-only proof worker', 'text': 'Run the missing positive control', 'due': '2026-11-20', 'wake': 'after station update'}

    def setUp(self):
        super().setUp()
        self.change_decision(verdict='KEEP', next=self.NEXT)

    def keep(self):
        return self.cli(status='To Do')

    def closes(self):
        return [r for r in self.rows() if r['op'] == 'close']

    def test_keep_on_a_ticket_already_to_do_settles_without_a_transition(self):
        self.status = 'To Do'
        result = self.keep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.posts, 0)
        self.assertEqual(len(self.closes()), 1)
        self.assertEqual(len([r for r in self.rows() if r['op'] == 'add']), 2)  # the validation and the next step it wrote
        again = self.keep()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual((len(self.closes()), self.posts), (1, 0))

    def test_keep_from_in_progress_transitions_once_then_settles(self):
        self.status = 'In Progress'
        result = self.keep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.status, self.posts, len(self.closes())), ('To Do', 1, 1))

    def test_keep_after_a_lost_response_and_restart_discharges_once(self):
        self.status = 'In Progress'
        self.lost = True
        result = self.keep()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status, 'To Do')
        again = self.keep()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual((self.posts, len(self.closes())), (1, 1))

    def test_keep_whose_post_never_applied_reports_the_transport_error_and_stays_pending(self):
        self.status = 'In Progress'
        self.drop = True
        result = self.keep()
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, r'(?i)fetch failed|terminated|socket|closed')
        self.assertEqual((self.closes(), self.status), ([], 'In Progress'))

    def test_keep_with_an_explicit_http_rejection_keeps_the_server_detail(self):
        self.status = 'In Progress'
        self.deny = True
        result = self.keep()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('HTTP 403', result.stderr)
        self.assertIn('workflow validator refused', result.stderr)
        self.assertEqual(self.closes(), [])


class OrdinaryCallers(LoopbackFlow):
    """Without --proof the shared transition keeps its original semantics."""

    def test_ordinary_http_rejection_keeps_the_server_detail(self):
        self.deny = True
        result = self.cli(proof=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('HTTP 403', result.stderr)
        self.assertIn('workflow validator refused', result.stderr)

    def test_ordinary_already_done_is_still_transition_not_found(self):
        self.status = 'Done'
        result = self.cli(proof=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Transition "Done" not found', result.stderr)
        self.assertEqual(self.posts, 0)

    def test_ordinary_lost_response_is_an_error_not_a_recovery(self):
        self.drop = True
        result = self.cli(proof=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.posts, 1)

    def test_ordinary_transition_to_a_listed_status_still_works(self):
        result = self.cli(proof=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.status, self.posts), ('Done', 1))


class RemainderPath(LoopbackFlow):
    """The live remainder through the real CLI: the race path, a settle that fails after the move, and a slow read."""

    world = decisions.ChiefDecision.world
    merge = decisions.ChiefDecision.merge
    body = decisions.ChiefDecision.body
    partial = decisions.ChiefDecision.partial
    CODE = decisions.ChiefDecision.CODE

    def cli_with(self, env_extra, status='Done'):
        env = {**os.environ, 'HOME': str(self.b), 'HIMMEL_CONFIG_DIR': str(self.b),
               'JIRA_BASE_URL': 'http://127.0.0.1:' + str(self.server.server_port), 'JIRA_ALLOW_HOST': '127.0.0.1:' + str(self.server.server_port), 'JIRA_EMAIL': 'fixture@example.invalid',
               'JIRA_API_TOKEN': 'fixture-only', 'JIRA_PROJECT_KEY': 'HIMMEL', 'HIMMEL_ADMISSIONS_LEDGER': str(self.b / 'admissions.jsonl'),
               **{k: v for k, v in env_extra.items() if k != 'HOME'}}
        self.command = ['node', str(HERE.parents[1] / 'jira/dist/index.js'), 'transition', 'HIMMEL-9848', status, '--no-version',
                        '--proof', 'o1', '--proof-bucket', str(self.b), '--proof-decision', str(self.decision)]
        return subprocess.run(self.command, env=env, text=True, capture_output=True, timeout=30)

    def test_a_remainder_that_appears_after_the_check_names_the_remainder_and_its_step_not_dod_proof(self):
        env = self.world()
        self.after_post = lambda: self.partial(77, self.CODE)
        result = self.cli_with(env)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(self.status, 'Done')
        steps = [r for r in self.rows() if r.get('capability') == 'remainder reconciliation']
        self.assertEqual(len(steps), 1)
        self.assertIn('PR #77', result.stderr)
        self.assertIn('implement X', result.stderr)
        self.assertIn('remainder reconciliation ' + steps[0]['id'], result.stderr)
        self.assertNotIn('DoD/Proof', result.stderr)
        self.assertFalse(any(r['op'] == 'close' for r in self.rows()))

    def test_a_settle_that_fails_after_the_move_says_done_not_settled_and_the_command_and_nothing_moves_back(self):
        env = self.world()
        writer = self.b / 'refuse-add.sh'
        writer.write_text('#!/bin/bash\n[ "$1" != add ] || { echo "disk full" >&2; exit 4; }\nexec bash ' + str(HERE / 'owe.sh') + ' "$@"\n')
        self.after_post = lambda: self.partial(77, self.CODE)
        result = self.cli_with({**env, 'PROOF_OWE_BIN': str(writer)})
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual((self.status, self.posts), ('Done', 1))
        self.assertIn('is now Done', result.stderr)
        self.assertIn('validation o1 is NOT settled', result.stderr)
        self.assertIn('disk full', result.stderr)
        self.assertIn('Run it again: node ' + ' '.join(self.command[1:]), result.stderr)
        self.assertFalse(any(r['op'] == 'close' for r in self.rows()))
        # clear the remainder and run the printed command again: the ticket is read as Done, no second POST, the validation settles once
        self.after_post = None
        self.merge(80, contract='yes')
        again = self.cli_with(env)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(self.posts, 1)
        self.assertEqual(len([r for r in self.rows() if r['op'] == 'close' and r['ref'] == 'o1']), 1)

    def test_the_run_it_again_line_asks_for_a_tool_timeout_that_outlasts_a_read_in_each_leg(self):
        env = self.world()
        writer = self.b / 'refuse-add.sh'
        writer.write_text('#!/bin/bash\n[ "$1" != add ] || { echo "disk full" >&2; exit 4; }\nexec bash ' + str(HERE / 'owe.sh') + ' "$@"\n')
        self.after_post = lambda: self.partial(77, self.CODE)
        result = self.cli_with({**env, 'PROOF_OWE_BIN': str(writer)})
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Run it again: node ' + ' '.join(self.command[1:]), result.stderr)
        self.assertIn('300000 ms', result.stderr)

    def test_a_slow_pull_request_read_refuses_at_the_check_with_the_unreadable_message_before_any_move(self):
        env = self.world()
        self.partial(77, self.CODE)
        slow = self.live / 'slow-gh'
        slow.write_text('#!/bin/sh\nsleep 25\n')
        slow.chmod(0o755)
        result = self.cli_with({**env, 'NEXT_DISPATCH_GH_CMD': str(slow), 'PROOF_REMAINDER_BUDGET_SECS': '2'})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.posts, self.status), (0, 'To Do'))
        self.assertIn('live pull-request remainder unreadable', result.stderr)
        self.assertIn('PR #77', result.stderr)
        self.assertEqual([r for r in self.rows() if r['op'] == 'close'], [])


if __name__ == '__main__':
    unittest.main()
