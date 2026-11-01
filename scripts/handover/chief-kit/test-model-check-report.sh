#!/usr/bin/env bash
# Missing Java must stay off with installation guidance; a wrong jar must never execute.
# External runtimes are optional: these prerequisite rows need neither Java nor the compiler.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/model-check-report.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/model-check-report-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
fails=0
check() {
    if [ "$2" = "$3" ]; then printf 'PASS: %s\n' "$1";
    else printf 'FAIL: %s (got %s, want %s)\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}
contains() {
    case "$2" in *"$3"*) printf 'PASS: %s\n' "$1" ;;
        *) printf 'FAIL: %s (missing %s)\n' "$1" "$3"; fails=$((fails + 1)) ;; esac
}
printf '%s\n' '---- MODULE Model ----' '====' > "$WORK/Model.tla"
printf 'SPECIFICATION Spec\n' > "$WORK/Model.cfg"
printf 'export const title = "fixture";\n' > "$WORK/view.mjs"
printf 'not a jar\n' > "$WORK/tla2tools.jar"
# shellcheck disable=SC2016  # expanded by the runner, not by fixture creation
printf '%s\n' '#!/bin/sh' 'touch "$MODEL_CHECK_CALLED"' > "$WORK/statechart"
chmod +x "$WORK/statechart"
run() (
    export JAVA="$1" TLA2TOOLS="$WORK/tla2tools.jar" STATECHART="$WORK/statechart"
    export MODEL_CHECK_CALLED="$WORK/called" HANDOVER_DIR="$WORK"
    bash "$SUT" 4313 queue-lock "$WORK/Model.tla" "$WORK/view.mjs" 2>&1
)
out="$(run "$WORK/no-java")"; rc=$?
check 'missing Java leaves the optional feature off (exit 3)' "$rc" 3
contains 'missing Java gives installation guidance' "$out" 'OpenJDK 21'
contains 'missing Java explicitly says no report ran' "$out" 'not run'

out="$(run /usr/bin/true)"; rc=$?
check 'a wrong jar sha is refused (exit 2)' "$rc" 2
contains 'a wrong jar names the sha256 failure' "$out" 'sha256'
check 'neither prerequisite failure executes the statechart runner' "$(test -e "$WORK/called" && printf yes || printf no)" no
# Exercise the exact embedded production formatter, without optional external runtimes.
# A greedy multiline rule match must not move a later bug heading into the opening sentence.
python3 -I - "$SUT" "$WORK" <<'PY'
import pathlib, subprocess, sys
sut, work = map(pathlib.Path, sys.argv[1:])
code = sut.read_text().split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
(work / 'output').mkdir()
(work / 'inputs').mkdir()
(work / 'inputs/Model.cfg').write_text('CONSTANT MaxBusyLoops = 4\n')
fixtures = [
    ('two bugs keep the first heading and path separate',
     '# Model\n\n## NoLostLock breaks\nThe shortest path has 1 step:\n0. free\n1. B deletes A\n\n## MutualExclusion breaks\nThe shortest path has 1 step:\n0. idle\n1. two holders\n',
     'NoLostLock breaks; the shortest path is free → B deletes A.'),
    ('a temporal counterexample is not falsely called shortest',
     "# Model\n\n## EventuallyLive breaks\nTLC's counterexample is in tlc-EventuallyLive.out. It has 1 step:\n0. waiting\n1. waiting\n",
     'EventuallyLive breaks; the shortest path is unavailable, so read the TLC counterexample before ruling.'),
    ('unchecked rules cannot read as a clean run',
     '# Model\n\n## Rules not checked\nNoLostLock\n',
     'Model checking is incomplete; no bug or shortest path can be ruled out.'),
    ('a report with no checked rules cannot read as clean',
     '# Model\n\nNo rules ran.\n',
     'Model checking is incomplete; no bug or shortest path can be ruled out.'),
]
fails = 0
for name, text, expected in fixtures:
    (work / 'output/report.md').write_text(text)
    r = subprocess.run([sys.executable, '-I', '-c', code, str(work), '123', 'a' * 40, 'scripts/handover/queue-lock.sh', 'f' * 64])
    got = (work / 'report.md').read_text().splitlines()[0] if r.returncode == 0 else f'formatter exit {r.returncode}'
    if got == expected:
        print(f'PASS: {name}')
    else:
        print(f'FAIL: {name} (got {got!r}, want {expected!r})')
        fails += 1
if 'CONSTANT MaxBusyLoops = 4' in (work / 'report.md').read_text():
    print('PASS: report carries actual config bounds for its read-only consumers')
else:
    print('FAIL: report omits actual config bounds')
    fails += 1
