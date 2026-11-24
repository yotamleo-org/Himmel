#!/usr/bin/env python3
"""Offline integration checks for the public fleet writer and launch gates."""
import collections
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import time
import sys
import shutil
import tempfile
import unittest
from unittest import mock

os.environ['HIMMEL_CORE_CHECK_BATCH'] = 'off'
ROOT = Path(__file__).resolve().parents[2]
WRITER =ROOT / 'scripts/handover/chief-kit/fleet-manifest.sh'
ENTRYPOINTS = Path(os.environ.get('FLEET_RUNTIME_ENTRYPOINTS', ROOT))


class Runtime(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bucket = Path(self.tmp.name)
        self.real_ps = shutil.which('ps')
        self.preexisting_pids = self.bucket / 'preexisting-pids'
        self.preexisting_pids.write_text(subprocess.run([self.real_ps, '-eo', 'pid='], capture_output=True, text=True).stdout)
        if os.environ.get('FLEET_RUNTIME_EVIDENCE'):
            self.addCleanup(self.save_evidence)
        self.env = dict(os.environ, HOME=str(self.bucket), HIMMEL_FLEET_SLOTS=str(self.bucket / 'slots'),
                        HIMMEL_POLICY_FOLLOWS_HOME='1')
        self.doc = self.bucket / 'TEST-1-N1-worker.md'
        self.doc.write_text('---\ndescription: fixture brief\n---\n> **Prior art:** none found (offline fixture)\n\n# worker\n')
        self.m = self.bucket / 'chief.fleet.json'
        self.call('control', 'init', self.m, '--target', '2')
        self.call('add', self.m, self.doc, '--lane', 'native', '--pending')

    def call(self, *args, ok=True, env=None):
        p = subprocess.run(['bash', str(WRITER), *map(str, args)], env=env or self.env,
                           capture_output=True, text=True, timeout=35)
        self.record(['bash', str(WRITER), *map(str, args)], p)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr)
        else:
            self.assertNotEqual(p.returncode, 0, p.stdout)
        return p

    def record(self, command, result):
        with (self.bucket / 'entrypoints.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(command=list(map(str, command)), rc=result.returncode,
                                         stdout=result.stdout, stderr=result.stderr)) + '\n')

    def save_evidence(self):
        dest = Path(os.environ['FLEET_RUNTIME_EVIDENCE']) / 'state' / self.id().split('.')[-1]
        dest.mkdir(parents=True, exist_ok=True)
        for path in [*self.bucket.glob('*.json'), *self.bucket.glob('*.md'), self.bucket / 'entrypoints.jsonl',
                     self.bucket / '.himmel/launch-refusals.jsonl']:
            if path.is_file():
                shutil.copy2(path, dest / path.name)
        if (self.bucket / 'slots').exists():
            shutil.copytree(self.bucket / 'slots', dest / 'slots', dirs_exist_ok=True)

    def rt(self, op, aid='one', ok=True, doc=None, manifest=None, extra=()):
        if op == 'commit':
            target = doc or self.doc
            env = dict(self.launch_env(), FLEET_LAUNCH_DOC=str(target), FLEET_LAUNCH_MANIFEST=str(manifest or self.m),
                       FLEET_LAUNCH_ATTEMPT=aid, CADENCE_USAGE_WORKER=Path(target).stem)
            self.entry('scripts/lib/usage-preflight.sh', env=env)
        return self.call('runtime', op, '--doc', doc or self.doc, '--manifest', manifest or self.m,
                         '--name', Path(doc or self.doc).stem, '--attempt-id', aid,
                         '--pid', os.getpid(), *extra, ok=ok)

    def active(self, generation=1):
        self.call('control', 'set', self.m, '--mode', 'active', '--expect-gen', generation)

    def pause(self, generation=2):
        self.call('control', 'set', self.m, '--mode', 'paused', '--expect-gen', generation)

    def test_pause_between_intent_and_commit(self):
        self.active()
        self.rt('begin')
        self.pause()
        self.rt('commit', ok=False)
        ack = json.loads(self.rt('ack').stdout)
        self.assertFalse(ack['quiescent'])
        self.assertEqual(ack['in_flight'][0]['attempt_id'], 'one')
        self.rt('outcome', extra=('--phase', 'refused'))
        final = json.loads(self.rt('ack').stdout)
        self.assertEqual(final['in_flight'], [])
        self.assertTrue(final['quiescent'])
        self.assertEqual(json.loads(self.m.read_text())['workers'], [])

    def test_commit_before_pause_and_unknown_survives_manifest_remove(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        self.pause()
        self.rt('outcome', extra=('--phase', 'unknown'))
        self.call('remove', self.m, self.doc)
        ack = json.loads(self.rt('ack').stdout)
        self.assertFalse(ack['quiescent'])
        self.assertEqual(ack['unknown'][0]['attempt_id'], 'one')
        self.rt('begin', aid='replacement', ok=False)

    def test_two_manifests_one_family_and_target(self):
        self.active()
        other = self.bucket / 'successor.fleet.json'
        other.write_text(self.m.read_text())
        self.rt('begin')
        self.rt('begin', aid='rival', manifest=other, ok=False)
        self.rt('commit')
        doc2 = self.bucket / 'TEST-2-N2-worker.md'
        doc2.write_text('# second\n')
        self.call('add', other, doc2, '--lane', 'native', '--pending')
        self.rt('begin', aid='two', doc=doc2, manifest=other)
        self.rt('commit', aid='two', doc=doc2, manifest=other)
        doc3 = self.bucket / 'TEST-3-N3-worker.md'
        doc3.write_text('# third\n')
        self.call('add', other, doc3, '--lane', 'native', '--pending')
        self.rt('begin', aid='three', doc=doc3, manifest=other)
        self.rt('commit', aid='three', doc=doc3, manifest=other, ok=False)

    def test_changed_generation_and_forged_held_do_not_authorize(self):
        self.active()
        self.rt('begin')
        self.call('control', 'set', self.m, '--mode', 'active', '--expect-gen', '2')
        self.rt('commit', ok=False)
        self.pause(generation=3)
        env = dict(self.env, FLEET_CAP_OK='1', FLEET_CONTROL_HELD='true', WORKER_SESSION_ROLE='chief')
        self.call('runtime', 'check', '--doc', self.doc, ok=False, env=env)

    def test_commit_without_real_resource_claim_and_direct_stamp_refuse(self):
        self.active()
        self.rt('begin')
        env = dict(self.env, FLEET_RESERVATION_HELD='true', FLEET_CONTROL_HELD='true')
        self.call('runtime', 'commit', '--doc', self.doc, '--manifest', self.m, '--name', self.doc.stem,
                  '--attempt-id', 'one', '--pid', os.getpid(), ok=False, env=env)
        slot = self.bucket / 'slots' / 'forged'
        slot.mkdir(parents=True)
        self.call('runtime', 'stamp', '--slot', slot, '--attempt-id', 'one', '--pid', os.getpid(), ok=False)
        self.assertFalse((slot / 'managed.json').exists())

    def test_missing_locator_is_derived_and_conflicting_locator_refuses(self):
        self.call('runtime', 'check', '--doc', self.doc, ok=False)
        self.active()
        self.call('runtime', 'check', '--doc', self.doc)
        bad = self.bucket / 'bad.fleet.json'
        data = json.loads(self.m.read_text())
        data['control']['family'] = 'other'
        bad.write_text(json.dumps(data))
        self.call('runtime', 'check', '--doc', self.doc, '--manifest', bad, ok=False)

    def test_unmanaged_compatibility(self):
        loose = self.bucket / 'loose'
        loose.mkdir()
        doc = loose / 'notes.md'
        doc.write_text('# personal\n')
        result = json.loads(self.call('runtime', 'check', '--doc', doc).stdout)
        self.assertFalse(result['managed'])

    def test_stale_receipt_cannot_remove_replacement(self):
        self.active()
        self.rt('begin')
        self.rt('outcome', extra=('--phase', 'refused'))
        self.call('add', self.m, self.doc, '--lane', 'native', '--pending')
        self.rt('begin', aid='two')
        self.rt('outcome', extra=('--phase', 'refused'))
        row = json.loads(self.m.read_text())['workers'][0]
        self.assertEqual(row['attempt']['attempt_id'], 'two')

    def test_unknown_legacy_registration_is_not_adopted(self):
        self.own_live_row(lock=11)
        self.active()
        p = self.rt('begin', ok=False)
        self.assertIn('unknown legacy family ownership', p.stderr)
        owners = json.loads(self.call('runtime', 'owners', '--manifest', self.m).stdout)
        self.assertEqual(len(owners), 1)
        ack = json.loads(self.call('control', 'ack', self.m).stdout)
        self.assertFalse(ack['quiescent'])
        self.assertEqual(ack['legacy_unknown'][0]['doc'], str(self.doc))

    def test_refusal_after_copied_preadd_leaves_no_sibling_owner(self):
        self.active()
        successor = self.bucket / 'successor.fleet.json'
        successor.write_text(self.m.read_text())
        self.rt('begin', manifest=successor)
        self.rt('outcome', manifest=successor, extra=('--phase', 'refused'))
        owners = json.loads(self.call('runtime', 'owners', '--manifest', self.m).stdout)
        self.assertEqual(owners, [])

    def test_concurrent_manual_and_controller_claim_only_one_family_owner(self):
        self.active()
        successor = self.bucket / 'successor.fleet.json'
        successor.write_text(self.m.read_text())
        commands = []
        for aid, manifest in [('manual', self.m), ('controller', successor)]:
            argv = ['bash', str(WRITER), 'runtime', 'begin', '--doc', str(self.doc), '--manifest', str(manifest),
                    '--name', self.doc.stem, '--attempt-id', aid, '--pid', str(os.getpid())]
            commands.append(subprocess.Popen(argv, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
        outcomes = [p.communicate(timeout=35) for p in commands]
        self.assertEqual(sorted(p.returncode for p in commands), [0, 10], str(outcomes))
        records = json.loads((self.bucket / 'fleet-control.json').read_text())['attempts']
        self.assertEqual(len(records), 1)
        self.assertEqual(next(iter(records.values()))['doc'], str(self.doc))

    def stub(self, name, body):
        path = self.bucket / name
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o755)
        return str(path)

    def launch_env(self):
        ps = self.stub('ps', 'exit 0')
        return dict(self.env, FLEET_LAUNCH_DOC=str(self.doc), FLEET_LAUNCH_MANIFEST=str(self.m),
                    CADENCE_USAGE_LAUNCH='1', CADENCE_USAGE_WORKER=self.doc.stem,
                    CADENCE_USAGE_CALLER_PID=str(os.getpid()), CADENCE_USAGE_LANE='native',
                    CADENCE_USAGE_SKIP_REFRESH='1', CADENCE_USAGE_CACHE=str(self.bucket / 'missing-cache'),
                    CADENCE_USAGE_LEDGER=str(self.bucket / 'cadence.jsonl'), FLEET_PS_CMD=ps,
                    FLEET_CAP_OK='1', HIMMEL_API_LANE='on')

    def anchorless_tree(self):
        """Symlinks to every entry of ENTRYPOINTS, except that scripts/, scripts/handover/, scripts/handover/chief-kit/ and scripts/lib/ are real
        directories and the seam guard, the preflight and the runtime are copies. The guard resolves its root from its own directory, so a launch
        run from this tree is not on a primary checkout, which is what a CI checkout is: there it refuses a Claude Code marker beside a seam,
        and the worker exports a marker. The runtime accepts a stamp only from the preflight beside it, so the two are copied together."""
        tree = self.bucket / 'tree'
        if tree.exists():
            return tree
        tree.mkdir()
        real = {Path('scripts'), Path('scripts/handover'), Path('scripts/handover/chief-kit'), Path('scripts/lib')}
        for entry in ENTRYPOINTS.glob('*'):
            if entry.name != 'scripts':
                (tree / entry.name).symlink_to(entry)
        for directory in sorted(real):
            (tree / directory).mkdir(parents=True, exist_ok=True)
            for entry in (ENTRYPOINTS / directory).iterdir():
                if directory / entry.name not in real:
                    (tree / directory / entry.name).symlink_to(entry)
        for name in ('chokepoint-seam-guard.sh', 'fleet_runtime.py', 'usage-preflight.sh'):
            copy = tree / 'scripts/lib' / name
            copy.unlink()
            shutil.copy2(ENTRYPOINTS / 'scripts/lib' / name, copy)
        return tree

    def entry(self, path, args=(), env=None, root=None):
        command = ['bash', str((root or self.anchorless_tree()) / path), *map(str, args)]
        result = subprocess.run(command, env=env or self.launch_env(), capture_output=True, text=True, timeout=20)
        self.record(command, result)
        return result

    def test_actual_preflight_native_and_api_pause_before_reservation(self):
        for lane in ('native', 'api'):
            env = dict(self.launch_env(), CADENCE_USAGE_LANE=lane)
            p = self.entry('scripts/lib/usage-preflight.sh', env=env)
            self.assertEqual(p.stdout.strip(), 'SKIPPED-FLEET', p.stderr)
            self.assertIn('fleet-paused', p.stderr)
            self.assertFalse((self.bucket / 'slots' / self.doc.stem).exists())

    def test_actual_worker_refuses_pause_even_with_stubbed_preflight(self):
        preflight = self.stub('preflight', 'echo PROCEED')
        target = self.stub('worker-target', 'touch "$HOME/worker-spawn"\nprintf "launched\\n" > "$HEADED_ARM_OUTCOME_FILE"')
        jira = self.bucket / 'jira.js'
        jira.write_text('for (const key of process.argv.slice(2).filter(x=>/^TEST-/.test(x))) console.log(process.argv.includes("bucket-check") ? "IN " + key + " current=v1.1.3 via=mirror" : "NOT-CORE " + key);')
        env = dict(self.launch_env(), HEADED_ARM_WORKER_PREFLIGHT=preflight, HEADED_ARM_WORKER_TARGET=target,
                   BRIEF_LINT_JIRA_CLI=str(jira), WORKER_SESSION_REPO=str(ROOT))
        p = self.entry('scripts/handover/chief-kit/headed-arm-worker.sh',
                       ('--fleet', self.m, '--no-profile', self.doc.stem, self.doc,
                        self.bucket / 'sig', '1', self.bucket / 'launch.log', 'claude-sonnet-5-5'), env)
        self.assertEqual(p.returncode, 10, p.stderr)
        self.assertIn('fleet-paused', p.stderr)
        self.assertFalse((self.bucket / 'worker-spawn').exists())
        self.assertEqual(json.loads(self.m.read_text())['workers'], [], p.stderr)

    def headed_env(self):
        record = self.bucket / 'spawned'
        proc = self.bucket / 'proc/9001'
        proc.mkdir(parents=True, exist_ok=True)
        (proc / 'comm').write_text('claude\n')
        (proc / 'cmdline').write_bytes(b'claude\0-n\0' + self.doc.stem.encode() + b'\0')
        konsole = self.stub('konsole', 'touch "$HOME/spawned"\nsleep 3')
        pgrep = self.stub('pgrep', '[ -e "$HOME/spawned" ] && { echo 9001; exit 0; }\nexit 1')
        return dict(self.launch_env(), KONSOLE_CMD=konsole, PGREP_CMD=pgrep,
                    HEADED_ARM_PROC=str(proc.parent), HEADED_ARM_REPO=str(ROOT),
                    HEADED_ARM_LOCK_DIR=str(self.bucket / 'locks'), KONSOLE_HOLD_LAUNCH='0')

    def test_actual_headed_arm_pause_and_unmanaged_control(self):
        env = self.headed_env()
        p = self.entry('scripts/handover/headed-arm.sh',
                       (self.doc.stem, self.doc, self.bucket / 'sig', '1', self.bucket / 'log'), env)
        self.assertEqual(p.returncode, 10, p.stderr)
        self.assertFalse((self.bucket / 'spawned').exists())

    def test_actual_unmanaged_headed_launch_is_compatible(self):
        loose = self.bucket / 'loose'
        loose.mkdir()
        doc = loose / 'notes.md'
        doc.write_text('# unmanaged\n')
        env = self.headed_env()
        env.pop('FLEET_LAUNCH_MANIFEST', None)
        env.pop('FLEET_LAUNCH_DOC', None)
        p = self.entry('scripts/handover/headed-arm.sh',
                       (self.doc.stem, doc, self.bucket / 'sig', '1', self.bucket / 'log'), env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue((self.bucket / 'spawned').exists())

    def test_actual_headed_arm_active_claim_commit_spawn_receipt(self):
        self.active()
        env = self.headed_env()
        p = self.entry('scripts/handover/headed-arm.sh',
                       (self.doc.stem, self.doc, self.bucket / 'sig', '1', self.bucket / 'log'), env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue((self.bucket / 'spawned').exists())
        attempts = json.loads((self.bucket / 'fleet-control.json').read_text())['attempts']
        self.assertEqual([a['phase'] for a in attempts.values()], ['launched'])
        self.assertTrue(next(iter(attempts.values()))['owner']['start'])

    def test_actual_api_pause_before_configuration_or_fallback(self):
        binary = self.stub('paid-call', 'touch "$HOME/paid"\nexit 0')
        env = dict(self.launch_env(), HIMMEL_API_CLAUDE_BIN=binary, HIMMEL_API_FALLBACK='on')
        p = self.entry('scripts/api-lane/claude-api.sh', ('-p', 'test'), env)
        self.assertEqual(p.returncode, 10, p.stderr)
        self.assertFalse((self.bucket / 'paid').exists())
        self.assertEqual(json.loads(self.m.read_text())['workers'], [])

    def test_actual_arm_resume_pause_precedes_scheduler(self):
        for name in ('at', 'crontab'):
            self.stub(name, 'touch "$HOME/scheduler-called"\nexit 0')
        when = time.strftime('%H:%M', time.localtime(time.time() + 600))
        env = dict(self.launch_env(), PATH=str(self.bucket) + ':' + os.environ['PATH'],
                   HANDOVER_DIR=str(self.bucket), ARM_RESUME_DOTENV_ROOT=str(self.bucket))
        p = self.entry('scripts/handover/arm-resume.sh',
                       ('--time', when, '--handover', self.doc, '--cwd', ROOT), env)
        self.assertEqual(p.returncode, 22, p.stdout + p.stderr)
        self.assertIn('fleet-paused', p.stderr)
        self.assertFalse((self.bucket / 'scheduler-called').exists())

    def test_managed_target_counts_other_api_reservations(self):
        self.active()
        slots = self.bucket / 'slots'
        for number in range(2):
            slot = slots / ('foreign-api-' + str(number))
            slot.mkdir(parents=True)
            (slot / 'pid').write_text(str(os.getpid()))
            (slot / 'expires').write_text(str(int(time.time()) + 600))
            (slot / 'lane').write_text('api')
        p = self.entry('scripts/lib/usage-preflight.sh', env=self.launch_env())
        self.assertEqual(p.stdout.strip(), 'SKIPPED-FLEET', p.stderr)

    def test_actual_worker_active_launch_claims_and_settles(self):
        self.active()
        env = self.headed_env()
        jira = self.bucket / 'jira.js'
        jira.write_text('for (const key of process.argv.slice(2).filter(x=>/^TEST-/.test(x))) console.log(process.argv.includes("bucket-check") ? "IN " + key + " current=v1.1.3 via=mirror" : "NOT-CORE " + key);')
        env.update(BRIEF_LINT_JIRA_CLI=str(jira), WORKER_SESSION_REPO=str(ROOT),
                   HEADED_ARM_WORKER_PREFLIGHT=self.stub('preflight', 'echo PROCEED'))
        p = self.entry('scripts/handover/chief-kit/headed-arm-worker.sh',
                       ('--fleet', self.m, '--no-profile', self.doc.stem, self.doc,
                        self.bucket / 'sig', '1', self.bucket / 'log', 'claude-sonnet-5-5'), env)
        log = self.bucket / 'log'
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout + (log.read_text() if log.exists() else ''))
        self.assertTrue((self.bucket / 'spawned').exists())
        self.assertEqual(json.loads(self.m.read_text())['workers'][0]['attempt']['phase'], 'launched')

    def test_finish_leaves_a_launched_attempt_launched_and_frees_nothing(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        self.rt('outcome', extra=('--phase', 'launched'))
        anchor = self.bucket / 'fleet-control.json'
        history = self.bucket / '.himmel/launch-refusals.jsonl'
        before = (json.loads(anchor.read_text()), json.loads(self.m.read_text()), history.read_text())
        self.assertEqual(json.loads(self.rt('finish').stdout)['phase'], 'launched')
        self.assertEqual((json.loads(anchor.read_text()), json.loads(self.m.read_text()), history.read_text()), before)
        self.assertEqual([a['phase'] for a in json.loads(anchor.read_text())['attempts'].values()], ['launched'])
        self.assertEqual(len(list((self.bucket / 'slots').glob('*/managed.json'))), 1)

    def test_finish_makes_a_committed_attempt_unknown_and_keeps_its_slot(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        self.assertEqual(json.loads(self.rt('finish').stdout)['phase'], 'unknown')
        anchor = json.loads((self.bucket / 'fleet-control.json').read_text())
        self.assertEqual([a['phase'] for a in anchor['attempts'].values()], ['unknown'])
        self.assertEqual(json.loads(self.m.read_text())['workers'][0]['attempt']['phase'], 'unknown')
        self.assertEqual(len(list((self.bucket / 'slots').glob('*/managed.json'))), 1)

    def test_launcher_death_is_unknown_even_with_reused_pid(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        anchor = self.bucket / 'fleet-control.json'
        data = json.loads(anchor.read_text())
        data['attempts']['one']['owner']['start'] = '0'
        anchor.write_text(json.dumps(data))
        ack = json.loads(self.rt('ack').stdout)
        self.assertEqual(ack['unknown'][0]['attempt_id'], 'one')
        self.assertFalse(ack['quiescent'])
        self.rt('begin', aid='two', ok=False)

    def test_long_running_commit_is_not_reclaimed_for_inactivity(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        ack = json.loads(self.rt('ack').stdout)
        self.assertEqual(ack['in_flight'][0]['phase'], 'committed')
        self.rt('begin', aid='two', ok=False)

    def test_unknown_reconciles_only_exact_attempt_session_evidence(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        self.rt('outcome', extra=('--phase', 'unknown'))
        code = 'import ctypes,time; ctypes.CDLL(None).prctl(15,b"claude",0,0,0); time.sleep(20)'
        env = dict(self.env, WORKER_SESSION_DOC=str(self.doc), WORKER_SESSION_ATTEMPT_ID='foreign')
        p = subprocess.Popen(['claude', '-c', code, '-n', self.doc.stem], executable=sys.executable, env=env)
        try:
            time.sleep(.1)
            self.assertEqual(len(json.loads(self.rt('ack').stdout)['unknown']), 1)
        finally:
            p.terminate()
            p.wait(timeout=5)
        env['WORKER_SESSION_ATTEMPT_ID'] = 'one'
        p = subprocess.Popen(['claude', '-c', code, '-n', self.doc.stem], executable=sys.executable, env=env)
        try:
            time.sleep(.1)
            ack = json.loads(self.rt('ack').stdout)
            self.assertEqual(ack['unknown'], [])
            self.assertEqual(ack['launched'][0]['session']['pid'], p.pid)
            self.assertTrue(ack['launched'][0]['session']['start'])
            self.assertFalse(ack['quiescent'])
        finally:
            p.terminate()
            p.wait(timeout=5)

    def wait_file(self, path, process):
        end = time.monotonic() + 8
        while time.monotonic() < end:
            if path.exists():
                return
            if process.poll() is not None:
                self.fail('launcher exited before barrier: ' + process.communicate()[1])
            time.sleep(.02)
        self.fail('launcher barrier timed out')

    def start_headed(self, env):
        p = subprocess.Popen(['bash', str(self.anchorless_tree() / 'scripts/handover/headed-arm.sh'), self.doc.stem,
                              str(self.doc), str(self.bucket / 'sig'), '1', str(self.bucket / 'log')],
                             env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        return p

    def test_real_reservation_pause_race_releases_only_owned_slot(self):
        self.active()
        hook = self.stub('admission-hook', '''[ "$1" = admission-complete ] || exit 0
touch "$HOME/reserved"
for i in {1..400}; do [ -e "$HOME/continue" ] && exit 0; sleep .02; done
exit 1''')
        env = dict(self.headed_env(), FLEET_ADMIT_TEST_HOOK=hook)
        p = self.start_headed(env)
        self.wait_file(self.bucket / 'reserved', p)
        slots = self.bucket / 'slots'
        own = slots / self.doc.stem
        self.assertTrue((own / 'managed.json').is_file())
        foreign = slots / 'other-attempt'
        foreign.mkdir()
        (foreign / 'managed.json').write_text(json.dumps({'attempt_id': 'foreign', 'owner': {'pid': p.pid}}))
        self.pause()
        (self.bucket / 'continue').touch()
        out, err = p.communicate(timeout=12)
        self.assertEqual(p.returncode, 10, out + err)
        self.assertFalse((self.bucket / 'spawned').exists())
        self.assertFalse(own.exists())
        self.assertTrue(foreign.exists())
        self.assertEqual(json.loads(self.m.read_text())['workers'], [])

    def test_real_committed_spawn_is_reported_by_later_pause(self):
        self.active()
        env = self.headed_env()
        env['KONSOLE_CMD'] = self.stub('konsole-barrier', '''touch "$HOME/spawned"
for i in {1..400}; do [ -e "$HOME/continue" ] && break; sleep .02; done
sleep 3''')
        p = self.start_headed(env)
        self.wait_file(self.bucket / 'spawned', p)
        self.pause()
        ack = json.loads(self.rt('ack').stdout)
        self.assertFalse(ack['quiescent'])
        self.assertEqual(len(ack['in_flight']), 1)
        self.assertEqual(ack['in_flight'][0]['phase'], 'committed')
        (self.bucket / 'continue').touch()
        out, err = p.communicate(timeout=12)
        self.assertEqual(p.returncode, 0, out + err)

    def test_actual_scheduled_gate_rechecks_pause_after_restart(self):
        helper = ROOT / 'scripts/lib/fleet_runtime.py'
        env = self.launch_env()
        command = ['python3', '-I', str(helper), 'run', '--doc', str(self.doc), '--name', self.doc.stem,
                   '--', 'bash', '-c', 'touch "$HOME/scheduled-spawn"']
        p = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(p.returncode, 10, p.stderr)
        self.assertFalse((self.bucket / 'scheduled-spawn').exists())
        # A new invocation reads the persisted generation, never an old active flag.
        self.active()
        self.pause()
        p = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(p.returncode, 10, p.stderr)
        self.assertFalse((self.bucket / 'scheduled-spawn').exists())

    def test_scheduled_reservation_pause_race_releases_its_claim(self):
        self.active()
        hook = self.stub('schedule-hook', '''[ "$1" = admission-complete ] || exit 0
touch "$HOME/reserved"
for i in {1..400}; do [ -e "$HOME/continue" ] && exit 0; sleep .02; done
exit 1''')
        env = dict(self.launch_env(), FLEET_ADMIT_TEST_HOOK=hook)
        command = ['python3', '-I', str(self.anchorless_tree() / 'scripts/lib/fleet_runtime.py'), 'run', '--doc', str(self.doc),
                   '--name', self.doc.stem, '--', 'bash', '-c', 'touch "$HOME/scheduled-spawn"']
        p = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.wait_file(self.bucket / 'reserved', p)
            self.pause()
            (self.bucket / 'continue').touch()
            out, err = p.communicate(timeout=12)
            self.assertEqual(p.returncode, 10, out + err)
            self.assertFalse((self.bucket / 'scheduled-spawn').exists())
            self.assertFalse((self.bucket / 'slots' / self.doc.stem).exists())
        finally:
            if p.poll() is None:
                p.terminate()
                p.wait(timeout=5)
    def test_dispatcher_whole_terminal_names_and_category(self):
        mirror = self.bucket / 'mirror'
        mirror.mkdir()
        statuses = [('To Do', 'To Do'), ('Resolved', 'To Do'), ("Won't Fix", 'To Do'),
                    ('Won’t Do', 'To Do'), ('In Public', 'To Do'), ('Custom shipped', 'Done'),
                    ('Resolved later', 'To Do')]
        for number, (status, category) in enumerate(statuses, 100):
            key = 'CASE-' + str(number)
            (mirror / (key + '.md')).write_text('---\nkey: "' + key + '"\ntype: "Task"\nstatus: "' + status +
                '"\nstatusCategory: "' + category + '"\npriority: "High"\nlabels: []\nfixVersions: ["v1.0.1"]\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n# ' + key + ': test\n## Description\nEdit scripts/runtime-fixture.sh.\n\nDoD\n- row passes\n\nProof\n- offline fixture\n')
        template = (mirror / 'CASE-100.md').read_text()
        for number in range(101, 107):
            key = 'CASE-' + str(number + 100)
            (mirror / (key + '.md')).write_text(template.replace('CASE-100', key).replace('blocked_by: []', 'blocked_by: ["blocked by CASE-' + str(number) + '"]'))
        gh = self.stub('gh', 'echo "[]"')
        jira = self.bucket / 'notcore.js'
        jira.write_text('for (const k of process.argv.slice(process.argv.indexOf("--key")+1)) console.log("NOT-CORE " + k);')
        env = dict(self.env, NEXT_DISPATCH_MIRROR=str(mirror), NEXT_DISPATCH_GH_CMD=gh,
                   NEXT_DISPATCH_JIRA_CLI=str(jira),
                   HIMMEL_QUOTA_DIR=str(self.bucket / 'quota'))
        p = self.entry('scripts/handover/chief-kit/next-dispatchable.sh', ('--no-classify', '--top', '20'), env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('CASE-100', p.stdout)
        for number in range(101, 106):
            self.assertNotIn('CASE-' + str(number), p.stdout)
            self.assertIn('CASE-' + str(number + 100), p.stdout)
            self.assertIn('\tCASE-' + str(number + 100) + '\t', p.stdout)
        self.assertNotIn('CASE-206', p.stdout)
        main = self.bucket / 'HIMMEL-nextleg-2026-11-16A-chief.fleet.json'
        data = json.loads(self.m.read_text())
        data['workers'] = []
        main.write_text(json.dumps(data))
        live_doc = self.bucket / 'CASE-100-N1-owner.md'
        live_doc.write_text('# live sibling owner\n- 10:00 LIVE running\n')
        self.real_worker('sibling', live_doc)
        unknown_doc = self.bucket / 'CASE-201-N2-missing.md'
        sibling = self.bucket / 'HIMMEL-nextleg-2026-11-16B-chief.fleet.json'
        for reference in (None, {'family':'foreign'}, 'malformed'):
            data = {'schema':1, 'workers':[{'doc':str(live_doc), 'label':'N1'},
                                          {'doc':str(unknown_doc), 'label':'N2'}]}
            if reference is not None:
                data['control'] = reference
            sibling.write_text(json.dumps(data))
            p = self.entry('scripts/handover/chief-kit/next-dispatchable.sh',
                           ('--no-classify', '--top', '20', '--workers-from', main), env)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertNotIn('CASE-100', p.stdout)
            self.assertNotIn('\tCASE-201\t', p.stdout)
            self.assertIn('unverified', p.stderr)

    def real_census_env(self):
        env = self.launch_env()
        env.pop('FLEET_PS_CMD', None)
        env.pop('FLEET_PROC', None)
        (self.bucket / 'census-bin').mkdir(exist_ok=True)
        shim = self.stub('census-bin/ps', '"%s" "$@" | awk \'NR==FNR{skip[$1]=1;next} !($1 in skip)\' "%s" -' % (self.real_ps, self.preexisting_pids))
        env['PATH'] = os.path.dirname(shim) + os.pathsep + env['PATH']
        return env

    def real_worker(self, aid='one', doc=None):
        doc = doc or self.doc
        ready = self.bucket / ('ready-' + aid)
        code = ('import ctypes,os,time; from pathlib import Path; '
                'ctypes.CDLL(None).prctl(15,b"claude",0,0,0); '
                'Path(os.environ["READY"]).touch(); time.sleep(60)')
        env = dict(self.env, WORKER_SESSION_DOC=str(doc), WORKER_SESSION_ATTEMPT_ID=aid, READY=str(ready))
        p = subprocess.Popen(['claude', '-c', code, '-n', doc.stem], executable=sys.executable,
                             env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: p.poll() is None and (p.terminate(), p.wait(timeout=5)))
        self.wait_file(ready, p)
        return p

    def test_completed_launch_releases_target_one_with_real_census(self):
        self.call('control', 'set', self.m, '--mode', 'active', '--target', '1', '--expect-gen', '1')
        env = self.real_census_env()
        # Real /proc and ps drive launch confirmation and resource admission.
        # Only the terminal/provider binaries are offline fixtures.
        launcher = self.bucket / 'offline-claude'
        launcher.write_text('#!' + sys.executable + '\nimport ctypes,json,os,time\nfrom pathlib import Path\n'
            'ctypes.CDLL(None).prctl(15,b"claude",0,0,0)\n'
            'b=Path(os.environ["HOME"])\n'
            '(b/"worker-env.json").write_text(json.dumps({k:v for k,v in os.environ.items() if k.startswith("FLEET_LAUNCH_") or k in ("WORKER_SESSION_DOC","WORKER_SESSION_ATTEMPT_ID")}))\n'
            '(b/"worker-pid").write_text(str(os.getpid()))\n'
            'while not (b/"end-worker").exists(): time.sleep(.02)\n'
            'with Path(os.environ["WORKER_SESSION_DOC"]).open("a") as f: f.write("- 12:00 WRAPPED ended\\n")\n')
        launcher.chmod(0o755)
        konsole = self.stub('real-konsole', 'while [ "$1" != -e ]; do shift; done\nshift\nexec "$@"')
        env.update(KONSOLE_CMD=konsole, HEADED_ARM_LAUNCHER=str(launcher), HEADED_ARM_REPO=str(ROOT),
                   HEADED_ARM_LOCK_DIR=str(self.bucket / 'locks'), KONSOLE_HOLD_LAUNCH='0')
        for number in range(3):
            doc = self.bucket / ('HIMMEL-' + str(900 + number) + '-N1-worker.md')
            doc.write_text('# offline worker\n')
            self.call('add', self.m, doc, '--lane', 'native', '--pending')
            p = self.entry('scripts/handover/headed-arm.sh',
                           (doc.stem, doc, self.bucket / 'sig', '1', self.bucket / 'log'), env)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            worker_pid = int((self.bucket / 'worker-pid').read_text())
            self.addCleanup(lambda pid=worker_pid: subprocess.run(['kill', str(pid)], capture_output=True))
            record = next(iter(json.loads((self.bucket / 'fleet-control.json').read_text())['attempts'].values()))
            self.assertEqual(record['phase'], 'launched')
            doc.write_text(doc.read_text() + '- 11:59 WRAPPED still alive\n')
            self.call('control', 'ack', self.m)
            self.assertTrue((self.bucket / 'slots' / doc.stem / 'managed.json').exists())
            self.assertIn(record['attempt_id'], json.loads((self.bucket / 'fleet-control.json').read_text())['attempts'])
            (self.bucket / 'end-worker').touch()
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                stat = Path('/proc', str(worker_pid), 'stat')
                if not stat.exists() or stat.read_text().rsplit(')', 1)[1].split()[0] == 'Z':
                    break
                time.sleep(.02)
            else:
                self.fail('offline worker did not end')
            if number == 0:
                self.call('control', 'ack', self.m)
                self.assertFalse((self.bucket / 'slots' / doc.stem).exists())
            # Later iterations depend on automatic cleanup before admission.
            (self.bucket / 'end-worker').unlink()
        self.call('control', 'ack', self.m)
        self.assertEqual(json.loads((self.bucket / 'fleet-control.json').read_text())['attempts'], {})
        child_env = json.loads((self.bucket / 'worker-env.json').read_text())
        self.assertNotIn('FLEET_LAUNCH_ATTEMPT', child_env)
        self.assertTrue(child_env['WORKER_SESSION_ATTEMPT_ID'])

    def test_proven_precommit_death_releases_but_handoff_and_commit_stay_unknown(self):
        self.active()
        for boundary in ('pending', 'handoff', 'committed'):
            code = ('import os,subprocess,sys,time\nfrom pathlib import Path\n'
                    'w,d,m,a=sys.argv[1:]\n'
                    'base=["bash",w,"runtime"]\n'
                    'opts=["--doc",d,"--manifest",m,"--name",Path(d).stem,"--attempt-id",a,"--pid",str(os.getpid())]\n'
                    'subprocess.run(base+["begin"]+opts,check=True)\n'
                    'e=dict(os.environ,FLEET_LAUNCH_DOC=d,FLEET_LAUNCH_MANIFEST=m,FLEET_LAUNCH_ATTEMPT=a,CADENCE_USAGE_WORKER=Path(d).stem,CADENCE_USAGE_CALLER_PID=str(os.getpid()))\n'
                    'subprocess.run(["bash",str(Path(w).parents[2]/"lib/usage-preflight.sh")],env=e,check=True)\n'
                    'if a!="pending": subprocess.run(base+[{"handoff":"handoff","committed":"commit"}[a]]+opts,check=True)\n'
                    'Path(os.environ["HOME"],"kill-"+a).touch()\n'
                    'time.sleep(60)\n')
            doc = self.bucket / ('HIMMEL-' + str(910 + len(boundary)) + '-' + boundary + '.md')
            doc.write_text('# worker\n')
            self.call('add', self.m, doc, '--lane', 'native', '--pending')
            p = subprocess.Popen([sys.executable, '-c', code, str(self.anchorless_tree() / 'scripts/handover/chief-kit/fleet-manifest.sh'),
                                  str(doc), str(self.m), boundary],
                                 env=self.real_census_env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.addCleanup(lambda p=p: p.poll() is None and (p.kill(), p.wait(timeout=5)))
            self.wait_file(self.bucket / ('kill-' + boundary), p)
            p.kill()
            p.communicate(timeout=5)
            if boundary == 'pending':
                ack_process = subprocess.Popen(['bash', str(WRITER), 'control', 'ack', str(self.m)],
                    env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                commands = []
                for aid in ('retry', 'rival'):
                    commands.append(subprocess.Popen(['bash', str(WRITER), 'runtime', 'begin', '--doc', str(doc),
                        '--manifest', str(self.m), '--name', doc.stem, '--attempt-id', aid, '--pid', str(os.getpid())],
                        env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
                outcomes = [p.communicate(timeout=10) for p in commands]
                self.assertEqual(sorted(p.returncode for p in commands), [0, 10], str(outcomes))
                ack_process.communicate(timeout=10)
                self.assertEqual(ack_process.returncode, 0)
                winner = ('retry', 'rival')[next(i for i, p in enumerate(commands) if p.returncode == 0)]
            ack = json.loads(self.call('control', 'ack', self.m).stdout)
            if boundary == 'pending':
                self.assertEqual(ack['unknown'], [])
                self.assertFalse((self.bucket / 'slots' / doc.stem).exists())
                history = [json.loads(line) for line in (self.bucket / '.himmel/launch-refusals.jsonl').read_text().splitlines()]
                self.assertEqual([r for r in history if r['attempt_id'] == boundary][-1]['cause'], 'launcher-lost-precommit')
                self.rt('outcome', aid=winner, doc=doc, extra=('--phase', 'refused'))
            else:
                self.assertIn(boundary, [r['attempt_id'] for r in ack['unknown']])
                self.assertTrue((self.bucket / 'slots' / doc.stem).exists())

    def test_chief_and_notes_in_bucket_are_administrative_but_worker_intent_refuses(self):
        env = self.real_census_env()
        for name in ('chief-handover.md', 'notes.md'):
            doc = self.bucket / name
            doc.write_text('# administrative document\n')
            result = json.loads(self.call('runtime', 'check', '--doc', doc).stdout)
            self.assertFalse(result['managed'])
            e = dict(env, FLEET_LAUNCH_DOC=str(doc), CADENCE_USAGE_WORKER=doc.stem)
            e.pop('FLEET_LAUNCH_MANIFEST')
            p = self.entry('scripts/lib/usage-preflight.sh', env=e)
            self.assertNotEqual(p.stdout.strip(), 'SKIPPED-FLEET', p.stderr)
            self.assertFalse((self.bucket / 'slots' / doc.stem / 'managed.json').exists())
        generated = self.bucket / 'unregistered.md'
        generated.write_text('# worker\n> **Leg kind:** build\n')
        self.call('runtime', 'check', '--doc', generated, ok=False)
        self.call('runtime', 'check', '--doc', generated, '--manifest', self.m, ok=False)
        self.call('runtime', 'check', '--doc', self.doc, ok=False)
        self.call('runtime', 'check', ok=False, env=dict(self.env, HIMMEL_CONSOLE_LEG='1'))
        loose = self.bucket / 'unregistered-loose'
        loose.mkdir()
        worker = loose / 'worker.md'
        worker.write_text('> **Proof leg:** HIMMEL-992\n')
        self.call('runtime', 'check', '--doc', worker, ok=False)
        self.active()
        self.call('runtime', 'resolve', '--doc', generated, ok=False)
        self.call('runtime', 'resolve', '--doc', generated, '--manifest', self.m)
        self.rt('begin', aid='explicit', doc=generated)
        self.rt('outcome', aid='explicit', doc=generated, extra=('--phase', 'refused'))

    def test_admit_predicts_check_and_writes_nothing(self):
        generated = self.bucket / 'unregistered.md'
        generated.write_text('# worker\n> **Leg kind:** build\n')
        files = lambda: {p.name: p.read_bytes() for p in self.bucket.glob('*.json')}
        before = files()
        p = self.call('runtime', 'admit', '--doc', generated, ok=False, env=dict(self.env, FLEET_LAUNCH_WORKER_INTENT='1'))
        self.assertIn('managed worker has no manifest reference', p.stderr)
        p = self.call('runtime', 'admit', '--doc', self.doc, '--manifest', self.m, ok=False)
        self.assertIn('fleet-paused', p.stderr)
        self.assertEqual(files(), before)
        self.active()
        before = files()
        self.assertTrue(json.loads(self.call('runtime', 'admit', '--doc', self.doc, '--manifest', self.m).stdout)['managed'])
        self.assertEqual(files(), before)
        self.rt('check')

    def test_admit_predicts_begin_ownership_refusals_and_writes_nothing(self):
        self.active()
        self.rt('begin', aid='first')
        files = lambda: {p.name: p.read_bytes() for p in self.bucket.glob('*.json')}
        before = files()
        p = self.call('runtime', 'admit', '--doc', self.doc, '--manifest', self.m, '--name', self.doc.stem, ok=False)
        self.assertIn('family already owns worker or ticket', p.stderr)
        self.assertEqual(files(), before)
        self.rt('begin', aid='second', ok=False)
        self.rt('outcome', aid='first', extra=('--phase', 'refused'))
        self.call('runtime', 'admit', '--doc', self.doc, '--manifest', self.m, '--name', self.doc.stem)
        sibling = self.bucket / 'earlier-chief.fleet.json'
        sibling.write_text(json.dumps({'control': json.loads(self.m.read_text())['control'], 'workers': [{'doc': str(self.doc.resolve())}]}))
        before = files()
        p = self.call('runtime', 'admit', '--doc', self.doc, '--manifest', self.m, '--name', self.doc.stem, ok=False)
        self.assertIn('unknown legacy family ownership', p.stderr)
        self.assertEqual(files(), before)
        p = self.rt('begin', aid='third', ok=False)
        self.assertIn('unknown legacy family ownership', p.stderr)

    def own_live_row(self, lock=0):
        data = json.loads(self.m.read_text())
        data['workers'][0].pop('registration')
        self.m.write_text(json.dumps(data))
        self.env = dict(self.env, TICKET_STATUS_QUEUE_LOCK=self.stub('queue-lock-%d' % lock, 'exit %d' % lock))

    def test_begin_admits_a_doc_only_its_own_manifest_lists_as_live_while_no_session_ran(self):
        self.own_live_row()
        self.active()
        self.rt('begin', aid='own')
        row = json.loads(self.m.read_text())['workers'][0]
        self.assertEqual((row['registration'], row['attempt']['attempt_id']), ('pending', 'own'))

    def test_begin_still_refuses_its_own_manifest_row_while_the_worker_holds_its_lock(self):
        self.own_live_row(lock=11)
        self.doc.write_text(self.doc.read_text() + '\n## Results\n\n- 10:00 LIVE — started\n')
        self.active()
        p = self.rt('begin', aid='own', ok=False)
        self.assertIn('unknown legacy family ownership', p.stderr)

    def test_begin_still_refuses_its_own_manifest_row_while_a_claude_session_is_on_the_doc(self):
        self.own_live_row()
        self.active()
        code = 'import ctypes,time; ctypes.CDLL(None).prctl(15,b"claude",0,0,0); time.sleep(30)'
        live = subprocess.Popen(['claude', '-c', code], executable=sys.executable, env=dict(self.env, WORKER_SESSION_DOC=str(self.doc)))
        time.sleep(.2)
        try:
            p = self.rt('begin', aid='own', ok=False)
        finally:
            live.terminate()
            live.wait(timeout=5)
        self.assertIn('unknown legacy family ownership', p.stderr)

    def test_a_doc_not_yet_written_is_unlaunched(self):
        p = subprocess.run(['python3', '-I', str(ROOT / 'scripts/lib/fleet_runtime.py'), 'unlaunched', '--doc', str(self.bucket / 'missing.md')],
                           env=self.env, capture_output=True, text=True, timeout=35)
        self.assertEqual(p.stdout.strip(), 'true', p.stderr)

    def test_a_sibling_manifest_row_refuses_and_names_its_file_and_row(self):
        self.active()
        sibling = self.bucket / 'earlier-chief.fleet.json'
        sibling.write_text(json.dumps({'schema': 1, 'control': json.loads(self.m.read_text())['control'],
                                       'workers': [{'doc': str(self.doc.resolve()), 'label': 'N1', 'lane': 'native'}]}))
        p = self.rt('begin', aid='sib', ok=False)
        self.assertIn('unknown legacy family ownership: %s row %s' % (sibling, self.doc.resolve()), p.stderr)

    def test_a_sibling_manifest_refusal_offers_the_remove_command(self):
        self.active()
        sibling = self.bucket / 'earlier-chief.fleet.json'
        sibling.write_text(json.dumps({'schema': 1, 'control': json.loads(self.m.read_text())['control'],
                                       'workers': [{'doc': str(self.doc.resolve()), 'label': 'N1', 'lane': 'native'}]}))
        p = self.rt('begin', aid='sib2', ok=False)
        remove = 'bash %s remove %s %s' % (shlex.quote(str(ROOT / 'scripts/handover/chief-kit/fleet-manifest.sh')),
                                           shlex.quote(str(sibling)), shlex.quote(str(self.doc.resolve())))
        self.assertIn(remove, p.stderr)

    def test_the_remove_command_quotes_a_manifest_path_with_a_space(self):
        self.active()
        sibling = self.bucket / 'earlier chief.fleet.json'
        sibling.write_text(json.dumps({'schema': 1, 'control': json.loads(self.m.read_text())['control'],
                                       'workers': [{'doc': str(self.doc.resolve()), 'label': 'N1', 'lane': 'native'}]}))
        p = self.rt('begin', aid='sib3', ok=False)
        self.assertIn(' remove %s ' % shlex.quote(str(sibling)), p.stderr)

    def live_worker(self):
        self.active()
        self.rt('begin', aid='first')
        self.rt('commit', aid='first')

    def api_call(self, join, doc=None, env=None):
        script = ('. "$1/scripts/lib/fleet-launch.sh"; fleet_launch_prepare "$2" api-managed "$3" "" "" "$4" || exit $?; '
                  'echo "managed=$FLEET_LAUNCH_MANAGED"; echo "child_attempt=$(printenv FLEET_LAUNCH_ATTEMPT)"; '
                  'fleet_launch_finish; fleet_launch_outcome complete; fleet_launch_release')
        command = ['bash', '-c', script, 'api-call', str(ENTRYPOINTS), str(doc or self.doc), str(self.m), join]
        result = subprocess.run(command, env=env or self.env, capture_output=True, text=True, timeout=35)
        self.record(command, result)
        return result

    def attempts(self):
        return json.loads((self.bucket / 'fleet-control.json').read_text()).get('attempts', {})

    def test_api_call_inside_live_worker_joins_its_own_attempt(self):
        self.live_worker()
        p = self.api_call('first', env=dict(self.env, FLEET_LAUNCH_ATTEMPT='first'))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('managed=false', p.stdout)
        self.assertIn('child_attempt=\n', p.stdout)
        self.assertEqual(list(self.attempts()), ['first'])
        files = lambda: {p.name: p.read_bytes() for p in self.bucket.glob('*.json')}
        before = files()
        p = self.call('runtime', 'admit', '--doc', self.doc, '--manifest', self.m, '--name', 'api-managed', '--join-attempt', 'first')
        self.assertEqual(json.loads(p.stdout)['joined'], 'first')
        self.assertEqual(files(), before)

    def test_joined_api_call_exit_leaves_the_worker_attempt_live(self):
        self.live_worker()
        before = self.attempts()['first']
        p = self.api_call('first')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.attempts()['first'], before)
        self.assertEqual(before['phase'], 'committed')
        self.assertTrue((Path(before['reservation']['path']) / 'managed.json').is_file())
        outcomes = [json.loads(line).get('outcome') for line in (self.bucket / '.himmel/launch-refusals.jsonl').read_text().splitlines()]
        self.assertNotIn('complete', outcomes)
        self.assertNotIn('refused', outcomes)

    def test_api_call_naming_another_docs_attempt_or_outside_its_tree_is_refused(self):
        self.live_worker()
        doc2 = self.bucket / 'TEST-2-N2-worker.md'
        doc2.write_text('# second\n')
        self.call('add', self.m, doc2, '--lane', 'native', '--pending')
        self.rt('begin', aid='two', doc=doc2)
        self.rt('commit', aid='two', doc=doc2)
        p = self.api_call('first', doc=doc2)
        self.assertEqual(p.returncode, 10, p.stdout)
        self.assertIn('family already owns worker or ticket', p.stderr)
        stranger = subprocess.Popen(['sleep', '30'])
        self.addCleanup(stranger.wait)
        self.addCleanup(stranger.kill)
        control = json.loads((self.bucket / 'fleet-control.json').read_text())
        stat = Path('/proc', str(stranger.pid), 'stat').read_text().rsplit(')', 1)[1].split()
        control['attempts']['first']['owner'] = dict(control['attempts']['first']['owner'], pid=stranger.pid, start=stat[19])
        (self.bucket / 'fleet-control.json').write_text(json.dumps(control))
        p = self.call('runtime', 'admit', '--doc', self.doc, '--manifest', self.m, '--name', 'api-managed', '--join-attempt', 'first', ok=False)
        self.assertIn('family already owns worker or ticket', p.stderr)

    def set_attempt(self, aid, **fields):
        control = json.loads((self.bucket / 'fleet-control.json').read_text())
        control['attempts'][aid].update(fields)
        (self.bucket / 'fleet-control.json').write_text(json.dumps(control))

    def test_api_call_naming_a_pending_or_unknown_attempt_of_a_live_owner_is_refused(self):
        self.active()
        self.rt('begin', aid='first')
        p = self.api_call('first')
        self.assertEqual(p.returncode, 10, p.stdout)
        self.assertIn('family already owns worker or ticket', p.stderr)
        self.set_attempt('first', phase='unknown')
        p = self.api_call('first')
        self.assertEqual(p.returncode, 10, p.stdout)
        self.assertIn('family already owns worker or ticket', p.stderr)

    def test_api_call_naming_a_launched_attempt_whose_ancestor_pid_was_reused_is_refused(self):
        self.live_worker()
        owner = self.attempts()['first']['owner']
        self.set_attempt('first', phase='launched', owner=dict(owner, start=str(int(owner['start']) + 1)))
        p = self.api_call('first')
        self.assertEqual(p.returncode, 10, p.stdout)
        self.assertIn('family already owns worker or ticket', p.stderr)
        self.assertEqual(self.attempts()['first']['phase'], 'launched')

    def test_api_call_with_no_inherited_attempt_is_refused_as_today(self):
        self.live_worker()
        p = self.api_call('')
        self.assertEqual(p.returncode, 10, p.stdout)
        self.assertIn('family already owns worker or ticket', p.stderr)
        self.assertEqual(list(self.attempts()), ['first'])

    def test_api_call_from_a_worker_whose_attempt_is_no_longer_live_is_refused(self):
        self.live_worker()
        gone = subprocess.Popen(['sleep', '30'])
        stat = Path('/proc', str(gone.pid), 'stat').read_text().rsplit(')', 1)[1].split()
        gone.kill()
        gone.wait()
        control = json.loads((self.bucket / 'fleet-control.json').read_text())
        control['attempts']['first']['owner'] = dict(control['attempts']['first']['owner'], pid=gone.pid, start=stat[19])
        (self.bucket / 'fleet-control.json').write_text(json.dumps(control))
        p = self.api_call('first')
        self.assertEqual(p.returncode, 10, p.stdout)
        self.assertIn('family already owns worker or ticket', p.stderr)
        self.assertEqual(self.attempts()['first']['phase'], 'unknown')

    def test_administrative_docs_still_obey_native_hard_cap(self):
        for number in range(4):
            doc = self.bucket / ('HIMMEL-%d-N%d-worker.md' % (number + 10, number + 10))
            doc.write_text('# offline worker\n')
            self.real_worker(aid='cap-%d' % number, doc=doc)
        for name in ('chief-handover.md', 'nonexistent-notes.md'):
            doc = self.bucket / name
            if name.startswith('chief'):
                doc.write_text('# chief\n')
            env = dict(self.real_census_env(), FLEET_LAUNCH_DOC=str(doc),
                       CADENCE_USAGE_WORKER=doc.stem)
            env.pop('FLEET_LAUNCH_MANIFEST')
            env.pop('FLEET_CAP_OK')
            result = self.entry('scripts/lib/usage-preflight.sh', env=env)
            self.assertEqual(result.stdout.strip(), 'SKIPPED-FLEET', result.stderr)

    def test_administrative_docs_still_obey_api_off(self):
        for name in ('chief-handover.md', 'nonexistent-notes.md'):
            doc = self.bucket / name
            if name.startswith('chief'):
                doc.write_text('# chief\n')
            env = dict(self.launch_env(), FLEET_LAUNCH_DOC=str(doc),
                       CADENCE_USAGE_WORKER=doc.stem, CADENCE_USAGE_LANE='api',
                       HIMMEL_API_LANE='off')
            env.pop('FLEET_LAUNCH_MANIFEST')
            env.pop('FLEET_CAP_OK')
            result = self.entry('scripts/lib/usage-preflight.sh', env=env)
            self.assertEqual(result.stdout.strip(), 'SKIPPED-BANK', result.stderr)

    def test_unbound_and_conflicting_sibling_keep_live_and_unknown_ownership(self):
        for reference in (None, {'family':'wrong'}, 'malformed'):
            sibling = self.bucket / 'old.fleet.json'
            data = {'workers':[{'doc':str(self.doc), 'label':'N1'}]}
            if reference is not None:
                data['control'] = reference
            sibling.write_text(json.dumps(data))
            owners = json.loads(self.call('runtime', 'owners', '--manifest', sibling).stdout)
            self.assertEqual([r['doc'] for r in owners], [str(self.doc)])
            self.assertNotIn('attempt', owners[0])

    def test_pause_ack_retains_unverified_sibling(self):
        live_doc = self.bucket / 'HIMMEL-994-N2-live.md'
        live_doc.write_text('# live worker\n')
        self.real_worker('unbound-live', live_doc)
        sibling = self.bucket / 'unbound.fleet.json'
        sibling.write_text(json.dumps({'workers':[{'doc':str(live_doc), 'label':'N2'}]}))
        ack = json.loads(self.call('control', 'ack', self.m).stdout)
        self.assertFalse(ack['quiescent'])
        self.assertEqual(ack['legacy_unknown'][0]['doc'], str(live_doc))

    def test_inherited_attempt_cannot_stamp_another_name(self):
        self.active()
        env = self.real_census_env()
        self.rt('begin')
        for doc, name in ((self.doc, 'unrelated-arm'), (self.bucket / 'notes.md', 'unrelated-notes')):
            if not doc.exists():
                doc.write_text('# notes\n')
            e = dict(env, FLEET_LAUNCH_DOC=str(doc), FLEET_LAUNCH_ATTEMPT='one', CADENCE_USAGE_WORKER=name)
            e.pop('FLEET_LAUNCH_MANIFEST')
            self.entry('scripts/lib/usage-preflight.sh', env=e)
            self.assertFalse((self.bucket / 'slots' / name / 'managed.json').exists())
        self.rt('commit')

    def test_unknown_precommit_identity_and_expired_slot_stay_protected(self):
        self.active()
        self.rt('begin')
        env = dict(self.real_census_env(), FLEET_LAUNCH_ATTEMPT='one')
        self.entry('scripts/lib/usage-preflight.sh', env=env)
        anchor = self.bucket / 'fleet-control.json'
        data = json.loads(anchor.read_text())
        data['attempts']['one']['owner']['host'] = 'unverifiable-host'
        anchor.write_text(json.dumps(data))
        slot = self.bucket / 'slots' / self.doc.stem
        (slot / 'expires').write_text('0\n')
        self.doc.write_text(self.doc.read_text() + '- 12:00 WRAPPED uncertain\n')
        ack = json.loads(self.call('control', 'ack', self.m).stdout)
        self.assertEqual([r['attempt_id'] for r in ack['unknown']], ['one'])
        self.assertTrue((slot / 'managed.json').exists())
        self.rt('begin', aid='replacement', ok=False)

    def test_forged_slot_root_and_marker_do_not_prove_admission(self):
        self.active()
        record = json.loads(self.rt('begin').stdout)
        forged = self.bucket / 'forged'
        slot = forged / self.doc.stem
        slot.mkdir(parents=True)
        (slot / 'managed.json').write_text(json.dumps({'attempt_id':'one', 'owner':record['owner']}))
        (slot / 'name').write_text(self.doc.stem + '\n')
        env = dict(self.env, HIMMEL_FLEET_SLOTS=str(forged), FLEET_CONTROL_HELD='true', FLEET_CAP_OK='1')
        env.pop('HIMMEL_POLICY_FOLLOWS_HOME', None)
        self.call('runtime', 'commit', '--doc', self.doc, '--manifest', self.m, '--name', self.doc.stem,
                  '--attempt-id', 'one', '--pid', os.getpid(), ok=False, env=env)
        # An authorized fixture root still needs the anchor's admission binding.
        self.env['HIMMEL_FLEET_SLOTS'] = str(forged)
        self.call('runtime', 'commit', '--doc', self.doc, '--manifest', self.m, '--name', self.doc.stem,
                  '--attempt-id', 'one', '--pid', os.getpid(), ok=False)

    def test_real_census_target_hard_cap_and_failure_controls(self):
        self.call('control', 'set', self.m, '--mode', 'active', '--target', '1', '--expect-gen', '1')
        self.rt('begin')
        env = dict(self.real_census_env(), FLEET_LAUNCH_ATTEMPT='one', FLEET_CONTROL_HELD='true',
                   FLEET_CONTROL_GENERATION='2', WORKER_SESSION_ROLE='chief', HIMMEL_FLEET_CAP='999')
        workers = []
        for number in range(4):
            doc = self.bucket / ('HIMMEL-' + str(950 + number) + '-N1-census.md')
            doc.write_text('# real census fixture\n')
            workers.append(self.real_worker('census-' + str(number), doc))
            if number == 0:
                p = self.entry('scripts/lib/usage-preflight.sh', env=env)
                self.assertEqual(p.stdout.strip(), 'SKIPPED-FLEET', p.stderr)
                self.assertIn('total=1/1', p.stderr)
        # A corrupt/manual target above the activation ceiling still cannot
        # weaken the independent resource cap.
        anchor = self.bucket / 'fleet-control.json'
        data = json.loads(anchor.read_text())
        data['target'] = 20
        anchor.write_text(json.dumps(data))
        p = self.entry('scripts/lib/usage-preflight.sh', env=env)
        self.assertEqual(p.stdout.strip(), 'SKIPPED-FLEET', p.stderr)
        self.assertIn('total=4/4', p.stderr)
        self.assertFalse((self.bucket / 'slots' / self.doc.stem).exists())
        for p in workers:
            p.terminate()
            p.wait(timeout=5)
        env['FLEET_PS_CMD'] = self.stub('broken-ps', 'exit 1')
        self.assertEqual(self.entry('scripts/lib/usage-preflight.sh', env=env).stdout.strip(), 'SKIPPED-FLEET')

    def test_exact_release_preserves_replacement_marker(self):
        self.active()
        record = json.loads(self.rt('begin').stdout)
        self.rt('commit')
        self.rt('outcome', extra=('--phase', 'unknown'))
        slot = self.bucket / 'slots' / self.doc.stem
        replacement = {'attempt_id':'replacement', 'owner':dict(record['owner'], start='0')}
        (slot / 'managed.json').write_text(json.dumps(replacement))
        self.rt('outcome', extra=('--phase', 'complete'))
        self.call('runtime', 'release', '--attempt-id', 'one', '--pid', os.getpid())
        self.assertEqual(json.loads((slot / 'managed.json').read_text()), replacement)
        replacement['attempt_id'] = 'one'
        (slot / 'managed.json').write_text(json.dumps(replacement))
        self.call('runtime', 'release', '--attempt-id', 'one', '--pid', os.getpid())
        self.assertEqual(json.loads((slot / 'managed.json').read_text()), replacement)

    def test_actual_chief_launch_while_workers_paused_is_quiescent(self):
        doc = self.bucket / 'chief-handover.md'
        doc.write_text('# chief recovery\n')
        env = self.headed_env()
        env.pop('FLEET_LAUNCH_MANIFEST')
        env.pop('FLEET_LAUNCH_DOC')
        p = self.entry('scripts/handover/headed-arm.sh',
                       (self.doc.stem, doc, self.bucket / 'sig', '1', self.bucket / 'log'), env)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertTrue((self.bucket / 'spawned').exists())
        ack = json.loads(self.call('control', 'ack', self.m).stdout)
        self.assertTrue(ack['quiescent'], ack)
        self.assertEqual(json.loads((self.bucket / 'fleet-control.json').read_text()).get('attempts'), {})

    def test_commit_itself_reconciles_terminal_attempt(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        self.rt('outcome', extra=('--phase', 'launched'))
        doc = self.bucket / 'HIMMEL-980-N2-next.md'
        doc.write_text('# next worker\n')
        self.call('add', self.m, doc, '--lane', 'native', '--pending')
        self.rt('begin', aid='two', doc=doc)
        env = dict(self.real_census_env(), FLEET_LAUNCH_DOC=str(doc), CADENCE_USAGE_WORKER=doc.stem,
                   FLEET_LAUNCH_ATTEMPT='two')
        p = self.entry('scripts/lib/usage-preflight.sh', env=env)
        self.assertIn(p.stdout.strip(), ('PROCEED', 'BANK-STALE', 'BANK-UNKNOWN'), p.stderr)
        self.doc.write_text(self.doc.read_text() + '- 12:00 WRAPPED ended\n')
        self.call('runtime', 'commit', '--doc', doc, '--manifest', self.m, '--name', doc.stem,
                  '--attempt-id', 'two', '--pid', os.getpid())
        self.assertEqual(list(json.loads((self.bucket / 'fleet-control.json').read_text())['attempts']), ['two'])
        self.assertFalse((self.bucket / 'slots' / self.doc.stem).exists())

    def test_active_scheduled_worker_repeats_with_explicit_manifest(self):
        self.call('control', 'set', self.m, '--mode', 'active', '--target', '1', '--expect-gen', '1')
        env = self.real_census_env()
        command = ['python3', '-I', str(self.anchorless_tree() / 'scripts/lib/fleet_runtime.py'), 'run', '--doc', str(self.doc),
                   '--name', self.doc.stem, '--manifest', str(self.m), '--', 'bash', '-c',
                   'test -z "${FLEET_LAUNCH_ATTEMPT:-}" && test -n "$WORKER_SESSION_ATTEMPT_ID" && touch "$HOME/scheduled-ended"']
        for _ in range(2):
            p = subprocess.run(command, env=env, capture_output=True, text=True, timeout=15)
            self.record(command, p)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertTrue((self.bucket / 'scheduled-ended').exists())
            self.assertEqual(json.loads((self.bucket / 'fleet-control.json').read_text())['attempts'], {})
            self.assertFalse((self.bucket / 'slots' / self.doc.stem).exists())

    # The shared ownership reading (_ts_worker_state) over this fixture's real state and receipt history.
    def state(self, doc=None, env=None):
        # the queue lock is a stub: with no handover root the real one cannot answer, which reads unknown
        env = env or dict(self.env, TICKET_STATUS_QUEUE_LOCK=self.stub('queue-lock-free', 'echo free'))
        p = subprocess.run(['bash', '-c', '. "$1/scripts/lib/ticket-status.sh"; ts_worker_state "$2"', 'fleet-runtime-test',
                            str(ENTRYPOINTS), str(doc or self.doc)], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.strip()

    def disp(self, doc=None):
        return json.loads(self.call('runtime', 'disposition', '--doc', doc or self.doc).stdout)

    def protected(self, doc=None):
        return json.loads(self.call('runtime', 'protected', '--doc', doc or self.doc).stdout)

    def lock_env(self, status, heartbeat_age=0):
        # queue-lock.sh status stub: rc 11 = held, with a heartbeat the given number of seconds old
        body = ('hb=$(date -u -d "-%d seconds" +%%Y-%%m-%%dT%%H:%%M:%%SZ)\n'
                'printf \'{\\n  "heartbeat": "%%s"\\n}\\nstatus: %s\\n\' "$hb"\nexit 11') % (heartbeat_age, status)
        return dict(self.env, TICKET_STATUS_QUEUE_LOCK=self.stub('queue-lock-stub', body))

    def named_session(self, attempt_id='', name=None, comm=b'claude', doc=None):
        code = 'import ctypes,time; ctypes.CDLL(None).prctl(15,%r,0,0,0); time.sleep(30)' % comm
        env = dict(self.env, WORKER_SESSION_DOC=str(doc or self.doc))
        if attempt_id:
            env['WORKER_SESSION_ATTEMPT_ID'] = attempt_id
        p = subprocess.Popen([comm.decode(), '-c', code, '-n', name or self.doc.stem], executable=sys.executable, env=env)
        self.addCleanup(lambda: (p.terminate(), p.wait(timeout=5)) if p.poll() is None else None)
        time.sleep(.2)
        return p

    def stop(self, process):
        process.terminate()
        process.wait(timeout=5)

    def wrote(self, line):
        with self.doc.open('a') as stream:
            stream.write(line + '\n')

    # No attempt phase may read as live, and none reads as free.
    def test_pending_registration_and_attempt_never_read_live_and_stay_protected(self):
        self.active()
        self.assertEqual(self.state(), 'unknown')  # a pending registration with no attempt
        self.rt('begin')
        self.assertEqual(self.disp(), 'pending')
        self.assertEqual(self.state(), 'unknown')
        self.assertTrue(self.protected())
        self.rt('begin', aid='second', ok=False)
        self.assertEqual(self.state(), 'unknown')

    def test_committed_attempt_without_an_observed_session_is_not_live_and_stays_protected(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        self.assertEqual(self.disp(), 'committed')
        self.assertEqual(self.state(), 'unknown')
        self.assertTrue(self.protected())
        self.rt('begin', aid='second', ok=False)
        self.assertEqual(self.state(), 'unknown')

    def test_unknown_attempt_is_neither_live_nor_free_and_stays_protected(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        self.rt('outcome', extra=('--phase', 'unknown'))
        self.assertEqual(self.disp(), 'unknown')
        state = self.state()
        self.assertEqual(state, 'unknown')
        self.assertNotIn(state, ('live', 'wrapped'))
        self.assertTrue(self.protected())
        self.rt('begin', aid='second', ok=False)

    def test_launched_attempt_with_no_marker_or_lock_is_unknown_not_live(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        self.rt('outcome', extra=('--phase', 'launched'))
        self.assertEqual(self.disp(), 'launched')
        self.assertEqual(self.state(), 'unknown')
        self.rt('begin', aid='second', ok=False)

    PAST_BOOT = '11111111-2222-3333-4444-555555555555'

    def journal_env(self, body):
        return dict(self.env, FLEET_JOURNAL_BOOTS_CMD=self.stub('list-boots', body))

    def prior_boot_wrapped_attempt(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        self.rt('outcome', extra=('--phase', 'launched'))
        self.wrote('- 12:00 WRAPPED done')
        self.forge(boot=self.PAST_BOOT)

    def admit_same_doc(self, env, ok):
        return self.call('runtime', 'admit', '--doc', self.doc, '--manifest', self.m, '--name', self.doc.stem, ok=ok, env=env)

    def test_launched_attempt_from_a_past_local_boot_is_settled_and_the_doc_admits_again(self):
        self.prior_boot_wrapped_attempt()
        listing = ' -1 %s Sun 2026-11-22 16:43:26 CET Mon 2026-11-23 14:10:41 CET\n  0 d188f74120ee4795befadc4e452e6397 Mon x Mon y\n'
        env = self.journal_env("cat <<'EOF'\nIDX BOOT ID\n" + listing % self.PAST_BOOT.replace('-', '') + 'EOF')
        self.admit_same_doc(env, True)
        self.env = env
        self.rt('begin', aid='second')

    def test_launched_attempt_from_an_unlisted_boot_stays_refused(self):
        self.prior_boot_wrapped_attempt()
        env = self.journal_env("echo '  0 d188f74120ee4795befadc4e452e6397 Mon x Mon y'")
        p = self.admit_same_doc(env, False)
        self.assertIn('family already owns worker or ticket', p.stderr)

    def test_launched_attempt_stays_refused_when_the_journal_is_unavailable(self):
        self.prior_boot_wrapped_attempt()
        p = self.admit_same_doc(self.journal_env('exit 1'), False)
        self.assertIn('family already owns worker or ticket', p.stderr)
        listed = ' -1 %s Sun x Mon y' % self.PAST_BOOT.replace('-', '')
        p = self.admit_same_doc(self.journal_env("echo '%s'; exit 1" % listed), False)
        self.assertIn('family already owns worker or ticket', p.stderr)
        p = self.admit_same_doc(dict(self.env, FLEET_JOURNAL_BOOTS_CMD=str(self.bucket / 'absent')), False)
        self.assertIn('family already owns worker or ticket', p.stderr)

    def listing_env(self, boot, gate=True):
        env = self.journal_env("echo ' -1 %s Sun x Mon y'" % boot.replace('-', ''))
        if not gate:
            del env['HIMMEL_POLICY_FOLLOWS_HOME']
        return env

    def test_journal_seam_is_ignored_without_the_policy_gate(self):
        self.prior_boot_wrapped_attempt()
        p = self.admit_same_doc(self.listing_env(self.PAST_BOOT, gate=False), False)
        self.assertIn('family already owns worker or ticket', p.stderr)

    def test_launched_attempt_from_a_foreign_host_with_a_listed_boot_stays_refused(self):
        self.prior_boot_wrapped_attempt()
        self.forge(host='another-host')
        p = self.admit_same_doc(self.listing_env(self.PAST_BOOT), False)
        self.assertIn('family already owns worker or ticket', p.stderr)

    def test_current_boot_without_dashes_is_never_a_past_boot(self):
        self.prior_boot_wrapped_attempt()
        current = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        self.forge(boot=current.replace('-', ''))
        p = self.admit_same_doc(self.listing_env(current), False)
        self.assertIn('family already owns worker or ticket', p.stderr)

    def ended_launched_attempt(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        self.rt('outcome', extra=('--phase', 'launched'))
        self.forge(start='0')
        self.free_env = dict(self.env, TICKET_STATUS_QUEUE_LOCK=self.stub('queue-lock-free', 'echo free'))

    def control_state(self):
        files = {p.name: p.read_bytes() for p in self.bucket.glob('*.json')}
        history = self.bucket / '.himmel/launch-refusals.jsonl'
        files['receipts'] = history.read_bytes() if history.exists() else b''
        return files

    def attempts_and_receipts(self):
        history = self.bucket / '.himmel/launch-refusals.jsonl'
        return self.attempts(), history.read_bytes() if history.exists() else b''

    def test_ended_launched_attempt_is_not_an_owner_for_the_dry_run_and_begin_settles_it(self):
        self.ended_launched_attempt()
        slot = self.bucket / 'slots' / self.doc.stem
        before = self.control_state()
        self.admit_same_doc(self.free_env, True)
        self.assertEqual(self.control_state(), before, 'the read-only admit writes nothing')
        self.env = self.free_env
        self.rt('begin', aid='second')
        self.assertEqual(list(self.attempts()), ['second'])
        self.assertFalse(slot.exists(), 'the settled attempt\'s reservation is released')
        rows = self.history_rows('one')
        self.assertEqual(rows[-1]['outcome'], 'refused')
        self.assertEqual(rows[-1]['cause'], 'settled-ended-session')
        self.assertEqual(rows[-1]['evidence']['owner'], 'dead')
        self.assertEqual(set(rows[-1]['settled_by']), {'host', 'pid', 'uid'})
        self.assertEqual([w['attempt']['attempt_id'] for w in json.loads(self.m.read_text())['workers']], ['second'])

    def test_launched_attempt_with_a_live_session_still_refuses_and_is_untouched(self):
        self.ended_launched_attempt()
        self.named_session(attempt_id='one')
        before = self.attempts_and_receipts()
        p = self.admit_same_doc(self.free_env, False)
        self.assertIn('family already owns worker or ticket', p.stderr)
        self.env = self.free_env
        self.rt('begin', aid='second', ok=False)
        self.assertEqual(self.attempts_and_receipts(), before)

    def test_launched_attempt_with_a_live_owner_still_refuses(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        self.rt('outcome', extra=('--phase', 'launched'))
        self.env = dict(self.env, TICKET_STATUS_QUEUE_LOCK=self.stub('queue-lock-free', 'echo free'))
        before = self.attempts_and_receipts()
        self.rt('begin', aid='second', ok=False)
        self.assertEqual(self.attempts_and_receipts(), before)

    def test_launched_attempt_whose_queue_lock_is_held_still_refuses(self):
        self.ended_launched_attempt()
        before = self.attempts_and_receipts()
        p = self.admit_same_doc(self.lock_env('HELD'), False)
        self.assertIn('family already owns worker or ticket', p.stderr)
        self.env = self.lock_env('HELD')
        self.rt('begin', aid='second', ok=False)
        self.assertEqual(self.attempts_and_receipts(), before)

    def test_launched_attempt_with_an_unknown_process_state_still_refuses(self):
        self.ended_launched_attempt()
        self.forge(host='another-host')
        before = self.attempts_and_receipts()
        p = self.admit_same_doc(self.free_env, False)
        self.assertIn('family already owns worker or ticket', p.stderr)
        self.env = self.free_env
        self.rt('begin', aid='second', ok=False)
        self.assertEqual(self.attempts_and_receipts(), before)

    # A terminal receipt ends ownership only when nothing newer or stronger contradicts it.
    def test_refused_receipt_does_not_hide_a_live_named_session(self):
        self.active()
        self.rt('begin')
        self.rt('outcome', extra=('--phase', 'refused'))
        self.assertEqual(self.state(), 'wrapped')  # control: the refusal alone ends it
        session = self.named_session()
        self.assertEqual(self.state(), 'unknown')
        self.stop(session)
        self.assertEqual(self.state(), 'wrapped')  # control: the receipt stands again once nothing contradicts it

    def test_complete_receipt_does_not_hide_a_later_resume(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        self.rt('outcome', extra=('--phase', 'launched'))
        self.wrote('- 12:00 WRAPPED done')
        self.rt('outcome', extra=('--phase', 'complete'))
        self.assertEqual(self.state(), 'wrapped')  # control
        session = self.named_session()
        self.assertEqual(self.state(), 'unknown')  # a live named session before any new marker is written
        self.wrote('- 12:30 RESUMED operator resumed by hand')
        self.assertEqual(self.state(), 'unknown')
        self.stop(session)
        self.assertEqual(self.state(), 'unknown')  # a marker later than the receipt stays an owner with no session and no lock

    def test_terminal_receipt_does_not_override_a_held_lock(self):
        self.active()
        self.rt('begin')
        self.rt('outcome', extra=('--phase', 'refused'))
        self.assertEqual(self.state(env=self.lock_env('HELD')), 'unknown')
        self.wrote('- 12:30 LIVE hand launched')
        self.assertEqual(self.state(env=self.lock_env('HELD')), 'live')

    def test_terminal_receipt_leaves_a_doc_with_a_live_class_marker_to_its_markers(self):
        self.active()
        self.wrote('- 11:00 LIVE worker started')
        self.rt('begin')
        self.rt('outcome', extra=('--phase', 'refused'))
        self.assertEqual(self.state(), 'unknown')  # the refusal releases its own registration, not a worker that never wrapped
        self.wrote('- 11:30 PARKED-USAGE usage limit')
        self.assertEqual(self.state(), 'parked')

    # A receipt belongs to the registration it settled, not to a later one for the same doc.
    def test_stale_terminal_receipt_does_not_hide_a_reregistered_pending_row(self):
        self.active()
        self.rt('begin')
        self.rt('outcome', extra=('--phase', 'refused'))
        self.assertEqual(json.loads(self.call('runtime', 'owners', '--manifest', self.m).stdout), [])
        self.assertEqual(self.disp(), 'refused')
        time.sleep(1.1)  # receipts and registrations are stamped to the second
        self.call('add', self.m, self.doc, '--lane', 'native', '--pending')
        owners = json.loads(self.call('runtime', 'owners', '--manifest', self.m).stdout)
        self.assertEqual([(row['doc'], row.get('registration')) for row in owners], [(str(self.doc), 'pending')])
        self.assertEqual(self.disp(), 'legacy')
        self.assertEqual(self.state(), 'unknown')
        self.rt('begin', aid='two')
        self.assertEqual(self.disp(), 'pending')

    # An idle shell and a long-running test are allocated work, never dead and never reclaimed for inactivity.
    def test_idle_shell_is_allocated_not_productive_and_never_claims_or_releases_a_slot(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        self.rt('outcome', extra=('--phase', 'unknown'))
        slot = self.bucket / 'slots' / self.doc.stem / 'managed.json'
        self.assertTrue(slot.is_file())
        # a shell in the worker's terminal inherits the worker environment and can carry the same -n argument
        shell = subprocess.Popen(['bash', '-c', 'sleep 30', 'x', '-n', self.doc.stem],
                                 env=dict(self.env, WORKER_SESSION_DOC=str(self.doc), WORKER_SESSION_ATTEMPT_ID='one'))
        self.addCleanup(lambda: (shell.terminate(), shell.wait(timeout=5)) if shell.poll() is None else None)
        time.sleep(.2)
        ack = json.loads(self.rt('ack').stdout)
        self.assertEqual([r['attempt_id'] for r in ack['unknown']], ['one'])  # not promoted to launched
        self.assertEqual(ack['launched'], [])
        self.assertFalse(ack['quiescent'])
        self.assertTrue(slot.is_file())  # not released
        self.assertEqual(self.state(), 'unknown')
        self.rt('begin', aid='second', ok=False)

    def test_idle_session_is_allocated_not_productive_and_not_dead(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        self.rt('outcome', extra=('--phase', 'unknown'))
        session = self.named_session(attempt_id='one')
        for _ in range(2):
            ack = json.loads(self.rt('ack').stdout)
            self.assertEqual(ack['unknown'], [])
            self.assertEqual([r['attempt_id'] for r in ack['launched']], ['one'])
            self.assertFalse(ack['quiescent'])
        self.assertTrue((self.bucket / 'slots' / self.doc.stem / 'managed.json').is_file())
        self.assertEqual(self.state(), 'unknown')  # a session with no marker and no lock is never productive
        self.assertNotEqual(self.state(env=self.lock_env('HELD')), 'wrapped')
        self.rt('begin', aid='second', ok=False)
        self.stop(session)

    def test_long_running_test_with_no_recent_tool_calls_is_owned_never_reclaimed(self):
        self.active()
        self.rt('begin')
        self.rt('commit')
        self.rt('outcome', extra=('--phase', 'unknown'))
        self.wrote('- 01:00 LIVE worker started; a long test is running')
        session = self.named_session(attempt_id='one')
        child = subprocess.Popen(['sleep', '30'])  # the long test, under the session
        self.addCleanup(lambda: (child.terminate(), child.wait(timeout=5)) if child.poll() is None else None)
        for _ in range(2):
            ack = json.loads(self.rt('ack').stdout)
            self.assertEqual([r['attempt_id'] for r in ack['launched']], ['one'])
        self.assertTrue((self.bucket / 'slots' / self.doc.stem / 'managed.json').is_file())
        self.assertEqual(self.state(env=self.lock_env('HELD')), 'live')  # a fresh lock is productive work
        # no tool call for longer than the idle warning: still held work, never released and never wrapped
        stale = self.state(env=dict(self.lock_env('HELD', heartbeat_age=7200), QUEUE_LOCK_IDLE_WARN_SECONDS='2700'))
        self.assertEqual(stale, 'IDLE-HELD')
        self.assertTrue((self.bucket / 'slots' / self.doc.stem / 'managed.json').is_file())
        self.rt('begin', aid='second', ok=False)
        self.stop(session)

    # One run's worker states: the batch answers the one-doc question from one read of each directory.
    def runtime_module(self):
        sys.path.insert(0, str(ENTRYPOINTS / 'scripts/lib'))
        try:
            import fleet_runtime
        finally:
            sys.path.pop(0)
        return fleet_runtime

    def batch_env(self):
        return mock.patch.dict(os.environ, dict(HOME=str(self.bucket), HIMMEL_POLICY_FOLLOWS_HOME='1',
                                                TICKET_STATUS_QUEUE_LOCK=self.stub('queue-lock-free', 'echo free')))

    def plain_doc(self, name, *lines):
        path = self.bucket / name
        path.write_text('# worker\n' + ''.join(line + '\n' for line in lines))
        return path

    def batch_scenario(self):
        """Docs in every state disposition tells apart: an anchored bucket (real attempts and receipts, then attempts written
        straight into the anchor) and a directory with no anchor."""
        self.active()
        docs = {'pending': self.doc}
        self.rt('begin')
        docs['refused'] = self.plain_doc('TEST-2-N1-refused.md')
        self.call('add', self.m, docs['refused'], '--lane', 'native', '--pending')
        self.rt('begin', aid='r', doc=docs['refused'])
        self.rt('outcome', aid='r', doc=docs['refused'], extra=('--phase', 'refused'))
        docs['complete'] = self.plain_doc('TEST-3-N1-complete.md')
        self.call('add', self.m, docs['complete'], '--lane', 'native', '--pending')
        self.rt('begin', aid='c', doc=docs['complete'])
        self.rt('commit', aid='c', doc=docs['complete'])
        self.rt('outcome', aid='c', doc=docs['complete'], extra=('--phase', 'launched'))
        with docs['complete'].open('a') as stream:
            stream.write('- 12:00 WRAPPED done\n')
        self.rt('outcome', aid='c', doc=docs['complete'], extra=('--phase', 'complete'))
        docs['reregistered'] = self.plain_doc('TEST-4-N1-reregistered.md')
        self.call('add', self.m, docs['reregistered'], '--lane', 'native', '--pending')
        self.rt('begin', aid='g', doc=docs['reregistered'])
        self.rt('outcome', aid='g', doc=docs['reregistered'], extra=('--phase', 'refused'))
        time.sleep(1.1)  # receipts and registrations are stamped to the second
        self.call('add', self.m, docs['reregistered'], '--lane', 'native', '--pending')
        docs['registered'] = self.plain_doc('TEST-5-N1-registered.md')
        self.call('add', self.m, docs['registered'], '--lane', 'native', '--pending')
        docs['legacy'] = self.plain_doc('TEST-6-N1-legacy.md')
        self.call('add', self.m, docs['legacy'], '--lane', 'native')
        docs['missing'] = self.bucket / 'TEST-7-N1-missing.md'
        self.call('add', self.m, docs['missing'], '--lane', 'native')
        docs['unlisted'] = self.plain_doc('TEST-8-N1-unlisted.md')
        anchor = self.bucket / 'fleet-control.json'
        data = json.loads(anchor.read_text())
        for key, phase in (('committed', 'committed'), ('unknown', 'unknown'), ('launched', 'launched')):
            docs[key] = self.plain_doc('TEST-9-N1-%s.md' % key)
            data['attempts']['syn-' + key] = dict(attempt_id='syn-' + key, phase=phase, doc=str(docs[key]), name=docs[key].stem)
        anchor.write_text(json.dumps(data))
        loose = self.bucket / 'loose'
        loose.mkdir()
        docs['loose'], docs['loose-attempt'] = self.plain_doc('loose/TEST-10-N1-loose.md'), self.plain_doc('loose/TEST-11-N1-attempt.md')
        (loose / 'a.fleet.json').write_text(json.dumps({'schema': 1, 'workers': [
            {'doc': str(docs['loose']), 'label': 'N1'},
            {'doc': str(docs['loose-attempt']), 'label': 'N2', 'attempt': {'attempt_id': 'x', 'phase': 'committed'}}]}))
        return docs

    def test_batch_answers_equal_the_one_doc_answer_in_every_state(self):
        docs = self.batch_scenario()
        runtime = self.runtime_module()
        with self.batch_env():
            batch = runtime.WorkerStates()
            for name, doc in docs.items():
                single = runtime.disposition(str(doc))
                got = batch.batched(str(doc))
                self.assertEqual(got, single, name)
                self.assertEqual(json.loads(self.call('runtime', 'disposition', '--doc', doc).stdout), single, name)
            # the scenario really holds every state, so the equalities above compare different answers
            self.assertEqual({name: batch.batched(str(doc)) for name, doc in docs.items()},
                             {'pending': 'pending', 'refused': 'refused', 'complete': 'complete', 'reregistered': 'legacy',
                              'registered': 'legacy', 'legacy': 'legacy', 'missing': 'legacy', 'unlisted': 'legacy', 'committed': 'committed',
                              'unknown': 'unknown', 'launched': 'launched', 'loose': 'legacy', 'loose-attempt': 'unknown'})

    def test_batch_reads_each_manifest_and_the_anchor_once_whatever_the_doc_count(self):
        docs = self.batch_scenario()
        runtime = self.runtime_module()
        reads = collections.Counter()
        real = runtime.read

        def counting(path):
            reads[str(path)] += 1
            return real(path)
        with self.batch_env(), mock.patch.object(runtime, 'read', counting):
            batch = runtime.WorkerStates()
            for _ in range(3):
                for doc in docs.values():
                    batch.batched(str(doc))
        self.assertEqual(max(reads.values()), 1, dict(reads))
        self.assertIn(str(self.m), reads)
        self.assertIn(str(self.bucket / 'fleet-control.json'), reads)
        self.assertIn(str(self.bucket / 'loose/a.fleet.json'), reads)

    def test_batch_that_cannot_read_leaves_the_doc_to_the_one_doc_answer(self):
        docs = self.batch_scenario()
        runtime = self.runtime_module()
        (self.bucket / 'broken.fleet.json').write_text('{not json')
        history = self.bucket / '.himmel/launch-refusals.jsonl'
        saved = history.read_text()
        with self.batch_env():
            batch = runtime.WorkerStates()
            for name, doc in docs.items():
                if name.startswith('loose'):
                    self.assertIsNotNone(batch.batched(str(doc)), name + ': the unbroken directory is still batched')
                else:
                    self.assertIsNone(batch.batched(str(doc)), name + ': a manifest that cannot be read leaves every doc of its directory')
            for name, doc in docs.items():
                self.assertEqual(runtime.WorkerStates()(str(doc)), runtime.worker_state(str(doc)), name)
            (self.bucket / 'broken.fleet.json').unlink()
            history.write_text(saved + json.dumps(dict(v=2, kind='launch-attempt', doc=str(docs['refused']))) + '\n')
            batch = runtime.WorkerStates()
            self.assertIsNone(batch.batched(str(docs['refused'])), 'a receipt the history reader cannot place leaves the doc to the one-doc answer')
            self.assertIsNone(batch.batched(str(docs['complete'])))
            for name, doc in docs.items():
                self.assertEqual(runtime.WorkerStates()(str(doc)), runtime.worker_state(str(doc)), name)
            # a row the batch reads but cannot place (an attempt that is not an object) leaves that doc alone, and only that doc
            badrow = self.plain_doc('loose/TEST-12-N1-badrow.md')
            (self.bucket / 'loose/b.fleet.json').write_text(json.dumps({'schema': 1, 'workers': [{'doc': str(badrow), 'label': 'N3', 'attempt': 'bogus'}]}))
            batch = runtime.WorkerStates()
            self.assertIsNone(batch.batched(str(badrow)))
            self.assertEqual(batch.batched(str(docs['loose'])), 'legacy')
            self.assertEqual(batch(str(badrow)), runtime.worker_state(str(badrow)))

    def test_worker_states_memoizes_by_doc_and_asks_the_canonical_function_once(self):
        docs = self.batch_scenario()
        runtime = self.runtime_module()
        calls = []
        real = runtime.worker_state

        def counting(doc, *args, **kwargs):
            calls.append((doc, kwargs.get('disposition') or (args[1] if len(args) > 1 else None)))
            return real(doc, *args, **kwargs)
        with self.batch_env(), mock.patch.object(runtime, 'worker_state', counting):
            states = runtime.WorkerStates()
            first = {name: states(str(doc)) for name, doc in docs.items()}
            second = {name: states(str(doc)) for name, doc in docs.items()}
        self.assertEqual(first, second)
        self.assertEqual(len(calls), len(docs))
        self.assertEqual(len({doc for doc, _ in calls}), len(docs))
        self.assertEqual({Path(doc).name for doc, disposition in calls if disposition is None}, set())
        with self.batch_env():
            for name, doc in docs.items():
                self.assertEqual(first[name], runtime.worker_state(str(doc)), name)

    # The explicit settle verb: a committed or unknown attempt whose launcher is gone and which never showed a session.
    def settle(self, aid='one', doc=None, ok=True, name=None, reason='the launcher is gone and nothing started', confirm=True):
        target = doc or self.doc
        argv = ['runtime', 'settle', '--doc', target, '--manifest', self.m, '--name', name or Path(target).stem,
                '--attempt-id', aid, '--reason', reason]
        if confirm:
            argv.append('--confirm-no-session')
        return self.call(*argv, ok=ok)

    def refused_settle(self, text, **kwargs):
        p = self.settle(ok=False, **kwargs)
        self.assertIn('settle refused', p.stderr)
        self.assertIn(text, p.stderr)
        return p

    def forge(self, aid='one', **fields):
        """Change the recorded identity of the attempt's owner and committer, as a reused pid or another boot would."""
        anchor = self.bucket / 'fleet-control.json'
        data = json.loads(anchor.read_text())
        for who in ('owner', 'committer'):
            if data['attempts'][aid].get(who):
                data['attempts'][aid][who].update(fields)
        anchor.write_text(json.dumps(data))

    def stuck(self, aid='one', doc=None):
        self.rt('begin', aid=aid, doc=doc)
        self.rt('commit', aid=aid, doc=doc)

    def anchor_attempts(self):
        return json.loads((self.bucket / 'fleet-control.json').read_text())['attempts']

    def history_rows(self, aid):
        path = self.bucket / '.himmel/launch-refusals.jsonl'
        return [row for row in map(json.loads, path.read_text().splitlines()) if row.get('attempt_id') == aid]

    def extra_doc(self, number):
        doc = self.bucket / ('TEST-%d-N%d-worker.md' % (number, number))
        doc.write_text('# worker\n')
        self.call('add', self.m, doc, '--lane', 'native', '--pending')
        return doc

    def test_settle_frees_a_stuck_attempt_keeps_its_history_and_is_idempotent(self):
        self.active()
        self.stuck()
        two = self.extra_doc(2)
        self.stuck('two', two)
        three = self.extra_doc(3)
        self.rt('begin', aid='three', doc=three)
        self.rt('commit', aid='three', doc=three, ok=False)  # the family target of 2 is full
        self.forge(start='0')
        ack = json.loads(self.rt('ack').stdout)
        self.assertEqual([r['attempt_id'] for r in ack['unknown']], ['one'])
        self.assertFalse(ack['quiescent'])
        slot = self.bucket / 'slots' / self.doc.stem
        self.assertTrue(slot.is_dir())
        self.refused_settle('--confirm-no-session', confirm=False)
        self.refused_settle('--reason', reason='   ')
        self.assertIn('one', self.anchor_attempts())
        self.assertTrue(slot.is_dir())
        result = json.loads(self.settle().stdout)
        self.assertEqual((result['phase'], result['cause']), ('refused', 'settled-no-session'))
        self.assertNotIn('one', self.anchor_attempts())
        self.assertFalse(slot.exists(), 'the attempt\'s own reservation is released')
        self.assertEqual([w['doc'] for w in json.loads(self.m.read_text())['workers']], [str(two), str(three)])
        self.assertTrue((self.bucket / 'slots' / two.stem).is_dir(), 'another attempt\'s reservation is untouched')
        four = self.extra_doc(4)
        self.rt('begin', aid='four', doc=four)
        self.rt('commit', aid='four', doc=four)  # the target slot the attempt held is free
        rows = self.history_rows('one')
        self.assertEqual([row['outcome'] for row in rows], ['attempt-started', 'refused'], 'history keeps the earlier rows and adds one')
        last = rows[-1]
        self.assertEqual(last['cause'], 'settled-no-session')
        self.assertEqual(last['reason'], 'the launcher is gone and nothing started')
        self.assertEqual(last['evidence']['owner'], 'dead')
        self.assertEqual(last['evidence']['committer'], 'dead')
        self.assertEqual(last['evidence']['scan'], 'absent')
        self.assertEqual(last['evidence']['phase'], 'unknown')
        self.assertEqual(set(last['settled_by']), {'host', 'pid', 'uid'})
        before = (self.bucket / '.himmel/launch-refusals.jsonl').read_text()
        replay = json.loads(self.settle().stdout)
        self.assertTrue(replay['replayed'])
        self.assertEqual((self.bucket / '.himmel/launch-refusals.jsonl').read_text(), before)

    def test_settle_takes_a_committed_attempt_before_any_ack_demoted_it(self):
        self.active()
        self.stuck()
        self.forge(start='0')
        self.assertEqual(self.anchor_attempts()['one']['phase'], 'committed')
        self.assertEqual(json.loads(self.settle().stdout)['cause'], 'settled-no-session')
        self.assertEqual(self.anchor_attempts(), {})

    def test_settle_gives_the_same_answer_to_an_old_attempt_and_a_new_one(self):
        self.active()
        two = self.extra_doc(2)
        self.stuck()
        self.stuck('two', two)
        anchor = self.bucket / 'fleet-control.json'
        data = json.loads(anchor.read_text())
        data['attempts']['one']['began_ticks'] = 0
        data['attempts']['two']['began_ticks'] = 10 ** 13
        anchor.write_text(json.dumps(data))
        history = self.bucket / '.himmel/launch-refusals.jsonl'
        history.write_text(history.read_text().replace('"attempt_id": "one"', '"ts": "1999-01-01T00:00:00Z", "attempt_id": "one"', 1))
        for aid in ('one', 'two'):
            self.forge(aid, start='0')
        self.settle('one')
        self.settle('two', doc=two)
        self.assertEqual(self.anchor_attempts(), {})

    def test_settle_needs_both_identities_proven_dead(self):
        self.active()
        self.stuck()
        self.refused_settle('owner')  # both are this live test process
        anchor = self.bucket / 'fleet-control.json'
        data = json.loads(anchor.read_text())
        data['attempts']['one']['owner']['start'] = '0'
        anchor.write_text(json.dumps(data))
        self.refused_settle('committer')  # the owner is gone, the committer is alive
        data['attempts']['one']['committer']['start'] = '0'
        anchor.write_text(json.dumps(data))
        self.settle()

    def test_settle_does_not_read_a_reused_pid_or_another_boot_as_more_than_the_existing_check_does(self):
        self.active()
        self.stuck()
        self.forge(boot='another-boot')
        self.refused_settle('not proven dead')  # a changed boot id is unknown, not dead
        self.forge(boot=(Path('/proc/sys/kernel/random/boot_id').read_text().strip()), host='another-host')
        self.refused_settle('not proven dead')  # a remote identity is unknown, not dead
        self.forge(host=socket.gethostname(), start='0')
        self.settle()  # the same host and boot with another start time: the existing check says dead

    def test_settle_refuses_while_a_session_may_exist(self):
        self.active()
        self.stuck()
        self.forge(start='0')
        session = self.named_session(attempt_id='one')
        self.refused_settle('session')
        self.stop(session)
        foreign = self.named_session(attempt_id='someone-else')  # a named process the scan cannot prove is not this attempt's
        self.refused_settle('session')
        self.stop(foreign)
        self.assertIn('one', self.anchor_attempts())
        self.settle()

    def test_settle_refuses_attempts_that_are_not_committed_or_unknown(self):
        self.active()
        self.rt('begin')
        self.forge(start='0')
        self.assertEqual(self.anchor_attempts()['one']['phase'], 'pending')
        self.refused_settle('phase')  # pending: settle does not reconcile, so the dead pending attempt is still there to refuse
        two = self.extra_doc(2)
        self.stuck('two', two)
        self.rt('outcome', aid='two', doc=two, extra=('--phase', 'launched'))
        self.forge('two', start='0')
        self.assertEqual(self.anchor_attempts()['two']['phase'], 'launched')
        self.refused_settle('phase', aid='two', doc=two)  # launched

    def test_settle_refuses_when_a_launched_or_terminal_receipt_exists(self):
        for outcome in ('launched', 'refused', 'complete'):
            self.setUp()
            history = self.bucket / '.himmel/launch-refusals.jsonl'
            self.active()
            self.stuck()
            self.forge(start='0')
            row = dict(self.history_rows('one')[0], outcome=outcome)
            with history.open('a') as stream:
                stream.write(json.dumps(row) + '\n')
            self.refused_settle('receipt')
            self.assertIn('one', self.anchor_attempts(), outcome)

    def test_settle_needs_the_exact_attempt_doc_and_name(self):
        self.active()
        self.stuck()
        self.forge(start='0')
        other = self.extra_doc(2)
        self.refused_settle('unknown attempt', aid='nope')
        self.refused_settle('locator', name='some-other-name')
        self.refused_settle('locator', doc=other)
        self.assertIn('one', self.anchor_attempts())
        self.settle()

    def test_a_second_attempt_after_a_settle_has_its_own_identity(self):
        self.active()
        self.stuck()
        first = self.anchor_attempts()['one']
        self.forge(start='0')
        self.settle()
        self.rt('begin', ok=False)  # the settled attempt id keeps its receipt history and is never reused
        self.call('add', self.m, self.doc, '--lane', 'native', '--pending')
        self.rt('begin', aid='two')
        second = self.anchor_attempts()['two']
        self.assertNotEqual(second['attempt_id'], first['attempt_id'])
        self.assertNotIn('reservation', second)
        self.assertNotIn('committer', second)
        self.assertEqual(second['phase'], 'pending')
        self.rt('commit', aid='two')
        self.assertEqual(self.anchor_attempts()['two']['phase'], 'committed')

    def test_a_settled_doc_that_shows_a_session_reads_as_owned(self):
        self.active()
        self.stuck()
        self.forge(start='0')
        self.settle()
        self.assertEqual(self.state(), 'wrapped')  # nothing contradicts the receipt
        session = self.named_session()
        self.assertEqual(self.state(), 'unknown')  # a session that shows up later is not hidden by it
        self.stop(session)

    def test_ack_names_the_way_out_as_text_and_only_when_the_preconditions_hold(self):
        self.active()
        self.stuck()
        ack = json.loads(self.rt('ack').stdout)  # the launcher is this live process
        self.assertEqual(ack['unknown'], [])
        self.forge(start='0')
        hint = json.loads(self.rt('ack').stdout)['unknown'][0]['settle_hint']
        self.assertTrue(hint['settleable'])
        self.assertIn('fleet-manifest.sh runtime settle', hint['text'])
        self.assertIn('--attempt-id one', hint['text'])
        self.assertIn('--confirm-no-session', hint['text'])
        session = self.named_session(attempt_id='someone-else')
        hint = json.loads(self.rt('ack').stdout)['unknown'][0]['settle_hint']
        self.assertFalse(hint['settleable'])
        self.assertIn('session', hint['text'])
        self.assertNotIn('fleet-manifest.sh runtime settle', hint['text'])
        self.stop(session)

    def test_settle_reads_no_age_and_nothing_calls_it(self):
        import ast
        import re
        source = (ENTRYPOINTS / 'scripts/lib/fleet_runtime.py').read_text()
        tree = ast.parse(source)
        functions = {node.name: node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)}
        forbidden = {'began_ticks', 'added', 'st_mtime', 'getmtime', 'strftime', 'gmtime', 'uptime', 'ts'}
        for name in ('settle_blockers', 'settle_attempt'):
            node = functions[name]
            used = {n.id for n in ast.walk(node) if isinstance(n, ast.Name)} | {n.attr for n in ast.walk(node) if isinstance(n, ast.Attribute)}
            used |= {n.value for n in ast.walk(node) if isinstance(n, ast.Constant) and isinstance(n.value, str)}
            self.assertEqual(used & forbidden, set(), name + ' reads a time')
            from_time = {n.attr for n in ast.walk(node) if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name) and n.value.id == 'time'}
            self.assertLessEqual(from_time, {'monotonic'}, name + ' uses the clock for more than the scan deadline')
        sites = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'settle_attempt']
        self.assertEqual(len(sites), 1, 'one call site: the verb itself')
        guards = [n for n in ast.walk(tree) if isinstance(n, ast.If) and "args.op == 'settle'" in ast.get_source_segment(source, n.test)
                  and sites[0] in list(ast.walk(n))]
        self.assertTrue(guards, 'the one call site is the settle verb\'s own branch (not ack, reconcile or any other op)')
        pattern = re.compile(r'''(?:\bruntime|fleet_runtime\.py)["']?\s+["']?settle\b''')
        allowed = {ENTRYPOINTS / 'scripts/lib/fleet_runtime.py', ENTRYPOINTS / 'scripts/lib/test-fleet-runtime.py'}
        callers, hints = [], []
        # Sources only: the files git lists (tracked, or untracked and not ignored). A compiled or cached file that a run writes into the tree is ignored, so it is never read.
        listed = subprocess.run(['git', '-C', str(ENTRYPOINTS), 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', 'scripts', 'marketplace', 'plugins'],
                                capture_output=True, check=True).stdout.decode().split('\0')
        for rel in filter(None, listed):
            path = ENTRYPOINTS / rel
            if path in allowed or {'node_modules', '.git', 'dist'} & set(Path(rel).parts) or path.is_symlink() or not path.is_file() or path.stat().st_size > 4_000_000:
                continue
            try:
                text = path.read_text(errors='ignore')
            except OSError:
                continue
            if 'settle_hint' in text:
                hints.append(str(path))
            for number, line in enumerate(text.splitlines(), 1):
                if pattern.search(line) and not (path.name == 'fleet-manifest.sh' and line.lstrip().startswith('#')):
                    callers.append('%s:%d' % (path, number))
        self.assertEqual(callers, [], 'nothing calls the settle verb: it is typed by the chief or the operator')
        self.assertEqual(hints, [], 'the hint is text for the chief: no code reads it')
        header = (ENTRYPOINTS / 'scripts/handover/chief-kit/fleet-manifest.sh').read_text().split('\n', 120)[:120]
        text = '\n'.join(header)
        self.assertIn('runtime settle', text)
        self.assertIn('attempt settle', text)
        self.assertRegex(text, r'manifest row only')

    # Review follow-ups. A launch that has not become the named session yet, the reason gate, and rows for the mutants the review kept alive.
    def carrier(self, variable='WORKER_SESSION_ATTEMPT_ID', value='one', argument=None):
        """A real child process of another name that carries the attempt id in its environment, or as an argument."""
        env = dict(self.env)
        if variable:
            env[variable] = value
        p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'] + ([argument] if argument else []), env=env)
        self.addCleanup(lambda: (p.terminate(), p.wait(timeout=5)) if p.poll() is None else None)
        time.sleep(.2)
        return p

    def opaque(self, name):
        """A process of this user whose environment cannot be read (not dumpable) and whose argument names `name`."""
        code = 'import ctypes,time; ctypes.CDLL(None).prctl(4,0,0,0,0); time.sleep(30)'
        p = subprocess.Popen([sys.executable, '-c', code, '-n', name], env=dict(self.env, WORKER_SESSION_ATTEMPT_ID='one'))
        self.addCleanup(lambda: (p.terminate(), p.wait(timeout=5)) if p.poll() is None else None)
        time.sleep(.2)
        return p

    def settle_hint_of(self, aid='one'):
        return next(r for r in json.loads(self.rt('ack').stdout)['unknown'] if r['attempt_id'] == aid)['settle_hint']

    def test_a_process_of_any_name_carrying_the_attempt_id_blocks_settle_and_the_hint(self):
        for variable, argument in (('WORKER_SESSION_ATTEMPT_ID', None), ('FLEET_LAUNCH_ATTEMPT', None), (None, 'WORKER_SESSION_ATTEMPT_ID=one')):
            self.setUp()
            self.active()
            self.stuck()
            self.forge(start='0')
            self.assertTrue(self.settle_hint_of()['settleable'])  # nothing carries it yet
            carrier = self.carrier(variable, argument=argument)
            self.refused_settle('carries the attempt id')
            self.assertIn('one', self.anchor_attempts())
            hint = self.settle_hint_of()
            self.assertFalse(hint['settleable'])
            self.assertIn('carries the attempt id', hint['text'])
            self.assertNotIn('fleet-manifest.sh runtime settle', hint['text'])
            self.stop(carrier)
            self.assertTrue(self.settle_hint_of()['settleable'])
            self.settle()  # the process is gone: nothing carries the id, so the existing proof stands
            self.assertEqual(self.anchor_attempts(), {})

    def test_a_late_process_after_a_dead_launcher_leaves_the_attempt_and_no_second_begin(self):
        self.active()
        self.stuck()
        self.forge(start='0')
        late = self.carrier()
        self.refused_settle('carries the attempt id')
        p = self.rt('begin', aid='two', ok=False)
        self.assertIn('family already owns', p.stderr)
        self.assertEqual(list(self.anchor_attempts()), ['one'])
        self.stop(late)
        self.settle()
        self.call('add', self.m, self.doc, '--lane', 'native', '--pending')
        self.rt('begin', aid='two')
        self.assertEqual(list(self.anchor_attempts()), ['two'])

    def test_a_process_of_this_user_that_could_be_the_launch_and_cannot_be_read_blocks_settle(self):
        self.active()
        self.stuck()
        self.forge(start='0')
        opaque = self.opaque(self.doc.stem)
        self.refused_settle('cannot be read')
        self.assertFalse(self.settle_hint_of()['settleable'])
        self.stop(opaque)
        self.settle()

    def test_an_unreadable_process_that_names_neither_the_attempt_nor_its_doc_is_not_a_candidate(self):
        self.active()
        self.stuck()
        self.forge(start='0')
        self.opaque('an-unrelated-process')
        self.settle()  # the rule: same user and the name or the doc in the command line; anything else cannot be told from the rest of the desktop

    def test_a_live_matching_session_blocks_settle_and_the_hint_whatever_its_start_time(self):
        for began in (0, 10 ** 13):
            self.setUp()
            self.active()
            self.stuck()
            self.forge(start='0')
            anchor = self.bucket / 'fleet-control.json'
            data = json.loads(anchor.read_text())
            data['attempts']['one']['began_ticks'] = began
            anchor.write_text(json.dumps(data))
            session = self.named_session(attempt_id='one')
            self.refused_settle('a session may exist')  # the session blocker itself, not only the new one for a process carrying the id
            self.refused_settle('a session may exist', aid='one')
            phase = self.anchor_attempts()['one']['phase']
            self.assertEqual(phase, 'committed')
            if began:
                hint = self.settle_hint_of()
                self.assertFalse(hint['settleable'])
                self.assertIn('a session may exist', hint['text'])
            else:
                ack = json.loads(self.rt('ack').stdout)
                self.assertEqual([r['attempt_id'] for r in ack['launched']], ['one'])
            self.stop(session)

    def test_an_earlier_launched_refused_or_complete_receipt_blocks_settle_though_the_last_row_is_indeterminate(self):
        for outcome in ('launched', 'refused', 'complete'):
            self.setUp()
            history = self.bucket / '.himmel/launch-refusals.jsonl'
            self.active()
            self.stuck()
            self.forge(start='0')
            base = self.history_rows('one')[0]
            with history.open('a') as stream:
                stream.write(json.dumps(dict(base, outcome=outcome)) + '\n')
                stream.write(json.dumps(dict(base, outcome='indeterminate', source='headed-arm-worker')) + '\n')
            self.refused_settle('receipt')
            self.assertIn('one', self.anchor_attempts(), outcome)

    def test_settle_releases_only_its_own_reservation_not_every_reservation_of_the_doc_name(self):
        self.active()
        self.stuck()
        self.forge(start='0')
        other = self.bucket / 'slots' / 'a-reservation-of-another-attempt'
        other.mkdir()
        (other / 'name').write_text(self.doc.stem + '\n')
        (other / 'managed.json').write_text(json.dumps({'attempt_id': 'another-attempt', 'owner': {'pid': 1}}))
        self.settle()
        self.assertFalse((self.bucket / 'slots' / self.doc.stem).exists())
        self.assertEqual(sorted(p.name for p in other.iterdir()), ['managed.json', 'name'])

    def test_a_worker_state_helper_that_fails_reads_unknown_never_wrapped(self):
        runtime = self.runtime_module()
        broken = self.bucket / 'broken-lib'
        broken.mkdir()
        doc = self.plain_doc('TEST-20-N1-wrapped.md', '- 10:00 WRAPPED - done')  # reads wrapped whenever the helper works
        with self.batch_env():
            self.assertEqual(runtime.worker_state(str(doc)), 'wrapped')
            (broken / 'ticket-status.sh').write_text('exit 1\n')
            with mock.patch.object(runtime, 'LIB', broken):
                self.assertEqual(runtime.worker_state(str(doc)), 'unknown')
                self.assertEqual(runtime.WorkerStates()(str(doc)), 'unknown')
            (broken / 'ticket-status.sh').write_text('sleep 5\n')
            with mock.patch.object(runtime, 'LIB', broken):
                self.assertEqual(runtime.worker_state(str(doc), 0.2), 'unknown')  # a timeout
            with mock.patch.dict(os.environ, {'PATH': '/nonexistent'}):
                self.assertEqual(runtime.worker_state(str(doc)), 'unknown')  # no shell to run it at all

    def test_the_memo_keeps_two_docs_with_one_basename_apart(self):
        runtime = self.runtime_module()
        first, second = self.bucket / 'dir-one', self.bucket / 'dir-two'
        first.mkdir()
        second.mkdir()
        (first / 'TEST-30-N1-same.md').write_text('# w\n- 10:00 WRAPPED - done\n')
        (second / 'TEST-30-N1-same.md').write_text('# w\n')
        with self.batch_env():
            states = runtime.WorkerStates()
            one, two = str(first / 'TEST-30-N1-same.md'), str(second / 'TEST-30-N1-same.md')
            self.assertEqual((states(one), states(two)), ('wrapped', 'unknown'))
            self.assertEqual((states(two), states(one)), ('unknown', 'wrapped'))
            self.assertEqual(runtime.WorkerStates()(two), 'unknown')

    def test_a_registration_stamped_the_same_second_as_its_receipt_is_settled_by_it(self):
        runtime = self.runtime_module()
        receipt = {'outcome': 'refused', 'ts': '2026-11-18T10:00:00Z'}
        self.assertTrue(runtime.settles(receipt, {'registration': 'pending', 'added': '2026-11-18T10:00:00Z'}))  # the tie
        self.assertTrue(runtime.settles(receipt, {'registration': 'pending', 'added': '2026-11-18T09:59:59Z'}))
        self.assertFalse(runtime.settles(receipt, {'registration': 'pending', 'added': '2026-11-18T10:00:01Z'}))
        self.assertTrue(runtime.settles(receipt, {'registration': 'pending'}))
        self.assertFalse(runtime.settles(dict(receipt, outcome='launched'), {'registration': 'pending', 'added': '2026-11-18T09:00:00Z'}))

    def test_the_reason_gate_refuses_a_bracketed_placeholder_and_the_printed_hint_is_not_a_ready_command(self):
        import shlex
        self.active()
        self.stuck()
        self.forge(start='0')
        for placeholder in ('<why>', '<type why>', '[why]', '{why}', ' <why> '):
            self.refused_settle('--reason', reason=placeholder)
        self.assertIn('one', self.anchor_attempts())
        text = self.settle_hint_of()['text']
        self.assertIn('replace', text)
        argv = shlex.split(text.split('type: ', 1)[1])
        argv[0] = str(WRITER)
        p = subprocess.run(['bash', *argv], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('settle refused', p.stderr)
        self.assertIn('one', self.anchor_attempts())
        self.settle(reason='[ops] the launcher is gone and nothing started')  # a real reason that only begins with a bracket
        self.assertEqual(self.anchor_attempts(), {})

    def test_a_scan_that_did_not_finish_is_not_proof_and_the_receipt_records_that_no_process_carried_the_id(self):
        runtime = self.runtime_module()
        self.active()
        self.stuck()
        self.forge(start='0')
        record = self.anchor_attempts()['one']
        with self.batch_env():
            self.assertEqual(runtime.settle_blockers(record, set(), time.monotonic() + 30), [])
            blockers = runtime.settle_blockers(record, set(), time.monotonic() - 1)  # the deadline has passed: nothing was read
            self.assertIn('the process scan did not finish', blockers)
        self.settle()
        self.assertEqual(self.history_rows('one')[-1]['evidence']['carriers'], 'none')

    def test_an_unreadable_process_is_a_candidate_only_when_it_is_this_users(self):
        runtime = self.runtime_module()
        self.active()
        self.stuck()
        self.forge(start='0')
        record = self.anchor_attempts()['one']
        opaque = self.opaque(self.doc.stem)
        carrying, unreadable, complete = runtime.launch_candidates(record, time.monotonic() + 30)
        self.assertEqual([pid for pid, _ in unreadable], [str(opaque.pid)])
        with mock.patch.object(runtime.os, 'getuid', return_value=os.getuid() + 1):  # as if the unreadable process belonged to someone else
            self.assertEqual(runtime.launch_candidates(record, time.monotonic() + 30)[1], [])
        self.stop(opaque)

    def bundle_docs(self, title):
        first, second = self.bucket / 'HIMMEL-101-N1-worker.md', self.bucket / 'HIMMEL-102-N2-worker.md'
        first.write_text(title + '\n')
        second.write_text('# HIMMEL-102 worker\n')
        for doc in (first, second):
            self.call('add', self.m, doc, '--lane', 'native', '--pending')
        return first, second

    def test_a_second_doc_for_a_ticket_a_bundle_h1_names_by_shorthand_is_refused(self):
        self.active()
        first, second = self.bundle_docs('# HIMMEL-101 / 102 — bundle')
        self.assertEqual(json.loads(self.rt('begin', aid='first', doc=first).stdout)['keys'], ['HIMMEL-101', 'HIMMEL-102'])
        p = self.rt('begin', aid='second', doc=second, ok=False)
        self.assertIn('family already owns worker or ticket', p.stderr)
        self.assertEqual(list(self.anchor_attempts()), ['first'])

    def test_a_second_doc_for_a_ticket_a_bundle_h1_writes_out_in_full_is_refused(self):
        self.active()
        first, second = self.bundle_docs('# HIMMEL-101 / HIMMEL-102 — bundle')
        self.rt('begin', aid='first', doc=first)
        p = self.rt('begin', aid='second', doc=second, ok=False)
        self.assertIn('family already owns worker or ticket', p.stderr)
        self.assertEqual(list(self.anchor_attempts()), ['first'])

    def dispatcher_title_expression(self, runtime):
        import re
        source = (ENTRYPOINTS / 'scripts/handover/chief-kit/next-dispatchable.sh').read_text()
        self.assertTrue(re.search(r'(?m)^from fleet_runtime import .*\btitle_keys as fr_title_keys\b', source),
                        'next-dispatchable.sh does not import title_keys from fleet_runtime')
        self.assertFalse('TITLE_KEY_RE' in source, 'next-dispatchable.sh keeps its own TITLE_KEY_RE')
        lines = source.splitlines()
        start = next(number for number, line in enumerate(lines) if line.startswith('def title_keys('))
        block = [lines[start]]
        for line in lines[start + 1:]:
            if line and not line[0].isspace():
                break
            block.append(line)
        namespace = {'fr_title_keys': runtime.title_keys}
        exec('\n'.join(block), namespace)
        return namespace

    def test_the_runtime_reads_a_doc_title_as_the_dispatcher_does(self):
        runtime = self.runtime_module()
        dispatcher = self.dispatcher_title_expression(runtime)
        titles = ['HIMMEL-101 / 102 — bundle', 'HIMMEL-101 + 102', 'HIMMEL-101 (+102, +103)', 'HIMMEL-101, 102 & 103',
                  'HIMMEL-101 / HIMMEL-102', 'HIMMEL-101 — worker', 'HIMMEL-101 worker 7', 'worker 7 — HIMMEL-101 / 2']
        self.assertIn('HIMMEL-103', dispatcher['title_keys'](['# ' + titles[2]]))
        for number, title in enumerate(titles):
            doc = self.bucket / ('HIMMEL-900-N%d-parity.md' % number)
            doc.write_text('# ' + title + '\n')
            expected = sorted({'HIMMEL-900', *dispatcher['title_keys'](['# ' + title])})
            self.assertEqual(runtime.worker_keys(doc), expected, title)

    def test_a_brief_file_name_year_tail_is_not_a_ticket_key(self):
        runtime = self.runtime_module()
        for name, expected in (('HIMMEL-10441-part1-vm-proof-RESUME-2026-11-22.md', ['HIMMEL-10441']),
                               ('HIMMEL-6497-N2809b-s1-relay-fast-path-RESUME-2026-10-19.md', ['HIMMEL-6497'])):
            self.assertEqual(runtime.worker_keys(self.bucket / 'absent' / name), expected, name)

    def test_a_sibling_row_named_resume_year_does_not_refuse_an_unrelated_brief(self):
        self.active()
        old = self.bucket / 'HIMMEL-6497-N2809b-s1-relay-fast-path-RESUME-2026-10-19.md'
        old.write_text('# worker\n')
        (self.bucket / 'old.fleet.json').write_text(json.dumps({'schema': 1, 'workers': [{'doc': str(old), 'label': 'N1'}]}))
        doc = self.bucket / 'HIMMEL-10441-part1-vm-proof-RESUME-2026-11-22.md'
        doc.write_text('# worker\n')
        self.call('runtime', 'admit', '--doc', doc, '--manifest', self.m, '--name', doc.stem)

    def begin_beside_old_sibling(self, key, empty=None, results='- 09:00 LIVE\n', session=True, lock=None, ok=False):
        self.active()
        old, new = self.bucket / 'HIMMEL-101-N1-old.md', self.bucket / 'HIMMEL-101-N2-new.md'
        old.write_text('# HIMMEL-101 old worker\n' + results)
        new.write_text('# HIMMEL-101 new worker\n')
        sibling = {'schema': 1, key: [dict(doc=str(old), label='N1', added='2026-11-01T00:00:00Z', lane='native')]}
        if empty:
            sibling[empty] = []
        (self.bucket / 'old.fleet.json').write_text(json.dumps(sibling))
        self.call('add', self.m, new, '--lane', 'native', '--pending')
        saved = self.env
        if lock:
            self.env = dict(self.env, TICKET_STATUS_QUEUE_LOCK=self.stub('queue-lock-' + lock, 'exit %d' % {'held': 11, 'free': 0}[lock]))
        live = None
        if session:
            code = 'import ctypes,time; ctypes.CDLL(None).prctl(15,b"claude",0,0,0); time.sleep(30)'
            live = subprocess.Popen(['claude', '-c', code], executable=sys.executable, env=dict(self.env, WORKER_SESSION_DOC=str(old)))
            time.sleep(.2)
        try:
            return self.rt('begin', aid='n1', doc=new, ok=ok)
        finally:
            self.env = saved
            if live:
                live.terminate()
                live.wait(timeout=5)

    def refused_beside_old_sibling(self, key, empty=None, **kwargs):
        p = self.begin_beside_old_sibling(key, empty, **kwargs)
        self.assertIn('unknown legacy family ownership', p.stderr)
        self.assertEqual(self.anchor_attempts(), {})

    def test_begin_is_refused_beside_a_live_row_a_workers_sibling_holds(self):
        self.refused_beside_old_sibling('workers')

    def test_begin_is_refused_beside_a_live_row_a_legs_sibling_holds(self):
        self.refused_beside_old_sibling('legs')

    def test_begin_is_refused_beside_a_live_legs_row_when_the_sibling_also_has_an_empty_workers(self):
        self.refused_beside_old_sibling('legs', empty='workers')

    def test_begin_is_refused_beside_a_live_workers_row_when_the_sibling_also_has_an_empty_legs(self):
        self.refused_beside_old_sibling('workers', empty='legs')

    def test_begin_is_admitted_beside_an_abandoned_row(self):
        self.begin_beside_old_sibling('workers', results='- 09:00 LIVE\n- 11:40 FINDING — a question\n- 12:30 LIVE\n',
                                      session=False, ok=True)
        self.assertEqual(list(self.anchor_attempts()), ['n1'])

    def test_begin_is_refused_beside_an_unwrapped_row_whose_lock_is_held(self):
        self.refused_beside_old_sibling('workers', session=False, lock='held')

    def test_begin_is_refused_beside_an_unwrapped_row_with_no_marker(self):
        self.refused_beside_old_sibling('workers', results='', session=False, lock='free')

    def test_begin_is_admitted_beside_a_row_that_wrapped_before_a_succession_note(self):
        self.begin_beside_old_sibling('workers', results='- 09:00 LIVE\n- 22:30 WRAPPED — merged\n'
                                      '- 09:00 bus-adopt: adopted: d console AP → AQ [via anchor]\n'
                                      '- 09:00 SUCCESSION accepted: AQ replaces AP\n', session=False, lock='free', ok=True)
        self.assertEqual(list(self.anchor_attempts()), ['n1'])

    def test_a_succession_note_after_an_end_marker_still_reads_ended(self):
        runtime = self.runtime_module()
        doc = self.bucket / 'ended.md'
        for lines, ended in ((['- 22:30 WRAPPED', '- 09:00 SUCCESSION accepted: AQ replaces AP'], True),
                             (['- 22:30 HALTED', '- 09:00 bus-adopt: adopted: d', '- 09:00 SUCCESSION accepted: AQ replaces AP'], True),
                             (['- 22:30 LIVE', '- 09:00 SUCCESSION accepted: AQ replaces AP'], False),
                             (['- 09:00 SUCCESSION accepted: AQ replaces AP'], False),
                             (['- 22:30 WRAPPED', '- 09:00 SUCCESSION accepted: AQ replaces AP', '- 09:10 LIVE'], False),
                             ([], True)):
            doc.write_text('\n'.join(['# d'] + lines) + '\n')
            self.assertEqual(runtime.reads_ended(doc), ended, lines)

    def test_a_damaged_owner_reads_unknown_and_only_an_exact_identity_reads_dead(self):
        runtime = self.runtime_module()
        owner = runtime.identity(os.getpid())
        self.assertEqual(runtime.process_state(owner), 'live')
        self.assertEqual(runtime.process_state(dict(owner, start='0')), 'dead')
        damaged = {'no start': {k: v for k, v in owner.items() if k != 'start'},
                   'no pid': {k: v for k, v in owner.items() if k != 'pid'},
                   'an extra field': dict(owner, extra='x'),
                   'a pid that is a string': dict(owner, pid=str(owner['pid'])),
                   'a pid that is a bool': dict(owner, pid=True),
                   'a start that is a number': dict(owner, start=int(owner['start'])),
                   'not a mapping': None}
        for name, value in damaged.items():
            self.assertEqual(runtime.process_state(value), 'unknown', name)

    def pending_attempt_with_a_reservation(self):
        self.active()
        self.rt('begin')
        env = dict(self.launch_env(), FLEET_LAUNCH_ATTEMPT='one')
        self.entry('scripts/lib/usage-preflight.sh', env=env)
        slot = self.bucket / 'slots' / self.doc.stem
        self.assertTrue((slot / 'managed.json').is_file())
        return slot

    def test_a_pending_attempt_whose_owner_lost_a_field_is_neither_refused_nor_released(self):
        slot = self.pending_attempt_with_a_reservation()
        anchor = self.bucket / 'fleet-control.json'
        data = json.loads(anchor.read_text())
        data['attempts']['one']['owner'].pop('start')
        anchor.write_text(json.dumps(data))
        ack = json.loads(self.rt('ack').stdout)
        self.assertEqual([r['attempt_id'] for r in ack['unknown']], ['one'])
        self.assertFalse(ack['quiescent'])
        self.assertEqual(list(self.anchor_attempts()), ['one'])
        self.assertTrue((slot / 'managed.json').is_file())
        self.assertEqual([row['outcome'] for row in self.history_rows('one')], ['attempt-started'])
        self.rt('begin', aid='second', ok=False)

    def test_a_pending_attempt_whose_launcher_lives_stays_pending(self):
        slot = self.pending_attempt_with_a_reservation()
        ack = json.loads(self.rt('ack').stdout)
        self.assertEqual([r['attempt_id'] for r in ack['in_flight']], ['one'])
        self.assertEqual(ack['unknown'], [])
        self.assertEqual(self.anchor_attempts()['one']['phase'], 'pending')
        self.assertTrue((slot / 'managed.json').is_file())

    def launched_line(self):
        return json.dumps(dict(v=2, kind='launch-attempt', attempt_id='one', name=self.doc.stem, doc=str(self.doc), outcome='launched'))

    def settle_after_history_tail(self, tail):
        self.active()
        self.stuck()
        self.forge(start='0')
        history = self.bucket / '.himmel/launch-refusals.jsonl'
        intact = history.read_text()
        history.write_text(intact + tail)
        return history, intact

    def test_settle_refuses_while_the_launched_receipt_line_is_torn(self):
        for tail in (self.launched_line()[:60], self.launched_line()[:60] + '\n'):
            self.setUp()
            history, intact = self.settle_after_history_tail(tail)
            self.refused_settle('history has a line that cannot be read')
            self.assertEqual(history.read_text(), intact + tail)
            self.assertEqual(list(self.anchor_attempts()), ['one'])
            self.assertTrue((self.bucket / 'slots' / self.doc.stem).is_dir())
            hint = self.settle_hint_of()
            self.assertFalse(hint['settleable'])
            self.assertIn('history has a line that cannot be read', hint['text'])
            history.write_text(intact)
            self.settle()
            self.assertEqual(self.anchor_attempts(), {})

    def test_an_intact_launched_line_refuses_settle_as_a_launched_receipt(self):
        self.settle_after_history_tail(self.launched_line() + '\n')
        self.refused_settle('a launched receipt exists')

    def test_a_blank_history_line_is_not_a_torn_receipt(self):
        self.settle_after_history_tail('\n')
        self.settle()
        self.assertEqual(self.anchor_attempts(), {})

    def test_a_receipt_after_a_torn_tail_starts_its_own_line(self):
        self.active()
        self.stuck()
        history = self.bucket / '.himmel/launch-refusals.jsonl'
        torn = self.launched_line()[:60]
        with history.open('a') as stream:
            stream.write(torn)
        self.rt('outcome', extra=('--phase', 'unknown'))
        lines = history.read_text().splitlines()
        self.assertEqual(json.loads(lines[0])['outcome'], 'attempt-started')
        self.assertEqual(lines[-2], torn)
        self.assertEqual(json.loads(lines[-1])['outcome'], 'indeterminate')

    def test_a_receipt_after_a_complete_tail_adds_no_blank_line(self):
        self.active()
        self.stuck()
        self.rt('outcome', extra=('--phase', 'unknown'))
        lines = (self.bucket / '.himmel/launch-refusals.jsonl').read_text().split('\n')
        self.assertEqual([json.loads(line)['outcome'] for line in lines[:-1]], ['attempt-started', 'indeterminate'])
        self.assertEqual(lines[-1], '')

    def test_settle_refuses_when_a_torn_line_sits_in_the_middle_of_the_history(self):
        other = json.dumps(dict(v=2, kind='launch-attempt', attempt_id='other', name='other', doc='/nowhere', outcome='attempt-started'))
        history, intact = self.settle_after_history_tail(self.launched_line()[:60] + '\n' + other + '\n')
        self.assertEqual(history.read_text().splitlines()[-1], other)
        self.refused_settle('history has a line that cannot be read')
        self.assertEqual(list(self.anchor_attempts()), ['one'])

    def test_settle_refuses_when_a_later_receipt_leaves_the_torn_line_in_the_middle(self):
        self.active()
        self.stuck()
        history = self.bucket / '.himmel/launch-refusals.jsonl'
        with history.open('a') as stream:
            stream.write(self.launched_line()[:60])
        self.rt('outcome', extra=('--phase', 'unknown'))
        self.assertEqual(json.loads(history.read_text().splitlines()[-1])['outcome'], 'indeterminate')
        self.forge(start='0')
        self.refused_settle('history has a line that cannot be read')
        self.assertEqual(list(self.anchor_attempts()), ['one'])

    def run_supervised(self, *command):
        argv = ['python3', '-I', str(self.anchorless_tree() / 'scripts/lib/fleet_runtime.py'), 'run', '--doc', str(self.doc), '--manifest', str(self.m),
                '--name', self.doc.stem, '--', *command]
        return subprocess.run(argv, env=self.launch_env(), capture_output=True, text=True, timeout=60)

    def history_all(self):
        return [json.loads(line) for line in (self.bucket / '.himmel/launch-refusals.jsonl').read_text().splitlines()]

    def test_a_program_that_cannot_be_spawned_is_refused_and_released(self):
        self.active()
        p = self.run_supervised(str(self.bucket / 'no-such-program'))
        self.assertEqual(p.returncode, 10, p.stderr)
        self.assertEqual(self.anchor_attempts(), {})
        self.assertFalse((self.bucket / 'slots' / self.doc.stem).exists())
        rows = self.history_all()
        self.assertEqual([row['outcome'] for row in rows], ['attempt-started', 'refused'])
        self.assertEqual(rows[-1]['cause'], 'spawn-failed')
        self.assertEqual(json.loads(self.m.read_text())['workers'], [])
        self.call('add', self.m, self.doc, '--lane', 'native', '--pending')
        self.assertEqual(self.run_supervised('/bin/true').returncode, 0)

    def test_a_program_that_starts_and_fails_is_complete_never_refused(self):
        self.active()
        p = self.run_supervised('bash', '-c', 'exit 3')
        self.assertEqual(p.returncode, 3, p.stderr)
        self.assertEqual([row['outcome'] for row in self.history_all()], ['attempt-started', 'complete'])
        self.assertEqual(self.anchor_attempts(), {})
        self.assertFalse((self.bucket / 'slots' / self.doc.stem).exists())

    def test_a_plain_refused_outcome_cannot_free_a_committed_attempt(self):
        self.active()
        self.stuck()
        anchor, history, slot = self.bucket / 'fleet-control.json', self.bucket / '.himmel/launch-refusals.jsonl', self.bucket / 'slots' / self.doc.stem
        before = (anchor.read_text(), self.m.read_text(), history.read_text())
        p = self.rt('outcome', extra=('--phase', 'refused'), ok=False)
        self.assertIn('committed attempt needs affirmative terminal evidence', p.stderr)
        self.assertEqual((anchor.read_text(), self.m.read_text(), history.read_text()), before)
        self.assertEqual(self.anchor_attempts()['one']['phase'], 'committed')
        self.assertTrue((slot / 'managed.json').is_file())
        for flag in ('--spawn-failed', '--spawn_failed'):
            p = self.rt('outcome', extra=('--phase', 'refused', flag), ok=False)
            self.assertIn('unrecognized arguments', p.stderr)
        self.assertEqual((anchor.read_text(), self.m.read_text(), history.read_text()), before)

    def sibling_owners(self, outcome, *lines, pending=True):
        doc = self.bucket / 'HIMMEL-111-N1-resumed.md'
        doc.write_text('# worker\n' + ''.join(line + '\n' for line in lines))
        row = dict(doc=str(doc), label='P1', added='2026-11-18T08:00:00Z', lane='native')
        if pending:
            row['registration'] = 'pending'
        sibling = self.bucket / 'sibling.fleet.json'
        data = json.loads(self.m.read_text())
        data['workers'] = [row]
        sibling.write_text(json.dumps(data))
        if outcome:
            history = self.bucket / '.himmel/launch-refusals.jsonl'
            history.parent.mkdir(exist_ok=True)
            history.write_text(json.dumps(dict(v=2, kind='launch-attempt', ts='2026-11-18T09:00:00Z', attempt_id='r2', name=doc.stem,
                                               doc=str(doc), family=data['control']['family'], outcome=outcome)) + '\n')
        return [Path(owner['doc']).name for owner in json.loads(self.call('runtime', 'owners', '--manifest', sibling).stdout)]

    def test_a_complete_receipt_does_not_hide_a_pending_row_whose_doc_was_resumed(self):
        self.assertEqual(self.sibling_owners('complete', '- 10:00 WRAPPED - done', '- 12:30 RESUMED - by hand'), ['HIMMEL-111-N1-resumed.md'])

    def test_a_row_that_is_not_pending_stays_owned_when_its_doc_was_resumed(self):
        self.assertEqual(self.sibling_owners('', '- 10:00 WRAPPED - done', '- 12:30 RESUMED - by hand', pending=False), ['HIMMEL-111-N1-resumed.md'])

    def test_a_terminal_receipt_does_not_hide_a_pending_row_whose_newest_marker_is_not_an_end_marker(self):
        for outcome, lines in (('refused', ['- 11:00 LIVE - worker started']), ('complete', ['- 10:00 WRAPPED - done', '- 11:30 PARKED-USAGE - usage limit'])):
            self.assertEqual(self.sibling_owners(outcome, *lines), ['HIMMEL-111-N1-resumed.md'], outcome + ' ' + lines[-1])

    def test_a_terminal_receipt_releases_a_pending_row_whose_newest_marker_is_absent_or_an_end_marker(self):
        for outcome, lines in (('complete', ['- 10:00 LIVE - working', '- 12:00 WRAPPED - done']), ('complete', ['- 10:00 HALTED - stopped']),
                               ('refused', []), ('refused', ['- 12:00 WRAPPED - done'])):
            self.assertEqual(self.sibling_owners(outcome, *lines), [], outcome + ' ' + str(lines))

    def test_a_stale_copied_row_goes_while_the_live_replacement_and_its_reservation_stay(self):
        self.active()
        self.rt('begin')
        stale = json.loads(self.m.read_text())['workers'][0]
        self.assertEqual(stale['attempt']['attempt_id'], 'one')
        self.rt('outcome', extra=('--phase', 'refused'))
        self.call('add', self.m, self.doc, '--lane', 'native', '--pending')
        self.rt('begin', aid='two')
        self.entry('scripts/lib/usage-preflight.sh', env=dict(self.launch_env(), FLEET_LAUNCH_ATTEMPT='two'))
        slot = self.bucket / 'slots' / self.doc.stem

        def copy_stale_row():
            data = json.loads(self.m.read_text())
            data['workers'].insert(0, stale)
            self.m.write_text(json.dumps(data))

        def row_attempts():
            return [row.get('attempt', {}).get('attempt_id') for row in json.loads(self.m.read_text())['workers']]
        copy_stale_row()
        self.assertEqual(row_attempts(), ['one', 'two'])
        self.rt('ack', aid='two')
        self.assertEqual(row_attempts(), ['two'])
        self.assertEqual(list(self.anchor_attempts()), ['two'])
        self.assertEqual(json.loads((slot / 'managed.json').read_text())['attempt_id'], 'two')
        copy_stale_row()
        self.rt('outcome', aid='two', extra=('--phase', 'refused'))
        self.assertEqual(row_attempts(), ['one'])
        self.assertFalse(slot.exists())
        self.rt('ack', aid='two')
        self.assertEqual(row_attempts(), [])


if __name__ == '__main__':
    unittest.main()
