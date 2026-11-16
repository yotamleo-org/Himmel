#!/usr/bin/env python3
"""Offline integration checks for the public fleet writer and launch gates."""
import json
import os
from pathlib import Path
import subprocess
import time
import sys
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WRITER = ROOT / 'scripts/handover/chief-kit/fleet-manifest.sh'
ENTRYPOINTS = Path(os.environ.get('FLEET_RUNTIME_ENTRYPOINTS', ROOT))


class Runtime(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bucket = Path(self.tmp.name)
        if os.environ.get('FLEET_RUNTIME_EVIDENCE'):
            self.addCleanup(self.save_evidence)
        self.env = dict(os.environ, HOME=str(self.bucket), HIMMEL_FLEET_SLOTS=str(self.bucket / 'slots'))
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
        for path in [*self.bucket.glob('*.json'), self.bucket / 'entrypoints.jsonl',
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
        self.active()
        data = json.loads(self.m.read_text())
        data['workers'][0].pop('registration')
        self.m.write_text(json.dumps(data))
        self.rt('begin', ok=False)
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

    def entry(self, path, args=(), env=None):
        command = ['bash', str(ENTRYPOINTS / path), *map(str, args)]
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
        p = subprocess.Popen(['bash', str(ENTRYPOINTS / 'scripts/handover/headed-arm.sh'), self.doc.stem,
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
        command = ['python3', '-I', str(ROOT / 'scripts/lib/fleet_runtime.py'), 'run', '--doc', str(self.doc),
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
        self.assertNotIn('CASE-206', p.stdout)


if __name__ == '__main__':
    unittest.main()
