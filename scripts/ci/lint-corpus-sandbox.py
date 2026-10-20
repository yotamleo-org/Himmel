#!/usr/bin/env python3
"""HIMMEL-4912: reject recognizable unwrapped launches in owned corpus harnesses.

Other fixture/replay harnesses warn until migrated (console-scoped first slice).
This is an architecture lint, not a shell interpreter or a malicious-code audit:
dynamic launch forms in the owned Python harness fail closed when unprovable.
"""
import ast
import pathlib
import re
import sys

ENFORCED = (
    "scripts/eval/guard-corpus/diff",
    "scripts/hooks/lib-test-block-destructive.sh",
    "scripts/hooks/test-block-destructive-commands-a.sh",
    "scripts/hooks/test-block-destructive-commands-b.sh",
    "scripts/hooks/test-block-destructive-commands-c.sh",
    "scripts/hooks/test-block-destructive-commands-d.sh",
)
FOLLOW_UPS = (
    "scripts/hooks/test-hook-chain-latency.sh",
    "scripts/hooks/test-block-chokepoint-env-prefix.sh",
    "scripts/codex/hook-smoke-demo.sh",
    "scripts/hooks/bench-hook-stack.mjs",
)


def python_launches(text):
    tree = ast.parse(text)
    assignments = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    assignments.setdefault(target.id, []).append(node.value)

    def runner_name(node):
        if not isinstance(node, ast.Name):
            return False
        values = assignments.get(node.id, [])
        def path_expression(value):
            if isinstance(value, ast.Constant) and isinstance(value.value, str):
                return True
            if isinstance(value, ast.Name) and value.id == "__file__":
                return True
            return (isinstance(value, ast.Call) and not value.keywords
                    and ast.unparse(value.func) in ("os.path.join", "os.path.dirname", "os.path.abspath")
                    and bool(value.args) and all(path_expression(arg) for arg in value.args))

        def runner_expression(value):
            if isinstance(value, ast.Constant) and isinstance(value.value, str):
                return pathlib.PurePosixPath(value.value).name == "sandbox-run.sh"
            if not (isinstance(value, ast.Call) and path_expression(value)):
                return False
            name = ast.unparse(value.func)
            if name == "os.path.abspath" and len(value.args) == 1:
                return runner_expression(value.args[0])
            return (name == "os.path.join" and isinstance(value.args[-1], ast.Constant)
                    and value.args[-1].value == "sandbox-run.sh")

        return len(values) == 1 and runner_expression(values[0])

    errors = []
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id == "subprocess"
                and node.func.attr in ("Popen", "run", "call", "check_call", "check_output")):
            continue
        args = node.args[0] if node.args else None
        # Require the prefix at the call site, never infer it from a mutable argv.
        while isinstance(args, ast.BinOp) and isinstance(args.op, ast.Add):
            args = args.left
        if isinstance(args, (ast.List, ast.Tuple)) and args.elts:
            first = args.elts[0]
            if isinstance(first, ast.Constant) and first.value == "git":
                continue
            if (isinstance(first, ast.Constant) and first.value == "bash"
                    and len(args.elts) >= 2 and runner_name(args.elts[1])):
                continue
        errors.append((node.lineno, "subprocess launch is not provably sandboxed"))
    return errors


def logical_lines(text):
    """Yield (first line number, text) with backslash continuations joined."""
    pending, first = "", 0
    for number, line in enumerate(text.splitlines(), 1):
        if not pending and line.lstrip().startswith("#"):
            continue
        if not pending:
            first = number
        if re.search(r'(?<!\\)(?:\\\\)*\\$', line):
            pending += line[:-1]
            continue
        yield first, pending + line
        pending = ""
    if pending:
        yield first, pending


def code_positions(line):
    """Per character: True where the shell reads code, False inside quotes.

    A command substitution or parenthesis opens code again, also inside double quotes.
    """
    code, stack, i = [False] * len(line), ["code"], 0
    while i < len(line):
        char = line[i]
        if char == "\\":
            code[i:i + 2] = [stack[-1] != "dq"] * 2
            i += 2
            continue
        if stack[-1] == "dq":
            if char == '"':
                stack.pop()
            elif char == "(" and line[i - 1] == "$":
                stack.append("paren")
                code[i] = True
        else:
            code[i] = True
            if char == "'":
                end = line.find("'", i + 1)
                if end < 0:
                    break
                code[i:end + 1] = [False] * (end + 1 - i)
                i = end
            elif char == '"':
                stack.append("dq")
            elif char == "(":
                stack.append("paren")
            elif char == ")" and stack[-1] == "paren":
                stack.pop()
        i += 1
    return code


