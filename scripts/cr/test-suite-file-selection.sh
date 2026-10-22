#!/usr/bin/env bash
# selector: tree-scan
# Compare independent suite-file edges and directory probes with the real selector.
# Usage: bash scripts/cr/test-suite-file-selection.sh [--fixtures-only|--property|--historical|--monotonic <measurement-log>]
# Default: fast fixture controls. Full measurements require an explicit flag.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -I - "$ROOT" "$@" <<'PY'
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import os
import re
import runpy
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
arguments = sys.argv[2:]
requested_mode = arguments[0] if arguments else '--fixtures-only'
valid_modes = ('--fixtures-only', '--property', '--historical', '--historical-inside', '--monotonic')
expected_arguments = 2 if requested_mode == '--monotonic' else 1
if requested_mode not in valid_modes or arguments and len(arguments) != expected_arguments:
    sys.exit('usage: test-suite-file-selection.sh [--fixtures-only|--property|--historical|--monotonic <measurement-log>]')
module = runpy.run_path(str(root / 'scripts/cr/suite-file-resolver.py'))
selector = root / 'scripts/cr/impacted-suites.sh'
# Whole-root scans are the selector's deliberate cost ponytail, not directory
# probes. Every exception needs a live scan, and every live scan needs a reason.
# See impacted-suites.sh's scan_roots ponytail; unknown roots are never exemptions.
WHOLE_REPO = {
    'scripts/agents-md/test-pointers.sh': 'pointers.sh inventories every tracked path to find CLAUDE.md siblings',
    'scripts/ci/test-tier-replay.sh': 'tier-replay.sh inventories every tracked suite for its trust-tier floor',
    'scripts/claudex/test-probe-chunk.sh': 'reference stream reads the repository-wide tracked *.md pathspec',
    'scripts/graphify/test-no-windows-indexed.sh': 'git inventory forbids tracked *.ps1 anywhere in the tree',
    'scripts/guardrails/test-leak-classes.sh': 'executed leak-classes.sh inventories the tracked git root in tree/ignore-removal modes; suite uses fixture repos',
    'scripts/himmelctl/test/test-versioned-layout.sh': 'fixture copies the tracked and untracked working tree',
    'scripts/hooks/test-check-npm-audit.sh': 'check-npm-audit.sh inventories *package.json throughout the repository',
    'scripts/hooks/test-check-npm-licenses.sh': 'check-npm-licenses.sh inventories *package.json throughout the repository',
    'scripts/hooks/test-gitattributes-no-driver.sh': 'driver lint reads every */.gitattributes pathspec',
    'scripts/lint/test-flag-parity.sh': 'flag-parity.sh inventories every tracked *.sh for doc parity',
    'scripts/test-adopt.sh': 'fixture copies every tracked path from the repository root',
    'scripts/test-check-plugin-drift.sh': 'coverage control reads dependency pins from every tracked *package.json',
}


GIT_REPO_SCRUB = {'GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
                  'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES',
                  'GIT_PREFIX', 'GIT_IMPLICIT_WORK_TREE', 'GIT_GRAFT_FILE',
                  'GIT_REPLACE_REF_BASE', 'GIT_SHALLOW_FILE', 'GIT_CONFIG'}


def run(*args, cwd, env=None, **kwargs):
    incoming = os.environ if env is None else env
    clean = {key: value for key, value in incoming.items() if key not in GIT_REPO_SCRUB}
    return subprocess.run(args, cwd=cwd, env=clean, text=True, capture_output=True, **kwargs)


def require_roots(actual, pinned):
    missing, stale = set(actual) - set(pinned), set(pinned) - set(actual)
    assert not missing, f'unlisted whole-repo scanners: {sorted(missing)}'
    assert not stale, f'stale whole-repo scanners: {sorted(stale)}'
    assert all(pinned.values()), 'whole-repo scanner needs a reason'


def rejected(function, message):
    try:
        function()
    except AssertionError:
        return
    raise AssertionError(message)


def matrix(repo, paths, script=selector):
    path_file = repo / '.queries'
    path_file.write_text(''.join(path + '\n' for path in paths))
    result = run('bash', str(script), '--paths-file', str(path_file), 'HEAD..HEAD', cwd=repo)
    assert result.returncode == 0, result.stderr
    rows = {}
    for row in result.stdout.splitlines():
        path, suite = row.split('\t', 1)
        rows.setdefault(path, set())
        if suite:
            rows[path].add(suite)
    assert set(rows) == set(paths), 'batch selector dropped or invented a query path'
    return rows


