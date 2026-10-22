#!/usr/bin/env python3
"""Independent lexical suite-file resolver: exact edges, scan probes and unknowns.

No selector maps are read. Source/execute edges are transitive; path reads are
leaves. Directory scans produce absent paths rather than expanding the tree.
Runtime-built paths and unresolved scan roots are reported, never made root.
"""
import argparse
import json
import os
import posixpath
import re
import shlex
import subprocess

SUITE = re.compile(r'(^|/)test-[^/]*\.sh$|\.test\.(mjs|js|ts)$')
REGISTRY = {
    'scripts/testing/test-unwired-hooks.sh',
    'scripts/observability/test-ledgers-registry.sh',
    'scripts/ci/test-check-host-file-read-sinks.sh',
}
CLOSURE_WALKERS = ('scripts/cr/test-cr-guarded-closure.sh',)
PATH = re.compile(r'(?:\$\{?[A-Za-z_]\w*\}?/|\.{1,2}/|/)?[A-Za-z0-9_.*?\[\]@-]+(?:/[A-Za-z0-9_.*?\[\]@-]+)+|/[A-Za-z0-9_.*?\[\]@-]+|[A-Za-z0-9_.-]+\.(?:sh|mjs|cjs|js|ts|py|json|md|html|txt|tsv|yaml|yml)')
VARIABLE = re.compile(r'\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))')
UNKNOWN = re.compile(r'\$\{[^}]*\}(?:/[^\s;]*)?|\$[A-Za-z_]\w*(?:/[^\s;]*)?')
CODE = ('.sh', '.js', '.mjs', '.cjs', '.ts', '.py')


