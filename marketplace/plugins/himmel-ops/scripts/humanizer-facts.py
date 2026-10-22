"""Normalize punctuation or compare literal facts; '-' reads the draft from stdin."""
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
        "number": r"(?<![\w])[vV]?[-+]?\d+(?:[.,]\d+)*(?:[eE][-+]?\d+)?(?:%|[A-Za-z]+)?(?![\w])",
        "path": r"(?<![\w/])[~./A-Za-z0-9_@+-]*/[A-Za-z0-9_.@+-]*[A-Za-z0-9_@+-](?![\w/])",
        "file": r"(?<![\w/])[~./A-Za-z0-9_@+-]*[A-Za-z0-9_+-]\.[A-Za-z][A-Za-z0-9]*(?:/[A-Za-z0-9_.@+-]+)*(?![\w/])",
        "dotfile": r"(?<![\w/])(?:[~./A-Za-z0-9_@+-]*/)?\.[A-Za-z](?:[A-Za-z0-9_.-]*[A-Za-z0-9_-])?(?![\w/])",
        "command": r"(?m)^[ \t]*(?:\$ )?(?:bash|sh|node|python3?|git|gh|npm|npx|bun|curl|make|cargo|pytest) [^\n]+",
    }
    for kind, pattern in patterns.items():
        for match in re.finditer(pattern, prose):
            protected[(kind, match[2] if kind == "inline code" else match[0])] += 1
    return protected


BANNED_WORDS = (
    "actually", "additionally", "align with", "bolstered", "crucial", "deep dive", "delve",
    "enduring", "enhance", "garner", "gate", "gated", "gating", "highlight", "interplay",
    "intricate", "intricacies", "key", "landscape", "meticulous", "meticulously", "pivotal",
    "quietly", "robust", "showcase", "tapestry", "testament", "underscore", "valuable", "vibrant",
    "stands as a testament", "a pivotal or crucial moment", "plays a key role",
    "marking or shaping the", "underscores its importance", "reflects a broader",
    "enduring or lasting legacy", "setting the stage for", "evolving landscape", "indelible mark",
    "despite these challenges", "continues to thrive", "challenges and legacy", "future outlook",
    "awards and recognition", "the future looks bright", "exciting times ahead",
    "a step in the right direction", "rich", "profound", "exemplifies", "commitment to",
    "natural beauty", "nestled", "in the heart of", "groundbreaking", "renowned", "featuring",
    "diverse array", "breathtaking", "must-visit", "stunning",
)


def normalize(text):
    text = re.sub(r"(?m)^([ \t]*(?:[-*+] |\d+[.)] )?)\*\*([^*\n]+)\*\*[ \t]+[—–][ \t]+", r"\1**\2:** ", text)
    text = re.sub(r"(?m)^([ \t]*(?:[-*+] |\d+[.)] )?)(`+)([^\n]+?)\2[ \t]+[—–][ \t]+", r"\1\2\3\2: ", text)
    text = re.sub(r"(?<=\S)[ \t]+[—–][ \t]+(?=\S)", ", ", text)
    return text.translate(str.maketrans({"“": '"', "”": '"', "‘": "'", "’": "'"}))


def main():
    normalizing = sys.argv[1:2] == ["--normalize"]
    args = sys.argv[2:] if normalizing else sys.argv[1:]
    if len(args) != 2:
        print("usage: humanizer-facts.py [--normalize] ORIGINAL CANDIDATE", file=sys.stderr)
        return 2
    try:
        original = sys.stdin.read() if args[0] == "-" else pathlib.Path(args[0]).read_text(encoding="utf-8")
        candidate = pathlib.Path(args[1])
        if normalizing and args[0] != "-" and (candidate.resolve() == pathlib.Path(args[0]).resolve() or
                (candidate.exists() and candidate.samefile(args[0]))):
            print("humanizer: normalization needs a separate candidate; use original", file=sys.stderr)
            return 2
        rewrite = normalize(original) if normalizing else candidate.read_text(encoding="utf-8")
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
    if normalizing:
        try:
            candidate.write_text(rewrite, encoding="utf-8")
        except (OSError, UnicodeError):
            print("humanizer: cannot write candidate; use original", file=sys.stderr)
            return 2
        flags = [word for word in BANNED_WORDS if re.search(r"(?<!\w)" + re.escape(word) + r"(?!\w)", rewrite, re.I)]
        if flags:
            print("humanizer: word flags (advisory only): " + ", ".join(flags), file=sys.stderr)
    print("humanizer: accepted (literal facts unchanged; review claims before filing)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
