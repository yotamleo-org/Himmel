#!/usr/bin/python3 -I
"""Print the paths a qmd collection would index, by its index.yml rules.

  qmd-collection-files.py --config <index.yml> <collection> [<path>...]

Each <path> is relative to the collection's root. A path is printed when
`qmd update` would index it: it matches the collection's `pattern`, matches
none of its `ignore` globs, has no dot-segment, and sits under none of
node_modules, .git, .cache, vendor, dist or build (the fork's
reindexCollectionIn, src/store.ts). The path is not stat'ed, so a deleted
file the collection held still prints.

The reader knows only the shape qmd writes: a top-level `collections:` map of
collections whose keys are `path`, `pattern` (one double-quoted glob) and
`ignore` (a list of double-quoted globs). Globs may use `*` (stops at `/`),
`**` (a whole segment, crosses `/`) and `{a,b}`. Any other shape, glob syntax
or path form exits 2, so a changed format fails loud instead of guessing.
"""

import re
import sys

EXCLUDED_DIRS = frozenset(("node_modules", ".git", ".cache", "vendor", "dist", "build"))
QUOTED = re.compile(r'"([^"\\]*)"')
NAME = re.compile(r"[A-Za-z0-9._-]+")


class Refused(Exception):
    pass


def read_rules(config, collection):
    try:
        with open(config, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError as err:
        raise Refused(f"cannot read {config}: {err.strerror}")
    except ValueError:
        raise Refused(f"{config}: not UTF-8 text")
    in_collections = False
    current = None
    seen = set()
    pattern = None
    ignore = None
    in_ignore = False
    for num, line in enumerate(lines, 1):
        where = f"{config}:{num}"
        if not line.strip() or line.lstrip(" ").startswith("#"):
            continue
        if "\t" in line or "\r" in line:
            raise Refused(f"{where}: tab or carriage return")
        body = line.lstrip(" ")
        indent = len(line) - len(body)
        if indent == 0:
            in_collections = body == "collections:"
            current = None
            in_ignore = False
            continue
        if not in_collections:
            continue
        if indent == 2:
            name = body[:-1] if body.endswith(":") else ""
            if not NAME.fullmatch(name):
                raise Refused(f"{where}: expected a collection name")
            if name in seen:
                raise Refused(f"{where}: collection {name} defined twice")
            seen.add(name)
            current = name
            in_ignore = False
            continue
        if current != collection:
            continue
        if indent == 4:
            key, sep, value = body.partition(":")
            value = value.strip()
            in_ignore = False
            if not sep:
                raise Refused(f"{where}: expected key: value")
            if key == "path":
                continue
            if key == "pattern" and pattern is None:
                match = QUOTED.fullmatch(value)
                if not match:
                    raise Refused(f"{where}: pattern must be one double-quoted glob")
                pattern = match.group(1)
                continue
            if key == "ignore" and ignore is None and value == "":
                ignore = []
                in_ignore = True
                continue
            raise Refused(f"{where}: unexpected key {key!r} in collection {collection}")
        if indent == 6 and in_ignore and body.startswith("- "):
            match = QUOTED.fullmatch(body[2:].strip())
            if not match:
                raise Refused(f"{where}: an ignore entry must be one double-quoted glob")
            ignore.append(match.group(1))
            continue
        raise Refused(f"{where}: unexpected line in collection {collection}")
    if collection not in seen:
        raise Refused(f"{config}: no collection {collection}")
    if pattern is None:
        raise Refused(f"{config}: collection {collection} has no pattern")
    return pattern, ignore or []


def expand_braces(glob):
    start = glob.find("{")
    if start < 0:
        if "}" in glob or "," in glob:
            raise Refused(f"glob {glob!r}: a comma or brace outside {{a,b}}")
        return [glob]
    depth = 0
    cuts = []
    for i in range(start, len(glob)):
        ch = glob[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                break
        elif ch == "," and depth == 1:
            cuts.append(i)
    else:
        raise Refused(f"glob {glob!r}: unclosed brace")
    if not cuts:
        raise Refused(f"glob {glob!r}: a brace without a comma")
    head, tail = glob[:start], glob[i + 1:]
    if "}" in head or "," in head:
        raise Refused(f"glob {glob!r}: a comma or brace outside {{a,b}}")
    bounds = [start] + cuts + [i]
    out = []
    for lo, hi in zip(bounds, bounds[1:]):
        out.extend(expand_braces(head + glob[lo + 1:hi] + tail))
    return out


def glob_regex(glob):
    alternatives = []
    for alt in expand_braces(glob):
        if any(ch in alt for ch in "?[]()!\\"):
            raise Refused(f"glob {glob!r}: syntax beyond * ** {{a,b}}")
        segments = alt.split("/")
        if any(seg in ("", ".", "..") for seg in segments):
            raise Refused(f"glob {glob!r}: an empty, . or .. segment")
        parts = []
        for i, seg in enumerate(segments):
            last = i == len(segments) - 1
            if seg == "**":
                parts.append(".+" if last else "(?:[^/]+/)*")
                continue
            if "**" in seg:
                raise Refused(f"glob {glob!r}: ** must be a whole segment")
            if seg == "*":
                parts.append("[^/]+")
            else:
                parts.append("[^/]*".join(re.escape(piece) for piece in seg.split("*")))
            if not last:
                parts.append("/")
        alternatives.append("".join(parts))
    return re.compile("|".join(f"(?:{alt})" for alt in alternatives))


def check_path(path):
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in path):
        raise Refused(f"path {path!r}: a control character")
    segments = path.split("/")
    if any(seg in ("", ".", "..") for seg in segments):
        raise Refused(f"path {path!r}: not a normalised relative path")
    return segments


def indexed(path, include, excludes):
    segments = check_path(path)
    if any(seg.startswith(".") for seg in segments):
        return False
    if any(seg in EXCLUDED_DIRS for seg in segments[:-1]):
        return False
    if not include.fullmatch(path):
        return False
    return not any(rx.fullmatch(path) for rx in excludes)


def main(argv):
    if len(argv) < 3 or argv[0] != "--config":
        print("usage: qmd-collection-files.py --config <index.yml> <collection> [<path>...]", file=sys.stderr)
        return 2
    config, collection, paths = argv[1], argv[2], argv[3:]
    try:
        pattern, ignore = read_rules(config, collection)
        include = glob_regex(pattern)
        excludes = [glob_regex(glob) for glob in ignore]
        keep = [path for path in paths if indexed(path, include, excludes)]
    except Refused as err:
        print(f"ERR qmd-collection-files: {err}", file=sys.stderr)
        return 2
    for path in keep:
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