with tempfile.TemporaryDirectory(prefix='suite-selection-') as scratch:
    repo = Path(scratch)
    def write(path, text):
        target = repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    def git(*args):
        result = run('git', '-c', 'core.hooksPath=/dev/null', *args, cwd=repo)
        assert result.returncode == 0, result.stderr
        return result.stdout.strip()
    git('init', '-q')
    git('config', 'user.email', 'fixture@example.invalid')
    git('config', 'user.name', 'Fixture')
    files = {
        'scripts/test-reader.sh': 'source "$ROOT/scripts/helper.sh"\nbash "$ROOT/scripts/gate.sh" -- bash "$ROOT/scripts/rejected.sh"\n',
        'scripts/helper.sh': 'bash "$ROOT/scripts/worker.sh"\nfor f in "$scratch"/* "${cfg%/*}" "$1"/* "$@"/.*; do : "$f"; done\n',
        'scripts/worker.sh': 'cat "$ROOT/data/settings.json"\nfind "$ROOT/docs" -path "*/ignored/*" -prune -o -name "*.md"\nprintf "%s\\n" \'find . -name "*.sh"\'\nnode "$ROOT/scripts/module.mjs"\n',
        'scripts/module.mjs': '// ../assets/unrelated.txt\n/*\n../data/never.txt\n*/\nconsole.log("ok");\n',
        'scripts/gate.sh': 'exit 0\n',
        'scripts/rejected.sh': 'cat "$ROOT/data/never.txt"\n',
        'data/never.txt': 'not executed\n',
        'data/settings.json': '{}\n',
        'docs/a.md': 'text\n',
        'docs/nested/b.md': 'text\n',
        'assets/unrelated.txt': 'unrelated\n',
        'scripts/testing/test-unwired-hooks.sh': 'cat "$ROOT/data/settings.json"\n',
    }
    for path, text in files.items():
        write(path, text)
    git('add', '.')
    git('commit', '-qm', 'baseline')
    with tempfile.TemporaryDirectory(prefix='suite-outer-') as outer_scratch:
        outer = Path(outer_scratch)
        initialized = run('git', 'init', '-q', cwd=outer)
        assert initialized.returncode == 0, initialized.stderr
        outer_before = {str(path.relative_to(outer)): path.read_bytes()
                        for path in outer.rglob('*') if path.is_file()}
        poisoned_environment = dict(os.environ, GIT_DIR=str(outer / '.git'),
                                    GIT_WORK_TREE=str(outer), GIT_INDEX_FILE=str(outer / '.git/index'),
                                    GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='core.fsync', GIT_CONFIG_VALUE_0='none')
        for inherited in (False, True):
            saved_environment = dict(os.environ)
            try:
                if inherited:
                    os.environ.clear()
                    os.environ.update(poisoned_environment)
                updated = run('git', 'config', 'fixture.safety', 'contained', cwd=repo,
                              **({} if inherited else {'env': poisoned_environment}))
                pinned = run('git', 'config', '--get', 'core.fsync', cwd=repo,
                             **({} if inherited else {'env': poisoned_environment}))
            finally:
                os.environ.clear()
                os.environ.update(saved_environment)
            outer_after = {str(path.relative_to(outer)): path.read_bytes()
                           for path in outer.rglob('*') if path.is_file()}
            assert outer_after == outer_before, 'fixture Git environment touched the outer repository'
            assert updated.returncode == 0, updated.stderr
            assert git('config', '--get', 'fixture.safety') == 'contained', 'fixture config write was redirected'
            assert pinned.returncode == 0 and pinned.stdout.strip() == 'none', 'fixture performance pins were dropped'
    print('PASS fixture Git calls isolate inherited and explicit repository redirects while preserving performance pins', flush=True)
    saved_environment = dict(os.environ)
    os.environ['GIT_DIR'] = str(repo / 'absent.git')
    try:
        try:
            poisoned_tree = module['tree'](str(repo), 'HEAD')
        except subprocess.CalledProcessError:
            poisoned_tree = {}
    finally:
        os.environ.clear()
        os.environ.update(saved_environment)
    assert 'scripts/test-reader.sh' in poisoned_tree, 'caller Git environment redirected the resolver tree'
    print('PASS resolver ignores caller repository-redirecting Git environment', flush=True)
    resolved = module['resolve'](module['tree'](str(repo), 'HEAD'), closure_walkers=())
    got = set(resolved['files']['scripts/test-reader.sh'])
    assert {'scripts/helper.sh', 'scripts/worker.sh', 'data/settings.json'} <= got, 'missing source/exec/path-read edge'
    assert not {'assets/unrelated.txt', 'data/never.txt', 'docs/a.md'} & got, 'invented exact-file edge'
    assert not resolved['whole_repo'], 'a find predicate or quoted command became a root scanner'
    probes = set(resolved['probes']['scripts/test-reader.sh'])
    assert {'docs/zz-oracle-probe.md', 'docs/zz-oracle-depth/zz-oracle-probe.md'} <= probes, 'recursive include probes missing'
    assert not any('' in path for path in probes), 'unknown positional parameter became a probe'
    assert 'scripts/testing/test-unwired-hooks.sh' not in resolved['files'], 'G2 registry suite was not excluded'
    print('PASS exact edges, recursive directory probes, argument/parameter false-positive controls and G2 exclusion', flush=True)

    quoted_execution = module['resolve']({
        'scripts/test-quoted-command.sh': 'printf "%s\\n" "example (bash scripts/data-only.sh)"\ngrep -q \'(bash scripts/data-only.sh)\' "$ROOT/docs/example.md"\n',
        'scripts/data-only.sh': 'cat "$ROOT/data/never.txt"\n',
        'docs/example.md': 'example\n',
        'data/never.txt': 'not read\n',
    }, closure_walkers=())
    assert 'data/never.txt' not in quoted_execution['files']['scripts/test-quoted-command.sh'], 'quoted command example became a transitive execute edge'
    assert 'scripts/data-only.sh' not in quoted_execution['files']['scripts/test-quoted-command.sh'], 'printed path or grep pattern became an exact read'
    assert 'docs/example.md' in quoted_execution['files']['scripts/test-quoted-command.sh'], 'grep input file read was lost'
    print('PASS quoted command examples are not executed', flush=True)

    dirname_alias = module['resolve']({
        'scripts/test-dirname.sh': 'GUARD="$(cd "$(dirname "$0")" && pwd)/guard.sh"\nbash "$GUARD"\n',
        'scripts/guard.sh': 'cat "$ROOT/data/settings.json"\n',
        'data/settings.json': '{}\n',
    }, closure_walkers=())
    assert {'scripts/guard.sh', 'data/settings.json'} <= set(dirname_alias['files']['scripts/test-dirname.sh']), 'dirname-derived interpreter operand was unresolved'
    print('PASS dirname-derived guard aliases retain execution closure', flush=True)

    stdin_read = module['resolve']({
        'scripts/test-stdin.sh': 'python3 -I - "$ROOT/scripts/data-only.py" <<\'PY\'\nimport sys\nopen(sys.argv[1]).read()\nPY\n',
        'scripts/data-only.py': 'open("data/never.txt").read()\n',
        'data/never.txt': 'not read\n',
    }, closure_walkers=())
    assert 'scripts/data-only.py' in stdin_read['files']['scripts/test-stdin.sh'], 'stdin program input file was not read'
    assert 'data/never.txt' not in stdin_read['files']['scripts/test-stdin.sh'], 'stdin program argument became an executed script'
    print('PASS interpreter stdin mode reads data without executing its arguments', flush=True)

    module_reads = module['resolve']({
        'scripts/test-module.sh': 'node "$ROOT/scripts/module.mjs"\n',
        'scripts/module.mjs': """import "./worker.mjs";
console.log("../data/never.txt");
console.log("import '../data/fake.mjs'");
""",
        'scripts/worker.mjs': 'import { readFileSync } from "node:fs";\nreadFileSync("data/settings.json");\n',
        'data/fake.mjs': 'true\n',
        'data/settings.json': '{}\n',
        'data/never.txt': 'not read\n',
    }, closure_walkers=())
    module_files = set(module_reads['files']['scripts/test-module.sh'])
    assert not {'data/never.txt', 'data/fake.mjs'} & module_files, 'module string data became a file read'
    assert {'scripts/worker.mjs', 'data/settings.json'} <= module_files, 'transitive static import read missing'
    print('PASS module imports execute transitively, literal string data is not a read', flush=True)

    relative_reads = module['resolve']({
        'scripts/test-relative.sh': 'cat README.md\nnode "$ROOT/scripts/module.mjs"\n',
        'scripts/module.mjs': 'import "../data/settings.json";\n',
        'README.md': 'root read\n',
        'scripts/README.md': 'not read\n',
        'data/settings.json': '{}\n',
    }, closure_walkers=())
    relative_files = set(relative_reads['files']['scripts/test-relative.sh'])
    assert 'README.md' in relative_files and 'data/settings.json' in relative_files, 'cwd read or module-relative import lost'
    assert 'scripts/README.md' not in relative_files, 'bare shell operand invented a caller-relative read'
    print('PASS shell cwd reads and module-relative imports do not invent sibling files', flush=True)

    literal_loops = module['resolve']({
        'scripts/test-loops.sh': 'for value in \'[null]\' "[json]"; do :; done\nbash "$ROOT/scripts/list.py"\nfor f in "$ROOT/docs"/*.md; do :; done\npython3 -c \'import json\nfor row in rows[1:]:\n    print(row)\'\n',
        'scripts/list.py': 'for row in rows[1:]:\n    print(row)\n',
        'docs/a.md': 'text\n',
    }, closure_walkers=())
    quoted_variable = module['resolve']({'scripts/test-quoted.sh': 'FILTER=\'[.hooks[]]\'\nfor value in "$FILTER"; do :; done\n'}, closure_walkers=())
    assert not quoted_variable['whole_repo'], 'quoted variable data underwent glob expansion'
    assert not literal_loops['whole_repo'], 'quoted data or Python loop became a shell glob'
    assert 'docs/zz-oracle-probe.md' in literal_loops['probes']['scripts/test-loops.sh'], 'unquoted shell glob was lost'
    print('PASS quoted loop data and Python slices are not shell globs', flush=True)

    noglob = module['resolve']({'scripts/test-noglob.sh': 'FAMILIES=mog-run.*\nset -f\nfor family in $FAMILIES; do :; done\nset +f\n'}, closure_walkers=())
    assert not noglob['whole_repo'], 'set -f data underwent pathname expansion'
    print('PASS set -f prevents family patterns becoming repository scans', flush=True)

    runtime_scope = module['resolve']({
        'scripts/test-scope.sh': 'local root\nfor root in "$@"; do\nfor child in "$root"/*/; do :; done\ndone\n(cd "$scratch" && find . -type f)\nwhile IFS= read -r ROOT; do\nfind "$ROOT" -name "*.md"\ndone\ncd "$fixture"\ngit ls-files\n',
    }, closure_walkers=())
    assert not runtime_scope['whole_repo'], 'runtime local or changed cwd became repository root'
    assert runtime_scope['unresolved']['scripts/test-scope.sh'], 'runtime scan context was not reported'
    print('PASS local variables and changed cwd are unresolved, not root', flush=True)

    pathspec_scan = module['resolve']({
        'scripts/test-pathspec.sh': 'git ls-files -- "docs/*.md" ":(exclude)ignored/*"\nfiles="$(git ls-files -- \'docs/*.md\')"\n',
        'docs/a.md': 'text\n',
    }, closure_walkers=())
    assert 'docs/zz-oracle-probe.md' in pathspec_scan['probes']['scripts/test-pathspec.sh'], 'git pathspec scan lost its directory probe'
    assert not pathspec_scan['whole_repo'], 'scoped git pathspec became root'
    assert all(not path.startswith(':') for path in pathspec_scan['probes']['scripts/test-pathspec.sh']), 'excluded git pathspec became a positive probe'
    print('PASS scoped git pathspec produces directory probes', flush=True)

    array_scans = module['resolve']({
        'scripts/test-arrays.sh': 'inputs=("$ROOT")\nruntime=(/usr /etc)\nfind "${runtime[@]}" -type f\nscan_targets=(docs)\nexisting=()\nfor t in "${scan_targets[@]}"; do\nexisting+=("$t")\ndone\ngrep -r x --include="*.md" "${existing[@]}"\n',
        'docs/a.md': 'text\n',
    }, closure_walkers=())
    assert not array_scans['whole_repo'], 'unrelated array supplied repository root to a scan'
    assert 'docs/zz-oracle-probe.md' in array_scans['probes']['scripts/test-arrays.sh'], 'loop/append array propagation lost directory'
    print('PASS scan roots are scoped to their actual array', flush=True)

    root_scan = module['resolve']({'scripts/test-root.sh': 'git ls-files\nfind "$unknown" -name "*.sh"\n'}, closure_walkers=())
    rejected(lambda: require_roots(root_scan['whole_repo'], {}), 'unlisted whole-root scan passed')
    require_roots(root_scan['whole_repo'], {'scripts/test-root.sh': 'fixture inventory'})
    rejected(lambda: require_roots({}, {'scripts/test-root.sh': 'fixture inventory'}), 'stale whole-root pin passed')
    assert root_scan['unresolved']['scripts/test-root.sh'], 'unknown scan variable was not reported'
    assert not root_scan['probes']['scripts/test-root.sh'], 'unknown variable became a root scan'
    print('PASS whole-repo pins fail closed both ways; unresolved root is reported', flush=True)

    walker = 'scripts/cr/test-cr-guarded-closure.sh'
    miniature = {
        walker: '# <himmel_dir>/scripts/cr/seed.sh\nfor f in "$ROOT"/scripts/cr/*.sh; do :; done\n',
        'scripts/cr/seed.sh': 'bash "$ROOT/scripts/lanes/guarded.sh"\n',
        'scripts/lanes/guarded.sh': 'bash "$ROOT/scripts/targets/unnamed.sh"\n',
        'scripts/targets/unnamed.sh': 'true\n',
        'scripts/cr/pr-check-context.sh': 'cr_guarded="scripts/cr"\n',
        '.claude/commands/pr-check.md': '<himmel_dir>/scripts/cr/seed.sh\n',
    }
    walked = module['resolve'](miniature, closure_walkers=(walker,))
    assert 'scripts/targets/unnamed.sh' in walked['files'][walker], 'closure walker did not reach unnamed target'
    without_row = module['resolve'](miniature, closure_walkers=())
    assert 'scripts/targets/unnamed.sh' not in without_row['files'][walker], 'walker mutation did not remove the edge'
    stale = dict(miniature, **{walker: 'true\n'})
    rejected(lambda: module['resolve'](stale, closure_walkers=(walker,)), 'stale closure walker row passed')
    print('PASS pinned closure walker reaches unnamed target and has anti-rot/mutation controls', flush=True)

    for path, text in {
        'scripts/test-source.sh': 'source "$ROOT/scripts/bridge.sh"\n',
        'scripts/bridge.sh': 'source "$ROOT/scripts/lib/shared.sh"\n',
        'scripts/lib/shared.sh': 'true\n',
        'scripts/new-setting.sh': '# HIMMEL_UNINSTALL_REAL_HOME\n',
        'scripts/test-uninstall-real-home-callers.sh': 'true\n',
        'scripts/test-tree.sh': '# selector: tree-scan\ntrue\n',
        'scripts/lanes/test-veto.sh': 'true\n',
        'scripts/lanes/test-launch-site-profiles.sh': 'true\n',
        'scripts/cr/test-pr-check-run.sh': 'true\n',
        'scripts/ci/test-check-cr-terminology.sh': 'true\n',
        **miniature,
    }.items():
        write(path, text)
    git('add', '.')
    git('commit', '-qm', 'selector parity fixtures')
    reference = repo / 'reference.sh'
    baseline = run('git', 'show', '274dd8374:scripts/cr/impacted-suites.sh', cwd=root)
    assert baseline.returncode == 0, baseline.stderr
    reference.write_text(baseline.stdout)
    (repo / 'anchor-handoff.sh').write_text((root / 'scripts/cr/anchor-handoff.sh').read_text())
    for changed in ['scripts/lib/shared.sh', 'scripts/lanes/test-veto.sh', 'scripts/new-setting.sh', 'scripts/lanes/guarded.sh', '.claude/commands/zz-oracle-probe.html', 'assets/new.txt']:
        before = git('rev-parse', 'HEAD')
        queried = matrix(repo, [changed])[changed]
        target = repo / changed
        write(changed, (target.read_text() if target.exists() else '') + '# changed\n')
        git('add', changed)
        git('commit', '-qm', 'one-file parity control')
        after = git('rev-parse', 'HEAD')
        selected = run('bash', str(selector), before + '..' + after, cwd=repo)
        old = run('bash', str(reference), before + '..' + after, cwd=repo)
        assert selected.returncode == old.returncode == 0, selected.stderr + old.stderr
        assert selected.stdout == old.stdout, f'single-diff changed from 274dd8374: {changed}'
        assert queried == set(selected.stdout.splitlines()), f'batch/single parity: {changed}'
    print('PASS batch/single/274dd8374 parity: source closure, scan+veto, content, guarded closure and tree-scan adds', flush=True)
    path_file = repo / '.queries'
    for mode in ['--check', '--selector-miss', '--runner-check', '--runner', '--run']:
        args = [mode] + (['scripts/test-reader.sh'] if mode in ('--runner', '--run') else [])
        result = run('bash', str(selector), '--paths-file', str(path_file), *args, 'HEAD..HEAD', cwd=repo)
        assert result.returncode == 2, f'batch did not refuse {mode}'
    link = repo / '.queries-link'
    link.symlink_to(path_file)
    assert run('bash', str(selector), '--paths-file', str(link), 'HEAD..HEAD', cwd=repo).returncode == 2, 'batch followed a symlink'
    print('PASS batch mode/input refusals', flush=True)

    for path, text in {
        'scripts/test-imports.sh': 'node "$ROOT/modules/entry.mjs"\npython3 "$ROOT/pylib/entry.py"\n',
        'scripts/test-mention.sh': 'node "$ROOT/modules/mention.mjs"\n',
        'modules/entry.mjs': 'import "./bridge.mjs";\n',
        'modules/bridge.mjs': 'const value = require("./leaf.cjs");\n',
        'modules/leaf.cjs': 'require("./entry.mjs");\n',
        'modules/mention.mjs': 'console.log("modules/leaf.cjs");\n',
        'pylib/entry.py': 'from bridge import value\n',
        'pylib/bridge.py': 'import leaf\n',
        'pylib/leaf.py': 'value = 1\n',
        'scripts/ci/test-check-actions-pinned.sh': 'bash "$ROOT/scripts/ci/check-actions-pinned.sh"\n',
        'scripts/ci/check-actions-pinned.sh': 'grep -r uses --include="*.yml" --include="*.yaml" .github\n',
        '.github/workflows/example.yml': 'name: fixture\n',
    }.items():
        write(path, text)
    git('add', '.')
    git('commit', '-qm', 'repo import and recursive scan controls')
    import_rows = matrix(repo, ['modules/leaf.cjs', 'pylib/leaf.py', '.github/zz-oracle-probe.yml', '.github/deep/zz-oracle-probe.yaml'])
    for changed in ['modules/leaf.cjs', 'pylib/leaf.py']:
        assert 'scripts/test-imports.sh' in import_rows[changed], f'import closure missing: {changed}'
    assert 'scripts/test-mention.sh' not in import_rows['modules/leaf.cjs'], 'plain path mention became an import edge'
    for changed in ['.github/zz-oracle-probe.yml', '.github/deep/zz-oracle-probe.yaml']:
        assert 'scripts/ci/test-check-actions-pinned.sh' in import_rows[changed], f'recursive YAML scan missing: {changed}'
    print('PASS transitive JS import/require and Python import closure; recursive YAML scan probes', flush=True)