raise SystemExit(bool(fails))
PY
rc=$?
[ "$rc" -eq 0 ] || fails=$((fails + 1))
# Isolate optional runtimes/network, while exercising the real wrapper and a real fixture git repo.
# Counterfactual copies change one guard each; no tracked file or external compiler is modified/run.
python3 -I - "$SUT" "$WORK" <<'PY'
import hashlib, json, os, pathlib, re, shlex, shutil, subprocess, sys
sut, work = map(pathlib.Path, sys.argv[1:])
repo = work / 'repo'
repo.mkdir()
subprocess.run(['git', 'init', '-q', str(repo)], check=True)
source = repo / 'scripts/handover/queue-lock.sh'
source.parent.mkdir(parents=True)
source.write_text('# fixture source, never executed\n')
subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], check=True)
head = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
bin_dir = work / 'bin'
bin_dir.mkdir()
def executable(p, text):
    p.write_text('#!/bin/bash\n' + text)
    p.chmod(0o700)
# The jar boundary is doubled, not the compiler tree hashing code.
executable(bin_dir / 'sha256sum', '''if [ "${BAD_JAR:-0}" = 1 ]; then printf 'bad  fixture\\n'; else
printf '%s  fixture\\n' 936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88; fi
''')
executable(bin_dir / 'gh', '''[ "$PWD" = "$EXPECTED_REPO" ] || exit 77
printf '%s\\n' "$PWD" >> "$GH_CALLS"
case " $* " in
  *' --jq '*) if [ "$SCENARIO" = stale ]; then printf '%040d\\n' 0; else printf '%s\\n' "$EXPECTED_HEAD"; fi ;;
  *) printf '%s\\n' "$PR_METADATA" ;;
esac
''')
executable(bin_dir / 'timeout', '''printf '%s\\n' "$*" >> "$TIMEOUT_CALLS"
if [ "$1" = -k ]; then shift 3; fi
exec "$@"
''')
tree = work / 'compiler'
tree.mkdir()
executable(tree / 'statechart', '''touch "$RUNNER_CALLED"
"$JAVA" -version || exit 2
while [ "$#" -gt 0 ]; do
  if [ "$1" = --out ]; then out="$2"; break; fi
  shift
done
[ "$SCENARIO" != no-report ] || exit 0
mkdir -p "$out" || exit 2
if [ "$SCENARIO" = unchecked ]; then printf '# Model\\n\\n## Rules not checked\\nSafe\\n' > "$out/report.md";
elif [ "$SCENARIO" = unknown ]; then printf '# Model\\n\\nNo rules ran.\\n' > "$out/report.md";
else printf '# Model\\n\\n## Rules that hold\\nSafe\\n' > "$out/report.md"; fi
printf 'stateDiagram-v2\\n' > "$out/chart.mmd"
[ "$SCENARIO" != failed-runner ] || exit 124
''')
(tree / 'dependency.ts').write_text('// compiler dependency fixture\n')
def digest(root):
    h = hashlib.sha256()
    for p in sorted(root.rglob('*')):
        if p.is_file():
            h.update(p.relative_to(root).as_posix().encode() + b'\0')
            h.update(hashlib.sha256(p.read_bytes()).digest())
    return h.hexdigest()
tree_sha = digest(tree)
vendored = repo / 'marketplace/plugins/pstack/skills/statechart/scripts'
shutil.copytree(tree, vendored)
(vendored / 'package-lock.json').write_text('{"fixture": true}\n')
vendor_sha = digest(vendored)
text = sut.read_text()
# Dependency injection is confined to a scratch copy's approved fixture digest and repo paths.
text = re.sub(r'^HERE=.*$', 'HERE=' + shlex.quote(str(sut.parent)), text, count=1, flags=re.M)
text = re.sub(r'^REPO=.*$', 'REPO=' + shlex.quote(str(repo)), text, count=1, flags=re.M)
text = text.replace('569c34baed9a2b1e56029556aa04d6e4b2b2ca3c7211f5ac4ab8049d1319eb13', tree_sha)
text = text.replace('61e16ef034ab70f9ab7c35678db5d52cd82817b85d41007b267ea66a0b443587', vendor_sha)
wrapper = work / 'wrapper.sh'
wrapper.write_text(text)
(work / 'bucket').mkdir()
base_env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                JAVA='/usr/bin/true', TLA2TOOLS=str(work / 'tla2tools.jar'),
                STATECHART=str(tree / 'statechart'), USER_SLUG='fixture', EXPECTED_REPO=str(repo), EXPECTED_HEAD=head,
                PR_METADATA=json.dumps({'headRefOid': head, 'files': [{'path': 'scripts/handover/queue-lock.sh'}]}))
