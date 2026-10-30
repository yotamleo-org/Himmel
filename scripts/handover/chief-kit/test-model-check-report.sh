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
printf '%s failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
