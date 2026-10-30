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
]
fails = 0
for name, text, expected in fixtures:
    (work / 'output/report.md').write_text(text)
    r = subprocess.run([sys.executable, '-I', '-c', code, str(work), '123', 'a' * 40, 'scripts/handover/queue-lock.sh'])
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
# Without repository binding, an absolute invocation from scratch cannot read the intended PR.
# Only the external boundaries are doubled; the real wrapper, git source read and formatter run.
python3 -I - "$SUT" "$WORK" <<'PY'
import json, os, pathlib, subprocess, sys
sut, work = map(pathlib.Path, sys.argv[1:])
repo = sut.parents[3]
head = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
bin_dir = work / 'bin'
bin_dir.mkdir()
def executable(name, text):
    p = bin_dir / name
    p.write_text('#!/bin/bash\n' + text)
    p.chmod(0o700)
# No external jar/compiler executes: these doubles isolate orchestration from optional runtimes.
executable('sha256sum', 'printf "%s  fixture\\n" 936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88\n')
executable('gh', '''[ "$PWD" = "$EXPECTED_REPO" ] || exit 77
printf '%s\\n' "$PWD" >> "$GH_CALLS"
case " $* " in
  *' --jq '*) printf '%s\\n' "$EXPECTED_HEAD" ;;
  *) printf '%s\\n' "$PR_METADATA" ;;
esac
''')
executable('statechart', '''while [ "$#" -gt 0 ]; do
  if [ "$1" = --out ]; then out="$2"; break; fi
  shift
done
mkdir -p "$out" || exit 2
printf '# Model\\n\\n## Rules that hold\\nSafe\\n' > "$out/report.md"
printf 'stateDiagram-v2\\n' > "$out/chart.mmd"
''')
(work / 'Model.tla').write_text('---- MODULE Model ----\n====\n')
(work / 'Model.cfg').write_text('SPECIFICATION Spec\n')
(work / 'view.mjs').write_text('export const title = "fixture";\n')
(work / 'bucket').mkdir()
env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
           JAVA='/usr/bin/true', TLA2TOOLS=str(work / 'tla2tools.jar'),
           STATECHART=str(bin_dir / 'statechart'), HANDOVER_DIR=str(work / 'bucket'), USER_SLUG='fixture',
           EXPECTED_REPO=str(repo), EXPECTED_HEAD=head, GH_CALLS=str(work / 'gh-calls'),
           PR_METADATA=json.dumps({'headRefOid': head, 'files': [{'path': 'scripts/handover/queue-lock.sh'}]}))
r = subprocess.run(['bash', str(sut), '4313', 'queue-lock', str(work / 'Model.tla'), str(work / 'view.mjs')],
                   cwd=work, env=env, capture_output=True, text=True)
if r.returncode != 0:
    print(f'FAIL: absolute invocation from scratch binds PR and source to its own repo (exit {r.returncode}: {r.stderr.strip()})')
    raise SystemExit(1)
calls = (work / 'gh-calls').read_text().splitlines()
reports = list((work / 'bucket').rglob('report.md'))
assert calls == [str(repo), str(repo)], calls
report = next(p for p in reports if p.parent.name.startswith('pr-4313-'))
assert f'Head: {head}' in report.read_text()
assert (report.parent / 'inputs/source.sh').read_bytes() == subprocess.check_output(['git', '-C', str(repo), 'show', f'{head}:scripts/handover/queue-lock.sh'])
print('PASS: absolute invocation from scratch binds both PR reads and source to its own repo')
PY
rc=$?
[ "$rc" -eq 0 ] || fails=$((fails + 1))
printf '%s failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