if requested_mode == '--fixtures-only':
    sys.exit(0)


def monotonic(log_path):
    # Reconstruct exactly the sorted prefixes emitted by the eight measurement
    # shards. Counts and the oracle must still agree; never substitute a sample.
    measured = Path(log_path).read_text()
    expected = re.search(r'ORACLE (\d+) query paths, (\d+) suites, (\d+) edges', measured)
    assert expected, 'measurement lacks oracle counts'
    current = module['resolve'](module['tree'](str(root), 'HEAD'))
    edge_sets = {suite: set(current['files'][suite]) | set(current['probes'][suite]) for suite in current['files']}
    paths = sorted({path for edges in edge_sets.values() for path in edges})
    assert tuple(map(int, expected.groups())) == (len(paths), len(edge_sets), sum(map(len, edge_sets.values()))), 'measurement oracle changed'
    prefixes = {int(i): (int(done), int(total)) for i, done, total in re.findall(r'TIMEOUT shard (\d+): (\d+)/(\d+) query paths', measured)}
    assert set(prefixes) == set(range(8)), 'measurement must name all eight shard prefixes'
    completed = []
    for index, (done, total) in prefixes.items():
        shard = paths[index::8]
        assert len(shard) == total and 0 < done <= total, 'invalid measured prefix'
        completed += shard[:done]
    result = re.search(r'RESULT (\d+)/(\d+) completed query paths', measured)
    assert result and (len(completed), len(paths)) == tuple(map(int, result.groups())), 'completed-path count mismatch'
    assert len(set(completed)) == len(completed), 'overlapping measured prefixes'
    baseline_ref = run('git', 'rev-parse', 'main', cwd=root)
    assert baseline_ref.returncode == 0, baseline_ref.stderr
    baseline_ref = baseline_ref.stdout.strip()
    baseline = run('git', 'show', baseline_ref + ':scripts/cr/impacted-suites.sh', cwd=root)
    anchor = run('git', 'show', baseline_ref + ':scripts/cr/anchor-handoff.sh', cwd=root)
    assert baseline.returncode == anchor.returncode == 0, baseline.stderr + anchor.stderr
    started = time.monotonic()
    print(f'MONOTONIC baseline main {baseline_ref}; {len(completed)} completed query paths; 16 disjoint workers', flush=True)
    with tempfile.TemporaryDirectory(prefix='suite-monotonic-') as scratch:
        scratch = Path(scratch)
        reference = scratch / 'baseline.sh'
        reference.write_text(baseline.stdout)
        (scratch / 'anchor-handoff.sh').write_text(anchor.stdout)
        shim = scratch / 'git'
        shim.write_text('''#!/usr/bin/env bash
if [ "${1:-}" = diff ] && [ -n "${SUITE_QUERY_PATH:-}" ]; then
    shape=0; names=0
    for arg in "$@"; do
        case "$arg" in --name-only) names=1 ;; --diff-filter=ADT) shape=1 ;; esac
    done
    if [ "$names" = 1 ]; then
        if [ "$shape" = 0 ] || [ "$SUITE_QUERY_ADD" = 1 ]; then
            printf '%s\\0' "$SUITE_QUERY_PATH"
        fi
        exit 0
    fi
fi
exec /usr/bin/git -c grep.threads=1 "$@"
''')
        shim.chmod(0o755)
        environment = dict(os.environ, PATH=str(scratch) + os.pathsep + os.environ['PATH'])
        environment.pop('SUITE_QUERY_PATH', None)
        contents = module['tree'](str(root), 'HEAD')
        def compare(index):
            chunk = sorted(completed)[index::16]
            path_file = scratch / f'queries-{index}'
            path_file.write_text(''.join(path + '\n' for path in chunk))
            selected = run('bash', str(selector), '--paths-file', str(path_file), 'HEAD..HEAD', cwd=root, env=environment, timeout=900)
            assert selected.returncode == 0, selected.stderr
            actual = {}
            for row in selected.stdout.splitlines():
                path, suite = row.split('\t', 1)
                actual.setdefault(path, set())
                if suite:
                    actual[path].add(suite)
            assert set(actual) == set(chunk), 'monotonic batch dropped a query'
            drops, checked = [], 0
            for path in chunk:
                query_env = dict(environment, SUITE_QUERY_PATH=path, SUITE_QUERY_ADD='0' if path in contents else '1')
                previous = run('bash', str(reference), 'HEAD..HEAD', cwd=root, env=query_env, timeout=90)
                assert previous.returncode == 0, previous.stderr
                if path in current['files']:
                    assert path in previous.stdout.splitlines(), 'main replay missed a changed-suite self-edge; diff shim did not apply'
                if path == '.claude/commands/zz-oracle-probe.html':
                    assert 'scripts/ci/test-check-cr-terminology.sh' in previous.stdout.splitlines(), 'main replay lost known add-probe edge'
                drops += [(path, suite) for suite in set(previous.stdout.splitlines()) - actual[path]]
                checked += 1
            print(f'MONOTONIC-SHARD {index}: {checked}/{len(chunk)} paths, {len(drops)} drops', flush=True)
            return checked, drops
        with ThreadPoolExecutor(max_workers=16) as pool:
            compared = list(pool.map(compare, range(16)))
        drops = [pair for _, rows in compared for pair in rows]
        checked = sum(count for count, _ in compared)
        for path, suite in drops:
            print(f'MONOTONIC-DROP {suite} {path}', flush=True)
        print(f'MONOTONIC RESULT {checked}/{len(completed)} paths, {len(drops)} drops against main {baseline_ref}; {time.monotonic()-started:.3f}s', flush=True)
        assert checked == len(completed) and not drops, 'selector is not monotonic against main'


