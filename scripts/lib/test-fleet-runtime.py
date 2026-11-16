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
            self.assertNotIn('CASE-201', p.stdout)
            self.assertIn('unverified', p.stderr)

    def real_census_env(self):
        env = self.launch_env()
        env.pop('FLEET_PS_CMD', None)
        env.pop('FLEET_PROC', None)
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
            p = subprocess.Popen([sys.executable, '-c', code, str(WRITER), str(doc), str(self.m), boundary],
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
            self.assertFalse((self.bucket / 'slots' / doc.stem).exists())
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
        command = ['python3', '-I', str(ROOT / 'scripts/lib/fleet_runtime.py'), 'run', '--doc', str(self.doc),
                   '--name', self.doc.stem, '--manifest', str(self.m), '--', 'bash', '-c',
                   'test -z "${FLEET_LAUNCH_ATTEMPT:-}" && test -n "$WORKER_SESSION_ATTEMPT_ID" && touch "$HOME/scheduled-ended"']
        for _ in range(2):
            p = subprocess.run(command, env=env, capture_output=True, text=True, timeout=15)
            self.record(command, p)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertTrue((self.bucket / 'scheduled-ended').exists())
            self.assertEqual(json.loads((self.bucket / 'fleet-control.json').read_text())['attempts'], {})
            self.assertFalse((self.bucket / 'slots' / self.doc.stem).exists())


if __name__ == '__main__':
    unittest.main()