def shell_launches(text):
    errors = []
    # Require the owned runner path at the call site, never a mutable binding.
    command = 'bash "$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh"'
    # Fail closed: any reference to a hook-like variable, and any variable run
    # directly by bash/sh/dash/zsh/ksh/env/python/exec/source/dot, is a launch
    # unless it sits after a wrapper's `--` or is one of the listed non-launch
    # uses. Other launch verbs (eval, command, timeout, nohup, xargs, a bare
    # "$T") are caught only when the variable is hook-named.
    name = r'[A-Za-z_0-9]*hook[A-Za-z_0-9]*'
    reference = re.compile(r'\$\{?' + name, re.I)
    # An operand is a run of escapes, bare characters and quoted strings; the
    # first `$` reached inside one is the variable (or substitution) it runs.
    piece = r'(?:\\.|"(?:[^"\\$]|\\.)*"|\'[^\']*\'|[^\s\\"\'$`;|&()])'
    runs_variable = re.compile(
        r'(?P<verb>\b(?:bash|sh|dash|zsh|ksh|env|python3?|exec|source)|(?<![\w$.])\.)'
        r'(?=\s+(?:' + piece + r'+\s+)*' + piece + r'*(?:"(?:[^"\\$]|\\.)*)?(?P<ref>\$))')
    # The one shared lib the owned suites source, by its exact path expression.
    lib_source = '. "$(cd "$(dirname "$0")" && pwd)/lib-test-block-destructive.sh"'
    ref = r'["\']?\$\{?' + name
    non_launch = re.compile(
        r'(?:\[\[?|\btest)\s+-[a-z]\s+' + ref
        + r'|\bchmod\s+[-+=a-z,]+\s+' + ref
        + r'|\bcp\s+' + ref, re.I)
    wrapper = re.compile(re.escape(command) + r'[^;|&]*?\s+--\s')
    for number, line in logical_lines(text):
        wrappers = list(wrapper.finditer(line))
        # Only the exact runner path expression is exempt; anything else before
        # the `--` (a command substitution, say) runs on the host.
        owned = [(w.start(), w.start() + len(command)) for w in wrappers]
        owned += [(m.start(), m.end()) for m in re.finditer(re.escape(lib_source), line)]
        allowed = list(non_launch.finditer(line))
        positions = {m.start() for m in reference.finditer(line)}
        # A verb inside quotes is payload data, so it runs nothing; hook-named
        # references above are still scanned wherever they sit.
        code = code_positions(line)
        positions |= {m.start("ref") for m in runs_variable.finditer(line)
                      if code[m.start("verb")]}
        for position in sorted(positions):
            if any(start <= position < end for start, end in owned):
                continue
            if any(m.start() <= position < m.end() for m in allowed):
                continue
            covering = [w for w in wrappers if w.end() <= position]
            if covering:
                between = line[covering[-1].end():position]
                # A wrapper protects only its own simple command, never a later
                # one, and never a substitution the host shell expands first.
                # Quoting is not parsed, so any parenthesis or backtick between the
                # delimiter and the reference refuses it.
                if not re.search(r'[;|&`(]', between):
                    continue
            errors.append((number, "hook reference outside a sandbox-run.sh wrapper"))
    return errors


def main(root):
    failures = 0
    for relative in ENFORCED:
        path = root / relative
        if not path.is_file():
            print("FAIL %s: enforced harness missing" % relative)
            failures += 1
            continue
        text = path.read_text()
        if "sandbox-run.sh" not in text:
            print("FAIL %s: sandbox runner missing" % relative)
            failures += 1
        try:
            errors = python_launches(text) if path.name == "diff" else shell_launches(text)
        except SyntaxError as error:
            errors = [(error.lineno, "cannot parse harness")]
        for line, reason in errors:
            print("FAIL %s:%s: %s" % (relative, line, reason))
            failures += 1
    warned = set(FOLLOW_UPS)
    # Discover additional fixture/corpus owners, not just the curated inventory.
    for base in (root / "scripts", root / "marketplace"):
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if (path.suffix not in (".sh", ".py", ".mjs") or not path.is_file()
                    or not re.search(r'test|bench|smoke|probe|replay', path.name, re.I)):
                continue
            text = path.read_text(errors="replace")
            if (re.search(r'\b(corpus|replay)\b|tool_input', text, re.I)
                    and re.search(r'\bHOOK\b|scripts/hooks/|hook_path', text)):
                warned.add(str(path.relative_to(root)))
    for relative in sorted(warned - set(ENFORCED)):
        if (root / relative).is_file() and relative != "scripts/ci/lint-corpus-sandbox.py":
            print("WARN %s: migration follow-up; not certified sandboxed" % relative)
    print("corpus-sandbox lint: %s" % ("FAIL" if failures else "PASS"))
    return bool(failures)


if __name__ == "__main__":
    root = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[2]
    sys.exit(main(root))