if '--monotonic' in sys.argv[2:]:
    monotonic(sys.argv[sys.argv.index('--monotonic') + 1])
    sys.exit(0)


def historical():
    parent = run('git', 'rev-parse', 'aca0f5c1e^', cwd=root)
    assert parent.returncode == 0, parent.stderr
    parent = parent.stdout.strip()
    names = [
        'scripts/cr/impacted-suites.sh', 'scripts/cr/anchor-handoff.sh',
        'scripts/cr/test-cr-guarded-closure.sh', 'scripts/cr/pr-check-context.sh',
        'scripts/cr/file-deferred-issues.sh', 'scripts/lib/forge.sh',
        'scripts/ci/check-cr-terminology.sh', 'scripts/ci/test-check-cr-terminology.sh',
        '.claude/commands/pr-check.md', '.agents/skills/pr-check/SKILL.md',
    ]
    # ponytail: a full parent exhausts sandbox /tmp, and worktree scratch is
    # read-only. This minimal replay preserves original blobs, not a full tree.
    with tempfile.TemporaryDirectory(prefix='suite-minimal-parent-') as scratch:
        repo = Path(scratch)
        def git(*args):
            result = run('git', '-c', 'core.hooksPath=/dev/null', *args, cwd=repo)
            assert result.returncode == 0, result.stderr
            return result.stdout.strip()
        git('init', '-q')
        git('config', 'user.email', 'fixture@example.invalid')
        git('config', 'user.name', 'Fixture')
        for name in names:
            blob = subprocess.check_output(['git', 'show', parent + ':' + name], cwd=root)
            target = repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(blob)
            oid = run('git', 'rev-parse', parent + ':' + name, cwd=root)
            assert oid.returncode == 0 and git('hash-object', name) == oid.stdout.strip(), f'parent bytes changed: {name}'
        git('add', '.')
        git('commit', '-qm', 'minimal historical parent-byte fixture')
        print(f'MINIMAL-PARENT-FIXTURE {parent}; {len(names)} original blobs, not a full-parent replay', flush=True)
        walker, target = 'scripts/cr/test-cr-guarded-closure.sh', 'scripts/lib/forge.sh'
        assert Path(target).name not in (repo / walker).read_text(), '4453 target already named'
        contents = module['tree'](str(repo), 'HEAD')
        oracle = module['resolve'](contents)
        assert target in oracle['files'][walker], 'historical unnamed closure member missing'
        mutated = module['resolve'](contents, closure_walkers=())
        assert target not in mutated['files'][walker], 'walker mutation retained historical RED'
        term = 'scripts/ci/test-check-cr-terminology.sh'
        probe = '.claude/commands/zz-oracle-probe.html'
        assert probe in oracle['probes'][term], 'historical .html probe missing'
        for ticket, path, suite in [('HIMMEL-4453', target, walker), ('HIMMEL-4488', probe, term)]:
            before = git('rev-parse', 'HEAD')
            changed = repo / path
            changed.parent.mkdir(parents=True, exist_ok=True)
            with changed.open('a') as output:
                output.write('\n# historical selector control\n')
            git('add', path)
            git('commit', '-qm', ticket + ' one-file control')
            result = run('bash', str(repo / 'scripts/cr/impacted-suites.sh'), before + '..HEAD', cwd=repo)
            assert result.returncode == 0, result.stderr
            assert suite not in result.stdout.splitlines(), f'{ticket} unexpectedly selected {suite}'
            print(f'RED {ticket}: {path} missing {suite}', flush=True)


