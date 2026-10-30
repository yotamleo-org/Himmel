#!/usr/bin/env bash
# Platform guard: POSIX bash 3.2+; git and python3.
# Only added non-test lines are judged; removals and unchanged code never fail.
# The audit-backed allowlist keeps exact detector lines, not entire files.
# Usage: check-platform-dropped.sh --range <base> | --diff <unified-diff>
# Exit: 0 clean, 1 findings, 2 cannot evaluate (fail closed).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd) || exit 2
python3 -I - "$HERE" "$@" <<'PY'
import ast
import json
import pathlib
import re
import subprocess
import sys


def in_scope(path):
    parts = pathlib.PurePosixPath(path).parts
    if not (path.startswith('scripts/') or path.startswith('marketplace/plugins/himmel-ops/')):
        return False
    if path.endswith('.md') or path == 'scripts/lint/platform-dropped-allow.json':
        return False
    if any(p in ('test', 'tests', '__tests__', 'fixtures', 'node_modules', 'claude-hud') for p in parts):
        return False
    return not (parts[-1].startswith(('test-', 'test_')) or re.search(r'\.(test|spec)\.', parts[-1]))


def added_lines(diff):
    path = None
    old_left = new_left = line_number = 0
    seen = False
    for line in diff.split('\n'):
        if old_left or new_left:
            if line.startswith('\\ No newline at end of file'):
                continue
            kind = line[:1]
            if kind not in ('+', '-', ' '):
                raise ValueError('malformed diff hunk')
            if kind in ('-', ' '):
                old_left -= 1
            if kind in ('+', ' '):
                if kind == '+' and in_scope(path):
                    yield path, line_number, line[1:]
                new_left -= 1
                line_number += 1
            if old_left < 0 or new_left < 0:
                raise ValueError('inconsistent diff hunk')
            continue
        if line.startswith('diff --git '):
            seen = True
            path = None
        elif line.startswith('+++ '):
            name = line[4:].split('\t', 1)[0]
            if name.startswith('"'):
                name = ast.literal_eval(name)
                name = name.encode('latin1').decode('utf-8', 'surrogateescape')
            if name == '/dev/null':
                path = ''
            elif name.startswith('b/'):
                path = name[2:]
            else:
                raise ValueError('unexpected diff destination')
        elif line.startswith('@@ '):
            match = re.match(r'^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@', line)
            if path is None or match is None:
                raise ValueError('malformed diff header')
            old_left = int(match[1] or 1)
            line_number = int(match[2])
            new_left = int(match[3] or 1)
    if old_left or new_left or (diff.strip() and not seen):
        raise ValueError('incomplete or invalid diff')


def main():
    here = pathlib.Path(sys.argv[1])
    args = sys.argv[2:]
    if len(args) != 2 or args[0] not in ('--range', '--diff'):
        raise ValueError('usage: check-platform-dropped.sh --range <base> | --diff <file>')
    patterns = [line.strip() for line in (here / '../handover/chief-kit/platform-dropped.re').read_text().splitlines()
                if line.strip() and not line.startswith('#')]
    if len(patterns) != 1:
        raise ValueError('expected one shared detector pattern')
    detector = re.compile(patterns[0], re.I)
    allow = json.loads((here / 'platform-dropped-allow.json').read_text())
    if not isinstance(allow, dict) or not allow:
        raise ValueError('empty or invalid allowlist')
    for path, row in allow.items():
        if not isinstance(row, dict) or not isinstance(row.get('reason'), str) or not row['reason'].strip():
            raise ValueError('allowlist entry needs a reason: ' + path)
        if not isinstance(row.get('lines'), list) or not row['lines'] or not all(isinstance(s, str) and s for s in row['lines']):
            raise ValueError('allowlist entry needs exact lines: ' + path)
    if args[0] == '--diff':
        diff = pathlib.Path(args[1]).read_text(errors='surrogateescape')
    else:
        base = subprocess.check_output(['git', 'rev-parse', '--verify', args[1] + '^{commit}'], text=True).strip()
        diff = subprocess.check_output(['git', 'diff', '--patch', '-U0', '--text', '--no-textconv',
                                        '--no-ext-diff', '--no-color', '--find-renames',
                                        '--src-prefix=a/', '--dst-prefix=b/', base, 'HEAD', '--'],
                                       text=True, errors='surrogateescape')
    findings = 0
    for path, number, text in added_lines(diff):
        if detector.search(text) and text not in allow.get(path, {}).get('lines', []):
            print(f'{path}:{number}: dropped-platform addition: {text}')
            findings += 1
    print(f'check-platform-dropped: {findings} new unallowlisted hits')
    return 1 if findings else 0


try:
    sys.exit(main())
except (OSError, ValueError, TypeError, SyntaxError, re.error, subprocess.CalledProcessError) as error:
    print(f'check-platform-dropped: cannot evaluate: {error}', file=sys.stderr)
    sys.exit(2)
PY
