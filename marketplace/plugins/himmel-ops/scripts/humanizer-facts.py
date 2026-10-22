"""Compare literal facts in a draft and rewrite; '-' reads the draft from stdin."""
import collections
import pathlib
import re
import sys


def facts(text):
    protected = collections.Counter()
    fence = None
    block = []
    prose = []
    indented = []
    for line in text.splitlines(keepends=True):
        if not fence and (line.startswith(("    ", "\t")) or (indented and not line.strip())):
            indented.append(line)
            continue
        if indented:
            protected[("code", "".join(indented))] += 1
            indented = []
        match = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line.rstrip("\r\n"))
        if fence:
            block.append(line)
            if (match and match[1][0] == fence[0] and
                    len(match[1]) >= len(fence) and not match[2].strip()):
                protected[("code", "".join(block))] += 1
                fence = None
                block = []
        elif match:
            fence = match[1]
            block = [line]
        else:
            prose.append(line)
    if indented:
        protected[("code", "".join(indented))] += 1
    if block:
        protected[("code", "".join(block))] += 1
    prose = "".join(prose)
    patterns = {
        "inline code": r"(?<!`)(`+)(?!`)([\s\S]*?)(?<!`)\1(?!`)",
        "ticket": r"\b[A-Z][A-Z0-9]*-[0-9]+\b",
        "number": r"(?<![\w])[vV]?[-+]?\d+(?:[.,]\d+)*(?:%|[A-Za-z]+)?(?![\w])",
        "path": r"(?<![\w/])[~./A-Za-z0-9_@+-]*/[A-Za-z0-9_.@+-]*[A-Za-z0-9_@+-](?![\w/])",
        "file": r"(?<![\w/])[~./A-Za-z0-9_@+-]*[A-Za-z0-9_+-]\.[A-Za-z][A-Za-z0-9]*(?:/[A-Za-z0-9_.@+-]+)*(?![\w/])",
        "dotfile": r"(?<![\w/])(?:[~./A-Za-z0-9_@+-]*/)?\.[A-Za-z][A-Za-z0-9_.-]*(?![\w/])",
        "command": r"(?m)^[ \t]*(?:\$ )?(?:bash|sh|node|python3?|git|gh|npm|npx|bun|curl|make|cargo|pytest) [^\n]+",
    }
    for kind, pattern in patterns.items():
        for match in re.finditer(pattern, prose):
            protected[(kind, match[2] if kind == "inline code" else match[0])] += 1
    return protected


def main():
    if len(sys.argv) != 3:
        print("usage: humanizer-facts.py ORIGINAL REWRITE", file=sys.stderr)
        return 2
    try:
        original = sys.stdin.read() if sys.argv[1] == "-" else pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
        rewrite = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        print("humanizer: rewrite refused (cannot read draft or rewrite); use original", file=sys.stderr)
        return 2
    if not rewrite.strip():
        print("humanizer: rewrite refused (empty rewrite); use original", file=sys.stderr)
        return 1
    before, after = facts(original), facts(rewrite)
    if before != after:
        kinds = sorted({kind for kind, value in (before - after) + (after - before)})
        print("humanizer: rewrite refused (changed " + ", ".join(kinds) + "); use original", file=sys.stderr)
        return 1
    print("humanizer: accepted (literal facts unchanged; review claims before filing)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
