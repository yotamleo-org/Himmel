#!/usr/bin/env bash
# Offline git fixtures catch missed conflicts, false upgrades and flag-off I/O.
# Platform guard: no .ps1 twin, by design; the chief kit runs under bash.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 -I - "$HERE/chain-push-check.sh" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SUT = sys.argv.pop()


class PushCheck(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='chain-push-check-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        self.env.update(HOME=str(self.root), HIMMEL_CONFIG_DIR=str(self.root / 'config'),
                        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                        GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
        self.env.pop('HIMMEL_FLAGS_TSV', None)
        self.git('init', '-q', '-b', 'main')
        (self.repo / 'shared file').write_text('top\n' + 'middle\n' * 20 + 'bottom\n')
        (self.repo / 'other').write_text('base\n')
        self.git('add', 'shared file', 'other')
        self.git('commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD')
        self.local = self.commit('local', 'shared file', 'top', 'local')
        self.clean = self.commit('clean', 'shared file', 'bottom', 'clean')
        self.conflict = self.commit('conflict', 'shared file', 'top', 'conflict')
        self.disjoint = self.commit('disjoint', 'other', 'base', 'different')
        self.git('checkout', '-q', 'local')
        self.fixture = self.root / 'responses.json'
        self.fake = self.root / 'gh'
        self.fake.write_text('#!/usr/bin/env python3\n'
                             'import json, sys\n'
                             'from pathlib import Path\n'
                             'data = json.loads(Path(__file__).with_name("responses.json").read_text())\n'
                             'args = sys.argv[1:]\n'
                             'if args[:2] == ["pr", "list"]: print("42"); sys.exit(0)\n'
                             'if args[:2] == ["pr", "view"]: print("feat(handover): [HIMMEL-7711] fixture"); sys.exit(0)\n'
                             'if args[:2] == ["pr", "edit"]: sys.exit(0)\n'
                             'if args[:2] == ["repo", "view"]: print("fixture/repo"); sys.exit(0)\n'
                             'if len(args) == 4 and args[0] == "api" and args[2:] == ["--jq", ".head.sha"]:\n'
                             '    print(data[args[1]]); sys.exit(0)\n'
                             'if len(args) != 4 or args[0] != "api" or args[2:] != ["--paginate", "--slurp"]:\n'
                             '    sys.exit("unexpected gh arguments: " + repr(args))\n'
                             'if args[1] not in data: sys.exit("fixture API failure: " + args[1])\n'
                             'print(json.dumps(data[args[1]]))\n')
        self.fake.chmod(0o700)
        self.env['GH_CMD'] = str(self.fake)
        self.responses([])

    def git(self, *args):
        p = subprocess.run(['git', '-C', str(self.repo), *args], env=self.env,
                           text=True, capture_output=True, check=True)
        return p.stdout.strip()

    def commit(self, branch, file, old, new):
        self.git('checkout', '-qb', branch, self.base)
        path = self.repo / file
        path.write_text(path.read_text().replace(old, new))
        self.git('add', file)
        self.git('commit', '-qm', branch)
        return self.git('rev-parse', 'HEAD')

    def pr(self, number, sha, branch, filename='shared file', previous=None):
        row = {'filename': filename, 'status': 'modified'}
        if previous:
            row.update(status='renamed', previous_filename=previous)
        return ({'number': number, 'head': {'sha': sha, 'ref': branch,
                                          'repo': {'full_name': 'fixture/repo'}},
                 'base': {'ref': 'main'}}, row)

    def responses(self, prs):
        # One PR per page catches accidentally ignoring pagination.
        data = {'repos/fixture/repo/pulls?state=open&per_page=100': [[pr] for pr, _ in prs] or [[]]}
        for pr, file in prs:
            data['repos/fixture/repo/pulls/%d/files?per_page=100' % pr['number']] = [[], [file]]
            data['repos/fixture/repo/pulls/%d' % pr['number']] = pr['head']['sha']
        self.fixture.write_text(json.dumps(data))

    def check(self, flag='1', **env):
        e = dict(self.env, **env)
        if flag is None:
            e.pop('HIMMEL_FLAG_CHAIN_PUSH_CHECK', None)
        else:
            e['HIMMEL_FLAG_CHAIN_PUSH_CHECK'] = flag
        return subprocess.run(['bash', SUT, '--repo-dir', str(self.repo), '--repo', 'fixture/repo',
                               '--base', 'main'], env=e, text=True, capture_output=True)

    def test_conflict_upgrades_edge_and_preserves_dirty_worktree(self):
        self.responses([self.pr(10, self.conflict, 'conflict')])
        (self.repo / 'other').write_text('uncommitted\n')
        self.git('add', 'other')
        (self.repo / 'untracked').write_text('keep\n')
        before = (self.git('rev-parse', 'HEAD'), self.git('status', '--porcelain'),
                  self.git('diff', '--cached'), (self.repo / 'shared file').read_bytes())
        p = self.check()
        self.assertEqual(p.returncode, 1, p.stderr)
        self.assertIn('FINDING edge-upgraded 10', p.stdout)
        self.assertIn('H2', p.stdout)
        self.assertIn('shared file', p.stdout)
        after = (self.git('rev-parse', 'HEAD'), self.git('status', '--porcelain'),
                 self.git('diff', '--cached'), (self.repo / 'shared file').read_bytes())
        self.assertEqual(after, before)

    def test_clean_shared_file_is_not_an_upgrade(self):
        self.responses([self.pr(11, self.clean, 'clean')])
        p = self.check()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn('FINDING', p.stdout)

    def test_all_pages_checked_and_current_pr_skipped(self):
        self.responses([self.pr(1, self.conflict, 'local'), self.pr(11, self.clean, 'clean'),
                        self.pr(12, self.conflict, 'conflict'), self.pr(13, self.conflict, 'second')])
        p = self.check()
        self.assertEqual(p.returncode, 1, p.stderr)
        self.assertNotIn('edge-upgraded 1 ', p.stdout)
        self.assertIn('edge-upgraded 12 ', p.stdout)
        self.assertIn('edge-upgraded 13 ', p.stdout)

    def test_rename_previous_path_is_an_overlap(self):
        self.responses([self.pr(14, self.conflict, 'conflict', filename='renamed', previous='shared file')])
        p = self.check()
        self.assertEqual(p.returncode, 1, p.stderr)
        self.assertIn('FINDING edge-upgraded 14', p.stdout)

    def test_no_overlap_does_not_need_peer_object(self):
        self.responses([self.pr(15, 'f' * 40, 'disjoint', filename='other')])
        p = self.check()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn('FINDING', p.stdout)

    def test_default_and_explicit_off_do_not_read_git_or_github(self):
        self.fixture.unlink()
        for flag in (None, '0'):
            with self.subTest(flag=flag):
                p = self.check(flag, GIT_DIR=str(self.root / 'missing'))
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertNotIn('FINDING', p.stdout)

    def test_api_failure_is_not_a_clean_result(self):
        self.fixture.write_text('{}')
        p = self.check()
        self.assertEqual(p.returncode, 2, p.stderr)
        self.assertNotIn('FINDING', p.stdout)

    def test_file_api_failure_is_not_a_clean_result(self):
        self.responses([self.pr(10, self.conflict, 'conflict')])
        data = json.loads(self.fixture.read_text())
        del data['repos/fixture/repo/pulls/10/files?per_page=100']
        self.fixture.write_text(json.dumps(data))
        p = self.check()
        self.assertEqual(p.returncode, 2, p.stderr)

    def test_invalid_flag_is_an_error(self):
        self.assertEqual(self.check('maybe').returncode, 2)

    def test_missing_overlapping_head_is_not_clean(self):
        self.responses([self.pr(16, 'f' * 40, 'missing')])
        p = self.check()
        self.assertEqual(p.returncode, 2, p.stderr)
        self.assertIn('unavailable locally', p.stderr)

    def test_peer_push_during_file_read_is_not_clean(self):
        self.responses([self.pr(17, self.clean, 'moving', filename='other')])
        data = json.loads(self.fixture.read_text())
        data['repos/fixture/repo/pulls/17'] = self.conflict
        self.fixture.write_text(json.dumps(data))
        p = self.check()
        self.assertEqual(p.returncode, 2, p.stderr)
        self.assertIn('head changed', p.stderr)

    def test_later_read_failure_does_not_hide_found_conflict(self):
        self.responses([self.pr(10, self.conflict, 'conflict'), self.pr(18, self.clean, 'clean')])
        data = json.loads(self.fixture.read_text())
        del data['repos/fixture/repo/pulls/18/files?per_page=100']
        self.fixture.write_text(json.dumps(data))
        p = self.check()
        self.assertEqual(p.returncode, 2, p.stderr)
        self.assertIn('FINDING edge-upgraded 10', p.stdout)

    def test_worker_pr_open_surfaces_advisory_without_changing_publication(self):
        self.git('branch', '-m', 'feat/himmel-7711-local')
        self.git('remote', 'add', 'origin', 'https://github.com/fixture/repo.git')
        self.git('update-ref', 'refs/remotes/origin/main', self.base)
        self.git('update-ref', 'refs/remotes/origin/feat/himmel-7711-local', self.local)
        self.git('branch', '--set-upstream-to=origin/feat/himmel-7711-local')
        self.responses([self.pr(10, self.conflict, 'conflict')])
        title, body = self.root / 'title', self.root / 'body'
        title.write_text('feat(handover): [HIMMEL-7711] fixture\n')
        body.write_text('Fixture body\n')
        env = dict(self.env, FORGE='github', CR_APP='0', WORKER_SESSION_JIRA_STATUS='0',
                   JIRA_PROJECT_KEY='HIMMEL')
        worker = Path(SUT).parents[2] / 'lanes' / 'worker-pr-open.sh'
        for flag in ('0', '1'):
            with self.subTest(flag=flag):
                env['HIMMEL_FLAG_CHAIN_PUSH_CHECK'] = flag
                p = subprocess.run(['bash', str(worker), str(title), str(body)], cwd=self.repo,
                                   env=env, text=True, capture_output=True)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(p.stdout.strip(), 'PR 42 https://github.com/fixture/repo/pull/42 ' + self.local)
                if flag == '1':
                    self.assertIn('FINDING edge-upgraded 10', p.stderr)
                else:
                    self.assertNotIn('FINDING', p.stderr)


unittest.main(verbosity=2)
PY