def tree(repo, ref):
    scrub = {'GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
             'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX',
             'GIT_IMPLICIT_WORK_TREE', 'GIT_GRAFT_FILE', 'GIT_REPLACE_REF_BASE',
             'GIT_SHALLOW_FILE', 'GIT_CONFIG', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT'}
    environment = {key: value for key, value in os.environ.items() if key not in scrub}
    def git(*args, **kwargs):
        return subprocess.check_output(['git', '-C', repo, *args], env=environment, **kwargs)
    entries = []
    for row in git('ls-tree', '-rz', ref).split(b'\0'):
        if row:
            metadata, name = row.split(b'\t', 1)
            mode, kind, oid = metadata.split()
            if kind == b'blob':
                entries.append((name.decode(), oid.decode(), mode))
    raw = git('cat-file', '--batch', input=''.join(oid + '\n' for _, oid, _ in entries).encode())
    contents, offset = {}, 0
    for name, _, mode in entries:
        end = raw.index(b'\n', offset)
        size = int(raw[offset:end].split()[2])
        data = raw[end + 1:end + 1 + size]
        contents[name] = '' if mode == b'120000' or b'\0' in data else data.decode('utf-8', errors='replace')
        offset = end + size + 2
    return contents


def commands(line):
    """Command positions only: quoted examples and find predicates are data."""
    # Keep quoted wildcard provenance until for-loop expansion is classified.
    shielded = re.sub(r"'[^']*'|\"[^\"]*\"", lambda match: match[0].translate(str.maketrans('*?[$', '')), line)
    try:
        lexer = shlex.shlex(shielded, posix=True, punctuation_chars=';&|()')
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        return
    chunk = []
    for token in tokens + [';']:
        if token and all(char in ';&|()' for char in token):
            while chunk and (chunk[0] in ('if', 'then', 'do', 'else', '!', '{') or re.match(r'^\w+=', chunk[0])):
                chunk.pop(0)
            if chunk:
                yield chunk
            chunk = []
        else:
            chunk.append(token)
    # Double-quoted substitutions are one token. Preserve their literal
    # operands; only a substitution itself inside single quotes is data.
    quoted = [(match.start(), match.end()) for match in re.finditer(r"'[^']*'", line)]
    for match in re.finditer(r'\$\(([^()]*)\)', line):
        if not any(start < match.start() < end for start, end in quoted):
            yield from commands(match[1])


def resolve(contents, closure_walkers=CLOSURE_WALKERS):
    files = set(contents)
    directories = {'.'}
    for path in files:
        directory = posixpath.dirname(path)
        while directory:
            directories.add(directory)
            directory = posixpath.dirname(directory)
    cache = {}

    def edges(path):
        if path in cache:
            return cache[path]
        base = posixpath.dirname(path)
        variables = {name: '/@repo' for name in ('ROOT', 'REPO_ROOT', 'REPO', 'root', 'repo_root')}
        variables.update({name: '/@repo/' + base for name in ('DIR', 'HERE', 'SCRIPT_DIR', 'dir', 'here')})
        exact, calls, scans, unknown = set(), set(), set(), set()
        array_dirs, loop_dirs = {}, {}
        heredoc, scan_buffer, cwd, noglob = None, '', '/@repo', False

        def normalize(token, relative_to=None):
            if token == '/@repo':
                return '.'
            if token.startswith('/@repo/'):
                return posixpath.normpath(token[7:])
            if token.startswith('/'):
                return None
            if relative_to is not None:
                return posixpath.normpath(posixpath.join(relative_to, token))
            if '$' in cwd:
                return None
            return posixpath.normpath(posixpath.join(cwd.removeprefix('/@repo/').replace('/@repo', '.'), token))

        def directories_of(token):
            token = token.translate(str.maketrans('', '*?[$'))
            reference = re.fullmatch(r'\$\{([A-Za-z_]\w*)\[@\]\}', token)
            if reference:
                return array_dirs.get(reference[1], set())
            reference = re.fullmatch(r'\$\{?([A-Za-z_]\w*)\}?', token)
            if reference and reference[1] in loop_dirs:
                return loop_dirs[reference[1]]
            token = VARIABLE.sub(lambda match: variables.get(match[1] or match[2], match[0]), token)
            directory = normalize(token)
            return {directory} if directory in directories else set()

        def record_scans(raw, number, expand):
            nonlocal cwd, noglob
            for words in commands(raw):
                if words[0] != 'for':
                    words = [word.translate(str.maketrans('', '*?[$')) for word in words]
                verb, args = words[0], words[1:]
                if verb == 'set':
                    if '-f' in args:
                        noglob = True
                    elif '+f' in args:
                        noglob = False
                if path.endswith('.sh') and verb not in ('echo', 'printf', 'local', 'export', 'readonly', 'for', 'case', 'select'):
                    read_args = list(args)
                    if verb in ('grep', 'sed', 'awk', 'jq'):
                        read_args, need_program, skip = [], True, False
                        for arg in args:
                            if skip:
                                skip = False
                                continue
                            if arg in ('-e', '--regexp', '--expression', '--arg', '--argjson'):
                                need_program, skip = False, True
                            elif arg.startswith('-'):
                                continue
                            elif need_program:
                                need_program = False
                            else:
                                read_args.append(arg)
                    for operand in read_args:
                        target = normalize(expand(operand))
                        if target in files:
                            exact.add(target)
                if path.endswith('.sh') and verb in ('source', '.', 'bash', 'sh', 'node', 'bun', 'python', 'python3', 'exec', 'tsx', 'deno'):
                    operands = [arg for arg in args if arg == '-' or not arg.startswith('-')]
                    if operands:
                        target = normalize(expand(operands[0]))
                        if target in files:
                            exact.add(target)
                            if target.endswith(CODE) and not any(arg in ('-c', '-e', '--eval', '--check', '-n') for arg in args):
                                calls.add(target)
                if verb == 'local':
                    for name in args:
                        if name.isidentifier():
                            variables.pop(name, None)
                if verb == 'for' and args and path.endswith('.sh'):
                    variables.pop(args[0], None)
                    loop_dirs[args[0]] = set().union(*(directories_of(token) for token in args[2:]))
                if 'read' in words and path.endswith('.sh'):
                    for name in words[words.index('read') + 1:]:
                        if name.isidentifier():
                            variables.pop(name, None)
                if verb == 'cd' and args:
                    target = expand(args[0])
                    cwd = target if target.startswith(('/', '$')) else posixpath.join(cwd, target)
                    continue
                patterns = tuple(arg.split('=', 1)[1] for arg in args if arg.startswith('--include='))
                patterns += tuple(args[i + 1] for i, arg in enumerate(args[:-1]) if arg == '-name')
                recursive, roots = True, []
                if verb == 'find':
                    for arg in args:
                        if arg.startswith('-') or arg in ('!', '('):
                            break
                        roots.append(arg)
                    recursive = '-maxdepth' not in args or args[args.index('-maxdepth') + 1] != '1'
                elif verb == 'grep' and any(arg == '--recursive' or re.match(r'^-[A-Za-z]*[rR]', arg) for arg in args):
                    need_pattern, skip = True, False
                    for arg in args:
                        if skip:
                            skip = False
                            continue
                        if arg in ('-e', '-f'):
                            need_pattern, skip = False, True
                        elif arg.startswith('-'):
                            continue
                        elif need_pattern:
                            need_pattern = False
                        else:
                            roots.append(arg)
                elif verb == 'git' and 'ls-files' in args:
                    git_cwd = expand(args[args.index('-C') + 1]) if '-C' in args else cwd
                    tail = args[args.index('ls-files') + 1:]
                    pathspecs = tail[tail.index('--') + 1:] if '--' in tail else [arg for arg in tail if not arg.startswith('-')]
                    for spec in pathspecs:
                        spec = expand(spec)
                        if spec.startswith((':(exclude)', ':!', ':^')):
                            continue
                        candidate = spec if spec.startswith('/') else posixpath.join(git_cwd, spec)
                        if '$' in candidate:
                            unknown.add(f'{path}:{number} unresolved pathspec={candidate}')
                            continue
                        candidate = normalize(candidate)
                        if candidate is None:
                            continue
                        if any(char in candidate for char in '*?['):
                            prefix = re.split(r'[*?\[]', candidate, 1)[0]
                            directory = posixpath.dirname(prefix) or '.'
                            pattern = candidate[len(directory) + 1:] if directory != '.' else candidate
                            scans.add((directory, (pattern,), True, f'{path}:{number} pathspec={spec}'))
                        elif candidate in files:
                            exact.add(candidate)
                        elif candidate in directories:
                            scans.add((candidate, (), True, f'{path}:{number} pathspec={spec}'))
                    if not pathspecs:
                        roots = [git_cwd]
                elif verb == 'for' and path.endswith('.sh') and not noglob and len(args) > 1 and args[1] == 'in':
                    for token in args[2:]:
                        token = re.sub('' + r'(\{[A-Za-z_]\w*\}|[A-Za-z_]\w*)', lambda match: expand('$' + match[1]).translate(str.maketrans('*?[', '')), token)
                        token = expand(token.replace('', '$'))
                        if '$' in token:
                            if any(char in token for char in '*?['):
                                unknown.add(f'{path}:{number} unresolved glob={token}')
                            continue
                        candidate = normalize(token)
                        if candidate is None or not any(char in candidate for char in '*?['):
                            continue
                        prefix = re.split(r'[*?\[]', candidate, 1)[0]
                        directory = posixpath.dirname(prefix) or '.'
                        pattern = candidate[len(directory) + 1:] if directory != '.' else candidate
                        scans.add((directory, (pattern,), '**' in candidate, f'{path}:{number} glob={token}'))
                for token in roots:
                    token = expand(token)
                    if '[@]' in token:
                        resolved_dirs = directories_of(token)
                        for directory in resolved_dirs:
                            scans.add((directory, patterns, recursive, f'{path}:{number} scan array root={directory}'))
                        if not resolved_dirs:
                            unknown.add(f'{path}:{number} unresolved array root={token}')
                        continue
                    if '$' in token:
                        unknown.add(f'{path}:{number} unresolved root={token}')
                        continue
                    if not token.startswith('/'):
                        token = posixpath.join(cwd, token)
                    if '$' in token:
                        unknown.add(f'{path}:{number} unresolved cwd/root={token}')
                        continue
                    directory = normalize(token)
                    if directory in directories:
                        scans.add((directory, patterns, recursive, f'{path}:{number} root={token}'))

        text = contents[path]
        if path.endswith(('.js', '.mjs', '.cjs', '.ts')):
            comments = r'''("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)|//[^\n]*|/\*.*?\*/'''
            text = re.sub(comments, lambda match: match[0] if match[1] else re.sub(r'[^\n]', ' ', match[0]), text, flags=re.S)
        for number, original in enumerate(text.replace('\\\n', '').splitlines(), 1):
            if heredoc:
                if original.strip() == heredoc:
                    heredoc = None
                continue
            marker = re.search(r'<<-?\s*[\"\']?([A-Za-z_]\w*)[\"\']?', original)
            if marker:
                heredoc = marker[1]
            directive = re.search(r'^\s*#\s*shellcheck\s+source=([^\s]+)', original)
            if original.lstrip().startswith('#') and not directive:
                continue
            line = original.replace('"', '').replace("'", '')
            expand = lambda value: VARIABLE.sub(lambda m: variables.get(m[1] or m[2], m[0]), value)
            for name, value in re.findall(r'\b([A-Za-z_]\w*)=([^\s;]+)', line):
                value = expand(value)
                if not any(char in value for char in '$()`'):
                    variables[name] = value
                elif name in variables and not any(word in line for word in ('dirname', '--show-toplevel', 'pwd')):
                    variables.pop(name)
            dirname_alias = re.match(r'''^\s*([A-Za-z_]\w*)=["']?\$\(cd\s+["']?\$\(dirname\s+["']?(?:\$0|\$\{BASH_SOURCE\[0\]\})["']?\)([A-Za-z0-9_./-]*)["']?\s*&&\s*pwd\)([A-Za-z0-9_./-]*)''', original)
            if dirname_alias:
                variables[dirname_alias[1]] = posixpath.normpath('/@repo/' + base + dirname_alias[2] + dirname_alias[3])
            for assignment in re.finditer(r'\b([A-Za-z_]\w*)(\+?=)\(([^)]*)\)', original):
                try:
                    values = shlex.split(assignment[3])
                except ValueError:
                    continue
                collected = set().union(*(directories_of(value) for value in values))
                if assignment[2] == '+=':
                    array_dirs.setdefault(assignment[1], set()).update(collected)
                else:
                    array_dirs[assignment[1]] = collected
            scan_buffer += original + '\n'
            try:
                shlex.split(scan_buffer, comments=True)
            except ValueError:
                pass
            else:
                record_scans(scan_buffer, number, expand)
                scan_buffer = ''
            line = UNKNOWN.sub('', expand(line))
            tokens = PATH.findall(line)
            if '=(' in line:
                tokens += re.findall(r'(?<![\w/.-])[A-Za-z_.-]+(?=[\s)])', line)
            if directive:
                target = normalize(expand(directive[1]))
                if target in files:
                    exact.add(target)
                    calls.add(target)
            if path.endswith(('.js', '.mjs', '.cjs', '.ts')):
                js_tokens = re.findall(r'''"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|[A-Za-z_$][\w$]*|[^\s]''', original)
                for index, verb in enumerate(js_tokens[:-1]):
                    importing = verb in ('import', 'from', 'require')
                    if not importing and verb not in ('readFile', 'readFileSync', 'readdir', 'readdirSync', 'open', 'openSync'):
                        continue
                    operand = index + 1
                    if js_tokens[operand] == '(':
                        operand += 1
                    if operand >= len(js_tokens) or not js_tokens[operand].startswith(('"', "'")):
                        continue
                    token = js_tokens[operand][1:-1]
                    candidate = normalize(token, base) if importing and token.startswith('.') else normalize(token)
                    if candidate in files:
                        exact.add(candidate)
                        if importing and candidate.endswith(CODE):
                            calls.add(candidate)
            elif not path.endswith('.sh'):
                for token in tokens:
                    candidate = normalize(token)
                    if candidate in files:
                        exact.add(candidate)
        cache[path] = exact, calls, scans, unknown
        return cache[path]

    result = {'files': {}, 'probes': {}, 'whole_repo': {}, 'unresolved': {}, 'closure_pins': []}
    for walker in closure_walkers:
        assert walker in files, f'walker row stale: {walker} missing'
        text = contents[walker]
        assert '<himmel_dir>/scripts/' in text and '/scripts/cr/*.' in text, f'walker row stale: {walker} seeds changed'
    for suite in sorted(files):
        if not SUITE.search(suite) or suite in REGISTRY:
            continue
        dependencies, visited, queue = {suite}, set(), [suite]
        suite_scans, unknown = set(), set()
        not_run, dist_primary = set(), set()
        if suite in closure_walkers:
            runbooks = [name for name in files if name in ('.claude/commands/pr-check.md', '.agents/skills/pr-check/SKILL.md') or name.startswith('scripts/cr/pr-check-ref/') and name.endswith('.md')]
            for runbook in runbooks:
                dependencies.add(runbook)
                queue += re.findall(r'<himmel_dir>/(scripts/[A-Za-z0-9_./-]+\.(?:sh|js|mjs|py))', contents[runbook])
            queue += [name for name in files if posixpath.dirname(name) == 'scripts/cr' and not posixpath.basename(name).startswith('test-') and name.endswith(('.sh', '.js', '.mjs'))]
            if 'scripts/cr/pr-check-context.sh' in files:
                dependencies.add('scripts/cr/pr-check-context.sh')
            pinned = re.search(r'^NOT_RUN="(.*?)"', contents[suite], re.M | re.S)
            not_run = set(pinned[1].splitlines()) if pinned else set()
            pinned = re.search(r'^DIST_PRIMARY="(.*?)"', contents[suite], re.M | re.S)
            dist_primary = {line.split('::', 1)[0] for line in pinned[1].splitlines()} if pinned else set()
            result['closure_pins'] += sorted(not_run | {parent + ' -> scripts/jira/dist/* (primary)' for parent in dist_primary})
        while queue:
            path = queue.pop()
            if path in visited or path not in files:
                continue
            visited.add(path)
            exact, calls, scans, unresolved = edges(path)
            def permitted(target):
                return f'{path} -> {target}' not in not_run and not (path in dist_primary and target.startswith('scripts/jira/dist/'))
            dependencies.update(target for target in exact if permitted(target))
            queue.extend(target for target in calls - visited if permitted(target))
            # A closure walker reads scripts; its script globs are seeds, not
            # directory-content assertions. The independent walk handles them.
            if path != suite or suite not in closure_walkers:
                suite_scans.update(scans)
            unknown.update(unresolved)
        probes, whole = set(), set()
        for directory, patterns, recursive, site in suite_scans:
            if directory == '.':
                whole.add(site)
                continue
            if not patterns:
                extensions = {posixpath.splitext(file)[1] for file in files if file.startswith(directory + '/')}
                patterns = tuple('*' + extension for extension in extensions)
            for pattern in patterns:
                name = pattern.replace('*', 'zz-oracle-probe').replace('?', 'x')
                name = re.sub(r'\[[^]]+\]', 'x', name)
                probes.add(directory + '/' + name)
                if recursive:
                    probes.add(directory + '/zz-oracle-depth/' + name)
        result['files'][suite] = sorted(dependencies)
        result['probes'][suite] = sorted(probes)
        result['unresolved'][suite] = sorted(unknown)
        if whole:
            result['whole_repo'][suite] = sorted(whole)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default='.')
    parser.add_argument('--ref', default='HEAD')
    args = parser.parse_args()
    print(json.dumps(resolve(tree(args.repo, args.ref)), sort_keys=True))


if __name__ == '__main__':
    main()