count = 0
def run(scenario='clean', script=wrapper, **extra):
    global count
    count += 1
    case = work / f'case-{count}'
    case.mkdir()
    bucket = case / 'bucket'
    bucket.mkdir()
    env = dict(base_env, SCENARIO=scenario, HANDOVER_DIR=str(bucket), GH_CALLS=str(case / 'gh'),
               TIMEOUT_CALLS=str(case / 'timeouts'), RUNNER_CALLED=str(case / 'called'))
    env.update(extra)
    if scenario == 'output-link':
        parent = bucket / 'fixture/himmel'
        parent.mkdir(parents=True)
        dest = case / 'redirected'
        dest.mkdir()
        (parent / 'model-check').symlink_to(dest, target_is_directory=True)
    spec = extra.get('MODEL', str(work / 'Model.tla'))
    view = extra.get('VIEW', str(work / 'view.mjs'))
    r = subprocess.run(['bash', str(script), '4313', 'queue-lock', spec, view], cwd=work, env=env, capture_output=True, text=True)
    reports = list(bucket.rglob('report.md'))
    report = next((p for p in reports if p.parent.name.startswith('pr-4313-')), None)
    return r, case, report

def clean_ok(result):
    r, case, report = result
    return (r.returncode == 0 and report is not None and f'Head: {head}' in report.read_text()
            and (case / 'gh').read_text().splitlines() == [str(repo), str(repo)]
            and (report.parent / 'inputs/source.sh').read_bytes() == source.read_bytes())
def refused(result, message):
    r, case, _ = result
    return r.returncode == 2 and message in r.stderr and not (case / 'called').exists()
def bounded(result, bound):
    r, case, _ = result
    calls = (case / 'timeouts').read_text() if (case / 'timeouts').exists() else ''
    return r.returncode == 0 and bound in calls
def incomplete(result):
    r, _, report = result
    return r.returncode == 2 and report is not None and report.read_text().startswith('Model checking did not complete;')
inside = repo / 'Model.tla'
inside.write_text((work / 'Model.tla').read_text())
inside.with_suffix('.cfg').write_text((work / 'Model.cfg').read_text())
inside_view = repo / 'view.mjs'
inside_view.write_text((work / 'view.mjs').read_text())
mutated = work / 'mutated-compiler'
shutil.copytree(tree, mutated)
(mutated / 'dependency.ts').write_text('// changed reachable compiler bytes\n')
linked = work / 'linked-compiler'
shutil.copytree(tree, linked)
external = work / 'identical-dependency.ts'
external.write_bytes((tree / 'dependency.ts').read_bytes())
(linked / 'dependency.ts').unlink()
(linked / 'dependency.ts').symlink_to(external)
# Each control below must be rejected by the same behavioral check that passes on production.
checks = [
    ('scratch cwd binds both PR reads and source', {}, clean_ok, ('cd "$REPO" || error', '# cd "$REPO" || error')),
    ('bad jar refuses with valid inputs', {'BAD_JAR': '1'}, lambda x: refused(x, 'sha256 mismatch'), ('[ "${actual%% *}" = "$sha" ] || error', ': || error')),
    ('changed reachable runner tree refuses before execution', {'STATECHART': str(mutated / 'statechart')}, lambda x: refused(x, 'statechart tree sha256 mismatch'), ('[ "$runner_sha" = "$approved_tree" ] || error', ': || error')),
    ('identical-byte compiler symlink refuses before execution', {'STATECHART': str(linked / 'statechart')}, lambda x: refused(x, 'symlink in compiler tree'), ('    if p.is_symlink():\n        raise SystemExit(f\'symlink in compiler tree: {p}\')', '    if False:\n        raise SystemExit(f\'symlink in compiler tree: {p}\')')),
    ('unknown report exits incomplete', {'SCENARIO': 'unknown'}, lambda x: x[0].returncode == 2 and x[2] is not None and x[2].read_text().startswith('Model checking is incomplete;'), ("elif re.search(r'^## Rules that hold$', text, re.M):", 'elif True:')),
    ('every JVM has hard time and heap limits', {}, lambda x: bounded(x, '-k 5s 60s /usr/bin/true -Xmx512m -XX:ActiveProcessorCount=2'), ('-k 5s 60s %q -Xmx512m', '%q -Xmx512m')),
    ('whole compiler has hard timeout', {}, lambda x: bounded(x, '-k 10s 300s '), ('timeout -k 10s 300s "$runner"', '"$runner"')),
    ('failed runner cannot leave a clean report', {'SCENARIO': 'failed-runner'}, incomplete, ('if [ "$rc" -gt 1 ] || [ ! -s "$run/output/report.md" ]; then', 'if false; then')),
    ('missing runner report is explicitly incomplete', {'SCENARIO': 'no-report'}, incomplete, ('if [ "$rc" -gt 1 ] || [ ! -s "$run/output/report.md" ]; then', 'if false; then')),
    ('stale PR head is refused', {'SCENARIO': 'stale'}, lambda x: x[0].returncode == 2 and 'PR head changed' in x[0].stderr, ('[ "$latest" = "$head" ] || error', ': || error')),
    ('unchecked rules exit incomplete', {'SCENARIO': 'unchecked'}, lambda x: x[0].returncode == 2 and x[2] is not None and x[2].read_text().startswith('Model checking is incomplete;'), ('if grep -Eq', 'if false; then :; elif false && grep -Eq')),
    ('in-repo jar is refused', {'TLA2TOOLS': str(source)}, lambda x: refused(x, 'TLC must stay outside'), ('"$REPO"/*) error \'TLC must stay outside', '"/never-matches"/*) error \'TLC must stay outside')),
    ('in-repo model is refused', {'MODEL': str(inside)}, lambda x: refused(x, 'model and view in external scratch'), ('"$REPO"/*) error \'write the model', '"/never-matches"/*) error \'write the model')),
    ('in-repo view is refused', {'VIEW': str(inside_view)}, lambda x: refused(x, 'model and view in external scratch'), ('"$REPO"/*) error \'write the model', '"/never-matches"/*) error \'write the model')),
    ('symlink output component is refused', {'SCENARIO': 'output-link'}, lambda x: refused(x, 'symlink output component'), ('[ ! -L "$p" ] || error', ': || error')),
]
fails = 0
for name, args, predicate, (old, new) in checks:
    scenario = args.get('SCENARIO', 'clean')
    extra = {k: v for k, v in args.items() if k != 'SCENARIO'}
    result = run(scenario, **extra)
    if not predicate(result):
        print(f'FAIL: {name}: exit={result[0].returncode} stderr={result[0].stderr.strip()}')
        fails += 1
        continue
    if old not in text:
        print(f'FAIL: {name}: missing counterfactual seam')
        fails += 1
        continue
    control = work / f'control-{count}.sh'
    control.write_text(text.replace(old, new, 1))
    if predicate(run(scenario, script=control, **extra)):
        print(f'FAIL: {name}: removing guard stayed GREEN')
        fails += 1
    else:
        print(f'PASS: {name}; guard removal RED')