if '--historical-inside' in sys.argv[2:]:
    historical()
    sys.exit(1)
common = run('git', 'rev-parse', '--path-format=absolute', '--git-common-dir', cwd=root)
assert common.returncode == 0, common.stderr
replay = run('bash', str(root / 'scripts/lib/sandbox-run.sh'), '--read-only', common.stdout.strip(), '--', 'bash', str(root / 'scripts/cr/test-suite-file-selection.sh'), '--historical-inside', cwd=root)
print(replay.stdout, end='', flush=True)
assert replay.returncode == 1 and all(marker in replay.stdout for marker in ('MINIMAL-PARENT-FIXTURE', 'RED HIMMEL-4453:', 'RED HIMMEL-4488:')), replay.stderr + replay.stdout
if '--historical' in sys.argv[2:]:
    sys.exit(1)

start = time.monotonic()
contents = module['tree'](str(root), 'HEAD')
assert module['REGISTRY'] <= set(contents), 'G2 registry exclusion stale'
resolved = module['resolve'](contents)
for suite, sites in resolved['whole_repo'].items():
    print(f'WHOLE-REPO {suite}: {sites}', flush=True)
require_roots(resolved['whole_repo'], WHOLE_REPO)
for suite, rows in resolved['unresolved'].items():
    for row in rows:
        print(f'UNRESOLVED {suite}: {row}', flush=True)