r, _, report = run(STATECHART=str(vendored / 'statechart'))
if r.returncode == 0 and report and f'Statechart tree SHA-256: {vendor_sha}' in report.read_text():
    control = work / 'vendor-pin-control.sh'
    control.write_text(text.replace(vendor_sha, tree_sha, 1))
    bad, case, _ = run(script=control, STATECHART=str(vendored / 'statechart'))
    if bad.returncode == 2 and not (case / 'called').exists():
        print('PASS: distinct vendored tree accepted and digest recorded; removing vendor pin RED')
    else:
        print('FAIL: removing vendored tree pin stayed GREEN')
        fails += 1
else:
    print(f'FAIL: vendored runner path/digest: {r.returncode} {r.stderr.strip()}')
    fails += 1
raise SystemExit(bool(fails))
PY
rc=$?
[ "$rc" -eq 0 ] || fails=$((fails + 1))
# The vendored compiler tree in this checkout must hash to the pin the wrapper and the doc both name.
python3 -I - "$SUT" "$HERE/../../../docs/internals/model-check.md" "$HERE/../../../marketplace/plugins/pstack/skills/statechart/scripts" <<'PY'
import hashlib, pathlib, re, sys
sut, doc, root = map(pathlib.Path, sys.argv[1:])
def digest(root):
    h = hashlib.sha256()
    for p in sorted(root.rglob('*')):
        if p.is_symlink():
            raise SystemExit(f'symlink in compiler tree: {p}')
        if p.is_dir():
            continue
        h.update(p.relative_to(root).as_posix().encode() + b'\0')
        h.update(hashlib.sha256(p.read_bytes()).digest())
    return h.hexdigest()
m = re.search(r'scripts/statechart\)\n\s+approved_tree=([0-9a-f]{64})', sut.read_text())
actual = digest(root)
fails = 0
if m and m.group(1) == actual:
    print('PASS: the vendored statechart tree digest equals the wrapper pin')
else:
    print(f'FAIL: vendored statechart tree digest {actual} != wrapper pin {m.group(1) if m else None}')
    fails += 1
if actual in doc.read_text():
    print('PASS: the vendored statechart tree digest is the one docs/internals/model-check.md names')
else:
    print(f'FAIL: docs/internals/model-check.md does not name vendored tree digest {actual}')
    fails += 1
raise SystemExit(bool(fails))
PY
rc=$?
[ "$rc" -eq 0 ] || fails=$((fails + 1))
printf '%s failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