for row in resolved['closure_pins']:
    print(f'CLOSURE-PIN {row}', flush=True)
edges = {suite: set(resolved['files'][suite]) | set(resolved['probes'][suite]) for suite in resolved['files']}
term = 'scripts/ci/test-check-cr-terminology.sh'
assert '.claude/commands/zz-oracle-probe.html' in edges[term], 'known terminology probe missing from oracle'
paths = sorted({path for dependencies in edges.values() for path in dependencies})
assert paths and edges, 'empty oracle'
with tempfile.TemporaryDirectory(prefix='suite-matrix-') as scratch:
    # matrix() only writes its paths file here; the selector must run at the repo.
    print(f'ORACLE {len(paths)} query paths, {len(edges)} suites, {sum(map(len, edges.values()))} edges; eight complete disjoint shards', flush=True)
    # ponytail: eight selector processes bound station load; each shard has an
    # eight-minute failure budget. Every query must finish, never a sample.
    def select_shard(index):
        path_file = Path(scratch) / f'paths-{index}'
        path_file.write_text(''.join(path + '\n' for path in paths[index::8]))
        shard_start = time.monotonic()
        try:
            selected = run('bash', str(selector), '--paths-file', str(path_file), 'HEAD..HEAD', cwd=root, timeout=480)
        except subprocess.TimeoutExpired as error:
            partial = error.stdout or ''
            if isinstance(partial, bytes):
                partial = partial.decode('utf-8', errors='replace')
            completed = len({row.split('\t', 1)[0] for row in partial.splitlines()})
            return partial, f'TIMEOUT shard {index}: {completed}/{len(paths[index::8])} query paths completed in 480s'
        elapsed = time.monotonic() - shard_start
        print(f'SHARD {index}: rc={selected.returncode} in {elapsed:.3f}s', flush=True)
        return selected.stdout, f'ERROR shard {index}: rc={selected.returncode}\n{selected.stderr}' if selected.returncode else ''
    actual, errors = {}, []
    with ThreadPoolExecutor(max_workers=8) as pool:
        for output, error in pool.map(select_shard, range(8)):
            if error:
                errors.append(error)
            for line in output.splitlines():
                path, suite = line.split('\t', 1)
                actual.setdefault(path, set())
                if suite:
                    actual[path].add(suite)
    misses = [(path, suite) for suite, dependencies in edges.items() for path in dependencies if path in actual and suite not in actual[path]]
    for path, suite in misses:
        print(f'FAIL selector-miss: {suite} {path}', flush=True)
    print(f'RESULT {len(actual)}/{len(paths)} completed query paths; {len(misses)} observed under-selections', flush=True)
    assert not errors, '\n'.join(errors)
    assert set(actual) == set(paths), 'query/result path counts differ'
    assert not misses, f'{len(misses)} selector under-selections'
print(f'PASS superset for {len(paths)} query paths across {len(edges)} suites in {time.monotonic()-start:.3f}s', flush=True)
PY
